# Palette themes

Palette uses semantic theme files rather than a widget stylesheet. A theme is a
TOML file in this folder (or the bundled defaults) with a `name`, `appearance`,
and any of these tables:

The bundled `ghostty-*.toml` files are colour ports of the themes Ghostty ships,
which are the MIT-licensed iTerm2-Color-Schemes collection. Only colour values
were copied; the original themes live at
<https://github.com/ghostty-org/ghostty/tree/main/themes>. Each port maps the
terminal background, foreground, cursor and ANSI colours onto Palette's palette
and derives surface, muted, border, badge and row states. A user theme in this
folder with the same name overrides the bundled copy.

The bundled `omarchy-*.toml` files are colour ports of the themes shipped with
[Omarchy](https://github.com/basecamp/omarchy), which is MIT-licensed. Only
colour values were copied from each theme's `colors.toml`; the originals live at
<https://github.com/basecamp/omarchy/tree/master/themes>. They use the same
mapping as the Ghostty ports.



- `[palette]` — background, foreground, accent, selection, badge, and status colors
- `[window]` — anchor, offset, corner radius, material, opacity
- `[search]`, `[list]`, `[typography]`, `[states.*]`, `[motion]`, `[footer]`

Every key is optional: missing values inherit from the built-in dark or light
theme, or from the theme named by `extends = "..."`.

Example:

```toml
name = "My Theme"
appearance = "dark"
extends = "catppuccin-mocha"

[palette]
accent = "#89b4fa"
selection_bg = "#45475a"

[window]
corner_radius = 16
offset_y = 96
```

Apply a theme with `/theme`, edit `[theme]` in `config.toml`, or press ⌘R after
saving a file. See `THEMING.md` in the repository for the complete token list.
