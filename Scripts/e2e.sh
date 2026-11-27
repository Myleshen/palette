#!/bin/bash
# End-to-end flows against the built app bundle. Each flow gets a fresh,
# isolated home and config/state/cache directory, drives the real app through
# PALETTE_SCRIPT, and fails on a non-zero exit or a missing artifact.
#
# Only things a shipped bundle can prove live here: real AppKit window
# placement, real Carbon hotkey registration, the terminate request, the cold
# launch round-trip, and that the process leaves nothing behind. Behaviour that
# can be asserted against the controller runs in `swift test` instead
# (Tests/PaletteTests/ControllerIntegrationTests.swift and friends).
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

# run_flow <name> <script> [required file] [check function]
# %DIR% in the script and required path expands to the flow's temp directory.
# The optional check function runs with the temp directory before it is deleted,
# for assertions the script grammar cannot express (JSON frames, process lists).
run_flow() {
  local name="$1" script="$2" required="${3:-}" check="${4:-}"
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/palette-e2e-$name.XXXXXX")"
  script="${script//%DIR%/$dir}"
  required="${required//%DIR%/$dir}"
  local log="$dir/app.log"

  PALETTE_SCRIPT="$script" \
  PALETTE_HOME="$dir/home" \
  PALETTE_CONFIG_DIR="$dir/config" \
  PALETTE_STATE_DIR="$dir/state" \
  PALETTE_CACHE_DIR="$dir/cache" \
  PALETTE_SUPPORT_DIR="$dir/support" \
  PALETTE_FORCE_HOTKEYS="${FORCE_HOTKEYS:-0}" \
    nice -n 10 taskpolicy -b "$APP" >"$log" 2>&1 &
  app_pid=$!

  # The script itself exits; the watchdog only catches a hung launch.
  local ticks=0
  while kill -0 "$app_pid" 2>/dev/null && [ "$ticks" -lt 160 ]; do
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

  if [ -n "$check" ] && ! "$check" "$dir" "$log"; then
    echo "FAIL $name: check failed"
    failed=1
    return
  fi

  rm -rf "$dir"
  echo "PASS $name"
}

# The controller's own behaviour (search reset, panel modes, menu picker,
# cheatsheets, theme/wallpaper apply) runs in swift test. What remains here is
# what only the assembled bundle can answer.

# Default global hotkeys are Carbon registrations against the live keyboard
# layout: only a running app can prove they all take, and that none lost to
# another owner. The script mode opt-in exists for exactly this.
check_hotkeys() {
  local log="$2"
  local registered
  registered="$(grep -c "Hotkey registered:" "$log" || true)"
  if [ "$registered" -ne 11 ]; then
    echo "    registered $registered hotkeys, expected 11"
    { grep "Hotkey" "$log" || true; } | tail -20 | sed 's/^/    /'
    return 1
  fi
  if grep -q "is unavailable\|unavailable:" "$log"; then
    echo "    a hotkey was unavailable"
    grep "Hotkey" "$log" | grep -i "unavailable" | sed 's/^/    /'
    return 1
  fi
}
# A running Palette already owns the same keys, so the defaults cannot be
# registered twice. CI has none; a workstation usually does.
if pgrep -x Palette >/dev/null 2>&1; then
  echo "SKIP hotkeys: a Palette process is running and holds the default shortcuts"
else
  FORCE_HOTKEYS=1 run_flow hotkeys \
    'wait_until=registeredHotkeys=11;timeout=15; show; wait=0.2; dump=%DIR%/state.json; exit' \
    '%DIR%/state.json' check_hotkeys
fi

# A real NSPanel must land at the configured size inside the active screen's
# visible frame, and a capture request (which needs Screen Recording TCC, not
# granted on CI) must not take the panel down with it.
run_flow panel-geometry-capture \
  'show; wait=0.8; assert=panelGeometryOK=true; shot; wait=1.5; assert=panelVisible=true; exit'

# Spotlight is off for these users, so a stray ⌘Q must dismiss, not quit.
# Reaching dump/exit proves the process survived the terminate request.
run_flow quit-intercepted \
  'show; wait=0.6; quit; wait=0.4; assert=panelVisible=false; dump=%DIR%/state.json; exit' \
  '%DIR%/state.json'

# A cold launch with nothing but an isolated home must accept the whole script
# grammar and write a parseable dump.
check_dump() {
  plutil -extract panelVisible raw -o - "$1/state.json" >/dev/null
}
run_flow cold-launch-script \
  'show; wait=0.7; query=session; wait=0.5; dump=%DIR%/state.json; exit' \
  '%DIR%/state.json' check_dump

# Closing the app must reap the PTY child the embedded terminal started, not
# leave an orphan behind. `sleep 4242` is unique enough to pgrep safely.
check_no_children() {
  local leftover=""
  for _ in 1 2 3 4; do
    leftover="$(pgrep -f 'sleep 4242' || true)"
    [ -z "$leftover" ] && return 0
    sleep 0.5
  done
  echo "    left PTY child running: $leftover"
  return 1
}
run_flow no-surviving-children \
  'show; term=sleep 4242; wait=2.5; exit' "" check_no_children

if [ "$failed" -ne 0 ]; then
  echo "e2e failed"
  exit 1
fi

# Belt and braces: no Palette process may outlive the run.
leftover="$(pgrep -f "$(pwd)/$APP" || true)"
if [ -n "$leftover" ]; then
  echo "FAIL leftover Palette process: $leftover"
  exit 1
fi
echo "e2e ok"
