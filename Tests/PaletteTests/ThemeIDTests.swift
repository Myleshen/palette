import XCTest
import PaletteApp
import PaletteCore

/// A theme file id is what the loader reads; a display name never is. Adding a
/// separate test file keeps the resolution contract and ThemeManager's reader
/// in one place.
@MainActor
final class ThemeIDTests: XCTestCase {
    private var bundledThemes: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    private func requireBundledThemes() throws -> URL {
        guard FileManager.default.fileExists(atPath: bundledThemes.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        return bundledThemes
    }

    private var userThemes: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("palette-themes-\(UUID().uuidString)", isDirectory: true)
    }

    func testDisplayNameAndShortDisplayNameResolveToFileID() throws {
        let bundled = try requireBundledThemes()
        let themes = userThemes
        XCTAssertEqual(
            ThemeLoader.themeID(for: "Ghostty · AlxPro Dark", themesDirectory: themes, bundledThemesDirectory: bundled),
            "ghostty-alxpro-dark"
        )
        XCTAssertEqual(
            ThemeLoader.themeID(for: "AlxPro Dark", themesDirectory: themes, bundledThemesDirectory: bundled),
            "ghostty-alxpro-dark"
        )
        XCTAssertEqual(
            ThemeLoader.themeID(for: "ghostty-alxpro-dark", themesDirectory: themes, bundledThemesDirectory: bundled),
            "ghostty-alxpro-dark"
        )
        XCTAssertNil(
            ThemeLoader.themeID(for: "Not · A Theme", themesDirectory: themes, bundledThemesDirectory: bundled)
        )
    }

    func testThemingConfigResolvesDisplayNameAndFallsBack() throws {
        _ = try requireBundledThemes()
        let userThemes = self.userThemes
        let config = ThemingConfig(enabled: true, theme: "Ghostty · AlxPro Dark")
        let resolved = config.resolvingThemeID(fallback: "default-dark", themesDirectory: userThemes)
        XCTAssertEqual(resolved.theme, "ghostty-alxpro-dark")

        var missing = config
        missing.theme = "Deleted Theme"
        XCTAssertEqual(
            missing.resolvingThemeID(fallback: "catppuccin-mocha", themesDirectory: userThemes).theme,
            "catppuccin-mocha"
        )

        var followsPalette = config
        followsPalette.theme = ""
        XCTAssertEqual(
            followsPalette.resolvingThemeID(fallback: "catppuccin-mocha", themesDirectory: userThemes).theme,
            ""
        )
    }

    func testCurrentThemeIDIsFileIDNotDisplayName() {
        let paths = PalettePaths(
            home: FileManager.default.temporaryDirectory.appendingPathComponent("palette-theme-id-\(UUID().uuidString)").path,
            configDir: FileManager.default.temporaryDirectory.appendingPathComponent("palette-theme-id-\(UUID().uuidString)").appendingPathComponent("config"),
            stateDir: FileManager.default.temporaryDirectory.appendingPathComponent("palette-theme-id-\(UUID().uuidString)").appendingPathComponent("state"),
            cacheDir: FileManager.default.temporaryDirectory.appendingPathComponent("palette-theme-id-\(UUID().uuidString)").appendingPathComponent("cache")
        )
        let manager = ThemeManager(
            paths: paths,
            selection: ThemeSelection(mode: .dark, dark: "Ghostty · AlxPro Dark", light: "default-light"),
            store: nil
        )
        XCTAssertEqual(manager.currentThemeID, "ghostty-alxpro-dark")
    }
}
