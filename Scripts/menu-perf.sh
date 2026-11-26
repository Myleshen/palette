#!/bin/bash
# Opens the 942-row menu probe, captures it, scrolls one page, then prints the
# open/scroll timings the app logged. Uses throwaway config/state directories
# and never touches the installed app.
#
#   Scripts/menu-perf.sh [path/to/Palette.app/Contents/MacOS/Palette]
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/Palette.app/Contents/MacOS/Palette}"
if [ ! -x "$APP" ]; then
  echo "No binary at $APP. Run 'make app' first." >&2
  exit 1
fi

dir="$(mktemp -d "${TMPDIR:-/tmp}/palette-menu-perf.XXXXXX")"

PALETTE_SCRIPT="palettemenu_stress; wait=0.4; palettemenu_snapshot=$dir/open.png; palettemenu_scroll; wait=0.4; palettemenu_snapshot=$dir/scroll.png; palettemenu_filter=Theme 42; wait=0.3; palettemenu_snapshot=$dir/filter.png; exit" \
PALETTE_CONFIG_DIR="$dir/config" \
PALETTE_STATE_DIR="$dir/state" \
PALETTE_CACHE_DIR="$dir/cache" \
PALETTE_SUPPORT_DIR="$dir/support" \
  nice -n 10 taskpolicy -b "$APP" >"$dir/app.log" 2>&1 || {
    echo "FAIL: app exited non-zero" >&2
    tail -20 "$dir/app.log" >&2
    exit 1
  }

grep -E "Palette menu" "$dir/app.log" || true
echo "Snapshots and log: $dir"
