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
                policyInstalled: { _ in false },
                isRunning: { _ in false }
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

    func testStarshipRegeneratesBothTOMLsOnThemeChangeWithoutTouchingTheUserFile() async throws {
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
        XCTAssertTrue(text(".config/palette/theme/starship.toml").contains("[palettes.palette]"))

        config.theme = "default-light"
        _ = await engine.applyTheme(named: "default-light", config: config)
        let lightPalette = PalettePalette(theme: .defaultLight)
        let light = try TOMLTable(string: text(".config/palette/theme/\(StarshipTheme.fileName)"))
        XCTAssertEqual(light.table("character")?.str("success_symbol"), "[>](bold \(lightPalette.ansi[2]))")
        XCTAssertNotEqual(mochaPalette.ansi[2], lightPalette.ansi[2])

        // The palette definition file follows the same theme change.
        let paletteFile = try TOMLTable(string: text(".config/palette/theme/starship.toml"))
        XCTAssertEqual(paletteFile.table("palettes")?.table("palette")?.str("green"), lightPalette.ansi[2])

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
