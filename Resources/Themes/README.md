# Palette themes

Palette uses semantic theme files rather than a widget stylesheet. A theme is a
TOML file in this folder (or the bundled defaults) with a `name`, `appearance`,
and any of these tables:

- `[palette]` — background, foreground, accent, selection, badge, and status colors
- `[window]` — width, max height, anchor, corner radius, material, opacity
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
width = 720
max_height = 520
```

Apply a theme with `/theme`, edit `[theme]` in `config.toml`, or press ⌘R after
saving a file. See `THEMING.md` in the repository for the complete token list.
