import XCTest
import PaletteCore
import PalettePlatform

final class ThemingReloadTests: XCTestCase {
    private func temporaryDirectory() -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palette-reload-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// A stand-in for kitty: it records its arguments and exits `lsStatus` for
    /// `@ ls` and `setStatus` for `@ set-colors`, exactly the two commands
    /// `KittyRemoteControl` sends. The socket form puts `--to` first, so the
    /// match is on the whole argument string.
    private func fakeKitty(in directory: String, lsStatus: Int, setStatus: Int) throws -> String {
        let path = directory + "/kitty"
        let log = directory + "/args.log"
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(log)"
        case "$*" in
          *"@ ls"*) exit \(lsStatus) ;;
          *" ls") printf '[{}]'; exit 0 ;;
          *"set-colors"*) exit \(setStatus) ;;
        esac
        exit 1
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func recordedArguments(in directory: String) -> [String] {
        guard let text = try? String(contentsOfFile: directory + "/args.log", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - Pure status mapping

    func testEveryTargetMapsToItsReloadInstruction() {
        let expected: [ThemingTarget: String] = [
            .kitty: "Restart kitty (remote control disabled)",
            .ghostty: "Restart Ghostty",
            .zellij: "New zellij session",
            .nvim: "Run :source ~/.config/palette/theme/nvim.lua or Restart Neovide/Neovim"
                + " (Neovide keeps the old colours until its nvim restarts)",
            .fish: "Open a new shell (or `source ~/.config/palette/theme/fish.fish`)",
            .starship: "New shell — fish sets STARSHIP_CONFIG; other shells: "
                + "export STARSHIP_CONFIG=~/.config/palette/theme/starship-theme.toml",
            .bat: "Next bat invocation (Palette runs bat cache --build)",
            .btop: "Set color_theme = \"palette\" in btop.conf once, then restart btop",
            .delta: "Next git/delta command",
        ]
        for (target, message) in expected {
            let status = ThemingReload.status(for: target)
            XCTAssertEqual(status.message, message, target.rawValue)
            XCTAssertEqual(status.state, .action, target.rawValue)
        }
    }

    func testOnlyKittyCanBeReloadedByPalette() {
        XCTAssertTrue(ThemingReload.canAttempt(.kitty))
        for target in ThemingTarget.allCases where target != .kitty {
            XCTAssertFalse(ThemingReload.canAttempt(target), target.rawValue)
        }
    }

    func testKittyStatusTracksRemoteControlAndTheCommand() {
        XCTAssertEqual(
            ThemingReload.kitty(remoteControl: false, applied: false),
            ThemingReload.Status(state: .action, message: "Restart kitty (remote control disabled)")
        )
        XCTAssertEqual(
            ThemingReload.kitty(remoteControl: true, applied: false),
            ThemingReload.Status(state: .failed, message: "Restart kitty (reload failed)")
        )
        XCTAssertEqual(
            ThemingReload.kitty(remoteControl: true, applied: true),
            ThemingReload.Status(state: .reloaded, message: "Reloaded open kitty windows")
        )
        XCTAssertEqual(
            ThemingReload.kittyAddedRemoteControl(),
            ThemingReload.Status(
                state: .action,
                message: "Added remote control — restart kitty once, then applies recolour it live"
            )
        )
        XCTAssertEqual(
            ThemingReload.kittyLive(windows: 1),
            ThemingReload.Status(state: .reloaded, message: "Reloaded 1 kitty window")
        )
        XCTAssertEqual(
            ThemingReload.kittyLive(windows: 3),
            ThemingReload.Status(state: .reloaded, message: "Reloaded 3 kitty windows")
        )
    }

    func testTheNeovimHintNamesNeovide() {
        let message = ThemingReload.status(for: .nvim).message
        XCTAssertTrue(message.contains("Restart Neovide/Neovim"))
        XCTAssertTrue(message.contains("Neovide keeps the old colours"))
    }

    // MARK: - Remote control with a real executable

    func testNoSocketIsReportedAsARestartWithoutSendingACommand() async throws {
        let directory = temporaryDirectory()
        let kitty = KittyRemoteControl(
            binary: try fakeKitty(in: directory, lsStatus: 1, setStatus: 0),
            environment: ["XDG_RUNTIME_DIR": directory + "/empty-run"],
            runningKittyPIDs: { [] }
        )

        let status = await kitty.reload(themeFile: directory + "/kitty.conf")

        XCTAssertEqual(status.state, .action)
        XCTAssertEqual(status.message, "Restart kitty (remote control disabled)")
        XCTAssertEqual(recordedArguments(in: directory), [], "set-colors must not run without a socket")
    }

    func testARefusedSetColorsIsNeverReportedAsReloaded() async throws {
        let directory = temporaryDirectory()
        let runtime = directory + "/run"
        try write("", to: runtime + "/kitty-31")
        let kitty = KittyRemoteControl(
            binary: try fakeKitty(in: directory, lsStatus: 0, setStatus: 1),
            environment: ["XDG_RUNTIME_DIR": runtime],
            runningKittyPIDs: { Set([31]) }
        )

        let status = await kitty.reload(themeFile: directory + "/kitty.conf")

        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.message, "Restart kitty (reload failed)")
    }

    func testAMissingBinaryIsARestartNotASuccess() async {
        let status = await KittyRemoteControl(
            binary: "/nonexistent/kitty",
            environment: ["XDG_RUNTIME_DIR": "/nonexistent/run"],
            runningKittyPIDs: { [] }
        ).reload(themeFile: "/tmp/kitty.conf")
        XCTAssertEqual(status.state, .action)
        XCTAssertEqual(status.message, "Restart kitty (remote control disabled)")
    }

    // MARK: - Socket discovery

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testListenTemplateParsesTheUserSetting() {
        let configured = """
        # listen_on unix:/commented/out-{kitty_pid}
        font_size 14
        listen_on unix:${XDG_RUNTIME_DIR}/omarchy-kitty-{kitty_pid}
        """
        XCTAssertEqual(
            KittyRemoteControl.listenTemplate(inConfig: configured),
            "omarchy-kitty-{kitty_pid}"
        )
        XCTAssertEqual(
            KittyRemoteControl.listenTemplate(inConfig: "font_size 14\n"),
            KittyRemoteControl.defaultListenTemplate,
            "kitty's own name is the fallback"
        )
        XCTAssertNil(
            KittyRemoteControl.listenTemplate(inConfig: "listen_on tcp:127.0.0.1:0\n"),
            "a TCP listener is not a filesystem socket"
        )
        XCTAssertEqual(
            KittyRemoteControl.listenTemplate(
                inConfig: "listen_on unix:${TMPDIR}palette-kitty-{kitty_pid}\n"
            ),
            "palette-kitty-{kitty_pid}",
            "the managed block's listener parses like any other"
        )
        XCTAssertEqual(
            KittyRemoteControl.listenTemplate(inConfig: """
            listen_on unix:${XDG_RUNTIME_DIR}/omarchy-kitty-{kitty_pid}
            listen_on unix:${TMPDIR}palette-kitty-{kitty_pid}
            """),
            "palette-kitty-{kitty_pid}",
            "kitty keeps the last listener, so the managed line is the active one"
        )
    }

    func testSocketDiscoveryKeepsOnlySocketsOfRunningKittyProcesses() {
        let sockets = KittyRemoteControl.socketPaths(
            template: "omarchy-kitty-{kitty_pid}",
            runtimeDir: "/run/user/501",
            entries: ["omarchy-kitty-111", "omarchy-kitty-222", "omarchy-kitty-333", "kitty-222"],
            pids: [222, 333]
        )
        XCTAssertEqual(
            sockets,
            ["/run/user/501/omarchy-kitty-222", "/run/user/501/omarchy-kitty-333"],
            "111 left a stale socket behind; kitty-222 does not match the template"
        )
    }

    func testLiveSetColorsAddressesTheSocket() async throws {
        let directory = temporaryDirectory()
        let runtime = directory + "/run"
        try write("", to: runtime + "/kitty-77")
        let kitty = KittyRemoteControl(
            binary: try fakeKitty(in: directory, lsStatus: 1, setStatus: 0),
            environment: ["XDG_RUNTIME_DIR": runtime],
            runningKittyPIDs: { Set([77]) }
        )
        let theme = directory + "/theme/kitty.conf"

        let status = await kitty.reload(themeFile: theme)

        XCTAssertEqual(status.state, .reloaded)
        XCTAssertEqual(status.message, "Reloaded 1 kitty window")
        XCTAssertEqual(
            recordedArguments(in: directory).filter { $0.contains("set-colors") },
            ["@ --to unix:\(runtime)/kitty-77 set-colors -a \(theme)"],
            "the socket must be addressed explicitly, not through an inherited env"
        )
    }

    func testDiscoveryFindsManagedAndUserSocketsAndIgnoresStaleEntries() async throws {
        let directory = temporaryDirectory()
        let temp = directory + "/tmp"
        let runtime = directory + "/xdg"
        try write("", to: temp + "/palette-kitty-11")
        try write("", to: temp + "/palette-kitty-12")
        try write("", to: runtime + "/omarchy-kitty-11")
        let config = directory + "/kitty.conf"
        try write("listen_on unix:${XDG_RUNTIME_DIR}/omarchy-kitty-{kitty_pid}\n", to: config)
        let kitty = KittyRemoteControl(
            binary: try fakeKitty(in: directory, lsStatus: 0, setStatus: 0),
            environment: ["TMPDIR": temp, "XDG_RUNTIME_DIR": runtime],
            runningKittyPIDs: { Set([11]) }
        )

        let status = await kitty.reload(themeFile: directory + "/theme.conf", configPath: config)

        XCTAssertEqual(status.state, .reloaded)
        XCTAssertEqual(status.message, "Reloaded 2 kitty windows")
        let commands = Set(recordedArguments(in: directory).filter { $0.contains("set-colors") })
        XCTAssertEqual(commands, [
            "@ --to unix:\(temp)/palette-kitty-11 set-colors -a \(directory)/theme.conf",
            "@ --to unix:\(runtime)/omarchy-kitty-11 set-colors -a \(directory)/theme.conf",
        ], "the managed socket and the user's old listener are both recoloured")
        XCTAssertFalse(commands.contains { $0.contains("palette-kitty-12") }, "a stale socket is ignored")
    }

    func testSeveralWindowsInOneKittyProcessAreCounted() async throws {
        let directory = temporaryDirectory()
        let path = directory + "/kitty"
        try """
        #!/bin/sh
        case "$*" in
          *" ls") printf '[{},{},{}]'; exit 0 ;;
          *"set-colors"*) exit 0 ;;
        esac
        exit 1
        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try write("", to: directory + "/run/palette-kitty-5")
        let kitty = KittyRemoteControl(
            binary: path,
            environment: ["TMPDIR": directory + "/run"],
            runningKittyPIDs: { Set([5]) }
        )

        let status = await kitty.reload(themeFile: directory + "/theme.conf")

        XCTAssertEqual(status.state, .reloaded)
        XCTAssertEqual(status.message, "Reloaded 3 kitty windows", "@ ls is the window count, not the socket count")
    }

    func testMissingRuntimeDirectoryFallsBackToTheRestartHint() async throws {
        let directory = temporaryDirectory()
        let kitty = KittyRemoteControl(
            binary: try fakeKitty(in: directory, lsStatus: 1, setStatus: 0),
            environment: ["XDG_RUNTIME_DIR": directory + "/absent"],
            runningKittyPIDs: { Set([42]) }
        )
        let config = directory + "/kitty.conf"
        try write("listen_on unix:${XDG_RUNTIME_DIR}/omarchy-kitty-{kitty_pid}\n", to: config)

        let status = await kitty.reload(themeFile: directory + "/theme.conf", configPath: config)

        XCTAssertEqual(status.state, .action)
        XCTAssertEqual(status.message, "Restart kitty (remote control disabled)")
        XCTAssertEqual(recordedArguments(in: directory), [])

        // A listener Palette cannot scan must not fall back to kitty's default.
        let tcp = directory + "/tcp.conf"
        try write("listen_on tcp:127.0.0.1:0\n", to: tcp)
        _ = await kitty.reload(themeFile: directory + "/theme.conf", configPath: tcp)
        XCTAssertEqual(recordedArguments(in: directory), [])
    }

    // MARK: - Engine wiring

    @MainActor
    func testEngineReloadActuallyRunsKittyAndPublishesTheAnswer() async throws {
        let home = temporaryDirectory()
        let paths = PalettePaths(
            home: home,
            configDir: URL(fileURLWithPath: home + "/config", isDirectory: true),
            stateDir: URL(fileURLWithPath: home + "/state", isDirectory: true),
            cacheDir: URL(fileURLWithPath: home + "/cache", isDirectory: true)
        )
        let fake = try fakeKitty(in: home, lsStatus: 0, setStatus: 0)
        try write("", to: home + "/run/kitty-88")
        let engine = ThemingEngine(
            paths: paths,
            themesDirectory: paths.themesDir,
            kitty: KittyRemoteControl(
                binary: fake,
                environment: ["XDG_RUNTIME_DIR": home + "/run"],
                runningKittyPIDs: { Set([88]) }
            )
        )

        let status = await engine.reload(.kitty)

        XCTAssertEqual(status.state, .reloaded)
        XCTAssertEqual(engine.reloadStatus(for: .kitty), status)
        XCTAssertTrue(recordedArguments(in: home).contains { $0.contains("set-colors -a ") })
    }

    @MainActor
    func testFirstApplyAsksForOneRestartThenTheNextApplyRecoloursLive() async throws {
        let home = temporaryDirectory()
        let runtime = home + "/run"
        try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true)
        let configPath = home + "/.config/kitty/kitty.conf"
        try write("listen_on unix:${XDG_RUNTIME_DIR}/omarchy-kitty-{kitty_pid}\n", to: configPath)
        let paths = PalettePaths(
            home: home,
            configDir: URL(fileURLWithPath: home + "/config", isDirectory: true),
            stateDir: URL(fileURLWithPath: home + "/state", isDirectory: true),
            cacheDir: URL(fileURLWithPath: home + "/cache", isDirectory: true)
        )
        let fake = try fakeKitty(in: home, lsStatus: 0, setStatus: 0)
        let engine = ThemingEngine(
            paths: paths,
            themesDirectory: paths.themesDir,
            kitty: KittyRemoteControl(
                binary: fake,
                environment: ["XDG_RUNTIME_DIR": runtime],
                runningKittyPIDs: { Set([4242]) }
            ),
            reloadsEnabled: true
        )
        let config = ThemingConfig(enabled: true, theme: "default-dark", targets: ["kitty"])

        // The block that first turns remote control on cannot reach the kitty
        // that is already running; that one starts listening on its next launch.
        let first = await engine.apply(config)
        XCTAssertTrue(first.status.contains("Added remote control — restart kitty once"), first.status)
        XCTAssertEqual(engine.reloadStatus(for: .kitty), ThemingReload.kittyAddedRemoteControl())
        let once = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertEqual(once.components(separatedBy: "allow_remote_control socket-only").count, 2)
        XCTAssertEqual(once.components(separatedBy: "include ~/config/theme/kitty.conf").count, 2)

        // After the restart the socket exists; the same Apply now recolours it.
        try write("", to: runtime + "/omarchy-kitty-4242")
        let second = await engine.apply(config)
        XCTAssertTrue(second.status.contains("Reloaded 1 kitty window"), second.status)
        XCTAssertFalse(second.status.contains("Added remote control"))
        let theme = paths.themeDir.appendingPathComponent("kitty.conf").path
        XCTAssertTrue(
            recordedArguments(in: home).contains(
                "@ --to unix:\(runtime)/omarchy-kitty-4242 set-colors -a \(theme)"
            ),
            recordedArguments(in: home).joined(separator: " | ")
        )
    }
}
