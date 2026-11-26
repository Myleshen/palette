# Theming

Themes are data, not code. A theme supplies semantic tokens and layout metrics;
the app decides how to render them. That constraint is deliberate: every theme
is guaranteed to produce a usable launcher, extensions cannot inject views or
CSS, and light/dark/accessibility behavior stays coherent.

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

## 6. Sources

v1 ships `builtin` and `file` sources:

- `source = "builtin"` with a bundled theme name. v1.3 includes Default
  Dark/Light, Catppuccin Mocha/Latte, Gruvbox Dark/Light, and Aetheria Pink
  (the pink/violet Noctalia palette).
- `source = "file"` with `dark` / `light` names resolved from the themes folder.

Architected for later, behind the same resolver:

- `wallpaper` — extract a seed color from the current desktop picture and
  generate a tonal palette (the Noctalia `m3-content` idea).
- `import` — base16/base24, pywal `colors.json`, iTerm2 `.itermcolors`, and
  Noctalia palette JSON, mapped onto the semantic tokens above.
- `community` — a local git checkout of shared themes; still no network calls
  from the app.

Importers and wallpaper derivation are roadmap items; the resolver interface and
token vocabulary are designed so they land without changing themes.

## 7. Accessibility

- Reduce Transparency forces `material = none` and `opacity = 1`.
- Reduce Motion sets `style = "none"`.
- Increase Contrast strengthens borders and separators by one step.
- System text size is respected as a floor; a theme may increase but not shrink
  below the accessibility setting.
- Fonts fall back to the system font when the requested family is unavailable.
- Contrast failures are repaired or warned as described under Contrast, and the
  result is written to the diagnostic log.

These overrides always win over theme values.

## 8. Reference notes

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
theme export templates with post-hooks. Palette adopts the source vocabulary now
and the wallpaper/export features on the roadmap.

## 9. Export templates (roadmap)

The intended shape, borrowed from Noctalia:

```toml
[theme.export.kitty]
input = "templates/kitty.conf"
output = "~/.config/kitty/theme.conf"
post_hook = "kitty @ set-colors --all --configured ~/.config/kitty/theme.conf"
```

Switching Palette's palette would then keep kitty, Neovide, zellij, and btop in
sync. Not in v1.
