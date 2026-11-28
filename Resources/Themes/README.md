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

The folder ships 69 curated families, one `-dark` and one `-light` variant each
(138 files). Everything else was pruned in 2.20.0 after a contrast, role-
separation and ANSI audit; `ThemeCuration` in `Sources/PaletteCore` maps a
pruned id to the kept variant, so an old config or favourite still loads.
Seoul Bones was dropped outright: its dark variant could not separate the
accent from body text without changing the accent's hue. Families that only
ever had one appearance (Dracula, Sonokai, Oxocarbon, Vesper, Zenburn) are not
here. The Omarchy ports are gone too: they repeated families the Ghostty ports
already cover, and the Ghostty variant is the one kept. See `THEMING.md` →
Catalogue for the policy.

After adding or importing a theme, repair its palette with
`swift run ThemeRepair Resources/Themes`. The app applies the same contrast
repair at load time, so the files, the picker swatches and the live theme agree.



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
