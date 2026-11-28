import AppKit
import XCTest
import PaletteCore
import PalettePlatform

/// Wallpaper palettes go through the real extraction pipeline (pywal's
/// clustering over the sampled pixels), so this stands a generated image in for
/// the desktop picture and asserts what lands in the managed directory:
/// `source = "wallpaper"` in `palette.json`, the generated include, and no
/// second copy when the same wallpaper is applied again.
@MainActor
final class WallpaperApplyIntegrationTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("palette-wallpaper-\(UUID().uuidString)", isDirectory: true)
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var configDir: URL { home.appendingPathComponent(".config/palette", isDirectory: true) }
    private var themeDir: URL { configDir.appendingPathComponent("theme", isDirectory: true) }
    private var wallpaper: URL { root.appendingPathComponent("wallpaper.png") }

    private var bundledThemes: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let kitty = home.appendingPathComponent(".config/kitty/kitty.conf")
        try FileManager.default.createDirectory(
            at: kitty.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "font_family JetBrainsMono Nerd Font\n".write(to: kitty, atomically: true, encoding: .utf8)
        try writeWallpaper()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A 64×64 two-tone bitmap: enough for pywal's sampler, and no window
    /// server or display layout involved.
    private func writeWallpaper() throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.08, green: 0.18, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0.85, green: 0.72, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: wallpaper)
    }

    private func makeEngine() -> ThemingEngine {
        let paths = PalettePaths(
            home: home.path,
            configDir: configDir,
            stateDir: root.appendingPathComponent("state", isDirectory: true),
            cacheDir: root.appendingPathComponent("cache", isDirectory: true)
        )
        return ThemingEngine(
            paths: paths,
            themesDirectory: bundledThemes,
            reloadsEnabled: false,
            wallpaperOverride: [wallpaper]
        )
    }

    private func paletteJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: themeDir.appendingPathComponent(ThemingRenderer.paletteJSONName))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func occurrences(of text: String, in relative: String) -> Int {
        let body = (try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)) ?? ""
        return body.components(separatedBy: text).count - 1
    }

    func testWallpaperApplyExtractsWritesAndDoesNotDoubleApply() async throws {
        guard FileManager.default.fileExists(atPath: bundledThemes.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        let engine = makeEngine()
        let config = ThemingConfig(
            enabled: true,
            source: .wallpaper,
            targets: [ThemingTarget.kitty.rawValue],
            darkMode: "dark"
        )

        // A theme apply first, so the source switch is visible in the file.
        _ = await engine.applyTheme(
            named: "ghostty-catppuccin-mocha",
            config: ThemingConfig(
                enabled: true,
                source: .theme,
                theme: "ghostty-catppuccin-mocha",
                targets: [ThemingTarget.kitty.rawValue]
            )
        )
        let themed = try paletteJSON()
        XCTAssertEqual(themed["source"] as? String, "theme")

        let applied = await engine.applyWallpaper(config)
        XCTAssertNil(applied.error, applied.error ?? "")
        XCTAssertEqual(applied.source, "wallpaper")
        XCTAssertTrue(applied.written.contains(ThemingRenderer.paletteJSONName))
        XCTAssertTrue(applied.written.contains(ThemingTarget.kitty.fileName))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: themeDir.appendingPathComponent("kitty.conf").path),
            "the generated kitty include was not written"
        )

        let wallpapered = try paletteJSON()
        XCTAssertEqual(wallpapered["source"] as? String, "wallpaper")
        XCTAssertEqual(wallpapered["theme"] as? String, "Wallpaper")
        XCTAssertEqual(wallpapered["theme_id"] as? String, "")
        XCTAssertEqual((wallpapered["ansi"] as? [String])?.count, 16)
        XCTAssertNotEqual(
            wallpapered["background"] as? String,
            themed["background"] as? String,
            "the wallpaper palette must replace the theme palette"
        )
        XCTAssertNotEqual(wallpapered["theme_id"] as? String, themed["theme_id"] as? String)

        let background = wallpapered["background"] as? String
        let ansi = wallpapered["ansi"] as? [String]

        // Applying the same wallpaper again rewrites the same palette and the
        // same single managed block; it never stacks a second include.
        let reapplied = await engine.applyWallpaper(config)
        XCTAssertNil(reapplied.error, reapplied.error ?? "")
        let again = try paletteJSON()
        XCTAssertEqual(again["background"] as? String, background)
        XCTAssertEqual(again["ansi"] as? [String], ansi)
        let includes = ThemingIncludes(home: home.path, themeDir: themeDir)
        XCTAssertEqual(occurrences(of: includes.startMarker(.hash), in: ".config/kitty/kitty.conf"), 1)
        XCTAssertEqual(occurrences(of: includes.endMarker(.hash), in: ".config/kitty/kitty.conf"), 1)
    }
}
