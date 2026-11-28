import XCTest
import PaletteCore

/// The canonical export: another tool should be able to read Palette's colours
/// without an adapter, so the slot mapping is pinned rather than incidental.
final class StandardPaletteExportTests: XCTestCase {
    private let palette = PalettePalette(theme: .defaultDark)
    private let metadata = PaletteMetadata(
        source: "theme", theme: "Default Dark", appearance: "dark", themeID: "default-dark"
    )

    private func export(_ name: String, palette: PalettePalette? = nil) throws -> String {
        let exports = ThemingRenderer.standardExports(palette: palette ?? self.palette, metadata: metadata)
        return try XCTUnwrap(exports.first { $0.name == name }?.contents)
    }

    func testBase16SlotsFollowThePalette() throws {
        let yaml = try export("palette.yaml")
        XCTAssertTrue(yaml.contains("scheme:"))
        XCTAssertTrue(yaml.contains("base00: \"\(palette.background)\""))
        XCTAssertTrue(yaml.contains("base05: \"\(palette.foreground)\""))
        XCTAssertTrue(yaml.contains("base08: \"\(palette.ansi[1])\""))
        XCTAssertTrue(yaml.contains("base09: \"\(palette.ansi[3])\""))
        XCTAssertTrue(yaml.contains("base0A: \"\(palette.ansi[3])\""))
        XCTAssertTrue(yaml.contains("base0B: \"\(palette.ansi[2])\""))
        XCTAssertTrue(yaml.contains("base0C: \"\(palette.ansi[6])\""))
        XCTAssertTrue(yaml.contains("base0D: \"\(palette.ansi[4])\""))
        XCTAssertTrue(yaml.contains("base0E: \"\(palette.ansi[5])\""))
        XCTAssertTrue(yaml.contains("base0F: \"\(palette.ansi[1])\""))
        for slot in 0...15 {
            XCTAssertTrue(yaml.contains(String(format: "base%02X:", slot)), "base\(slot) missing")
        }
    }

    func testTerminalSexyJSONHasTheSixteenColoursInOrder() throws {
        let text = try export("palette.terminal-sexy.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["background"] as? String, palette.background)
        XCTAssertEqual(object["foreground"] as? String, palette.foreground)
        XCTAssertEqual(object["cursorColor"] as? String, palette.cursor)
        for index in 0..<16 {
            XCTAssertEqual(
                object[String(format: "color_%02d", index + 1)] as? String,
                palette.ansi[index],
                "color_\(index + 1)"
            )
        }
    }

    func testTheExportChangesWithThePalette() throws {
        let light = PalettePalette(theme: .defaultLight)
        let darkYAML = try export("palette.yaml")
        let lightYAML = try export("palette.yaml", palette: light)
        XCTAssertNotEqual(darkYAML, lightYAML)
        XCTAssertTrue(lightYAML.contains(light.background))
        let darkJSON = try export("palette.terminal-sexy.json")
        let lightJSON = try export("palette.terminal-sexy.json", palette: light)
        XCTAssertNotEqual(darkJSON, lightJSON)
    }

    func testBothFilesAreInTheStandardSet() {
        XCTAssertEqual(
            ThemingRenderer.standardExportNames,
            ["palette.yaml", "palette.terminal-sexy.json"]
        )
    }
}
