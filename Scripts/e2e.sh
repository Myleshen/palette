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

# run_flow <name> <script> [required file] [prep function]
# %DIR% in the script and required path expands to the flow's temp directory.
# The optional prep function runs with the temp directory before launch.
run_flow() {
  local name="$1" script="$2" required="${3:-}" prep="${4:-}"
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/palette-e2e-$name.XXXXXX")"
  script="${script//%DIR%/$dir}"
  required="${required//%DIR%/$dir}"
  local log="$dir/app.log"

  if [ -n "$prep" ]; then
    "$prep" "$dir"
  fi

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

# The scratchpad, ask, terminal and preview panels share one content area:
# opening a mode must close the previous one.
run_flow mode-exclusive \
  'show; wait=0.6; scratchpad; wait=0.4; assert=scratchpadActive=true; ask; wait=0.4; assert=previewEnabled=true; assert=scratchpadActive=false; assert=terminalActive=false; dump=%DIR%/state.json; exit'

run_flow mode-exclusive-reverse \
  'show; wait=0.6; ask; wait=0.4; assert=previewEnabled=true; scratchpad; wait=0.4; assert=scratchpadActive=true; assert=previewEnabled=false; assert=terminalActive=false; dump=%DIR%/state.json; exit'

# A folder declared in the flow's own config must reach /cheat.
prep_cheatsheets() {
  local dir="$1" sheets="$1/sheets"
  mkdir -p "$sheets" "$dir/config"
  printf '# Deploy notes\n\n- build\n- ship\n' > "$sheets/notes.md"
  printf 'tiny guide\n' > "$sheets/guide.txt"
  printf '[cheatsheets]\nfolders = ["%s"]\n' "$sheets" > "$dir/config/config.toml"
}

run_flow cheatsheets \
  'show; wait=0.7; query=/cheat; wait_until=itemCount>0;timeout=5; assert=firstProvider=cheat; dump=%DIR%/state.json; exit' \
  '%DIR%/state.json' prep_cheatsheets

# ⌘Q with the launcher open dismisses it instead of quitting: Spotlight is off
# for these users, so a stray ⌘Q would leave them with no launcher. Reaching the
# dump/exit proves the process survived the terminate request.
run_flow quit-intercepted \
  'show; wait=0.6; quit; wait=0.4; assert=panelVisible=false; dump=%DIR%/state.json; exit' \
  '%DIR%/state.json'

# Asking must not tear the launcher down: both stay on screen together.
run_flow ask-window-coexists \
  'show; wait=0.6; askwindow=hello; wait=1.0; assert=panelVisible=true; assert=askWindows=1; dump=%DIR%/state.json; exit' \
  '%DIR%/state.json'

if [ "$failed" -ne 0 ]; then
  echo "e2e failed"
  exit 1
fi
echo "e2e ok"
