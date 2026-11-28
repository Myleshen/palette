# One wallpaper across every Space

## Why

`NSWorkspace.setDesktopImageURL` only updates the active Space of each display.
On a Mac with several Spaces, applying a wallpaper from the deck leaves the
other Spaces on their previous picture, so switching Space changes the wallpaper
and the palette on screen no longer matches the one Palette sampled.

## What changes

- After setting the picture per display, rewrite
  `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` so every
  Space and display references the same picture, then restart WallpaperAgent.
- Do nothing (and log) when the store is missing or unreadable.

## Out of scope

- Per-Space wallpapers as a user preference; Palette applies one picture
  everywhere, which is the behaviour the user asked for.
- Dynamic/aerial wallpapers.
