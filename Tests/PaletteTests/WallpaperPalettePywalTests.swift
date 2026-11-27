import TOMLKit
import XCTest
import PaletteCore

/// pywal 3.8.15 (the maintained pywal on PyPI) was run over the same sixteen
/// input colours with a stub ImageMagick, so these expectations are its real
/// `colors.json` output, not a hand-written guess.
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
    ) {
        XCTAssertEqual(palette.ansi.count, 16, file: file, line: line)
        for (index, pair) in zip(palette.ansi, expected).enumerated() where pair.0 != pair.1 {
            XCTFail("color\(index): expected \(pair.1), got \(pair.0)", file: file, line: line)
        }
    }

    // MARK: Golden comparison

    func testDarkMatchesPywal() throws {
        let palette = try XCTUnwrap(WallpaperPalette.extract(pixels: pixels(fixture), appearance: "dark"))
        assertANSI(palette, [
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
        assertANSI(palette, [
            "#f2f2f3", "#2f6a5a", "#3a6ea5", "#a35a1e",
            "#c05080", "#4f9a5a", "#b0a030", "#3c3c3c",
            "#b5b5b6", "#2f6a5a", "#3a6ea5", "#a35a1e",
            "#c05080", "#4f9a5a", "#b0a030", "#3c3c3c",
        ])
    }

    func testSaturationMatchesPywal() throws {
        let up = try XCTUnwrap(WallpaperPalette.extract(pixels: pixels(fixture), appearance: "dark", saturation: 0.5))
        assertANSI(up, [
            "#020d28", "#08906b", "#026cdc", "#c15700",
            "#fb1477", "#14d430", "#e0c400", "#c2c3c6",
            "#2847a3", "#08906b", "#026cdc", "#c15700",
            "#fb1477", "#14d430", "#e0c400", "#c2c3c6",
        ])

        let down = try XCTUnwrap(WallpaperPalette.extract(pixels: pixels(fixture), appearance: "dark", saturation: -0.5))
        assertANSI(down, [
            "#171613", "#554348", "#716f6d", "#725e4e",
            "#848b88", "#895f83", "#787668", "#c2c3c6",
            "#8f7a3d", "#554348", "#716f6d", "#725e4e",
            "#848b88", "#895f83", "#787668", "#c2c3c6",
        ])
    }

    func testContrastMatchesPywal() throws {
        let palette = try XCTUnwrap(WallpaperPalette.extract(pixels: pixels(fixture), appearance: "dark", contrast: 4.5))
        assertANSI(palette, [
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
