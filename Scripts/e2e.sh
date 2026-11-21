#!/bin/bash
# End-to-end flows against the built app bundle. Each flow gets a fresh
# config/state/cache directory, drives the real controller through
# PALETTE_SCRIPT, and fails on a non-zero exit or a missing artifact.
#
#   Scripts/e2e.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Palette.app/Contents/MacOS/Palette"
if [ ! -x "$APP" ]; then
  make app
fi

failed=0

# run_flow <name> <script> [required file]
# %DIR% in the script and required path expands to the flow's temp directory.
run_flow() {
  local name="$1" script="$2" required="${3:-}"
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/palette-e2e-$name.XXXXXX")"
  script="${script//%DIR%/$dir}"
  required="${required//%DIR%/$dir}"
  local log="$dir/app.log"

  PALETTE_SCRIPT="$script" \
  PALETTE_CONFIG_DIR="$dir/config" \
  PALETTE_STATE_DIR="$dir/state" \
  PALETTE_CACHE_DIR="$dir/cache" \
    "$APP" >"$log" 2>&1 &
  local pid=$!

  # The script itself exits; the watchdog only catches a hung launch.
  local ticks=0
  while kill -0 "$pid" 2>/dev/null && [ "$ticks" -lt 120 ]; do
    sleep 0.25
    ticks=$((ticks + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    echo "FAIL $name: timed out"
    tail -20 "$log" | sed 's/^/    /'
    failed=1
    return
  fi

  local status=0
  wait "$pid" || status=$?

  if [ "$status" -ne 0 ] || ! grep -q "SCRIPT OK" "$log"; then
    echo "FAIL $name (exit $status)"
    tail -20 "$log" | sed 's/^/    /'
    failed=1
    return
  fi

  if [ -n "$required" ] && [ ! -s "$required" ]; then
    echo "FAIL $name: missing $required"
    failed=1
    return
  fi

  rm -rf "$dir"
  echo "PASS $name"
}

run_flow empty-query-reset \
  'show; wait=0.6; query=safari; wait=0.8; key=down; wait=0.2; hide; wait=0.3; show; wait=0.8; assert=query=; assert=selectionIndex=0; dump=%DIR%/state.json; exit'

# The capture needs Screen Recording TCC, which CI does not grant; the panel
# must survive either outcome, so only visibility is asserted.
run_flow screenshot-keeps-panel \
  'show; wait=0.6; shot; wait=1.5; assert=panelVisible=true; exit'

# Default global providers (system/timer/awake) must answer an unprefixed
# query without depending on installed apps.
run_flow universal-search \
  'show; query=session; wait=1.0; assert=itemCount>0; dump=%DIR%/state.json; exit'

run_flow terminal-tab \
  'settings; wait=0.8; settings_tab=10; wait=0.9; settings_snapshot=%DIR%/settings-terminal.png; exit' \
  '%DIR%/settings-terminal.png'

if [ "$failed" -ne 0 ]; then
  echo "e2e failed"
  exit 1
fi
echo "e2e ok"
