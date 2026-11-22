import AppKit
import Foundation
import IOKit.pwr_mgt
import PaletteCore

extension Notification.Name {
    /// Posted when the root clamshell guard stops being armed.
    public static let paletteClamshellDropped = Notification.Name("palette.clamshell.dropped")
}

public struct KeepAwakeStatus: Sendable, Equatable {
    public var active: Bool
    public var startedAt: Date?
    public var endsAt: Date?
    public var displaySleepPrevented: Bool
    public var clamshell: Bool
    public var clamshellRequiresPower: Bool

    public init(
        active: Bool = false,
        startedAt: Date? = nil,
        endsAt: Date? = nil,
        displaySleepPrevented: Bool = true,
        clamshell: Bool = false,
        clamshellRequiresPower: Bool = true
    ) {
        self.active = active
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.displaySleepPrevented = displaySleepPrevented
        self.clamshell = clamshell
        self.clamshellRequiresPower = clamshellRequiresPower
    }

    public var remaining: TimeInterval? {
        guard let endsAt else { return nil }
        return max(0, endsAt.timeIntervalSinceNow)
    }

    public var remainingLabel: String {
        guard let remaining else { return "indefinitely" }
        let total = Int(remaining.rounded())
        if total >= 3600 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        if total >= 60 {
            return "\(total / 60)m"
        }
        return "\(total)s"
    }
}

public protocol ClamshellControlling: Sendable {
    func isEnabled() async -> Bool
    /// True only when the flag exists *and* the system reports sleep disabled
    /// (or the Mac is on battery, where the guard arms on AC).
    func isArmed() async -> Bool
    func enable() async throws
    func disable() async
}

/// Keeps the Mac awake with IOPM assertions. Clamshell mode additionally uses
/// a short-lived root guard, because macOS treats a lid close as forced sleep
/// and user-space assertions cannot override it.
public actor KeepAwakeService {
    private let assertionsEnabled: Bool
    private let clamshellGuard: any ClamshellControlling
    private let timerInterval: TimeInterval
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var clamshellAssertion: IOPMAssertionID = 0
    private var timer: DispatchSourceTimer?
    private var status = KeepAwakeStatus()
    private var observerTokens: [NSObjectProtocol] = []
    private var expiryTask: Task<Void, Never>?

    public init(
        assertionsEnabled: Bool = true,
        clamshellGuard: any ClamshellControlling = ClamshellGuard(),
        timerInterval: TimeInterval = 30
    ) {
        self.assertionsEnabled = assertionsEnabled
        self.clamshellGuard = clamshellGuard
        self.timerInterval = max(0.1, timerInterval)
    }

    deinit {
        timer?.cancel()
        expiryTask?.cancel()
    }

    public func snapshot() -> KeepAwakeStatus {
        status
    }

    public func start(
        duration: TimeInterval?,
        preventDisplaySleep: Bool = true,
        clamshell: Bool = false
    ) async throws {
        let keepClamshell = clamshell || status.clamshell
        stopActiveSession()

        status = KeepAwakeStatus(
            active: true,
            startedAt: Date(),
            endsAt: duration.map { Date().addingTimeInterval($0) },
            displaySleepPrevented: preventDisplaySleep,
            clamshell: keepClamshell
        )
        createAssertions()
        installObservers()
        startTimer()
        scheduleExpiry()

        if keepClamshell {
            do {
                try await ensureClamshell()
            } catch {
                stopActiveSession()
                status.clamshell = false
                throw error
            }
        }
    }

    public func stop() async {
        stopActiveSession()
        await clamshellGuard.disable()
        status = KeepAwakeStatus()
    }

    /// Clamshell is its own toggle. It can be armed while idle keep-awake is
    /// off, and starting a timer preserves it.
    /// Toggles idle/display keep-awake without touching clamshell. Settings
    /// uses this so its two switches are independent.
    public func setKeepAwake(_ enabled: Bool) async throws {
        if enabled {
            if !status.active {
                try await start(duration: nil)
            }
        } else {
            stopActiveSession()
        }
    }

    public func setClamshell(_ enabled: Bool) async throws {
        if enabled {
            try await ensureClamshell()
        } else {
            await clamshellGuard.disable()
            status.clamshell = false
            releaseClamshellAssertion()
        }
    }

    private func ensureClamshell() async throws {
        // A leftover flag from a crashed run must not pass as "already on":
        // without a live guard the lid still sleeps.
        if !(await clamshellGuard.isArmed()) {
            try await clamshellGuard.enable()
        }
        status.clamshell = true
        releaseClamshellAssertion()
        createClamshellAssertion()
        // Keep checking while clamshell is on, even without a keep-awake timer.
        if timer == nil {
            startTimer()
        }
    }

    public func toggleDisplaySleep() {
        guard status.active else { return }
        status.displaySleepPrevented.toggle()
        releaseKeepAwakeAssertions()
        createKeepAwakeAssertions()
    }

    // MARK: - Assertions

    private func createAssertions() {
        createKeepAwakeAssertions()
        if status.clamshell {
            createClamshellAssertion()
        }
    }

    private func createKeepAwakeAssertions() {
        guard assertionsEnabled else { return }
        systemAssertion = Self.createAssertion(
            type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            reason: "Palette is keeping your Mac awake"
        )
        if status.displaySleepPrevented {
            displayAssertion = Self.createAssertion(
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                reason: "Palette is keeping your display awake"
            )
        }
    }

    private func createClamshellAssertion() {
        guard assertionsEnabled, status.clamshell else { return }
        clamshellAssertion = Self.createAssertion(
            type: kIOPMAssertionTypePreventSystemSleep as CFString,
            reason: "Palette clamshell mode"
        )
    }

    private func releaseKeepAwakeAssertions() {
        for assertion in [systemAssertion, displayAssertion] where assertion != 0 {
            IOPMAssertionRelease(assertion)
        }
        systemAssertion = 0
        displayAssertion = 0
    }

    private func releaseClamshellAssertion() {
        if clamshellAssertion != 0 {
            IOPMAssertionRelease(clamshellAssertion)
            clamshellAssertion = 0
        }
    }

    private func releaseAssertions() {
        releaseKeepAwakeAssertions()
        releaseClamshellAssertion()
    }

    private func stopActiveSession() {
        timer?.cancel()
        timer = nil
        expiryTask?.cancel()
        expiryTask = nil
        removeObservers()
        releaseAssertions()
        status.active = false
        status.startedAt = nil
        status.endsAt = nil
    }

    private static func createAssertion(type: CFString, reason: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : 0
    }

    // MARK: - Lifecycle

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + timerInterval, repeating: timerInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() async {
        if status.clamshell, !(await clamshellGuard.isArmed()) {
            // The guard died, so the lid sleeps again. Say so instead of
            // leaving the UI claiming clamshell mode is on.
            Log.shared.error("Clamshell: guard is no longer armed; lid sleep is back on", source: "awake")
            status.clamshell = false
            releaseClamshellAssertion()
            NotificationCenter.default.post(name: .paletteClamshellDropped, object: nil)
        }
        guard status.active else { return }
        if let endsAt = status.endsAt, Date() >= endsAt {
            await stop()
            return
        }
        // Recreate the assertions after wake/display changes. The root
        // clamshell guard re-checks AC power on its own loop.
        releaseAssertions()
        createAssertions()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let endsAt = status.endsAt else { return }
        expiryTask = Task { [weak self] in
            let delay = max(0, endsAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopIfExpired()
        }
    }

    private func stopIfExpired() async {
        guard status.active, let endsAt = status.endsAt, Date() >= endsAt else { return }
        await stop()
    }

    private func installObservers() {
        removeObservers()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { await self?.tick() }
            })
        }
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for token in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
    }
}

/// The root clamshell guard. `pmset -a disablesleep` is the only documented
/// switch that overrides lid-close sleep. It is enabled only while the flag
/// exists, on AC power, and Palette is still running; it restores normal sleep
/// when any of those stops being true.
public actor ClamshellGuard: ClamshellControlling {
    public enum GuardError: LocalizedError {
        case cancelled
        case failed(String)
        case notEnabled
        case guardStopped

        public var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Clamshell mode needs administrator approval."
            case .failed(let message):
                return message.isEmpty ? "Could not enable clamshell mode." : message
            case .notEnabled:
                return "Clamshell mode did not turn on. The log has the pmset output; try again."
            case .guardStopped:
                return "Clamshell mode turned on but stopped immediately, so the lid will still sleep. Try again from Settings."
            }
        }
    }

    private let flagURL: URL
    private let verifyEnabled: Bool

    public init(flagURL: URL? = nil, verifyEnabled: Bool = true) {
        self.flagURL = flagURL ?? PalettePaths.resolve().stateDir.appendingPathComponent("clamshell.active")
        self.verifyEnabled = verifyEnabled
    }

    public func isEnabled() async -> Bool {
        FileManager.default.fileExists(atPath: flagURL.path)
    }

    public func isArmed() async -> Bool {
        guard FileManager.default.fileExists(atPath: flagURL.path) else { return false }
        guard (try? await onACPower()) == true else { return true }
        return (try? await sleepIsDisabled()) == true
    }

    public func enable() async throws {
        try FileManager.default.createDirectory(
            at: flagURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: flagURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: flagURL.path)

        // The guard has to outlive the authorisation prompt, so a root
        // LaunchDaemon owns it. A backgrounded shell from `do shell script`
        // is torn down with the session, which is why the old approach armed
        // nothing once the password dialog closed.
        let install = Self.installCommand(pid: getpid(), flagPath: flagURL.path)
        let appleScript = "do shell script \(Self.appleScriptQuote(install)) with administrator privileges"

        Log.shared.info("Clamshell: installing the root guard daemon", source: "awake")
        let result = try await ProcessRunner.run(
            ["/usr/bin/osascript", "-e", appleScript],
            timeout: 120
        )
        Log.shared.info("Clamshell: authorisation finished with status \(result.status)", source: "awake")
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: flagURL)
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            // The dialog only says "cancelled"; a non-zero status after the
            // user authenticated is a launchctl failure, so keep its words.
            Log.shared.error(
                "Clamshell: the daemon install failed\(message.isEmpty ? "" : ": \(message)")",
                source: "awake"
            )
            if message.localizedCaseInsensitiveContains("cancel") || message.localizedCaseInsensitiveContains("user canceled") {
                throw GuardError.cancelled
            }
            throw GuardError.failed(message)
        }

        guard verifyEnabled else { return }
        var armed = false
        for _ in 0..<40 {
            if try await sleepIsDisabled() { armed = true; break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        // Battery power intentionally leaves SleepDisabled off. The guard is
        // still armed and will enable it as soon as AC returns.
        if !armed {
            if !(try await onACPower()) { return }
            let state = (try? await ProcessRunner.run(["/usr/bin/pmset", "-g"], timeout: 10))?.stdoutString ?? ""
            Log.shared.error("Clamshell: SleepDisabled did not turn on. pmset said: \(state)", source: "awake")
            try? FileManager.default.removeItem(at: flagURL)
            throw GuardError.notEnabled
        }
        // A guard that dies right after arming leaves the flag behind but lets
        // the lid sleep again, so check it is still armed a few seconds later.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        if try await onACPower(), !(try await sleepIsDisabled()) {
            Log.shared.error("Clamshell: the guard stopped after arming; lid sleep is back on", source: "awake")
            try? FileManager.default.removeItem(at: flagURL)
            throw GuardError.guardStopped
        }
    }

    /// Idempotent root install: writes the guard and its LaunchDaemon, then
    /// loads it. Payloads are base64 so quoting survives every layer.
    public static func installCommand(pid: Int32, flagPath: String) -> String {
        let script = helperScript(pid: pid, flagPath: flagPath, cleanUpPlist: true)
        let plist = daemonPlist()
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let plistB64 = Data(plist.utf8).base64EncodedString()
        let scriptPath = shellQuote(daemonScriptPath)
        let plistPath = shellQuote(daemonPlistPath)
        let label = daemonLabel
        return """
        /bin/mkdir -p /Library/LaunchDaemons \(shellQuote(daemonDirectory)) && \
        /usr/bin/printf '%s' \(shellQuote(scriptB64)) | /usr/bin/base64 -D > \(scriptPath) && \
        /usr/bin/printf '%s' \(shellQuote(plistB64)) | /usr/bin/base64 -D > \(plistPath) && \
        /bin/chmod 755 \(scriptPath) && /bin/chmod 644 \(plistPath) && \
        /usr/sbin/chown root:wheel \(scriptPath) \(plistPath) && \
        (/bin/launchctl bootout system/\(label) 2>/dev/null || true) && \
        /bin/launchctl bootstrap system \(plistPath)
        """
    }

    public static let daemonLabel = "dev.myleshen.palette.clamshell"
    static let daemonDirectory = "/Library/Application Support/Palette"
    static let daemonScriptPath = daemonDirectory + "/clamshell-guard.sh"
    public static let daemonPlistPath = "/Library/LaunchDaemons/" + daemonLabel + ".plist"

    public static func daemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Label</key><string>\(daemonLabel)</string>
        <key>ProgramArguments</key>
        <array><string>/bin/sh</string><string>\(daemonScriptPath)</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><false/>
        <key>ProcessType</key><string>Background</string>
        </dict>
        </plist>
        """
    }

    public func disable() async {
        Log.shared.info("Clamshell: disarming the root guard", source: "awake")
        try? FileManager.default.removeItem(at: flagURL)
        // The guard normally removes its own job; bootout is a defensive
        // second try for a deleted plist that launchd still remembers. It
        // legitimately fails without root and is not fatal.
        _ = try? await ProcessRunner.run(
            ["/bin/launchctl", "bootout", "system/\(Self.daemonLabel)"],
            timeout: 5
        )
        // The root loop notices the missing flag within three seconds and
        // restores normal sleep. Wait briefly so "off" is not just cosmetic.
        for _ in 0..<10 {
            if (try? await sleepIsDisabled()) != true { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    public nonisolated static func clearFlag() {
        let url = PalettePaths.resolve().stateDir.appendingPathComponent("clamshell.active")
        try? FileManager.default.removeItem(at: url)
    }

    private func sleepIsDisabled() async throws -> Bool {
        let result = try await ProcessRunner.run(["/usr/bin/pmset", "-g"], timeout: 10)
        return result.stdoutString.contains("SleepDisabled")
            && result.stdoutString.split(separator: "\n").contains { $0.contains("SleepDisabled") && $0.contains("1") }
    }

    /// The loop is kept in one place so tests can exercise the AC/flag
    /// transitions with a fake `pmset` without needing root.
    public static func helperScript(
        pid: Int32,
        flagPath: String,
        pmset: String = "/usr/bin/pmset",
        sleepBinary: String = "/bin/sleep",
        interval: Int = 3,
        cleanUpPlist: Bool = false
    ) -> String {
        let flag = shellQuote(flagPath)
        let tool = shellQuote(pmset)
        let sleeper = shellQuote(sleepBinary)
        // Written by root so a guard that dies right after arming is visible
        // instead of looking like a silent success.
        let log = shellQuote("/tmp/palette-clamshell-guard.log")
        // The guard runs as root, so it can remove what it owns: its script,
        // its plist and the log it has been growing.
        let cleanUp = cleanUpPlist
            ? """
              /bin/rm -f \(shellQuote(daemonScriptPath)) \(shellQuote(daemonPlistPath))
              """
            : ""
        return """
        exec >>\(log) 2>&1
        note() { echo "$(date '+%F %T') [\(pid)] $1"; }
        cleanup() {
          \(tool) -a disablesleep 0 >/dev/null 2>&1
          note "guard stopping"
          exec >/dev/null 2>&1
          : > \(log)
          \(cleanUp)
        }
        trap cleanup EXIT
        trap 'exit 0' INT TERM HUP
        note "guard started"
        was=""
        while /bin/kill -0 \(pid) 2>/dev/null && [ -f \(flag) ]; do
          if \(tool) -g ps | /usr/bin/grep -q "AC Power"; then
            \(tool) -a disablesleep 1 >/dev/null 2>&1
            now="armed"
          else
            \(tool) -a disablesleep 0 >/dev/null 2>&1
            now="battery"
          fi
          if [ "$now" != "$was" ]; then note "state $now"; was="$now"; fi
          \(sleeper) \(interval)
        done
        note "guard exiting (palette gone or flag removed)"
        exit 0
        """
    }

    private func onACPower() async throws -> Bool {
        let result = try await ProcessRunner.run(["/usr/bin/pmset", "-g", "ps"], timeout: 10)
        return result.stdoutString.contains("AC Power")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
