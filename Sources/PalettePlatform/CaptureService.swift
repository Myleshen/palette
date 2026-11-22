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
    public var config: CaptureConfig
    public var onStatus: ((String) -> Void)?
    /// Called with the saved file after a screenshot, and after a recording
    /// stops, so the app can show the annotator or the player.
    public var onScreenshot: ((URL) -> Void)?
    public var onRecordingStopped: ((URL) -> Void)?
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
        try Self.requireScreenRecording()
        let directory = try destinationDirectory()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-shot-\(UUID().uuidString).png")

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
        // The annotator can only save over a real file, so a copy-only action
        // still writes one when this capture is going to the editor.
        if config.screenshotAction.savesFile || annotateNextCapture {
            let target = directory.appendingPathComponent(fileName(kind: "shot", extension: config.screenshotFormat))
            try? FileManager.default.removeItem(at: target)
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
        if saved == nil { try? FileManager.default.removeItem(at: temp) }

        guard let final = saved else {
            onScreenshot?(temp)
            return CaptureResult(url: temp, copied: copied)
        }
        let message = copied ? "Saved and copied \(final.lastPathComponent)" : "Saved \(final.lastPathComponent)"
        onStatus?(message)
        onScreenshot?(final)
        return CaptureResult(url: final, copied: copied)
    }

    // MARK: - Recording

    /// screencapture just says "could not create image from display" when the
    /// grant is missing, so ask for the permission and say what to do.
    private static func requireScreenRecording() throws {
        if CGPreflightScreenCaptureAccess() { return }
        if CGRequestScreenCaptureAccess() { return }
        throw CaptureError.failed(
            "Screen Recording is off for Palette. Enable it in System Settings → Privacy & Security → Screen Recording, then try again."
        )
    }

    public func startRecording() throws {
        guard !isRecording else { return }
        try Self.requireScreenRecording()
        let directory = try destinationDirectory()
        let target = directory.appendingPathComponent(fileName(kind: "rec", extension: "mov"))
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

    private func fileName(kind: String, extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(kind)-\(formatter.string(from: Date())).\(ext)"
    }

    private func copyImageToPasteboard(_ url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    private func copyFileToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private static func message(_ result: ProcessResult, fallback: String) -> String {
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        return "\(fallback) (exit \(result.status))"
    }
}
