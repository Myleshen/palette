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
    private var enabled = false

    func isEnabled() async -> Bool { enabled }
    func enable() async throws { enabled = true }
    func disable() async { enabled = false }
}

final class KeepAwakeTests: XCTestCase {
    private func makeGuard() -> ClamshellGuard {
        let flag = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-clamshell-\(UUID().uuidString).active")
        return ClamshellGuard(flagURL: flag, verifyEnabled: false)
    }

    func testStartAndStopWithAssertionsDisabled() async throws {
        let service = KeepAwakeService(assertionsEnabled: false, clamshellGuard: makeGuard(), timerInterval: 0.1)
        try await service.start(duration: nil)
        var status = await service.snapshot()
        XCTAssertTrue(status.active)
        XCTAssertNil(status.endsAt)

        await service.stop()
        status = await service.snapshot()
        XCTAssertFalse(status.active)
    }

    func testTimedSessionExpires() async throws {
        let service = KeepAwakeService(assertionsEnabled: false, clamshellGuard: makeGuard(), timerInterval: 0.05)
        try await service.start(duration: 0.25)
        let active = await service.snapshot()
        XCTAssertTrue(active.active)
        XCTAssertNotNil(active.endsAt)

        try await Task.sleep(nanoseconds: 700_000_000)
        let stopped = await service.snapshot()
        XCTAssertFalse(stopped.active)
    }

    func testProviderRowsAndStartAction() async throws {
        let service = KeepAwakeService(assertionsEnabled: false, clamshellGuard: makeGuard())
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

    func testClamshellToggleIsIndependentOfKeepAwake() async throws {
        let fake = FakeClamshell()
        let service = KeepAwakeService(assertionsEnabled: false, clamshellGuard: fake)

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
        let service = KeepAwakeService(assertionsEnabled: false, clamshellGuard: fake)

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

    func testProviderClamshellActionTogglesWithoutStartingTimer() async throws {
        let fake = FakeClamshell()
        let service = KeepAwakeService(assertionsEnabled: false, clamshellGuard: fake)
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

        let script = ClamshellGuard.helperScript(
            pid: getpid(),
            flagPath: flag.path,
            pmset: fakePmset.path,
            sleepBinary: fakeSleep.path,
            interval: 0
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
        defer {
            if process.isRunning { process.terminate() }
        }

        func stateValue() -> String {
            (try? String(contentsOf: state, encoding: .utf8)) ?? ""
        }

        // The helper polls every 50ms; give slow CI runners room for the first write.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(stateValue(), "1", "AC power should arm lid-sleep prevention")

        try "Battery Power".write(to: ac, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(stateValue(), "0", "Battery power should restore normal sleep")

        try "AC Power".write(to: ac, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(stateValue(), "1", "Reconnecting AC should re-arm the guard")

        try manager.removeItem(at: flag)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(stateValue(), "0", "Removing the flag should restore normal sleep")
    }
}
