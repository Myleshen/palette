# Match the macOS appearance to the applied palette

## Why

A light palette is applied while macOS stays dark: Palette and the apps look
light, every other window stays dark, and the desktop looks like two systems.

## What changes

- `[theming] system_appearance = "auto" | "off"` (default auto).
- When auto, a successful apply switches macOS to the palette's appearance
  through System Events (one native automation prompt), and reports if that is
  denied instead of failing silently.
- A Settings control exposes Auto/Off.

## Out of scope

- Per-display or scheduled appearance changes.
- Changing the wallpaper selection.
