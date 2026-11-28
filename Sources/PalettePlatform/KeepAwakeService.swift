import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import PaletteCore

extension Notification.Name {
    /// Posted when the root clamshell guard stops being armed.
    public static let paletteClamshellDropped = Notification.Name("palette.clamshell.dropped")
}

public enum KeepAwakeError: LocalizedError {
    case couldNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotStart(let message):
            return message.isEmpty ? "Could not start keep-awake." : message
        }
    }
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
        clamshellRequiresPower: Bool = false
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
    /// True only when the flag exists *and* the system reports sleep disabled.
    func isArmed() async -> Bool
    func enable() async throws
    func disable() async
}

/// Keeps the Mac awake with a detached `caffeinate` child, so the session
/// outlives Palette, and restores that session on the next launch. Clamshell
/// mode additionally uses a short-lived root guard, because macOS treats a lid
/// close as forced sleep and user-space assertions cannot override it.
public actor KeepAwakeService {
    /// The child is detached on purpose: quitting Palette must not end the
    /// session. Settings and the menu read the restored snapshot instead.
    private struct PersistedSession: Codable {
        var pid: Int32
        var startedAt: Date
        var endsAt: Date?
        var preventDisplaySleep: Bool
    }

    private let assertionsEnabled: Bool
    private let clamshellGuard: any ClamshellControlling
    private let timerInterval: TimeInterval
    private let stateFile: URL
    private let caffeinatePath: String
    private var clamshellAssertion: IOPMAssertionID = 0
    private var caffeinate: Process?
    private var sessionPID: Int32?
    private var timer: DispatchSourceTimer?
    private var status = KeepAwakeStatus()
    private var observerTokens: [NSObjectProtocol] = []
    private var expiryTask: Task<Void, Never>?

    public init(
        assertionsEnabled: Bool = true,
        clamshellGuard: any ClamshellControlling = ClamshellGuard(),
        timerInterval: TimeInterval = 30,
        stateDir: URL? = nil,
        caffeinatePath: String = "/usr/bin/caffeinate"
    ) {
        self.assertionsEnabled = assertionsEnabled
        self.clamshellGuard = clamshellGuard
        self.timerInterval = max(0.1, timerInterval)
        let directory = stateDir ?? PalettePaths.resolve().stateDir
        self.stateFile = directory.appendingPathComponent("keepawake.json")
        self.caffeinatePath = caffeinatePath
    }

    deinit {
        timer?.cancel()
        expiryTask?.cancel()
        // Deliberately no terminate: the caffeinate child is the point.
    }

    public func snapshot() -> KeepAwakeStatus {
        status
    }

    /// Restores what an earlier run left behind: an adopted caffeinate session
    /// and an armed clamshell guard. Call once at launch.
    public func restore() async {
        adoptSession()
        await adoptClamshell()
        scheduleExpiry()
        refreshTicker()
    }

    public func start(
        duration: TimeInterval?,
        preventDisplaySleep: Bool = true,
        clamshell: Bool = false
    ) async throws {
        let keepClamshell = clamshell || status.clamshell
        let clamshellInactive = status.clamshellRequiresPower
        stopActiveSession()

        let now = Date()
        status = KeepAwakeStatus(
            active: true,
            startedAt: now,
            endsAt: duration.map { now.addingTimeInterval($0) },
            displaySleepPrevented: preventDisplaySleep,
            clamshell: keepClamshell,
            clamshellRequiresPower: keepClamshell && clamshellInactive
        )
        do {
            try launchSession()
        } catch {
            status.active = false
            status.startedAt = nil
            status.endsAt = nil
            throw error
        }
        refreshTicker()
        scheduleExpiry()

        if keepClamshell {
            do {
                try await ensureClamshell()
            } catch {
                stopActiveSession()
                status.clamshell = false
                status.clamshellRequiresPower = false
                refreshTicker()
                throw error
            }
        }
    }

    public func stop() async {
        stopActiveSession()
        await clamshellGuard.disable()
        status = KeepAwakeStatus()
        refreshTicker()
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
            status.clamshellRequiresPower = false
            releaseClamshellAssertion()
            refreshTicker()
        }
    }

    private func ensureClamshell() async throws {
        // A leftover flag from a crashed run must not pass as "already on":
        // without a live guard the lid still sleeps.
        if !(await clamshellGuard.isArmed()) {
            try await clamshellGuard.enable()
        }
        status.clamshell = true
        status.clamshellRequiresPower = !(await clamshellGuard.isArmed())
        releaseClamshellAssertion()
        createClamshellAssertion()
        // Keep checking while clamshell is on, even without a keep-awake timer.
        refreshTicker()
    }

    public func toggleDisplaySleep() {
        guard status.active else { return }
        status.displaySleepPrevented.toggle()
        terminateSession()
        do {
            try launchSession()
        } catch {
            Log.shared.error("Keep awake: could not restart caffeinate: \(error.localizedDescription)", source: "awake")
            stopActiveSession()
        }
    }

    // MARK: - Session

    private func launchSession() throws {
        guard assertionsEnabled else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: caffeinatePath)
        var arguments = ["-i", "-m", "-s"]
        if status.displaySleepPrevented {
            arguments.insert("-d", at: 0)
        }
        if let endsAt = status.endsAt {
            // Let caffeinate expire on its own even when Palette is closed.
            arguments += ["-t", "\(max(1, Int(endsAt.timeIntervalSinceNow.rounded(.up))))"]
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw KeepAwakeError.couldNotStart(error.localizedDescription)
        }
        caffeinate = process
        sessionPID = process.processIdentifier
        persistSession(pid: process.processIdentifier)
    }

    private func adoptSession() {
        guard !status.active, sessionPID == nil else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateFile) else { return }
        guard let session = try? decoder.decode(PersistedSession.self, from: data) else {
            Log.shared.warn("Keep awake: ignoring a malformed state file", source: "awake")
            try? FileManager.default.removeItem(at: stateFile)
            return
        }
        let now = Date()
        if let endsAt = session.endsAt, endsAt <= now {
            Log.shared.info("Keep awake: the previous timed session already ended", source: "awake")
            try? FileManager.default.removeItem(at: stateFile)
            return
        }
        guard session.pid > 0,
              isProcessAlive(session.pid),
              isOurCaffeinate(session.pid) else {
            Log.shared.info("Keep awake: the previous caffeinate process is gone", source: "awake")
            try? FileManager.default.removeItem(at: stateFile)
            return
        }
        status.active = true
        status.startedAt = session.startedAt
        status.endsAt = session.endsAt
        status.displaySleepPrevented = session.preventDisplaySleep
        sessionPID = session.pid
        Log.shared.info("Keep awake: restored a running session", source: "awake")
    }

    private func persistSession(pid: Int32) {
        let session = PersistedSession(
            pid: pid,
            startedAt: status.startedAt ?? Date(),
            endsAt: status.endsAt,
            preventDisplaySleep: status.displaySleepPrevented
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(session).write(to: stateFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
        } catch {
            Log.shared.error("Keep awake: could not save the session state: \(error.localizedDescription)", source: "awake")
        }
    }

    /// Kills the recorded child only when the pid really is our caffeinate.
    /// A stale pid can belong to any process, and Stop must never kill it.
    private func terminateSession() {
        if let pid = sessionPID ?? persistedPID(), isOurCaffeinate(pid) {
            kill(pid, SIGTERM)
        }
        caffeinate = nil
        sessionPID = nil
        try? FileManager.default.removeItem(at: stateFile)
    }

    private func persistedPID() -> Int32? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateFile),
              let session = try? decoder.decode(PersistedSession.self, from: data) else { return nil }
        return session.pid
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    private func isOurCaffeinate(_ pid: Int32) -> Bool {
        guard isProcessAlive(pid) else { return false }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: caffeinatePath).resolvingSymlinksInPath().path
    }

    private func adoptClamshell() async {
        let armed = await clamshellGuard.isArmed()
        if armed {
            status.clamshell = true
            status.clamshellRequiresPower = false
            createClamshellAssertion()
            return
        }
        // The flag can survive a quit or a crash, so an off toggle would hide
        // a setting the user still has on. Say it is armed but inactive.
        if await clamshellGuard.isEnabled() {
            status.clamshell = true
            status.clamshellRequiresPower = true
            releaseClamshellAssertion()
        } else {
            status.clamshell = false
            status.clamshellRequiresPower = false
        }
    }

    // MARK: - Assertions

    private func createClamshellAssertion() {
        guard assertionsEnabled, status.clamshell else { return }
        clamshellAssertion = Self.createAssertion(
            type: kIOPMAssertionTypePreventSystemSleep as CFString,
            reason: "Palette clamshell mode"
        )
    }

    private func releaseClamshellAssertion() {
        if clamshellAssertion != 0 {
            IOPMAssertionRelease(clamshellAssertion)
            clamshellAssertion = 0
        }
    }

    private func stopActiveSession() {
        expiryTask?.cancel()
        expiryTask = nil
        terminateSession()
        status.active = false
        status.startedAt = nil
        status.endsAt = nil
        refreshTicker()
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

    private func refreshTicker() {
        if status.active || status.clamshell {
            if timer == nil {
                startTimer()
            }
            installObservers()
        } else {
            timer?.cancel()
            timer = nil
            removeObservers()
        }
    }

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
        if status.clamshell {
            let armed = await clamshellGuard.isArmed()
            if armed {
                status.clamshellRequiresPower = false
                if clamshellAssertion == 0 {
                    createClamshellAssertion()
                }
            } else if await clamshellGuard.isEnabled() {
                status.clamshellRequiresPower = true
                releaseClamshellAssertion()
            } else {
                // The guard died and its flag is gone, so the lid sleeps again.
                Log.shared.error("Clamshell: guard is no longer armed; lid sleep is back on", source: "awake")
                status.clamshell = false
                status.clamshellRequiresPower = false
                releaseClamshellAssertion()
                refreshTicker()
                NotificationCenter.default.post(name: .paletteClamshellDropped, object: nil)
            }
        }
        guard status.active else { return }
        if let endsAt = status.endsAt, Date() >= endsAt {
            // Expiry ends this session only; clamshell is its own toggle.
            stopActiveSession()
            return
        }
        // The child can be killed from outside. Do not keep claiming it runs.
        if let pid = sessionPID, !isOurCaffeinate(pid) {
            stopActiveSession()
        }
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
        // Expiry is not Stop All: leave the clamshell guard armed.
        stopActiveSession()
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
/// exists and the Mac is on AC power; it disarms on battery, when the flag is
/// removed, or at the 12-hour cap, and never outlives the flag.
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
        // Sleep is only really disabled when pmset says so. On battery the
        // guard is armed but the lid still sleeps, so report that honestly.
        guard FileManager.default.fileExists(atPath: flagURL.path) else { return false }
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
        let install = Self.installCommand(flagPath: flagURL.path)
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
        // Battery power intentionally leaves SleepDisabled off. The guard
        // exits on battery and launchd rechecks every 30 seconds, so plugging
        // AC back in re-arms it without another password prompt.
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
    public static func installCommand(flagPath: String) -> String {
        let script = helperScript(flagPath: flagPath, cleanUpPlist: true)
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
    static let daemonLogDirectory = "/Library/Logs/Palette"
    public static let daemonLogPath = daemonLogDirectory + "/clamshell-guard.log"
    public static let daemonPlistPath = "/Library/LaunchDaemons/" + daemonLabel + ".plist"
    /// A forgotten clamshell must not keep a laptop awake forever.
    public static let maxArmedDuration: TimeInterval = 12 * 60 * 60

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
        <key>StartInterval</key><integer>30</integer>
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
        // If the daemon had exited on battery, the loaded job starts again
        // within 30 seconds and removes itself on the same flag check.
        for _ in 0..<10 {
            if (try? await sleepIsDisabled()) != true { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func sleepIsDisabled() async throws -> Bool {
        let result = try await ProcessRunner.run(["/usr/bin/pmset", "-g"], timeout: 10)
        return result.stdoutString.contains("SleepDisabled")
            && result.stdoutString.split(separator: "\n").contains { $0.contains("SleepDisabled") && $0.contains("1") }
    }

    /// The loop is kept in one place so tests can exercise the AC/flag
    /// transitions with a fake `pmset` without needing root.
    ///
    /// Lifecycle: while the flag exists and AC power is on, keep
    /// `disablesleep` set. On battery, disarm and exit; launchd's
    /// `StartInterval` starts it again so AC returning re-arms it. When the
    /// flag disappears or the 12-hour cap fires, disarm, remove the plist and
    /// boot the job out for good. The EXIT trap is the last line of defence
    /// against a dead daemon leaving sleep disabled.
    public static func helperScript(
        flagPath: String,
        pmset: String = "/usr/bin/pmset",
        sleepBinary: String = "/bin/sleep",
        interval: Int = 3,
        maxArmedSeconds: Int = 12 * 60 * 60,
        logPath: String = daemonLogPath,
        cleanUpPlist: Bool = false
    ) -> String {
        let flag = shellQuote(flagPath)
        let tool = shellQuote(pmset)
        let sleeper = shellQuote(sleepBinary)
        let cleanup = cleanUpPlist
            ? """
              /bin/rm -f \(shellQuote(daemonScriptPath)) \(shellQuote(daemonPlistPath))
              /bin/launchctl bootout system/\(daemonLabel) >/dev/null 2>&1 || true
              """
            : ""
        // Written by root in the system log directory so a guard that dies right
        // after arming is visible instead of looking like a silent success, and
        // a local user cannot pre-create or read it through /tmp.
        let log = shellQuote(logPath)
        let logDirectory = shellQuote((logPath as NSString).deletingLastPathComponent)
        return """
        /bin/mkdir -p \(logDirectory)
        : > \(log)
        /bin/chmod 0600 \(log)
        exec >>\(log) 2>&1
        note() { echo "$(/bin/date '+%F %T') [guard] $1"; }
        disarm() { \(tool) -a disablesleep 0 >/dev/null 2>&1; }
        cleanup() {
          disarm
        \(cleanup)
        }
        finish() {
          trap - EXIT INT TERM HUP
          note "$1"
          cleanup
          exit 0
        }
        onBattery() {
          trap - EXIT INT TERM HUP
          disarm
          note "$1"
          exit 0
        }
        trap 'disarm; note "guard stopped (trap)"; exit 0' EXIT INT TERM HUP
        note "guard started"
        was=""
        while [ -f \(flag) ]; do
          if ! \(tool) -g ps | /usr/bin/grep -q "AC Power"; then
            onBattery "battery power; lid sleep restored (launchd will recheck)"
          fi
          armed_at=$(/usr/bin/stat -f %m \(flag) 2>/dev/null || echo 0)
          now=$(/bin/date +%s)
          if [ "$armed_at" -gt 0 ] && [ $((now - armed_at)) -ge \(maxArmedSeconds) ]; then
            /bin/rm -f \(flag)
            finish "12h cap reached; clamshell disarmed and flag removed"
          fi
          \(tool) -a disablesleep 1 >/dev/null 2>&1
          if [ "$was" != "armed" ]; then note "state armed"; was="armed"; fi
          \(sleeper) \(interval)
        done
        finish "flag removed; lid sleep restored"
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
