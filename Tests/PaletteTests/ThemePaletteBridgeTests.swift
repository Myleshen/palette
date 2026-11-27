import XCTest
import PaletteCore

/// A palette that has no theme file — a wallpaper extraction or a cross-app
/// apply — still has to drive Palette's own theme, and the applied id has to
/// land in the slot that matches its appearance.
final class ThemePaletteBridgeTests: XCTestCase {
    func testThemeFromPaletteKeepsTheLauncherColours() {
        var source = Theme.defaultLight
        source.name = "Sand"
        source.palette.bg = "#f4efe6"
        source.palette.fg = "#2b2620"
        source.palette.accent = "#b05a2a"
        let palette = PalettePalette(theme: source)

        let theme = Theme(palette: palette)
        XCTAssertEqual(theme.name, "Sand")
        XCTAssertEqual(theme.appearance, "light")
        XCTAssertEqual(theme.palette.bg, palette.background)
        XCTAssertEqual(theme.palette.fg, palette.foreground)
        XCTAssertEqual(theme.palette.accent, palette.cursor)
        XCTAssertEqual(theme.palette.surface, palette.surface)
        XCTAssertEqual(theme.palette.elevated, palette.elevated)
        XCTAssertEqual(theme.palette.fgMuted, palette.muted)
        XCTAssertEqual(theme.palette.selectionBg, palette.selectionBackground)
        XCTAssertEqual(theme.palette.selectionFg, palette.selectionForeground)
        XCTAssertEqual(theme.palette.danger, palette.ansi[1])
        XCTAssertEqual(theme.palette.success, palette.ansi[2])
        XCTAssertEqual(theme.palette.warning, palette.ansi[3])
        XCTAssertEqual(theme.palette.info, palette.ansi[4])
        XCTAssertEqual(theme.window.material, "popover")
    }

    func testAppliedThemeWritesTheSlotForItsAppearance() {
        let selection = ThemeSelection(mode: .auto, dark: "gruvbox-dark", light: "gruvbox-light")

        let light = selection.applying(themeID: "solarized-light", appearance: "light")
        XCTAssertEqual(light.mode, .light)
        XCTAssertEqual(light.light, "solarized-light")
        XCTAssertEqual(light.dark, "gruvbox-dark")

        let dark = selection.applying(themeID: "solarized-dark", appearance: "dark")
        XCTAssertEqual(dark.mode, .dark)
        XCTAssertEqual(dark.dark, "solarized-dark")
        XCTAssertEqual(dark.light, "gruvbox-light")
    }
}
