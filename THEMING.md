# Theming

Themes are data, not code. A theme supplies semantic tokens and layout metrics;
the app decides how to render them. That constraint is deliberate: every theme
is guaranteed to produce a usable launcher, extensions cannot inject views or
CSS, and light/dark/accessibility behavior stays coherent.

This file explains how theming works. The behaviour contract — including error
paths, refusals and migration — lives in
[`openspec/specs/theming/`](openspec/specs/theming/spec.md) and
[`openspec/specs/theme-catalogue/`](openspec/specs/theme-catalogue/spec.md);
the deck is in
[`openspec/specs/theme-deck/`](openspec/specs/theme-deck/spec.md).

## 1. Location and selection

```
~/.config/palette/themes/<name>.toml
```

`config.toml` picks the active theme:

```toml
[theme]
mode = "auto"                      # dark | light | auto
dark = "catppuccin-mocha"
light = "catppuccin-latte"
```

`auto` follows `NSApp.effectiveAppearance`. `mode = "dark"` or `"light"` pins a
theme regardless of system appearance. A theme whose `appearance` does not match
the resolved mode is still usable; Palette just picks the configured slot.

Themes reload on `⌘R` and when the theme directory changes. A parse failure
keeps the last good theme and records a diagnostic instead of breaking the UI.

## 2. File format

```toml
name = "Catppuccin Mocha"
appearance = "dark"
extends = "default-dark"           # optional

[palette]
bg = "#1e1e2e"
surface = "#181825"
elevated = "#313244"
fg = "#cdd6f4"
fg_muted = "#a6adc8"
accent = "#cba6f7"
accent_fg = "#1e1e2e"
selection_bg = "#313244"
selection_fg = "#cdd6f4"
match_fg = "#f5c2e7"
border = "#45475a"
separator = "#31324480"
danger = "#f38ba8"
warning = "#f9e2af"
success = "#a6e3a1"
info = "#89b4fa"
badge_bg = "#45475a"
badge_fg = "#cdd6f4"

# Panel position lives here; geometry is one fixed frame per screen, and
# preview direction / provider bar placement live in config.toml under [window].
[window]
anchor = "top"                     # top | center
offset_y = 120                     # points, or "18%" of screen height
corner_radius = 14
material = "hudWindow"             # hudWindow | popover | menu | sidebar | none
glass = true                       # theme-tinted liquid-glass surfaces
glass_opacity = 0.7                # 0 = clear, 1 = opaque theme surface
opacity = 0.98
border_width = 1
shadow = true

[search]
height = 56
placeholder = "Search apps, files, commands…"
show_icon = true

[list]
row_height = 44
spacing = 2
density = "comfortable"            # comfortable | compact
show_icons = true
icon_size = 20
icon_style = "original"            # original | monochrome
show_subtitles = true
selection = "fill"                 # fill | bar | outline | none
columns = 1                        # reserved for future grid layouts
show_scrollbar = true

[typography]
family = "SF Pro Text"
size = 14
subtitle_size = 12
mono = "JetBrains Mono"            # reserved for provider-supplied metadata
match_weight = "semibold"          # regular | medium | semibold | bold

[states.selected]
bg = "#45475a"
fg = "#cdd6f4"

[states.hover]
bg = "#313244"

[states.disabled]
fg = "#6c7086"

[motion]
duration_ms = 120
style = "fade"                     # fade | instant

[footer]
show = true
hint_color = "#a6adc8"
```

Colors accept `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, and `transparent`.
Numbers are points unless stated otherwise.

## 3. Token reference

### Palette

| Token | Used for |
|---|---|
| `bg` | window background, when material is `none` or transparency is reduced |
| `surface` | search bar and footer background |
| `elevated` | action sheet, prompt sheet |
| `fg` | primary text |
| `fg_muted` | subtitles, hints, placeholders |
| `accent` | selection bar, active prefix, focus ring |
| `accent_fg` | text on accent |
| `selection_bg` / `selection_fg` | selected row |
| `match_fg` | matched characters |
| `border` | window border |
| `separator` | dividers |
| `danger` / `warning` / `success` / `info` | status badges, errors |
| `badge_bg` / `badge_fg` | accessory badges |

Derived values: if `selection_fg` is omitted it falls back to `fg`; if
`accent_fg` is omitted it is computed from accent contrast. Every resolved theme
is then measured and repaired where needed (see Contrast, below).

### Contrast

Pairs are checked after `extends` resolution and derived values:

| Pair | Minimum |
|---|---|
| `fg` on `bg` (body text) | 7.0:1 |
| `fg_muted` on `bg` | 4.5:1 |
| `accent` on `bg`, `surface` and `elevated` | 4.5:1 |
| `accent` / `accent_fg` | 4.5:1 |
| `selection_bg` / `selection_fg` | 4.5:1 |
| `badge_bg` / `badge_fg` | 4.5:1 |
| `states.selected.bg` / `states.selected.fg` | 4.5:1 |
| `danger` / `warning` / `success` / `info` on `bg` | 3.0:1 |

A failing foreground is repaired rather than shipped, in OKLab: only lightness
moves, hue stays fixed, and chroma is reduced only when sRGB requires it. The
search takes the smallest lightness change that clears the bar. `bg` is never
changed, so a mid-tone background is capped at the best ratio it can physically
reach. A warning diagnostic records every adjustment for user themes; bundled
files are rewritten ahead of time with the same repair:

```sh
swift run ThemeRepair Resources/Themes
```

`states.selected` takes part in both the check and the repair.

### Metrics

`window.offset_y`, `window.corner_radius`, `search.height`, `list.row_height`,
`list.spacing`, `list.icon_size`, `motion.duration_ms`.

Panel width and height are not theme keys. The launcher uses one fixed frame per
screen (60% of each screen axis, with absolute caps when smaller), so
a theme stays portable across screen sizes. `config.toml` under `[window]` only
picks the preview direction, provider bar placement and favicons.

`anchor = "top"` centers horizontally and places the panel `offset_y` from the
top of the active screen. `center` ignores `offset_y`.

`density = "compact"` scales row height and icons to about 82% without changing
the configured values, so the launcher shows more results. `columns` is parsed
and reserved for a future grid layout; v1 always renders a single column.

## 4. Composition

`extends` loads a parent theme first, then deep-merges the child:

- tables merge key by key;
- scalars and arrays replace;
- `states.*` merge per state;
- cycles are rejected with a diagnostic;
- `extends = "default-dark"` and `"default-light"` always exist.

This is the rofi `@theme` idea without arbitrary widget trees: a theme can be a
20-line overlay on a maintained base.

## 5. What themes control, and what they do not

Controlled: colors, material, opacity, border, shadow, corner radius, offset,
anchor, row height, spacing, density, icons, subtitles, selection style,
typography, match emphasis, motion, footer hints. Grid `columns` is reserved for
a later release.

Not controlled by themes: panel width and height. The launcher uses one fixed
frame per screen; the preview shares that frame instead of resizing it. Preview
direction, provider bar placement and favicons live in `config.toml` under
`[window]`.

Not controlled: the order of results, provider behavior, arbitrary views, custom
CSS, per-item layout. Extensions can attach an icon, subtitle, badge, group, and
accent hint; the theme decides how those are drawn.

This boundary is what keeps a launcher coherent. rofi and wofi allow arbitrary
widget trees and GTK CSS respectively, which is powerful but means every theme
is a small program. Palette trades that for a smaller surface that always works.

## 6. Cross-app theming

Palette can carry its palette into the terminal, editor and shell. It is off by
default and lives in its own Settings section (**Theming**) and in
`[theming]` in `config.toml`:

```toml
[theming]
enabled = true
source = "theme"                     # theme | wallpaper
theme = "catppuccin-mocha"           # catalogue id; empty = the theme Palette shows
follow_wallpaper = false             # source = "wallpaper" only
dark_mode = "auto"                   # auto | dark | light
wallpaper_directory = "~/dot-files/wallpapers"
extraction = "pywal"                 # wallpaper palettes use pywal's pipeline
saturation = 0.0                     # pywal --saturate: -1.0...1.0
contrast = 0.0                       # pywal --contrast: 0 off, 1.5...4.5 useful
targets = ["kitty", "ghostty", "zellij", "nvim", "fish", "starship"]
```

Wallpaper palettes are extracted with pywal's pipeline: the image is quantized
to sixteen colours, ordered dark to light, poured into pywal's
`color0`…`color15` slots and adjusted for the chosen `dark_mode`. `color0` is
the background, `color15` the foreground, and slots 1–14 are the image's own
colours rather than Palette's fixed semantic hues. `saturation` and `contrast`
mirror pywal's `--saturate` and `--contrast` flags and are applied on top.

`theme` is a catalogue id (`catppuccin-mocha`, `ghostty-alxpro-dark`), not the
display name. Older builds saved the display name; the value is migrated on
launch, and a theme that no longer exists falls back to Default Dark with a
visible notice.

Generated files go under `~/.config/palette/theme/`: `kitty.conf`,
`ghostty.conf`, `zellij.kdl`, `nvim.lua`, `fish.fish`, `bat.tmTheme`,
`gitconfig-delta`, `btop.theme`, `yazi.toml`, plus `palette.json` (the machine-
readable palette: source, theme id, appearance, background, foreground, accent,
ANSI 0–15) for your own scripts. Starship adds `starship-theme.toml` and
`starship-palette.fish`. Every generated config opens with a header naming the
source, theme, appearance and timestamp, written with that format's real comment
syntax (`#`, `//` for KDL, `--` for Lua, `"` for Vim; bat's follows its XML
declaration). `palette.json` carries the same fields as JSON.

### Targets

| Target | What Palette writes | When it takes effect |
|---|---|---|
| kitty | `include` of the generated file plus `allow_remote_control socket-only` in `~/.config/kitty/kitty.conf` | Palette recolours every running kitty over its unix socket; the first apply that adds the block needs one restart |
| Ghostty | `config-file = <absolute path>` in `~/.config/ghostty/config` | restart Ghostty |
| zellij | the palette block and `theme "palette"` in `~/.config/zellij/config.kdl` | new zellij session |
| Neovim | `dofile(...)` in `init.lua` (or `source` in `init.vim`) | `:source` that file, or restart Neovide/Neovim (Neovide keeps the old colours until its nvim restarts) |
| fish | `source` of the palette snippet in `~/.config/fish/config.fish` | new shell, or `source` the file |
| Starship | never edits `starship.toml`: writes a remapped copy plus a fish snippet that exports `STARSHIP_CONFIG` | new shell |
| bat | `--theme=palette` in `~/.config/bat/config` and a symlink at `~/.config/bat/themes/palette.tmTheme` | next `bat` run |
| delta | `[include] path` in `~/.gitconfig` (or `~/.config/git/config`) | next git/delta command |
| btop | `color_theme = "palette"` in `~/.config/btop/btop.conf` and a symlink at `~/.config/btop/themes/palette.theme` | restart btop |
| yazi | nothing automatic; `yazi.toml` is generated for a manual merge | after you merge it into `~/.config/yazi/theme.toml` and restart yazi |
| Chromium browsers | `BrowserThemeColor` in the user-owned managed preference plist; a `.mobileconfig` is still generated as a manual fallback | every Apply writes it silently; a running browser refreshes itself |

yazi is manual on purpose: its `theme.toml` is a table-per-section file, so
appending a second `[mgr]` block would be invalid TOML. Copy the generated file
over your theme, or merge the values you want, then restart yazi. VS Code, Zed,
Neovide and Arc are listed but disabled, with the reason shown; Neovide is
covered by the Neovim palette.

### Marker blocks, backup and Revert

Palette only ever touches an app's config inside a marked block:

```
# >>> palette theme >>>
include ~/.config/palette/theme/kitty.conf
# <<< palette theme <<<
```

The comment token follows the file (`//` for zellij's KDL, `--` for Lua, `"` for
Vim). Unchecking one target removes only that block; turning theming off removes
every block. If Palette had to create a config that did not exist, removing the
block deletes the file instead of leaving an empty one. Nothing outside the
block is rewritten.

Before the first change, Palette copies the app's config to
`~/.config/palette/theme/previous/<target>-<file>.orig` (or drops a `.created`
marker when it made the file). **Revert to previous** restores those configs and
swaps the generated palette set back one step, so Revert is one click and cannot
stack. The next Apply snapshots the current set again.

### Wallpapers

Wallpaper cards come from `wallpaper_directory` (default
`~/dot-files/wallpapers`). It is scanned without recursion: images become
picture cards, videos become browse-only cards (macOS cannot set a video as the
desktop picture; the apply path says so rather than pretending). Thumbnails load
only near the selection, the desktop picture currently in use is marked, and
each visible card's dots come from a small off-main sample of its own picture.
`⌘⌥W` opens the deck straight into Wallpapers mode; `⌘⌥G` opens Colors mode, and
filters/favourites stay inside the active mode.

Choosing a picture card sets it on every screen first. Then, only when
cross-app theming is enabled **and** `source = "wallpaper"`, the new picture is
sampled and the resulting palette applied, so the "colors from wallpaper" flow
is one keystroke; with theming off or `source = "theme"`, only the desktop
picture changes and the status line says the palette was left alone. `source =
"wallpaper"` on its own samples the current desktop picture; `dark_mode` decides
whether the derived palette is the dark or light variant. `follow_wallpaper =
true` checks the desktop picture's URL every five seconds and re-applies when it
changes. The launcher follows the same palette: a wallpaper-derived palette
becomes Palette's own theme while it is applied (there is no theme file to name,
so it is sampled again at launch), and the embedded terminal recolours in place
so no shell is restarted. An Apply that uses a Palette theme also records that
id in `[theme]`, so the launcher, the embedded terminal and the other apps all
show one palette. A deliberate "Theme override" for other apps is the one place
they differ.

### Browser theming

Chromium browsers (Helium always; Chrome, Edge, Brave, Vivaldi and Chromium when
installed) get the palette background as `BrowserThemeColor`. Palette writes it
to the user-scoped managed preference file
`/Library/Managed Preferences/<user>/<bundleID>.plist`. Chromium reads that file
like any managed domain, so the colour covers every profile of that browser at
once; it is app-wide and approximate by design, not a per-window theme.

The first time, press **Enable silent browser theming** in the Browsers card.
That is the only administrator step: one password prompt that removes any old
Palette profile, creates the plist, hands it to your user, and seeds the current
colour. After that every Apply rewrites the plist as you, with no password and
no System Settings trip. A running browser is asked to refresh with
`<app bundle binary> --refresh-platform-policy --no-startup-window`; if the
binary cannot be found, the row says a restart picks the colour up.

**Download profile** still writes a valid `.mobileconfig` to `~/Downloads` for
people who prefer the OS-managed route. **Remove…** deletes Palette's plist
with one administrator prompt; the browser falls back to its own colour.

The old flow — approving a profile under **General → Device Management →
Profiles**, re-approving after every palette change — is gone. The one-time
enable removes any profile left by an earlier Palette version first.

### Starship

Starship modules embed literal colour names, so selecting a palette is not
enough. Palette writes `starship-theme.toml`: your `starship.toml` is parsed,
every colour name in `style`/`format` values is replaced with the palette's hex,
values in your active `[palettes.<name>]` table are moved to the nearest Palette
colour in OKLab, and all keys, modules and the prompt format are kept. The TOML
round-trip drops comments; the header says so. Your `starship.toml` itself is
never edited, and a missing or invalid file gets a minimal default instead (with
a notice). `starship-palette.fish` exports `STARSHIP_CONFIG` to that copy and is
sourced from fish's marked block; other shells must export it themselves.

### Troubleshooting

- **A generated file has a stale header or old syntax.** Apply once. Builds
  before 2.20.0 wrote `#` comments into Lua and KDL and put bat's XML comment
  before the declaration, which made those files invalid; a fresh Apply rewrites
  them. Older files also miss the current theme's id in the header.
- **Apply says written but the app looks unchanged.** Check the app's reload
  row: only kitty can be reloaded by Palette; everything else needs the restart
  or source step in the table above.
- **A target stays "Not installed" though Apply succeeded.** Its config may be
  at a nonstandard path (Neovim `init.vim` vs `init.lua`, git's XDG file vs
  `~/.gitconfig`), or the app's config is unreadable. The row shows the path
  Palette uses.
- **bat/btop say the palette is missing.** Their theme files are symlinks into
  the Palette theme directory; removing or moving that directory breaks them.
  Apply again to recreate the links.
- **Revert restored an app config but not the palette.** Revert restores the
  previous generated set and the app configs, not the launcher's own theme.
- **A browser did not change colour.** Press **Enable silent browser theming**
  once. After that the Browsers card says *Managed — updates silently*; a
  running browser may need a restart, and **Refresh** re-reads the state.
- **The themed apps use the wrong theme.** A `theme` value that is a display
  name instead of an id is migrated on launch; re-pick the theme in Settings →
  Theming if a hand-edited value still looks wrong. An id pruned from the
  bundled catalogue is replaced by its kept variant, or by the built-in default
  when the family went away; the status line says which.

## 7. Sources

Bundled themes ship inside the app as TOML resources; a user theme with the
same file name in `~/.config/palette/themes` wins. `[theme]` in `config.toml`
only names the dark and light theme and picks the mode — there is no `source`
key. The catalogue is the built-in defaults (Default Dark/Light, Catppuccin
Mocha/Latte, Gruvbox Dark/Light, Aetheria Pink, Siri Silver/Graphite), 69
bundled port families (138 files) and your own files.

### Catalogue

A 2.20.0 audit measured every shipped port with the contrast table above and
with an OKLab distance between its UI roles. The catalogue was cut from 933
files to 69 families, each shipping one dark and one light variant:

- both variants clear the whole contrast table, so a light counterpart is never
  a washed-out approximation of the dark one;
- text, muted text, accent, border, surface and selection stay visibly apart:
  `fg`/`fg_muted` ≥ 12 ΔE, `fg_muted`/`border` ≥ 8, `accent`/`fg` ≥ 15,
  `accent`/`selection_bg` ≥ 8, `surface`/`bg` 1.5–12, `elevated`/`surface`
  ≥ 1.5 and `selection_fg`/`selection_bg` ≥ 12 ΔE at 4.5:1;
- `danger` / `success` / `warning` / `info` stay four separate hues (no theme
  whose status colours are one decorative colour), so diffs, git status and
  errors remain readable;
- ANSI red and ANSI green are at least 5 ΔE apart, normal and bright, so the
  two hues a colour-blind user can confuse never collapse;
- every ANSI text slot clears 2.5:1 on the background.

Theme ANSI slots are still hand-authored through `PalettePalette.ansi`, so a
port whose accent is its ANSI blue can repeat that hue in slots 4/5. Wallpaper
palettes are machine-generated, so `PalettePalette.distinctANSI` repairs a
colliding wallpaper pair in OKLCH; a pywal scheme that already separates is
returned untouched.

Seoul Bones was dropped from the catalogue in 2.20.0: its dark variant could
not separate `accent` from `fg` without changing the accent's hue, and the
family lost both files rather than ship an unusable dark half. Families that
only ever shipped one appearance were dropped — Dracula, Sonokai,
Oxocarbon, Vesper and Zenburn have no light port, and the Nightfox set splits
its dark (`nightfox`, `duskfox`, `nordfox`, `terafox`, `carbonfox`) and light
(`dayfox`, `dawnfox`) variants across separate files. `ThemeCuration` maps every
pruned id to the kept variant that replaced it, or to the built-in default when
the family is gone, and rewrites `config.toml` and card favourites once at
launch.

Not implemented yet:

- `import` — base16/base24, pywal `colors.json`, iTerm2 `.itermcolors`, and
  Noctalia palette JSON, mapped onto the semantic tokens above.
- `community` — a local git checkout of shared themes; still no network calls
  from the app.

Wallpaper-derived palettes are implemented, but for the cross-app targets, not as
a launcher theme source: see section 6. Importers and community sharing remain
roadmap items; the resolver interface and token vocabulary are designed so they
land without changing themes.

## 8. Accessibility

- Reduce Transparency forces `material = none` and `opacity = 1`.
- Reduce Motion sets `style = "none"`.
- Increase Contrast strengthens borders and separators by one step.
- System text size is respected as a floor; a theme may increase but not shrink
  below the accessibility setting.
- Fonts fall back to the system font when the requested family is unavailable.
- Contrast failures are repaired or warned as described under Contrast, and the
  result is written to the diagnostic log.

These overrides always win over theme values.

## 9. Reference notes

**rofi** contributes the idea of a theme as a first-class, composable file with
global defaults, per-widget sections, and states (`selected`, `alternate`,
`urgent`). Palette keeps the state model and composition, and drops the widget
tree and CSS parser. rofi's `-dump-theme` equivalent here is a diagnostic dump of
the resolved theme in the log.

**wofi** contributes the minimal, learnable configuration surface and the
external indexed color file (`--wofi-color0…N`), which maps cleanly onto pywal
and base16 palettes. Palette uses named semantic tokens instead of indices, and
supports the same "swap the palette, keep the layout" workflow.

**Noctalia** contributes the palette source model (`builtin`, `wallpaper`,
`community`, `custom`), live palette application, light/dark separation, and
theme export templates with post-hooks. Palette implements the wallpaper source
for its cross-app targets (section 6); template export is still unimplemented.

## 10. Export templates (roadmap)

Nothing in this section is read by Palette today. The intended shape, borrowed
from Noctalia:

```toml
[theme.export.kitty]
input = "templates/kitty.conf"
output = "~/.config/kitty/theme.conf"
post_hook = "kitty @ set-colors --all --configured ~/.config/kitty/theme.conf"
```

Switching Palette's palette would then keep kitty, Neovide, zellij, and btop in
sync. Today the generated set under `~/.config/palette/theme/` covers those apps
without templating; per-template output and post-hooks are not implemented.
