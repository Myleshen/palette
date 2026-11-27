import Darwin
import XCTest
@testable import PaletteApp

@MainActor
final class TerminalProcessesTests: XCTestCase {
    func testStoppingTerminalKillsTheChildAndItsJob() throws {
        let child = try spawn("/bin/sh", ["-c", "sleep 300 & sleep 300"])
        defer { kill(child, SIGKILL) }

        TerminalProcesses.register(child)
        TerminalProcesses.stopAll()
        _ = waitUntilGone(child, timeout: 2)
        XCTAssertFalse(isAlive(child), "the shell is left running after quit")

        let survivors = descendants(of: child)
        XCTAssertTrue(survivors.isEmpty, "jobs started by the shell survived: \(survivors)")
    }

    func testStoppingOneTerminalLeavesTheOtherRunning() throws {
        let one = try spawn("/bin/sh", ["-c", "sleep 300"])
        let two = try spawn("/bin/sh", ["-c", "sleep 300"])
        defer {
            kill(one, SIGKILL)
            kill(two, SIGKILL)
        }

        TerminalProcesses.register(one)
        TerminalProcesses.register(two)
        TerminalProcesses.stop(pid: one)

        _ = waitUntilGone(one, timeout: 2)
        XCTAssertFalse(isAlive(one))
        XCTAssertTrue(isAlive(two), "stopping one terminal killed another")
    }

    // MARK: - Helpers

    private func spawn(_ path: String, _ args: [String]) throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try process.run()
        return process.processIdentifier
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    @discardableResult
    private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            usleep(20_000)
        }
        return !isAlive(pid)
    }

    /// Children of a dead wrapper are reparented, so scan every process for a
    /// parent pid we are checking. Small enough for a test on this machine.
    private func descendants(of pid: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var candidates: [pid_t] = [pid]
        for _ in 0..<3 {
            var next: [pid_t] = []
            for candidate in candidates {
                for child in children(of: candidate) where !out.contains(child) {
                    out.append(child)
                    next.append(child)
                }
            }
            candidates = next
        }
        return out
    }

    private func children(of pid: pid_t) -> [pid_t] {
        var capacity = 16
        while capacity <= 4096 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let size = proc_listchildpids(pid, &pids, Int32(capacity * MemoryLayout<pid_t>.stride))
            if size <= 0 { return [] }
            let count = Int(size) / MemoryLayout<pid_t>.stride
            if count < capacity { return pids.prefix(count).filter { $0 > 0 } }
            capacity *= 2
        }
        return []
    }
}
