import XCTest
import PaletteCore

/// The scanner is pure, so every rule is exercised against a temp home that
/// mirrors one real user config pattern.
final class ThemingAdviceTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-advice-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func write(_ text: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func scan(_ targets: Set<ThemingTarget> = Set(ThemingTarget.allCases)) -> [ThemingAdvice] {
        ThemingAdvice.scan(
            home: home.path,
            enabledTargets: targets
        )
    }

    // MARK: - nvim

    func testNvimPluginOptsColorschemeIsBlockingAtItsLine() throws {
        try write(
            """
            return {
              { "LazyVim/LazyVim",
                opts = {
                  colorscheme = "tokyonight",
                },
              },
            }
            """,
            to: ".config/nvim/lua/plugins/colors.lua"
        )

        let rows = scan([.nvim])
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.target, .nvim)
        XCTAssertEqual(row.severity, .blocking)
        XCTAssertEqual(row.file, "~/.config/nvim/lua/plugins/colors.lua")
        XCTAssertEqual(row.line, 4)
        XCTAssertTrue(row.message.contains("ColorScheme/VimEnter"))
    }

    func testNvimInstallTableColorschemeIsAWarning() throws {
        try write(
            """
            require("lazy").setup({
              install = { colorscheme = { "tokyonight", "habamax" } },
            })
            """,
            to: ".config/nvim/lua/config/lazy.lua"
        )

        let rows = scan([.nvim])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.severity, .warning)
        XCTAssertEqual(rows.first?.line, 2)
    }

    func testNvimTernaryColorschemeIsBlocking() throws {
        try write(
            """
            return {
              {
                "LazyVim/LazyVim",
                opts = {
                  colorscheme = vim.fn.has("mac") == 1 and "aetheria" or "noctalia",
                },
              },
            }
            """,
            to: ".config/nvim/lua/plugins/noctalia.lua"
        )

        let rows = scan([.nvim])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.severity, .blocking)
        XCTAssertEqual(rows.first?.line, 5)
    }

    func testNvimCommandsAndProtectedHighlightsAreBlocking() throws {
        try write(
            """
            vim.o.background = "dark"
            vim.cmd.colorscheme("habamax")
            vim.api.nvim_set_hl(0, "Normal", { bg = "#000000" })
            vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#000000" })
            vim.api.nvim_set_hl(0, "Visual", { bg = "#000000" })
            vim.api.nvim_set_hl(0, "WinBar", { bg = nil })
            """,
            to: ".config/nvim/lua/config/options.lua"
        )

        let rows = scan([.nvim])
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.line), [1, 2, 3, 4, 5])
        XCTAssertTrue(rows.allSatisfy { $0.severity == .blocking })
        XCTAssertFalse(rows.contains { $0.message.contains("WinBar") })
    }

    func testCommentedNvimRulesAreIgnored() throws {
        try write(
            """
            -- colorscheme = "tokyonight"
            -- vim.cmd.colorscheme("habamax")
            -- vim.api.nvim_set_hl(0, "Normal", { bg = "#000000" })
            """,
            to: ".config/nvim/lua/config/options.lua"
        )

        XCTAssertTrue(scan([.nvim]).isEmpty)
    }

    // MARK: - Starship

    func testStarshipForeignPaletteIsBlocking() throws {
        try write(
            """
            palette = "noctalia"

            [palettes.noctalia]
            pink = "#ff00ff"
            """,
            to: ".config/starship.toml"
        )

        let rows = scan([.starship])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.target, .starship)
        XCTAssertEqual(rows.first?.severity, .blocking)
        XCTAssertEqual(rows.first?.line, 1)
        XCTAssertTrue(rows.first?.message.contains("noctalia") == true)
    }

    func testStarshipOwnPaletteAndNestedKeysAreFine() throws {
        try write(
            """
            palette = "palette"

            [palettes.noctalia]
            palette = "something-else"
            """,
            to: ".config/starship.toml"
        )

        XCTAssertTrue(scan([.starship]).isEmpty)
    }

    // MARK: - fish

    func testFishStarshipConfigOutsideTheManagedBlockIsBlocking() throws {
        try write(
            """
            starship init fish | source
            set -gx STARSHIP_CONFIG ~/.config/starship.toml
            # >>> palette theme >>>
            source /Users/x/.config/palette/theme/starship-palette.fish
            # <<< palette theme <<<
            """,
            to: ".config/fish/config.fish"
        )

        let rows = scan([.fish])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.target, .fish)
        XCTAssertEqual(rows.first?.severity, .blocking)
        XCTAssertEqual(rows.first?.line, 2)
    }

    func testFishStarshipConfigPointingAtTheThemedCopyIsFine() throws {
        try write(
            """
            set -gx STARSHIP_CONFIG ~/.config/palette/theme/starship-theme.toml
            """,
            to: ".config/fish/config.fish"
        )
        try write(
            """
            set -gx STARSHIP_CONFIG "$HOME/.config/palette/theme/starship-theme.toml"
            """,
            to: ".config/fish/conf.d/starship.fish"
        )

        XCTAssertTrue(scan([.fish]).isEmpty)
    }

    // MARK: - zellij

    func testZellijThemeOutsideTheManagedBlockIsBlocking() throws {
        try write(
            """
            theme "noctalia"
            // >>> palette theme >>>
            themes {
                palette {
                    text "#ffffff"
                }
            }
            theme "palette"
            // <<< palette theme <<<
            """,
            to: ".config/zellij/config.kdl"
        )

        let rows = scan([.zellij])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.target, .zellij)
        XCTAssertEqual(rows.first?.severity, .blocking)
        XCTAssertEqual(rows.first?.line, 1)
        XCTAssertTrue(rows.first?.message.contains("Duplicate theme key") == true)
    }

    func testZellijManagedBlockAloneIsFine() throws {
        try write(
            """
            // >>> palette theme >>>
            themes {
                palette {
                    text "#ffffff"
                }
            }
            theme "palette"
            // <<< palette theme <<<
            """,
            to: ".config/zellij/config.kdl"
        )

        XCTAssertTrue(scan([.zellij]).isEmpty)
    }

    // MARK: - kitty

    func testKittyColoursAfterTheIncludeAreBlocking() throws {
        try write(
            """
            background #000000
            include ~/.config/palette/theme/kitty.conf
            background #ffffff
            foreground #eeeeee
            color0 #111111
            color255 #222222
            cursor #ff0000
            cursor_trail 1
            background_opacity 0.9
            """,
            to: ".config/kitty/kitty.conf"
        )

        let rows = scan([.kitty])
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.line), [3, 4, 5, 6, 7])
        XCTAssertTrue(rows.allSatisfy { $0.severity == .blocking })
        XCTAssertEqual(rows.first?.target, .kitty)
        XCTAssertEqual(rows.first?.file, "~/.config/kitty/kitty.conf")
    }

    func testKittyColoursBeforeTheIncludeAreFine() throws {
        try write(
            """
            background #000000
            foreground #eeeeee
            include ~/.config/palette/theme/kitty.conf
            """,
            to: ".config/kitty/kitty.conf"
        )

        XCTAssertTrue(scan([.kitty]).isEmpty)
    }

    // MARK: - ghostty

    func testGhosttyThemeAfterTheIncludeIsBlocking() throws {
        try write(
            """
            theme = "light:foo"
            config-file = \(home.path)/.config/palette/theme/ghostty.conf
            theme = "dark:bar"
            """,
            to: ".config/ghostty/config"
        )

        let rows = scan([.ghostty])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.severity, .blocking)
        XCTAssertEqual(rows.first?.line, 3)
        XCTAssertEqual(rows.first?.target, .ghostty)
    }

    // MARK: - Neovide

    func testNeovideForkIsAWarning() throws {
        try write(
            """
            frame = "none"
            fork = true
            """,
            to: ".config/neovide/config.toml"
        )

        let rows = scan([.nvim])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.target, .nvim)
        XCTAssertEqual(rows.first?.severity, .warning)
        XCTAssertEqual(rows.first?.line, 2)
        XCTAssertTrue(rows.first?.message.contains("Neovide runs detached") == true)
    }

    func testNeovideWithoutForkIsFine() throws {
        try write(
            """
            frame = "none"
            fork = false
            """,
            to: ".config/neovide/config.toml"
        )

        XCTAssertTrue(scan([.nvim]).isEmpty)
    }

    // MARK: - Robustness and scoping

    func testUnreadableFileReturnsAWarningRow() throws {
        // A directory where the file should be: it exists, but cannot be read.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".config/starship.toml"),
            withIntermediateDirectories: true
        )

        let rows = scan([.starship])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.target, .starship)
        XCTAssertEqual(rows.first?.severity, .warning)
        XCTAssertTrue(rows.first?.message.contains("cannot read") == true)
    }

    func testOnlyEnabledTargetsAreReported() throws {
        try write("colorscheme = \"tokyonight\"", to: ".config/nvim/lua/config/colors.lua")
        try write(
            """
            include ~/.config/palette/theme/kitty.conf
            background #ffffff
            """,
            to: ".config/kitty/kitty.conf"
        )

        let rows = scan([.kitty])
        XCTAssertEqual(rows.map(\.target), [.kitty])
    }
}
