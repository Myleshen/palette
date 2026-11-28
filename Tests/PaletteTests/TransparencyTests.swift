import TOMLKit
import XCTest
import PaletteCore
import PalettePlatform

final class TransparencyDetectionTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palette-transparency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, to relativePath: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func detect() -> TransparencyDetection.Result {
        TransparencyDetection.detect(home: home.path)
    }

    func testKittyOpacityBelowOneIsTransparent() throws {
        try write("font_size 14\nbackground_opacity 0.6\n", to: ".config/kitty/kitty.conf")
        let result = detect()
        XCTAssertTrue(result.isTransparent)
        XCTAssertEqual(result.reason, "kitty 0.6")
    }

    func testKittyOpacityOneAndAbsentAreOpaque() throws {
        try write("background_opacity 1.0\n", to: ".config/kitty/kitty.conf")
        XCTAssertFalse(detect().isTransparent)

        try write("font_size 14\n", to: ".config/kitty/kitty.conf")
        XCTAssertFalse(detect().isTransparent)
    }

    func testKittyLastValueWinsAndCommentsAreIgnored() throws {
        try write("# background_opacity 0.5\nbackground_opacity 0.6\nbackground_opacity 1\n",
                  to: ".config/kitty/kitty.conf")
        XCTAssertFalse(detect().isTransparent)

        try write("background_opacity=0.7  # dim\n", to: ".config/kitty/kitty.conf")
        let result = detect()
        XCTAssertTrue(result.isTransparent)
        XCTAssertEqual(result.reason, "kitty 0.7")
    }

    func testQuickAccessTerminalCounts() throws {
        try write("background_opacity 0.7\n", to: ".config/kitty/quick-access-terminal.conf")
        let result = detect()
        XCTAssertTrue(result.isTransparent)
        XCTAssertEqual(result.reason, "kitty 0.7")
    }

    func testGhosttyOpacity() throws {
        try write("background-opacity = 0.8\n", to: ".config/ghostty/config")
        let result = detect()
        XCTAssertTrue(result.isTransparent)
        XCTAssertEqual(result.reason, "ghostty 0.8")

        try write("background-opacity = 1\n", to: ".config/ghostty/config")
        XCTAssertFalse(detect().isTransparent)
    }

    func testNeovideLuaOpacity() throws {
        try write(
            "vim.g.neovide_normal_opacity = 0.6\n",
            to: ".config/nvim/lua/plugins/ui.lua"
        )
        let result = detect()
        XCTAssertTrue(result.isTransparent)
        XCTAssertEqual(result.reason, "neovim lua 0.6")

        try write("vim.g.neovide_opacity = 0.9\n", to: ".config/nvim/lua/settings.lua")
        XCTAssertEqual(detect().reason, "neovim lua 0.6")
    }

    func testNeovideOpacityOneIsOpaque() throws {
        try write("vim.g.neovide_normal_opacity = 1\n", to: ".config/nvim/lua/init.lua")
        XCTAssertFalse(detect().isTransparent)
    }

    func testMissingAndUnreadableFilesAreOpaque() throws {
        XCTAssertFalse(detect().isTransparent)

        try write("background_opacity 0.6\n", to: ".config/kitty/kitty.conf")
        let url = home.appendingPathComponent(".config/kitty/kitty.conf")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        XCTAssertFalse(detect().isTransparent)
    }
}

final class TransparencyRenderTests: XCTestCase {
    private let palette = PalettePalette(theme: .defaultDark)

    private func nvim(transparent: Bool) throws -> String {
        try XCTUnwrap(ThemingRenderer.contents(
            for: .nvim,
            palette: palette,
            metadata: PaletteMetadata(
                source: "theme",
                theme: "Default Dark",
                appearance: "dark",
                generatedAt: Date(timeIntervalSince1970: 0),
                transparentBackgrounds: transparent
            )
        ))
    }

    func testTransparentNvimDropsNormalBackground() throws {
        let text = try nvim(transparent: true)
        XCTAssertTrue(text.contains("  Normal = { fg = p.fg },\n  NormalNC = { fg = p.fg },"))
        XCTAssertTrue(text.contains("  NormalFloat = { fg = p.fg, bg = p.surface },"))
        XCTAssertFalse(text.contains("Normal = { fg = p.fg, bg = p.bg }"))
    }

    func testOpaqueNvimKeepsThePaletteBackground() throws {
        let text = try nvim(transparent: false)
        XCTAssertTrue(text.contains("  Normal = { fg = p.fg, bg = p.bg },"))
        XCTAssertFalse(text.contains("NormalNC"))
        XCTAssertTrue(text.contains("  NormalFloat = { fg = p.fg, bg = p.surface },"))
    }

    func testTransparentConfigRoundTrip() throws {
        for value in ThemingTransparency.allCases {
            let rendered = ThemingConfig(transparent: value).render()
            XCTAssertTrue(rendered.contains("transparent = \"\(value.rawValue)\""))
            let table = try XCTUnwrap(try TOMLTable(string: rendered).table("theming"))
            XCTAssertEqual(ThemingConfig.parse(table).transparent, value)
        }

        let invalid = try TOMLTable(string: "transparent = \"sometimes\"")
        XCTAssertEqual(ThemingConfig.parse(invalid).transparent, .auto)
        XCTAssertTrue(
            ThemingConfig.diagnostics(for: invalid).contains { $0.message.contains("transparent") }
        )
    }
}

@MainActor
final class TransparencyEngineTests: XCTestCase {
    private func makePaths() -> PalettePaths {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palette-transparency-engine-\(UUID().uuidString)", isDirectory: true)
        return PalettePaths(
            home: base.path,
            configDir: base.appendingPathComponent("config", isDirectory: true),
            stateDir: base.appendingPathComponent("state", isDirectory: true),
            cacheDir: base.appendingPathComponent("cache", isDirectory: true)
        )
    }

    private func writeKitty(_ paths: PalettePaths, opacity: String) throws {
        let directory = URL(fileURLWithPath: paths.home).appendingPathComponent(".config/kitty")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "background_opacity \(opacity)\n".write(
            to: directory.appendingPathComponent("kitty.conf"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func nvimFile(_ paths: PalettePaths) throws -> String {
        try String(contentsOf: paths.themeDir.appendingPathComponent("nvim.lua"), encoding: .utf8)
    }

    func testEngineAutoReadsKittyAndRecordsTheReason() async throws {
        let paths = makePaths()
        try writeKitty(paths, opacity: "0.6")
        let engine = ThemingEngine(paths: paths, themesDirectory: paths.themesDir, reloadsEnabled: false)

        let result = await engine.apply(
            ThemingConfig(enabled: true, theme: "default-dark", targets: ["nvim"])
        )

        XCTAssertTrue(try nvimFile(paths).contains("  Normal = { fg = p.fg },"))
        XCTAssertTrue(result.notices.contains("nvim: transparent background (kitty 0.6)"))
    }

    func testEngineOffOverridesDetectedTransparency() async throws {
        let paths = makePaths()
        try writeKitty(paths, opacity: "0.6")
        let engine = ThemingEngine(paths: paths, themesDirectory: paths.themesDir, reloadsEnabled: false)

        let result = await engine.apply(
            ThemingConfig(enabled: true, theme: "default-dark", targets: ["nvim"], transparent: .off)
        )

        XCTAssertTrue(try nvimFile(paths).contains("  Normal = { fg = p.fg, bg = p.bg },"))
        XCTAssertFalse(result.notices.contains { $0.contains("transparent background") })
    }

    func testEngineOnForcesTransparencyWithoutDetection() async throws {
        let paths = makePaths()
        let engine = ThemingEngine(paths: paths, themesDirectory: paths.themesDir, reloadsEnabled: false)

        let result = await engine.apply(
            ThemingConfig(enabled: true, theme: "default-dark", targets: ["nvim"], transparent: .on)
        )

        XCTAssertTrue(try nvimFile(paths).contains("  NormalNC = { fg = p.fg },"))
        XCTAssertTrue(result.notices.contains("nvim: transparent background (transparent = on)"))
    }
}
