import XCTest
@testable import PaletteCore
import PalettePlatform
import TOMLKit

final class ThemeCardsTests: XCTestCase {
    private var themesDirectory: URL!

    private var bundledDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

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
        XCTAssertEqual(deck.current.id, "wallpaper")

        deck.move(by: -1)
        XCTAssertEqual(deck.current.id, "my-blue")
        XCTAssertEqual(deck.next.id, "wallpaper")

        deck.move(by: 1)
        XCTAssertEqual(deck.current.id, "wallpaper")

        deck.jumpToLast()
        XCTAssertEqual(deck.current.id, "my-blue")
        deck.move(by: 1)
        XCTAssertEqual(deck.current.id, "wallpaper")

        deck.move(by: -2)
        XCTAssertEqual(deck.current.id, "omarchy-tokyo-night")
    }

    func testOpeningSelectsTheCurrentTheme() {
        let deck = ThemeCardDeck(catalog: sampleCatalog, currentTheme: "Ghostty · Dracula")
        XCTAssertEqual(deck.current.id, "ghostty-dracula")

        let idDeck = ThemeCardDeck(catalog: sampleCatalog, currentTheme: "omarchy-nord")
        XCTAssertEqual(idDeck.current.id, "omarchy-nord")

        let missing = ThemeCardDeck(catalog: sampleCatalog, currentTheme: "not-in-the-catalogue")
        XCTAssertEqual(missing.current.id, "wallpaper", "an unknown current theme opens on the wallpaper card")
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
        XCTAssertEqual(selected.current.target, .wallpaper)
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

        var config = PaletteConfig()
        config.themeGalleryHotkey = "ctrl+alt+g"
        let rendered = ConfigWriter.render(config)
        XCTAssertTrue(rendered.contains("theme_gallery_hotkey = \"ctrl+alt+g\""))

        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(
            TOMLTable(string: rendered),
            diagnostics: &diagnostics
        )
        XCTAssertEqual(parsed.themeGalleryHotkey, "ctrl+alt+g")
        XCTAssertTrue(diagnostics.isEmpty)

        var disabled = config
        disabled.themeGalleryHotkey = ""
        let disabledParsed = try ConfigLoader.parse(
            TOMLTable(string: ConfigWriter.render(disabled)),
            diagnostics: &diagnostics
        )
        XCTAssertTrue(disabledParsed.themeGalleryHotkey.isEmpty)
    }

    /// The gallery default must not lose to another default in the ordered
    /// plan, which is what a duplicate Carbon identity would do.
    func testDefaultHotkeysAreDistinct() {
        let config = PaletteConfig()
        let keys = [
            config.hotkey, config.clipboardHotkey, config.terminalHotkey,
            config.themeGalleryHotkey, config.scratchpadHotkey, config.askHotkey,
            config.screenshotHotkey, config.regionScreenshotHotkey,
            config.windowScreenshotHotkey, config.recordingHotkey,
        ]
        let identities = keys.compactMap { HotKeySpec.parse($0)?.identity }
        XCTAssertEqual(identities.count, keys.count)
        XCTAssertEqual(Set(identities).count, identities.count)
        XCTAssertEqual(HotKeySpec.parse(config.themeGalleryHotkey)?.prettyDisplay, "⌘⌥G")
    }

    /// The card list is metadata only, and the visible card plus its two
    /// neighbours are parsed once. A warm flip should not touch the disk.
    func testWarmFlipCostWith942Cards() throws {
        guard FileManager.default.fileExists(atPath: bundledDirectory.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        ThemeLoader.resetCachesForTesting()
        let clock = ContinuousClock()
        var catalog = ThemeBrowserCatalog(themes: [])
        let catalogTime = clock.measure {
            catalog = ThemeBrowserCatalog(
                themes: ThemeLoader.catalog(
                    themesDirectory: themesDirectory,
                    bundledThemesDirectory: bundledDirectory
                )
            )
        }
        XCTAssertGreaterThan(catalog.count, 900)

        var deck = ThemeCardDeck(catalog: catalog)
        let warmCards = [deck.previous, deck.current, deck.next]
        let coldTime = clock.measure {
            for card in warmCards {
                guard let name = card.themeID else { continue }
                _ = ThemeCardPalette(theme: ThemeLoader.load(
                    name: name,
                    themesDirectory: themesDirectory,
                    bundledThemesDirectory: bundledDirectory
                ).theme)
            }
        }

        let flips = 1_000
        var palettes: [String: ThemeCardPalette] = [:]
        for card in warmCards {
            guard let name = card.themeID else { continue }
            palettes[card.cacheKey] = ThemeCardPalette(theme: ThemeLoader.load(
                name: name,
                themesDirectory: themesDirectory,
                bundledThemesDirectory: bundledDirectory
            ).theme)
        }
        let flipTime = clock.measure {
            for _ in 0..<flips {
                deck.move(by: 1)
                _ = palettes[deck.current.cacheKey]
            }
        }

        let perFlip = seconds(flipTime) / Double(flips)
        print(
            "Theme cards: \(catalog.count) cards · catalogue "
                + "\(milliseconds(catalogTime)) ms · first 3 palettes "
                + "\(milliseconds(coldTime)) ms · warm flip \(ms(perFlip)) ms"
        )
        XCTAssertLessThan(perFlip, 0.001, "a warm flip is a dictionary lookup, not a parse")
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f", seconds(duration) * 1_000)
    }

    private func ms(_ value: Double) -> String {
        String(format: "%.4f", value * 1_000)
    }
}
