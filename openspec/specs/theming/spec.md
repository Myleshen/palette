# Theming Specification

## Purpose

Cross-app theming: deriving one palette from the Palette theme or the desktop
wallpaper and carrying it into each app config inside a managed block, with a
one-step Revert. See [ADR 0006](../../decisions/0006-managed-includes-non-destructive-revert.md)
and [ADR 0003](../../decisions/0003-wallpaper-picking-owns-palette.md).

## Requirements

### Requirement: Palette source

`[theming] source` SHALL accept `theme` or `wallpaper`. While it is `wallpaper`,
applying a theme SHALL be refused with a visible explanation; the source SHALL
only change through an explicit control (Settings source picker or the deck
toggle).

#### Scenario: Theme source

- **WHEN** `source = "theme"` and `theme = "catppuccin-mocha"`
- **THEN** the generated files carry that theme's palette

#### Scenario: Off by default

- **WHEN** `[theming]` is absent
- **THEN** no app config is touched and no generated files are written

#### Scenario: Theme pick while wallpaper owns the palette

- **WHEN** the user applies a theme from the browser, `/theme` or the deck and
  `source = "wallpaper"`
- **THEN** nothing is written, the source stays `wallpaper`, and a status names
  the reason and how to switch

#### Scenario: Explicit switch to theme colours

- **WHEN** the user picks Theme in the Settings source control or the deck toggle
- **THEN** the source becomes `theme` and the current theme is applied

### Requirement: Wallpaper palette extraction

Wallpaper palettes SHALL use pywal's pipeline: quantise the picture to sixteen
colours, order dark to light, fill `color0`…`color15`, with `color0` as
background and `color15` as foreground. `saturation` and `contrast` SHALL map
to pywal's `--saturate` and `--contrast` and be applied on top. Slots 1–14
SHALL be the image's own colours. See [ADR 0004](../../decisions/0004-pywal-wallpaper-extraction.md).

#### Scenario: Light picture

- **WHEN** `source = "wallpaper"` and the desktop picture is light
- **THEN** the extracted palette uses the light variant's slot ordering

#### Scenario: Adjustments

- **WHEN** `saturation = 0.4` and `contrast = 3.0`
- **THEN** the same adjustments are applied to the extracted palette

### Requirement: Theme id resolution

A stored theme reference SHALL resolve as an id first, then as a display name,
and SHALL be rewritten to the id. A value that resolves to nothing SHALL NOT
silently apply Default Dark; it SHALL report the failure and keep the last good
palette.

#### Scenario: Display name stored

- **WHEN** `[theming] theme = "Ghostty · AlxPro Dark"`
- **THEN** it is stored as `ghostty-alxpro-dark` and applies that theme

#### Scenario: Unknown id

- **WHEN** `[theming] theme = "ghostty-does-not-exist"`
- **THEN** Apply reports that the theme is unknown and the current palette stays

### Requirement: Generated targets

Palette SHALL write generated files under `~/.config/palette/theme/`:
`kitty.conf`, `ghostty.conf`, `zellij.kdl`, `nvim.lua`, `fish.fish`,
`bat.tmTheme`, `gitconfig-delta`, `btop.theme`, `yazi.toml`,
`starship-theme.toml`, `starship-palette.fish` and `palette.json`. Every file
SHALL open with a header naming source, theme, appearance and timestamp in that
format's real comment syntax.

#### Scenario: Generated Lua and KDL

- **WHEN** a palette is applied
- **THEN** `nvim.lua` uses `--` comments and `zellij.kdl` uses `//` comments

#### Scenario: bat XML

- **WHEN** `bat.tmTheme` is written
- **THEN** the XML declaration leads the file and the comment follows it

#### Scenario: Machine-readable handoff

- **WHEN** an apply completes
- **THEN** `palette.json` records source, theme id, appearance, background, foreground, accent and ANSI 0–15

### Requirement: Starship remap

Starship theming SHALL never edit `starship.toml`. Palette SHALL write a
remapped copy, replacing colour names in `style`/`format` values with palette
hex and moving `[palettes.<name>]` values to the nearest palette colour in
OKLab, keeping keys and prompt format. `starship-palette.fish` SHALL export
`STARSHIP_CONFIG` to that copy.

#### Scenario: Existing prompt

- **WHEN** a user has a custom `starship.toml`
- **THEN** the generated copy keeps every module and format line and `starship.toml` is unchanged

#### Scenario: Missing or invalid starship.toml

- **WHEN** `starship.toml` is absent or does not parse
- **THEN** a minimal default copy is written with a notice

### Requirement: Managed blocks

Palette SHALL only change an app config inside a block delimited by
`# >>> palette theme >>>` and `# <<< palette theme <<<`, using the file's own
comment token. Content outside the block SHALL never be rewritten.

#### Scenario: Existing user settings

- **WHEN** kitty.conf already has user settings and theming is applied
- **THEN** only the marked block is added or replaced

#### Scenario: One block per file

- **WHEN** the same palette is applied a second time
- **THEN** each app config contains exactly one palette block

### Requirement: Target selection and removal

Unchecking one target SHALL remove only that target's block. Disabling theming
SHALL remove every block and SHALL restore `[theming] enabled = false`. If
Palette created a config that did not exist, removal SHALL delete the file
instead of leaving an empty one, and SHALL only delete it when nothing else
remains.

#### Scenario: Unchecking one target

- **WHEN** the user unchecks Ghostty
- **THEN** only Ghostty's marked block is removed and the other blocks stay

#### Scenario: Palette-created file

- **WHEN** a config consists only of Palette's block and the target is unchecked
- **THEN** the file is deleted

#### Scenario: Reset Theming

- **WHEN** the user resets the Theming pane
- **THEN** every installed include block is removed before defaults are written

### Requirement: Non-destructive Revert

Revert SHALL strip Palette's blocks, restore the previous generated set in one
atomic step, keep user edits made outside the block, and SHALL NOT stack. A
failed Revert SHALL be reported and SHALL be retryable.

#### Scenario: Revert after hand edits

- **WHEN** the user added unrelated settings to kitty.conf and then chooses Revert
- **THEN** the palette block is removed and those settings survive

#### Scenario: Revert twice

- **WHEN** Revert runs twice in a row
- **THEN** only the one previous generated set is restored

#### Scenario: Revert fails

- **WHEN** a config cannot be written during Revert
- **THEN** the failure is shown, no partial state is left, and Revert can be retried

### Requirement: Apply semantics

An Apply SHALL record the applied theme id in `[theme]` so the launcher, the
embedded terminal and the other apps share one palette. Apply SHALL NOT enable
theming by itself, and it SHALL NOT overwrite a deliberate Theme override
setting for other apps.

#### Scenario: Applying a theme

- **WHEN** the user applies `default-dark`
- **THEN** `[theme]` names it and the launcher, terminal and generated files agree

#### Scenario: Override preserved

- **WHEN** a Theme override is set for other apps
- **THEN** Apply does not silently clear it

### Requirement: Restart policy per target

kitty SHALL recolour live over its unix socket, with one restart needed the
first time the managed block adds `allow_remote_control socket-only`. Ghostty,
Neovim/Neovide, fish, Starship, bat, delta and btop SHALL take effect on the
documented reload or restart; zellij SHALL need a new session. bat SHALL run
`bat cache --build` after linking its theme.

#### Scenario: Recolour a running kitty

- **WHEN** a second apply runs after kitty's include is installed
- **THEN** running kitty windows recolour without a restart

#### Scenario: zellij palette

- **WHEN** a zellij palette is applied
- **THEN** the status line says a new session is required

#### Scenario: btop and yazi are manual

- **WHEN** btop or yazi is a target
- **THEN** the row says the palette needs a restart or a manual merge

### Requirement: Partial target failure

A target whose config is unreadable or at a nonstandard path SHALL be reported
with the path Palette uses, and SHALL NOT block the other targets. Apply SHALL
report success per target, not only overall.

#### Scenario: Unreadable Neovim config

- **WHEN** `init.lua` cannot be read
- **THEN** the Neovim row reports the path and failure while other targets still apply

### Requirement: Wallpaper following

`source = "wallpaper"` SHALL sample the current desktop picture. With
`follow_wallpaper = true` Palette SHALL check the desktop picture URL every five
seconds and re-apply when it changes. A wallpaper palette SHALL recolour the
launcher and the live embedded terminal without restarting a shell.

#### Scenario: Desktop picture changes

- **WHEN** `follow_wallpaper = true` and the user sets a new picture in System Settings
- **THEN** the palette re-applies within five seconds

#### Scenario: No theme file to name

- **WHEN** a wallpaper palette is applied
- **THEN** it is sampled again at launch because no theme id exists

### Requirement: Browser policy

Chromium-based browsers SHALL be themed through `BrowserThemeColor` in the
user-scoped managed preference plist; Helium SHALL always be supported and the
others only when installed. The first enable SHALL be the only administrator
step; later applies SHALL rewrite the plist without a password. A
`.mobileconfig` download and a Remove action SHALL remain available. See
[ADR 0007](../../decisions/0007-silent-chromium-managed-policy.md).

#### Scenario: Silent update after enable

- **WHEN** silent browser theming has been enabled once and the palette changes
- **THEN** the plist is rewritten as the user and a running browser is asked to refresh

#### Scenario: Browser not installed

- **WHEN** a catalogue browser is absent
- **THEN** its row reports that instead of writing a policy

#### Scenario: Remove

- **WHEN** the user chooses Remove
- **THEN** Palette's plist is deleted with one administrator prompt and the browser fallback colour returns

### Requirement: Launch repair

On launch Palette SHALL migrate a display-name `theme` value to its id, repair a
stale `palette.json` id or pre-2.20 `#`-prefixed Lua/KDL header with one silent
re-apply, and report an unknown target id or invalid `dark_mode` as a
diagnostic. A stale browser profile SHALL be surfaced once per apply.

#### Scenario: Old generated file

- **WHEN** `~/.config/palette/theme/nvim.lua` starts with a `#` header
- **THEN** one silent re-apply rewrites it with the current syntax

#### Scenario: Invalid dark_mode

- **WHEN** `dark_mode = "dim"`
- **THEN** control reports the invalid value and uses `auto`

### Requirement: Launch palette push

When theming is enabled and a supported terminal is already running, Palette
SHALL push the current generated palette to that terminal once at launch,
without rewriting generated files, restarting the terminal or changing the
configured source.

#### Scenario: Terminal was running before Palette

- **WHEN** Palette launches with `[theming] enabled = true` and a kitty process
  that Palette manages is already running
- **THEN** the running kitty adopts the current palette without a file rewrite

#### Scenario: Theming disabled

- **WHEN** Palette launches with `[theming] enabled = false`
- **THEN** no palette is pushed to any running terminal

#### Scenario: Push fails

- **WHEN** the terminal's socket is gone or refuses the command
- **THEN** the failure is logged and the launch continues; no restart prompt is
  raised for a terminal the user did not open through Palette

### Requirement: Wallpaper follow starts at launch

When `[theming] enabled = true`, `source = "wallpaper"` and
`follow_wallpaper = true`, Palette SHALL poll the desktop picture from launch,
so a desktop change is picked up without touching Settings or relaunching.

#### Scenario: Launch then change the desktop

- **WHEN** Palette launches in wallpaper-follow mode and the desktop picture
  later changes
- **THEN** the palette files and Palette's own theme update on the next poll

#### Scenario: Follow disabled

- **WHEN** `follow_wallpaper = false`
- **THEN** no poll is installed and a desktop change does nothing

### Requirement: Zellij UI roles follow the palette

The generated zellij theme SHALL define the tab bar, status bar, pane frames and
exit-code roles from the palette, with readable foregrounds, not only the base
ANSI palette.

#### Scenario: Tab bar and frames

- **WHEN** the generated zellij theme is active
- **THEN** the tab bar, status bar, selected/unselected tabs and pane frames use
  the palette's accent, surface and muted roles

#### Scenario: Exit codes

- **WHEN** a command succeeds or fails in a pane
- **THEN** the exit-code indicator uses the palette's green or red with a
  readable foreground

### Requirement: Standard palette export

Every successful apply SHALL write the active palette as a base16 scheme and as
terminal.sexy JSON in the generated theme directory, so another tool can read
Palette's colours without an adapter.

#### Scenario: Apply writes both files

- **WHEN** a theme or wallpaper palette is applied
- **THEN** `palette.yaml` and `palette.terminal-sexy.json` exist and carry that
  palette's colours

#### Scenario: Slot mapping

- **WHEN** the files are read
- **THEN** `base00` is the background, `base05` the foreground, `base08`–`base0F`
  the ANSI hues in base16 order, and terminal.sexy's `color_01`…`color_16` are
  ANSI 0…15

#### Scenario: Backup and revert

- **WHEN** the palette is reverted
- **THEN** both files return to the previous palette with the rest of the set

### Requirement: Transparency is preserved

When the user's terminal or Neovide is configured to be translucent, the
generated nvim file SHALL NOT paint an opaque normal background over it.

#### Scenario: Auto detection

- **WHEN** `[theming] transparent = "auto"` and kitty, ghostty or the nvim lua
  files configure an opacity below 1
- **THEN** `Normal` and `NormalNC` carry the foreground without a background

#### Scenario: Explicit off

- **WHEN** `transparent = "off"`
- **THEN** `Normal` keeps the palette background even if a terminal is
  translucent

#### Scenario: No transparency configured

- **WHEN** `transparent = "auto"` and no opacity setting is found
- **THEN** the opaque palette background is emitted as before

### Requirement: One wallpaper on every Space

Applying a wallpaper SHALL set the same picture on every Space of every display,
not only the Space that is active when the apply runs.

#### Scenario: Several Spaces

- **WHEN** the user applies a wallpaper while the Mac has more than one Space
- **THEN** every Space's desktop picture is that wallpaper after the apply

#### Scenario: Space switched later

- **WHEN** the user switches to another Space
- **THEN** the wallpaper and the palette Palette sampled match

#### Scenario: Store unavailable

- **WHEN** the wallpaper store cannot be read or written
- **THEN** the per-display picture is still set, the failure is logged, and the
  apply reports success for the picture itself

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

### Requirement: System appearance follows the palette

With `system_appearance = "auto"`, applying a light or dark palette SHALL switch
the macOS appearance to match it, and SHALL report when the automation
permission is denied rather than failing silently.

#### Scenario: Light palette while macOS is dark

- **WHEN** a light theme is applied and macOS is in dark mode
- **THEN** macOS switches to light and the apply reports it

#### Scenario: Off

- **WHEN** `system_appearance = "off"`
- **THEN** the macOS appearance is never changed

#### Scenario: Permission denied

- **WHEN** the System Events automation is denied
- **THEN** the palette still applies and a notice names the permission
