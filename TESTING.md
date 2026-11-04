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
| `PathsEngineTests` | fd enumeration, excludes, fzf ranking, weird filenames |
| `ManifestTests` | provider manifest parsing and validation diagnostics |
| `AskTests` | Ask config round-trip without secrets, free-first model order, endpoint scoping, response/error parsing, quota fallback, invalid-key endpoint skipping, Settings model precedence |
| `ExternalProviderTests` | NDJSON round-trip against the hello example |

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

Supported steps: `show`, `hide`, `toggle`, `actions`, `exit`,
`query=<text>`, `snapshot=<path>`, `wait=<seconds>`, and
`key=<token>` where token is `up`, `down`, `enter`, `esc`, `tab`, `space`,
`comma`, `k`, `r`, `w`, `1`…`9`, optionally prefixed with `cmd+`, `opt+`, or
`shift+` (for example `key=cmd+k`). `snapshot` writes the panel content without
screen-recording permission, so it works on a locked display.

Other hooks: `PALETTE_QUERY`, `PALETTE_SHOW_ON_LAUNCH`,
`PALETTE_SNAPSHOT`, `PALETTE_SNAPSHOT_DELAY`, `PALETTE_EXIT_AFTER_SNAPSHOT`,
and `PALETTE_ACTIONS`.

The harness calls the same `SearchController` keyboard path as the panel, but
it does not test Carbon hotkey delivery or real typing. Check those manually.

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
- [ ] v1 has no login item; launch Palette after login (or add it to Login Items).
- [ ] Rebuild + reinstall preserves config, state, and clipboard history.

## Verified in this build

Checked on 2026-11-03, macOS 27.2 (arm64), with the display unlocked:

- `swift test` — 70 tests, 0 failures (including ordered NDJSON delivery,
  web-app URL normalization, shortcut parsing, store dedupe, text/image/file
  clipboard, pins, Lua export, config round-trip with `clipboard_hotkey`,
  `search_position`, and `web_app_browser`, emoji catalog and Apple names,
  breadth-first paths, browser validation, the shortcut recorder, Bitwarden
  session classification, encrypted cache expiry and refresh, path filtering,
  use counts, fuzzy abbreviations, fuzzy clipboard/file search, Ask config
  without secrets, free-first models, quota fallback, invalid-key endpoint
  skipping, response parsing, and Ask history trimming).
- `make app` and `make install` — release bundle assembled, ad-hoc signed,
  installed at `/Applications/Palette.app` (`dev.myleshen.palette`, LSUIElement,
  version 2.0.1). Hotkeys `opt+space` and `opt+v` registered without a
  conflict.
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
- v1.8.0 checks: `/ask` listed only the selected endpoint's models with free
  options first, selecting a model persisted it, and a mock OpenAI-compatible
  endpoint answered `/ask hello openai` in 0.35 s. The Q&A row included model,
  provider, latency, and tokens; `/askh` found it with fuzzy search and preview.
  The no-key path showed the setup row, and Settings Ask displayed only
  “Key saved in the macOS Keychain” after saving. Real Zen free quota returned
  429 and the expired Go key returned 401; both were reported without a crash.
  `swift test`: 70 tests, 0 failures.
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
  Pressing the Hammerspoon shortcut `ctrl+alt+m` launched the identical app-mode
  command instead of Safari. The 1.6.0 build offered a segmented
  Top/Center/Bottom control; the Bottom option was removed in 1.7.1 because it
  inverted the layout, and old `bottom` configs now open in the center.
- v1.5.1 physical round on the installed app (screen unlocked):
  `⌥Space` opened the launcher and `⌥V` opened the clipboard browser with the
  wide preview and filter chips; `Esc` dismissed them. In Settings, clicking the
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
  Text/Images/Files groups, the All/Text/Images/Files chips highlighted the
  matching filter, and `/clip image` showed only the 1024×1024 image with its
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
  screenshot, and a two-file Finder selection were captured and grouped under
  Text/Images/Files. Images rendered in the preview pane; a single
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
- Web-app shortcuts: added an app with `ctrl+alt+f`; Palette exported
  `~/.hammerspoon/palette-webapps.lua`, Hammerspoon reloaded and the shortcut
  opened the URL. The generated file, `init.lua`, and `keybinds.lua` pass
  `luajit -bl` syntax checks.
- Snapshots confirmed: app list and selection, calculator, `/neo` browse and
  freeform, `/neof`, `/zj`, `/bw` login/unlock, `/clip` text and image entries,
  `/sys`, `/theme`, external `/hello`, web search, favicon, Settings, and the
  web-app shortcut row.
- Not exercised in this environment: OS-level `⌘⏎` paste delivery (copy-only
  fallback is verified).
