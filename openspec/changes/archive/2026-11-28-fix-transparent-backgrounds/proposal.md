# Keep terminal and Neovide transparency

## Why

The generated nvim file paints `Normal` with an opaque background. In a
terminal or Neovide configured for transparency (kitty `background_opacity 0.6`,
`neovide_normal_opacity 0.6`) that opaque colour hides the effect, so the editor
looks like a solid slab while every other window is translucent.

## What changes

- `[theming] transparent = "auto" | "on" | "off"` (default `auto`).
- `auto` looks for a transparency setting the user already made: kitty/ghostty
  opacity below 1 in their config, or `neovide_normal_opacity`/`neovide_opacity`
  below 1 in their nvim lua files.
- When transparent, `Normal` and `NormalNC` keep the foreground but no
  background, so the terminal's palette background and Neovide's opacity show
  through; `NormalFloat` keeps its surface for readability.
- A Settings control next to the theme controls exposes the three states.

## Out of scope

- Changing the user's kitty/Neovide opacity values.
