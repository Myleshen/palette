import Foundation
import XCTest
@testable import PaletteCore

/// The generated nvim.lua has to theme a real LazyVim session: base UI,
/// treesitter captures, diagnostics, diff signs, lualine, neo-tree and the
/// pickers/notifiers. A half-themed file shows the previous colorscheme in
/// exactly those plugin groups.
final class NvimThemeTests: XCTestCase {
    private func render(_ palette: PalettePalette, transparent: Bool = false) throws -> String {
        try XCTUnwrap(ThemingRenderer.contents(
            for: .nvim,
            palette: palette,
            metadata: PaletteMetadata(
                source: "theme",
                theme: palette.name,
                appearance: palette.appearance,
                generatedAt: Date(timeIntervalSince1970: 0),
                transparentBackgrounds: transparent
            )
        ))
    }

    /// Group name to the inside of its `{ ... }` spec, from the rendered file.
    private func specs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard line.hasPrefix("  ") else { continue }
            let body = line.dropFirst(2).dropLast()
            let name: String
            let spec: String
            if body.hasPrefix("[\"") {
                guard let close = body.range(of: "\"] = { ") else { continue }
                name = String(body[body.index(body.startIndex, offsetBy: 2)..<close.lowerBound])
                spec = String(body[close.upperBound...].dropLast())
            } else {
                guard let separator = body.range(of: " = { ") else { continue }
                name = String(body[..<separator.lowerBound])
                spec = String(body[separator.upperBound...].dropLast())
            }
            result[name] = spec.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // MARK: - Coverage

    func testEveryHighlightIsRendered() throws {
        for transparent in [false, true] {
            let text = try render(PalettePalette(theme: .defaultDark), transparent: transparent)
            let rendered = specs(text)
            let expected = ThemingRenderer.nvimHighlights(transparent: transparent)
            XCTAssertEqual(rendered.count, expected.count, "transparent: \(transparent)")
            for highlight in expected {
                XCTAssertNotNil(rendered[highlight.group], "missing \(highlight.group)")
            }
            // The table does not repeat a group; a duplicate would silently
            // overwrite the earlier spec in the Lua map.
            XCTAssertEqual(Set(expected.map(\.group)).count, expected.count)
        }
    }

    /// No duplicate, no group from the spec list left out.
    func testCoversTheLazyVimSurface() throws {
        let rendered = Set(specs(try render(PalettePalette(theme: .defaultDark))).keys)
        let required = [
            // base
            "NormalNC", "NormalFloat", "FloatBorder", "FloatTitle", "CursorLine",
            "CursorColumn", "ColorColumn", "LineNr", "CursorLineNr", "SignColumn",
            "Folded", "FoldColumn", "WinSeparator", "StatusLineNC", "WinBar", "WinBarNC",
            "TabLine", "TabLineFill", "TabLineSel", "PmenuSbar", "PmenuThumb", "VisualNOS",
            "Search", "IncSearch", "CurSearch", "MatchParen", "Directory", "Title", "NonText",
            "SpecialKey", "Whitespace", "EndOfBuffer", "ErrorMsg", "WarningMsg", "MoreMsg",
            "Question", "ModeMsg", "QuickFixLine", "Substitute", "Conceal",
            // syntax
            "Constant", "String", "Character", "Number", "Boolean", "Float", "Identifier",
            "Statement", "Conditional", "Repeat", "Label", "Operator", "Keyword", "Exception",
            "PreProc", "Include", "Define", "Macro", "PreCondit", "StorageClass", "Structure",
            "Typedef", "Special", "SpecialChar", "Tag", "Delimiter", "SpecialComment", "Debug",
            "Underlined", "Ignore", "Error", "Todo",
            // treesitter
            "@variable", "@variable.builtin", "@variable.parameter", "@variable.member",
            "@constant", "@constant.builtin", "@module", "@string", "@string.escape",
            "@string.special", "@character", "@number", "@boolean", "@function",
            "@function.call", "@function.builtin", "@function.macro", "@method", "@method.call",
            "@constructor", "@keyword", "@keyword.function", "@keyword.return",
            "@keyword.operator", "@conditional", "@repeat", "@operator", "@type",
            "@type.builtin", "@type.qualifier", "@attribute", "@property", "@field",
            "@parameter", "@namespace", "@comment", "@comment.error", "@comment.warning",
            "@punctuation", "@punctuation.bracket", "@punctuation.delimiter",
            "@punctuation.special", "@tag", "@tag.attribute", "@tag.delimiter", "@label",
            "@markup.heading", "@markup.link", "@markup.raw", "@markup.list",
            // diagnostics
            "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint", "DiagnosticOk",
            "DiagnosticUnderlineError", "DiagnosticUnderlineWarn", "DiagnosticUnderlineInfo",
            "DiagnosticUnderlineHint", "DiagnosticVirtualTextError", "DiagnosticVirtualTextWarn",
            "DiagnosticVirtualTextInfo", "DiagnosticVirtualTextHint", "DiagnosticFloatingError",
            "DiagnosticFloatingWarn", "DiagnosticFloatingInfo", "DiagnosticFloatingHint",
            "DiagnosticSignError", "DiagnosticSignWarn", "DiagnosticSignInfo", "DiagnosticSignHint",
            // diff and git
            "DiffAdd", "DiffChange", "DiffDelete", "DiffText", "Added", "Removed", "Changed",
            "GitSignsAdd", "GitSignsChange", "GitSignsDelete", "MiniDiffSignAdd",
            "MiniDiffSignChange", "MiniDiffSignDelete", "diffAdded", "diffRemoved", "diffChanged",
            // neo-tree
            "NeoTreeNormal", "NeoTreeNormalNC", "NeoTreeDirectoryName", "NeoTreeDirectoryIcon",
            "NeoTreeFileName", "NeoTreeFileNameOpened", "NeoTreeFileIcon", "NeoTreeRootName",
            "NeoTreeIndentMarker", "NeoTreeExpander", "NeoTreeCursorLine", "NeoTreeGitAdded",
            "NeoTreeGitModified", "NeoTreeGitDeleted", "NeoTreeGitUntracked", "NeoTreeGitRenamed",
            "NeoTreeGitIgnored", "NeoTreeSymbolicLinkTarget",
            // telescope and snacks
            "TelescopeNormal", "TelescopeBorder", "TelescopeTitle", "TelescopePromptNormal",
            "TelescopePromptBorder", "TelescopePromptTitle", "TelescopeResultsNormal",
            "TelescopeResultsBorder", "TelescopeResultsTitle", "TelescopePreviewNormal",
            "TelescopePreviewBorder", "TelescopePreviewTitle", "TelescopeSelection",
            "TelescopeSelectionCaret", "TelescopeMatching", "SnacksPicker", "SnacksPickerBorder",
            "SnacksPickerTitle", "SnacksPickerListCursorLine", "SnacksPickerMatch",
            "SnacksPickerDir", "SnacksPickerFile", "SnacksPickerIcon", "SnacksDashboardHeader",
            "SnacksDashboardIcon", "SnacksDashboardKey", "SnacksDashboardDesc",
            "SnacksDashboardFooter", "SnacksDashboardTitle", "SnacksDashboardTerminal",
            "SnacksDashboardSpecial", "SnacksNotifierInfo", "SnacksNotifierWarn",
            "SnacksNotifierError", "SnacksNotifierDebug", "SnacksNotifierTrace",
            // noice and notify
            "NoiceCmdline", "NoiceCmdlineIcon", "NoiceCmdlinePopup", "NoiceCmdlinePopupBorder",
            "NoicePopup", "NoicePopupBorder", "NoiceMini", "NoiceConfirm", "NoiceConfirmBorder",
            "NotifyINFO", "NotifyWARN", "NotifyERROR", "NotifyDEBUG", "NotifyTRACE",
            // misc
            "LazyNormal", "LazyButton", "LazyButtonActive", "LazyH1", "LazySpecial",
            "MasonNormal", "MasonHeader", "TroubleNormal", "TroubleText", "DapBreakpoint",
            "DapStopped", "TreesitterContext", "TreesitterContextLineNumber", "CmpItemAbbr",
            "CmpItemAbbrMatch", "CmpItemKind", "CmpItemMenu",
            // and lualine in every mode
            "lualine_a_normal", "lualine_b_normal", "lualine_c_normal", "lualine_x_normal",
            "lualine_y_normal", "lualine_z_normal", "lualine_a_insert", "lualine_b_insert",
            "lualine_c_insert", "lualine_x_insert", "lualine_y_insert", "lualine_z_insert",
            "lualine_a_visual", "lualine_b_visual", "lualine_c_visual", "lualine_x_visual",
            "lualine_y_visual", "lualine_z_visual", "lualine_a_replace", "lualine_b_replace",
            "lualine_c_replace", "lualine_x_replace", "lualine_y_replace", "lualine_z_replace",
            "lualine_a_command", "lualine_b_command", "lualine_c_command", "lualine_x_command",
            "lualine_y_command", "lualine_z_command", "lualine_a_terminal", "lualine_b_terminal",
            "lualine_c_terminal", "lualine_x_terminal", "lualine_y_terminal", "lualine_z_terminal",
            "lualine_a_inactive", "lualine_b_inactive", "lualine_c_inactive", "lualine_x_inactive",
            "lualine_y_inactive", "lualine_z_inactive",
        ]
        XCTAssertEqual(required.filter { !rendered.contains($0) }, [])
    }

    // MARK: - Roles

    func testGroupsUseOnlyPaletteRoles() throws {
        for palette in [PalettePalette(theme: .defaultDark), PalettePalette(theme: .defaultLight)] {
            let text = try render(palette)
            let roles = Set(specs(text).values.flatMap { spec -> [String] in
                guard let regex = try? NSRegularExpression(pattern: "p\\.([A-Za-z]+)") else { return [] }
                return regex.matches(in: spec, range: NSRange(spec.startIndex..., in: spec)).compactMap {
                    Range($0.range(at: 1), in: spec).map { String(spec[$0]) }
                }
            })
            let pTable = Set(text.components(separatedBy: "\n").flatMap { line -> [String] in
                guard let regex = try? NSRegularExpression(pattern: "([A-Za-z]+) = \"#") else { return [] }
                return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
                    Range($0.range(at: 1), in: line).map { String(line[$0]) }
                }
            })
            XCTAssertEqual(roles.subtracting(pTable), [], "\(palette.name)")
            XCTAssertFalse(specs(text).values.contains { $0.contains("#") }, "raw hex in a group")
        }
    }

    func testSpotChecksResolveToTheExpectedRoles() throws {
        for palette in [PalettePalette(theme: .defaultDark), PalettePalette(theme: .defaultLight)] {
            let text = try render(palette)
            XCTAssertTrue(text.contains("  lualine_a_normal = { fg = p.cursorText, bg = p.blue, bold = true },"))
            XCTAssertTrue(text.contains("  NeoTreeDirectoryName = { fg = p.blue },"))
            XCTAssertTrue(text.contains("  SnacksDashboardHeader = { fg = p.blue, bg = p.bg },"))
            XCTAssertTrue(text.contains("  NotifyERROR = { fg = p.red, bg = p.surface },"))
            XCTAssertTrue(text.contains("  [\"@keyword\"] = { fg = p.magenta },"))
            // Dark and light really carry their own values.
            XCTAssertTrue(text.contains("bg = \"\(palette.background)\""))
            XCTAssertTrue(text.contains("fg = \"\(palette.foreground)\""))
        }
        XCTAssertNotEqual(
            PalettePalette(theme: .defaultDark).background,
            PalettePalette(theme: .defaultLight).background
        )
    }

    // MARK: - Transparency

    func testTransparentPanelsDropTheirBackground() throws {
        let text = try render(PalettePalette(theme: .defaultDark), transparent: true)
        let rendered = specs(text)
        for group in [
            "Normal", "NormalNC", "LineNr", "SignColumn", "FoldColumn",
            "NeoTreeNormal", "NeoTreeNormalNC", "NeoTreeCursorLine",
            "SnacksDashboardHeader", "SnacksDashboardDesc", "SnacksDashboardFooter",
            "TroubleNormal", "LazyNormal", "MasonNormal", "NoiceMini", "NoiceCmdline",
            "TreesitterContext",
        ] {
            XCTAssertFalse(rendered[group]?.contains("bg =") ?? true, "\(group) keeps a bg")
        }
        // The tree cursor row is still visible without a fill.
        XCTAssertEqual(rendered["NeoTreeCursorLine"], "bold = true")
        XCTAssertEqual(rendered["TreesitterContext"], "bold = true")
    }

    func testOpaquePanelsUseTheirSurface() throws {
        let rendered = specs(try render(PalettePalette(theme: .defaultDark), transparent: false))
        XCTAssertEqual(rendered["NeoTreeNormal"], "fg = p.fg, bg = p.surface")
        XCTAssertEqual(rendered["SnacksDashboardHeader"], "fg = p.blue, bg = p.bg")
        XCTAssertEqual(rendered["TreesitterContext"], "bg = p.surface, bold = true")
        XCTAssertEqual(rendered["Normal"], "fg = p.fg, bg = p.bg")
    }

    func testFloatsAndBarsKeepTheirBackground() throws {
        let rendered = specs(try render(PalettePalette(theme: .defaultDark), transparent: true))
        for group in [
            "NormalFloat", "SnacksPicker", "TelescopeNormal", "Pmenu",
            "NoicePopup", "NotifyINFO", "SnacksNotifierError",
            "StatusLine", "StatusLineNC",
        ] {
            XCTAssertTrue(rendered[group]?.contains("bg =") ?? false, "\(group) lost its bg")
        }
    }
}
