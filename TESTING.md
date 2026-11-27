# Testing

## Automated

```sh
make test          # swift test
```

The suite is pure Swift and does not require a running app. Path and external
provider tests skip themselves when `fd`, `fzf`, or `python3` is missing.

| File | What is covered |
|---|---|
| `CoreTests` | query parsing and completion, ranking, frecency math, calculator, scope globs, config defaults, theme composition, app lookup |
| `StorageTests` | SQLite migrations, frecency round-trip, metadata, clipboard dedupe/cap |
| `ClipboardCaptureTests` | capture policy (concealed wins, ignored apps), `ignored_apps` config round-trip, copy-only paste targets |
| `ClipboardSearchIndexTests` | the clipboard search snapshot: rebuild on history change, pinned ranking, folded scoring, per-keystroke timing at 5k entries |
| `PathsEngineTests` | fd enumeration, excludes, fzf ranking, weird filenames |
| `ManifestTests` | provider manifest parsing and validation diagnostics |
| `AskTests` | Ask config round-trip without secrets, free-first model order, endpoint scoping, response/error parsing, quota fallback, invalid-key endpoint skipping, Settings model precedence, streaming, saved chats and sources, markdown blocks/tables/images, web-search parsing and the untrusted system note |
| `KeepAwakeTests` | keep-awake start/stop, timed expiry, provider rows/actions, clamshell toggle independence, clamshell flag cleanup, AC/battery guard transitions |
| `ExternalProviderTests` | NDJSON round-trip against the hello example |
| `PerformanceTests` | hard budgets for theme menu open, warm catalog, 5k clipboard snapshot, cached `/neo`, and theme apply file generation |
| `ThemeApplyIntegrationTests` | Apply/uncheck/Revert against a sandbox HOME with real kitty, Ghostty, zellij, Neovim, fish and Starship configs |
| `ThemeCardsTests`, `ThemeFanTests` | deck order (wallpaper first), filtering, favourites, fan geometry and hit-testing |
| `ThemeFormatTests`, `ThemeIDTests` | per-format generated syntax (Lua/KDL/TOML/XML headers), display-name → id resolution and migration |
| `ThemingIncludesTests`, `ThemingReloadTests`, `ThemingTests` | marker blocks per format, created-file removal, backup/Revert, per-target reload truth, palette extraction |
| `AnnotationInteractionTests` | pointer hit-test, delete selected, one-step move undo, crop clamping |

## Provider conformance harness

`Tests/PaletteTests/ExternalProviderTests.swift` starts
`Resources/Examples/hello/main.py` with `python3`, sends `init` and `query`, and
asserts:

- a `results` message with at least one item for a matching query;
- the item carries the provider id and mapped metadata;
- `activate` produces a `notify`;
- `shutdown` exits the process.

Use it as the template for third-party providers: point `command` at your
executable and copy the assertions.

## Unattended UI harness

For an unattended Mac (or CI), drive the real app with `PALETTE_SCRIPT`. Steps
run after launch and are separated by `;`:

```sh
PALETTE_SCRIPT='show; query=Safari; wait=1.2; actions; \
  snapshot=/tmp/safari-actions.png; exit' \
  build/Palette.app/Contents/MacOS/Palette
```

Supported steps: `show`, `hide`, `toggle`, `actions`, `settings`, `exit`,
`query=<text>`, `rail=<id>`, `railfocus`, `focus=<search|list|rail|strip>`,
`scratchlist`, `snapshot=<path>`, `shot`,
`settings_tab=<index>`,
`settings_size=<w>x<h>`, `settings_edit=<field>=<value>`,
`settings_clear_search`, `theming_apply=<theme>`, `awake=<seconds>`,
`settings_snapshot=<path>`,
`window_snapshot=<path>`, `statuspanel`, `statuspanelclose`,
`statuspanel_snapshot=<path>`, `askwindow=<question>`, `chatwindow`,
`chatopen=<index>`, `ask_cancel`, `asktoggle`, `askclose`,
`palette_menu=<probe|picker|engine_browser>`, `palettemenu_probe`,
`wait=<seconds>`, `dump=<path>`, `assert=<cond>`,
`wait_until=<cond>[;timeout=<s>]`, and
`key=<token>` where token is `up`, `down`, `enter`, `esc`, `tab`, `space`,
`comma`, `k`, `r`, `w`, `1`…`9`, optionally prefixed with `cmd+`, `opt+`, or
`shift+` (for example `key=cmd+k`). `snapshot` writes the panel content without
screen-recording permission, so it works on a locked display.

Theme cards have their own steps: `themecards` opens the fanned gallery,
`themecards_next` / `_prev` / `_first` / `_last` move, `themecards_filter=<text>`
types into the filter, `themecards_tab` toggles favourites, `themecards_favourite`
marks the front card, `themecards_apply` applies it without Return, and
`themecards_snapshot=<path>` / `themecardsclose` capture and close it.
`Scripts/theme-cards-snapshot.sh` uses those steps to render
`Tests/Snapshots/theme-cards-fan.png` headlessly, which is how the hand, the
dimming and the lifted card are checked without opening the app.

A scripted run never takes focus. Windows are ordered to the back of the normal
level, panels never become key, the app stays an accessory (no Dock icon), and a
resign-key auto-hide is ignored so clicking elsewhere cannot break a flow.
Typing and `key=` steps call the controller directly, so they need no key
window. The app logs `Script mode: … shown without activation` for every quiet
presentation, and `assert=appActive=false` proves it from inside the app.

Other hooks: `PALETTE_QUERY`, `PALETTE_SHOW_ON_LAUNCH`,
`PALETTE_SNAPSHOT`, `PALETTE_SNAPSHOT_DELAY`, `PALETTE_EXIT_AFTER_SNAPSHOT`,
and `PALETTE_ACTIONS`. `dump` also exposes the Ask window as `askWindows`,
`askStreaming`, `askTurns`, `askChats`, and `askBadge`.

Cross-app theming needs a home of its own, or a scripted apply would edit the
real kitty/Ghostty/fish configs. `PALETTE_HOME` moves every managed path into a
temp directory, and `PALETTE_KITTY` points the reload step at a fake binary:

```sh
PALETTE_HOME="$TMP/home" PALETTE_KITTY="$TMP/bin/kitty" \
PALETTE_STATE_DIR="$TMP/state" PALETTE_CACHE_DIR="$TMP/cache" \
PALETTE_SCRIPT="theming_apply=default-dark; wait=1; dump=$TMP/dump.json; exit" \
  build/Palette.app/Contents/MacOS/Palette
```

`dump` then carries a `theming` object with the apply status and one
`{id, title, state, note}` row per target, so a shell check can assert the
markers and the reload answers.

The harness calls the same `SearchController` keyboard path as the panel, but
it does not test Carbon hotkey delivery or real typing. Check those manually.

### What quiet script mode cannot reproduce

Script mode cannot enter a native menu-tracking loop, because it never opens a
native `NSMenu` and never activates the app. The custom, non-activating panels
replaced those menus for exactly that reason, and the flows drive them instead:
`statuspanel` opens the status-item panel, and
`palette_menu=<probe|picker|engine_browser>` opens a representative menu, a
`PaletteMenuPicker` menu, or the engine browser picker. While one is open the
dump exposes `paletteMenuOpen`, `paletteMenuRows`, `paletteMenuHighlight` and
`statusPanelOpen`, `statusPanelRows`, `statusPanelHighlight`. `palettemenu_probe`
stands in for a global hotkey callback and increments `paletteMenuProbe`; a
native tracking loop would block that callback until the menu closed.
`key=` routes Up/Down/Return/Esc to the open panel, so the flows assert the
highlight moves and Esc closes.

What remains human-only: the system app menu bar, Services, file panels,
first-run and TCC alerts, and confirming that a real Carbon hotkey still fires
while a panel is open. The theme cards gallery renders in script mode without
activation, but its steps drive the deck model directly: real arrow-key handling,
typing into the filter, click-to-deal and drag on a card, and the lift animation
are checked by eye (see `theme-cards-fan.png`). Script mode can also prove the
app stayed out of focus (`appActive=false`), but not that a real activation
(click, Dock, `open`) leaves the panel placed correctly. Those stay on the manual
checklist.

## E2E flows

```sh
make e2e           # Scripts/e2e.sh; builds build/Palette.app if it is missing
```

`Scripts/e2e.sh` runs one flow per launch. Each flow gets its own temp
`PALETTE_CONFIG_DIR`, `PALETTE_STATE_DIR` (SQLite database and logs),
`PALETTE_CACHE_DIR`, and `PALETTE_SUPPORT_DIR` (Ask key file and web-app
profiles), so the real `~/.config/palette` and `~/Library/Application Support`
stay untouched. It fails on a non-zero exit, a missing `SCRIPT OK` in the log,
a missing quiet-presentation log line, or a missing artifact, and it kills a
leftover Palette process before exiting:

| Flow | What it asserts |
|---|---|
| `empty-query-reset` | hiding and reshowing resets the query and selection to the first row |
| `screenshot-keeps-panel` | a capture leaves the panel visible |
| `universal-search` | an unprefixed query returns rows from the default global providers (`system`, `timer`, `awake`) |
| `launcher-tab` | the Launcher Settings tab renders, via `settings_snapshot=` |
| `ask-window-not-modal` | the Ask window opens while the scratchpad stays active |
| `ask-window-coexists` | the Ask window and the launcher are both visible |
| `cheatsheets` | a temp `[cheatsheets] folders` entry reaches `/cheat`, which returns rows from the `cheat` provider |
| `status-panel-interaction` | the status-item panel opens without activation, reports rows, and Esc closes it |
| `palette-menu-probe` | the menu holds its five fixed rows, a hotkey probe runs while it is open, Up cycles the highlight while skipping a separator and a disabled row, and Esc closes |
| `palette-menu-picker` | a `PaletteMenuPicker` menu builds four rows and Up/Down move between choices |
| `engine-browser-picker` | the web-search engine browser picker builds its rows, stays inactive, and moves the highlight |
| `theme-menu-lazy` | the 942-row theme browser reports the whole catalog but renders under 45 rows (`themeMenuRows`, `themeMenuRendered`) |
| `quit-intercepted` | with the panel open, a terminate request (⌘Q) hides the panel instead of quitting; reaching `dump`/`exit` proves the process survived |

The capture flow asserts panel visibility only: a real capture needs Screen
Recording TCC, which CI does not grant.

`make test`, `make e2e`, and `make layout-check` run under `taskpolicy -b` and
`nice -n 10`, and the scripts do the same for their internal builds and app
launches, so a run yields to whatever the user is doing. Timing-sensitive flows
use `wait_until=` instead of a fixed sleep for that reason.

`make debug-app` builds `build/Palette Debug.app` with its own bundle id and
isolated config, then launches it through LaunchServices so permission prompts
attribute to Palette Debug instead of the terminal. E2E still launches
`build/Palette.app` directly.

Three steps make a script verifiable: `dump=<path>` writes the observable
state as JSON, `assert=<condition>` records a failure when the condition is
false, and `wait_until=<condition>;timeout=<seconds>` polls until it holds
(5 s default). Any failure makes the process exit non-zero.

## Performance budgets

`PerformanceTests` fails with the measured value when a budget is crossed.
Thresholds are loose enough for a loaded laptop and far below the regression
they guard. The numbers below are from a 2026-11-26 run on the development Mac
(M-series, debug build, `swift test`):

| What | Threshold | Measured |
|---|---|---|
| Opening the 942-row theme menu (warm catalog, building the rows) | < 250 ms | 4.9 ms |
| `ThemeLoader.catalog` warm | < 400 ms | 21.8 ms |
| 5k-entry clipboard search snapshot rebuild | < 100 ms | 20.8 ms |
| Cached `/neo` open (empty query over a 20k-path snapshot) | < 200 ms | 50.9 ms; 101 ms at background QoS |
| Theme apply file generation (sandbox HOME, 7 files, no reloads) | < 300 ms | 10.1 ms |
| Theme browser first frame (942 rows in catalog) | renders < 45 rows | checked by `theme-menu-lazy` in e2e |

The last row is a UI-laziness assertion and lives in the e2e flow because
`PaletteTests` does not link the `PaletteApp` target that owns the view.

The fanned deck logs its catalogue build time (`Theme cards catalogue: … in …
ms`, 942 themes plus the wallpaper folder) but has no hard budget: its cost is
dominated by `ThemeLoader.catalog`, which the row above budgets. Card flips and
thumbnail loads are bounded by drawing only the cards near the selection.

`AnnotationInteractionTests` drives the editor model, not the window: hit-test
picking, delete-selected, one undo step per move, and crop clamping. The
corner-handle text resize added in 2.19.0 is not covered here yet; extend this
suite against the annotation model rather than the crop path.

## Layout check

Unit tests cannot see a clipped label or a squashed stepper. `make layout-check`
renders every Settings pane headlessly — all 20 of them — and compares each with
the reference in `Tests/Snapshots/`:

```sh
make layout-check                  # fail if any section drifts more than 2%
Scripts/layout-check.sh --record   # accept the current rendering
```

Snapshots are normalised to 900 px wide, so a different display scale does not
produce noise, and differences below a 6% channel delta are ignored. A focused
text field used to make the numbers wobble; the capture resigns first responder
before rendering. Run it after any change to `SettingsView`.

## Release integrity

`.github/workflows/release.yml` runs only on a `v*` tag that is on `main`, and
refuses a tag whose version disagrees with `Resources/Info.plist`. It runs the
tests, builds the zip, attests it with GitHub build provenance, writes
`SHA256SUMS`, and publishes the release as a draft first — immutable releases
cannot be edited afterwards, so the notes and assets are fixed while it is still
a draft, then the workflow flips it. A `smoke` job then downloads the published
assets back the way a user does, checks `shasum -a 256 -c SHA256SUMS`, unzips
the app, and runs `codesign -dv`. The same two commands verify a download
(`gh attestation verify Palette-<version>.zip --repo Myleshen/palette` and
`shasum -a 256 -c SHA256SUMS`), documented in README → Release integrity.

## Manual macOS checklist

Run `make run`, then work through this list. Items marked ⚠ require permissions.

**Lifecycle**
- [ ] Menu bar icon appears; no Dock icon.
- [ ] `⌥Space` toggles the panel; it appears on the active space and above
      full-screen apps.
- [ ] Typing immediately goes into the search field.
- [ ] `Esc` clears a non-empty query, then hides.
- [ ] Clicking outside hides the panel.

**Apps and calculator**
- [ ] Typing `saf` lists Safari; `⏎` opens it.
- [ ] `2+2*3` shows `8`; `⏎` copies it.
- [ ] `sqrt(81)` shows `9`.

**Paths**
- [ ] `/neo dot` lists directories under `~/dev`/`~/dot-files`.
- [ ] `/neof package` lists files; `⏎` opens in Neovide.
- [ ] Files named with spaces and newlines display and open correctly.
- [ ] `node_modules`, `.git`, `.build`, and `Library` are absent.
- [ ] Rename a folder while the panel is open; `⌘R` refreshes results.
- [ ] Remove `fd` from `PATH` temporarily; the install row appears.

**Clipboard**
- [ ] Copy text in another app; it appears under `/clip`.
- [ ] `⏎` copies it back; `⌘⏎` pastes into the previous app. ⚠
- [ ] Concealed clipboard writes (password managers) do not appear.
- [ ] Duplicate copies do not create duplicate rows.
- [ ] History survives a relaunch.

**Zellij**
- [ ] `/zj` lists existing sessions.
- [ ] `⏎` attaches in kitty, creating a window.
- [ ] `/zj newname` offers "Create session newname"; it starts in kitty.

**Bitwarden**
- [ ] Missing `bw` shows an install row.
- [ ] Logged out shows a login row that opens Terminal.
- [ ] Locked shows an unlock row with a secure prompt; wrong password reports
      an error, correct password reveals items.
- [ ] Searching returns logins; `⏎` copies the password and clears after 30 s.
- [ ] No secret appears in the log or process arguments.

**Ask chat**
- [ ] `⌘⌥A` opens the Ask window; with nothing streaming, `Esc` closes it.
- [ ] `⏎` sends and the answer streams in; **Stop** (or `Esc`) stops it and the
      partial answer stays with a **Stopped** note and **Retry**.
- [ ] Close the window mid-answer; the answer completes, the Dock badge appears,
      and reopening shows the answer and clears the badge.
- [ ] A markdown answer renders a table with aligned columns and a fenced code
      block whose **Copy** button copies the code.
- [ ] The globe (`⇧⌘G`) on for a current question produces a numbered
      **Sources** list; a source opens in the browser.
- [ ] The sidebar lists the chat; **New chat** (`⌘N`) starts an empty transcript,
      and delete asks for confirmation.
- [ ] Quit and relaunch: the chat is still listed and opens with its transcript,
      sources, and model.

**GitHub**
- [ ] `/gha` outside a repository shows **Pick a repository** (`SETUP`);
      `/gha owner/repo` lists runs.
- [ ] A run offers **View Log** in the panel, **Re-run Failed Jobs** behind a
      confirmation, and **Cancel Run** while it is not completed.
- [ ] `/ghn` lists notifications, shows `EMPTY` for a clear inbox, and shows
      `SCOPE` with **Run gh auth refresh** when the token lacks the scope.
- [ ] `/ghr` offers **Clone into …** for the first devx root, plus **Copy slug**.
- [ ] `/proj` with an empty query offers **Clone a repository…** and
      **New project…**; without `devx` the clone row reports the missing tool.

**Provider rail**
- [ ] The rail shows Everything first, then one row per provider; clicking a row
      opens its prefix and `Tab` / `⇧Tab` cycle the same rows.
- [ ] Opening `/clip` with a preview narrows the rail to icons and shows the
      preview pane.

**Settings**
- [ ] Changing a value updates `config.toml` and the footer reports **Saved**;
      there is no Save or Cancel.
- [ ] `⌘F` finds a pane or section; **Reset `<pane>`…** restores only that pane.
- [ ] Clearing an optional shortcut disables it; a duplicate shows an inline
      error and a footer count.

**Themes**
- [ ] Themes list under `/theme`; selecting one updates the UI immediately.
- [ ] Editing the theme file and pressing `⌘R` applies changes.
- [ ] Invalid TOML keeps the previous theme and logs a diagnostic.
- [ ] System dark/light switch updates the theme in `auto` mode.
- [ ] Reduce Transparency removes the blur.

**External providers**
- [ ] Copy `Resources/Examples/hello` to `~/.config/palette/providers/hello`;
      `/hello` answers queries.
- [ ] A broken provider surfaces a diagnostic without killing the app.
- [ ] Removing its directory and pressing `⌘R` unregisters it.

**Packaging**
- [ ] `make install` replaces `~/Applications/Palette.app`.
- [ ] The app launches after a fresh rebuild and reinstall.
- [ ] Palette installs itself as a login item on first launch from
      `/Applications` (or `~/Applications`); **Open Palette at login** in
      Settings → General turns it off and that choice sticks across reinstalls.
- [ ] Rebuild + reinstall preserves config, state, and clipboard history.

## Earlier verification

Per-release evidence lives in `CHANGELOG.md`; the dated checks below are kept as
history and carry the version they were run on. They are not a claim about the
current build.

- v2.2.2 install check (2026-11-03, macOS 27.2 arm64): `make app` and
  `make install` — release bundle assembled, ad-hoc signed,
  installed at `/Applications/Palette.app` (`dev.myleshen.palette`, LSUIElement,
  version 2.2.2). Launcher, clipboard, terminal, scratchpad, and Ask hotkeys
  registered without a conflict.
- Real OS input: the physical `⌥Space` hotkey opened the panel; typing `safari`
  ranked Safari first; `Esc` hid the panel; typing `2+2*3` and pressing `⏎`
  copied `8` and returned focus to the previous app; typing `/ne` and pressing
  `Tab` completed to `/neo `.
- Live harness runs (real `SearchController`, synthetic key events):
  `/calc` copied a result; clipboard capture picked up new text while running;
  `⌘K` action overlay worked; `/theme` switched live and restored
  Catppuccin Mocha; `/neof package.swift` resolved the right file; `/zj` listed
  sessions and offered a create row; selecting **Copy Bundle ID** on Safari put
  `com.apple.Safari` on the clipboard.
- v2.1.0 checks: the Settings search field jumps to matching sections; the
  global shortcut summary reports conflicts; `/scratch` lists notes with a
  **New Scratch Note** row; `/snip` loaded a TOML snippet and expanded
  `{{date}}`/`{{clipboard}}` in the preview; `/recent`, project, path, port,
  command, Git, and Finder-file rows
  expose **Open in Embedded Terminal**; clipboard file previews use QuickLook;
  app rows expose **Quit App** and **Move App to the Trash…**; physical
  `⌘⌥T`, `⌘⌥S`, and `⌘⌥A` opened terminal, scratchpad, and Ask respectively.
- v2.2.2 checks: Settings → General shows **Keep Awake** with **Keep Mac
  Awake** and **Clamshell Mode (Lid Closed)** ON/OFF toggles and live status.
  Turning Keep Mac Awake off leaves clamshell armed; turning clamshell off
  leaves an active timer alone. The clamshell toggle still opens the standard
  admin prompt, and cancelling it reverts the toggle to OFF.
- v2.2.1 checks: `/awake` shows Clamshell Mode as an **OFF** toggle with
  Turn On/Turn Off actions; cancelling the admin prompt leaves it OFF and
  creates no Palette power assertions. Tests prove clamshell can be armed while
  idle, survives starting a timer, can be turned off without stopping the
  timer, and that Stop clears both.
- v2.2.0 checks: `/awake` rendered the Keep Awake provider tab with the
  indefinite, 15-minute–8-hour, and clamshell rows; pressing `⏎` on the
  indefinite row created live `PreventUserIdleSystemSleep` and
  `PreventUserIdleDisplaySleep` assertions named Palette; the UI changed to
  `ACTIVE` and the footer reported keeping the Mac awake; the clamshell row
  opened the standard macOS administrator prompt and cancelling it removed the
  guard flag. `pmset -g assertions` showed both Palette assertions while the
  session was active.
- Hotkey regression (1.4.1): the previous build's `⌥Space` was dead whenever
  `⌥V` was registered, because a second `InstallEventHandler` replaced the first
  on the same Carbon target. After the shared-router fix, the brew-installed
  1.4.1 opened the launcher with `⌥Space` and the clipboard browser with `⌥V` in
  the same session, with Raycast running.
- v1.9.0 checks: `/clip transform:<id>` showed the full transform result in
  the preview pane; `/port` listed real listeners with process/PID/cwd;
  `/git` listed clean and dirty repositories; `/proj` listed `~/dev`
  projects; `/cmd` loaded a manifest command; Settings exposes typography and
  provider order/aliases.
- v1.8.0 checks (the `/ask` and `/askh` providers were removed in 2.15.0; Ask
  is a window now): `/ask` listed only the selected endpoint's models with free
  options first, selecting a model persisted it, and a mock OpenAI-compatible
  endpoint answered `/ask hello openai` in 0.35 s. The Q&A row included model,
  provider, latency, and tokens; `/askh` found it with fuzzy search and preview.
  The no-key path showed the setup row, and Settings Ask displayed only
  “Key saved in the macOS Keychain” after saving. Real Zen free quota returned
  429 and the expired Go key returned 401; both were reported without a crash.
  `swift test`: 81 tests, 0 failures.
- v1.7.13 checks: after opening the clipboard browser and pressing `Esc`, the
  snapshot showed the empty app list at normal width with no preview pane or
  “No preview available” placeholder.
- v1.7.12 checks: a real kitty TUI probe received `0x16` (Ctrl+V) from Palette's
  image-paste path; the previous fixed 220 ms delay failed the same probe, and
  the new activation polling delivered every run. Clipboard search found a
  needle stored behind 5,001 newer entries, proving the old 5,000-entry scan cap
  is gone. `SecureVaultCache.ttl` is 30 days and the session round-trip still
  survives expiry tests. `swift test`: 51 tests, 0 failures.
- v1.7.11 checks: `actmon` ranked Activity Monitor first in the app list;
  `/clip qbf` matched “The quick brown fox jumps over the lazy dog” from the
  clipboard, and a file named `Quarterly-Budget-Final.xlsx` matched `qbf` and
  `qbfinal`; `drgn` found Dragon, while `dragon` did not surface Red Triangle;
  Bitwarden matching accepted `tst`, `exmpl`, and `rd` against the test login.
  `swift test`: 49 tests, 0 failures.
- v1.7.10 checks: app grid mode is gone; the empty query renders the same
  single-list layout as every provider, and legacy `app_grid` keys are ignored.
  `swift test`: 43 tests, 0 failures.
- v1.7.9 checks: image paste logged `target=kitty modifiers=262144` (Ctrl+V) and
  `target=TextEdit modifiers=1048576` (Cmd+V); a Finder-launched build logged
  `Accessibility trusted=true` after the stable-signature grant. Settings
  Advanced showed the provider list, diagnostics, Export Backup, and Open Crash
  Log. `swift test`: 42 tests, 0 failures.
- v1.7.8 checks: a Finder-launched Palette reported Accessibility “Not granted”
  until the stale cdhash entry was removed; the new build exposes that state in
  Settings instead of silently only copying. `/clip` typed manually opened the
  preview pane, and clearing the query removed it. Fresh configs default to
  `search_style = "pill"`. The app is signed with
  `designated => identifier "dev.myleshen.palette"` and verifies with
  `codesign --verify --deep --strict`.
- v1.7.7 checks: provider tabs used two rows with 8 pt vertical chip padding
  and a 10 pt strip padding, all 15 providers visible; pill cards were fully
  opaque, so terminal text behind the launcher no longer ghosted through the
  list. The grid kept its rounded selection cell, actions stayed compact, and
  Settings retained its record buttons and padding.
- v1.7.6 checks: on a white desktop, pill mode showed only the search capsule
  and content card with no duplicate dark plates or outer window shadow. Classic
  still used its normal panel shadow. The fix disables `NSPanel.hasShadow` in
  floating-card mode and caps the per-card shadow at a subtle 6–8 pt radius.
  All 15 provider tabs wrapped into two complete rows (`BW Passwords`, `BW
  Notes`, `BW URLs`, `BW TOTP`, `BW Users`, …) with no clipped edge; the grid
  used a rounded selection cell; actions and clipboard modes kept the same
  two-card shell.
- v1.7.5 checks: opening Settings, pressing **Record** for the launcher hotkey,
  and pressing `⌘Space` changed the field to `cmd+space`; the previous version
  left it as `opt+space`. Saving wrote `hotkey = "cmd+space"`, the log showed
  `Hotkey registered: cmd+space`, and pressing `⌘Space` with Palette running
  opened the panel. The recorder’s event tap stops on capture and on focus loss.
- v1.7.4 checks: enabling `search_style = "pill"` through the real Settings
  picker and pressing Save produced a standalone search capsule plus a separate
  rounded content card with a visible desktop gap and independent shadows. The
  Classic fallback remained a single vibrancy panel. Search, tab, result,
  action, and footer content all stayed inside the content card, and the
  install/version screenshot was taken from the installed app.
- v1.7.3 checks: with Settings open, the launcher hotkey read `opt+space`.
  Closing Settings, editing `config.toml` to `hotkey = "cmd+space"`, and
  choosing the menu-bar **Reload Configuration** item logged
  `Hotkey registered: cmd+space`; reopening Settings showed `cmd+space`. The new
  **Record** button was pressed, `⌃⌥K` was typed, and the field changed to
  `opt+ctrl+k`; Save wrote `hotkey = "opt+ctrl+k"`, the log showed it registered,
  and the physical shortcut opened the panel. The record buttons and recorder
  values were also confirmed through the accessibility tree.
- v1.7.2 checks: with `search_style = "pill"` on Aetheria Pink, the panel
  background was opaque (no ghosted terminal text), the placeholder rendered
  fully, the search field and active tab/result/action used consistent soft
  accent capsules, unselected rows stayed flat, and the trailing tab faded
  instead of being cut. The Actions overlay and Classic mode were also
  snapshotted; Classic kept its original flat layout with the corrected
  placeholder.
- v1.7.1 checks: the status menu contained Open Palette, Reload, Launcher
  Position, Refresh Bitwarden Cache, Settings, Advanced, and Quit — no
  Clipboard Paste Permissions item. A fresh Palette process with the same test
  profile and **no** `BW_PASSWORD` logged “Bitwarden restored the cached
  session” and listed `Test` immediately; the sealed session file was 186 bytes
  at `0600`. Settings exposed the Siri-style pill picker; with
  `search_style = "pill"`, the search field, tab rail, selected result, badge,
  and panel corners all rendered as the rounded pill treatment, while Classic
  kept the original layout. Legacy `search_position = "bottom"` parsed as
  Center.
- v1.7.0 checks: the empty query showed only apps plus pinned items, with the
  pinned Youtube Music web app first and the rest alphabetical; switching
  `app_sort` to `frequent` put Safari first after seeding nine launches; the
  clipboard action order showed **Paste** first and Enter pasted
  `SECOND PASTE CHECK 98765` into TextEdit; the Settings Advanced tab exposed
  config/providers/themes/log while the footer kept only Cancel/Save; the
  menu-bar icon rendered as the flower palette and **Refresh Bitwarden Cache**
  logged a refresh; `/neo` filtered out a `[` entry and a broken symlink.
- Bitwarden cache: first unlock fetched the list in 2.8 s and wrote a 1 KB
  encrypted file plus a 32-byte `0600` key; a fresh process with the same
  profile unlocked and rendered `Test` with **zero** new `bw list` calls.
  `strings` on the cache found no vault text.
- v1.6.0 checks: `/bw` showed **Unlock Bitwarden — myleshennihonjin@gmail.com**
  and the prompt read “Master password for …”; after unlocking through the real
  secure prompt, `/bw`, `/bwn`, and `/bwu` shared one session with no repeated
  password prompt. A saved web app opened as
  `Helium --app=https://music.youtube.com --user-data-dir=…/Palette/WebApps/helium`,
  producing a standalone YouTube Music window with no tabs or address bar.
  Pressing the saved shortcut `ctrl+alt+m` launched the identical app-mode
  command instead of Safari. The 1.6.0 build offered a segmented
  Top/Center/Bottom control; the Bottom option was removed in 1.7.1 because it
  inverted the layout, and old `bottom` configs now open in the center.
- v1.5.1 physical round on the installed app (screen unlocked):
  `⌥Space` opened the launcher and `⌥V` opened the clipboard browser with the
  wide preview (the kind filter chips of that release were removed in 2.19.0;
  the preview remains); `Esc` dismissed them. In Settings, clicking the
  launcher recorder and pressing `⌃⌥K` changed the field to `opt+ctrl+k`; Save
  rewrote `config.toml`, the app logged `Hotkey registered: opt+ctrl+k`, and the
  recorded shortcut opened the panel. Recording `⌥Space` again restored it.
  Choosing Google Chrome in the web-app browser picker and pressing Save showed
  “Google Chrome is not installed…” and left `web_app_browser = "Helium"`
  unchanged. Setting the position picker to Center placed the panel at
  `515,336` (680×480) on a 1710×1112 screen; restoring Top returned it to the
  top. Opening `/sys config` launched Neovide with the config file and no nvim
  launch error after the PATH fix. Enter-to-hidden latency measured 84–105 ms
  (was 423 ms with the window animation).
- v1.5 checks: the empty query showed the Apps tab first; `Tab` switched to
  `/calc` and `⇧Tab` returns; typing `finder` ranked the CoreServices Finder
  first with web-search rows below; the 1.5 build's `search_position =
  "bottom"` put the tab strip and search field under the results (removed in
  1.7.1); `/clip` showed pinned-first
  Text/Images/Files groups with All/Text/Images/Files chips (both since removed:
  `/clip` is one chronological list) highlighting the matching filter, and
  `/clip image` showed only the 1024×1024 image with its
  preview; Settings showed recorded `opt+space` / `opt+v` and the position
  picker.
- v1.3 parity checks: empty query is a list by default; `/neo ~/dev/` showed
  direct folders before deeper files; a lone `/` returned apps without Zellij
  create rows; `rust async runtime` offered Google/DuckDuckGo/GitHub/YouTube;
  `/theme` listed Gruvbox Dark/Light and Aetheria Pink, and selecting Aetheria
  Pink repainted the panel live; `/emoji dragon` returned Dragon/Dragon Face
  without loose matches; `/web figma.com` added an app with the real Figma
  favicon; Settings opened and saving wrote `config.toml` and reloaded.
- Bitwarden (test profile in `BITWARDENCLI_APPDATA_DIR`, credentials read from
  `BITWARDEN_TEST_USER_PASS`): the GUI app unlocked with `BW_PASSWORD` and
  listed `Test`; `/bwn` listed and copied `Test note` (“test note, success if
  you can read it”); `/bwu` copied the username `test`. A second, logged-out
  profile went through the in-app login row with `BW_EMAIL`/`BW_PASSWORD`,
  reached the vault, and left `bw status` authenticated as the test user. After
  copying a note, the pasteboard held it while the clipboard-history table had
  zero matching rows, proving vault values bypass history. The user’s normal
  vault profile was not modified, and no password is stored by Palette.
- Physical `⌥V` on the installed app opened the clipboard browser at `/clip`
  with the wide preview pane, grouped rows, and live text preview; `Esc`
  dismissed it and `⌥Space` still opened the normal launcher.
- Emoji: `/emoji` listed the full catalog with Apple names and Unicode group
  badges; `/emoji star` ranked Star first, followed by Starry Eyes, Star of
  David, and other literal matches.
- Clipboard browser (`⌥V` via the harness clipboard step): text, a 1360×928
  screenshot, and a two-file Finder selection were captured; the build of that
  era grouped them under Text/Images/Files (kind grouping was removed in
  2.19.0). Images
  rendered in the preview pane; a single
  `emoji-test.txt` entry rendered header, icon, 672 KB size, and a `bat` text
  preview; `/clip text` filtered to the text entry. Copy Files restored file
  URLs to the pasteboard (`«class furl»`).
- Homebrew (1.5.0): `brew upgrade --cask palette` moved 1.4.1 → 1.5.0, installed
  build 7 into `/Applications`, and used `postflight_steps` without the old
  `postflight` deprecation warning; `xattr` showed only `com.apple.provenance`
  (no quarantine). The
  The installed app launched, logged `Hotkey registered: opt+space` and
  `Clipboard hotkey registered: opt+v`, and the embedded `AppIcon.icns` rendered
  from the bundle.
- Web-app shortcuts: added an app with `ctrl+alt+f`; Palette registered the
  shortcut itself and it opened the URL in its standalone app window.
- Snapshots confirmed: app list and selection, calculator, `/neo` browse and
  freeform, `/neof`, `/zj`, `/bw` login/unlock, `/clip` text and image entries,
  `/sys`, `/theme`, external `/hello`, web search, favicon, Settings, and the
  web-app shortcut row.
- Not exercised in this environment: OS-level `⌘⏎` paste delivery (copy-only
  fallback is verified).
