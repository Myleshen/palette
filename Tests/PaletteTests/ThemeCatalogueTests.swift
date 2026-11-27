import Foundation
import TOMLKit
import XCTest
import PaletteCore

/// The 2.20.0 catalogue guarantees, checked against the files that ship:
/// 69 families with a dark and a light variant each, every kept file loads,
/// clears the contrast bars from `ThemeContrastThresholds` and keeps its UI
/// roles visibly apart, ANSI red and green stay apart, and every pruned id
/// still resolves to a theme that loads.
final class ThemeCatalogueTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    private var userThemes: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.fileExists(atPath: resources.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        userThemes = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-catalogue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: userThemes, withIntermediateDirectories: true)
        defaultsSuite = "palette-catalogue-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw XCTSkip("no user defaults suite")
        }
        self.defaults = defaults
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: userThemes)
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var keptIDs: Set<String> {
        Set(ThemeCuration.families.flatMap { [$0.dark, $0.light] })
    }

    private var bundledFiles: Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".toml") }.map { String($0.dropLast(5)) })
    }

    private func load(_ id: String) -> ThemeLoadResult {
        ThemeLoader.load(name: id, themesDirectory: userThemes, bundledThemesDirectory: resources)
    }

    private func table(_ id: String) throws -> TOMLTable {
        let text = try String(
            contentsOf: resources.appendingPathComponent("\(id).toml"),
            encoding: .utf8
        )
        return try TOMLTable(string: text)
    }

    private func favourites() -> ThemeCardFavourites {
        ThemeCardFavourites(defaults: defaults)
    }

    /// OKLab distance, the same measure `ThemeContrastRepair` uses for hue
    /// drift, scaled x100 so a just-noticeable difference is about 2.
    private func deltaE(_ first: String, _ second: String) -> Double {
        func lab(_ hex: String) -> (Double, Double, Double) {
            let digits = Array(hex.dropFirst())
            func channel(_ index: Int) -> Double {
                Double(Int(String(digits[index..<index + 2]), radix: 16) ?? 0) / 255
            }
            func linear(_ value: Double) -> Double {
                value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let r = linear(channel(0)), g = linear(channel(2)), b = linear(channel(4))
            let l = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b)
            let m = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b)
            let s = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b)
            return (
                0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
                1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
                0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s
            )
        }
        let a = lab(first), b = lab(second)
        return 100 * sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2))
    }

    private func ratio(_ foreground: String, _ background: String) throws -> Double {
        try XCTUnwrap(RGBA(hex: foreground)).contrast(with: try XCTUnwrap(RGBA(hex: background)))
    }

    // MARK: - Catalogue shape

    func testEveryFamilyShipsBothAppearances() {
        for family in ThemeCuration.families {
            XCTAssertNotEqual(family.dark, family.light, family.name)
            XCTAssertTrue(bundledFiles.contains(family.dark), family.dark)
            XCTAssertTrue(bundledFiles.contains(family.light), family.light)
            XCTAssertEqual(load(family.dark).theme.appearance, "dark", family.dark)
            XCTAssertEqual(load(family.light).theme.appearance, "light", family.light)
        }
        XCTAssertEqual(bundledFiles, keptIDs, "no orphan or missing theme file")
    }

    func testEveryKeptFileParsesWithRequiredSlots() throws {
        let required = [
            "bg", "surface", "elevated", "fg", "fg_muted", "accent", "accent_fg",
            "selection_bg", "selection_fg", "match_fg", "border", "separator",
            "danger", "warning", "success", "info", "badge_bg", "badge_fg",
        ]
        for id in keptIDs.sorted() {
            let table = try table(id)
            XCTAssertFalse(table.str("name")?.isEmpty ?? true, "\(id) name")
            XCTAssertNotNil(table.str("appearance"), "\(id) appearance")
            let palette = try XCTUnwrap(table.table("palette"), "\(id) [palette]")
            for key in required {
                let value = try XCTUnwrap(palette.str(key), "\(id) missing \(key)")
                XCTAssertNotNil(RGBA(hex: value), "\(id) \(key) is not a hex colour: \(value)")
            }
            XCTAssertNotNil(table.table("states")?.table("selected")?.str("bg"), "\(id) selected bg")
            XCTAssertNotNil(table.table("states")?.table("selected")?.str("fg"), "\(id) selected fg")
        }
    }

    func testCatalogueHasNoDuplicateIDsOrDisplayNames() throws {
        var names: [String: String] = [:]
        for id in bundledFiles {
            let display = try table(id).str("name") ?? id
            if let other = names[display] {
                XCTFail("\(id) and \(other) share the display name \(display)")
            }
            names[display] = id
        }
    }

    // MARK: - Contrast and ANSI

    func testEveryKeptThemeClearsContrastThresholds() throws {
        for id in keptIDs.sorted() {
            var diagnostics: [Diagnostic] = []
            let table = try table(id)
            var theme = ThemeLoader.parse(
                table,
                name: id,
                base: themeBase(for: table),
                diagnostics: &diagnostics
            )
            let report = ThemeContrastRepair.repair(&theme)
            XCTAssertTrue(report.changes.isEmpty, "\(id) needed repair: \(report.changes.map(\.field))")

            let palette = theme.palette
            XCTAssertGreaterThanOrEqual(
                try ratio(palette.fg, palette.bg), ThemeContrastThresholds.body, "\(id) body"
            )
            XCTAssertGreaterThanOrEqual(
                try ratio(palette.fgMuted, palette.bg), ThemeContrastThresholds.muted, "\(id) muted"
            )
            XCTAssertGreaterThanOrEqual(
                try ratio(palette.accent, palette.bg), ThemeContrastThresholds.accent, "\(id) accent"
            )
            XCTAssertGreaterThanOrEqual(
                try ratio(palette.accentFg, palette.accent),
                ThemeContrastThresholds.accentFg, "\(id) accent text"
            )
            XCTAssertGreaterThanOrEqual(
                try ratio(palette.selectionFg, palette.selectionBg),
                ThemeContrastThresholds.selection, "\(id) selection"
            )
            XCTAssertGreaterThanOrEqual(
                try ratio(palette.badgeFg, palette.badgeBg), ThemeContrastThresholds.badge, "\(id) badge"
            )
            for (value, label) in [
                (palette.danger, "danger"), (palette.warning, "warning"),
                (palette.success, "success"), (palette.info, "info"),
            ] {
                XCTAssertGreaterThanOrEqual(
                    try ratio(value, palette.bg), ThemeContrastThresholds.semantic, "\(id) \(label)"
                )
            }
        }
    }

    func testANSIOnBackgroundStaysReadable() throws {
        for id in keptIDs.sorted() {
            let theme = load(id).theme
            let ansi = PalettePalette(theme: theme).ansi
            let background = try XCTUnwrap(RGBA(hex: theme.palette.bg))
            for index in [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] {
                let colour = try XCTUnwrap(RGBA(hex: ansi[index]), "\(id) ansi\(index)")
                // PalettePalette.ansi floors every text slot at 2.5:1.
                XCTAssertGreaterThanOrEqual(colour.contrast(with: background), 2.5, "\(id) ansi\(index)")
            }
        }
    }

    /// A port can clear every contrast bar and still be hard to read because
    /// two roles are the same grey. These are the usability floors for the
    /// curated set; a theme that cannot meet them is dropped, not shipped.
    func testEveryKeptThemeKeepsRolesDistinct() throws {
        for id in keptIDs.sorted() {
            let p = load(id).theme.palette
            XCTAssertGreaterThanOrEqual(deltaE(p.fg, p.fgMuted), 12, "\(id) fg vs muted")
            XCTAssertGreaterThanOrEqual(deltaE(p.fgMuted, p.border), 8, "\(id) muted vs border")
            XCTAssertGreaterThanOrEqual(deltaE(p.accent, p.fg), 15, "\(id) accent vs fg")
            XCTAssertGreaterThanOrEqual(deltaE(p.accent, p.selectionBg), 8, "\(id) accent vs selection bg")
            XCTAssertGreaterThanOrEqual(deltaE(p.elevated, p.surface), 1.5, "\(id) elevated vs surface")

            let surface = deltaE(p.surface, p.bg)
            XCTAssertGreaterThanOrEqual(surface, 1.5, "\(id) surface vs bg")
            XCTAssertLessThanOrEqual(surface, 12, "\(id) surface vs bg")

            XCTAssertGreaterThanOrEqual(deltaE(p.selectionFg, p.selectionBg), 12, "\(id) selection fg vs bg")
            XCTAssertGreaterThanOrEqual(try ratio(p.selectionFg, p.selectionBg), 4.5, "\(id) selection contrast")
        }
    }

    func testRedAndGreenNeverCollapse() throws {
        for id in keptIDs.sorted() {
            let ansi = PalettePalette(theme: load(id).theme).ansi
            XCTAssertGreaterThanOrEqual(deltaE(ansi[1], ansi[2]), 5, "\(id) ansi1 vs ansi2")
            XCTAssertGreaterThanOrEqual(deltaE(ansi[9], ansi[10]), 5, "\(id) ansi9 vs ansi10")
        }
    }

    private func themeBase(for table: TOMLTable) -> Theme {
        table.str("appearance")?.lowercased() == "light" ? .defaultLight : .defaultDark
    }

    // MARK: - Migration

    func testEveryPrunedIDResolvesToAThemeThatShips() {
        for (pruned, kept) in ThemeCuration.pruned {
            XCTAssertFalse(bundledFiles.contains(pruned), "\(pruned) is both pruned and bundled")
            if kept.hasPrefix("default-") {
                XCTAssertTrue(ThemeLoader.builtinNames.contains(kept), "\(pruned) -> \(kept)")
            } else {
                XCTAssertTrue(keptIDs.contains(kept), "\(pruned) -> \(kept)")
                let result = load(kept)
                XCTAssertFalse(result.theme.name.isEmpty, kept)
            }
        }
    }

    func testMigrationRewritesPrunedConfigReferences() {
        var config = PaletteConfig()
        config.theme.dark = "ghostty-dracula"
        config.theme.light = "ghostty-catppuccin-frappe"
        config.theming.theme = "ghostty-tokyonight-storm"

        let notes = ThemeCuration.migrate(
            &config,
            themesDirectory: userThemes,
            bundledThemesDirectory: resources,
            favourites: favourites()
        )

        XCTAssertEqual(config.theme.dark, "default-dark", "a dropped family falls back to the default")
        XCTAssertEqual(config.theme.light, "ghostty-catppuccin-mocha")
        XCTAssertEqual(config.theming.theme, "ghostty-tokyonight")
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes.contains { $0.contains("no curated sibling") }, "the fallback is named")
    }

    func testMigrationMovesThemeFavouritesAndKeepsWallpaperCards() {
        let store = favourites()
        store.save(["theme:ghostty-tokyonight-storm", "theme:ghostty-tokyonight", "wallpaper-file:/tmp/a.png"])

        var config = PaletteConfig()
        _ = ThemeCuration.migrate(
            &config,
            themesDirectory: userThemes,
            bundledThemesDirectory: resources,
            favourites: store
        )

        let keys = favourites().keys
        XCTAssertTrue(keys.contains("theme:ghostty-tokyonight"))
        XCTAssertFalse(keys.contains("theme:ghostty-tokyonight-storm"))
        XCTAssertTrue(keys.contains("wallpaper-file:/tmp/a.png"))
    }

    func testMigrationKeepsAUserThemeWithAPrunedName() throws {
        let text = try String(contentsOf: resources.appendingPathComponent("ghostty-nord.toml"), encoding: .utf8)
        try text.write(to: userThemes.appendingPathComponent("ghostty-dracula.toml"), atomically: true, encoding: .utf8)
        var config = PaletteConfig()
        config.theme.dark = "ghostty-dracula"

        let notes = ThemeCuration.migrate(
            &config,
            themesDirectory: userThemes,
            bundledThemesDirectory: resources,
            favourites: favourites()
        )

        XCTAssertEqual(config.theme.dark, "ghostty-dracula")
        XCTAssertTrue(notes.isEmpty)
    }

    func testMigrationIsIdempotentAndIgnoresUnknownIDs() {
        var config = PaletteConfig()
        config.theme.dark = "ghostty-dracula"
        config.theme.light = "a-theme-the-user-removed"
        let first = ThemeCuration.migrate(
            &config, themesDirectory: userThemes, bundledThemesDirectory: resources, favourites: favourites()
        )
        let second = ThemeCuration.migrate(
            &config, themesDirectory: userThemes, bundledThemesDirectory: resources, favourites: favourites()
        )

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(config.theme.light, "a-theme-the-user-removed", "an unresolvable id is left alone")
    }
}
