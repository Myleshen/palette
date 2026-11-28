# Wallpaper colours own the palette until the user says otherwise

## Why

Applying a theme while `[theming] source = "wallpaper"` currently flips the
source silently. The user wants the opposite contract: while wallpaper colours
are enabled, a theme pick is refused with a visible explanation, and the only
way to switch is an explicit control.

## What changes

- Theme applies (theme browser "Use Theme", `/theme`, the deck) are refused
  while the source is wallpaper, with a toast/status that names the reason and
  the way out.
- The deck gains a `Wallpaper colours | Theme colours` toggle that flips the
  source and applies the matching palette, so the switch is one click away.

## Out of scope

- Changing the Settings segmented control (it stays, and remains the other way
  to flip the source).
