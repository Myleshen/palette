import XCTest
@testable import PaletteCore

final class ThemeBrowserTests: XCTestCase {
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
            .appendingPathComponent("palette-theme-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: themesDirectory)
    }

    private func theme(_ name: String, _ displayName: String, builtin: Bool = true) -> ThemeInfo {
        ThemeInfo(name: name, displayName: displayName, appearance: "dark", isBuiltin: builtin)
    }

    private var sampleCatalog: ThemeBrowserCatalog {
        ThemeBrowserCatalog(themes: [
            theme("catppuccin-mocha", "Catppuccin Mocha"),
            theme("siri-silver", "Siri Silver"),
            theme("ghostty-dracula", "Ghostty · Dracula"),
            theme("ghostty-nord", "Ghostty · Nord"),
            theme("my-blue", "My Blue", builtin: false),
        ])
    }

    func testSectionsSplitSourcesAndKeepOrder() {
        let catalog = sampleCatalog
        XCTAssertEqual(catalog.sections.map(\.section), [.builtIn, .ghostty, .custom])
        XCTAssertEqual(catalog.sections.map(\.count), [2, 2, 1])
        XCTAssertEqual(catalog.sections[1].themes.map(\.name), ["ghostty-dracula", "ghostty-nord"])
    }

    func testSearchFiltersAcrossSectionsCaseInsensitively() {
        let catalog = sampleCatalog
        XCTAssertEqual(Set(catalog.filtered("CAT").flatMap(\.themes).map(\.name)),
                       ["catppuccin-mocha"])
        XCTAssertEqual(Set(catalog.filtered("dracula").flatMap(\.themes).map(\.name)),
                       ["ghostty-dracula"])
        // The canonical name without the Ghostty prefix also matches.
        XCTAssertEqual(Set(catalog.filtered("nord").flatMap(\.themes).map(\.name)),
                       ["ghostty-nord"])
        XCTAssertEqual(Set(catalog.filtered("my blue").flatMap(\.themes).map(\.name)),
                       ["my-blue"])
        // Sections with no match disappear.
        XCTAssertEqual(catalog.filtered("ghostty").map(\.section), [.ghostty])
        XCTAssertTrue(catalog.filtered("nothing-matches").isEmpty)
        XCTAssertEqual(catalog.filtered("   ").count, 3)
    }

    func testSelectionDoesNotMutateConfig() {
        let config = PaletteConfig()
        let before = config.theme
        var session = ThemeBrowserSession(catalog: sampleCatalog, selected: "catppuccin-mocha")

        session.query = "dracula"
        session.select("ghostty-dracula")

        XCTAssertEqual(config.theme, before)
        XCTAssertEqual(session.selected, "ghostty-dracula")
        XCTAssertEqual(session.visibleThemes.map(\.name), ["ghostty-dracula"])
    }

    func testUseThemeWritesTheActiveSlotAndKeepsMode() {
        let session = ThemeBrowserSession(catalog: sampleCatalog, selected: "ghostty-dracula")
        let original = ThemeSelection(mode: .dark, dark: "siri-graphite", light: "siri-silver")

        let dark = session.applying(to: original, activeAppearance: "dark")
        XCTAssertEqual(dark.mode, .dark)
        XCTAssertEqual(dark.dark, "ghostty-dracula")
        XCTAssertEqual(dark.light, "siri-silver")

        var lightMode = original
        lightMode.mode = .light
        XCTAssertEqual(session.applying(to: lightMode, activeAppearance: "dark").light, "ghostty-dracula")
        XCTAssertEqual(session.applying(to: lightMode, activeAppearance: "dark").dark, "siri-graphite")

        var auto = original
        auto.mode = .auto
        XCTAssertEqual(session.applying(to: auto, activeAppearance: "light").light, "ghostty-dracula")
        XCTAssertEqual(session.applying(to: auto, activeAppearance: "dark").dark, "ghostty-dracula")
        XCTAssertEqual(session.applying(to: auto, activeAppearance: "light").mode, .auto)
    }

    func testRevertRestoresThePreviewToTheCurrentTheme() {
        var session = ThemeBrowserSession(catalog: sampleCatalog, selected: "catppuccin-mocha")
        session.select("ghostty-dracula")
        session.markApplied()
        XCTAssertEqual(session.applied, "ghostty-dracula")

        session.revert(to: "Catppuccin Mocha")
        XCTAssertEqual(session.selected, "catppuccin-mocha")
        XCTAssertNil(session.applied)

        session.select("ghostty-nord")
        session.revert(to: "siri-silver")
        XCTAssertEqual(session.selected, "siri-silver")
    }

    func testArrowMovementFollowsTheFilteredRows() {
        var session = ThemeBrowserSession(catalog: sampleCatalog, selected: "catppuccin-mocha")
        XCTAssertEqual(session.selected, "catppuccin-mocha")
        session.moveSelection(by: 1)
        XCTAssertEqual(session.selected, "siri-silver")
        session.query = "ghostty"
        session.moveSelection(by: 1)
        XCTAssertEqual(session.selected, "ghostty-dracula")
        session.moveSelection(by: 1)
        XCTAssertEqual(session.selected, "ghostty-nord")
        session.moveSelection(by: 1)
        XCTAssertEqual(session.selected, "ghostty-nord", "the last row clamps")
        session.moveSelection(by: -1)
        XCTAssertEqual(session.selected, "ghostty-dracula")
    }

    func testOpeningTheBrowserDoesNotParseEveryTheme() throws {
        ThemeLoader.resetCachesForTesting()
        let catalog = ThemeLoader.catalog(
            themesDirectory: themesDirectory,
            bundledThemesDirectory: bundledDirectory
        )
        XCTAssertGreaterThan(catalog.count, 900)
        XCTAssertEqual(ThemeLoader.catalogCallCountForTesting, 1)
        XCTAssertEqual(ThemeLoader.fullParseCountForTesting, 0, "the catalogue reads headers only")

        let browser = ThemeBrowserCatalog(themes: catalog)
        let session = ThemeBrowserSession(catalog: browser, selected: "ghostty-dracula")
        let visible = Array(session.visibleThemes.prefix(12))
        XCTAssertGreaterThan(visible.count, 0)

        for info in visible {
            _ = ThemeLoader.load(
                name: info.name,
                themesDirectory: themesDirectory,
                bundledThemesDirectory: bundledDirectory
            )
        }
        if let selected = session.selected {
            _ = ThemeLoader.load(
                name: selected,
                themesDirectory: themesDirectory,
                bundledThemesDirectory: bundledDirectory
            )
        }

        XCTAssertLessThanOrEqual(ThemeLoader.fullParseCountForTesting, visible.count + 1)
        XCTAssertLessThan(ThemeLoader.fullParseCountForTesting, catalog.count)

        let parsed = ThemeLoader.fullParseCountForTesting
        for info in visible {
            _ = ThemeLoader.load(
                name: info.name,
                themesDirectory: themesDirectory,
                bundledThemesDirectory: bundledDirectory
            )
        }
        XCTAssertEqual(ThemeLoader.fullParseCountForTesting, parsed, "cached rows do not reparse")
    }

    func testFullParseCacheEvictsOldThemes() {
        ThemeLoader.resetCachesForTesting()
        let names = Array(ThemeLoader.bundledThemeNames(themesDirectory: bundledDirectory).prefix(60))
        XCTAssertEqual(names.count, 60)
        for name in names {
            _ = ThemeLoader.load(
                name: name,
                themesDirectory: themesDirectory,
                bundledThemesDirectory: bundledDirectory
            )
        }
        XCTAssertEqual(ThemeLoader.fullParseCountForTesting, 60)
        XCTAssertLessThanOrEqual(ThemeLoader.cachedThemeCountForTesting, 48)

        let before = ThemeLoader.fullParseCountForTesting
        _ = ThemeLoader.load(
            name: names[0],
            themesDirectory: themesDirectory,
            bundledThemesDirectory: bundledDirectory
        )
        XCTAssertEqual(ThemeLoader.fullParseCountForTesting, before + 1, "the oldest entry was evicted")
    }

    func testCatalogueBuildMeasurement() {
        ThemeLoader.resetCachesForTesting()
        var catalog: [ThemeInfo] = []
        let clock = ContinuousClock()
        let first = clock.measure {
            catalog = ThemeLoader.catalog(
                themesDirectory: themesDirectory,
                bundledThemesDirectory: bundledDirectory
            )
        }
        let second = clock.measure {
            _ = ThemeLoader.catalog(
                themesDirectory: themesDirectory,
                bundledThemesDirectory: bundledDirectory
            )
        }
        print("Theme browser catalogue first build: \(first) for \(catalog.count) themes; cached rebuild: \(second)")
        XCTAssertGreaterThan(catalog.count, 900)
    }
}
