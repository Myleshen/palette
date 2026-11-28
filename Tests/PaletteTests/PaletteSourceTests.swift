import XCTest
import PaletteCore
import TOMLKit
@testable import PaletteApp

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

    // MARK: - Deck blocked/enabled matrix

    private func themeCard(_ name: String = "default-dark") -> ThemeCard {
        .theme(ThemeInfo(name: name, displayName: name, appearance: "dark", isBuiltin: true))
    }

    @MainActor
    private func gallery(source: ThemingSource, _ card: ThemeCard) -> ThemeGalleryModel {
        let model = ThemeGalleryModel(deck: ThemeCardDeck(cards: [card]))
        model.paletteSource = source
        return model
    }

    /// Apply is refused only for a theme card while the wallpaper owns the
    /// palette; every other pair stays enabled.
    @MainActor
    func testDeckApplyMatrix() {
        XCTAssertNil(gallery(source: .theme, themeCard()).blockedApplyReason)
        XCTAssertNil(gallery(source: .theme, .wallpaper).blockedApplyReason)
        XCTAssertNil(gallery(source: .wallpaper, .wallpaper).blockedApplyReason)
        XCTAssertEqual(
            gallery(source: .wallpaper, themeCard()).blockedApplyReason,
            ThemeCardSourceGuard.wallpaperHint
        )
    }

    /// The deck stays open while the config changes, so flipping the source
    /// back to Theme must re-enable the card without a reopen.
    @MainActor
    func testSourceFlipWhileOpenReenablesThemeCard() {
        let model = gallery(source: .wallpaper, themeCard())
        XCTAssertNotNil(model.blockedApplyReason)

        model.paletteSource = .theme
        XCTAssertNil(model.blockedApplyReason)

        model.paletteSource = .wallpaper
        XCTAssertEqual(model.blockedApplyReason, ThemeCardSourceGuard.wallpaperHint)
    }

    /// Return on a blocked card records the hint and refuses the apply: the
    /// card, the spinner and the celebration are untouched.
    @MainActor
    func testBlockedApplyRefusalChangesOnlyTheHint() {
        let model = gallery(source: .wallpaper, themeCard())
        XCTAssertNil(model.status)
        XCTAssertFalse(model.applying)
        XCTAssertEqual(model.celebration, 0)

        XCTAssertTrue(model.showApplyRefusal())
        XCTAssertEqual(model.status, ThemeCardSourceGuard.wallpaperHint)
        XCTAssertFalse(model.statusFailed)
        XCTAssertFalse(model.applying)
        XCTAssertEqual(model.celebration, 0)
        XCTAssertEqual(model.deck.current, themeCard())

        // A card that can apply is not refused, so the caller starts the apply.
        model.paletteSource = .theme
        model.status = nil
        XCTAssertFalse(model.showApplyRefusal())
        XCTAssertNil(model.status)
    }
}
