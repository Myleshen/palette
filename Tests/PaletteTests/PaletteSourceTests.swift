import XCTest
import PaletteCore
import TOMLKit

/// The Theming pane's "Palette source" toggle and the ⌘⌥G deck guard: the
/// disabled state and the deck's hint are decided here, so the pane only has
/// to apply one mapping.
final class PaletteSourceTests: XCTestCase {
    // MARK: - Source matrix

    func testThemeSourceEnablesTheThemePickerAndDisablesWallpaperControls() {
        let controls = ThemingSourceControls(source: .theme)

        XCTAssertTrue(controls.themeEnabled)
        XCTAssertFalse(controls.wallpaperEnabled)
        XCTAssertNil(controls.themeDisabledReason)
        XCTAssertEqual(
            controls.wallpaperDisabledReason,
            "Theme drives the palette — switch source to follow the wallpaper."
        )
    }

    func testWallpaperSourceEnablesWallpaperControlsAndDisablesTheThemePicker() {
        let controls = ThemingSourceControls(source: .wallpaper)

        XCTAssertFalse(controls.themeEnabled)
        XCTAssertTrue(controls.wallpaperEnabled)
        XCTAssertEqual(
            controls.themeDisabledReason,
            "Wallpaper drives the palette — switch source to pick a theme."
        )
        XCTAssertNil(controls.wallpaperDisabledReason)
    }

    // MARK: - Persistence

    func testWallpaperSourceRoundTripsThroughTheConfigFile() throws {
        let config = ThemingConfig(enabled: true, source: .wallpaper, followWallpaper: true)
        let rendered = config.render()
        XCTAssertTrue(rendered.contains("source = \"wallpaper\""))
        XCTAssertTrue(rendered.contains("follow_wallpaper = true"))

        let table = try TOMLTable(string: rendered)
        let reloaded = ThemingConfig.parse(try XCTUnwrap(table.table("theming")))
        XCTAssertEqual(reloaded.source, .wallpaper)
        XCTAssertTrue(reloaded.followWallpaper)
    }

    func testSwitchingBackToThemePersistsTheQuietFollowFlag() throws {
        var config = ThemingConfig(enabled: true, source: .wallpaper, followWallpaper: true)
        config.source = .theme

        let rendered = config.render()
        XCTAssertTrue(rendered.contains("source = \"theme\""))
        XCTAssertTrue(rendered.contains("follow_wallpaper = false"))
        let table = try TOMLTable(string: rendered)
        XCTAssertEqual(
            ThemingConfig.parse(try XCTUnwrap(table.table("theming"))).source,
            .theme
        )
    }

    // MARK: - Deck guard

    func testWallpaperSourceBlocksThemeCardsWithTheHint() {
        let reason = ThemeCardSourceGuard.blockedReason(
            source: .wallpaper,
            target: .theme("default-dark")
        )
        XCTAssertEqual(
            reason,
            "Palette follows the wallpaper — switch source to Theme to pick colours"
        )
    }

    func testWallpaperSourceLeavesWallpaperCardsAlone() {
        XCTAssertNil(ThemeCardSourceGuard.blockedReason(source: .wallpaper, target: .wallpaper))
        XCTAssertNil(
            ThemeCardSourceGuard.blockedReason(
                source: .wallpaper,
                target: .wallpaperFile("/tmp/wallpaper.png")
            )
        )
    }

    func testThemeSourceDoesNotBlockThemeCards() {
        XCTAssertNil(ThemeCardSourceGuard.blockedReason(source: .theme, target: .theme("default-dark")))
    }
}
