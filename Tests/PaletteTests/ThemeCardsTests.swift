import XCTest
@testable import PaletteCore
import PalettePlatform
import TOMLKit

final class ThemeCardsTests: XCTestCase {
    private var themesDirectory: URL!

    override func setUpWithError() throws {
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-theme-cards-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: themesDirectory)
    }

    private func info(_ name: String, _ displayName: String, builtin: Bool = true) -> ThemeInfo {
        ThemeInfo(name: name, displayName: displayName, appearance: "dark", isBuiltin: builtin)
    }

    /// Deliberately handed over out of order: the deck must still walk the
    /// browser's sections Built-in → Ghostty → Omarchy → Custom.
    private var sampleCatalog: ThemeBrowserCatalog {
        ThemeBrowserCatalog(themes: [
            info("my-blue", "My Blue", builtin: false),
            info("omarchy-nord", "Omarchy · Nord"),
            info("ghostty-dracula", "Ghostty · Dracula"),
            info("catppuccin-mocha", "Catppuccin Mocha"),
            info("omarchy-tokyo-night", "Omarchy · Tokyo Night"),
            info("ghostty-nord", "Ghostty · Nord"),
            info("siri-silver", "Siri Silver"),
        ])
    }

    func testWallpaperCardComesFirstThenSectionsInOrder() {
        let deck = ThemeCardDeck(catalog: sampleCatalog)
        XCTAssertEqual(deck.cards.first, .wallpaper)
        XCTAssertNil(deck.cards.first?.themeID)
        XCTAssertEqual(
            deck.cards.dropFirst().map(\.sectionTitle),
            ["Built-in", "Built-in", "Ghostty", "Ghostty", "Omarchy", "Omarchy", "Custom"]
        )
        XCTAssertEqual(
            deck.cards.dropFirst().map(\.displayName),
            [
                "Catppuccin Mocha", "Siri Silver",
                "Ghostty · Dracula", "Ghostty · Nord",
                "Omarchy · Nord", "Omarchy · Tokyo Night",
                "My Blue",
            ]
        )
    }

    func testMovementWrapsAtBothEnds() {
        var deck = ThemeCardDeck(catalog: sampleCatalog)
        XCTAssertEqual(deck.current.id, "catppuccin-mocha")

        deck.move(by: -1)
        XCTAssertEqual(deck.current.id, "my-blue")
        XCTAssertEqual(deck.next.id, "catppuccin-mocha")

        deck.move(by: 1)
        XCTAssertEqual(deck.current.id, "catppuccin-mocha")

        deck.jumpToLast()
        XCTAssertEqual(deck.current.id, "my-blue")
        deck.move(by: 1)
        XCTAssertEqual(deck.current.id, "catppuccin-mocha")

        deck.move(by: -2)
        XCTAssertEqual(deck.current.id, "omarchy-tokyo-night")
    }

    func testOpeningSelectsTheCurrentTheme() {
        let deck = ThemeCardDeck(catalog: sampleCatalog, currentTheme: "Ghostty · Dracula")
        XCTAssertEqual(deck.current.id, "ghostty-dracula")

        let idDeck = ThemeCardDeck(catalog: sampleCatalog, currentTheme: "omarchy-nord")
        XCTAssertEqual(idDeck.current.id, "omarchy-nord")

        let missing = ThemeCardDeck(catalog: sampleCatalog, currentTheme: "not-in-the-catalogue")
        XCTAssertEqual(
            missing.current.id,
            "catppuccin-mocha",
            "an unknown current theme opens on the first theme, never a wallpaper"
        )
    }

    func testDisplayNameResolvesToThemeID() {
        let deck = ThemeCardDeck(catalog: sampleCatalog)
        XCTAssertEqual(deck.themeID(forDisplay: "Ghostty · Dracula"), "ghostty-dracula")
        XCTAssertEqual(deck.themeID(forDisplay: "ghostty-dracula"), "ghostty-dracula")
        XCTAssertEqual(deck.themeID(forDisplay: "My Blue"), "my-blue")
        XCTAssertNil(deck.themeID(forDisplay: "No Such Theme"))

        var selected = ThemeCardDeck(catalog: sampleCatalog, currentTheme: "Ghostty · Dracula")
        XCTAssertEqual(selected.current.target, .theme("ghostty-dracula"))
        selected.jumpToFirst()
        XCTAssertEqual(selected.current.target, .theme("catppuccin-mocha"))
    }

    func testEightBrightestANSIDotsKeepANSIOrder() {
        let ramp = (0..<16).map { String(format: "#%02x%02x%02x", $0 * 16, $0 * 16, $0 * 16) }
        let palette = ThemeCardPalette(
            appearance: "dark",
            background: ramp[0],
            foreground: ramp[15],
            accent: ramp[12],
            selection: ramp[8],
            ansi: ramp
        )
        XCTAssertEqual(palette.brightestANSI, Array(ramp[8...15]))
        XCTAssertEqual(palette.brightestANSI.count, 8)
    }

    func testThemeGalleryHotkeyConfigRoundTrip() throws {
        XCTAssertEqual(PaletteConfig().themeGalleryHotkey, "cmd+opt+g")
        XCTAssertEqual(PaletteConfig().wallpaperGalleryHotkey, "cmd+opt+w")

        var config = PaletteConfig()
        config.themeGalleryHotkey = "ctrl+alt+g"
        config.wallpaperGalleryHotkey = "ctrl+alt+w"
        let rendered = ConfigWriter.render(config)
        XCTAssertTrue(rendered.contains("theme_gallery_hotkey = \"ctrl+alt+g\""))
        XCTAssertTrue(rendered.contains("wallpaper_gallery_hotkey = \"ctrl+alt+w\""))

        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(
            TOMLTable(string: rendered),
            diagnostics: &diagnostics
        )
        XCTAssertEqual(parsed.themeGalleryHotkey, "ctrl+alt+g")
        XCTAssertEqual(parsed.wallpaperGalleryHotkey, "ctrl+alt+w")
        XCTAssertTrue(diagnostics.isEmpty)

        var disabled = config
        disabled.themeGalleryHotkey = ""
        disabled.wallpaperGalleryHotkey = ""
        let disabledParsed = try ConfigLoader.parse(
            TOMLTable(string: ConfigWriter.render(disabled)),
            diagnostics: &diagnostics
        )
        XCTAssertTrue(disabledParsed.themeGalleryHotkey.isEmpty)
        XCTAssertTrue(disabledParsed.wallpaperGalleryHotkey.isEmpty)
    }

    /// The gallery default must not lose to another default in the ordered
    /// plan, which is what a duplicate Carbon identity would do.
    func testDefaultHotkeysAreDistinct() {
        let config = PaletteConfig()
        let keys = [
            config.hotkey, config.clipboardHotkey, config.terminalHotkey,
            config.themeGalleryHotkey, config.wallpaperGalleryHotkey,
            config.scratchpadHotkey, config.askHotkey,
            config.screenshotHotkey, config.regionScreenshotHotkey,
            config.windowScreenshotHotkey, config.recordingHotkey,
        ]
        let identities = keys.compactMap { HotKeySpec.parse($0)?.identity }
        XCTAssertEqual(identities.count, keys.count)
        XCTAssertEqual(Set(identities).count, identities.count)
        XCTAssertEqual(HotKeySpec.parse(config.themeGalleryHotkey)?.prettyDisplay, "⌘⌥G")
        XCTAssertEqual(HotKeySpec.parse(config.wallpaperGalleryHotkey)?.prettyDisplay, "⌘⌥W")
    }

}
