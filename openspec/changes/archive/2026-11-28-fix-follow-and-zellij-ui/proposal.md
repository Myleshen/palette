# Fix wallpaper follow at launch and theme the zellij UI

## Why

Two gaps in the theming loop:

1. `configureThemingPolling()` runs only from `reload()`. Launching Palette with
   `source = "wallpaper"` and `follow_wallpaper = true` installs no five-second
   poll, so changing the desktop while Palette runs updates nothing until a
   settings change or relaunch.
2. The generated zellij theme defines only the base palette (fg/bg/ANSI). Zellij
   derives its tab bar, status bar and pane frames from defaults, so they stay
   grey while the terminal body adopts the palette.

## What changes

- Start the wallpaper-follow poll during launch, not only on reload.
- Generate zellij's UI roles (`text_*`, `ribbon_*`, `frame_*`,
  `exit_code_*`) from the palette, with contrast-safe foregrounds, so the top
  bar, tabs, status line and borders take the theme.

## Out of scope

- Zellij plugins that hard-code their own colours.
- A live reload of a running zellij session (zellij has no runtime theme switch;
  the existing "Open themed session" path remains).
