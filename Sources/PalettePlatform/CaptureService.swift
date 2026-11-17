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
    private var recordingURL: URL?
    private var recordingStartedAt: Date?
    private var stopRequested = false

    public init(config: CaptureConfig = CaptureConfig()) {
        self.config = config
    }

    private static let tool = "/usr/sbin/screencapture"

    public var isRecording: Bool { recorder?.isRunning == true }

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

        let result = try await ProcessRunner.run([Self.tool] + arguments, timeout: 120)
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
        process.executableURL = URL(fileURLWithPath: Self.tool)
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
                let message = "Recording failed: screencapture exited with status \(finished.terminationStatus). Grant Screen Recording in System Settings → Privacy & Security."
                Log.shared.error(message, source: "capture")
                self.onFailure?(message)
            }
        }
        try process.run()
        recorder = process
        stopRequested = false
        Log.shared.info(
            "Recording started to \(target.lastPathComponent) (pid \(process.processIdentifier), args: \(arguments.joined(separator: " ")))",
            source: "capture"
        )
        recordingURL = target
        recordingStartedAt = Date()
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
        guard let process = recorder, process.isRunning else { throw CaptureError.recordingNotRunning }
        stopRequested = true
        process.interrupt()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning { process.terminate() }
        let graceDeadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < graceDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            // Never block on terminationStatus: it waits for the process.
            kill(process.processIdentifier, SIGKILL)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let stderr = ""
        let status = process.isRunning ? -1 : process.terminationStatus
        Log.shared.info("Recording stopped with status \(status)\(stderr.isEmpty ? "" : ": \(stderr)")", source: "capture")
        recorder = nil
        recordingStartedAt = nil
        stopRequested = false

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
