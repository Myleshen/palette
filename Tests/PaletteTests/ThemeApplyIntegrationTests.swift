import AppKit
import TOMLKit
import XCTest
import Foundation
import PaletteCore
import PalettePlatform

/// Apply writes a marked include block into each app's own config; unchecking
/// one target removes only that block; Revert puts every byte back. A sandbox
/// HOME keeps the real dotfiles untouched, and reloads are off so the test
/// cannot repaint the user's kitty window.
@MainActor
final class ThemeApplyIntegrationTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("palette-apply-\(UUID().uuidString)", isDirectory: true)
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var configDir: URL { home.appendingPathComponent(".config/palette", isDirectory: true) }
    private var themeDir: URL { configDir.appendingPathComponent("theme", isDirectory: true) }

    private var bundledThemes: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    private let originals: [String: String] = [
        ".config/kitty/kitty.conf": """
        font_family JetBrainsMono Nerd Font
        font_size 14
        background_opacity 0.95

        """,
        ".config/ghostty/config": """
        font-family = JetBrainsMono Nerd Font
        window-padding-x = 8

        """,
        ".config/zellij/config.kdl": """
        keybinds {
            normal {
                bind "Ctrl g" { SwitchToMode "Locked"; }
            }
        }

        """,
        ".config/nvim/init.lua": """
        vim.opt.number = true
        vim.opt.relativenumber = true

        """,
        ".config/fish/config.fish": """
        set -g fish_greeting ""
        abbr -a gs git status

        """,
        ".config/starship.toml": """
        add_newline = false
        [character]
        success_symbol = "[>](bold green)"

        """,
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        for (relative, text) in originals {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func text(_ relative: String) -> String {
        (try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    private func data(_ relative: String) -> Data {
        (try? Data(contentsOf: home.appendingPathComponent(relative))) ?? Data()
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
            chromiumProbe: ThemingEngine.ChromiumProbe(
                installed: { [] },
                isRunning: { _ in false },
                silentActive: { _ in false },
                legacyProfile: { _ in false }
            ),
            reloadsEnabled: false
        )
    }

    private func theming(_ targets: [ThemingTarget]) -> ThemingConfig {
        var config = ThemingConfig()
        config.enabled = true
        config.source = .theme
        config.theme = "catppuccin-mocha"
        config.targets = targets.map(\.rawValue)
        return config
    }

    /// A small striped picture so a wallpaper apply samples a fixture instead
    /// of whatever is on the user's desktop.
    private func writePicture(_ name: String = "wall.png") throws -> URL {
        let size = 64
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let colours: [NSColor] = [
            NSColor(red: 0.12, green: 0.14, blue: 0.24, alpha: 1),
            NSColor(red: 0.86, green: 0.30, blue: 0.35, alpha: 1),
            NSColor(red: 0.20, green: 0.70, blue: 0.45, alpha: 1),
            NSColor(red: 0.74, green: 0.62, blue: 0.20, alpha: 1),
        ]
        let bitmap = try XCTUnwrap(image)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for column in 0..<colours.count {
            colours[column].setFill()
            NSRect(
                x: column * (size / colours.count),
                y: 0,
                width: size / colours.count,
                height: size
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// With cross-app theming off nothing is generated, but the picture still
    /// owns Palette's own colours: pywal parity, one publish, no files.
    func testWallpaperApplyPublishesOnceWithoutWritingWhenThemingIsOff() async throws {
        let engine = makeEngine()
        var published = 0
        engine.onAppliedPalette = { _, metadata in
            published += 1
            XCTAssertEqual(metadata.source, "wallpaper")
        }
        engine.wallpaperURLOverride = try writePicture()

        var config = ThemingConfig()
        config.enabled = false
        config.source = .theme
        let result = await engine.applyWallpaper(config)

        XCTAssertNil(result.error)
        XCTAssertEqual(published, 1, "one palette pass, no double apply")
        XCTAssertTrue(result.written.isEmpty, "cross-app theming is off")
        XCTAssertEqual(result.source, "wallpaper")
        XCTAssertEqual(result.appearance, "dark")
        XCTAssertTrue(
            result.status.contains("Cross-app theming is off"),
            "the report says why no files were written: \(result.status)"
        )
    }

    /// The deck may find the source on Theme; the picture still takes over.
    func testWallpaperApplyIgnoresTheSourceItFound() async throws {
        let engine = makeEngine()
        var published = 0
        engine.onAppliedPalette = { _, _ in published += 1 }
        engine.wallpaperURLOverride = try writePicture()

        var config = theming([.kitty])
        config.source = .theme
        let result = await engine.applyWallpaper(config)

        XCTAssertNil(result.error)
        XCTAssertEqual(published, 1)
        XCTAssertFalse(result.written.isEmpty, "an enabled engine writes the generated files")
        XCTAssertEqual(engine.lastResult?.source, "wallpaper")
    }

    /// Every engine apply announces the palette so Palette's own surfaces can
    /// follow it. This is the hook that keeps the launcher and the embedded
    /// terminal from keeping an old palette while other apps get the new one.
    func testApplyPublishesThePaletteForPalettesOwnTheme() async throws {
        let engine = makeEngine()
        var seen: (PalettePalette, PaletteMetadata)?
        engine.onAppliedPalette = { palette, metadata in
            seen = (palette, metadata)
        }

        let result = await engine.applyTheme(named: "catppuccin-mocha", config: theming([.kitty]))

        XCTAssertNil(result.error)
        XCTAssertEqual(seen?.1.source, "theme")
        XCTAssertEqual(seen?.1.themeID, "catppuccin-mocha")
        XCTAssertEqual(seen?.0.background, "#1e1e2e")
        XCTAssertEqual(seen?.0.foreground, "#cdd6f4")
    }

    /// Kitty, Ghostty, Neovim and fish name the generated file; Zellij inlines
    /// its theme block and Starship inlines the palette table. The generated
    /// file is always absolute under the sandbox theme directory; the include
    /// itself is home-relative (`~/…`), so it resolves against the sandbox
    /// HOME rather than the machine running the test.
    private func assertInclude(
        _ relative: String,
        file: String,
        startMarker: String,
        endMarker: String
    ) throws {
        let body = text(relative)
        XCTAssertTrue(body.contains(startMarker), "\(relative): missing start marker")
        XCTAssertTrue(body.contains(endMarker), "\(relative): missing end marker")

        let generated = themeDir.appendingPathComponent(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: generated.path), "\(generated.path) was not generated")
        XCTAssertTrue(generated.path.hasPrefix("/"), "generated path is not absolute")

        let suffix = "~/.config/palette/theme/\(file)"
        if body.contains(suffix) || body.contains(generated.path) || body.contains(StarshipTheme.snippetFileName) {
            // kitty keeps the documented `~` form; Ghostty, Neovim and fish
            // use the absolute path because their config syntax may not expand it.
            let resolved = home.path + suffix.dropFirst()
            XCTAssertEqual(
                URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path,
                generated.resolvingSymlinksInPath().path
            )
        } else {
            // Zellij and Starship carry the body, not an include path.
            XCTAssertTrue(
                body.contains("theme \"palette\"") || body.contains("[palettes.palette]"),
                "\(relative): no include path and no inline palette body"
            )
        }
    }

    func testApplyUncheckAndRevertInASandboxHome() async throws {
        guard FileManager.default.fileExists(atPath: bundledThemes.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        let originalBytes = Dictionary(uniqueKeysWithValues: originals.map { ($0.key, data($0.key)) })
        let targets: [ThemingTarget] = [.kitty, .ghostty, .zellij, .nvim, .fish, .starship]
        let engine = makeEngine()

        let applied = await engine.applyTheme(named: "catppuccin-mocha", config: theming(targets))
        XCTAssertNil(applied.error, applied.error ?? "")
        XCTAssertEqual(
            Set(applied.written),
            Set(targets.map(\.fileName) + ["palette.json", StarshipTheme.fileName, StarshipTheme.snippetFileName])
        )

        let blocks: [(String, ThemingIncludes.Format, String)] = [
            (".config/kitty/kitty.conf", .hash, "kitty.conf"),
            (".config/ghostty/config", .hash, "ghostty.conf"),
            (".config/zellij/config.kdl", .kdl, "zellij.kdl"),
            (".config/nvim/init.lua", .lua, "nvim.lua"),
            (".config/fish/config.fish", .hash, "fish.fish"),
        ]
        let includes = ThemingIncludes(home: home.path, themeDir: themeDir)
        for (relative, format, file) in blocks {
            for line in (originals[relative] ?? "").components(separatedBy: "\n") where !line.isEmpty {
                XCTAssertTrue(text(relative).contains(line), "\(relative): lost original line '\(line)'")
            }
            try assertInclude(
                relative,
                file: file,
                startMarker: includes.startMarker(format),
                endMarker: includes.endMarker(format)
            )
        }

        // Starship is never edited. Palette writes a remapped copy and fish
        // exports STARSHIP_CONFIG, so the user's own file stays byte-identical.
        XCTAssertEqual(data(".config/starship.toml"), originalBytes[".config/starship.toml"])
        let mocha = PalettePalette(theme: ThemeLoader.load(name: "catppuccin-mocha", themesDirectory: bundledThemes).theme)
        let themed = try TOMLTable(string: String(contentsOf: themeDir.appendingPathComponent(StarshipTheme.fileName), encoding: .utf8))
        XCTAssertEqual(themed.table("character")?.str("success_symbol"), "[>](bold \(mocha.ansi[2]))")
        let snippet = try String(
            contentsOf: themeDir.appendingPathComponent(StarshipTheme.snippetFileName),
            encoding: .utf8
        )
        XCTAssertTrue(snippet.contains("set -gx STARSHIP_CONFIG \(themeDir.appendingPathComponent(StarshipTheme.fileName).path)"))

        let fishBody = text(".config/fish/config.fish").components(separatedBy: "\n")
        let fishStart = try XCTUnwrap(fishBody.firstIndex(of: includes.startMarker(.hash)))
        let fishEnd = try XCTUnwrap(fishBody.firstIndex(of: includes.endMarker(.hash)))
        XCTAssertEqual(
            Array(fishBody[(fishStart + 1)..<fishEnd]),
            ["source \(themeDir.appendingPathComponent(StarshipTheme.snippetFileName).path)"]
        )

        for target in targets {
            XCTAssertTrue(engine.includeStatus(for: target).installed, "\(target.title) reports not installed")
        }
        XCTAssertTrue(engine.includeStatus(for: .starship).note.contains("fish sets STARSHIP_CONFIG"))

        // Unchecking fish removes its block and its generated file, and nothing
        // else: the other four app configs keep their marker and Starship's
        // snippet stays for a shell that sets STARSHIP_CONFIG by hand.
        let withoutFish = targets.filter { $0 != .fish }
        let unchecked = await engine.applyTheme(named: "catppuccin-mocha", config: theming(withoutFish))
        XCTAssertNil(unchecked.error, unchecked.error ?? "")
        XCTAssertEqual(data(".config/fish/config.fish"), originalBytes[".config/fish/config.fish"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: themeDir.appendingPathComponent("fish.fish").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: themeDir.appendingPathComponent(StarshipTheme.snippetFileName).path))
        for (relative, format, _) in blocks where relative != ".config/fish/config.fish" {
            XCTAssertTrue(text(relative).contains(includes.startMarker(format)), "\(relative) lost its block")
        }
        XCTAssertFalse(engine.includeStatus(for: .fish).installed)
        XCTAssertTrue(engine.includeStatus(for: .starship).note.contains("export STARSHIP_CONFIG"))

        // Revert restores every original byte; starship.toml was never touched.
        let reverted = await engine.revert()
        XCTAssertNil(reverted.error, reverted.error ?? "")
        for (relative, bytes) in originalBytes {
            XCTAssertEqual(data(relative), bytes, "\(relative) was not restored byte for byte")
        }
        XCTAssertFalse(engine.includeStatus(for: .kitty).installed)
    }

    func testStarshipRegeneratesTheRemappedCopyOnThemeChangeWithoutTouchingTheUserFile() async throws {
        guard FileManager.default.fileExists(atPath: bundledThemes.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        let userBytes = data(".config/starship.toml")
        var config = theming([.fish, .starship])
        let engine = makeEngine()

        _ = await engine.applyTheme(named: "catppuccin-mocha", config: config)
        let mochaPalette = PalettePalette(
            theme: ThemeLoader.load(name: "catppuccin-mocha", themesDirectory: bundledThemes).theme
        )
        let mocha = try TOMLTable(string: text(".config/palette/theme/\(StarshipTheme.fileName)"))
        XCTAssertEqual(mocha.table("character")?.str("success_symbol"), "[>](bold \(mochaPalette.ansi[2]))")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: themeDir.appendingPathComponent("starship.toml").path),
            "the unused palette-table copy must not be generated"
        )

        config.theme = "default-light"
        _ = await engine.applyTheme(named: "default-light", config: config)
        let lightPalette = PalettePalette(theme: .defaultLight)
        let light = try TOMLTable(string: text(".config/palette/theme/\(StarshipTheme.fileName)"))
        XCTAssertEqual(light.table("character")?.str("success_symbol"), "[>](bold \(lightPalette.ansi[2]))")
        XCTAssertNotEqual(mochaPalette.ansi[2], lightPalette.ansi[2])

        XCTAssertEqual(data(".config/starship.toml"), userBytes)
    }

    func testCustomPaletteValuesAreRecolouredAndFollowTheTheme() async throws {
        guard FileManager.default.fileExists(atPath: bundledThemes.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        let user = """
        palette = "noctalia"
        format = "$directory"

        [directory]
        style = "fg:pink bold"

        [palettes.noctalia]
        pink = "#ffacea"
        text = "#f2dde8"
        flamingo = "#ffb4ab"
        subtext0 = "#a28a99"

        """
        let starshipPath = home.appendingPathComponent(".config/starship.toml")
        try user.write(to: starshipPath, atomically: true, encoding: .utf8)
        let userBytes = data(".config/starship.toml")
        let engine = makeEngine()
        var config = theming([.starship])

        func recoloured() throws -> [String: String] {
            let table = try TOMLTable(string: text(".config/palette/theme/\(StarshipTheme.fileName)"))
            let values = try XCTUnwrap(table.table("palettes")?.table("noctalia"))
            return Dictionary(uniqueKeysWithValues: values.keys.map { ($0, values.str($0) ?? "") })
        }

        _ = await engine.applyTheme(named: "catppuccin-mocha", config: config)
        let mocha = try recoloured()
        let mochaPalette = PalettePalette(
            theme: ThemeLoader.load(name: "catppuccin-mocha", themesDirectory: bundledThemes).theme
        )
        let allowed = Set(
            [mochaPalette.background, mochaPalette.foreground, mochaPalette.cursor,
             mochaPalette.selectionBackground, mochaPalette.selectionForeground] + mochaPalette.ansi
        )
        let originals = [
            "pink": "#ffacea",
            "text": "#f2dde8",
            "flamingo": "#ffb4ab",
            "subtext0": "#a28a99",
        ]
        XCTAssertEqual(Set(mocha.keys), Set(originals.keys))
        for (key, original) in originals {
            let value = try XCTUnwrap(mocha[key])
            XCTAssertNotEqual(value, original, "\(key) was not recoloured")
            XCTAssertTrue(allowed.contains(value), "\(key) mapped to \(value), outside the Palette colours")
        }

        config.theme = "default-light"
        _ = await engine.applyTheme(named: "default-light", config: config)
        let light = try recoloured()

        XCTAssertEqual(Set(mocha.keys), Set(light.keys))
        XCTAssertNotEqual(mocha, light)
        XCTAssertEqual(data(".config/starship.toml"), userBytes)
    }
}
