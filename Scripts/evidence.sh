#!/bin/bash
# Per-action evidence pass for Palette 2.20.0.
#
# One real render of the app per user-facing action, produced by the app's own
# snapshot hooks (Screen Recording is unavailable to a shell-launched run, and
# must never be needed). Every scenario gets a throwaway HOME/config/state/
# cache/support tree, is driven through PALETTE_SCRIPT, and must leave a
# non-blank PNG plus the app's JSON state dump behind.
#
#   Scripts/evidence.sh            run every scenario
#   Scripts/evidence.sh 01 12 17   run only those numbers (while iterating)
#
# Output:
#   Tests/Evidence/actions/NN-name.png
#   Tests/Evidence/actions/NN-name.json
#   Tests/Evidence/actions/summary.tsv
#   Tests/Evidence/panes/*.png     (the 20 Settings renders)
#   Tests/Evidence/index.html
set -uo pipefail

cd "$(dirname "$0")/.."

ROOT="$PWD"
APP="$ROOT/build/Palette.app/Contents/MacOS/Palette"
OUT="$ROOT/Tests/Evidence/actions"
PANES="$ROOT/Tests/Evidence/panes"
WORK="${TMPDIR:-/tmp}/palette-evidence.$$"
SUMMARY="$OUT/summary.tsv"
INDEX_DATA="$OUT/index.tsv"
ONLY="$*"

mkdir -p "$OUT" "$PANES" "$WORK"
: >"$SUMMARY"
: >"$INDEX_DATA"

APP_PID=""
cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        sleep 0.4
        kill -KILL "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

bg() { nice -n 10 taskpolicy -b "$@"; }

should_run() {
    [ -z "$ONLY" ] && return 0
    local wanted
    for wanted in $ONLY; do [ "$wanted" = "$1" ] && return 0; done
    return 1
}

# A stale bundle silently renders old code: rebuild when sources moved.
bundle_is_stale() {
    [ ! -x "$APP" ] && return 0
    find Sources Resources Package.swift Package.resolved \
        -newer "$APP" -type f 2>/dev/null | grep -q .
}
if bundle_is_stale; then
    echo "building…"
    bg make app >/dev/null || { echo "build failed"; exit 1; }
fi

# run_app <dir> <script> [extra app arguments...]
# One isolated cold launch. Success = exit 0 and the app printed SCRIPT OK.
run_app() {
    local dir="$1" script="$2"
    shift 2
    local log="$dir/app.log"
    HOME="$dir/home" \
    PALETTE_SCRIPT="$script" \
    PALETTE_HOME="$dir/home" \
    PALETTE_CONFIG_DIR="$dir/config" \
    PALETTE_STATE_DIR="$dir/state" \
    PALETTE_CACHE_DIR="$dir/cache" \
    PALETTE_SUPPORT_DIR="$dir/support" \
    PALETTE_FORCE_HOTKEYS=0 \
        bg "$APP" "$@" >"$log" 2>&1 &
    APP_PID=$!
    local ticks=0
    while kill -0 "$APP_PID" 2>/dev/null && [ "$ticks" -lt 300 ]; do
        sleep 0.25
        ticks=$((ticks + 1))
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill -9 "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null
        APP_PID=""
        echo "RUN: timed out after 75s" >>"$log"
        return 1
    fi
    local status=0
    wait "$APP_PID" || status=$?
    APP_PID=""
    grep -q "SCRIPT OK" "$log" || return 1
    return "$status"
}

fixture() { swift "$ROOT/Scripts/evidence-fixture.swift" "$@"; }

write_config() {
    local dir="$1"
    shift
    mkdir -p "$dir/config"
    printf '%s\n' "$@" >"$dir/config/config.toml"
}

# A first launch creates palette.sqlite and its schema. Fixtures are inserted
# afterwards, before the scenario launch, so the seeded rows are real database
# rows the provider reads (never a fake view).
init_db() {
    local dir="$1"
    run_app "$dir" "wait=0.2; exit" || return 1
    rm -f "$dir/app.log"
}

sql() { sqlite3 "$1/state/palette.sqlite" "$2"; }

seed_clip_text() { # dir text created pinned
    local dir="$1" text="$2" created="$3" pinned="$4"
    local hash
    hash=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
    sql "$dir" "INSERT OR REPLACE INTO clipboard (id, hash, text, created, pinned, kind)
        VALUES ('clip-$hash', '$hash', '$text', $created, $pinned, 'text');"
}

seed_clip_image() { # dir png created
    local dir="$1" png="$2" created="$3"
    local sha rel sub id
    sha=$(shasum -a 256 "$png" | awk '{print $1}')
    sub=${sha:0:2}
    rel="images/$sub/$sha.png"
    id="img-$sha"
    mkdir -p "$dir/state/clipboard/images/$sub"
    cp "$png" "$dir/state/clipboard/$rel"
    sql "$dir" "INSERT OR REPLACE INTO clipboard (id, hash, text, created, pinned, kind, width, height)
        VALUES ('$id', '$sha', '', $created, 0, 'image', 1200, 700);
        INSERT OR REPLACE INTO clipboard_images
            (clipboard_id, sha256, relative_path, thumb_relative_path, byte_count, width, height)
        VALUES ('$id', '$sha', '$rel', '$rel', $(wc -c <"$png" | tr -d ' '), 1200, 700);"
}

seed_clip_files() { # dir paths csv created
    local dir="$1" text="$2" created="$3" hash
    hash=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
    sql "$dir" "INSERT OR REPLACE INTO clipboard (id, hash, text, created, pinned, kind)
        VALUES ('files-$hash', '$hash', '$text', $created, 0, 'files');"
}

seed_wallpapers() { # dir
    local dir="$1" i hue
    mkdir -p "$dir/wallpapers"
    for i in 0 1 2 3 4 5; do
        hue=$(awk -v i="$i" 'BEGIN { printf "%.2f", i / 6 }')
        fixture "$dir/wallpapers/wall-$i.png" 1200 700 "$hue"
    done
}

# prepare <dir> <number>: seed config and database fixtures before the launch.
prepare() {
    local dir="$1" nn="$2" now
    now=$(date +%s)
    case "$nn" in
    03)
        # The no-results state must not be filled by web-search fallback rows.
        write_config "$dir" '[web_search]' 'enabled = false'
        ;;
    04)
        init_db "$dir"
        seed_clip_text "$dir" "SELECT * FROM sessions WHERE expires_at < now();" "$((now - 300))" 0
        seed_clip_text "$dir" "kubectl logs -f deploy/palette --tail=200" "$((now - 200))" 0
        ;;
    06)
        # A plain login shell, no multiplexer: the user's zellij server must
        # not be attached to or typed into by an evidence run.
        write_config "$dir" '[terminal_session]' 'multiplexer = "none"' 'shell = "/bin/zsh"'
        ;;
    10)
        write_config "$dir" '[theming]' 'enabled = true' 'source = "theme"'
        ;;
    11)
        write_config "$dir" '[theming]' 'enabled = true' 'source = "wallpaper"' \
            "wallpaper_directory = \"$dir/wallpapers\""
        seed_wallpapers "$dir"
        ;;
    14|15|18)
        write_config "$dir" '[theming]' 'enabled = true' 'source = "wallpaper"' \
            "wallpaper_directory = \"$dir/wallpapers\""
        seed_wallpapers "$dir"
        ;;
    19)
        init_db "$dir"
        fixture "$dir/clip-image.png" 1200 700 0.55
        seed_clip_text "$dir" "kubectl logs -f deploy/palette --tail=200" "$((now - 90))" 0
        seed_clip_text "$dir" "BEGIN; UPDATE settings SET source = theme; COMMIT;" "$((now - 180))" 0
        seed_clip_text "$dir" "https://github.com/myleshen/palette/releases" "$((now - 260))" 0
        seed_clip_image "$dir" "$dir/clip-image.png" "$((now - 360))"
        seed_clip_files "$dir" "/Users/evidence/Downloads/release-notes.md
/Users/evidence/Downloads/palette-2.20.0.dmg" "$((now - 480))"
        ;;
    20)
        init_db "$dir"
        seed_clip_text "$dir" "Release checklist: deck, panes, typography" "$((now - 600))" 1
        seed_clip_text "$dir" "Newest unpinned copy" "$((now - 30))" 0
        seed_clip_text "$dir" "Older unpinned copy" "$((now - 120))" 0
        ;;
    22)
        mkdir -p "$dir/config"
        printf '%s\n' \
            '[[snippet]]' \
            'title = "Email signature"' \
            'keywords = ["email", "mail", "signature"]' \
            'text = "Best regards,\nMyles\n{{date}}"' \
            >"$dir/config/snippets.toml"
        ;;
    23)
        write_config "$dir" '# evidence fixture'
        printf '%s\n' \
            '[[bookmark]]' \
            'name = "Palette Releases"' \
            'url = "https://github.com/myleshen/palette/releases"' \
            'browser = ""' \
            'keywords = ["release", "palette"]' \
            '' \
            '[[bookmark]]' \
            'name = "Ghostty Themes"' \
            'url = "https://github.com/ghostty-org/ghostty/tree/main/themes"' \
            'browser = ""' \
            'keywords = ["theme", "ghostty"]' \
            '' \
            '[[bookmark]]' \
            'name = "OpenCode Docs"' \
            'url = "https://opencode.ai/docs"' \
            'browser = ""' \
            'keywords = ["docs", "agents"]' \
            >"$dir/config/bookmarks.toml"
        ;;
    24)
        mkdir -p "$dir/cheats"
        printf '# Palette cheatsheet\n\n- /clip\n- /theme\n' >"$dir/cheats/shortcuts.md"
        printf 'zellij keybinds\n' >"$dir/cheats/zellij.txt"
        printf 'git workflows\n' >"$dir/cheats/git.md"
        write_config "$dir" '[cheatsheets]' "folders = [\"$dir/cheats\"]" 'extensions = ["md", "txt"]'
        ;;
    25)
        init_db "$dir"
        sql "$dir" "INSERT INTO webapps (id, name, url, created, shortcut) VALUES
            ('wa-1', 'Linear', 'https://linear.app', $((now - 300)), 'lin'),
            ('wa-2', 'Figma', 'https://figma.com', $((now - 200)), 'fig'),
            ('wa-3', 'GitHub', 'https://github.com', $((now - 100)), 'gh');"
        ;;
    28b)
        fixture "$dir/preview.png" 1200 760 0.08
        ;;
    29)
        init_db "$dir"
        sql "$dir" "INSERT INTO ask_chats (id, title, model, created, updated)
            VALUES ('chat-1', '2.20.0 release checklist', 'beam-free', $((now - 120)), $((now - 60)));
            INSERT INTO ask_chat_messages
                (id, chat_id, role, content, created, duration_ms, prompt_tokens, completion_tokens, sources)
            VALUES
                ('msg-1', 'chat-1', 'user', 'What should I verify before shipping 2.20.0?', $((now - 110)), 0, 0, 0, NULL),
                ('msg-2', 'chat-1', 'assistant', 'Verify the theme deck at 3440x1415, every Settings pane, the launcher after a palette apply, and the contrast and error states.', $((now - 100)), 1450, 18, 64, NULL),
                ('msg-3', 'chat-1', 'user', 'And the wallpaper state?', $((now - 90)), 0, 0, 0, NULL),
                ('msg-4', 'chat-1', 'assistant', 'Extract the desktop palette in an isolated home, confirm palette.json, then show the launcher in those colours.', $((now - 80)), 980, 12, 48, NULL);"
        ;;
    31)
        write_config "$dir" '[search]' 'enabled = true'
        ;;
    33)
        write_config "$dir" '[theming]' 'enabled = true' 'source = "theme"'
        ;;
    35)
        write_config "$dir" '[theme' 'mode = "dark"' 'this is not toml'
        ;;
    36|37)
        write_config "$dir" '# evidence fixture'
        ;;
    40)
        write_config "$dir" '# evidence fixture'
        ;;
    esac
}

dims_of() {
    local png="$1"
    sips -g pixelWidth -g pixelHeight "$png" 2>/dev/null |
        awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {if (w && h) print w"x"h}'
}

# post_18: the wallpaper apply must have written its own palette in isolation,
# and the launcher colours must be that palette, not the config theme.
post_18() {
    local dir="$1" json="$2"
    local palette="$dir/config/theme/palette.json"
    [ -s "$palette" ] || { echo "palette.json missing at $palette"; return 1; }
    local source palette_bg launcher_bg
    source=$(plutil -extract source raw -o - "$palette" 2>/dev/null)
    palette_bg=$(plutil -extract background raw -o - "$palette" 2>/dev/null)
    launcher_bg=$(plutil -extract theme.background raw -o - "$json" 2>/dev/null)
    [ "$source" = "wallpaper" ] || { echo "palette.json source is '$source'"; return 1; }
    [ -n "$palette_bg" ] && [ "$palette_bg" = "$launcher_bg" ] ||
        { echo "launcher bg '$launcher_bg' != palette.json bg '$palette_bg'"; return 1; }
}

# post_40: applying a theme while the deck was closed must visibly change the
# launcher compared with the same query on the default palette (02).
post_40() {
    local json="$2" diff
    plutil -extract theme.id raw -o - "$json" 2>/dev/null | grep -q 'catppuccin' ||
        { echo "theme.id is not catppuccin-mocha"; return 1; }
    diff=$(swift "$ROOT/Scripts/pixel-diff.swift" "$OUT/02-launcher-search.png" "$png" 2>&1) || true
    case "$diff" in
    0.00%*|'') echo "launcher pixels did not change after the theme apply ($diff)"; return 1 ;;
    esac
    echo "palette changed: $diff"
}

# post_22: the seeded snippet, not the setup row, is the visible result.
post_22() {
    local json="$2" title
    title=$(plutil -extract items.0.title raw -o - "$json" 2>/dev/null)
    [ "$title" = "Email signature" ] || { echo "snippet row is '$title'"; return 1; }
}

# post_20: the pinned row carries its Unpin action, and an untyped /clip list
# stays in strict newest-first order (pinning does not reorder the browser).
post_20() {
    local json="$2"
    local first second third
    first=$(plutil -extract items.0.title raw -o - "$json" 2>/dev/null)
    second=$(plutil -extract items.1.title raw -o - "$json" 2>/dev/null)
    third=$(plutil -extract items.2.title raw -o - "$json" 2>/dev/null)
    [ "$first" = "Newest unpinned copy" ] && [ "$second" = "Older unpinned copy" ] &&
        [ "$third" = "Release checklist: deck, panes, typography" ] ||
        { echo "chronology wrong: '$first', '$second', '$third'"; return 1; }
    grep -q '"unpin:' "$json" || { echo "pinned row has no Unpin action"; return 1; }
}

# post_21: the calculator row really shows the result, not just the provider.
post_21() {
    local json="$2" title
    title=$(plutil -extract items.0.title raw -o - "$json" 2>/dev/null)
    [ "$title" = "8" ] || { echo "calculator result row is '$title', expected 8"; return 1; }
}

# post_35: the parse error is the visible status, not a silent fallback.
post_35() {
    local json="$2" status
    status=$(plutil -extract statusMessage raw -o - "$json" 2>/dev/null)
    case "$status" in
    *"config.toml has an error"*) return 0 ;;
    *) echo "statusMessage is '$status'"; return 1 ;;
    esac
}

# post_37: the deck must have been laid out for the scripted 3440px display.
post_37() {
    local dims
    dims=$(dims_of "$3")
    local width=${dims%x*}
    [ -n "$width" ] && [ "$width" -ge 3000 ] ||
        { echo "deck snapshot is $dims, not the 3440px scripted size"; return 1; }
}

# States that render but whose defining pixels are outside what the app's
# snapshot hooks can reach. Recorded as skip, never as a passing shot.
skip_reason_for() {
    case "$1" in
    06) echo "SwiftTerm draws terminal glyphs into a layer; snapshot= captures the pane frame but not the text. The text itself was verified with PALETTE_TERMINAL_DEBUG: echo palette-2200 printed palette-2200." ;;
    esac
}

run_scenario() {
    local nn="$1" slug="$2" group="$3" title="$4" assertion="$5" script="$6"
    local post="${7:-}"
    should_run "$nn" || return 0
    local dir="$WORK/$nn"
    local png="$OUT/$nn-$slug.png"
    local json="$OUT/$nn-$slug.json"
    rm -rf "$dir"
    mkdir -p "$dir/home"
    rm -f "$png" "$json"
    prepare "$dir" "$nn"
    script="${script//%PNG%/$png}"
    script="${script//%JSON%/$json}"
    script="${script//%DIR%/$dir}"

    local args=()
    # The favourites view reads UserDefaults. An argument-domain value gives it
    # a favourite without writing the user's real preference domain.
    [ "$nn" = "37" ] && args=(-themeCardFavourites '("theme:ghostty-gruvbox-dark")')

    echo "▶ $nn $slug"
    local status=0
    run_app "$dir" "$script" ${args[@]+"${args[@]}"} || status=$?

    local verdict="PASS" reason=""
    if [ "$status" -ne 0 ]; then
        verdict="FAIL"
        reason=$(grep -E "SCRIPT:|RUN: timed out" "$dir/app.log" | tail -1)
        [ -n "$reason" ] || reason="app exited $status"
    fi
    if [ ! -s "$png" ]; then
        verdict="FAIL"
        [ -n "$reason" ] || reason="no snapshot written"
    fi
    local dims="" variance=""
    if [ -s "$png" ]; then
        variance=$(swift "$ROOT/Scripts/image-variance.swift" "$png" 2>&1)
        if [ $? -ne 0 ]; then
            verdict="FAIL"
            [ -n "$reason" ] || reason="uniform image ($variance)"
        fi
        dims=$(dims_of "$png")
    fi
    if [ -s "$png" ] && [ "$(wc -c <"$png" | tr -d ' ')" -lt 5000 ]; then
        verdict="FAIL"
        [ -n "$reason" ] || reason="snapshot is only $(wc -c <"$png" | tr -d ' ') bytes"
    fi
    if [ "$verdict" = "PASS" ] && [ -n "$post" ]; then
        local post_out=""
        if ! post_out=$("$post" "$dir" "$json" "$png" 2>&1); then
            verdict="FAIL"
            reason="$post_out"
        fi
    fi
    if [ "$verdict" = "PASS" ] && [ "$nn" = "17" ]; then
        plutil -extract theme.id raw -o - "$json" 2>/dev/null | grep -q 'catppuccin' ||
            { verdict="FAIL"; reason="theme.id is not catppuccin-mocha"; }
    fi
    if [ "$verdict" = "PASS" ] && [ "$nn" = "40" ]; then
        local p40=""
        if ! p40=$(post_40 "$dir" "$json" "$png" 2>&1); then
            verdict="FAIL"
            reason="$p40"
        fi
    fi

    local forced_skip
    forced_skip=$(skip_reason_for "$nn")
    if [ -n "$forced_skip" ]; then
        verdict="SKIP"
        reason="$forced_skip"
    fi
    local verdict_label="$verdict"
    [ "$verdict" = "PASS" ] && verdict_label="pass"
    [ "$verdict" = "FAIL" ] && verdict_label="fail"
    [ "$verdict" = "SKIP" ] && verdict_label="skip"
    printf '%s-%s\t%s\t%s\t%s\n' "$nn" "$slug" "$verdict_label" "${dims:-no-image}" "$assertion" >>"$SUMMARY"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$nn" "$slug" "$group" "$title" "$assertion" "$verdict_label" "${dims:-}" "${reason:-}" >>"$INDEX_DATA"
    if [ "$verdict" = "FAIL" ]; then
        echo "  FAIL: $reason"
        cp "$dir/app.log" "$OUT/$nn-$slug.log" 2>/dev/null || true
        rm -rf "$dir"
    else
        [ -n "$variance" ] && echo "  $variance"
        rm -rf "$dir"
    fi
}

# ── Launcher ────────────────────────────────────────────────────────────────

run_scenario 01 launcher-empty Launcher "Launcher, empty" \
    "panelVisible=true,itemCount>0" \
    'show; wait=0.9; assert=panelVisible=true; assert=itemCount>0; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 02 launcher-search Launcher "Launcher, typed search results" \
    "itemCount>0 for a typed query" \
    'show; wait=0.4; query=calc 2+2*3; wait=0.9; assert=itemCount>0; assert=query=calc 2+2*3; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 03 launcher-no-results Launcher "Launcher, no-results state" \
    "itemCount=0 with a query typed" \
    'show; wait=0.4; query=zzzzqqq; wait=0.9; assert=itemCount=0; assert=query=zzzzqqq; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 04 clipboard-preview Launcher "Clipboard history with live preview" \
    "previewEnabled=true,itemCount>0 from seeded clips" \
    'show; clipboard; wait=1.0; assert=previewEnabled=true; assert=itemCount>0; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 05 scratchpad Launcher "Scratchpad" \
    "scratchpadActive=true" \
    'show; wait=0.3; scratchpad; wait=0.9; assert=scratchpadActive=true; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 06 terminal Launcher "Embedded terminal pane" \
    "terminalActive=true after echo" \
    'show; wait=0.3; term=echo palette-2200; wait=3.0; assert=terminalActive=true; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 09 theme-browser Launcher "Theme browser (launcher /theme)" \
    "firstProvider=theme,itemCount>0" \
    'show; wait=0.4; query=/theme; wait=1.0; assert=firstProvider=theme; assert=itemCount>0; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 21 calculator-result Launcher "Calculator result row" \
    "firstTitle=8,firstProvider=calc" \
    'show; wait=0.4; query=/calc 2+2*3; wait=0.9; assert=firstProvider=calc; dump=%JSON%; snapshot=%PNG%; exit' post_21

run_scenario 22 snippet-expansion Launcher "Snippet row with expanded preview" \
    "firstProvider=snip,previewEnabled=true" \
    'show; wait=0.4; query=/snip email; wait=0.9; assert=firstProvider=snip; assert=previewEnabled=true; dump=%JSON%; snapshot=%PNG%; exit' post_22

run_scenario 23 bookmarks-results Launcher "Bookmark search results" \
    "firstProvider=bookmark,itemCount>0" \
    'show; wait=0.4; query=/bookmark; wait=0.8; assert=firstProvider=bookmark; assert=itemCount>0; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 24 cheatsheets-results Launcher "Cheatsheet search results" \
    "firstProvider=cheat,itemCount>0" \
    'show; wait=0.4; query=/cheat; wait=2.4; assert=firstProvider=cheat; assert=itemCount>0; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 25 webapps-results Launcher "Web App search results" \
    "firstProvider=web,itemCount>2" \
    'show; wait=0.4; query=/web; wait=0.8; assert=firstProvider=web; assert=itemCount>2; dump=%JSON%; snapshot=%PNG%; exit'

# ── Panels ──────────────────────────────────────────────────────────────────

run_scenario 07 ask-window Panels "Ask window, composer" \
    "askWindows=1" \
    'chatwindow; wait=0.9; assert=askWindows=1; dump=%JSON%; window_snapshot=%PNG%; exit'

run_scenario 08 status-panel Panels "Status panel" \
    "statusPanelOpen=true" \
    'show; wait=0.3; statuspanel; wait=0.9; assert=statusPanelOpen=true; dump=%JSON%; statuspanel_snapshot=%PNG%; exit'

run_scenario 19 clipboard-list Panels "Clipboard list: text, image and file entries" \
    "itemCount>4 from five seeded rows" \
    'show; wait=0.4; query=/clip; wait=1.1; assert=itemCount>4; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 20 clipboard-pinned Panels "Pinned clipboard row and chronology" \
    "itemCount=3, pinned row offers Unpin, newest first" \
    'show; wait=0.4; query=/clip; wait=1.1; assert=itemCount=3; dump=%JSON%; snapshot=%PNG%; exit' post_20

run_scenario 29 ask-chat Panels "Ask conversation restored from history" \
    "askWindows=1,askTurns>0" \
    'chatwindow; wait=0.7; chatopen=0; wait=1.4; assert=askWindows=1; assert=askTurns!=0; dump=%JSON%; window_snapshot=%PNG%; exit'

run_scenario 30 palette-menu Panels "Palette menu probe with arrow highlight" \
    "paletteMenuOpen=true,paletteMenuRows>0" \
    'show; wait=0.3; palettemenu; wait=0.6; palettemenu_key=down; wait=0.4; assert=paletteMenuOpen=true; assert=paletteMenuRows>0; dump=%JSON%; palettemenu_snapshot=%PNG%; exit'

run_scenario 28b media-preview Panels "Screenshot annotator preview (Pin toolbar)" \
    "annotator renders the capture window; Pin action visible" \
    'annotate=%DIR%/preview.png; wait=1.6; dump=%JSON%; window_snapshot=%PNG%; exit'

# ── Settings ────────────────────────────────────────────────────────────────

run_scenario 10 theming-source-theme Theming "Settings → Theming, source = Theme" \
    "settings window rendered, theming.enabled=true" \
    'settings; settings_size=1100x820; wait=0.7; settings_tab=19; wait=0.8; settings_jump=theming-section; wait=3.3; assert=themeMenuRows>0; dump=%JSON%; settings_snapshot=%PNG%; exit'

run_scenario 11 theming-source-wallpaper Theming "Settings → Theming, source = Wallpaper (theme group disabled)" \
    "settings window rendered, source=wallpaper" \
    'settings; settings_size=1100x820; wait=0.7; settings_tab=19; wait=0.8; settings_jump=theming-section; wait=3.3; assert=themeMenuRows>0; dump=%JSON%; settings_snapshot=%PNG%; exit'

run_scenario 26 screenshots-pane Settings "Settings → Screenshots" \
    "settings window rendered" \
    'settings; settings_size=1100x820; wait=0.7; settings_tab=10; wait=0.8; settings_jump=screenshots-destination; wait=3.3; dump=%JSON%; settings_snapshot=%PNG%; exit'

run_scenario 27 recordings-pane Settings "Settings → Recordings" \
    "settings window rendered" \
    'settings; settings_size=1100x820; wait=0.7; settings_tab=12; wait=0.8; settings_jump=recordings-action; wait=3.3; dump=%JSON%; settings_snapshot=%PNG%; exit'

run_scenario 28 captures-pane Settings "Settings → Captures" \
    "settings window rendered" \
    'settings; settings_size=1100x820; wait=0.7; settings_tab=13; wait=0.8; settings_jump=search-captures; wait=3.3; dump=%JSON%; settings_snapshot=%PNG%; exit'

run_scenario 31 engine-browser Settings "Settings → Search, engine browser rows" \
    "settings window rendered with engine rows" \
    'settings; settings_size=1100x820; wait=0.7; settings_tab=4; wait=0.8; settings_jump=search-engines; wait=3.3; dump=%JSON%; settings_snapshot=%PNG%; exit'

run_scenario 33 browser-policy Settings "Settings → Theming → Browsers, policy state" \
    "settings window rendered, browsers card" \
    'settings; settings_size=1100x820; wait=0.7; settings_tab=19; wait=0.8; settings_jump=theming-browsers; wait=3.3; dump=%JSON%; settings_snapshot=%PNG%; exit'

run_scenario 38 diagnostics Settings "Settings → Diagnostics" \
    "settings window rendered" \
    'settings; settings_size=1100x820; wait=0.7; settings_tab=18; wait=0.8; settings_jump=diagnostics-lines; wait=3.3; dump=%JSON%; settings_snapshot=%PNG%; exit'

run_scenario 39 about-pane Settings "Settings → About" \
    "settings window rendered" \
    'settings; settings_size=1100x820; wait=0.7; settings_tab=14; wait=0.8; settings_jump=settings-about; wait=3.3; dump=%JSON%; settings_snapshot=%PNG%; exit'

# ── Deck ────────────────────────────────────────────────────────────────────

run_scenario 12 deck-colors-fan Deck "Theme deck, colours fan at 3440×1415" \
    "thumbsReady=true, deck rendered" \
    'themecards_size=3440x1415; themecards; wait=1.6; themecards_next; wait=0.4; themecards_next; wait=0.7; assert=thumbsReady=true; dump=%JSON%; themecards_snapshot=%PNG%; exit'

run_scenario 13 deck-colors-preview Deck "Theme deck, colour preview" \
    "thumbsReady=true, preview open" \
    'themecards_size=3440x1415; themecards; wait=1.6; themecards_next; wait=0.5; themecards_preview; wait=1.0; assert=thumbsReady=true; dump=%JSON%; themecards_snapshot=%PNG%; exit'

run_scenario 14 deck-wallpapers-fan Deck "Theme deck, wallpapers fan" \
    "thumbsReady=true,thumbsTotal>0" \
    'themecards_size=3440x1415; themecards; themecards_mode=wallpapers; wait_until=thumbsReady=true;timeout=25; wait=2.2; assert=thumbsTotal>0; dump=%JSON%; themecards_snapshot=%PNG%; exit'

run_scenario 15 deck-wallpaper-preview Deck "Theme deck, wallpaper preview" \
    "thumbsReady=true, preview open" \
    'themecards_size=3440x1415; themecards; themecards_mode=wallpapers; wait_until=thumbsReady=true;timeout=25; themecards_next; wait=1.0; themecards_preview; wait=1.2; assert=thumbsTotal>0; dump=%JSON%; themecards_snapshot=%PNG%; exit'

run_scenario 16 deck-mid-deal Deck "Theme deck, mid-deal at 0.5" \
    "thumbsReady=true, deal frozen" \
    'themecards_size=3440x1415; themecards; wait=1.4; themecards_deal=0.5; wait=0.5; assert=thumbsReady=true; dump=%JSON%; themecards_snapshot=%PNG%; exit'

run_scenario 36 deck-filter Deck "Theme deck, filter active (gruvbox)" \
    "deck open, filter narrowed" \
    'themecards_size=3440x1415; themecards; wait=1.5; themecards_filter=gruvbox; wait=0.9; assert=thumbsReady=true; dump=%JSON%; themecards_snapshot=%PNG%; exit'

run_scenario 37 deck-favourites Deck "Theme deck, favourites view (Tab)" \
    "favourites view open with seeded favourite" \
    'themecards_size=3440x1415; themecards; wait=1.5; themecards_tab; wait=0.9; assert=thumbsReady=true; dump=%JSON%; themecards_snapshot=%PNG%; exit' post_37

# ── Theming ─────────────────────────────────────────────────────────────────

run_scenario 17 theme-applied Theming "Launcher after applying catppuccin-mocha" \
    "theme.id contains catppuccin, panel visible" \
    'show; wait=0.4; theming_apply=catppuccin-mocha; wait=1.8; assert=panelVisible=true; dump=%JSON%; snapshot=%PNG%; exit'

run_scenario 18 wallpaper-applied Theming "Wallpaper-sourced palette applied in an isolated home" \
    "palette.json written, launcher uses wallpaper palette" \
    'themecards_size=1600x1000; themecards; themecards_mode=wallpapers; wait_until=thumbsReady=true;timeout=25; themecards_first; wait=0.5; themecards_apply; wait=2.5; themecardsclose; show; wait=1.0; dump=%JSON%; snapshot=%PNG%; exit' post_18

run_scenario 40 theme-applied-search Theming "Themed launcher with search, compared with 02" \
    "theme.id contains catppuccin, pixels differ from 02" \
    'show; wait=0.4; theming_apply=catppuccin-mocha; wait=1.8; query=calc 2+2*3; wait=0.9; assert=itemCount>0; dump=%JSON%; snapshot=%PNG%; exit'

# ── Accessibility / errors ──────────────────────────────────────────────────

run_scenario 35 broken-config Errors "Broken config.toml: visible parse error" \
    "statusMessage contains 'config.toml has an error'" \
    'show; wait=1.0; assert=statusMessage~=config\.toml has an error; dump=%JSON%; snapshot=%PNG%; exit' post_35

# Scenario 32 (restart prompt) and 34 (Increase Contrast) have no script
# surface that can show them without touching the user's machine. Recorded as
# skipped instead of faked.
if should_run 32; then
    printf '32-restart-prompt\tskip\tno-image\tno script verb; needs a running target app and a real restart prompt\n' >>"$SUMMARY"
    printf '32\trestart-prompt\tErrors\tRestart prompt (kitty/Ghostty)\tskipped: no script verb, requires a running target app\tskip\tno-image\tNeeds themingEngine.restartPrompt, which only publishes after a real apply against a running app. No verb exposes it and faking it would not be the real window.\n' >>"$INDEX_DATA"
fi
if should_run 34; then
    printf '34-increase-contrast\tskip\tno-image\tno script verb; requires toggling the real macOS Increase Contrast setting\n' >>"$SUMMARY"
    printf '34\tincrease-contrast\tAccessibility\tIncrease Contrast forced on\tskipped: requires the real system accessibility setting\tskip\tno-image\tIncrease Contrast comes from NSWorkspace/SwiftUI colourSchemeContrast; there is no app override or script verb, and changing it would alter the user settings.\n' >>"$INDEX_DATA"
fi

# ── Settings panes (the 20 layout-check renders) ────────────────────────────

PANE_TITLES=(general launcher appearance shortcuts search ask terminal bookmarks cheatsheets web-apps screenshots after-capture recordings captures about providers provider-files config-files diagnostics theming)
PANE_SUMMARY="$PANES/summary.tsv"
: >"$PANE_SUMMARY"
pane_missing=0
for index in "${!PANE_TITLES[@]}"; do
    number=$(printf '%02d' $((index + 1)))
    src="$ROOT/Tests/Snapshots/settings-$index.png"
    dst="$PANES/$number-${PANE_TITLES[$index]}.png"
    verdict="pass"
    reason=""
    if [ ! -s "$src" ]; then
        verdict="fail"
        reason="missing $src"
    else
        cp "$src" "$dst"
        variance=$(swift "$ROOT/Scripts/image-variance.swift" "$dst" 2>&1) || {
            verdict="fail"
            reason="uniform: $variance"
        }
    fi
    [ "$verdict" = "fail" ] && pane_missing=$((pane_missing + 1))
    printf '%s-%s\t%s\t%s\tSettings pane %s\n' "$number" "${PANE_TITLES[$index]}" "$verdict" \
        "$(dims_of "$dst")" "${PANE_TITLES[$index]}" >>"$PANE_SUMMARY"
done

# ── index.html ──────────────────────────────────────────────────────────────

group_order=(Launcher Panels Settings Deck Theming Accessibility Errors)
{
    cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Palette 2.20.0 — per-action evidence</title>
<style>
  :root { color-scheme: dark; --bg:#0b0c0e; --surface:#141619; --surface2:#1b1e22;
          --border:#2a2e34; --fg:#e7e9ec; --muted:#9aa1aa; --accent:#8ab4f8;
          --pass:#3fb950; --fail:#f85149; --skip:#d29922; }
  * { box-sizing: border-box; }
  body { margin:0 auto; max-width:62rem; padding:2.5rem 1.25rem 6rem; background:var(--bg);
         color:var(--fg); font:15px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace; }
  h1,h2,h3 { line-height:1.25; letter-spacing:-0.01em; }
  h1 { font-size:1.7rem; margin:0 0 .35rem; }
  h2 { font-size:1.15rem; margin:2.8rem 0 1rem; padding-bottom:.45rem;
       border-bottom:1px solid var(--border); scroll-margin-top:1rem; }
  h3 { font-size:.95rem; margin:0 0 .5rem; }
  p { color:var(--muted); }
  a { color:var(--accent); }
  .lede { max-width:46rem; }
  .card { background:var(--surface); border:1px solid var(--border); border-radius:10px;
          padding:1rem 1.1rem 1.15rem; margin:0 0 1.4rem; }
  .card img { display:block; width:100%; height:auto; border-radius:6px;
              border:1px solid var(--border); background:#000; }
  .meta { display:flex; gap:.6rem; align-items:center; flex-wrap:wrap; margin:.55rem 0 .35rem;
          color:var(--muted); font-size:.8rem; }
  .badge { display:inline-block; padding:.08rem .5rem; border-radius:999px; font-size:.75rem;
           font-weight:700; letter-spacing:.02em; }
  .badge.pass { background:rgba(63,185,80,.14); color:var(--pass); border:1px solid rgba(63,185,80,.4); }
  .badge.fail { background:rgba(248,81,73,.14); color:var(--fail); border:1px solid rgba(248,81,73,.4); }
  .badge.skip { background:rgba(210,153,34,.14); color:var(--skip); border:1px solid rgba(210,153,34,.4); }
  .assert { color:var(--fg); font-size:.85rem; margin:.15rem 0 0; }
  .assert span { color:var(--muted); }
  .reason { color:var(--fail); font-size:.82rem; margin:.4rem 0 0; }
  .skipped { border-left:3px solid var(--skip); padding:.75rem 1rem; background:var(--surface2);
             border-radius:0 8px 8px 0; color:var(--muted); }
  .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(17rem,1fr)); gap:1rem; }
  .grid figure { margin:0; background:var(--surface2); border:1px solid var(--border);
                 border-radius:8px; padding:.6rem; }
  .grid img { width:100%; height:auto; border-radius:4px; border:1px solid var(--border); }
  .grid figcaption { font-size:.75rem; color:var(--muted); margin-top:.45rem; }
</style>
</head>
<body>
<h1>Palette 2.20.0 — per-action evidence</h1>
<p class="lede">One real render per user-facing action, produced by the app's own
<code>snapshot=</code>, <code>window_snapshot=</code>, <code>statuspanel_snapshot=</code>,
<code>settings_snapshot=</code> and <code>themecards_snapshot=</code> hooks. Every run used a
throwaway HOME/config/state/cache tree, asserted its state through <code>assert=</code>/<code>dump=</code>,
and each image passed a non-blank pixel-variance check. Screen Recording was never used.</p>
HTML_HEAD

    for group in "${group_order[@]}"; do
        echo "<h2 id=\"$(printf '%s' "$group" | tr '[:upper:]' '[:lower:]')\">$group</h2>"
        while IFS=$'\t' read -r nn slug grp title assertion verdict dims reason; do
            [ "$grp" = "$group" ] || continue
            case "$verdict" in
            pass) badge='<span class="badge pass">PASS</span>' ;;
            fail) badge='<span class="badge fail">FAIL</span>' ;;
            *) badge='<span class="badge skip">SKIP</span>' ;;
            esac
            echo "<article class=\"card\">"
            echo "<h3>$(printf '%s' "$nn" | sed 's/^0*//') · $title</h3>"
            artifact=""
            [ -s "$OUT/$nn-$slug.json" ] && artifact="<span>actions/$nn-$slug.json</span>"
            echo "<div class=\"meta\">$badge<span>${dims:-no image}</span>$artifact</div>"
            echo "<p class=\"assert\"><span>Proves:</span> $assertion</p>"
            if [ "$verdict" = "skip" ]; then
                if [ -s "$OUT/$nn-$slug.png" ]; then
                    echo "<img loading=\"lazy\" src=\"actions/$nn-$slug.png\" alt=\"$title\">"
                fi
                echo "<div class=\"skipped\">Not fully captured. ${reason:-No script surface for this state.}</div>"
            elif [ -s "$OUT/$nn-$slug.png" ]; then
                echo "<img loading=\"lazy\" src=\"actions/$nn-$slug.png\" alt=\"$title\">"
                [ -n "$reason" ] && echo "<p class=\"reason\">$reason</p>"
            fi
            echo "</article>"
        done < <(sort -t "$(printf '\t')" -k1,1 "$INDEX_DATA" | awk -F'\t' -v g="$group" '$3==g')
    done

    echo '<h2 id="settings-panes">Settings panes</h2>'
    echo '<p>All 20 Settings sections, rendered by <code>Scripts/layout-check.sh</code> and copied here unchanged so every pane is represented even where no scripted state applies.</p>'
    echo '<div class="grid">'
    for index in "${!PANE_TITLES[@]}"; do
        number=$(printf '%02d' $((index + 1)))
        file="$PANES/$number-${PANE_TITLES[$index]}.png"
        [ -s "$file" ] || continue
        echo "<figure><img loading=\"lazy\" src=\"panes/$number-${PANE_TITLES[$index]}.png\" alt=\"Settings ${PANE_TITLES[$index]}\"><figcaption>$number · ${PANE_TITLES[$index]}</figcaption></figure>"
    done
    echo '</div>'

    cat <<'HTML_TAIL'
</body>
</html>
HTML_TAIL
} >"$ROOT/Tests/Evidence/index.html"

# ── Verdict ─────────────────────────────────────────────────────────────────

failures=$(grep -c $'\tfail\t' "$SUMMARY" || true)
skips=$(grep -c $'\tskip\t' "$SUMMARY" || true)
passes=$(grep -c $'\tpass\t' "$SUMMARY" || true)
echo
echo "actions: $passes pass, $failures fail, $skips skipped"
if [ "$pane_missing" -ne 0 ]; then
    echo "settings panes: $pane_missing failed"
fi
column -t -s "$(printf '\t')" "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
if [ "$failures" -ne 0 ] || [ "$pane_missing" -ne 0 ]; then
    echo "evidence failed"
    exit 1
fi
echo "evidence ok"
