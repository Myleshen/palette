import XCTest
import PaletteCore
import TOMLKit

/// The Theming pane's "Palette source" toggle and the ⌘⌥G deck guard: the
/// disabled state and the deck's hint are decided here, so the pane only has
/// to apply one mapping.
final class PaletteSourceTests: XCTestCase {
    // MARK: - Source matrix

    func testSourceMatrixEnablesOnlyItsOwnControls() {
        let theme = ThemingSourceControls(source: .theme)
        XCTAssertTrue(theme.themeEnabled)
        XCTAssertFalse(theme.wallpaperEnabled)
        XCTAssertNil(theme.themeDisabledReason)
        XCTAssertEqual(
            theme.wallpaperDisabledReason,
            "Theme drives the palette — switch source to follow the wallpaper."
        )

        let wallpaper = ThemingSourceControls(source: .wallpaper)
        XCTAssertFalse(wallpaper.themeEnabled)
        XCTAssertTrue(wallpaper.wallpaperEnabled)
        XCTAssertEqual(
            wallpaper.themeDisabledReason,
            "Wallpaper drives the palette — switch source to pick a theme."
        )
        XCTAssertNil(wallpaper.wallpaperDisabledReason)
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

    func testSourceGuardBlocksOnlyThemeCardsUnderWallpaperSource() {
        XCTAssertEqual(
            ThemeCardSourceGuard.blockedReason(source: .wallpaper, target: .theme("default-dark")),
            "Palette follows the wallpaper — switch source to Theme to pick colours"
        )
        XCTAssertNil(ThemeCardSourceGuard.blockedReason(source: .wallpaper, target: .wallpaper))
        XCTAssertNil(
            ThemeCardSourceGuard.blockedReason(
                source: .wallpaper,
                target: .wallpaperFile("/tmp/wallpaper.png")
            )
        )
        XCTAssertNil(ThemeCardSourceGuard.blockedReason(source: .theme, target: .theme("default-dark")))
    }
}
