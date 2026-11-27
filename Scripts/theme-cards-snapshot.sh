#!/bin/bash
# Headless render of the theme cards, for eyeballing the deck without opening
# Palette. Uses the scripted panel hooks, so it never activates the app.
#
#   scripts/theme-cards-snapshot.sh [fan.png] [preview.png] [wallpapers.png] [wallpaper-preview.png]
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Palette.app/Contents/MacOS/Palette"
OUT_FAN="${1:-Tests/Snapshots/theme-cards-fan.png}"
OUT_PREVIEW="${2:-Tests/Snapshots/theme-cards-preview.png}"
OUT_WALLPAPERS="${3:-Tests/Snapshots/theme-cards-wallpapers.png}"
OUT_WALLPAPER_PREVIEW="${4:-Tests/Snapshots/theme-cards-wallpaper-preview.png}"
CONFIG="$(mktemp -d /tmp/palette-fan-cfg.XXXXXX)"
trap 'rm -rf "$CONFIG"' EXIT INT TERM

bundle_is_stale() {
  [ ! -x "$APP" ] && return 0
  find Sources Resources Package.swift Package.resolved \
    -newer "$APP" -type f 2>/dev/null | grep -q .
}

if bundle_is_stale; then
  echo "building…"
  nice -n 10 taskpolicy -b make app >/dev/null
fi

mkdir -p "$(dirname "$OUT_FAN")"
rm -f "$OUT_FAN" "$OUT_PREVIEW" "$OUT_WALLPAPERS" "$OUT_WALLPAPER_PREVIEW"

# The wallpaper cards decode 4K pictures on first sight; give the front card a
# moment before capturing so the snapshot shows the picture, not its loader.
PALETTE_SCRIPT="themecards; wait=1.5; themecards_next; wait=0.35; themecards_next; wait=0.6; themecards_snapshot=$OUT_FAN; wait=0.2; themecards_preview; wait=0.8; themecards_snapshot=$OUT_PREVIEW; wait=0.2; themecards_previewclose; themecards_mode=wallpapers; wait=2.5; themecards_snapshot=$OUT_WALLPAPERS; wait=0.2; themecards_preview; wait=1.5; themecards_snapshot=$OUT_WALLPAPER_PREVIEW; wait=0.2; exit" \
  nice -n 10 taskpolicy -b "$APP" >/dev/null 2>&1 || true

for out in "$OUT_FAN" "$OUT_PREVIEW" "$OUT_WALLPAPERS" "$OUT_WALLPAPER_PREVIEW"; do
  if [ ! -s "$out" ]; then
    echo "no snapshot was written to $out" >&2
    exit 1
  fi
  echo "wrote $out"
done
