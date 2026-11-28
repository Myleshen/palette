## ADDED Requirements

### Requirement: Complete nvim highlight coverage

The generated nvim file SHALL paint the base, treesitter, diagnostic, diff/git,
statusline, file-tree and picker highlight groups, so a LazyVim session shows
the palette everywhere rather than keeping the previous colorscheme in plugin
groups.

#### Scenario: Plugin groups follow the palette

- **WHEN** the generated file is applied in a LazyVim session
- **THEN** lualine, neo-tree, telescope/snacks and diagnostic groups carry
  Palette colours

#### Scenario: Unknown group

- **WHEN** a plugin defines a group Palette does not name
- **THEN** it links to a painted base group instead of keeping a stale colour

### Requirement: Transparent panels stay see-through

When the palette is applied with a transparent background, the generated nvim
file SHALL paint panel and full-window groups without a background, while
floating windows and statusline bars keep their surface so they stay legible.

#### Scenario: neo-tree and the dashboard

- **WHEN** the generated file is applied with transparency on
- **THEN** NeoTreeNormal, NeoTreeCursorLine and SnacksDashboardHeader carry no
  background, and NormalFloat, SnacksPicker and StatusLine still do
