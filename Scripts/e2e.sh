#!/bin/bash
# End-to-end flows against the built app bundle. Each flow gets a fresh
# config/state/cache directory, drives the real controller through
# PALETTE_SCRIPT, and fails on a non-zero exit or a missing artifact.
#
#   Scripts/e2e.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Palette.app/Contents/MacOS/Palette"
# Builds and the test app yield to whatever the user is doing.
bg() { nice -n 10 taskpolicy -b "$@"; }
# A stale bundle exercises old code and passes: rebuild whenever sources moved.
bundle_is_stale() {
  [ ! -x "$APP" ] && return 0
  find Sources Resources Package.swift Package.resolved \
    -newer "$APP" -type f 2>/dev/null | grep -q .
}

if bundle_is_stale; then
  bg make app
fi

failed=0
app_pid=""

# No Palette process may outlive the harness, even on Ctrl-C or a failure.
cleanup() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid" 2>/dev/null || true
    sleep 0.5
    kill -KILL "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

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
  PALETTE_SUPPORT_DIR="$dir/support" \
    nice -n 10 taskpolicy -b "$APP" >"$log" 2>&1 &
  app_pid=$!

  # The script itself exits; the watchdog only catches a hung launch.
  local ticks=0
  while kill -0 "$app_pid" 2>/dev/null && [ "$ticks" -lt 120 ]; do
    sleep 0.25
    ticks=$((ticks + 1))
  done
  if kill -0 "$app_pid" 2>/dev/null; then
    kill -9 "$app_pid" 2>/dev/null || true
    echo "FAIL $name: timed out"
    tail -20 "$log" | sed 's/^/    /'
    failed=1
    return
  fi

  local status=0
  wait "$app_pid" || status=$?
  app_pid=""

  if [ "$status" -ne 0 ] || ! grep -q "SCRIPT OK" "$log"; then
    echo "FAIL $name (exit $status)"
    tail -20 "$log" | sed 's/^/    /'
    failed=1
    return
  fi

  # A scripted run must never take focus: the app logs every quiet show.
  if ! grep -q "without activation" "$log"; then
    echo "FAIL $name: no quiet-presentation log line"
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
  'show; wait=0.6; assert=appActive=false; query=safari; wait=0.8; key=down; wait=0.2; hide; wait=0.3; show; wait=0.8; assert=query=; assert=selectionIndex=0; assert=appActive=false; dump=%DIR%/state.json; exit'

# The capture needs Screen Recording TCC, which CI does not grant; the panel
# must survive either outcome, so only visibility is asserted.
run_flow screenshot-keeps-panel \
  'show; wait=0.6; shot; wait=1.5; assert=panelVisible=true; exit'

# Default global providers (system/timer/awake) must answer an unprefixed
# query without depending on installed apps. The wait is generous because the
# app runs at background QoS and yields to whatever the user is doing.
run_flow universal-search \
  'show; query=session; wait_until=itemCount>0;timeout=10; dump=%DIR%/state.json; exit'

run_flow launcher-tab \
  'settings; wait=0.8; settings_tab=1; wait=0.9; settings_snapshot=%DIR%/settings-launcher.png; exit' \
  '%DIR%/settings-launcher.png'

# The status item's panel replaces an NSMenu: it must open without activating
# the app, render rows, and close on Esc.
run_flow status-panel-interaction \
  'show; wait=0.6; statuspanel; wait=0.6; assert=statusPanelOpen=true; assert=statusPanelRows>0; assert=appActive=false; assert=panelVisible=true; key=esc; wait=0.3; assert=statusPanelOpen=false; assert=appActive=false; exit'

# A non-tracking Palette menu keeps the app inactive and its keys alive. The
# probe stands in for a global hotkey callback; a native NSMenu would hold it.
run_flow palette-menu-probe \
  'show; wait=0.6; palette_menu=probe; wait=0.4; assert=paletteMenuOpen=true; assert=paletteMenuRows=5; assert=paletteMenuHighlight=probe-one; assert=appActive=false; palettemenu_probe; assert=paletteMenuProbe=1; key=down; wait=0.2; assert=paletteMenuHighlight=probe-two; key=down; wait=0.2; assert=paletteMenuHighlight=probe-three; key=down; wait=0.2; assert=paletteMenuHighlight=probe-one; key=esc; wait=0.3; assert=paletteMenuOpen=false; assert=appActive=false; dump=%DIR%/state.json; exit' \
  '%DIR%/state.json'

# The picker rows are built by the same helper PaletteMenuPicker uses, so the
# count and the choice round-trip cover the real control.
run_flow palette-menu-picker \
  'show; wait=0.6; palette_menu=picker; wait=0.4; assert=paletteMenuOpen=true; assert=paletteMenuRows=4; assert=paletteMenuHighlight=choice:0; key=down; wait=0.2; assert=paletteMenuHighlight=choice:1; key=up; wait=0.2; assert=paletteMenuHighlight=choice:0; key=esc; wait=0.3; assert=paletteMenuOpen=false; exit'

# The web-search engine browser picker from Settings: default row, installed
# browsers, separator, the two mode rows.
run_flow engine-browser-picker \
  'show; wait=0.6; palette_menu=engine_browser; wait=0.4; assert=paletteMenuOpen=true; assert=paletteMenuRows>4; assert=paletteMenuHighlight=default-browser; assert=appActive=false; palettemenu_probe; assert=paletteMenuProbe=1; key=down; wait=0.2; assert=paletteMenuHighlight!=default-browser; key=esc; wait=0.3; assert=paletteMenuOpen=false; exit'

# Opening the 942-row theme browser must stay lazy: only the rows that fit the
# 430 pt list pane appear, not all 900+ TOML files.
run_flow theme-menu-lazy \
  'settings; wait=0.8; settings_tab=19; wait_until=themeMenuRendered>0;timeout=15; assert=themeMenuRows>900; assert=themeMenuRendered<45; assert=appActive=false; dump=%DIR%/state.json; exit' \
  '%DIR%/state.json'

# The scratchpad, ask, terminal and preview panels share one content area:
# opening a mode must close the previous one.
# Ask lives in its own window now: opening it must not tear down the panel's
# scratchpad or terminal, and the window must be tracked separately.
run_flow ask-window-not-modal \
  'show; wait=0.6; scratchpad; wait=0.4; askwindow=hello; wait_until=askWindows=1;timeout=10; assert=scratchpadActive=true; dump=%DIR%/state.json; exit' \
  '%DIR%/state.json'

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
  'show; wait=0.6; askwindow=hello; wait_until=askWindows=1;timeout=10; assert=panelVisible=true; dump=%DIR%/state.json; exit' \
  '%DIR%/state.json'

if [ "$failed" -ne 0 ]; then
  echo "e2e failed"
  exit 1
fi

# Belt and braces: no Palette child may outlive the run.
leftover="$(pgrep -f "$(pwd)/$APP" || true)"
if [ -n "$leftover" ]; then
  echo "FAIL leftover Palette process: $leftover"
  exit 1
fi
echo "e2e ok"
