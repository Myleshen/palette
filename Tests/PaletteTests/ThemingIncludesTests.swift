import TOMLKit
import XCTest
import PaletteCore
import PalettePlatform

final class ThemingIncludesTests: XCTestCase {
    private func makeHome() -> String {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palette-includes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.path
    }

    private func includes(_ home: String) -> ThemingIncludes {
        ThemingIncludes(
            home: home,
            themeDir: URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("config/theme", isDirectory: true)
        )
    }

    private func palette() -> PalettePalette { PalettePalette(theme: .defaultDark) }

    private func metadata() -> PaletteMetadata {
        PaletteMetadata(
            source: "theme",
            theme: "Default Dark",
            appearance: "dark",
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func install(_ includes: ThemingIncludes, _ target: ThemingTarget) -> ThemingIncludes.Outcome {
        includes.install(target, palette: palette(), metadata: metadata())
    }

    private func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Markers per syntax

    func testMarkersUseTheCommentSyntaxOfEachFormat() throws {
        let home = makeHome()
        let includes = includes(home)

        XCTAssertNil(install(includes, .kitty).error)
        XCTAssertTrue(try read(home + "/.config/kitty/kitty.conf").contains("# >>> palette theme >>>"))

        XCTAssertNil(install(includes, .zellij).error)
        let zellij = try read(home + "/.config/zellij/config.kdl")
        XCTAssertTrue(zellij.hasPrefix("// >>> palette theme >>>"))
        XCTAssertTrue(zellij.contains("themes {"))
        XCTAssertTrue(zellij.contains("theme \"palette\""))

        XCTAssertNil(install(includes, .nvim).error)
        let lua = try read(home + "/.config/nvim/init.lua")
        XCTAssertTrue(lua.hasPrefix("-- >>> palette theme >>>"))
        XCTAssertTrue(lua.contains("dofile(\"\(home)/config/theme/nvim.lua\")"))

        XCTAssertNil(install(includes, .fish).error)
        XCTAssertTrue(try read(home + "/.config/fish/config.fish").contains("# >>> palette theme >>>"))
    }

    /// A shell that inherited no STARSHIP_CONFIG (a zellij server started
    /// before the setting existed) reads the user's starship.toml, so that file
    /// must carry the current palette too — between markers, never touching the
    /// user's own lines.
    func testStarshipInstallUpdatesOnlyItsPaletteBlock() throws {
        let home = makeHome()
        let path = home + "/.config/starship.toml"
        let original = "# user starship\nadd_newline = false\n\npalette = \"palette\"\n\n[character]\nsuccess_symbol = \">\"\n"
        try write(original, to: path)
        let includes = includes(home)

        _ = install(includes, .starship)
        let first = try read(path)
        XCTAssertTrue(first.contains("# >>> palette theme >>>"))
        XCTAssertTrue(first.contains("[palettes.palette]"))
        XCTAssertTrue(first.contains("# user starship"))
        XCTAssertTrue(first.contains("[character]"))

        let second = try read(path)
        let block = first.components(separatedBy: "# >>> palette theme >>>").last?
            .components(separatedBy: "# <<< palette theme <<<").first
        XCTAssertNotNil(block)
        XCTAssertEqual(
            first.components(separatedBy: "# >>> palette theme >>>").count, 2,
            "a second apply must replace the block, not append another"
        )
        XCTAssertEqual(second, first)

        XCTAssertEqual(includes.remove(.starship).action, .removed)
        XCTAssertFalse(try read(path).contains("[palettes.palette]"))
        XCTAssertTrue(try read(path).contains("# user starship"))
    }

    func testVimFallbackUsesVimCommentsAndSource() throws {
        let home = makeHome()
        try write("\" user vimrc\nset number\n", to: home + "/.config/nvim/init.vim")
        let includes = includes(home)

        XCTAssertEqual(includes.plan(for: .nvim)?.format, .vim)
        XCTAssertNil(install(includes, .nvim).error)

        let vim = try read(home + "/.config/nvim/init.vim")
        XCTAssertTrue(vim.contains("\" >>> palette theme >>>"))
        XCTAssertTrue(vim.contains("source \(home)/config/theme/nvim.lua"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.config/nvim/init.lua"))
    }

    func testIncludeLinesUseAbsolutePathsExceptKitty() throws {
        let home = makeHome()
        let includes = includes(home)
        let theme = home + "/config/theme"

        XCTAssertNil(install(includes, .kitty).error)
        XCTAssertTrue(try read(home + "/.config/kitty/kitty.conf").contains("include ~/config/theme/kitty.conf"))

        XCTAssertNil(install(includes, .ghostty).error)
        XCTAssertTrue(try read(home + "/.config/ghostty/config").contains("config-file = \(theme)/ghostty.conf"))

        XCTAssertNil(install(includes, .fish).error)
        XCTAssertTrue(try read(home + "/.config/fish/config.fish").contains("source \(theme)/fish.fish"))

        XCTAssertNil(install(includes, .delta).error)
        XCTAssertTrue(try read(home + "/.config/git/config").contains("path = \(theme)/gitconfig-delta"))
    }

    func testAnOldTildeBlockIsReplacedWithTheAbsoluteOne() throws {
        let home = makeHome()
        let path = home + "/.config/ghostty/config"
        try write(
            "font-size = 13\n# >>> palette theme >>>\nconfig-file = ~/config/theme/ghostty.conf\n# <<< palette theme <<<\n",
            to: path
        )
        let includes = includes(home)

        XCTAssertEqual(install(includes, .ghostty).action, .installed)
        let updated = try read(path)
        XCTAssertEqual(updated, "font-size = 13\n# >>> palette theme >>>\nconfig-file = \(home)/config/theme/ghostty.conf\n# <<< palette theme <<<\n")
        XCTAssertEqual(updated.components(separatedBy: "# >>> palette theme >>>").count, 2)
    }

    // MARK: - Idempotence

    func testApplyingTwiceLeavesOneBlock() throws {
        let home = makeHome()
        try write("# user kitty\nfont_size 13\n", to: home + "/.config/kitty/kitty.conf")
        let includes = includes(home)

        XCTAssertEqual(install(includes, .kitty).action, .installed)
        let once = try read(home + "/.config/kitty/kitty.conf")
        XCTAssertEqual(install(includes, .kitty).action, .unchanged)
        let twice = try read(home + "/.config/kitty/kitty.conf")

        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice.components(separatedBy: "# >>> palette theme >>>").count, 2)
        XCTAssertEqual(twice.components(separatedBy: "# <<< palette theme <<<").count, 2)
    }

    func testKittyBlockOwnsSocketOnlyRemoteControlAndReportsItOnce() throws {
        let home = makeHome()
        try write("listen_on unix:${XDG_RUNTIME_DIR}/omarchy-kitty-{kitty_pid}\n", to: home + "/.config/kitty/kitty.conf")
        let includes = includes(home)

        let first = install(includes, .kitty)
        XCTAssertTrue(first.addedRemoteControl, "the first Apply is the one that needs the restart")
        let text = try read(home + "/.config/kitty/kitty.conf")
        XCTAssertTrue(text.contains(
            "allow_remote_control socket-only\n"
                + "# Palette overrides listen_on so it can recolour this window live; unchecking restores your own line.\n"
                + "listen_on unix:${TMPDIR}palette-kitty-{kitty_pid}\n"
                + "include ~/config/theme/kitty.conf"
        ))
        XCTAssertTrue(text.contains("listen_on unix:${XDG_RUNTIME_DIR}/omarchy-kitty-{kitty_pid}"), "the user's listener stays")
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "omarchy-kitty-{kitty_pid}")?.lowerBound),
            try XCTUnwrap(text.range(of: "palette-kitty-{kitty_pid}")?.lowerBound),
            "the managed listener must come after the user's line; kitty keeps the last one"
        )

        let second = install(includes, .kitty)
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertFalse(second.addedRemoteControl, "the directive is in the config now, so no second restart hint")
        XCTAssertEqual(try read(home + "/.config/kitty/kitty.conf"), text)

        _ = includes.remove(.kitty)
        let restored = try read(home + "/.config/kitty/kitty.conf")
        XCTAssertEqual(
            restored,
            "listen_on unix:${XDG_RUNTIME_DIR}/omarchy-kitty-{kitty_pid}\n",
            "removing the block restores the user's own listener"
        )
    }

    func testRemovalRestoresTheUnrelatedContentByteForByte() throws {
        let home = makeHome()
        let path = home + "/.config/kitty/kitty.conf"
        let original = "# user kitty\nfont_family JetBrains Mono\nfont_size 13\n"
        try write(original, to: path)
        let includes = includes(home)

        XCTAssertEqual(install(includes, .kitty).action, .installed)
        XCTAssertNotEqual(try read(path), original)
        XCTAssertEqual(includes.remove(.kitty).action, .removed)
        XCTAssertEqual(try read(path), original)
    }

    // MARK: - Symlinks and file modes

    func testWritesThroughASymlinkAndKeepsItASymlink() throws {
        let home = makeHome()
        try write("original\n", to: home + "/dot-files/kitty.conf")
        let config = home + "/.config/kitty/kitty.conf"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: config).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: config),
            withDestinationURL: URL(fileURLWithPath: home + "/dot-files/kitty.conf")
        )
        let includes = includes(home)

        XCTAssertNil(install(includes, .kitty).error)

        let target = try read(home + "/dot-files/kitty.conf")
        XCTAssertTrue(target.hasPrefix("original\n"))
        XCTAssertTrue(target.contains("# >>> palette theme >>>"))
        let attributes = try FileManager.default.attributesOfItem(atPath: config)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testPreservesFileMode() throws {
        let home = makeHome()
        let path = home + "/.config/kitty/kitty.conf"
        try write("user\n", to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: path)
        let includes = includes(home)

        XCTAssertNil(install(includes, .kitty).error)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o751)
    }

    // MARK: - Creation and revert

    func testMissingConfigIsCreatedWithOnlyTheBlockAndDeletedOnRevert() throws {
        let home = makeHome()
        let includes = includes(home)
        let path = home + "/.config/ghostty/config"

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(install(includes, .ghostty).error)
        let created = try read(path)
        XCTAssertTrue(created.hasPrefix("# >>> palette theme >>>\n"))
        XCTAssertTrue(created.contains("config-file = \(home)/config/theme/ghostty.conf"))

        let outcomes = includes.revert()
        XCTAssertEqual(outcomes.first { $0.target == .ghostty }?.action, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRevertRestoresTheOriginalFile() throws {
        let home = makeHome()
        let path = home + "/.config/fish/config.fish"
        let original = "set -g fish_greeting \"\"\n"
        try write(original, to: path)
        let includes = includes(home)

        XCTAssertNil(install(includes, .fish).error)
        XCTAssertNotEqual(try read(path), original)
        let outcomes = includes.revert()
        XCTAssertEqual(outcomes.first { $0.target == .fish }?.action, .restored)
        XCTAssertEqual(try read(path), original)
        XCTAssertFalse(includes.hasBackups)
    }

    func testBackupIsTakenOnlyOnce() throws {
        let home = makeHome()
        let path = home + "/.config/kitty/kitty.conf"
        try write("original\n", to: path)
        let includes = includes(home)

        XCTAssertNil(install(includes, .kitty).error)
        let backup = home + "/config/theme/previous/kitty-kitty.conf.orig"
        XCTAssertEqual(try read(backup), "original\n")

        // A user edit after the first apply must survive; the backup must not
        // be replaced by the edited file.
        try write(try read(path) + "user edit after install\n", to: path)
        XCTAssertNil(install(includes, .kitty).error)
        XCTAssertEqual(try read(backup), "original\n")
        XCTAssertTrue(try read(path).contains("user edit after install\n"))

        let backups = try FileManager.default.contentsOfDirectory(atPath: home + "/config/theme/previous")
        XCTAssertEqual(backups.filter { $0 == "kitty-kitty.conf.orig" }.count, 1)
    }

    func testRevertKeepsSettingsTheUserAddedAfterTheFirstApply() throws {
        let home = makeHome()
        let path = home + "/.config/kitty/kitty.conf"
        let original = "font_size 13\n"
        try write(original, to: path)
        let includes = includes(home)

        XCTAssertNil(install(includes, .kitty).error)
        // The user keeps editing the file after Palette's block was installed.
        try write(try read(path) + "background_opacity 0.9\n", to: path)

        let outcomes = includes.revert()
        XCTAssertEqual(outcomes.first { $0.target == .kitty }?.action, .restored)
        XCTAssertEqual(try read(path), original + "background_opacity 0.9\n")
        XCTAssertFalse(includes.hasBackups)
    }

    func testRevertKeepsUserContentWrittenIntoAPaletteCreatedFile() throws {
        let home = makeHome()
        let path = home + "/.config/kitty/kitty.conf"
        let includes = includes(home)

        XCTAssertNil(install(includes, .kitty).error)
        try write(try read(path) + "font_size 15\n", to: path)

        XCTAssertEqual(includes.revert().first { $0.target == .kitty }?.action, .restored)
        XCTAssertEqual(try read(path), "font_size 15\n")
    }

    func testRevertRestoresTheSnapshotWhenTheBlockWasRemovedByHand() throws {
        let home = makeHome()
        let path = home + "/.config/kitty/kitty.conf"
        let original = "font_size 13\n"
        try write(original, to: path)
        let includes = includes(home)

        XCTAssertNil(install(includes, .kitty).error)
        try write(original, to: path)

        XCTAssertEqual(includes.revert().first { $0.target == .kitty }?.action, .restored)
        XCTAssertEqual(try read(path), original)
    }

    // MARK: - Neovim target drift

    func testNvimBlockInInitVimIsStillFoundAfterInitLuaAppears() throws {
        let home = makeHome()
        let vim = home + "/.config/nvim/init.vim"
        let lua = home + "/.config/nvim/init.lua"
        try write("set number\n", to: vim)
        let includes = includes(home)

        XCTAssertNil(install(includes, .nvim).error)
        XCTAssertTrue(try read(vim).contains("\" >>> palette theme >>>"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lua))

        // The user later creates an init.lua; the primary path now points there.
        try write("vim.opt.number = true\n", to: lua)
        XCTAssertEqual(includes.plan(for: .nvim)?.path, vim)
        XCTAssertTrue(includes.status(for: .nvim).installed)

        XCTAssertEqual(includes.revert().first { $0.target == .nvim }?.action, .restored)
        XCTAssertEqual(try read(vim), "set number\n")
        XCTAssertEqual(try read(lua), "vim.opt.number = true\n")
    }

    func testNvimRemoveStripsTheBlockFromTheAlternateFile() throws {
        let home = makeHome()
        let vim = home + "/.config/nvim/init.vim"
        try write("set number\n", to: vim)
        let includes = includes(home)

        XCTAssertNil(install(includes, .nvim).error)
        try write("vim.opt.number = true\n", to: home + "/.config/nvim/init.lua")

        XCTAssertEqual(includes.remove(.nvim).action, .removed)
        XCTAssertEqual(try read(vim), "set number\n")
    }

    // MARK: - Starship TOML

    func testStarshipStatusSaysHowToWireItWithoutFish() throws {
        let home = makeHome()
        let theme = home + "/config/theme"
        try write("set -gx STARSHIP_CONFIG \(theme)/starship-theme.toml\n", to: theme + "/starship-palette.fish")
        try write("palette = \"palette\"\n", to: theme + "/starship-theme.toml")
        let includes = includes(home)

        let status = includes.status(for: .starship)
        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.note.contains("export STARSHIP_CONFIG"), status.note)
    }

    func testFishBlockSourcesTheStarshipSnippetAndFallsBackToFishPalette() throws {
        let home = makeHome()
        let includes = includes(home)
        let fishPath = home + "/.config/fish/config.fish"
        let theme = home + "/config/theme"
        try write("set -g fish_greeting \"\"\n", to: fishPath)
        try write("set -gx STARSHIP_CONFIG \(theme)/starship-theme.toml\n", to: theme + "/starship-palette.fish")

        XCTAssertNil(install(includes, .fish).error)
        let wired = try read(fishPath)
        let body = wired.components(separatedBy: "\n")
        let start = try XCTUnwrap(body.firstIndex(of: "# >>> palette theme >>>"))
        let end = try XCTUnwrap(body.firstIndex(of: "# <<< palette theme <<<"))
        XCTAssertEqual(Array(body[(start + 1)..<end]), ["source \(theme)/starship-palette.fish"])

        XCTAssertEqual(includes.remove(.starship).action, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: theme + "/starship-palette.fish"))
        XCTAssertTrue(try read(fishPath).contains("source \(theme)/fish.fish"))
        XCTAssertFalse(try read(fishPath).contains("starship-palette.fish"))
    }

    func testStarshipRemoveCleansALegacyInlineBlock() throws {
        let home = makeHome()
        let path = home + "/.config/starship.toml"
        let original = """
        add_newline = false
        palette = "palette"
        # >>> palette theme >>>
        [palettes.palette]
        blue = "#0000ff"
        # <<< palette theme <<<

        """
        try write(original, to: path)
        let includes = includes(home)

        XCTAssertEqual(includes.remove(.starship).action, .removed)
        XCTAssertEqual(try read(path), "add_newline = false\n")
    }

    // MARK: - Mappings and availability

    func testPerTargetMappings() {
        let home = makeHome()
        let includes = includes(home)

        XCTAssertEqual(includes.plan(for: .kitty)?.path, home + "/.config/kitty/kitty.conf")
        XCTAssertEqual(includes.plan(for: .ghostty)?.path, home + "/.config/ghostty/config")
        XCTAssertEqual(includes.plan(for: .zellij)?.path, home + "/.config/zellij/config.kdl")
        XCTAssertEqual(includes.plan(for: .fish)?.path, home + "/.config/fish/config.fish")
        XCTAssertEqual(includes.plan(for: .starship)?.path, home + "/.config/starship.toml")
        XCTAssertEqual(includes.plan(for: .bat)?.path, home + "/.config/bat/config")
        XCTAssertEqual(includes.plan(for: .btop)?.path, home + "/.config/btop/btop.conf")
        XCTAssertEqual(includes.plan(for: .delta)?.path, home + "/.config/git/config")
        XCTAssertNil(includes.plan(for: .yazi))
        XCTAssertNil(includes.plan(for: .vscode))
        XCTAssertNil(includes.plan(for: .helium))
    }

    func testStatusReportsInstalledNotInstalledAndUnavailable() throws {
        let home = makeHome()
        let includes = includes(home)

        XCTAssertEqual(includes.status(for: .kitty).note, "Not installed")
        XCTAssertNil(install(includes, .kitty).error)
        XCTAssertEqual(includes.status(for: .kitty).note, "Installed in ~/.config/kitty/kitty.conf")
        XCTAssertFalse(includes.status(for: .vscode).available)
    }

    // MARK: - Multiple blocks

    func testRemoveOnlyTouchesTheNamedTarget() throws {
        let home = makeHome()
        try write("kitty user\n", to: home + "/.config/kitty/kitty.conf")
        try write("fish user\n", to: home + "/.config/fish/config.fish")
        let includes = includes(home)

        XCTAssertNil(install(includes, .kitty).error)
        XCTAssertNil(install(includes, .fish).error)
        XCTAssertEqual(includes.remove(.kitty).action, .removed)

        XCTAssertEqual(try read(home + "/.config/kitty/kitty.conf"), "kitty user\n")
        XCTAssertTrue(try read(home + "/.config/fish/config.fish").contains("# >>> palette theme >>>"))
    }

    func testRemoveAllRemovesEveryBlock() throws {
        let home = makeHome()
        try write("kitty user\n", to: home + "/.config/kitty/kitty.conf")
        try write("fish user\n", to: home + "/.config/fish/config.fish")
        let includes = includes(home)

        XCTAssertNil(install(includes, .kitty).error)
        XCTAssertNil(install(includes, .fish).error)
        XCTAssertEqual(includes.removeAll().count, 2)

        XCTAssertEqual(try read(home + "/.config/kitty/kitty.conf"), "kitty user\n")
        XCTAssertEqual(try read(home + "/.config/fish/config.fish"), "fish user\n")
    }

    // MARK: - Auxiliary theme links

    func testBatAndBtopThemesAreLinkedForTheAppAndUnlinkedOnRevert() throws {
        let home = makeHome()
        try write("theme body\n", to: home + "/config/theme/bat.tmTheme")
        try write("theme body\n", to: home + "/config/theme/btop.theme")
        let includes = includes(home)

        XCTAssertNil(install(includes, .bat).error)
        XCTAssertNil(install(includes, .btop).error)
        XCTAssertTrue(try read(home + "/.config/bat/config").contains("--theme=palette"))
        // btop deletes a marker block when it saves, so Palette never writes
        // one; the linked theme file is the install.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.config/btop/btop.conf"))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.config/bat/themes/palette.tmTheme"),
            home + "/config/theme/bat.tmTheme"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.config/btop/themes/palette.theme"),
            home + "/config/theme/btop.theme"
        )

        _ = includes.revert()
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.config/bat/themes/palette.tmTheme"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.config/btop/themes/palette.theme"))
    }

    // MARK: - Delta and yazi

    func testDeltaBlockIsInstalled() throws {
        let home = makeHome()
        let includes = includes(home)

        XCTAssertNil(install(includes, .delta).error)
        let git = try read(home + "/.config/git/config")
        XCTAssertTrue(git.contains("[include]"))
        XCTAssertTrue(git.contains("path = \(home)/config/theme/gitconfig-delta"))
    }

    func testYaziStaysManualBecauseTheTOMLCannotBeMerged() throws {
        let home = makeHome()
        let path = home + "/.config/yazi/theme.toml"
        let original = "[manager]\ncwd = { fg = \"#ffffff\" }\n"
        try write(original, to: path)
        let includes = includes(home)

        let status = includes.status(for: .yazi)
        XCTAssertFalse(status.available)
        XCTAssertTrue(status.note.contains("Manual"))
        XCTAssertEqual(install(includes, .yazi).action, .unchanged)
        XCTAssertEqual(try read(path), original)
    }
}
