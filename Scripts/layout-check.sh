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

# Renders and the test app yield to whatever the user is doing.
bg() { nice -n 10 taskpolicy -b "$@"; }

cleanup() { rm -rf "$CURRENT_DIR"; }
trap cleanup EXIT INT TERM

# A stale bundle silently compares old renders against the snapshots, which
# reads as a passing check. Rebuild whenever the sources moved.
bundle_is_stale() {
  [ ! -x "$APP" ] && return 0
  find Sources Resources Package.swift Package.resolved \
    -newer "$APP" -type f 2>/dev/null | grep -q .
}

if bundle_is_stale; then
  echo "building…"
  bg make app >/dev/null
fi

mkdir -p "$REFERENCE_DIR"
failed=0

# One snapshot per SettingsTab.allCases entry. The case list is read from the
# enum declaration so adding a tab does not silently skip its snapshot.
TAB_CASES="$(awk '/enum SettingsTab/{found=1} found && /^    case /{print} found && /var id: Int/{exit}' Sources/PaletteApp/SettingsView.swift)"
TAB_COUNT="$(printf '%s\n' "$TAB_CASES" | sed 's/^    case //' | tr ',' '\n' | grep -c '[[:alnum:]]')"
if [ "$TAB_COUNT" -lt 1 ]; then
  echo "could not read SettingsTab.allCases from Sources/PaletteApp/SettingsView.swift"
  exit 1
fi
echo "rendering $TAB_COUNT settings tabs"

for ((tab = 0; tab < TAB_COUNT; tab++)); do
  config="$(mktemp -d /tmp/palette-layout-cfg.XXXXXX)"
  PALETTE_CONFIG_DIR="$config" \
  PALETTE_STATE_DIR="$config/state" \
  PALETTE_CACHE_DIR="$config/cache" \
  PALETTE_SUPPORT_DIR="$config/support" \
  PALETTE_SCRIPT="settings; settings_size=900x649; wait=0.6; settings_tab=$tab; wait=0.9; settings_clear_search; wait=0.15; settings_snapshot=$CURRENT_DIR/section-$tab.png; exit" \
    nice -n 10 taskpolicy -b "$APP" >/dev/null 2>&1 || true

  reference="$REFERENCE_DIR/settings-$tab.png"
  if [ ! -f "$CURRENT_DIR/section-$tab.png" ]; then
    echo "section $tab: FAILED to render"
    failed=1
    rm -rf "$config"
    continue
  fi

  if [ "$RECORD" = "1" ] || [ ! -f "$reference" ]; then
    cp "$CURRENT_DIR/section-$tab.png" "$reference"
    echo "section $tab: recorded"
    rm -rf "$config"
    continue
  fi

  if result="$(bg swift scripts/pixel-diff.swift "$reference" "$CURRENT_DIR/section-$tab.png" "$TOLERANCE")"; then
    echo "section $tab: ok ($result)"
  else
    echo "section $tab: CHANGED ($result)"
    failed=1
  fi
  rm -rf "$config"
done

if [ "$failed" = "1" ]; then
  echo
  echo "Layout differs from $REFERENCE_DIR. If the change is intended, run:"
  echo "  scripts/layout-check.sh --record"
  echo "Current renders are in $CURRENT_DIR"
  # Keep the renders for inspection; clear the trap so EXIT does not remove them.
  trap - EXIT INT TERM
  exit 1
fi

echo "layout ok"
