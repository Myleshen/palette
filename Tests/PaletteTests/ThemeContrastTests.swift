import Foundation
import XCTest
@testable import PaletteCore

/// A palette edit must not ship unreadable text. `ThemeLoader.load` repairs
/// every failing pair, so every built-in and bundled theme has to clear the
/// shared thresholds after loading, and the repair has to be idempotent.
final class ThemeContrastTests: XCTestCase {
    private let themesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("palette-theme-contrast-\(UUID().uuidString)", isDirectory: true)

    private var bundledThemes: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    private func load(_ name: String) -> ThemeLoadResult {
        ThemeLoader.load(name: name, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemes)
    }

    private func assertReadable(
        _ theme: Theme,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let palette = theme.palette
        let bg = try XCTUnwrap(RGBA(hex: palette.bg), name, file: file, line: line)

        func check(_ value: String, on backdrop: RGBA, minimum: Double, _ label: String) throws {
            let color = try XCTUnwrap(RGBA(hex: value), "\(name) \(label)", file: file, line: line)
            // A mid-tone background cannot reach every bar; the body bar is
            // capped at what that background physically allows.
            let target = min(minimum, ThemeContrastRepair.maximumContrast(on: backdrop))
            XCTAssertGreaterThanOrEqual(
                color.contrast(with: backdrop), target - 0.000_001,
                "\(name) \(label): \(value) on \(PalettePalette.hex(backdrop))",
                file: file, line: line
            )
        }

        try check(palette.fg, on: bg, minimum: ThemeContrastThresholds.body, "body")
        try check(palette.fgMuted, on: bg, minimum: ThemeContrastThresholds.muted, "muted")
        for surface in [palette.bg, palette.surface, palette.elevated] {
            let backdrop = try XCTUnwrap(RGBA(hex: surface), name, file: file, line: line)
            try check(palette.accent, on: backdrop, minimum: ThemeContrastThresholds.accent, "accent on \(surface)")
        }
        let accent = try XCTUnwrap(RGBA(hex: palette.accent), name, file: file, line: line)
        try check(palette.accentFg, on: accent, minimum: ThemeContrastThresholds.accentFg, "accent text")
        let selectionBg = try XCTUnwrap(RGBA(hex: palette.selectionBg), name, file: file, line: line)
        try check(palette.selectionFg, on: selectionBg, minimum: ThemeContrastThresholds.selection, "selection")
        let badgeBg = try XCTUnwrap(RGBA(hex: palette.badgeBg), name, file: file, line: line)
        try check(palette.badgeFg, on: badgeBg, minimum: ThemeContrastThresholds.badge, "badge")
        for (value, label) in [
            (palette.danger, "danger"), (palette.warning, "warning"),
            (palette.success, "success"), (palette.info, "info"),
        ] {
            try check(value, on: bg, minimum: ThemeContrastThresholds.semantic, label)
        }
        if let selectedBg = theme.states.selected.bg.flatMap(RGBA.init(hex:)),
           let selectedFg = theme.states.selected.fg {
            try check(selectedFg, on: selectedBg, minimum: ThemeContrastThresholds.selectedRow, "selected row")
        }
    }

    func testBuiltinThemesMeetContrast() throws {
        for name in ThemeLoader.builtinNames {
            let result = load(name)
            try assertReadable(result.theme, name: name)
            var again = result.theme
            XCTAssertTrue(
                ThemeContrastRepair.repair(&again).changes.isEmpty,
                "\(name) repair is not idempotent"
            )
        }
    }

    /// Bundled resource themes ship without a first-run copy, so every one has
    /// to resolve from the package resources and clear the same contrast bars.
    func testBundledThemesParseResolveAndMeetContrast() throws {
        let names = ThemeLoader.bundledThemeNames(themesDirectory: bundledThemes)
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(Set(names).count, names.count, "bundled theme names must be unique")
        for name in names {
            XCTAssertTrue(name.hasPrefix("ghostty-") || name.hasPrefix("omarchy-") || name.hasPrefix("rex-"), "unprefixed name \(name)")
        }

        let catalogNames = ThemeLoader.catalog(themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemes).map(\.name)
        XCTAssertEqual(Set(catalogNames).count, catalogNames.count, "catalogue names must be unique")

        for name in names {
            let result = ThemeLoader.load(name: name, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemes)
            XCTAssertTrue(result.diagnostics.filter { $0.level != .info }.isEmpty, "\(name): \(result.diagnostics)")
            try assertReadable(result.theme, name: name)
            var again = result.theme
            XCTAssertTrue(
                ThemeContrastRepair.repair(&again).changes.isEmpty,
                "\(name) repair is not idempotent"
            )
        }
    }

    /// Three authored values that failed before the repair. Each must clear
    /// its bar and keep its hue. The palettes are built in memory: the ports
    /// these came from were pruned in 2.20.0, but the values still pin the
    /// repair's behaviour.
    func testKnownFailingOriginalsAreRepaired() throws {
        let cases: [(label: String, field: String, original: String, backdrop: String, minimum: Double)] = [
            // Accent unreadable on the surface it is painted on.
            ("grass accent", "accent", "#0000a3", "#13773d", ThemeContrastThresholds.accent),
            // Muted text at 3.1:1, below the muted bar.
            ("latte muted", "fg_muted", "#85889a", "#eff1f5", ThemeContrastThresholds.muted),
            // Warning colour at 2.0:1, below the semantic bar.
            ("noctis warning", "warning", "#f49725", "#f2f1f8", ThemeContrastThresholds.semantic),
        ]

        for item in cases {
            let backdrop = try XCTUnwrap(RGBA(hex: item.backdrop), item.label)
            let original = try XCTUnwrap(RGBA(hex: item.original), item.label)
            XCTAssertLessThan(original.contrast(with: backdrop), item.minimum, "\(item.label) should fail")

            var seeded = Theme.defaultDark
            seeded.palette.bg = item.backdrop
            seeded.palette.surface = item.backdrop
            seeded.palette.elevated = item.backdrop
            set(item.field, to: item.original, in: &seeded)
            let report = ThemeContrastRepair.repair(&seeded)
            let change = try XCTUnwrap(report.changes.first { $0.field == item.field }, item.label)
            XCTAssertGreaterThanOrEqual(change.after, min(item.minimum, ThemeContrastRepair.maximumContrast(on: backdrop)) - 0.000_001)
            XCTAssertNotEqual(change.repaired, item.original, "\(item.label) was not corrected")
            XCTAssertLessThanOrEqual(change.hueShift, 10.0, "\(item.label) hue drift")
        }
    }

    /// A user theme gets the same repair as a bundled one, and the adjustment
    /// is surfaced instead of being silent.
    func testUserThemeIsRepairedWhenLoaded() throws {
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: themesDirectory) }
        try """
        name = "Bad Theme"
        appearance = "dark"
        [palette]
        bg = "#202020"
        fg = "#2a2a2a"
        fg_muted = "#303030"
        accent = "#303030"
        accent_fg = "#202020"
        selection_bg = "#303030"
        selection_fg = "#333333"
        badge_bg = "#303030"
        badge_fg = "#333333"
        danger = "#303030"
        warning = "#303030"
        success = "#303030"
        info = "#303030"
        """.write(to: themesDirectory.appendingPathComponent("bad-theme.toml"), atomically: true, encoding: .utf8)

        let result = ThemeLoader.load(name: "bad-theme", themesDirectory: themesDirectory, bundledThemesDirectory: nil)
        try assertReadable(result.theme, name: "bad-theme")
        XCTAssertTrue(
            result.diagnostics.contains { $0.level == .warning && $0.message.contains("fg") },
            "repair should log a diagnostic: \(result.diagnostics)"
        )
    }

    /// A background between black and white cannot reach 7:1. The repair goes
    /// to the best achievable foreground instead of failing silently.
    func testMidToneBackgroundUsesBestAchievableForeground() throws {
        var theme = Theme.defaultDark
        theme.palette.bg = "#808080"
        theme.palette.fg = "#808080"
        let report = ThemeContrastRepair.repair(&theme)
        let change = try XCTUnwrap(report.changes.first { $0.field == "fg" })
        let bg = try XCTUnwrap(RGBA(hex: "#808080"))
        let repaired = try XCTUnwrap(RGBA(hex: theme.palette.fg))
        let best = ThemeContrastRepair.maximumContrast(on: bg)

        XCTAssertLessThan(best, ThemeContrastThresholds.body)
        XCTAssertEqual(repaired.contrast(with: bg), best, accuracy: 0.001)
        XCTAssertEqual(change.after, best, accuracy: 0.001)
    }

    func testHueDriftStaysBoundedAcrossSaturatedColours() throws {
        let colors = ["#ff0000", "#ff8800", "#ffee00", "#33ff00", "#00ffcc", "#0088ff", "#5500ff", "#ff00cc"]
        for bg in ["#101010", "#f7f5ef"] {
            for color in colors {
                var theme = Theme.defaultDark
                theme.palette.bg = bg
                theme.palette.warning = color
                let report = ThemeContrastRepair.repair(&theme)
                guard let change = report.changes.first(where: { $0.field == "warning" }) else { continue }
                XCTAssertLessThanOrEqual(change.hueShift, 10.0, "\(color) on \(bg)")
            }
        }
    }

    func testRepairIsIdempotentForAuthoredFailures() {
        var theme = Theme.defaultDark
        theme.palette.bg = "#101010"
        theme.palette.fg = "#202020"
        theme.palette.fgMuted = "#252525"
        theme.palette.accent = "#303030"
        theme.palette.accentFg = "#101010"
        theme.palette.selectionBg = "#303030"
        theme.palette.selectionFg = "#202020"
        theme.palette.badgeBg = "#303030"
        theme.palette.badgeFg = "#202020"
        theme.palette.danger = "#303030"
        theme.palette.warning = "#303030"
        theme.palette.success = "#303030"
        theme.palette.info = "#303030"

        let first = ThemeContrastRepair.repair(&theme)
        XCTAssertFalse(first.changes.isEmpty)
        let second = ThemeContrastRepair.repair(&theme)
        XCTAssertTrue(second.changes.isEmpty, "\(second.changes)")
    }

    func testAuthoredPassingPairsAreKept() throws {
        // Catppuccin Mocha's accent pair passes as authored, so correction must
        // not churn it.
        let palette = load("catppuccin-mocha").theme.palette
        XCTAssertEqual(palette.accentFg, "#1e1e2e")
    }

    func testFailingAccentPairsAreRepaired() throws {
        // Both authored pairs fail. The repair may move the accent instead of
        // flipping the text, but the pair has to clear the bar afterwards.
        let authored: [(name: String, accent: String, accentFg: String)] = [
            ("siri-silver", "#5b7cfa", "#ffffff"),
            ("gruvbox-light", "#b57614", "#fbf1c7"),
        ]
        for item in authored {
            let accent = try XCTUnwrap(RGBA(hex: item.accent), item.name)
            let fg = try XCTUnwrap(RGBA(hex: item.accentFg), item.name)
            XCTAssertLessThan(accent.contrast(with: fg), ThemeContrastThresholds.accentFg, item.name)

            let palette = load(item.name).theme.palette
            let repairedAccent = try XCTUnwrap(RGBA(hex: palette.accent), item.name)
            let repairedFg = try XCTUnwrap(RGBA(hex: palette.accentFg), item.name)
            XCTAssertGreaterThanOrEqual(repairedAccent.contrast(with: repairedFg), ThemeContrastThresholds.accentFg, item.name)
        }
    }

    private func value(of field: String, in palette: ThemePalette) -> String {
        switch field {
        case "fg": return palette.fg
        case "fg_muted": return palette.fgMuted
        case "accent": return palette.accent
        case "accent_fg": return palette.accentFg
        case "selection_fg": return palette.selectionFg
        case "badge_fg": return palette.badgeFg
        case "danger": return palette.danger
        case "warning": return palette.warning
        case "success": return palette.success
        case "info": return palette.info
        default: return ""
        }
    }

    private func set(_ field: String, to value: String, in theme: inout Theme) {
        switch field {
        case "fg": theme.palette.fg = value
        case "fg_muted": theme.palette.fgMuted = value
        case "accent": theme.palette.accent = value
        case "accent_fg": theme.palette.accentFg = value
        case "selection_fg": theme.palette.selectionFg = value
        case "badge_fg": theme.palette.badgeFg = value
        case "danger": theme.palette.danger = value
        case "warning": theme.palette.warning = value
        case "success": theme.palette.success = value
        case "info": theme.palette.info = value
        default: break
        }
    }
}
