#!/bin/bash
# Headless render of the fanned theme cards, for eyeballing the hand without
# opening Palette. Uses the scripted panel hooks, so it never activates the app.
#
#   scripts/theme-cards-snapshot.sh [output.png]
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Palette.app/Contents/MacOS/Palette"
OUT="${1:-Tests/Snapshots/theme-cards-fan.png}"
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

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

PALETTE_CONFIG_DIR="$CONFIG" \
PALETTE_STATE_DIR="$CONFIG/state" \
PALETTE_CACHE_DIR="$CONFIG/cache" \
PALETTE_SUPPORT_DIR="$CONFIG/support" \
PALETTE_SCRIPT="themecards; wait=1.5; themecards_next; wait=0.35; themecards_next; wait=0.6; themecards_snapshot=$OUT; wait=0.2; exit" \
  nice -n 10 taskpolicy -b "$APP" >/dev/null 2>&1 || true

if [ ! -s "$OUT" ]; then
  echo "no snapshot was written to $OUT" >&2
  exit 1
fi
echo "wrote $OUT"
