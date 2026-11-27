import AppKit
import PaletteCore
import SwiftTerm

/// The embedded terminal's colours, derived from the same palette every other
/// app receives. Pure mapping, so the theme → terminal contract is testable
/// without a running shell.
enum TerminalPalette {
    static func palette(for theme: Theme) -> PalettePalette {
        PalettePalette(theme: theme)
    }

    /// ANSI 0...15 as hex, exactly what the generated terminal files carry.
    static func ansiHex(for theme: Theme) -> [String] {
        palette(for: theme).ansi
    }

    static func ansiColors(for theme: Theme) -> [SwiftTerm.Color] {
        ansiHex(for: theme).compactMap { hex in
            guard let rgba = RGBA(hex: hex) else { return nil }
            return SwiftTerm.Color(
                red: UInt16((min(1, max(0, rgba.red)) * 65535).rounded()),
                green: UInt16((min(1, max(0, rgba.green)) * 65535).rounded()),
                blue: UInt16((min(1, max(0, rgba.blue)) * 65535).rounded())
            )
        }
    }

    /// Applies a new palette to a live view. SwiftTerm repaints native colours,
    /// ANSI slots, caret and selection, and the running session is untouched.
    @MainActor
    static func apply(_ theme: Theme, to terminal: LocalProcessTerminalView) {
        let palette = palette(for: theme)
        let ansi = ansiColors(for: theme)
        if ansi.count == 16 {
            terminal.installColors(ansi)
        }
        let background = theme.nsColor(palette.background)
        terminal.nativeBackgroundColor = background
        terminal.nativeForegroundColor = theme.nsColor(palette.foreground)
        terminal.caretColor = theme.nsColor(palette.cursor)
        terminal.selectedTextBackgroundColor = theme.nsColor(palette.selectionBackground)
        terminal.layer?.backgroundColor = background.cgColor
        TerminalColorProbe.record(view: terminal, palette: palette)
    }
}

/// What the live embedded terminal is actually showing, for scripted dumps.
/// A pane that was never opened reports no view and empty colours.
@MainActor
enum TerminalColorProbe {
    private static weak var terminal: LocalProcessTerminalView?
    private static var ansi: [String] = []

    static func record(view: LocalProcessTerminalView, palette: PalettePalette) {
        terminal = view
        ansi = palette.ansi
    }

    static func snapshot() -> [String: Any] {
        let view = terminal
        return [
            "live": view != nil,
            "background": view.map { hex($0.nativeBackgroundColor) } ?? "",
            "foreground": view.map { hex($0.nativeForegroundColor) } ?? "",
            // A dismantled pane keeps no palette: stale hex would let a script
            // believe a terminal is recolouring when none is on screen.
            "ansi": view == nil ? [] : ansi,
        ]
    }

    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
        func channel(_ value: CGFloat) -> Int {
            Int((min(1, max(0, value)) * 255).rounded())
        }
        return String(
            format: "#%02x%02x%02x",
            channel(rgb.redComponent),
            channel(rgb.greenComponent),
            channel(rgb.blueComponent)
        )
    }
}
