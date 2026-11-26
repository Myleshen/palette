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

    func testKittyRendererGolden() {
        let palette = PalettePalette(theme: .defaultDark)
        let metadata = PaletteMetadata(
            source: "theme",
            theme: "Default Dark",
            appearance: "dark",
            generatedAt: Date(timeIntervalSince1970: 0),
            targets: ["kitty"]
        )
        let output = ThemingRenderer.contents(for: .kitty, palette: palette, metadata: metadata)
        var expected = [
            "# generated by Palette — do not edit",
            "# source: theme · Default Dark · dark · 1970-01-01T00:00:00Z",
            "",
            "background            \(palette.background)",
            "foreground            \(palette.foreground)",
            "cursor                \(palette.cursor)",
            "cursor_text_color     \(palette.cursorText)",
            "selection_background  \(palette.selectionBackground)",
            "selection_foreground  \(palette.selectionForeground)",
        ]
        for (index, color) in palette.ansi.enumerated() {
            expected.append("color\(index)              \(color)")
        }
        XCTAssertEqual(output, expected.joined(separator: "\n") + "\n")
    }

    func testGhosttyRendererGolden() {
        let palette = PalettePalette(theme: .defaultDark)
        let metadata = PaletteMetadata(
            source: "theme",
            theme: "Default Dark",
            appearance: "dark",
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let output = ThemingRenderer.contents(for: .ghostty, palette: palette, metadata: metadata)
        XCTAssertTrue(output?.hasPrefix("# generated by Palette — do not edit\n") == true)
        XCTAssertTrue(output?.contains("background = \(palette.background)") == true)
        XCTAssertTrue(output?.contains("palette = 0=\(palette.ansi[0])") == true)
        XCTAssertTrue(output?.contains("palette = 15=\(palette.ansi[15])") == true)
    }

    func testEveryImplementedRendererProducesItsShape() throws {
        let palette = PalettePalette(theme: .defaultDark)
        let metadata = PaletteMetadata(
            source: "theme",
            theme: "Default Dark",
            appearance: "dark",
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        for target in ThemingTarget.allCases where target.isImplemented && !target.isBrowser {
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
                XCTAssertTrue(output.contains("fish_color_command \(palette.ansi[4])"))
            case .starship:
                XCTAssertTrue(output.contains("[palettes.palette]"))
            case .bat:
                XCTAssertTrue(output.contains("<key>background</key>"))
                XCTAssertTrue(output.contains("<string>\(palette.background)</string>"))
            case .delta:
                XCTAssertTrue(output.contains("[delta]"))
                XCTAssertTrue(output.contains("line-numbers-plus-style"))
            case .btop:
                XCTAssertTrue(output.contains("theme[main_bg]=\"\(palette.background)\""))
            case .yazi:
                XCTAssertTrue(output.contains("[manager]"))
                XCTAssertTrue(output.contains("preview_title"))
            case .vscode, .zed, .helium, .neovide:
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
        XCTAssertEqual(ThemingTarget.neovide.unavailableReason, "Covered by Neovim — no separate file.")
        XCTAssertEqual(ThemingTarget.vscode.unavailableReason, "Not yet — VS Code needs a settings merge.")
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

    func testApplyWritesOnlyTheManagedDirectory() async throws {
        let paths = makePaths()
        let fakeKitty = URL(fileURLWithPath: paths.home, isDirectory: true)
            .appendingPathComponent(".config/kitty", isDirectory: true)
            .appendingPathComponent("kitty.conf")
        try FileManager.default.createDirectory(
            at: fakeKitty.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "user-owned kitty config".write(to: fakeKitty, atomically: true, encoding: .utf8)

        let engine = makeEngine(paths)
        var config = ThemingConfig(enabled: true, targets: phaseOneIDs)
        config.theme = "default-dark"
        _ = await engine.apply(config)

        XCTAssertEqual(try read(fakeKitty), "user-owned kitty config")
        let generated = try FileManager.default.contentsOfDirectory(atPath: paths.themeDir.path).sorted()
        XCTAssertEqual(
            generated,
            ["fish.fish", "ghostty.conf", "kitty.conf", "nvim.lua", "palette.json", "starship.toml", "zellij.kdl"]
        )
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

    func testOtherAppsInheritThePaletteThemeByDefault() async throws {
        let paths = makePaths()
        let engine = makeEngine(paths)
        let config = ThemingConfig(enabled: true, source: .theme, theme: "", targets: ["kitty"])
        _ = await engine.apply(config, fallbackThemeName: "catppuccin-mocha")

        let kitty = try read(paths.themeDir.appendingPathComponent("kitty.conf"))
        let mocha = ThemeLoader.load(name: "catppuccin-mocha", themesDirectory: paths.themesDir)
        XCTAssertTrue(kitty.contains("background            \(mocha.theme.palette.bg)"))
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

    // MARK: - Chromium browsers

    private func makeBrowserEngine(
        _ paths: PalettePaths,
        installed: Set<String> = ["net.imput.helium"],
        installedPolicies: Set<String> = [],
        running: Bool = false
    ) -> ThemingEngine {
        ThemingEngine(
            paths: paths,
            themesDirectory: paths.themesDir,
            chromiumProbe: ThemingEngine.ChromiumProbe(
                installed: { installed },
                policyInstalled: { installedPolicies.contains($0) },
                isRunning: { _ in running }
            )
        )
    }

    private func browserConfig(_ targets: [String]) -> ThemingConfig {
        ThemingConfig(
            enabled: true,
            source: .theme,
            theme: "default-dark",
            targets: targets
        )
    }

    func testChromiumBrowserCatalogue() {
        XCTAssertEqual(ChromiumBrowser.catalog.count, 7)
        XCTAssertEqual(
            ChromiumBrowser.catalog.map(\.bundleID),
            [
                "net.imput.helium",
                "com.google.Chrome",
                "com.microsoft.edgemac",
                "com.brave.Browser",
                "com.vivaldi.Vivaldi",
                "org.chromium.Chromium",
                "company.thebrowser.Browser",
            ]
        )
        XCTAssertEqual(ChromiumBrowser.browser(for: .chrome)?.name, "Google Chrome")
        XCTAssertEqual(ChromiumBrowser.browser(for: .helium)?.targetTitle, "Helium (managed policy)")
        XCTAssertEqual(ChromiumBrowser.browser(for: .arc)?.supportsThemePolicy, false)
        XCTAssertEqual(
            ChromiumBrowser.browser(for: .brave)?.policyIdentifier,
            "dev.myleshen.palette.chromium.com.brave.Browser"
        )
    }

    func testChromiumMobileConfigPerBrowser() {
        let palette = PalettePalette(theme: .defaultDark)
        for browser in ChromiumBrowser.catalog where browser.supportsThemePolicy {
            let xml = ChromiumPolicy.mobileConfig(browser: browser, palette: palette)
            XCTAssertTrue(xml.contains("<string>com.apple.ManagedClient.preferences</string>"))
            XCTAssertTrue(xml.contains("<key>\(browser.bundleID)</key>"))
            XCTAssertTrue(xml.contains("<key>Forced</key>"))
            XCTAssertTrue(xml.contains("<key>mcx_preference_settings</key>"))
            XCTAssertTrue(xml.contains("<key>BrowserThemeColor</key>"))
            XCTAssertTrue(xml.contains("<string>\(palette.background)</string>"))
            XCTAssertTrue(xml.contains(browser.policyIdentifier))
            XCTAssertFalse(xml.contains("Browser" + "ColorScheme"))
        }
    }

    func testBatchedInstallAndRemoveCommands() {
        let paths = [
            "/tmp/palette/helium-theme.mobileconfig",
            "/tmp/palette/chrome-theme.mobileconfig",
        ]
        XCTAssertEqual(
            ChromiumPolicy.installCommand(paths: paths),
            "sudo profiles install -path /tmp/palette/helium-theme.mobileconfig && sudo profiles install -path /tmp/palette/chrome-theme.mobileconfig"
        )
        let identifiers = [
            "dev.myleshen.palette.chromium.net.imput.helium",
            "dev.myleshen.palette.chromium.com.google.Chrome",
        ]
        XCTAssertEqual(
            ChromiumPolicy.removeCommand(identifiers: identifiers),
            "sudo profiles remove -identifier dev.myleshen.palette.chromium.net.imput.helium && sudo profiles remove -identifier dev.myleshen.palette.chromium.com.google.Chrome"
        )
    }

    func testInstalledBrowserDetectionWithInjectedSet() {
        let paths = makePaths()
        let engine = makeBrowserEngine(paths, installed: ["com.google.Chrome", "org.chromium.Chromium"])
        XCTAssertEqual(
            engine.installedBrowserIDs(),
            ["com.google.Chrome", "org.chromium.Chromium"]
        )
        XCTAssertEqual(
            engine.browserRows().map(\.bundleID),
            ["net.imput.helium", "com.google.Chrome", "org.chromium.Chromium"]
        )
    }

    func testApplySkipsUninstalledBrowserWithoutFailingTheRest() async throws {
        let paths = makePaths()
        let engine = makeBrowserEngine(paths, installed: ["net.imput.helium"])
        let config = browserConfig(["helium", "chrome"])

        let result = await engine.apply(config)

        XCTAssertNil(result.error)
        let helium = try XCTUnwrap(result.targets.first { $0.id == "helium" })
        XCTAssertEqual(helium.state, .written)
        let chrome = try XCTUnwrap(result.targets.first { $0.id == "chrome" })
        XCTAssertEqual(chrome.state, .skipped)
        XCTAssertTrue(chrome.note.contains("Google Chrome is not installed"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.themeDir.appendingPathComponent("helium-theme.mobileconfig").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.themeDir.appendingPathComponent("chrome-theme.mobileconfig").path
        ))
    }

    func testApplySkipsArcAsUnsupported() async throws {
        let paths = makePaths()
        let engine = makeBrowserEngine(paths, installed: ["company.thebrowser.Browser"])
        let result = await engine.apply(browserConfig(["arc"]))

        let arc = try XCTUnwrap(result.targets.first { $0.id == "arc" })
        XCTAssertEqual(arc.state, .skipped)
        XCTAssertTrue(arc.note.contains("BrowserThemeColor"))
        XCTAssertNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.themeDir.appendingPathComponent("arc-theme.mobileconfig").path
        ))
    }

    func testPolicyStatusWhenMissingAndPresent() async throws {
        let missingPaths = makePaths()
        let missingEngine = makeBrowserEngine(missingPaths, installedPolicies: [])
        let missing = await missingEngine.apply(browserConfig(["helium"]))
        XCTAssertTrue(missing.status.contains("Awaiting install in System Settings"))
        XCTAssertEqual(missingEngine.policyStates["net.imput.helium"], false)
        XCTAssertTrue(
            missingEngine.lastResult?.targets.first { $0.id == "helium" }?.note.contains("Not installed") == true
        )

        let installedPaths = makePaths()
        let installedEngine = makeBrowserEngine(
            installedPaths,
            installedPolicies: ["net.imput.helium"]
        )
        let installed = await installedEngine.apply(browserConfig(["helium"]))
        XCTAssertTrue(installed.status.contains("Managed policies installed"))
        XCTAssertEqual(installedEngine.policyStates["net.imput.helium"], true)
        XCTAssertEqual(
            installedEngine.lastResult?.targets.first { $0.id == "helium" }?.note,
            "Installed — all Helium profiles."
        )
    }

    func testOneMobileConfigPerSelectedBrowser() async throws {
        let paths = makePaths()
        let installed = ["net.imput.helium", "com.google.Chrome", "com.brave.Browser"]
        let engine = makeBrowserEngine(paths, installed: Set(installed), installedPolicies: Set(installed))
        let result = await engine.apply(browserConfig(["helium", "chrome", "brave"]))

        XCTAssertTrue(result.written.contains("helium-theme.mobileconfig"))
        XCTAssertTrue(result.written.contains("chrome-theme.mobileconfig"))
        XCTAssertTrue(result.written.contains("brave-theme.mobileconfig"))
        for (bundle, file) in [
            ("net.imput.helium", "helium-theme.mobileconfig"),
            ("com.google.Chrome", "chrome-theme.mobileconfig"),
            ("com.brave.Browser", "brave-theme.mobileconfig"),
        ] {
            let xml = try read(paths.themeDir.appendingPathComponent(file))
            XCTAssertTrue(xml.contains(ChromiumPolicy.identifier(for: bundle)))
        }
    }

    // MARK: - Settings structure

    func testSettingsSidebarGroupOrder() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PaletteApp/SettingsView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "static let sidebarGroups"))
        let tail = String(text[start.lowerBound...].prefix(1800))
        let titles = Self.matches(#"SettingsTabGroup\(title: "([^"]+)""#, in: tail)
        XCTAssertEqual(titles, ["Basics", "Features", "Theming", "Advanced", "System"])
        XCTAssertTrue(tail.contains(#"SettingsTabGroup(title: "Theming", tabs: [.theming])"#))
        let advanced = try XCTUnwrap(titles.firstIndex(of: "Advanced"))
        let system = try XCTUnwrap(titles.firstIndex(of: "System"))
        XCTAssertLessThan(advanced, system)
        XCTAssertEqual(system, titles.count - 1)
    }

    func testThemingIsTheLastSettingsTabCase() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PaletteApp/SettingsView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "enum SettingsTab: Int, CaseIterable, Identifiable {"))
        let end = try XCTUnwrap(text.range(of: "var id: Int { rawValue }", range: start.upperBound..<text.endIndex))
        let cases = Self.matches(#"case (\w+)"#, in: String(text[start.upperBound..<end.lowerBound]))
        XCTAssertEqual(cases.last, "theming")
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let value = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[value])
        }
    }
}
