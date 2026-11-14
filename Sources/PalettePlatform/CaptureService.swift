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

    private var recorder: Process?
    private var recordingURL: URL?
    private var recordingStartedAt: Date?

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
        if config.screenshotAction.savesFile {
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
            return CaptureResult(url: temp, copied: copied)
        }
        let message = copied ? "Saved and copied \(final.lastPathComponent)" : "Saved \(final.lastPathComponent)"
        onStatus?(message)
        return CaptureResult(url: final, copied: copied)
    }

    // MARK: - Recording

    public func startRecording() throws {
        guard !isRecording else { return }
        let directory = try destinationDirectory()
        let target = directory.appendingPathComponent(fileName(kind: "rec", extension: "mov"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.tool)
        var arguments = ["-v"]
        if config.captureCursor { arguments.append("-C") }
        if config.showClicks { arguments.append("-k") }
        arguments.append(target.path)
        process.arguments = arguments
        try process.run()
        recorder = process
        Log.shared.info("Recording started to \(target.lastPathComponent) (pid \(process.processIdentifier))", source: "capture")
        recordingURL = target
        recordingStartedAt = Date()
        onStatus?("Recording to \(target.lastPathComponent)")
    }

    public func stopRecording() async throws -> URL {
        guard let process = recorder, process.isRunning else { throw CaptureError.recordingNotRunning }
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
