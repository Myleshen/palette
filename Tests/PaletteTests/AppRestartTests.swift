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

    func testRestartListUsesTheProcessTableAndNeverZellij() async {
        let table = ProcessTable([
            "kitty": [41, 42],
            "neovide": [43],
            "Ghostty": [44],
            "zellij": [45],
        ])
        let restart = AppRestart(pids: { table.pids($0) })

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
        let restart = AppRestart(pids: { _ in [1] })

        let apps = await restart.appsToRestart(
            kittyNeedsRestart: false,
            neovideNeedsRestart: false,
            ghosttyNeedsRestart: false
        )

        XCTAssertEqual(apps, [])
    }

    func testAnAppThatIsNotRunningIsNotOffered() async {
        let table = ProcessTable(["Ghostty": [4]])
        let restart = AppRestart(pids: { table.pids($0) })
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
        let relaunched = CallLog()
        let table = ProcessTable(["Ghostty": [7]])
        let restart = AppRestart(
            pids: { table.pids($0) },
            run: { arguments, _ in
                calls.record(arguments.joined(separator: " "))
                if arguments[0] == "/usr/bin/osascript" { table.set("Ghostty", []) }
                return success()
            },
            wait: { _ in },
            relaunch: { relaunched.record($0.name) }
        )

        let report = await restart.restart([
            AppRestart.App(name: "Ghostty", processName: "Ghostty"),
        ])

        XCTAssertEqual(report, "Restarted Ghostty")
        XCTAssertEqual(calls.all, [
            "/usr/bin/osascript -e tell application \"Ghostty\" to quit",
        ])
        XCTAssertEqual(relaunched.all, ["Ghostty"])
    }

    func testAnEditorThatRefusesToQuitIsBroughtForwardWithoutForceKill() async {
        let calls = CallLog()
        let relaunched = CallLog()
        let table = ProcessTable(["Ghostty": [7]])
        let restart = AppRestart(
            quitTimeout: 0.4,
            pollInterval: 0.2,
            pids: { table.pids($0) },
            run: { arguments, _ in
                calls.record(arguments.joined(separator: " "))
                return success()
            },
            wait: { _ in },
            relaunch: { relaunched.record($0.name) }
        )

        let report = await restart.restart([
            AppRestart.App(name: "Ghostty", processName: "Ghostty"),
        ])

        XCTAssertEqual(report, "Restarted Ghostty")
        XCTAssertEqual(calls.all, [
            "/usr/bin/osascript -e tell application \"Ghostty\" to quit",
        ])
        XCTAssertFalse(calls.all.contains { $0.hasPrefix("/bin/kill") }, "editors are never force-killed")
        XCTAssertEqual(relaunched.all, ["Ghostty"])
    }

    // MARK: - kitty escalation

    func testKittyEscalatesFromQuitToSIGTERMThenRelaunches() async {
        let calls = CallLog()
        let relaunched = CallLog()
        let table = ProcessTable(["kitty": [11, 12]])
        let restart = AppRestart(
            quitTimeout: 0.4,
            termTimeout: 0.4,
            pollInterval: 0.2,
            pids: { table.pids($0) },
            run: { arguments, _ in
                calls.record(arguments.joined(separator: " "))
                if arguments[0] == "/bin/kill" { table.set("kitty", []) }
                return success()
            },
            wait: { _ in },
            relaunch: { relaunched.record($0.name) }
        )

        let report = await restart.restart([
            AppRestart.App(name: "kitty", processName: "kitty"),
        ])

        XCTAssertEqual(report, "Restarted kitty")
        XCTAssertEqual(calls.all, [
            "/usr/bin/osascript -e tell application \"kitty\" to quit",
            "/bin/kill -TERM 11 12",
        ])
        XCTAssertEqual(relaunched.all, ["kitty"])
    }

    func testKittyThatIgnoresSIGTERMGetsSIGKILLBeforeRelaunch() async {
        let calls = CallLog()
        let relaunched = CallLog()
        let table = ProcessTable(["kitty": [21]])
        let restart = AppRestart(
            quitTimeout: 0.4,
            termTimeout: 0.4,
            pollInterval: 0.2,
            pids: { table.pids($0) },
            run: { arguments, _ in
                calls.record(arguments.joined(separator: " "))
                if arguments[0] == "/bin/kill", arguments[1] == "-KILL" {
                    table.set("kitty", [])
                }
                return success()
            },
            wait: { _ in },
            relaunch: { relaunched.record($0.name) }
        )

        let report = await restart.restart([
            AppRestart.App(name: "kitty", processName: "kitty"),
        ])

        XCTAssertEqual(report, "Restarted kitty")
        XCTAssertEqual(calls.all, [
            "/usr/bin/osascript -e tell application \"kitty\" to quit",
            "/bin/kill -TERM 21",
            "/bin/kill -KILL 21",
        ])
        XCTAssertEqual(relaunched.all, ["kitty"])
    }

    func testAnUnkillableKittyIsReportedAndNotDuplicated() async {
        let calls = CallLog()
        let relaunched = CallLog()
        let table = ProcessTable(["kitty": [31]])
        let restart = AppRestart(
            quitTimeout: 0.4,
            termTimeout: 0.4,
            pollInterval: 0.2,
            pids: { table.pids($0) },
            run: { arguments, _ in
                calls.record(arguments.joined(separator: " "))
                return success()
            },
            wait: { _ in },
            relaunch: { relaunched.record($0.name) }
        )

        let report = await restart.restart([
            AppRestart.App(name: "kitty", processName: "kitty"),
        ])

        XCTAssertEqual(report, "could not stop kitty")
        XCTAssertEqual(relaunched.all, [], "a surviving instance must not get a second window")
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
        let table = ProcessTable([
            "kitty": [1],
            "neovide": [2],
            "Ghostty": [3],
        ])
        let restart = AppRestart(
            quitTimeout: 0.1,
            pollInterval: 0.05,
            pids: { table.pids($0) },
            run: { arguments, _ in
                calls.record(arguments.joined(separator: " "))
                // Quit every app so the prompt test exercises routing, not kills.
                if arguments[0] == "/usr/bin/osascript" {
                    for name in ["kitty", "neovide", "Ghostty"] { table.set(name, []) }
                }
                return success()
            },
            wait: { _ in },
            relaunch: { _ in }
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
            "Restart to finish applying: kitty, Neovide, Ghostty"
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
                pids: { _ in [] }
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

private func success() -> ProcessResult {
    ProcessResult(status: 0, stdout: Data(), stderr: Data())
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

/// A fake `pgrep` result: name in, pids out, mutable so a test can make a
/// quit or signal actually remove a process.
private final class ProcessTable: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: [Int]]

    init(_ table: [String: [Int]]) {
        self.table = table
    }

    func pids(_ name: String) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return table[name] ?? []
    }

    func set(_ name: String, _ pids: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        table[name] = pids
    }
}
