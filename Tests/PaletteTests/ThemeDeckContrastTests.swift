import Foundation
import XCTest
@testable import PaletteApp
@testable import PaletteCore

/// Every label the deck draws has to clear WCAG 1.4.3 as it is actually
/// rendered: the repair only guarantees the theme's own pairs at full opacity,
/// so each role below is composited through the alpha the view uses. Roles on a
/// picture are measured over a white image, the worst case for white text.
final class ThemeDeckContrastTests: XCTestCase {
    private let themesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("palette-deck-contrast-\(UUID().uuidString)", isDirectory: true)

    private var bundledThemes: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    private func over(_ top: RGBA, _ bottom: RGBA, _ alpha: Double) -> RGBA {
        RGBA(
            red: top.red * alpha + bottom.red * (1 - alpha),
            green: top.green * alpha + bottom.green * (1 - alpha),
            blue: top.blue * alpha + bottom.blue * (1 - alpha)
        )
    }

    private func rgb(_ hex: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> RGBA {
        try XCTUnwrap(RGBA(hex: hex), "\(name): \(hex)", file: file, line: line)
    }

    func testDeckLabelsClearWCAGOnEveryTheme() throws {
        let names = Set(ThemeLoader.bundledThemeNames(themesDirectory: bundledThemes) + ThemeLoader.builtinNames)
        XCTAssertGreaterThan(names.count, 100, "the theme catalogue did not load")

        let white = RGBA(red: 1, green: 1, blue: 1)
        let black = RGBA(red: 0, green: 0, blue: 0)
        var failures: [String] = []
        var worst: (role: String, theme: String, ratio: Double)?

        for name in names.sorted() {
            let theme = ThemeLoader.load(name: name, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemes).theme
            let palette = theme.palette
            let card = ThemeCardPalette(theme: theme)
            let bg = try rgb(palette.bg, name)
            let fg = try rgb(card.foreground, name)
            let muted = try rgb(palette.fgMuted, name)
            let accent = try rgb(card.accent, name)
            let surface = try rgb(palette.surface, name)
            let elevated = try rgb(palette.elevated, name)

            // The deck chrome sits on `bg`; the filter and unlit chips are the
            // theme's `elevated` laid over it.
            let field = over(elevated, bg, ThemeDeckInk.fieldFill)
            let chip = over(elevated, bg, ThemeDeckInk.chipFill)
            // Theme cards and the focused preview use the card's own `bg`.
            let cardBg = try rgb(card.background, name)

            func check(_ role: String, _ text: RGBA, _ background: RGBA, minimum: Double = 4.5) {
                let ratio = text.contrast(with: background)
                if ratio < minimum - 0.000_001 {
                    failures.append(String(format: "%@ on %@: %@ %.2f:1", name, background == bg ? "bg" : "its backdrop", role, ratio))
                }
                if worst == nil || ratio < worst!.ratio {
                    worst = (role, name, ratio)
                }
            }

            // Header, filter, chips, counter, footer, empty state.
            check("header label", over(muted, bg, ThemeDeckInk.labelAlpha), bg)
            check("mode pill", over(bg, accent, ThemeDeckInk.labelAlpha), accent)
            check("filter icon", over(muted, field, ThemeDeckInk.labelAlpha), field, minimum: 3)
            check("filter placeholder", over(fg, field, ThemeDeckInk.labelAlpha), field)
            check("chip (lit)", over(bg, accent, ThemeDeckInk.labelAlpha), accent)
            check("chip (idle)", over(fg, chip, ThemeDeckInk.labelAlpha), chip)
            check("card counter", over(muted, bg, ThemeDeckInk.labelAlpha), bg)
            check("footer hints", over(muted, bg, ThemeDeckInk.labelAlpha), bg)
            check("empty state", over(muted, bg, ThemeDeckInk.labelAlpha), bg)

            // A theme card.
            check("card title", fg, cardBg)
            check("card section chip", accent, cardBg)
            check("card swatch label", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("card appearance", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("card summary", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("card secondary title", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("banner caption", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)

            // The focused theme preview.
            check("preview kicker", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("preview counter", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("preview shortcuts", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("preview section label", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("preview live label", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("preview summary", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("preview swatch label", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("preview ANSI index", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("preview ANSI hex", over(fg, cardBg, ThemeDeckInk.labelAlpha), cardBg)
            check("preview accent chip", accent, cardBg)
            check("preview chip", fg, cardBg)

            // Cards and the preview before their palette arrives.
            check("loading card title", fg, surface)

            // Wallpaper labels: the worst case is a white picture under the
            // solid bar, then the secondary/counter alpha on top of the bar.
            let plate = over(black, white, ThemeDeckInk.wallpaperScrim)
            check("wallpaper card title", white, plate)
            check("wallpaper card secondary", over(white, plate, ThemeDeckInk.wallpaperSecondary), plate)
            check("wallpaper preview title", white, plate)
            check("wallpaper preview secondary", over(white, plate, ThemeDeckInk.wallpaperSecondary), plate)
            check("wallpaper preview counter", over(white, plate, ThemeDeckInk.wallpaperCounter), plate)
        }

        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count) deck label(s) below 4.5:1; worst \(worst.map { "\($0.role) on \($0.theme) \(String(format: "%.2f", $0.ratio)):1" } ?? "none")\n"
                + failures.prefix(20).joined(separator: "\n")
        )
    }
}
