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

Checked on 2026-11-02, macOS 27.2 (arm64), with the display unlocked:

- `swift test` — 32 tests, 0 failures (including ordered NDJSON delivery,
  web-app URL normalization, shortcut parsing, store dedupe, text/image/file
  clipboard, pins, Lua export, config round-trip with `clipboard_hotkey`,
  `search_position`, and `web_app_browser`, emoji catalog and Apple names,
  breadth-first paths, default-off app grid, browser validation, and the
  shortcut recorder).
- `make app` and `make install` — release bundle assembled, ad-hoc signed,
  installed at `/Applications/Palette.app` (`dev.myleshen.palette`, LSUIElement,
  version 1.5.0). Hotkeys `opt+space` and `opt+v` registered without a
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
- v1.5 checks: the empty query showed the Apps tab first; `Tab` switched to
  `/calc` and `⇧Tab` returns; typing `finder` ranked the CoreServices Finder
  first with web-search rows below; `search_position = "bottom"` put the tab
  strip and search field under the results; `/clip` showed pinned-first
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
- Homebrew: uninstalled and reinstalled with `brew install --cask
  Myleshen/tap/palette`; the cask downloaded `v1.4.0`, installed build 5 into
  `/Applications`, and its postflight removed `com.apple.quarantine`. The
  installed app launched, logged `Hotkey registered: opt+space` and
  `Clipboard hotkey registered: opt+v`, and physical `⌥V` opened the clipboard
  browser with grouped Text rows and the preview pane.
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
