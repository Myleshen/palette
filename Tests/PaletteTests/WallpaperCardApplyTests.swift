import XCTest
import PaletteCore
import PalettePlatform
@testable import PaletteApp

/// Picking a wallpaper is picking its colours, the way pywal does on Linux:
/// the picture changes first, the config records wallpaper as the source, and
/// exactly one palette run follows. Palette itself always takes the colours;
/// the generated app files only when the master switch is on.
final class WallpaperCardApplyTests: XCTestCase {
    private func enabledConfig(source: ThemingSource = .theme) -> PaletteConfig {
        var config = PaletteConfig()
        config.theming.enabled = true
        config.theming.source = source
        config.theming.followWallpaper = false
        config.theming.darkMode = "dark"
        config.theming.targets = ["kitty"]
        return config
    }

    func testWallpaperCardFlipsTheSourceAndFiresTheEngineOnce() async throws {
        var pictures: [String] = []
        var applies: [ThemingConfig] = []
        var saved: PaletteConfig?
        let flow = await ThemeCardApplyFlow.wallpaperFile(
            path: "/tmp/wall.png",
            name: "wall.png",
            config: enabledConfig(source: .theme),
            setDesktopPicture: { path in
                pictures.append(path)
                return true
            },
            saveConfig: { saved = $0 },
            applyPalette: { config in
                applies.append(config)
                return .empty
            }
        )

        XCTAssertEqual(pictures, ["/tmp/wall.png"], "the picture changes first")
        XCTAssertEqual(applies.count, 1, "one palette run per card, never two")
        XCTAssertEqual(applies.first?.source, .wallpaper, "the engine samples the picture it was given")
        XCTAssertEqual(flow.config.theming.source, .wallpaper)
        XCTAssertFalse(flow.config.theming.followWallpaper, "the user's follow setting is not forced")
        XCTAssertEqual(saved?.theming.source, .wallpaper, "the source is saved with the apply")
        XCTAssertEqual(flow.outcome.message, "Desktop picture set and palette applied — wall.png")
        XCTAssertFalse(flow.outcome.failed)
    }

    func testWallpaperCardReportsEvenWithCrossAppThemingOff() async {
        var pictures = 0
        var applies = 0
        var config = enabledConfig()
        config.theming.enabled = false

        let flow = await ThemeCardApplyFlow.wallpaperFile(
            path: "/tmp/off.png",
            name: "off.png",
            config: config,
            setDesktopPicture: { _ in
                pictures += 1
                return true
            },
            saveConfig: { _ in },
            applyPalette: { _ in
                applies += 1
                return .empty
            }
        )

        XCTAssertEqual(pictures, 1)
        XCTAssertEqual(applies, 1, "Palette still follows the picture")
        XCTAssertEqual(flow.config.theming.source, .wallpaper)
        XCTAssertFalse(flow.config.theming.enabled, "a card never turns the master switch on")
        XCTAssertEqual(flow.outcome.message, "Desktop picture set and palette applied — off.png")
        XCTAssertFalse(flow.outcome.failed)
    }

    func testAFailedPaletteStillReportsTheChangedPicture() async {
        let failure = ThemingEngine.ApplyResult(
            status: "No desktop picture found — choose one.",
            source: "wallpaper",
            appearance: "dark",
            written: [],
            skipped: [],
            includeLines: [],
            notices: [],
            changes: [],
            targets: [],
            error: "No desktop picture found — choose one."
        )
        let flow = await ThemeCardApplyFlow.wallpaperFile(
            path: "/tmp/bad.png",
            name: "bad.png",
            config: enabledConfig(),
            setDesktopPicture: { _ in true },
            saveConfig: { _ in },
            applyPalette: { _ in failure }
        )

        XCTAssertTrue(flow.outcome.failed)
        XCTAssertEqual(
            flow.outcome.message,
            "Desktop picture set, but the palette was not applied — bad.png: "
                + "No desktop picture found — choose one."
        )
        XCTAssertEqual(flow.config.theming.source, .wallpaper, "the picture owns the colours either way")
    }

    func testARejectedPictureDoesNotTouchThePalette() async {
        var applies = 0
        let before = enabledConfig()
        let flow = await ThemeCardApplyFlow.wallpaperFile(
            path: "/tmp/clip.mp4",
            name: "clip.mp4",
            config: before,
            setDesktopPicture: { _ in false },
            saveConfig: { _ in XCTFail("nothing to save when the picture did not change") },
            applyPalette: { _ in
                applies += 1
                return .empty
            }
        )

        XCTAssertEqual(applies, 0)
        XCTAssertTrue(flow.outcome.failed)
        XCTAssertEqual(flow.outcome.message, "Could not set clip.mp4 as the desktop picture.")
        XCTAssertEqual(flow.config, before, "config stays as it was")
    }

    func testThemeConfigFlipsTheSourceBack() {
        var config = ThemingConfig(enabled: true, source: .wallpaper, followWallpaper: true)
        config.targets = ["kitty"]
        let next = WallpaperCardPolicy.themeConfig(from: config)
        XCTAssertEqual(next.source, .theme)
        XCTAssertTrue(next.followWallpaper, "the user's follow setting is left alone")
        XCTAssertEqual(next.targets, ["kitty"])
        XCTAssertTrue(next.enabled)
    }

    func testWallpaperConfigKeepsEveryOtherSetting() {
        var config = ThemingConfig(enabled: false, source: .theme, followWallpaper: true)
        config.wallpaperDirectory = "~/Pictures/Walls"
        let next = WallpaperCardPolicy.wallpaperConfig(from: config)
        XCTAssertEqual(next.source, .wallpaper)
        XCTAssertEqual(next.wallpaperDirectory, "~/Pictures/Walls")
        XCTAssertTrue(next.followWallpaper)
        XCTAssertFalse(next.enabled)
    }
}
