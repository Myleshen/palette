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
    /// Keys and session tokens that must never leak into a provider script or
    /// an unrelated child (`git`, `gh`, a provider's own subprocesses).
    public static let secretEnvironmentNames: [String] =
        AskEndpoint.allCases.flatMap(\.keyEnvironment) + ["BW_SESSION", "BW_PASSWORD"]

    /// Drops inherited secrets but keeps anything the caller passes explicitly
    /// (Bitwarden hands `BW_SESSION` to `bw` on purpose).
    public static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        var clean = environment
        for name in secretEnvironmentNames {
            clean.removeValue(forKey: name)
        }
        return clean
    }

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
        let executable = try resolveExecutable(arguments[0])

        var environment = sanitizedEnvironment(ProcessInfo.processInfo.environment)
        for (key, value) in additions {
            environment[key] = value
        }

        // Raw pipes: plain `read(2)` never raises, so a timeout can close the
        // read end from another thread and unblock the reader.
        var outFDs: [Int32] = [-1, -1]
        var errFDs: [Int32] = [-1, -1]
        guard pipe(&outFDs) == 0, pipe(&errFDs) == 0 else {
            throw ProviderError.failed("Could not create pipes")
        }
        for fd in outFDs + errFDs {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        var stdinFDs: [Int32] = [-1, -1]
        if stdin != nil {
            guard pipe(&stdinFDs) == 0 else {
                throw ProviderError.failed("Could not create the input pipe")
            }
            for fd in stdinFDs {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            }
        }

        let pidBox = PidBox()
        let timeoutState = TimeoutState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var actions: posix_spawn_file_actions_t?
                    posix_spawn_file_actions_init(&actions)
                    defer { posix_spawn_file_actions_destroy(&actions) }
                    posix_spawn_file_actions_adddup2(&actions, outFDs[1], STDOUT_FILENO)
                    posix_spawn_file_actions_adddup2(&actions, errFDs[1], STDERR_FILENO)
                    if stdin != nil {
                        posix_spawn_file_actions_adddup2(&actions, stdinFDs[0], STDIN_FILENO)
                    } else {
                        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
                    }
                    if let cwd {
                        posix_spawn_file_actions_addchdir_np(
                            &actions,
                            PathExpansion.expand(cwd)
                        )
                    }

                    var attributes: posix_spawnattr_t?
                    posix_spawnattr_init(&attributes)
                    defer { posix_spawnattr_destroy(&attributes) }
                    // A new process group lets a timeout kill grandchildren that
                    // still hold stdout open, not just the direct child.
                    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
                    posix_spawnattr_setpgroup(&attributes, 0)

                    let argv = cStrings([executable] + Array(arguments.dropFirst()))
                    let envp = cStrings(environment.map { "\($0.key)=\($0.value)" })
                    defer {
                        for pointer in argv { free(pointer) }
                        for pointer in envp { free(pointer) }
                    }

                    var pid: pid_t = 0
                    let spawnResult = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
                    guard spawnResult == 0 else {
                        Darwin.close(outFDs[0]); Darwin.close(outFDs[1])
                        Darwin.close(errFDs[0]); Darwin.close(errFDs[1])
                        if stdin != nil {
                            Darwin.close(stdinFDs[0]); Darwin.close(stdinFDs[1])
                        }
                        let message = String(cString: strerror(spawnResult))
                        continuation.resume(throwing: ProviderError.failed(message))
                        return
                    }

                    pidBox.store(pid)
                    Darwin.close(outFDs[1])
                    Darwin.close(errFDs[1])
                    if stdin != nil {
                        Darwin.close(stdinFDs[0])
                        if let stdin {
                            stdin.withUnsafeBytes { buffer in
                                var offset = 0
                                while offset < buffer.count {
                                    let written = write(stdinFDs[1], buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                                    if written <= 0 { if errno == EINTR { continue }; break }
                                    offset += written
                                }
                            }
                        }
                        Darwin.close(stdinFDs[1])
                    }

                    let outReader = PipeReader(outFDs[0])
                    let errReader = PipeReader(errFDs[0])
                    let group = DispatchGroup()
                    var outData = Data()
                    var errData = Data()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        outData = outReader.readAll()
                        outReader.close()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errData = errReader.readAll()
                        errReader.close()
                        group.leave()
                    }

                    var timeoutWork: DispatchWorkItem?
                    if let timeout, timeout > 0 {
                        let work = DispatchWorkItem {
                            guard timeoutState.markTimedOut() else { return }
                            kill(-pid, SIGTERM)
                            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                                kill(-pid, SIGKILL)
                            }
                            // A killed grandchild closes its copy of the pipe,
                            // but close our read ends too in case it is stuck.
                            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                                outReader.close()
                                errReader.close()
                            }
                        }
                        timeoutWork = work
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
                    }

                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1, errno == EINTR {}

                    // Descendants that outlive the command would otherwise keep
                    // the pipes open and hang the caller after the command ended.
                    kill(-pid, SIGKILL)

                    if group.wait(timeout: .now() + 2) == .timedOut {
                        outReader.close()
                        errReader.close()
                        group.wait()
                    }
                    timeoutWork?.cancel()

                    continuation.resume(returning: ProcessResult(
                        status: exitStatus(status),
                        stdout: outData,
                        stderr: errData,
                        timedOut: timeoutState.timedOut
                    ))
                }
            }
        } onCancel: {
            pidBox.cancel()
        }
    }

    /// Launch without waiting. Used for apps and detached terminals.
    public static func launch(_ arguments: [String], cwd: String? = nil, environment additions: [String: String] = [:]) throws {
        guard !arguments.isEmpty else { return }
        let executable = try resolveExecutable(arguments[0])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: PathExpansion.expand(cwd), isDirectory: true)
        }
        var environment = sanitizedEnvironment(ProcessInfo.processInfo.environment)
        for (key, value) in additions { environment[key] = value }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func resolveExecutable(_ command: String) throws -> String {
        if command.contains("/") { return command }
        guard let resolved = ToolLocator.shared.path(for: command) else {
            throw ProviderError.toolMissing(command)
        }
        return resolved
    }

    private static func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        values.map { strdup($0) } + [nil]
    }

    private static func exitStatus(_ status: Int32) -> Int32 {
        let signalBits = status & 0x7f
        if signalBits == 0 {
            return (status >> 8) & 0xff
        }
        if signalBits != 0x7f {
            return 128 + signalBits
        }
        return (status >> 8) & 0xff
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var didTimeOut = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    func markTimedOut() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didTimeOut else { return false }
        didTimeOut = true
        return true
    }
}

private final class PidBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    func store(_ value: pid_t) {
        lock.lock()
        pid = value
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { terminateGroup(value) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let value = pid
        lock.unlock()
        if value > 0 { terminateGroup(value) }
    }

    private func terminateGroup(_ value: pid_t) {
        kill(-value, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            kill(-value, SIGKILL)
        }
    }
}

/// Owns one pipe read end so a timeout can close it exactly once while the
/// reader thread is blocked in `read(2)`.
private final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    func readAll() -> Data {
        let fd = currentDescriptor()
        guard fd >= 0 else { return Data() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }

    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    private func currentDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }
}
