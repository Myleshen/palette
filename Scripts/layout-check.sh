#!/bin/bash
# Renders every Settings section headlessly and compares it with the checked-in
# reference. Catches clipping, shifted labels and squashed controls, which unit
# tests cannot see.
#
#   scripts/layout-check.sh            check
#   scripts/layout-check.sh --record   replace the references
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Palette.app/Contents/MacOS/Palette"
REFERENCE_DIR="Tests/Snapshots"
CURRENT_DIR="$(mktemp -d /tmp/palette-layout.XXXXXX)"
TOLERANCE="${TOLERANCE:-0.02}"
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1

if [ ! -x "$APP" ]; then
  echo "building…"
  make app >/dev/null
fi

mkdir -p "$REFERENCE_DIR"
failed=0

# One snapshot per SettingsTab.allCases entry. The case list is read from the
# enum declaration so adding a tab does not silently skip its snapshot.
TAB_CASES="$(awk '/enum SettingsTab/{found=1} found && /^    case /{print; exit}' Sources/PaletteApp/SettingsView.swift)"
TAB_COUNT="$(printf '%s\n' "$TAB_CASES" | tr ',' '\n' | wc -l | tr -d ' ')"
if [ "$TAB_COUNT" -lt 1 ]; then
  echo "could not read SettingsTab.allCases from Sources/PaletteApp/SettingsView.swift"
  exit 1
fi
echo "rendering $TAB_COUNT settings tabs"

for ((tab = 0; tab < TAB_COUNT; tab++)); do
  config="$(mktemp -d /tmp/palette-layout-cfg.XXXXXX)"
  PALETTE_CONFIG_DIR="$config" \
  PALETTE_STATE_DIR="$config/state" \
  PALETTE_SCRIPT="settings; wait=0.8; settings_tab=$tab; wait=0.9; settings_snapshot=$CURRENT_DIR/section-$tab.png; exit" \
    "$APP" >/dev/null 2>&1 || true

  reference="$REFERENCE_DIR/settings-$tab.png"
  if [ ! -f "$CURRENT_DIR/section-$tab.png" ]; then
    echo "section $tab: FAILED to render"
    failed=1
    continue
  fi

  if [ "$RECORD" = "1" ] || [ ! -f "$reference" ]; then
    cp "$CURRENT_DIR/section-$tab.png" "$reference"
    echo "section $tab: recorded"
    continue
  fi

  if result="$(swift scripts/pixel-diff.swift "$reference" "$CURRENT_DIR/section-$tab.png" "$TOLERANCE")"; then
    echo "section $tab: ok ($result)"
  else
    echo "section $tab: CHANGED ($result)"
    failed=1
  fi
done

if [ "$failed" = "1" ]; then
  echo
  echo "Layout differs from $REFERENCE_DIR. If the change is intended, run:"
  echo "  scripts/layout-check.sh --record"
  echo "Current renders are in $CURRENT_DIR"
  exit 1
fi

rm -rf "$CURRENT_DIR"
echo "layout ok"
