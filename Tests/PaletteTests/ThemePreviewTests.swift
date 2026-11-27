import XCTest
@testable import PaletteCore
import PalettePlatform

/// The focused preview and the deck's two modes: routing, the wallpaper vs
/// theme content decision, Reduce Motion, per-mode filters/favourites and the
/// wallpaper-palette rule.
final class ThemePreviewTests: XCTestCase {
    private var root: URL!

    private var bundledDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func info(_ name: String, _ displayName: String) -> ThemeInfo {
        ThemeInfo(name: name, displayName: displayName, appearance: "dark", isBuiltin: true)
    }

    private var sampleCatalog: ThemeBrowserCatalog {
        ThemeBrowserCatalog(themes: [
            info("ghostty-dracula", "Ghostty · Dracula"),
            info("omarchy-nord", "Omarchy · Nord"),
            info("my-blue", "My Blue"),
        ])
    }

    private var wallpapers: [URL] {
        [
            root.appendingPathComponent("a-ridge.png"),
            root.appendingPathComponent("b-dunes.jpg"),
        ]
    }

    // MARK: - Preview state and keys

    private func command(
        _ keyCode: UInt16,
        _ characters: String? = nil,
        filterEmpty: Bool = true,
        previewing: Bool
    ) -> ThemeCardCommand? {
        ThemeCardKeyRoute.command(
            keyCode: keyCode,
            characters: characters,
            filterEmpty: filterEmpty,
            previewing: previewing
        )
    }

    func testPreviewOpensClosesAndFlipsInside() {
        // P and Space open from the fan.
        XCTAssertEqual(command(35, "p", previewing: false), .openPreview)
        XCTAssertEqual(command(49, " ", previewing: false), .openPreview)

        // Inside the preview the same keys collapse it; arrows flip and Return
        // still applies.
        XCTAssertEqual(command(35, "p", previewing: true), .closePreview)
        XCTAssertEqual(command(49, " ", previewing: true), .closePreview)
        XCTAssertEqual(command(123, previewing: true), .flip(-1))
        XCTAssertEqual(command(124, previewing: true), .flip(1))
        XCTAssertEqual(command(36, "\r", previewing: true), .apply)
        XCTAssertEqual(command(48, "\t", previewing: true), .toggleFavouritesView)
    }

    /// Esc peels one layer at a time: preview first, deck second.
    func testEscapeClosesThePreviewBeforeTheDeck() {
        XCTAssertEqual(command(53, previewing: true), .closePreview)
        XCTAssertEqual(command(53, previewing: false), .closeDeck)
    }

    /// `p` is a letter too: once a filter is being typed it must reach the
    /// filter, so Space is the always-available preview toggle there.
    func testPIsALetterWhileFiltering() {
        XCTAssertEqual(command(35, "p", filterEmpty: false, previewing: false), .appendFilter("p"))
        XCTAssertEqual(command(35, "p", filterEmpty: false, previewing: true), .appendFilter("p"))
        XCTAssertEqual(command(49, " ", filterEmpty: false, previewing: true), .closePreview)
        XCTAssertEqual(command(36, "\r", filterEmpty: false, previewing: true), .apply)
    }

    // MARK: - Content decision

    func testPreviewContentFollowsTheCardKind() {
        let theme = ThemeCard.theme(info("ghostty-dracula", "Ghostty · Dracula"))
        XCTAssertEqual(ThemeCardPreviewContent(card: theme), .palette)
        XCTAssertEqual(ThemeCardPreviewContent(card: .wallpaper), .picture)
        XCTAssertEqual(ThemeCardPreviewContent(card: .wallpaperFile(wallpapers[0])), .picture)
    }

    // MARK: - Reduce Motion

    func testReduceMotionSkipsTheGrowth() {
        let still = ThemeCardPreviewMotion.visual(progress: 0, reduceMotion: true)
        XCTAssertEqual(still.scale, 1)
        XCTAssertEqual(still.opacity, 1)

        let start = ThemeCardPreviewMotion.visual(progress: 0, reduceMotion: false)
        XCTAssertEqual(start.scale, ThemeCardPreviewMotion.startScale)
        XCTAssertEqual(start.opacity, 0)

        let end = ThemeCardPreviewMotion.visual(progress: 1, reduceMotion: false)
        XCTAssertEqual(end.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(end.opacity, 1, accuracy: 0.0001)
    }

    // MARK: - Modes

    private func deck(mode: ThemeCardMode = .colors) -> ThemeCardDeck {
        ThemeCardDeck(
            catalog: sampleCatalog,
            wallpapers: wallpapers,
            currentDesktop: wallpapers[0],
            mode: mode
        )
    }

    func testModesNeverMixThemesAndWallpapers() {
        var deck = deck()
        XCTAssertEqual(deck.mode, .colors)
        XCTAssertEqual(deck.count, 3)
        XCTAssertTrue(deck.visible.allSatisfy { !$0.isWallpaper })

        deck.mode = .wallpapers
        XCTAssertEqual(deck.selected, 0, "a mode switch starts at its first card")
        XCTAssertEqual(deck.count, 2)
        XCTAssertTrue(deck.visible.allSatisfy(\.isWallpaper))
        XCTAssertEqual(deck.current.displayName, "a-ridge.png")

        deck.mode = .colors
        XCTAssertEqual(deck.count, 3)
        XCTAssertNotNil(deck.current.themeID)
    }

    func testWallpaperFilterMatchesFileNamesCaseInsensitively() {
        var deck = deck(mode: .wallpapers)
        deck.query = "DUNES"
        XCTAssertEqual(deck.count, 1)
        XCTAssertEqual(deck.current.displayName, "b-dunes.jpg")

        deck.query = ".jpg"
        XCTAssertEqual(deck.count, 1)

        deck.query = "ridge"
        XCTAssertEqual(deck.count, 1)
        XCTAssertEqual(deck.current.wallpaperPath, wallpapers[0].path)
    }

    func testFilterAndFavouritesStayInsideTheMode() {
        var deck = deck()
        deck.query = "nord"
        XCTAssertEqual(deck.count, 1, "a theme filter finds themes in Colors mode")

        deck.query = ""
        deck.jumpToFirst()
        let favouriteName = deck.current.displayName
        deck.toggleFavourite()
        XCTAssertTrue(deck.isCurrentFavourite)

        deck.mode = .wallpapers
        deck.favouritesOnly = true
        XCTAssertEqual(deck.count, 0, "the theme favourite is not a wallpaper favourite")

        deck.mode = .colors
        deck.favouritesOnly = true
        XCTAssertEqual(deck.count, 1)
        XCTAssertEqual(deck.current.displayName, favouriteName)
    }

    func testWallpaperModeKeepsTheFromWallpaperCardWhenTheFolderIsEmpty() {
        let empty = ThemeCardDeck(catalog: sampleCatalog, wallpapers: [], mode: .wallpapers)
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(empty.current, .wallpaper)
    }

    // MARK: - Lazy work

    /// The preview renders the front card, which is already one of the cards
    /// the fan parsed; opening it adds no parse, and a preview flip parses the
    /// same single neighbour a fan flip does.
    func testPreviewKeepsTheFanParseWindow() {
        var deck = deck()
        var parsed = Set(deck.fanWindow(reach: 3).map(\.card.cacheKey))
        XCTAssertEqual(parsed.count, 3, "3 themes: the whole hand fits")

        // Opening on the card in front reads no new key.
        parsed.insert(deck.current.cacheKey)
        XCTAssertEqual(parsed.count, 3)

        let next = deck.next.cacheKey
        deck.move(by: 1)
        parsed.insert(deck.current.cacheKey)
        XCTAssertEqual(deck.current.cacheKey, next, "the preview flip lands on the neighbour")
        XCTAssertTrue(parsed.contains(next))
    }

    // MARK: - Wallpaper apply rule

    @MainActor
    func testWallpaperPaletteRunsOnlyWhenEnabledAndSamplingWallpaper() {
        var config = ThemingConfig()
        config.enabled = false
        config.source = .wallpaper
        XCTAssertFalse(ThemingEngine.shouldApplyWallpaperCard(config))

        config.enabled = true
        config.source = .theme
        XCTAssertFalse(
            ThemingEngine.shouldApplyWallpaperCard(config),
            "source = theme: a card changes the picture, not the palette"
        )

        config.source = .wallpaper
        XCTAssertTrue(ThemingEngine.shouldApplyWallpaperCard(config))
    }

}
