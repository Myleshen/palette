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
        if body.contains(suffix) || body.contains(generated.path) {
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
        XCTAssertEqual(Set(applied.written), Set(targets.map(\.fileName) + ["palette.json"]))

        let blocks: [(String, ThemingIncludes.Format, String)] = [
            (".config/kitty/kitty.conf", .hash, "kitty.conf"),
            (".config/ghostty/config", .hash, "ghostty.conf"),
            (".config/zellij/config.kdl", .kdl, "zellij.kdl"),
            (".config/nvim/init.lua", .lua, "nvim.lua"),
            (".config/fish/config.fish", .hash, "fish.fish"),
            (".config/starship.toml", .hash, "starship.toml"),
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
        for target in targets {
            XCTAssertTrue(engine.includeStatus(for: target).installed, "\(target.title) reports not installed")
        }

        // Unchecking fish removes its block and its generated file, and nothing
        // else: the other five app configs keep their marker.
        let withoutFish = targets.filter { $0 != .fish }
        let unchecked = await engine.applyTheme(named: "catppuccin-mocha", config: theming(withoutFish))
        XCTAssertNil(unchecked.error, unchecked.error ?? "")
        XCTAssertEqual(data(".config/fish/config.fish"), originalBytes[".config/fish/config.fish"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: themeDir.appendingPathComponent("fish.fish").path))
        for (relative, format, _) in blocks where relative != ".config/fish/config.fish" {
            XCTAssertTrue(text(relative).contains(includes.startMarker(format)), "\(relative) lost its block")
        }
        XCTAssertFalse(engine.includeStatus(for: .fish).installed)

        // Revert restores every original byte, including starship's root key.
        let reverted = await engine.revert()
        XCTAssertNil(reverted.error, reverted.error ?? "")
        for (relative, bytes) in originalBytes {
            XCTAssertEqual(data(relative), bytes, "\(relative) was not restored byte for byte")
        }
        XCTAssertFalse(engine.includeStatus(for: .kitty).installed)
    }
}
