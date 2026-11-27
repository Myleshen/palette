import Darwin
import Dispatch

/// Live PTY children. They are not children of this process in the POSIX sense
/// (the shell is reparented after `forkpty`), so quitting the app would leave
/// the shell — and anything it started — running. Register on start, unregister
/// on exit, and stop them all when the app terminates.
@MainActor
enum TerminalProcesses {
    private static var pids: Set<pid_t> = []

    static func register(_ pid: pid_t) {
        guard pid > 0 else { return }
        pids.insert(pid)
    }

    static func unregister(_ pid: pid_t) {
        pids.remove(pid)
    }

    /// Stops one terminal: the shell and any job it left behind.
    static func stop(pid: pid_t) {
        guard pid > 0 else { return }
        unregister(pid)
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            if kill(pid, 0) == 0 {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }

    /// Terminates every live terminal's process group. `forkpty` makes the
    /// child a session leader, so `-pid` reaches the shell and its jobs.
    static func stopAll() {
        guard !pids.isEmpty else { return }
        for pid in pids {
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
        }
        usleep(250_000)
        for pid in pids where kill(pid, 0) == 0 {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        pids.removeAll()
    }
}
