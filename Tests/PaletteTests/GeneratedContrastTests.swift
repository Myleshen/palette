import Foundation
import XCTest
@testable import PaletteCore

/// Pairs the generated terminal/editor files paint, which the theme palette
/// repair cannot see because the renderer chooses the foreground later.
final class GeneratedContrastTests: XCTestCase {
    private func ratio(_ fg: String, _ bg: String) throws -> Double {
        let foreground = try XCTUnwrap(RGBA(hex: fg))
        let background = try XCTUnwrap(RGBA(hex: bg))
        return foreground.contrast(with: background)
    }

    /// Neovim's Visual highlight used the body foreground, which is not the
    /// pair the loader validates. It has to use the selection pair.
    func testNvimVisualUsesSelectionPair() throws {
        var palette = PalettePalette(theme: .defaultDark)
        palette.selectionBackground = "#ffffff"
        palette.selectionForeground = "#1d1d20"
        let output = try XCTUnwrap(ThemingRenderer.contents(
            for: .nvim,
            palette: palette,
            metadata: PaletteMetadata(source: "theme", theme: "test", appearance: "dark")
        ))
        XCTAssertTrue(output.contains("Visual = { fg = p.selectionFg, bg = p.selection }"))
        XCTAssertGreaterThanOrEqual(
            try ratio(palette.selectionForeground, palette.selectionBackground),
            4.5
        )
    }

    /// Search puts text on the yellow ANSI slot. A mid-tone slot cannot carry
    /// either the background or white, so the renderer picks the readable one.
    func testNvimSearchPicksReadableText() throws {
        var palette = PalettePalette(theme: .defaultDark)
        palette.background = "#ffffff"
        palette.ansi[3] = "#808080"
        let output = try XCTUnwrap(ThemingRenderer.contents(
            for: .nvim,
            palette: palette,
            metadata: PaletteMetadata(source: "theme", theme: "test", appearance: "dark")
        ))
        let text = PalettePalette.hex(PalettePalette.bestText(on: try XCTUnwrap(RGBA(hex: palette.ansi[3]))))
        XCTAssertTrue(output.contains("Search = { fg = p.searchFg, bg = p.searchBg }"))
        XCTAssertTrue(output.contains("searchFg = \"\(text)\""))
        XCTAssertTrue(output.contains("searchBg = \"\(palette.ansi[3])\""))
        XCTAssertGreaterThanOrEqual(try ratio(text, palette.ansi[3]), 4.5)
    }

    /// Yazi's mode chips are the same trap: a fixed background colour with
    /// text borrowed from the body palette.
    func testYaziModesPickReadableText() throws {
        var palette = PalettePalette(theme: .defaultDark)
        palette.ansi[4] = "#808080"
        palette.ansi[3] = "#777777"
        palette.muted = "#6f6f6f"
        let output = try XCTUnwrap(ThemingRenderer.contents(
            for: .yazi,
            palette: palette,
            metadata: PaletteMetadata(source: "theme", theme: "test", appearance: "dark")
        ))
        for (key, background) in [("normal_main", palette.ansi[4]),
                                  ("select_main", palette.ansi[3]),
                                  ("unset_main", palette.muted)] {
            let text = try chipText(background)
            XCTAssertTrue(
                output.contains("\(key) = { fg = \"\(text)\", bg = \"\(background)\""),
                "\(key) should use \(text) on \(background)"
            )
            XCTAssertGreaterThanOrEqual(try ratio(text, background), 4.5)
        }
    }

    /// Delta's emphasis style used to paint only a background, leaving the
    /// terminal's foreground on it. It now names both sides of the pair.
    func testDeltaEmphasisNamesBothSides() throws {
        var palette = PalettePalette(theme: .defaultDark)
        palette.ansi[1] = "#808080"
        palette.ansi[2] = "#777777"
        let output = try XCTUnwrap(ThemingRenderer.contents(
            for: .delta,
            palette: palette,
            metadata: PaletteMetadata(source: "theme", theme: "test", appearance: "dark")
        ))
        for (key, background) in [("minus-emph-style", palette.ansi[1]),
                                  ("plus-emph-style", palette.ansi[2])] {
            let text = try chipText(background)
            XCTAssertTrue(output.contains("\(key) = normal \"\(text)\" \"\(background)\""))
            XCTAssertGreaterThanOrEqual(try ratio(text, background), 4.5)
        }
    }

    private func chipText(_ background: String) throws -> String {
        let color = try XCTUnwrap(RGBA(hex: background))
        let soft = PalettePalette.bestText(on: color)
        if soft.contrast(with: color) >= 4.5 { return PalettePalette.hex(soft) }
        let black = RGBA(red: 0, green: 0, blue: 0)
        let white = RGBA(red: 1, green: 1, blue: 1)
        return PalettePalette.hex(black.contrast(with: color) >= white.contrast(with: color) ? black : white)
    }
}
