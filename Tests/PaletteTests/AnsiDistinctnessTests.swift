import Foundation
import XCTest
@testable import PaletteCore

/// Wallpaper palettes are machine-generated, so two ANSI slots landing on the
/// same colour is a bug. The theme path is hand-authored and deliberately left
/// untouched; this file pins that and covers the wallpaper safety net.
final class AnsiDistinctnessTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    private let slots = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]

    /// The curated theme path did not change for this release. Ghostty
    /// Adwaita Dark is untouched by the 2.20.0 role repair, so its 16 slots
    /// pin the derivation exactly.
    func testCuratedThemeANSIStaysPinned() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-ansi-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let theme = ThemeLoader.load(
            name: "ghostty-adwaita-dark",
            themesDirectory: directory,
            bundledThemesDirectory: resources
        ).theme
        XCTAssertEqual(PalettePalette(theme: theme).ansi, [
            "#37373a", "#c7252e", "#2ec27e", "#f5c211", "#1e78e4", "#51a1ff",
            "#269db1", "#dfdfe0", "#727274", "#d8666d", "#6dd4a5", "#f8d458",
            "#62a1ec", "#85bdff", "#67bac8", "#ffffff",
        ])
    }

    func testWallpaperCollisionIsSeparatedAndKeepsTheContrastFloor() throws {
        let background = try XCTUnwrap(RGBA(hex: "#101010"))
        let colours = [
            "#000000", "#e05a5a", "#4fd07a", "#e8c65a", "#5aa0ff", "#5aa0ff",
            "#5ad0d0", "#d0d0d0", "#303030", "#f08a8a", "#7ae0a0", "#f0d88a",
            "#8ab8ff", "#8ab8ff", "#8ae0e0", "#ffffff",
        ].compactMap { RGBA(hex: $0) }

        let repaired = PalettePalette.distinctANSI(colours, background: background)
        XCTAssertEqual(repaired.count, 16)
        XCTAssertEqual(repaired[0], colours[0], "black slots are untouched")
        XCTAssertEqual(repaired[7], colours[7], "white slots are untouched")
        XCTAssertEqual(repaired[8], colours[8], "bright black is untouched")
        XCTAssertEqual(repaired[15], colours[15], "bright white is untouched")
        XCTAssertNotEqual(repaired[4], repaired[5], "blue and magenta no longer collide")
        XCTAssertNotEqual(repaired[12], repaired[13], "their bright halves no longer collide")

        for (offset, first) in slots.enumerated() {
            for second in slots[(offset + 1)...] {
                XCTAssertGreaterThanOrEqual(deltaE(repaired[first], repaired[second]), 5)
            }
        }
        for index in slots {
            XCTAssertGreaterThanOrEqual(repaired[index].contrast(with: background), 2.5, "ansi\(index)")
        }

        XCTAssertEqual(
            PalettePalette.distinctANSI(colours, background: background).map(hex),
            repaired.map(hex),
            "the same input must produce the same 16 slots"
        )
    }

    func testPassingWallpaperSchemeIsReturnedUntouched() throws {
        let background = try XCTUnwrap(RGBA(hex: "#101010"))
        let colours = [
            "#000000", "#e05a5a", "#4fd07a", "#e8c65a", "#5aa0ff", "#c060ff",
            "#5ad0d0", "#d0d0d0", "#303030", "#f08a8a", "#7ae0a0", "#f0d88a",
            "#8ab8ff", "#d08aff", "#8ae0e0", "#ffffff",
        ].compactMap { RGBA(hex: $0) }
        XCTAssertEqual(
            PalettePalette.distinctANSI(colours, background: background),
            colours,
            "pywal parity: a scheme that already separates is byte-identical"
        )
    }

    private func deltaE(_ first: RGBA, _ second: RGBA) -> Double {
        let a = ThemeContrastRepair.oklab(first)
        let b = ThemeContrastRepair.oklab(second)
        return 100 * sqrt(pow(a.l - b.l, 2) + pow(a.a - b.a, 2) + pow(a.b - b.b, 2))
    }

    private func hex(_ color: RGBA) -> String { PalettePalette.hex(color) }
}
