import AppKit
import SwiftTerm
import XCTest
import PaletteCore
@testable import PaletteApp

/// The embedded terminal gets its colours from the same palette the generated
/// terminal files carry. These checks pin the theme → terminal mapping and the
/// live recolour without starting a shell.
final class TerminalPaletteTests: XCTestCase {
    func testANSIMappingComesFromTheThemePalette() {
        var theme = Theme.defaultDark
        theme.palette.bg = "#101418"
        theme.palette.fg = "#e8e8e8"
        theme.palette.danger = "#ff5555"
        theme.palette.success = "#55cc55"
        theme.palette.accent = "#77aaff"

        let hex = TerminalPalette.ansiHex(for: theme)
        XCTAssertEqual(hex.count, 16)
        XCTAssertEqual(hex, PalettePalette(theme: theme).ansi)
        // Legible semantic hues land in their ANSI slots unmodified.
        XCTAssertEqual(hex[1], "#ff5555")
        XCTAssertEqual(hex[2], "#55cc55")
        XCTAssertEqual(TerminalPalette.palette(for: theme).background, "#101418")
        XCTAssertEqual(TerminalPalette.palette(for: theme).foreground, "#e8e8e8")
    }

    func testTwoThemesProduceDifferentANSISets() {
        XCTAssertNotEqual(
            TerminalPalette.ansiHex(for: .defaultDark),
            TerminalPalette.ansiHex(for: .defaultLight)
        )
    }

    /// A running pane must take the new palette in place: same view, new
    /// colours, no session teardown.
    @MainActor
    func testLiveViewRecoloursInPlace() {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalPalette.apply(.defaultDark, to: view)
        let darkBackground = view.nativeBackgroundColor
        XCTAssertEqual(
            TerminalColorProbe.snapshot()["ansi"] as? [String],
            TerminalPalette.ansiHex(for: .defaultDark)
        )

        TerminalPalette.apply(.defaultLight, to: view)
        XCTAssertNotEqual(view.nativeBackgroundColor, darkBackground)
        XCTAssertEqual(
            TerminalColorProbe.snapshot()["ansi"] as? [String],
            TerminalPalette.ansiHex(for: .defaultLight)
        )
        XCTAssertEqual(
            TerminalColorProbe.snapshot()["live"] as? Bool,
            true
        )
    }
}
