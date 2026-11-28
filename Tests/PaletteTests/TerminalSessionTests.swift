import XCTest
import PaletteCore
import PalettePlatform

final class TerminalSessionTests: XCTestCase {
    // MARK: - Zellij attach decisions

    func testSessionNameSanitizes() {
        XCTAssertEqual(ZellijAttach.sessionName("Palette"), "Palette")
        XCTAssertEqual(ZellijAttach.sessionName("ssh-pi.dev_1"), "ssh-pi.dev_1")
        XCTAssertEqual(ZellijAttach.sessionName("my project:two"), "my-project-two")
        XCTAssertTrue(ZellijAttach.sessionName("---").hasPrefix("palette-"))
    }

    func testUnusableNamesGetDistinctFallbacks() {
        let a = ZellijAttach.sessionName("!!!")
        let b = ZellijAttach.sessionName("???")
        XCTAssertTrue(a.hasPrefix("palette-"))
        XCTAssertTrue(b.hasPrefix("palette-"))
        XCTAssertNotEqual(a, b)
        // Stable across calls, otherwise every attach would make a new session.
        XCTAssertEqual(a, ZellijAttach.sessionName("!!!"))
    }

    func testPlanResetsAnExitedSession() {
        let listing = """
        polished-glockenspiel [Created 21days ago] (EXITED - attach to resurrect)
        Work [Created 7days ago] (current)
        """
        XCTAssertEqual(
            ZellijAttach.plan(name: "Work", listing: listing),
            .attach(name: "Work")
        )
        XCTAssertEqual(
            ZellijAttach.plan(name: "polished-glockenspiel", listing: listing),
            .reset(name: "polished-glockenspiel")
        )
        XCTAssertEqual(
            ZellijAttach.plan(name: "Palette", listing: listing),
            .attach(name: "Palette")
        )
    }

    func testPlanDoesNotMatchAPrefixOfAnotherName() {
        let listing = "Workout [Created 1h ago] (EXITED - attach to resurrect)"
        XCTAssertEqual(ZellijAttach.plan(name: "Work", listing: listing), .attach(name: "Work"))
    }

    func testPlanSanitizesTheNameItAttachesTo() {
        XCTAssertEqual(
            ZellijAttach.plan(name: "my project", listing: ""),
            .attach(name: "my-project")
        )
    }

    func testStaleFailureDetection() {
        XCTAssertTrue(ZellijAttach.isStaleSessionFailure("Session name already in use"))
        XCTAssertTrue(ZellijAttach.isStaleSessionFailure("Error: There is no active session"))
        XCTAssertTrue(ZellijAttach.isStaleSessionFailure("No active sessions found"))
        XCTAssertFalse(ZellijAttach.isStaleSessionFailure("Permission denied"))
        XCTAssertFalse(ZellijAttach.isStaleSessionFailure(""))
    }

    func testAttachScriptRetriesOnceOnFailure() {
        let script = ZellijLauncher.attachScript(zellij: "/opt/homebrew/bin/zellij", name: "Work", create: false)
        XCTAssertEqual(
            script,
            "'/opt/homebrew/bin/zellij' attach 'Work' || "
                + "{ '/opt/homebrew/bin/zellij' delete-session --force 'Work'; "
                + "exec '/opt/homebrew/bin/zellij' --session 'Work'; }"
        )
        XCTAssertTrue(
            ZellijLauncher.attachScript(zellij: "/z", name: "Work", create: true)
                .hasPrefix("'/z' attach --create 'Work' ||")
        )
    }

    func testThemedSessionButtonCreatesThePaletteSession() {
        XCTAssertEqual(ZellijLauncher.themedSessionName, "Palette")
        XCTAssertEqual(
            ZellijLauncher.themedSessionScript(zellij: "/opt/homebrew/bin/zellij"),
            "'/opt/homebrew/bin/zellij' attach --create 'Palette' || "
                + "{ '/opt/homebrew/bin/zellij' delete-session --force 'Palette'; "
                + "exec '/opt/homebrew/bin/zellij' --session 'Palette'; }"
        )
    }

    @MainActor
    func testKittyTerminalArgumentsKeepTheThemedScriptIntact() {
        // `zsh -lic` gets one raw argument: escaping the script's quotes again
        // made zsh fail with "unmatched '" and the kitty window closed.
        let script = ZellijLauncher.themedSessionScript(zellij: "/z")
        XCTAssertEqual(
            LauncherService.kittyTerminalArguments(command: script),
            ["--detach", "/bin/zsh", "-lic", "\(script); exec /bin/zsh -l"]
        )
    }

    func testRestartRelaunchUsesTheThemedSessionScript() {
        // AppRestart relaunches through the same command as the button: a
        // fresh Palette session, because a running one never re-reads the
        // palette.
        XCTAssertEqual(
            ZellijLauncher.themedSessionScript(zellij: "/z"),
            "'/z' attach --create 'Palette' || "
                + "{ '/z' delete-session --force 'Palette'; "
                + "exec '/z' --session 'Palette'; }"
        )
    }

    // MARK: - Editor launch

    func testNeovideStartsANewInstance() {
        let command = EditorLaunch.newInstanceCommand(
            appPath: "/Applications/Neovide.app",
            path: "~/dev/palette-launcher"
        )
        XCTAssertEqual(
            command,
            ["/Applications/Neovide.app/Contents/MacOS/neovide", "--fork", "~/dev/palette-launcher"]
        )
    }

    func testOtherAppsKeepTheNormalOpenPath() {
        XCTAssertNil(EditorLaunch.newInstanceCommand(appPath: "/Applications/Preview.app", path: "/tmp/a.png"))
        XCTAssertNil(EditorLaunch.newInstanceCommand(appPath: "Safari", path: "/tmp/a.html"))
    }

    func testWindowReusingRowsCarryAHint() {
        XCTAssertTrue(EditorLaunch.reusesOpenWindow(app: "Visual Studio Code"))
        XCTAssertTrue(EditorLaunch.reusesOpenWindow(app: "/Applications/Cursor.app"))
        XCTAssertFalse(EditorLaunch.reusesOpenWindow(app: "neovide"))
        XCTAssertFalse(EditorLaunch.reusesOpenWindow(app: "kitty"))
    }
}
