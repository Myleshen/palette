#!/bin/bash
# Headless render of the theme cards, for eyeballing the deck without opening
# Palette. Uses the scripted panel hooks, so it never activates the app.
#
#   scripts/theme-cards-snapshot.sh [fan.png] [preview.png] [wallpapers.png] [wallpaper-preview.png] [deal.png]
#
#   THEME_CARDS_SIZE=1710x1073 renders the deck for that usable display size.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Palette.app/Contents/MacOS/Palette"
OUT_FAN="${1:-Tests/Snapshots/theme-cards-fan.png}"
OUT_PREVIEW="${2:-Tests/Snapshots/theme-cards-preview.png}"
OUT_WALLPAPERS="${3:-Tests/Snapshots/theme-cards-wallpapers.png}"
OUT_WALLPAPER_PREVIEW="${4:-Tests/Snapshots/theme-cards-wallpaper-preview.png}"
OUT_DEAL="${5:-Tests/Snapshots/theme-cards-deal.png}"
# THEME_CARDS_SIZE=1710x1073 renders the deck for a display this machine may
# not have, using the panel's scripted size hook.
SIZE="${THEME_CARDS_SIZE:-}"
PREFIX=""
[ -n "$SIZE" ] && PREFIX="themecards_size=$SIZE; "
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
rm -f "$OUT_FAN" "$OUT_PREVIEW" "$OUT_WALLPAPERS" "$OUT_WALLPAPER_PREVIEW" "$OUT_DEAL"

# The wallpaper cards decode 4K pictures on first sight; give the front card a
# moment before capturing so the snapshot shows the picture, not its loader.
PALETTE_SCRIPT="${PREFIX}themecards; wait=1.5; themecards_next; wait=0.35; themecards_next; wait=0.6; themecards_snapshot=$OUT_FAN; wait=0.2; themecards_deal=0.5; wait=0.3; themecards_snapshot=$OUT_DEAL; wait=0.2; themecards_deal=1; wait=0.3; themecards_preview; wait=0.8; themecards_snapshot=$OUT_PREVIEW; wait=0.2; themecards_previewclose; themecards_mode=wallpapers; wait_until=thumbsReady=true;timeout=20; assert=thumbsReady=true; wait=0.3; themecards_snapshot=$OUT_WALLPAPERS; wait=0.2; themecards_preview; wait=1.5; themecards_snapshot=$OUT_WALLPAPER_PREVIEW; wait=0.2; exit" \
  nice -n 10 taskpolicy -b "$APP" >/dev/null 2>&1 || SCRIPT_STATUS=$?
SCRIPT_STATUS="${SCRIPT_STATUS:-0}"

for out in "$OUT_FAN" "$OUT_PREVIEW" "$OUT_WALLPAPERS" "$OUT_WALLPAPER_PREVIEW" "$OUT_DEAL"; do
  if [ ! -s "$out" ]; then
    echo "no snapshot was written to $out" >&2
    exit 1
  fi
  echo "wrote $out"
done
if [ "$SCRIPT_STATUS" -ne 0 ]; then
  echo "theme cards script failed (exit $SCRIPT_STATUS)" >&2
  exit 1
fi
