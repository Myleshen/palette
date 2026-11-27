import XCTest
import PaletteCore
import PalettePlatform

final class AppRestartTests: XCTestCase {
    private func temporaryDirectory() -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palette-restart-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func paths(_ home: String) -> PalettePaths {
        PalettePaths(
            home: home,
            configDir: URL(fileURLWithPath: home + "/config", isDirectory: true),
            stateDir: URL(fileURLWithPath: home + "/state", isDirectory: true),
            cacheDir: URL(fileURLWithPath: home + "/cache", isDirectory: true)
        )
    }

    // MARK: - Decision

    func testRestartListUsesTheProcessProbeAndNeverZellij() async {
        let running: Set<String> = ["kitty", "neovide", "Ghostty", "zellij"]
        let restart = AppRestart(
            isRunning: { running.contains($0) },
            instanceCount: { _ in 2 }
        )

        let apps = await restart.appsToRestart(
            kittyNeedsRestart: true,
            neovideNeedsRestart: true,
            ghosttyNeedsRestart: true
        )

        XCTAssertEqual(apps.map(\.name), ["kitty", "Neovide", "Ghostty"])
        XCTAssertEqual(apps.first?.label, "kitty (2 windows)")
        XCTAssertFalse(apps.contains { $0.name.lowercased() == "zellij" }, "killing zellij ends every session")
    }

    func testAKittyThatRecolouredLiveIsNotOffered() async {
        let restart = AppRestart(
            isRunning: { _ in true },
            instanceCount: { _ in 1 }
        )

        let apps = await restart.appsToRestart(
            kittyNeedsRestart: false,
            neovideNeedsRestart: false,
            ghosttyNeedsRestart: false
        )

        XCTAssertEqual(apps, [])
    }

    func testAnAppThatIsNotRunningIsNotOffered() async {
        let restart = AppRestart(
            isRunning: { $0 == "Ghostty" },
            instanceCount: { _ in 1 }
        )
        let apps = await restart.appsToRestart(
            kittyNeedsRestart: true,
            neovideNeedsRestart: true,
            ghosttyNeedsRestart: true
        )
        XCTAssertEqual(apps.map(\.name), ["Ghostty"])
    }

    // MARK: - Graceful restart

    func testRestartQuitsGracefullyThenReopens() async {
        let calls = CallLog()
        let running = RunningFlag(true)
        let restart = AppRestart(
            timeout: 10,
            pollInterval: 0.2,
            isRunning: { _ in running.value },
            instanceCount: { _ in 1 },
            run: { arguments, _ in
                calls.record(arguments.joined(separator: " "))
                if arguments[0] == "/usr/bin/osascript" { running.value = false }
                return ProcessResult(status: 0, stdout: Data(), stderr: Data())
            },
            wait: { _ in }
        )

        let report = await restart.restart([
            AppRestart.App(name: "Ghostty", processName: "Ghostty"),
        ])

        XCTAssertEqual(report, "Restarted Ghostty")
        XCTAssertEqual(calls.all, [
            "/usr/bin/osascript -e tell application \"Ghostty\" to quit",
            "/usr/bin/open -a Ghostty",
        ])
    }

    func testAnAppThatRefusesToQuitIsReopenedAfterTheTimeoutWithoutForceKill() async {
        let calls = CallLog()
        let waits = CallCounter()
        let restart = AppRestart(
            timeout: 0.4,
            pollInterval: 0.2,
            isRunning: { _ in true },
            instanceCount: { _ in 1 },
            run: { arguments, _ in
                calls.record(arguments.joined(separator: " "))
                return ProcessResult(status: 0, stdout: Data(), stderr: Data())
            },
            wait: { _ in waits.increment() }
        )

        let report = await restart.restart([
            AppRestart.App(name: "kitty", processName: "kitty"),
        ])

        XCTAssertEqual(report, "Restarted kitty")
        XCTAssertEqual(waits.value, 2, "two 200 ms polls fit in the 400 ms timeout")
        XCTAssertEqual(calls.all, [
            "/usr/bin/osascript -e tell application \"kitty\" to quit",
            "/usr/bin/open -a kitty",
        ])
        XCTAssertFalse(calls.all.contains { $0.contains("kill") }, "no force-kill, ever")
    }

    func testQuitScriptEscapesTheAppName() {
        XCTAssertEqual(
            AppRestart.quitScript(for: "My \"App\""),
            "tell application \"My \\\"App\\\"\" to quit"
        )
    }

    // MARK: - Engine prompt and button routing

    @MainActor
    func testApplyBuildsTheRestartPromptAndRoutesTheButtons() async throws {
        let home = temporaryDirectory()
        let palettePaths = paths(home)
        let calls = CallLog()
        let restart = AppRestart(
            timeout: 0.1,
            pollInterval: 0.05,
            isRunning: { ["kitty", "neovide", "Ghostty"].contains($0) },
            instanceCount: { _ in 3 },
            run: { arguments, _ in
                calls.record(arguments.joined(separator: " "))
                return ProcessResult(status: 0, stdout: Data(), stderr: Data())
            },
            wait: { _ in }
        )
        let engine = ThemingEngine(
            paths: palettePaths,
            themesDirectory: palettePaths.themesDir,
            kitty: KittyRemoteControl(
                binary: "/nonexistent/kitty",
                environment: [:],
                runningKittyPIDs: { [] }
            ),
            appRestart: restart,
            reloadsEnabled: false
        )
        let config = ThemingConfig(
            enabled: true,
            theme: "default-dark",
            targets: ["kitty", "nvim", "ghostty"]
        )

        _ = await engine.apply(config)

        let prompt = try XCTUnwrap(engine.restartPrompt)
        XCTAssertEqual(prompt.apps.map(\.name), ["kitty", "Neovide", "Ghostty"])
        XCTAssertEqual(
            prompt.message,
            "Restart to finish applying: kitty (3 windows), Neovide, Ghostty"
        )
        XCTAssertEqual(prompt.primaryLabel, "Restart now")
        XCTAssertEqual(prompt.secondaryLabel, "Later")

        // "Restart now" is the primary button.
        let report = await engine.restartAppsNow()
        XCTAssertEqual(report, "Restarted kitty, Neovide, Ghostty")
        XCTAssertEqual(engine.status, "Restarted kitty, Neovide, Ghostty")
        XCTAssertNil(engine.restartPrompt)
        XCTAssertEqual(calls.all.filter { $0.hasPrefix("/usr/bin/osascript") }.count, 3)

        // "Later" only dismisses.
        engine.dismissRestartPrompt()
        XCTAssertNil(engine.restartPrompt)
    }

    @MainActor
    func testSecondApplyAfterALiveRecolourDropsKittyFromThePrompt() async throws {
        let home = temporaryDirectory()
        let runtime = home + "/run"
        try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true)
        let script = home + "/kitty"
        try """
        #!/bin/sh
        exit 0
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let palettePaths = paths(home)
        let engine = ThemingEngine(
            paths: palettePaths,
            themesDirectory: palettePaths.themesDir,
            kitty: KittyRemoteControl(
                binary: script,
                environment: ["TMPDIR": runtime],
                runningKittyPIDs: { Set([9]) }
            ),
            appRestart: AppRestart(
                isRunning: { _ in false },
                instanceCount: { _ in 0 }
            ),
            reloadsEnabled: true
        )
        let config = ThemingConfig(enabled: true, theme: "default-dark", targets: ["kitty"])

        let first = await engine.apply(config)
        XCTAssertTrue(first.status.contains("Added remote control"))
        XCTAssertNil(engine.restartPrompt, "kitty is not running, so it is not offered")

        try Data().write(to: URL(fileURLWithPath: runtime + "/palette-kitty-9"))
        let second = await engine.apply(config)
        XCTAssertTrue(second.status.contains("Reloaded 1 kitty window"))
        XCTAssertNil(engine.restartPrompt, "the second Apply recoloured live")
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func record(_ call: String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

private final class RunningFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
