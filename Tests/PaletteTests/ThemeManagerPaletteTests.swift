import AppKit
import XCTest
import PaletteCore
@testable import PaletteApp

/// A wallpaper palette has no theme file, so ThemeManager has to hold the
/// derived colours until a real theme pick replaces them. Otherwise the next
/// config save or relaunch would put the launcher back in another theme.
@MainActor
final class ThemeManagerPaletteTests: XCTestCase {
    private func manager() -> ThemeManager {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-derived-\(UUID().uuidString)", isDirectory: true)
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        return ThemeManager(
            paths: paths,
            selection: ThemeSelection(mode: .dark, dark: "default-dark", light: "default-light"),
            store: nil
        )
    }

    func testDerivedPaletteBecomesTheTheme() {
        let manager = manager()
        var source = Theme.defaultLight
        source.name = "Wallpaper"
        source.palette.bg = "#f6f1e8"
        source.palette.fg = "#201c17"
        let palette = PalettePalette(theme: source)

        manager.applyPalette(palette)
        XCTAssertTrue(manager.hasDerivedPalette)
        XCTAssertEqual(manager.theme.palette.bg, palette.background)
        XCTAssertEqual(manager.theme.palette.fg, palette.foreground)
        XCTAssertEqual(manager.theme.appearance, "light")
    }

    func testPickingAThemeDropsTheDerivedPalette() {
        let manager = manager()
        manager.applyPalette(PalettePalette(theme: .defaultLight))
        XCTAssertTrue(manager.hasDerivedPalette)

        let loaded = expectation(description: "theme loaded")
        manager.select("default-dark") { theme in
            XCTAssertEqual(theme.appearance, "dark")
            loaded.fulfill()
        }
        XCTAssertFalse(manager.hasDerivedPalette)
        wait(for: [loaded], timeout: 5)
        XCTAssertEqual(manager.theme.name, Theme.defaultDark.name)
    }

    func testConfigSelectionChangeDropsTheDerivedPalette() {
        let manager = manager()
        manager.applyPalette(PalettePalette(theme: .defaultLight))
        XCTAssertTrue(manager.hasDerivedPalette)

        manager.updateSelection(ThemeSelection(mode: .dark, dark: "catppuccin-mocha", light: "default-light"))
        XCTAssertFalse(manager.hasDerivedPalette)
    }
}
