# Theming guidance and a visible deck guard

## Why

- LazyVim, a custom starship palette, a duplicate zellij theme or a kitty colour
  line after the include can silently beat Palette's palette. The user has no
  way to know which of their own files is responsible.
- With `source = "wallpaper"`, theme cards are refused by design, but the
  refusal is a one-shot status line; the Apply button still looks active and a
  theme card appears to do nothing.

## What changes

- A read-only conflict scanner with actionable file:line recommendations, shown
  in Settings → Theming and summarised after an apply.
- Starship palette keys named after terminal colours map to that ANSI slot, not
  the nearest colour, so a monochrome wallpaper palette does not collapse blue
  and bright-blue into one grey.
- The deck disables Apply for theme cards in wallpaper mode and keeps the reason
  visible until the source changes.

## Out of scope

- Editing the user's config automatically.
- Themable Neovide chrome (only the embedded nvim applies).
