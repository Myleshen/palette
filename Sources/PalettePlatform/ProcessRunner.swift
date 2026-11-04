import Darwin
import Foundation
import PaletteCore

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

public enum ProcessRunner {
    public static func run(
        _ arguments: [String],
        cwd: String? = nil,
        environment additions: [String: String] = [:],
        stdin: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        guard !arguments.isEmpty else {
            throw ProviderError.failed("Empty command")
        }

        let executable: String
        if arguments[0].contains("/") {
            executable = arguments[0]
        } else {
            guard let resolved = ToolLocator.shared.path(for: arguments[0]) else {
                throw ProviderError.toolMissing(arguments[0])
            }
            executable = resolved
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: PathExpansion.expand(cwd), isDirectory: true)
        }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in additions {
            environment[key] = value
        }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if stdin != nil {
            process.standardInput = Pipe()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: ProviderError.failed(error.localizedDescription))
                        return
                    }

                    if let stdin, let inputPipe = process.standardInput as? Pipe {
                        inputPipe.fileHandleForWriting.write(stdin)
                        try? inputPipe.fileHandleForWriting.close()
                    }

                    let group = DispatchGroup()
                    var outData = Data()
                    var errData = Data()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    final class TimeoutFlag: @unchecked Sendable {
                        var value = false
                    }
                    let timedOut = TimeoutFlag()
                    var timeoutWork: DispatchWorkItem?
                    if let timeout, timeout > 0 {
                        let work = DispatchWorkItem {
                            if process.isRunning {
                                timedOut.value = true
                                process.terminate()
                                let pid = process.processIdentifier
                                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                                    if process.isRunning {
                                        kill(pid, SIGKILL)
                                    }
                                }
                            }
                        }
                        timeoutWork = work
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
                    }

                    process.waitUntilExit()
                    group.wait()
                    timeoutWork?.cancel()

                    continuation.resume(returning: ProcessResult(
                        status: process.terminationStatus,
                        stdout: outData,
                        stderr: errData,
                        timedOut: timedOut.value
                    ))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Launch without waiting. Used for apps and detached terminals.
    public static func launch(_ arguments: [String], cwd: String? = nil, environment additions: [String: String] = [:]) throws {
        guard !arguments.isEmpty else { return }
        let executable: String
        if arguments[0].contains("/") {
            executable = arguments[0]
        } else if let resolved = ToolLocator.shared.path(for: arguments[0]) {
            executable = resolved
        } else {
            throw ProviderError.toolMissing(arguments[0])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: PathExpansion.expand(cwd), isDirectory: true)
        }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in additions { environment[key] = value }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
