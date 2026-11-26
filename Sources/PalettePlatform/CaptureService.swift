import AppKit
import Foundation
import PaletteCore

public enum CaptureMode: String, Sendable {
    case screen
    case region
    case window
}

public enum CaptureError: LocalizedError {
    case cancelled
    case failed(String)
    case recordingNotRunning
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Capture cancelled"
        case .failed(let message):
            return message.isEmpty ? "Capture failed" : message
        case .recordingNotRunning:
            return "No recording is running"
        case .recordingFailed(let message):
            return message.isEmpty ? "Recording failed" : message
        }
    }
}

public struct CaptureResult: Sendable {
    public var url: URL
    public var copied: Bool
}

/// Image bytes Palette put on the pasteboard itself, with the thumbnail and
/// pixel size when the caller already has them. Zero dimensions and a nil
/// thumbnail are filled in once by `prepared()`, never by the store.
public struct PaletteClipboardImage: Sendable {
    public var png: Data
    public var thumbnail: Data?
    public var width: Int
    public var height: Int

    public init(png: Data, thumbnail: Data? = nil, width: Int = 0, height: Int = 0) {
        self.png = png
        self.thumbnail = thumbnail
        self.width = width
        self.height = height
    }
}

/// Bytes Palette put on the pasteboard itself. The clipboard monitor skips
/// Palette's own writes, so the app records these explicitly to keep `/clip`
/// complete; path and reveal copies carry no bytes and are never recorded.
public enum PaletteClipboardCopy: Sendable {
    case image(PaletteClipboardImage)
    case files([String], thumbnail: Data?)

    /// Does the one decode or icon lookup a copy needs, so the store only
    /// writes bytes. Call it off the main actor: a full-size screenshot decode
    /// is what used to stall the capture path.
    public func prepared() -> PaletteClipboardCopy {
        switch self {
        case .image(var image):
            if image.width <= 0 || image.height <= 0,
               let size = ClipboardMonitor.imageSize(of: image.png) {
                image.width = size.width
                image.height = size.height
            }
            if image.thumbnail == nil {
                image.thumbnail = ClipboardMonitor.thumbnailPNG(from: image.png)
            }
            return .image(image)
        case .files(let paths, .none):
            return .files(paths, thumbnail: ClipboardMonitor.fileThumbnail(paths.first))
        case .files:
            return self
        }
    }
}

/// What `startRecording` leaves on disk so a relaunch can adopt or clean up the
/// recorder after a quit or a crash.
struct RecordingState: Codable, Equatable, Sendable {
    var pid: Int32
    var startedAt: Double
    var path: String
}

public enum RecordingAdoption: Equatable, Sendable {
    case none
    case adopted(path: String, startedAt: Date)
    case cleanedUp(reason: String)
}

/// Screenshots and screen recordings through the system capture engine, with
/// the saved file, clipboard copy, and errors surfaced instead of swallowed.
@MainActor
public final class CaptureService {
    public var config: CaptureConfig {
        didSet {
            guard config != oldValue else { return }
            onConfigChanged?(config)
        }
    }
    /// A `/rec` choice writes through to config.toml instead of dying with the
    /// process.
    public var onConfigChanged: ((CaptureConfig) -> Void)?
    public var onStatus: ((String) -> Void)?
    /// Called with the saved file after a screenshot, and after a recording
    /// stops, so the app can show the annotator or the player.
    public var onScreenshot: ((URL) -> Void)?
    public var onRecordingStopped: ((URL) -> Void)?
    /// Palette's own copy, which the monitor deliberately skips. The app
    /// records it in history; only bytes, never a path copy.
    public var onCopiedToPasteboard: ((PaletteClipboardCopy) -> Void)?
    /// Set false for scripted runs: a TCC dialog steals focus from the panel
    /// the flow is checking, and CI cannot grant Screen Recording anyway.
    public var requestsPermission = true
    /// Set by the "capture and annotate" rows.
    public var annotateNextCapture = false
    /// Failures the user is not looking at: the panel is hidden while
    /// recording, so a dead recorder has to be reported, not just dropped.
    public var onFailure: ((String) -> Void)?

    private var recorder: Process?
    private var adopted: RecordingState?
    private var recordingURL: URL?
    private var recordingStartedAt: Date?
    private var stopRequested = false
    /// `stateDir/recording.json`. Nil keeps this service memory-only (tests).
    public var stateFile: URL?
    /// Injectable so a test can adopt a real child process without Screen
    /// Recording permission.
    public var toolPath = "/usr/sbin/screencapture"

    public init(config: CaptureConfig = CaptureConfig()) {
        self.config = config
    }

    public var isRecording: Bool {
        if recorder?.isRunning == true { return true }
        if let adopted { return Self.isAlive(adopted.pid) }
        return false
    }

    /// The pid of the live recorder, ours or adopted after a relaunch.
    private var recordingPid: pid_t? {
        if let recorder, recorder.isRunning { return recorder.processIdentifier }
        if let adopted, Self.isAlive(adopted.pid) { return adopted.pid }
        return nil
    }

    // MARK: - Crash recovery

    /// Adopts a recorder left running by a previous Palette, or removes the
    /// state file when its pid is gone or is no longer screencapture.
    @discardableResult
    public func adoptPendingRecording() -> RecordingAdoption {
        guard let stateFile else { return .none }
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return .none }
        guard let data = try? Data(contentsOf: stateFile) else {
            try? FileManager.default.removeItem(at: stateFile)
            Log.shared.warn("Removed an unreadable recording state file", source: "capture")
            return .cleanedUp(reason: "unreadable state file")
        }
        guard let record = try? JSONDecoder().decode(RecordingState.self, from: data) else {
            try? FileManager.default.removeItem(at: stateFile)
            Log.shared.warn("Removed an unreadable recording state file", source: "capture")
            return .cleanedUp(reason: "unreadable state file")
        }

        let outcome = Self.decideAdoption(
            record: record,
            pidAlive: Self.isAlive(record.pid),
            executablePath: Self.executablePath(of: record.pid),
            expectedExecutable: toolPath
        )
        switch outcome {
        case .adopted(let path, let startedAt):
            adopted = record
            recordingURL = URL(fileURLWithPath: path)
            recordingStartedAt = startedAt
            Log.shared.info(
                "Adopted running recording pid \(record.pid) → \(path)",
                source: "capture"
            )
            onStatus?("Recording in progress")
        case .cleanedUp(let reason):
            try? FileManager.default.removeItem(at: stateFile)
            Log.shared.warn("Removed a stale recording state file: \(reason)", source: "capture")
        case .none:
            break
        }
        return outcome
    }

    /// Rule for the state file: only a live `screencapture` pid is adopted.
    nonisolated static func decideAdoption(
        record: RecordingState,
        pidAlive: Bool,
        executablePath: String?,
        expectedExecutable: String = "/usr/sbin/screencapture"
    ) -> RecordingAdoption {
        guard pidAlive else {
            return .cleanedUp(reason: "pid \(record.pid) is gone")
        }
        guard let executablePath,
              FDEnumerator.canonicalPath(executablePath) == FDEnumerator.canonicalPath(expectedExecutable) else {
            return .cleanedUp(
                reason: "pid \(record.pid) is \(executablePath ?? "unknown"), not screencapture"
            )
        }
        return .adopted(path: record.path, startedAt: Date(timeIntervalSince1970: record.startedAt))
    }

    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func executablePath(of pid: pid_t) -> String? {
        let size = Int(MAXPATHLEN) * 4
        var buffer = [CChar](repeating: 0, count: size)
        guard proc_pidpath(pid, &buffer, UInt32(size)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private func writeState(pid: pid_t, startedAt: Date, path: String) {
        guard let stateFile else { return }
        let record = RecordingState(pid: pid, startedAt: startedAt.timeIntervalSince1970, path: path)
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: stateFile, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateFile.path
            )
        } catch {
            Log.shared.warn("Could not write the recording state file: \(error.localizedDescription)", source: "capture")
        }
    }

    private func clearStateFile() {
        guard let stateFile else { return }
        try? FileManager.default.removeItem(at: stateFile)
    }

    public var recordingElapsed: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    // MARK: - Screenshots

    public func screenshot(_ mode: CaptureMode) async throws -> CaptureResult {
        // A cancelled capture must not leave "annotate next" armed for a plain
        // shot days later. onScreenshot still sees the flag inside this call.
        let annotate = annotateNextCapture
        defer { annotateNextCapture = false }
        try requireScreenRecording()
        let directory = try destinationDirectory()
        // Ask screencapture for the real format: a jpg config used to leave PNG
        // bytes under a .jpg name.
        let format = config.screenshotFormat == "jpg" ? "jpg" : "png"
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-shot-\(UUID().uuidString).\(format)")

        var arguments = ["-x"]
        switch mode {
        case .screen:
            break
        case .region:
            arguments.append("-i")
        case .window:
            arguments.append(contentsOf: ["-i", "-w"])
        }
        if config.captureCursor { arguments.append("-C") }
        if config.delay > 0 { arguments.append(contentsOf: ["-T", String(config.delay)]) }
        arguments.append(contentsOf: ["-t", format])
        arguments.append(temp.path)

        let result = try await ProcessRunner.run([toolPath] + arguments, timeout: 120)
        guard result.status == 0 else {
            throw CaptureError.failed(Self.message(result, fallback: "Screen capture failed"))
        }
        guard FileManager.default.fileExists(atPath: temp.path) else {
            // `screencapture -i` exits 0 when the user presses escape.
            throw mode == .screen ? CaptureError.failed("Screen capture produced no file") : CaptureError.cancelled
        }

        var saved: URL?
        // The annotator can only save over a real file, so a copy-only (or
        // edit) action still writes one when this capture is going to the
        // editor. Deleting the temp first is what broke "Could not open …".
        if config.screenshotAction.savesFile || annotate || config.editAfterCapture {
            let target = directory.appendingPathComponent(
                fileName(kind: "shot", ext: format, in: directory)
            )
            // Never remove an existing capture: the unique name guarantees a
            // free slot even for two shots in the same second.
            try FileManager.default.moveItem(at: temp, to: target)
            saved = target
        }
        var copied = false
        if config.screenshotAction.copiesToClipboard {
            copied = copyImageToPasteboard(saved ?? temp)
        }
        if config.screenshotAction == .preview, let saved {
            NSWorkspace.shared.open(saved)
        }
        // Keep the temp until after onScreenshot: that callback is what opens
        // the annotator or reads the image for the confirmation HUD.
        if saved == nil {
            onScreenshot?(temp)
            try? FileManager.default.removeItem(at: temp)
            return CaptureResult(url: temp, copied: copied)
        }
        let final = saved ?? temp
        let message = copied ? "Saved and copied \(final.lastPathComponent)" : "Saved \(final.lastPathComponent)"
        onStatus?(message)
        onScreenshot?(final)
        return CaptureResult(url: final, copied: copied)
    }

    // MARK: - Recording

    /// screencapture just says "could not create image from display" when the
    /// grant is missing, so ask for the permission and say what to do.
    private func requireScreenRecording() throws {
        if CGPreflightScreenCaptureAccess() { return }
        if requestsPermission, CGRequestScreenCaptureAccess() { return }
        throw CaptureError.failed(
            "Screen Recording is off for Palette. Enable it in System Settings → Privacy & Security → Screen Recording, then try again."
        )
    }

    public func startRecording() throws {
        guard !isRecording else { return }
        try requireScreenRecording()
        let directory = try destinationDirectory()
        let target = directory.appendingPathComponent(
            fileName(kind: "rec", ext: "mov", in: directory)
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        let arguments = Self.recordingArguments(config: config, path: target.path)
        process.arguments = arguments
        // screencapture exits at once when Screen Recording is not granted;
        // without this the indicator just vanishes mid-recording.
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.recorder === finished, !self.stopRequested else { return }
                self.recorder = nil
                self.recordingStartedAt = nil
                self.recordingURL = nil
                self.clearStateFile()
                let message = "Recording failed: screencapture exited with status \(finished.terminationStatus). Grant Screen Recording in System Settings → Privacy & Security."
                Log.shared.error(message, source: "capture")
                self.onFailure?(message)
            }
        }
        try process.run()
        recorder = process
        stopRequested = false
        let startedAt = Date()
        Log.shared.info(
            "Recording started to \(target.lastPathComponent) (pid \(process.processIdentifier), args: \(arguments.joined(separator: " ")))",
            source: "capture"
        )
        recordingURL = target
        recordingStartedAt = startedAt
        writeState(pid: process.processIdentifier, startedAt: startedAt, path: target.path)
        onStatus?("Recording to \(target.lastPathComponent)")
    }

    /// The exact `screencapture -v` arguments for a config. Kept separate so
    /// the target, display, region and audio options are testable without
    /// running a capture.
    public nonisolated static func recordingArguments(config: CaptureConfig, path: String) -> [String] {
        var arguments = ["-v"]
        switch config.recordingTarget {
        case "display":
            arguments.append(contentsOf: ["-D", String(max(1, config.recordingDisplay))])
        case "region":
            let region = config.recordingRegion.trimmingCharacters(in: .whitespaces)
            if !region.isEmpty { arguments.append(contentsOf: ["-R", region]) }
        default:
            break
        }
        if config.recordingAudio {
            let microphone = config.recordingMicrophone.trimmingCharacters(in: .whitespaces)
            if microphone.isEmpty {
                arguments.append("-g")
            } else {
                arguments.append(contentsOf: ["-G", microphone])
            }
        }
        if config.captureCursor { arguments.append("-C") }
        if config.showClicks { arguments.append("-k") }
        arguments.append(path)
        return arguments
    }

    public func stopRecording() async throws -> URL {
        guard let pid = recordingPid else {
            clearStateFile()
            throw CaptureError.recordingNotRunning
        }
        stopRequested = true
        kill(pid, SIGINT)
        let deadline = Date().addingTimeInterval(5)
        while Self.isAlive(pid) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if Self.isAlive(pid) { kill(pid, SIGTERM) }
        let graceDeadline = Date().addingTimeInterval(3)
        while Self.isAlive(pid) && Date() < graceDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if Self.isAlive(pid) {
            kill(pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let stderr = ""
        // terminationStatus would wait for the (already reaped) child only when
        // it is still our child; an adopted pid never is.
        let status = recorder.map { $0.isRunning ? -1 : $0.terminationStatus } ?? -1
        Log.shared.info("Recording stopped with status \(status)\(stderr.isEmpty ? "" : ": \(stderr)")", source: "capture")
        recorder = nil
        adopted = nil
        recordingStartedAt = nil
        stopRequested = false
        clearStateFile()

        guard let url = recordingURL else { throw CaptureError.recordingNotRunning }
        recordingURL = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureError.recordingFailed(stderr.isEmpty ? "The recording produced no file" : stderr)
        }

        var final = url
        if config.recordingFormat == "mp4" {
            let mp4 = url.deletingPathExtension().appendingPathExtension("mp4")
            if let converted = try? await convertToMP4(url, mp4) {
                try? FileManager.default.removeItem(at: url)
                final = converted
            }
        }
        if config.recordingAction.copiesToClipboard {
            copyFileToPasteboard(final)
        }
        onStatus?("Saved \(final.lastPathComponent)")
        onRecordingStopped?(final)
        return final
    }

    /// Synchronous quit path: SIGINT gives screencapture time to finalise the
    /// file. The mp4 conversion and preview are skipped because the app is going
    /// away; the raw recording is kept.
    public func stopRecordingOnQuit() {
        guard let pid = recordingPid else {
            clearStateFile()
            return
        }
        stopRequested = true
        kill(pid, SIGINT)
        let deadline = Date().addingTimeInterval(5)
        while Self.isAlive(pid) && Date() < deadline {
            usleep(100_000)
        }
        if Self.isAlive(pid) { kill(pid, SIGTERM) }
        let graceDeadline = Date().addingTimeInterval(1)
        while Self.isAlive(pid) && Date() < graceDeadline {
            usleep(100_000)
        }
        if Self.isAlive(pid) {
            kill(pid, SIGKILL)
            usleep(300_000)
        }
        Log.shared.info("Recording stopped for quit (pid \(pid))", source: "capture")
        recorder = nil
        adopted = nil
        recordingURL = nil
        recordingStartedAt = nil
        clearStateFile()
    }

    // MARK: - Helpers

    private func convertToMP4(_ source: URL, _ target: URL) async throws -> URL {
        let result = try await ProcessRunner.run([
            "/usr/bin/avconvert",
            "--source", source.path,
            "--preset", "PresetHighestQuality",
            "--output", target.path,
        ], timeout: 600)
        guard result.status == 0 else {
            throw CaptureError.recordingFailed(Self.message(result, fallback: "Could not convert the recording to mp4"))
        }
        return target
    }

    private func destinationDirectory() throws -> URL {
        let expanded = (config.directory as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CaptureError.failed("Could not create \(url.path): \(error.localizedDescription)")
        }
        return url
    }

    /// Millisecond resolution plus a free-name check: two captures in the same
    /// second used to delete the earlier file.
    private func fileName(kind: String, ext: String, in directory: URL) -> String {
        Self.uniqueFileName(kind: kind, ext: ext, in: directory, date: Date())
    }

    /// The name is deterministic for a given date, so tests can prove two
    /// captures in the same second never collide.
    public nonisolated static func uniqueFileName(
        kind: String,
        ext: String,
        in directory: URL,
        date: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let stem = "\(kind)-\(formatter.string(from: date))"
        let manager = FileManager.default
        var candidate = "\(stem).\(ext)"
        var suffix = 2
        while manager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(stem)-\(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    private func copyImageToPasteboard(_ url: URL) -> Bool {
        // One read for the pasteboard write and the history row; the old path
        // read the saved file again after the copy. The bytes go straight onto
        // the pasteboard, so no full-size decode or TIFF encode runs here.
        guard let data = try? Data(contentsOf: url) else { return false }
        let type: NSPasteboard.PasteboardType = url.pathExtension.lowercased() == "jpg"
            ? NSPasteboard.PasteboardType("public.jpeg")
            : .png
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: type) else { return false }
        ClipboardMonitor.notePaletteWrite(pasteboard.changeCount)
        onCopiedToPasteboard?(.image(PaletteClipboardImage(png: data)))
        return true
    }

    private func copyFileToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        ClipboardMonitor.notePaletteWrite(pasteboard.changeCount)
        onCopiedToPasteboard?(.files([url.path], thumbnail: nil))
    }

    private static func message(_ result: ProcessResult, fallback: String) -> String {
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        return "\(fallback) (exit \(result.status))"
    }
}
