import Foundation
import XCTest
@testable import PaletteCore

/// A palette edit must not ship unreadable text. `ThemeLoader.load` repairs
/// failing foregrounds, so every built-in has to pass this after loading.
final class ThemeContrastTests: XCTestCase {
    private let themesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("palette-theme-contrast-\(UUID().uuidString)", isDirectory: true)

    private func palette(_ name: String) throws -> ThemePalette {
        ThemeLoader.load(name: name, themesDirectory: themesDirectory).theme.palette
    }

    private func theme(_ name: String) -> Theme {
        ThemeLoader.load(name: name, themesDirectory: themesDirectory).theme
    }

    func testBuiltinThemesMeetContrast() throws {
        for name in ThemeLoader.builtinNames {
            let palette = try palette(name)
            let theme = theme(name)
            let bg = try XCTUnwrap(RGBA(hex: palette.bg), name)
            let fg = try XCTUnwrap(RGBA(hex: palette.fg), name)
            let muted = try XCTUnwrap(RGBA(hex: palette.fgMuted), name)
            let accent = try XCTUnwrap(RGBA(hex: palette.accent), name)
            let accentFg = try XCTUnwrap(RGBA(hex: palette.accentFg), name)
            let selectionBg = try XCTUnwrap(RGBA(hex: palette.selectionBg), name)
            let selectionFg = try XCTUnwrap(RGBA(hex: palette.selectionFg), name)
            let badgeBg = try XCTUnwrap(RGBA(hex: palette.badgeBg), name)
            let badgeFg = try XCTUnwrap(RGBA(hex: palette.badgeFg), name)

            XCTAssertGreaterThanOrEqual(bg.contrast(with: fg), 4.5, "\(name) body")
            XCTAssertGreaterThanOrEqual(accent.contrast(with: accentFg), 4.5, "\(name) accent")
            XCTAssertGreaterThanOrEqual(selectionBg.contrast(with: selectionFg), 4.5, "\(name) selection")
            XCTAssertGreaterThanOrEqual(badgeBg.contrast(with: badgeFg), 4.5, "\(name) badge")
            XCTAssertGreaterThanOrEqual(bg.contrast(with: muted), 3.0, "\(name) muted")
            if let selectedBg = theme.states.selected.bg.flatMap(RGBA.init(hex:)),
               let selectedFg = theme.states.selected.fg.flatMap(RGBA.init(hex:)) {
                XCTAssertGreaterThanOrEqual(selectedBg.contrast(with: selectedFg), 4.5, "\(name) selected row")
            }
        }
    }

    /// Bundled resource themes ship without a first-run copy, so every one has
    /// to resolve from the package resources and clear the same contrast bars.
    func testBundledThemesParseResolveAndMeetContrast() throws {
        let bundled = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
        let names = ThemeLoader.bundledThemeNames(themesDirectory: bundled)
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(Set(names).count, names.count, "bundled theme names must be unique")
        for name in names {
            XCTAssertTrue(name.hasPrefix("ghostty-") || name.hasPrefix("rex-"), "unprefixed name \(name)")
        }

        let catalogNames = ThemeLoader.catalog(themesDirectory: themesDirectory, bundledThemesDirectory: bundled).map(\.name)
        XCTAssertEqual(Set(catalogNames).count, catalogNames.count, "catalogue names must be unique")

        for name in names {
            let result = ThemeLoader.load(name: name, themesDirectory: themesDirectory, bundledThemesDirectory: bundled)
            XCTAssertTrue(result.diagnostics.filter { $0.level != .info }.isEmpty, "\(name): \(result.diagnostics)")
            let palette = result.theme.palette
            let bg = try XCTUnwrap(RGBA(hex: palette.bg), name)
            let fg = try XCTUnwrap(RGBA(hex: palette.fg), name)
            let muted = try XCTUnwrap(RGBA(hex: palette.fgMuted), name)
            let accent = try XCTUnwrap(RGBA(hex: palette.accent), name)
            let accentFg = try XCTUnwrap(RGBA(hex: palette.accentFg), name)
            let selectionBg = try XCTUnwrap(RGBA(hex: palette.selectionBg), name)
            let selectionFg = try XCTUnwrap(RGBA(hex: palette.selectionFg), name)
            let badgeBg = try XCTUnwrap(RGBA(hex: palette.badgeBg), name)
            let badgeFg = try XCTUnwrap(RGBA(hex: palette.badgeFg), name)

            XCTAssertGreaterThanOrEqual(bg.contrast(with: fg), 4.5, "\(name) body")
            XCTAssertGreaterThanOrEqual(accent.contrast(with: accentFg), 4.5, "\(name) accent")
            XCTAssertGreaterThanOrEqual(selectionBg.contrast(with: selectionFg), 4.5, "\(name) selection")
            XCTAssertGreaterThanOrEqual(badgeBg.contrast(with: badgeFg), 4.5, "\(name) badge")
            XCTAssertGreaterThanOrEqual(bg.contrast(with: muted), 3.0, "\(name) muted")
        }
    }

    func testUserThemeOverridesBundledTheme() throws {
        let bundled = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
        let override = themesDirectory.appendingPathComponent("ghostty-dracula.toml")
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: themesDirectory) }
        try """
        name = "My Dracula"
        appearance = "dark"
        [palette]
        bg = "#000000"
        """.write(to: override, atomically: true, encoding: .utf8)

        let loaded = ThemeLoader.load(name: "ghostty-dracula", themesDirectory: themesDirectory, bundledThemesDirectory: bundled)
        XCTAssertEqual(loaded.theme.name, "My Dracula")
        XCTAssertEqual(loaded.theme.palette.bg, "#000000")
        let info = ThemeLoader.catalog(themesDirectory: themesDirectory, bundledThemesDirectory: bundled)
            .first { $0.name == "ghostty-dracula" }
        XCTAssertEqual(info?.displayName, "My Dracula")
        XCTAssertEqual(info?.isBuiltin, false)
    }

    func testAuthoredPassingPairsAreKept() throws {
        // Catppuccin Mocha's accent pair passes as authored, so correction must
        // not churn it.
        let palette = try palette("catppuccin-mocha")
        XCTAssertEqual(palette.accentFg, "#1e1e2e")
    }

    func testFailingAccentPairsAreRepaired() throws {
        // Both ship white on a bright accent; the loader must replace it.
        for name in ["siri-silver", "gruvbox-light"] {
            let palette = try palette(name)
            XCTAssertNotEqual(palette.accentFg, "#ffffff", name)
            let accent = try XCTUnwrap(RGBA(hex: palette.accent), name)
            let fg = try XCTUnwrap(RGBA(hex: palette.accentFg), name)
            XCTAssertGreaterThanOrEqual(accent.contrast(with: fg), 4.5, name)
        }
    }
}
