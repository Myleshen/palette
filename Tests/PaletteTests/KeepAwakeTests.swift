import XCTest
import Foundation
import PaletteCore
import PalettePlatform
import PaletteProviders

private actor KeepAwakeBridge: HostBridge {
    private var notes: [String] = []

    func lastNotification() -> String? { notes.last }

    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? { nil }

    func notify(_ message: String) async {
        notes.append(message)
    }

    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {}
}

private actor FakeClamshell: ClamshellControlling {
    private var armed = false
    private var staleFlag = false
    private(set) var enableCount = 0
    private(set) var disableCount = 0

    func setStaleFlag() { staleFlag = true }
    func isEnabled() async -> Bool { armed || staleFlag }
    func isArmed() async -> Bool { armed }
    func enable() async throws { armed = true; staleFlag = false; enableCount += 1 }
    func disable() async { armed = false; staleFlag = false; disableCount += 1 }
}

private struct SessionFixture: Encodable {
    var pid: Int32
    var startedAt: Date
    var endsAt: Date?
    var preventDisplaySleep: Bool
}

final class KeepAwakeTests: XCTestCase {
    private func makeGuard() -> ClamshellGuard {
        let flag = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-clamshell-\(UUID().uuidString).active")
        return ClamshellGuard(flagURL: flag, verifyEnabled: false)
    }

    private func makeStateDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-awake-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func sessionFile(in dir: URL) -> URL {
        dir.appendingPathComponent("keepawake.json")
    }

    private func writeSession(
        to dir: URL,
        pid: Int32,
        startedAt: Date = Date(),
        endsAt: Date?,
        preventDisplaySleep: Bool = true
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = SessionFixture(
            pid: pid,
            startedAt: startedAt,
            endsAt: endsAt,
            preventDisplaySleep: preventDisplaySleep
        )
        try encoder.encode(session).write(to: sessionFile(in: dir), options: .atomic)
    }

    private func startCaffeinate(seconds: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-t", "\(seconds)"]
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
        }
        return process
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(process.isRunning, "the child should have exited")
    }

    func testStartAndStopWithAssertionsDisabled() async throws {
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: makeGuard(),
            timerInterval: 0.1,
            stateDir: makeStateDir()
        )
        try await service.start(duration: nil)
        var status = await service.snapshot()
        XCTAssertTrue(status.active)
        XCTAssertNil(status.endsAt)

        await service.stop()
        status = await service.snapshot()
        XCTAssertFalse(status.active)
    }

    func testTimedSessionExpires() async throws {
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: makeGuard(),
            timerInterval: 0.05,
            stateDir: makeStateDir()
        )
        try await service.start(duration: 0.25)
        let active = await service.snapshot()
        XCTAssertTrue(active.active)
        XCTAssertNotNil(active.endsAt)

        try await Task.sleep(nanoseconds: 700_000_000)
        let stopped = await service.snapshot()
        XCTAssertFalse(stopped.active)
    }

    func testProviderRowsAndStartAction() async throws {
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: makeGuard(),
            stateDir: makeStateDir()
        )
        let bridge = KeepAwakeBridge()
        let launcher = await MainActor.run { LauncherService() }
        let provider = KeepAwakeProvider(service: service, bridge: bridge, launcher: launcher)

        let rows = try await provider.search(SearchRequest(text: "", limit: 50, isBound: true))
        XCTAssertTrue(rows.contains { $0.title == "Keep Mac Awake" })
        XCTAssertTrue(rows.contains { $0.title.contains("Clamshell Mode") })
        XCTAssertTrue(rows.contains { $0.title.contains("15 minutes") })

        let start = try XCTUnwrap(rows.first { $0.id == "status" })
        let action = try XCTUnwrap(start.actions.first)
        try await provider.activate(start, action: action)

        var status = await service.snapshot()
        XCTAssertTrue(status.active)
        XCTAssertNil(status.endsAt)
        let note = await bridge.lastNotification()
        XCTAssertEqual(note, "Keeping your Mac awake until you stop it")

        await service.stop()
        status = await service.snapshot()
        XCTAssertFalse(status.active)
    }

    func testClamshellDaemonInstallCommand() throws {
        let command = ClamshellGuard.installCommand(flagPath: "/tmp/clamshell flag.active")
        XCTAssertTrue(command.contains(ClamshellGuard.daemonLabel))
        XCTAssertTrue(command.contains("/bin/launchctl bootstrap system"))
        XCTAssertTrue(command.contains(ClamshellGuard.daemonPlistPath))
        XCTAssertFalse(command.contains("\\("), "no unexpanded interpolation should survive")

        let plist = ClamshellGuard.daemonPlist()
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key><true/>"))
        XCTAssertTrue(plist.contains("<key>StartInterval</key><integer>30</integer>"))
        XCTAssertTrue(plist.contains(ClamshellGuard.daemonLabel))
        // The plist must be valid property list data, or launchd rejects it.
        let data = try XCTUnwrap(plist.data(using: .utf8))
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(parsed?["Label"] as? String, ClamshellGuard.daemonLabel)
        XCTAssertEqual(parsed?["StartInterval"] as? Int, 30)
        XCTAssertEqual((parsed?["ProgramArguments"] as? [String])?.first, "/bin/sh")

        // The guard watches the flag and power, not Palette's pid.
        let script = ClamshellGuard.helperScript(flagPath: "/tmp/clamshell flag.active", cleanUpPlist: true)
        XCTAssertFalse(script.contains("kill -0"), "the daemon must outlive Palette")
        XCTAssertTrue(script.contains("/tmp/clamshell flag.active"))
        XCTAssertTrue(script.contains("stat -f %m"), "the cap reads the flag's age")
        XCTAssertTrue(script.contains("12h cap reached"))
        XCTAssertTrue(script.contains("battery power; lid sleep restored"))
        XCTAssertTrue(script.contains(ClamshellGuard.daemonLabel), "the guard removes its own plist on exit")
        XCTAssertTrue(script.contains("/Library/Logs/Palette/clamshell-guard.log"))
        XCTAssertTrue(script.contains("/bin/chmod 0600"))
        XCTAssertFalse(script.contains("/tmp/palette-clamshell-guard.log"))
    }

    func testClamshellInstallCommandParsesAsShell() async throws {
        let command = ClamshellGuard.installCommand(flagPath: "/tmp/clamshell.active")
        // `sh -n` parses without executing, so this catches quoting breaks in
        // the root command before it ever reaches the password prompt.
        let result = try await ProcessRunner.run(["/bin/sh", "-n", "-c", command], timeout: 10)
        XCTAssertEqual(result.status, 0, "install command must parse: \(result.stderrString)")
    }

    /// Every tool the root command calls must exist at the path it names.
    /// `sh -n` cannot catch this: `/bin/chown` parses fine and fails at run
    /// time with status 127, after the user has already typed a password.
    func testClamshellToolsExistAtTheirPaths() throws {
        let sources = [
            ClamshellGuard.installCommand(flagPath: "/tmp/clamshell.active"),
            ClamshellGuard.helperScript(flagPath: "/tmp/clamshell.active"),
        ]
        let pattern = try NSRegularExpression(pattern: "/(?:usr/)?s?bin/[A-Za-z0-9_.-]+")
        for source in sources {
            let text = source as NSString
            for match in pattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                let path = text.substring(with: match.range)
                XCTAssertTrue(FileManager.default.fileExists(atPath: path), "missing tool: \(path)")
            }
        }
    }

    func testStaleClamshellFlagRearmsTheGuard() async throws {
        let fake = FakeClamshell()
        await fake.setStaleFlag()
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: fake,
            stateDir: makeStateDir()
        )

        // The flag exists from an earlier run but nothing is armed, so the
        // guard must be started again rather than trusted.
        try await service.setClamshell(true)
        let count = await fake.enableCount
        XCTAssertEqual(count, 1, "a stale flag must not be trusted")
    }

    func testClamshellToggleIsIndependentOfKeepAwake() async throws {
        let fake = FakeClamshell()
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: fake,
            stateDir: makeStateDir()
        )

        try await service.setClamshell(true)
        var status = await service.snapshot()
        XCTAssertTrue(status.clamshell)
        XCTAssertFalse(status.active)
        let armed = await fake.isEnabled()
        XCTAssertTrue(armed)

        try await service.start(duration: 60)
        status = await service.snapshot()
        XCTAssertTrue(status.active)
        XCTAssertTrue(status.clamshell, "Starting a timer should preserve clamshell")

        try await service.setClamshell(false)
        status = await service.snapshot()
        XCTAssertFalse(status.clamshell)
        XCTAssertTrue(status.active, "Turning clamshell off should leave the timer alone")
        let disarmed = await fake.isEnabled()
        XCTAssertFalse(disarmed)

        await service.stop()
        status = await service.snapshot()
        XCTAssertFalse(status.active)
        XCTAssertFalse(status.clamshell)
    }

    func testKeepAwakeToggleLeavesClamshellAlone() async throws {
        let fake = FakeClamshell()
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: fake,
            stateDir: makeStateDir()
        )

        try await service.setClamshell(true)
        try await service.setKeepAwake(true)
        var status = await service.snapshot()
        XCTAssertTrue(status.active)
        XCTAssertTrue(status.clamshell)

        try await service.setKeepAwake(false)
        status = await service.snapshot()
        XCTAssertFalse(status.active)
        XCTAssertTrue(status.clamshell)
        let stillArmed = await fake.isEnabled()
        XCTAssertTrue(stillArmed)

        try await service.setClamshell(false)
        status = await service.snapshot()
        XCTAssertFalse(status.clamshell)
        let disarmed = await fake.isEnabled()
        XCTAssertFalse(disarmed)
    }

    func testExpiredTimerLeavesClamshellAlone() async throws {
        let fake = FakeClamshell()
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: fake,
            timerInterval: 0.05,
            stateDir: makeStateDir()
        )
        try await service.setClamshell(true)
        try await service.start(duration: 0.25)
        var status = await service.snapshot()
        XCTAssertTrue(status.active, "the timer starts active")
        XCTAssertNotNil(status.endsAt, "the timer has a deadline")
        XCTAssertTrue(status.clamshell, "clamshell is armed alongside the timer")

        try await Task.sleep(nanoseconds: 700_000_000)
        status = await service.snapshot()
        XCTAssertFalse(status.active, "The timer alone should expire")
        XCTAssertNil(status.endsAt, "the deadline is cleared with the session")
        XCTAssertTrue(status.clamshell, "Expiry is not Stop All; clamshell stays armed")
        let stillArmed = await fake.isEnabled()
        XCTAssertTrue(stillArmed)
        let disables = await fake.disableCount
        XCTAssertEqual(disables, 0, "Expiry must not disarm the clamshell guard")
    }

    func testProviderClamshellActionTogglesWithoutStartingTimer() async throws {
        let fake = FakeClamshell()
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: fake,
            stateDir: makeStateDir()
        )
        let bridge = KeepAwakeBridge()
        let launcher = await MainActor.run { LauncherService() }
        let provider = KeepAwakeProvider(service: service, bridge: bridge, launcher: launcher)

        let rows = try await provider.search(SearchRequest(text: "", limit: 50, isBound: true))
        let clamshell = try XCTUnwrap(rows.first { $0.id == "clamshell" })
        let action = try XCTUnwrap(clamshell.actions.first)
        try await provider.activate(clamshell, action: action)

        var status = await service.snapshot()
        XCTAssertTrue(status.clamshell)
        XCTAssertFalse(status.active)

        let refreshed = try await provider.search(SearchRequest(text: "", limit: 50, isBound: true))
        XCTAssertEqual(refreshed.first { $0.id == "clamshell" }?.badge, "ON")
        XCTAssertTrue(refreshed.contains { $0.id == "stop" })

        try await provider.activate(clamshell, action: action)
        status = await service.snapshot()
        XCTAssertFalse(status.clamshell)
        XCTAssertFalse(status.active)
    }

    func testClamshellFlagIsRemovedOnDisable() async throws {
        let flag = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-clamshell-\(UUID().uuidString).active")
        defer { try? FileManager.default.removeItem(at: flag) }
        let guardService = ClamshellGuard(flagURL: flag, verifyEnabled: false)
        try Data().write(to: flag)
        let enabled = await guardService.isEnabled()
        XCTAssertTrue(enabled)
        await guardService.disable()
        let disabled = await guardService.isEnabled()
        XCTAssertFalse(disabled)
    }

    func testClamshellHelperFollowsPowerAndFlag() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-clamshell-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let flag = root.appendingPathComponent("active")
        let ac = root.appendingPathComponent("ac")
        let state = root.appendingPathComponent("state")
        let fakePmset = root.appendingPathComponent("pmset")
        let fakeSleep = root.appendingPathComponent("sleep")
        let manager = FileManager.default

        try """
        #!/bin/sh
        if [ "$1" = "-g" ] && [ "$2" = "ps" ]; then
          cat "$FAKE_AC"
          exit 0
        fi
        if [ "$1" = "-a" ] && [ "$2" = "disablesleep" ]; then
          printf '%s' "$3" > "$FAKE_STATE"
          exit 0
        fi
        exit 1
        """.write(to: fakePmset, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        /bin/sleep 0.05
        """.write(to: fakeSleep, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePmset.path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSleep.path)

        try "AC Power".write(to: ac, atomically: true, encoding: .utf8)
        try Data().write(to: flag)

        func startGuard(maxArmedSeconds: Int = 12 * 60 * 60) throws -> Process {
            let script = ClamshellGuard.helperScript(
                flagPath: flag.path,
                pmset: fakePmset.path,
                sleepBinary: fakeSleep.path,
                interval: 0,
                maxArmedSeconds: maxArmedSeconds,
                logPath: root.appendingPathComponent("guard.log").path
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = [
                "FAKE_AC": ac.path,
                "FAKE_STATE": state.path,
                "PATH": "/usr/bin:/bin",
            ]
            try process.run()
            return process
        }

        func stateValue() -> String {
            (try? String(contentsOf: state, encoding: .utf8)) ?? ""
        }

        func waitForState(_ value: String) async throws -> Bool {
            for _ in 0..<40 {
                if stateValue() == value { return true }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }

        var guardProcess = try startGuard()
        let armed = try await waitForState("1")
        XCTAssertTrue(armed, "AC power should arm lid-sleep prevention")
        XCTAssertTrue(guardProcess.isRunning)

        try "Battery Power".write(to: ac, atomically: true, encoding: .utf8)
        let disarmed = try await waitForState("0")
        XCTAssertTrue(disarmed, "Battery power should restore normal sleep")
        // The daemon exits on battery; launchd's StartInterval starts it again.
        try await waitForExit(guardProcess)

        try "AC Power".write(to: ac, atomically: true, encoding: .utf8)
        guardProcess = try startGuard()
        let rearmed = try await waitForState("1")
        XCTAssertTrue(rearmed, "A launchd restart should re-arm on AC")
        XCTAssertTrue(guardProcess.isRunning)

        try manager.removeItem(at: flag)
        let stopped = try await waitForState("0")
        XCTAssertTrue(stopped, "Removing the flag should restore normal sleep")
        try await waitForExit(guardProcess)

        // A killed daemon must not leave sleep disabled behind.
        try Data().write(to: flag)
        guardProcess = try startGuard()
        let armedAgain = try await waitForState("1")
        XCTAssertTrue(armedAgain)
        guardProcess.terminate()
        try await waitForExit(guardProcess)
        let trapDisarmed = try await waitForState("0")
        XCTAssertTrue(trapDisarmed, "The EXIT trap must disarm a killed guard")

        // The 12-hour cap (shortened here) disarms and removes the flag.
        try Data().write(to: flag)
        try manager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: flag.path
        )
        let capProcess = try startGuard(maxArmedSeconds: 1)
        try await waitForExit(capProcess)
        XCTAssertFalse(manager.fileExists(atPath: flag.path), "The cap must remove the flag")
        XCTAssertEqual(stateValue(), "0")
    }

    // MARK: - Session adoption

    func testRestoreAdoptsLiveCaffeinate() async throws {
        let dir = makeStateDir()
        let process = try startCaffeinate(seconds: 30)
        let endsAt = Date().addingTimeInterval(30)
        try writeSession(to: dir, pid: process.processIdentifier, endsAt: endsAt)

        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: FakeClamshell(),
            stateDir: dir
        )
        await service.restore()

        let status = await service.snapshot()
        XCTAssertTrue(status.active)
        XCTAssertTrue(status.displaySleepPrevented)
        XCTAssertEqual(try XCTUnwrap(status.endsAt).timeIntervalSince(endsAt), 0, accuracy: 1)

        await service.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(in: dir).path))
        try await waitForExit(process)
    }

    func testRestoreClearsADeadPid() async throws {
        let dir = makeStateDir()
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run()
        dead.waitUntilExit()
        try writeSession(to: dir, pid: dead.processIdentifier, endsAt: Date().addingTimeInterval(60))

        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: FakeClamshell(),
            stateDir: dir
        )
        await service.restore()

        let status = await service.snapshot()
        XCTAssertFalse(status.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(in: dir).path))
    }

    func testRestoreClearsAnExpiredDeadline() async throws {
        let dir = makeStateDir()
        // The pid is alive but is not caffeinate: the deadline must win.
        try writeSession(to: dir, pid: getpid(), endsAt: Date().addingTimeInterval(-1))

        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: FakeClamshell(),
            stateDir: dir
        )
        await service.restore()

        let status = await service.snapshot()
        XCTAssertFalse(status.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(in: dir).path))
    }

    func testRestoreIgnoresAMalformedFile() async throws {
        let dir = makeStateDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: sessionFile(in: dir))

        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: FakeClamshell(),
            stateDir: dir
        )
        await service.restore()

        let status = await service.snapshot()
        XCTAssertFalse(status.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(in: dir).path))
    }

    /// A recycled pid belongs to some other process; Stop must never kill it.
    func testRestoreIgnoresAPidThatIsNotCaffeinate() async throws {
        let dir = makeStateDir()
        try writeSession(to: dir, pid: getpid(), endsAt: Date().addingTimeInterval(60))

        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: FakeClamshell(),
            stateDir: dir
        )
        await service.restore()
        await service.stop()

        let status = await service.snapshot()
        XCTAssertFalse(status.active)
        XCTAssertEqual(kill(getpid(), 0), 0, "Stop must not signal a pid it did not start")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(in: dir).path))
    }

    func testStartPersistsTheCaffeinateSession() async throws {
        let dir = makeStateDir()
        let service = KeepAwakeService(
            assertionsEnabled: true,
            clamshellGuard: FakeClamshell(),
            stateDir: dir
        )
        try await service.start(duration: 60)

        let data = try Data(contentsOf: sessionFile(in: dir))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pid = try XCTUnwrap(object["pid"] as? Int)
        XCTAssertGreaterThan(pid, 0)
        XCTAssertNotNil(object["startedAt"] as? String)
        XCTAssertNotNil(object["endsAt"] as? String)
        XCTAssertEqual(object["preventDisplaySleep"] as? Bool, true)

        await service.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile(in: dir).path))
        var ticks = 0
        while kill(Int32(pid), 0) == 0, ticks < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            ticks += 1
        }
        XCTAssertNotEqual(kill(Int32(pid), 0), 0, "Stop must kill the recorded caffeinate")
    }

    func testAdoptedClamshellShowsArmedButInactive() async throws {
        let fake = FakeClamshell()
        await fake.setStaleFlag()
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: fake,
            stateDir: makeStateDir()
        )
        await service.restore()

        let status = await service.snapshot()
        XCTAssertTrue(status.clamshell)
        XCTAssertTrue(status.clamshellRequiresPower)
    }

    func testAdoptedArmedClamshellTurnsTheToggleOn() async throws {
        let fake = FakeClamshell()
        try await fake.enable()
        let service = KeepAwakeService(
            assertionsEnabled: false,
            clamshellGuard: fake,
            stateDir: makeStateDir()
        )
        await service.restore()

        let status = await service.snapshot()
        XCTAssertTrue(status.clamshell)
        XCTAssertFalse(status.clamshellRequiresPower)
    }
}
