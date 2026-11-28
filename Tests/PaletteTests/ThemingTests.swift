import AppKit
import TOMLKit
import XCTest
import PaletteCore
import PalettePlatform

@MainActor
final class ThemingTests: XCTestCase {
    private func makePaths() -> PalettePaths {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palette-theming-\(UUID().uuidString)", isDirectory: true)
        return PalettePaths(
            home: base.path,
            configDir: base.appendingPathComponent("config", isDirectory: true),
            stateDir: base.appendingPathComponent("state", isDirectory: true),
            cacheDir: base.appendingPathComponent("cache", isDirectory: true)
        )
    }

    private func makeEngine(_ paths: PalettePaths) -> ThemingEngine {
        ThemingEngine(paths: paths, themesDirectory: paths.themesDir)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private var phaseOneIDs: [String] {
        ["kitty", "ghostty", "zellij", "nvim", "fish", "starship"]
    }

    // MARK: - Config

    func testConfigRoundTrip() throws {
        let original = ThemingConfig(
            enabled: true,
            source: .wallpaper,
            theme: "ghostty-dracula",
            followWallpaper: true,
            targets: ["kitty", "zellij", "bat", "not-a-target"],
            darkMode: "light"
        )
        let rendered = original.render()
        let table = try TOMLTable(string: rendered)
        let parsed = try XCTUnwrap(table.table("theming"))
        let result = ThemingConfig.parse(parsed)

        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.source, .wallpaper)
        XCTAssertEqual(result.theme, "ghostty-dracula")
        XCTAssertTrue(result.followWallpaper)
        XCTAssertEqual(result.targets, ["kitty", "zellij", "bat"])
        XCTAssertEqual(result.darkMode, "light")
        XCTAssertTrue(rendered.contains("follow_wallpaper = true"))
    }

    func testBrowserTargetsAreDroppedOnNormalize() {
        let config = ThemingConfig(
            enabled: true,
            targets: ["kitty", "helium", "chrome", "edge", "brave", "vivaldi", "chromium", "arc", "nvim"]
        )
        XCTAssertEqual(config.normalized().targets, ["kitty", "nvim"])
    }

    func testDefaultsAreOffWithPhaseOneTargets() throws {
        let config = ThemingConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.source, .theme)
        XCTAssertEqual(config.theme, "")
        XCTAssertEqual(config.targets, phaseOneIDs)
        XCTAssertFalse(config.followWallpaper)

        let defaults = try TOMLTable(string: ConfigLoader.defaultTOML())
        let theming = try XCTUnwrap(defaults.table("theming"))
        XCTAssertEqual(theming.bool("enabled"), false)
        XCTAssertEqual(theming.strArray("targets"), phaseOneIDs)
    }

    // MARK: - Palette derivation

    func testPaletteDerivationFromTheme() throws {
        let dark = PalettePalette(theme: .defaultDark)
        XCTAssertEqual(dark.background, "#1e1e2e")
        XCTAssertEqual(dark.foreground, "#cdd6f4")
        XCTAssertEqual(dark.cursor, "#cba6f7")
        XCTAssertEqual(dark.ansi.count, 16)
        XCTAssertEqual(dark.ansi[5], "#cba6f7")
        let background = try XCTUnwrap(RGBA(hex: dark.background))
        let foreground = try XCTUnwrap(RGBA(hex: dark.foreground))
        XCTAssertGreaterThanOrEqual(background.contrast(with: foreground), 4.5)
        for color in dark.ansi {
            XCTAssertNotNil(RGBA(hex: color), "ANSI entry is not a colour: \(color)")
        }

        var light = Theme.defaultLight
        light.name = "Light Test"
        let derived = PalettePalette(theme: light)
        XCTAssertEqual(derived.appearance, "light")
        XCTAssertEqual(derived.background, "#ffffff")
        XCTAssertEqual(derived.ansi.count, 16)
    }

    // MARK: - Wallpaper

    func testWallpaperExtractionFromKnownPixels() throws {
        let navy = RGBA(red: 0.05, green: 0.08, blue: 0.16)
        let white = RGBA(red: 0.97, green: 0.97, blue: 0.99)
        let red = RGBA(red: 0.90, green: 0.16, blue: 0.22)
        let blue = RGBA(red: 0.20, green: 0.48, blue: 0.95)
        var pixels: [RGBA] = []
        for y in 0..<40 {
            for x in 0..<40 {
                switch (x, y) {
                case (30..<40, 0..<40), (0..<30, 0..<10):
                    pixels.append(white)
                case (0..<15, 10..<25):
                    pixels.append(red)
                case (15..<30, 10..<25):
                    pixels.append(blue)
                default:
                    pixels.append(navy)
                }
            }
        }
        let data = WallpaperPixels(width: 40, height: 40, pixels: pixels)

        let dark = try XCTUnwrap(WallpaperPalette.extract(pixels: data, appearance: "dark"))
        XCTAssertEqual(dark.appearance, "dark")
        let darkBackground = try XCTUnwrap(RGBA(hex: dark.background))
        XCTAssertLessThan(darkBackground.luminance, 0.2)
        let accent = try XCTUnwrap(RGBA(hex: dark.cursor))
        XCTAssertGreaterThan(accent.saturation, 0.2)
        XCTAssertGreaterThanOrEqual(darkBackground.contrast(with: try XCTUnwrap(RGBA(hex: dark.foreground))), 4.5)

        let light = try XCTUnwrap(WallpaperPalette.extract(pixels: data, appearance: "light"))
        let lightBackground = try XCTUnwrap(RGBA(hex: light.background))
        XCTAssertGreaterThan(lightBackground.luminance, 0.6)
        XCTAssertGreaterThanOrEqual(lightBackground.contrast(with: try XCTUnwrap(RGBA(hex: light.foreground))), 4.5)
    }

    // MARK: - Renderers

    func testEveryImplementedRendererProducesItsShape() throws {
        let palette = PalettePalette(theme: .defaultDark)
        let metadata = PaletteMetadata(
            source: "theme",
            theme: "Default Dark",
            appearance: "dark",
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        for target in ThemingTarget.allCases where target.isImplemented && target != .starship {
            let output = try XCTUnwrap(ThemingRenderer.contents(for: target, palette: palette, metadata: metadata))
            XCTAssertTrue(output.contains("generated by Palette"), "\(target) has no house header")
            switch target {
            case .kitty:
                XCTAssertTrue(output.contains("color15              \(palette.ansi[15])"))
            case .ghostty:
                XCTAssertTrue(output.contains("palette = 15=\(palette.ansi[15])"))
            case .zellij:
                XCTAssertTrue(output.contains("themes {"))
                XCTAssertTrue(output.contains("orange \"\(palette.ansi[3])\""))
            case .nvim:
                XCTAssertTrue(output.contains("vim.g.colors_name = \"palette\""))
            case .fish:
                XCTAssertTrue(output.contains("fish_color_command \(String(palette.ansi[4].dropFirst()))"))
            case .bat:
                XCTAssertTrue(output.contains("<key>background</key>"))
                XCTAssertTrue(output.contains("<string>\(palette.background)</string>"))
            case .delta:
                XCTAssertTrue(output.contains("[delta]"))
                XCTAssertTrue(output.contains("line-numbers-plus-style"))
            case .btop:
                XCTAssertTrue(output.contains("theme[main_bg]=\"\(palette.background)\""))
            case .yazi:
                XCTAssertTrue(output.contains("[mgr]"))
                XCTAssertTrue(output.contains("cwd = "))
            case .vscode, .zed:
                XCTFail("unimplemented target reported as implemented")
            default:
                XCTFail("\(target) has no renderer test")
            }
        }
    }

    func testUnimplementedTargetsRenderNothingAndSayWhy() {
        for target in ThemingTarget.allCases where !target.isImplemented {
            XCTAssertNil(ThemingRenderer.contents(
                for: target,
                palette: PalettePalette(theme: .defaultDark),
                metadata: PaletteMetadata(source: "theme", theme: "x", appearance: "dark")
            ))
            XCTAssertFalse((target.unavailableReason ?? "").isEmpty)
        }
        XCTAssertEqual(ThemingTarget.vscode.unavailableReason, "Not yet — VS Code needs a settings merge.")
        XCTAssertTrue(ThemingTarget.nvim.includeHint.contains("Neovide"))
    }

    // MARK: - Applying

    func testDisabledGeneratesNothing() async throws {
        let paths = makePaths()
        let engine = makeEngine(paths)
        let result = await engine.apply(ThemingConfig(enabled: false, targets: ["kitty"]))

        XCTAssertTrue(result.written.isEmpty)
        XCTAssertTrue(result.status.contains("off"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.themeDir.path))
    }

    func testSubsetWritesOnlySelectedImplementedFiles() async throws {
        let paths = makePaths()
        let engine = makeEngine(paths)
        var config = ThemingConfig(enabled: true, targets: ["kitty", "bat", "vscode"])
        config.theme = "default-dark"
        let result = await engine.apply(config)

        XCTAssertTrue(result.written.contains("kitty.conf"))
        XCTAssertTrue(result.written.contains("bat.tmTheme"))
        XCTAssertTrue(result.written.contains("palette.json"))
        XCTAssertFalse(result.written.contains("ghostty.conf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.themeDir.appendingPathComponent("ghostty.conf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.themeDir.appendingPathComponent("vscode.json").path))
        XCTAssertTrue(result.skipped.contains("vscode.json"))
        let vscode = try XCTUnwrap(result.targets.first { $0.id == "vscode" })
        XCTAssertEqual(vscode.state, .skipped)
        XCTAssertTrue(vscode.note.contains("settings merge"))
    }

    func testApplyInstallsTheIncludeAndKeepsTheRestOfTheConfig() async throws {
        let paths = makePaths()
        let fakeKitty = URL(fileURLWithPath: paths.home, isDirectory: true)
            .appendingPathComponent(".config/kitty", isDirectory: true)
            .appendingPathComponent("kitty.conf")
        try FileManager.default.createDirectory(
            at: fakeKitty.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "user-owned kitty config\nfont_size 13\n".write(to: fakeKitty, atomically: true, encoding: .utf8)

        let engine = makeEngine(paths)
        var config = ThemingConfig(enabled: true, targets: phaseOneIDs)
        config.theme = "default-dark"
        _ = await engine.apply(config)

        let kitty = try read(fakeKitty)
        XCTAssertTrue(kitty.hasPrefix("user-owned kitty config\nfont_size 13\n"))
        XCTAssertTrue(kitty.contains("# >>> palette theme >>>"))
        XCTAssertTrue(kitty.contains("include \(engine.includes.shortPath(paths.themeDir.appendingPathComponent("kitty.conf").path))"))
        XCTAssertEqual(kitty.components(separatedBy: "# >>> palette theme >>>").count, 2)
        let generated = try FileManager.default.contentsOfDirectory(atPath: paths.themeDir.path).sorted()
        XCTAssertEqual(
            generated,
            [
                "fish.fish", "ghostty.conf", "kitty.conf", "nvim.lua", "palette.json",
                "palette.terminal-sexy.json", "palette.yaml",
                "previous", "starship-palette.fish", "starship-theme.toml", "zellij.kdl",
            ]
        )
    }

    func testUncheckingATargetRemovesOnlyItsBlock() async throws {
        let paths = makePaths()
        let kittyPath = paths.home + "/.config/kitty/kitty.conf"
        let fishPath = paths.home + "/.config/fish/config.fish"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: kittyPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: fishPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "kitty user\n".write(toFile: kittyPath, atomically: true, encoding: .utf8)
        try "fish user\n".write(toFile: fishPath, atomically: true, encoding: .utf8)

        let engine = makeEngine(paths)
        var config = ThemingConfig(enabled: true, theme: "default-dark", targets: ["kitty", "fish"])
        _ = await engine.apply(config)
        XCTAssertTrue(try read(URL(fileURLWithPath: fishPath)).contains("palette theme"))

        config.targets = ["kitty"]
        _ = await engine.apply(config)

        XCTAssertEqual(try read(URL(fileURLWithPath: fishPath)), "fish user\n")
        XCTAssertTrue(try read(URL(fileURLWithPath: kittyPath)).contains("palette theme"))
        XCTAssertEqual(engine.includeStatus(for: .fish).installed, false)
        XCTAssertEqual(engine.includeStatus(for: .kitty).installed, true)
    }

    func testDisablingTheMasterSwitchRemovesEveryBlock() async throws {
        let paths = makePaths()
        let kittyPath = paths.home + "/.config/kitty/kitty.conf"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: kittyPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "kitty user\n".write(toFile: kittyPath, atomically: true, encoding: .utf8)

        let engine = makeEngine(paths)
        _ = await engine.apply(ThemingConfig(enabled: true, theme: "default-dark", targets: ["kitty", "fish"]))
        XCTAssertTrue(try read(URL(fileURLWithPath: kittyPath)).contains("palette theme"))

        let disabled = await engine.apply(ThemingConfig(enabled: false, targets: ["kitty", "fish"]))
        XCTAssertTrue(disabled.status.contains("off"))
        XCTAssertEqual(try read(URL(fileURLWithPath: kittyPath)), "kitty user\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.home + "/.config/fish/config.fish"))
    }

    func testRevertRestoresTheOriginalConfig() async throws {
        let paths = makePaths()
        let kittyPath = paths.home + "/.config/kitty/kitty.conf"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: kittyPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = "original kitty\n"
        try original.write(toFile: kittyPath, atomically: true, encoding: .utf8)

        let engine = makeEngine(paths)
        _ = await engine.apply(ThemingConfig(enabled: true, theme: "default-dark", targets: ["kitty"]))
        XCTAssertTrue(try read(URL(fileURLWithPath: kittyPath)).contains("palette theme"))
        _ = await engine.apply(ThemingConfig(enabled: true, theme: "default-light", targets: ["kitty"]))

        let reverted = await engine.revert()
        XCTAssertNil(reverted.error)
        XCTAssertEqual(try read(URL(fileURLWithPath: kittyPath)), original)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.themeDir.appendingPathComponent("previous/kitty-kitty.conf.orig").path
        ))
    }

    func testRevertRestoresThePreviousSet() async throws {
        let paths = makePaths()
        let engine = makeEngine(paths)
        var first = ThemingConfig(enabled: true, targets: ["kitty"])
        first.theme = "default-dark"
        _ = await engine.apply(first)
        let firstKitty = try read(paths.themeDir.appendingPathComponent("kitty.conf"))

        var second = first
        second.theme = "default-light"
        _ = await engine.apply(second)
        let secondKitty = try read(paths.themeDir.appendingPathComponent("kitty.conf"))
        XCTAssertNotEqual(firstKitty, secondKitty)

        let reverted = await engine.revert()
        XCTAssertNil(reverted.error)
        XCTAssertEqual(try read(paths.themeDir.appendingPathComponent("kitty.conf")), firstKitty)
        XCTAssertTrue(engine.hasPrevious)
    }

    func testApplyingTheSamePaletteTwiceKeepsTheFirstRevertTarget() async throws {
        let paths = makePaths()
        let kittyPath = paths.home + "/.config/kitty/kitty.conf"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: kittyPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "original kitty\n".write(toFile: kittyPath, atomically: true, encoding: .utf8)
        let engine = makeEngine(paths)
        let config = ThemingConfig(enabled: true, theme: "default-dark", targets: ["kitty"])

        _ = await engine.apply(config)
        _ = await engine.apply(config)

        let reverted = await engine.revert()
        XCTAssertNil(reverted.error, reverted.error ?? "")
        XCTAssertEqual(try read(URL(fileURLWithPath: kittyPath)), "original kitty\n")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.themeDir.appendingPathComponent("kitty.conf").path
        ))
    }

    func testRevertFailureLeavesTheAppConfigUntouchedAndRetryable() async throws {
        let paths = makePaths()
        let kittyPath = paths.home + "/.config/kitty/kitty.conf"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: kittyPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "original kitty\n".write(toFile: kittyPath, atomically: true, encoding: .utf8)
        let engine = makeEngine(paths)
        _ = await engine.apply(ThemingConfig(enabled: true, theme: "default-dark", targets: ["kitty"]))
        _ = await engine.apply(ThemingConfig(enabled: true, theme: "default-light", targets: ["kitty"]))

        // An unreadable snapshot makes the generated-file swap fail before any
        // include is reverted.
        let previous = paths.themeDir.appendingPathComponent("previous/kitty.conf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: previous.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: previous.path) }

        let failed = await engine.revert()
        XCTAssertNotNil(failed.error)
        XCTAssertTrue(failed.status.contains("left unchanged"))
        XCTAssertTrue(try read(URL(fileURLWithPath: kittyPath)).contains("palette theme"))
        XCTAssertTrue(engine.hasPrevious)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: previous.path)
        let retried = await engine.revert()
        XCTAssertNil(retried.error, retried.error ?? "")
        XCTAssertEqual(try read(URL(fileURLWithPath: kittyPath)), "original kitty\n")
    }

    func testFirstRevertDoesNotClaimRestoredFiles() async throws {
        let paths = makePaths()
        let kittyPath = paths.home + "/.config/kitty/kitty.conf"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: kittyPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "original kitty\n".write(toFile: kittyPath, atomically: true, encoding: .utf8)
        let engine = makeEngine(paths)
        _ = await engine.apply(ThemingConfig(enabled: true, theme: "default-dark", targets: ["kitty"]))

        let reverted = await engine.revert()
        XCTAssertNil(reverted.error, reverted.error ?? "")
        XCTAssertFalse(reverted.status.contains("(0 files)"))
        XCTAssertTrue(reverted.status.contains("app config"))
        XCTAssertEqual(try read(URL(fileURLWithPath: kittyPath)), "original kitty\n")
    }

    func testMissingThemeIsAnErrorAndWritesNothing() async throws {
        let paths = makePaths()
        let engine = makeEngine(paths)
        let config = ThemingConfig(enabled: true, source: .theme, theme: "gone-theme", targets: ["kitty"])

        let result = await engine.applyTheme(named: "gone-theme", config: config)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.status.contains("was not found"))
        XCTAssertTrue(result.written.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.themeDir.appendingPathComponent("kitty.conf").path
        ))
        XCTAssertFalse(engine.includeStatus(for: .kitty).installed)
        XCTAssertTrue(engine.status.contains("was not found"))
    }

    func testOtherAppsInheritThePaletteThemeByDefault() async throws {
        let paths = makePaths()
        let engine = makeEngine(paths)
        let config = ThemingConfig(enabled: true, source: .theme, theme: "", targets: ["kitty"])
        _ = await engine.apply(config, fallbackThemeName: "catppuccin-mocha")

        let kitty = try read(paths.themeDir.appendingPathComponent("kitty.conf"))
        let mocha = ThemeLoader.load(name: "catppuccin-mocha", themesDirectory: paths.themesDir)
        XCTAssertTrue(kitty.contains("background            \(mocha.theme.palette.bg)"))
    }

    func testStarshipWithoutFishStillWritesTheCopyAndSaysHowToWireIt() async throws {
        let paths = makePaths()
        let engine = makeEngine(paths)
        var config = ThemingConfig(enabled: true, targets: ["starship"])
        config.theme = "default-dark"
        let result = await engine.apply(config)

        XCTAssertNil(result.error)
        XCTAssertTrue(result.written.contains(StarshipTheme.fileName))
        XCTAssertTrue(result.written.contains(StarshipTheme.snippetFileName))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.themeDir.appendingPathComponent(StarshipTheme.fileName).path
        ))
        XCTAssertTrue(result.notices.contains { $0.contains("STARSHIP_CONFIG") })
        XCTAssertTrue(
            result.targets.first { $0.id == "starship" }?.note.contains("STARSHIP_CONFIG") == true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.home + "/.config/fish/config.fish"))
    }

    func testOtherAppsOverrideIsHonoured() async throws {
        let paths = makePaths()
        let engine = makeEngine(paths)
        let config = ThemingConfig(enabled: true, source: .theme, theme: "default-light", targets: ["kitty"])
        _ = await engine.apply(config, fallbackThemeName: "catppuccin-mocha")

        let kitty = try read(paths.themeDir.appendingPathComponent("kitty.conf"))
        XCTAssertTrue(kitty.contains("background            #ffffff"))
        XCTAssertFalse(kitty.contains("#1e1e2e"))
    }

    func testAutoApplyOnlyForWallpaperFollow() {
        var config = ThemingConfig(enabled: true, source: .theme, followWallpaper: true)
        XCTAssertFalse(ThemingEngine.shouldAutoApply(config))
        config.source = .wallpaper
        config.followWallpaper = false
        XCTAssertFalse(ThemingEngine.shouldAutoApply(config))
        config.followWallpaper = true
        XCTAssertTrue(ThemingEngine.shouldAutoApply(config))
        config.enabled = false
        XCTAssertFalse(ThemingEngine.shouldAutoApply(config))
    }

}
