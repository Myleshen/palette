import TOMLKit
import XCTest
@testable import PaletteCore

/// pywal 3.8.15 (the maintained pywal on PyPI) was run over the same sixteen
/// input colours with a stub ImageMagick, so these expectations are its real
/// `colors.json` output, not a hand-written guess.
///
/// The base half is pywal byte-for-byte. The bright half deliberately deviates:
/// pywal emits `color9…14 == color1…6`, and `distinctANSI` separates those
/// colliding slots, so the tests check the separation instead of equality.
final class WallpaperPalettePywalTests: XCTestCase {
    /// Sixteen flat blocks, ascending W3 luminance — the order pywal's
    /// ImageMagick backend returns its quantized colours in.
    private let fixture = [
        "#0a0d14", "#241b16", "#3a1f24", "#1d2f55",
        "#123a2a", "#5a2a5e", "#6b3a1e", "#8a1f2e",
        "#2f6a5a", "#3a6ea5", "#a35a1e", "#c05080",
        "#4f9a5a", "#b0a030", "#d0a060", "#e8e8f0",
    ]

    private func pixels(_ colors: [String]) -> WallpaperPixels {
        let side = 64
        let block = side / 4
        var values: [RGBA] = []
        for y in 0..<side {
            for x in 0..<side {
                let index = (y / block) * 4 + (x / block)
                values.append(RGBA(hex: colors[index])!)
            }
        }
        return WallpaperPixels(width: side, height: side, pixels: values)
    }

    private func assertANSI(
        _ palette: PalettePalette,
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(palette.ansi.count, 16, file: file, line: line)
        // Base slots, bright black and bright white keep exact pywal parity.
        for index in [0, 1, 2, 3, 4, 5, 6, 7, 8, 15] {
            XCTAssertEqual(palette.ansi[index], expected[index], "color\(index)", file: file, line: line)
        }

        // pywal repeats color1…6 in color9…14. `distinctANSI` separates those
        // collisions on purpose, so a bright slot must either stay byte-equal
        // or be a distinguishable same-hue variant that still reads.
        let background = try XCTUnwrap(RGBA(hex: palette.ansi[0]), file: file, line: line)
        for index in 9...14 where palette.ansi[index] != expected[index] {
            let bright = try XCTUnwrap(RGBA(hex: palette.ansi[index]), file: file, line: line)
            let base = try XCTUnwrap(RGBA(hex: palette.ansi[index - 8]), file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                deltaE(bright, base), 5,
                "color\(index) is too close to color\(index - 8)", file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                hueDistance(bright, base), 30,
                "color\(index) left color\(index - 8)'s hue family", file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(
                bright.contrast(with: background), 2.5,
                "color\(index) lost its contrast floor", file: file, line: line
            )
        }
    }

    /// OKLab distance x100, the same measure `distinctANSI` uses.
    private func deltaE(_ first: RGBA, _ second: RGBA) -> Double {
        let a = ThemeContrastRepair.oklab(first)
        let b = ThemeContrastRepair.oklab(second)
        return 100 * sqrt(pow(a.l - b.l, 2) + pow(a.a - b.a, 2) + pow(a.b - b.b, 2))
    }

    /// Circular OKLab hue distance in degrees; near-neutral slots have no hue
    /// worth comparing, so they count as the same family.
    private func hueDistance(_ first: RGBA, _ second: RGBA) -> Double {
        func hue(_ color: RGBA) -> Double? {
            let lab = ThemeContrastRepair.oklab(color)
            guard (lab.a * lab.a + lab.b * lab.b).squareRoot() >= 0.02 else { return nil }
            let degrees = atan2(lab.b, lab.a) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }
        guard let a = hue(first), let b = hue(second) else { return 0 }
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    // MARK: Golden comparison

    func testDarkMatchesPywal() throws {
        let palette = try XCTUnwrap(WallpaperPalette.extract(pixels: pixels(fixture), appearance: "dark"))
        try assertANSI(palette, [
            "#0d121e", "#2f6a5a", "#3a6ea5", "#a35a1e",
            "#c05080", "#4f9a5a", "#b0a030", "#c2c3c6",
            "#5c6170", "#2f6a5a", "#3a6ea5", "#a35a1e",
            "#c05080", "#4f9a5a", "#b0a030", "#c2c3c6",
        ])
        XCTAssertEqual(palette.background, palette.ansi[0])
        XCTAssertEqual(palette.foreground, palette.ansi[15])
        XCTAssertEqual(palette.ansi[7], palette.ansi[15])
    }

    func testLightMatchesPywal() throws {
        let palette = try XCTUnwrap(WallpaperPalette.extract(pixels: pixels(fixture), appearance: "light"))
        try assertANSI(palette, [
            "#f2f2f3", "#2f6a5a", "#3a6ea5", "#a35a1e",
            "#c05080", "#4f9a5a", "#b0a030", "#3c3c3c",
            "#b5b5b6", "#2f6a5a", "#3a6ea5", "#a35a1e",
            "#c05080", "#4f9a5a", "#b0a030", "#3c3c3c",
        ])
    }

    func testSaturationMatchesPywal() throws {
        let up = try XCTUnwrap(WallpaperPalette.extract(pixels: pixels(fixture), appearance: "dark", saturation: 0.5))
        try assertANSI(up, [
            "#020d28", "#08906b", "#026cdc", "#c15700",
            "#fb1477", "#14d430", "#e0c400", "#c2c3c6",
            "#2847a3", "#08906b", "#026cdc", "#c15700",
            "#fb1477", "#14d430", "#e0c400", "#c2c3c6",
        ])

        let down = try XCTUnwrap(WallpaperPalette.extract(pixels: pixels(fixture), appearance: "dark", saturation: -0.5))
        try assertANSI(down, [
            "#171613", "#554348", "#716f6d", "#725e4e",
            "#848b88", "#895f83", "#787668", "#c2c3c6",
            "#8f7a3d", "#554348", "#716f6d", "#725e4e",
            "#848b88", "#895f83", "#787668", "#c2c3c6",
        ])
    }

    func testContrastMatchesPywal() throws {
        let palette = try XCTUnwrap(WallpaperPalette.extract(pixels: pixels(fixture), appearance: "dark", contrast: 4.5))
        try assertANSI(palette, [
            "#0d121e", "#66e7c4", "#aed5ff", "#ffc697",
            "#ffc0db", "#77e988", "#e8d23f", "#cfd0d3",
            "#c6d0f1", "#66e7c4", "#aed5ff", "#ffc697",
            "#ffc0db", "#77e988", "#e8d23f", "#c2c3c6",
        ])
    }

    // MARK: Behaviour

    func testDarkAndLightBendTheBackgroundTheWayPywalDoes() throws {
        let data = pixels(fixture)
        let dark = try XCTUnwrap(WallpaperPalette.extract(pixels: data, appearance: "dark"))
        let light = try XCTUnwrap(WallpaperPalette.extract(pixels: data, appearance: "light"))
        let darkBackground = try XCTUnwrap(RGBA(hex: dark.background))
        let lightBackground = try XCTUnwrap(RGBA(hex: light.background))
        XCTAssertLessThan(darkBackground.luminance, 0.05)
        XCTAssertGreaterThan(lightBackground.luminance, 0.8)
        XCTAssertGreaterThanOrEqual(darkBackground.contrast(with: try XCTUnwrap(RGBA(hex: dark.foreground))), 4.5)
        XCTAssertGreaterThanOrEqual(lightBackground.contrast(with: try XCTUnwrap(RGBA(hex: light.foreground))), 4.5)
    }

    func testSaturationAndContrastClampToPywalRanges() throws {
        let data = pixels(fixture)
        let plain = try XCTUnwrap(WallpaperPalette.extract(pixels: data))
        let overSaturated = try XCTUnwrap(WallpaperPalette.extract(pixels: data, saturation: 4))
        let maxSaturated = try XCTUnwrap(WallpaperPalette.extract(pixels: data, saturation: 1))
        XCTAssertEqual(overSaturated.ansi, maxSaturated.ansi)
        XCTAssertNotEqual(plain.ansi, maxSaturated.ansi)

        let impossibleContrast = try XCTUnwrap(WallpaperPalette.extract(pixels: data, contrast: 40))
        XCTAssertEqual(impossibleContrast.ansi, plain.ansi)
    }

    func testGreyscaleImageStillProducesAReadablePalette() throws {
        let grey = RGBA(hex: "#404040")!
        let data = WallpaperPixels(width: 16, height: 16, pixels: Array(repeating: grey, count: 256))
        let palette = try XCTUnwrap(WallpaperPalette.extract(pixels: data, appearance: "dark"))
        XCTAssertEqual(palette.ansi.count, 16)
        for hex in palette.ansi where hex != palette.ansi[8] {
            let color = try XCTUnwrap(RGBA(hex: hex))
            XCTAssertEqual(color.red, color.green)
            XCTAssertEqual(color.green, color.blue)
        }
        let background = try XCTUnwrap(RGBA(hex: palette.background))
        let foreground = try XCTUnwrap(RGBA(hex: palette.foreground))
        XCTAssertGreaterThanOrEqual(background.contrast(with: foreground), 4.5)
    }

    func testLowColourImageKeepsItsHues() throws {
        let hues = ["#202020", "#802020", "#208020", "#2020a0"]
        let data = WallpaperPixels(
            width: 16,
            height: 16,
            pixels: (0..<256).map { RGBA(hex: hues[($0 / 4 + $0 % 4) % 4])! }
        )
        let palette = try XCTUnwrap(WallpaperPalette.extract(pixels: data, appearance: "dark"))
        XCTAssertEqual(Set(palette.ansi[1...6]).count, 4)
    }

    func testExtractionIsDeterministic() throws {
        let data = pixels(fixture)
        let first = try XCTUnwrap(WallpaperPalette.extract(pixels: data))
        let second = try XCTUnwrap(WallpaperPalette.extract(pixels: data))
        XCTAssertEqual(first, second)
    }

    // MARK: Config

    func testConfigDefaultsToPywal() {
        let config = ThemingConfig()
        XCTAssertEqual(config.extraction, ThemingConfig.pywal)
        XCTAssertEqual(config.saturation, 0)
        XCTAssertEqual(config.contrast, 0)
        XCTAssertTrue(config.render().contains("extraction = \"pywal\""))
    }

    func testConfigRoundTripsAdjustments() throws {
        var config = ThemingConfig()
        config.saturation = 0.4
        config.contrast = 3
        let rendered = config.render()
        let table = try XCTUnwrap(try TOMLTable(string: rendered).table("theming"))
        let reloaded = ThemingConfig.parse(table)
        XCTAssertEqual(reloaded.extraction, "pywal")
        XCTAssertEqual(reloaded.saturation, 0.4)
        XCTAssertEqual(reloaded.contrast, 3)
    }

    func testConfigClampsAndWarnsOnBadAdjustments() throws {
        let table = try XCTUnwrap(try TOMLTable(string: """
        [theming]
        extraction = "magic"
        saturation = 9
        contrast = 42
        """).table("theming"))
        let config = ThemingConfig.parse(table)
        XCTAssertEqual(config.extraction, "pywal")
        XCTAssertEqual(config.saturation, 1)
        XCTAssertEqual(config.contrast, 0)
        let diagnostics = ThemingConfig.diagnostics(for: table)
        XCTAssertEqual(diagnostics.count, 3)
        XCTAssertTrue(diagnostics.contains { $0.message.contains("extraction") })
        XCTAssertTrue(diagnostics.contains { $0.message.contains("saturation") })
        XCTAssertTrue(diagnostics.contains { $0.message.contains("contrast") })
    }
}
