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
