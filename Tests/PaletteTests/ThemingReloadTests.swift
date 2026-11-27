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
    /// `KittyRemoteControl` sends.
    private func fakeKitty(in directory: String, lsStatus: Int, setStatus: Int) throws -> String {
        let path = directory + "/kitty"
        let log = directory + "/args.log"
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(log)"
        case "$1 $2" in
          "@ ls") exit \(lsStatus) ;;
          "@ set-colors") exit \(setStatus) ;;
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
            .nvim: "Run :source ~/.config/palette/theme/nvim.lua or restart Neovim",
            .fish: "Open a new shell (or `source ~/.config/palette/theme/fish.fish`)",
            .starship: "New shell (or `source ~/.config/palette/theme/starship-palette.fish`)",
            .bat: "Next bat invocation",
            .btop: "Restart btop",
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
    }

    // MARK: - Remote control with a real executable

    func testRemoteControlOffIsReportedAsARestart() async throws {
        let directory = temporaryDirectory()
        let kitty = KittyRemoteControl(binary: try fakeKitty(in: directory, lsStatus: 1, setStatus: 0))

        let status = await kitty.reload(themeFile: directory + "/kitty.conf")

        XCTAssertEqual(status.state, .action)
        XCTAssertEqual(status.message, "Restart kitty (remote control disabled)")
        XCTAssertEqual(recordedArguments(in: directory), ["@ ls"], "set-colors must not run without remote control")
    }

    func testRemoteControlOnSendsSetColorsWithTheThemeFile() async throws {
        let directory = temporaryDirectory()
        let kitty = KittyRemoteControl(binary: try fakeKitty(in: directory, lsStatus: 0, setStatus: 0))
        let themeFile = directory + "/theme/kitty.conf"

        let status = await kitty.reload(themeFile: themeFile)

        XCTAssertEqual(status.state, .reloaded)
        XCTAssertEqual(status.message, "Reloaded open kitty windows")
        XCTAssertTrue(recordedArguments(in: directory).contains("@ set-colors -a \(themeFile)"))
    }

    func testARefusedSetColorsIsNeverReportedAsReloaded() async throws {
        let directory = temporaryDirectory()
        let kitty = KittyRemoteControl(binary: try fakeKitty(in: directory, lsStatus: 0, setStatus: 1))

        let status = await kitty.reload(themeFile: directory + "/kitty.conf")

        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.message, "Restart kitty (reload failed)")
    }

    func testAMissingBinaryIsARestartNotASuccess() async {
        let status = await KittyRemoteControl(binary: "/nonexistent/kitty")
            .reload(themeFile: "/tmp/kitty.conf")
        XCTAssertEqual(status.state, .action)
        XCTAssertEqual(status.message, "Restart kitty (remote control disabled)")
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
        let engine = ThemingEngine(
            paths: paths,
            themesDirectory: paths.themesDir,
            kitty: KittyRemoteControl(binary: fake)
        )

        let status = await engine.reload(.kitty)

        XCTAssertEqual(status.state, .reloaded)
        XCTAssertEqual(engine.reloadStatus(for: .kitty), status)
        XCTAssertTrue(recordedArguments(in: home).contains { $0.hasPrefix("@ set-colors -a ") })
    }
}
