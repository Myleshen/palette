# Changelog

## 1.7.8 — 2026-11-03

### Changed

- **Pill is now the default launcher shape.** Existing configs keep whatever
  they already specify; fresh installs and missing `search_style` values use
  the two floating surfaces.
- Entering `/clip` by typing or tabbing now opens the preview layout just like
  the clipboard hotkey; leaving `/clip` removes the preview and returns the
  normal width.

### Fixed

- **Stable code signing.** Builds now use an explicit designated requirement
  based on `dev.myleshen.palette` instead of a per-build cdhash, so an
  Accessibility grant survives future installs. The old cdhash grant is invalid
  after this change and must be re-added once.
- Settings now shows Accessibility status, an **Open Accessibility Settings**
  button, and **Check Again**, plus the app version and a copyable
  `brew upgrade --cask palette` command.
- The shortcut recorder reports when it cannot create its event tap because
  Accessibility is missing, and the app asks for that permission at launch.
- Paste timing was increased slightly and target/trust is logged for diagnosis.

## 1.7.7 — 2026-11-03

### Changed

- More vertical padding on provider tabs and the tab strip, plus a clear gap
  between wrapped rows. Tabs remain two rows with every provider visible.
- Pill cards are now fully opaque. The previous 96% fill let high-contrast text
  from windows behind the launcher ghost through the list.
- The list keeps its bottom fade so the scroll edge does not end on a hard cut.

## 1.7.6 — 2026-11-03

### Fixed

- Removed the dark “background plate” artifacts behind the floating pill
  surfaces. Pill mode disabled the panel’s own window shadow and the cards were
  still drawing large black shadows, producing a duplicate dark outline on
  bright desktops.
- Pill mode now uses only subtle per-card shadows; the window itself casts no
  shadow. The two-card layout stays clean on white and other bright wallpapers.
- Classic mode keeps its normal window shadow and vibrancy.
- Provider tabs now wrap into two rows instead of hiding behind a clipped
  horizontal scroller. Bitwarden labels are shortened to `BW …` and the row has
  proper spacing and vertical padding.
- More breathing room throughout pill mode: 14 pt outer gutters, a 10 pt gap,
  larger row insets, a 28 pt content-card radius, and a 6-row cap with a bottom fade.
- Grid selection uses a rounded cell instead of a stretched capsule; long app
  names no longer sit inside an oval blur.

## 1.7.5 — 2026-11-03

### Fixed

- **Shortcut recorder now captures macOS-reserved combinations** such as
  `⌘Space`. A focused text field never received those key-downs because the
  system consumed them first. The recorder now installs a short-lived session
  event tap while recording, records the combination, and consumes its key-up.
  The tap is torn down on capture, Esc, focus loss, or app deactivation, so it
  cannot keep intercepting keys.
- Verified `⌘Space` can be recorded, saved to `config.toml`, registered by the
  Carbon hotkey manager, and used to open Palette.
- README no longer lists the removed **Bottom** launcher position.

## 1.7.4 — 2026-11-03

### Changed

- **Pill mode now uses two separate floating surfaces**: a standalone search
  capsule and a rounded content card below it, with the desktop visible through
  the gap. The content card owns the tabs, results, actions, and footer.
- The window background is transparent in pill mode, so each surface draws its
  own border and shadow instead of sharing one full-window vibrancy rectangle.
- The search capsule uses the theme surface colour, matching the content card
  rather than picking up the desktop behind it.
- Panel height includes the new top/bottom margins and gap, so the card is not
  cut off.
- Switching between Classic and Pill in Settings applies live through the same
  reload path; Classic keeps the original single-panel layout and vibrancy.

## 1.7.3 — 2026-11-03

### Fixed

- **Settings no longer keeps stale values.** Closing the window kept its old
  SwiftUI state alive, so after editing `config.toml` and pressing `⌘R`, the
  next Settings visit showed the old hotkey/browser/theme and could write those
  old values back on Save. The window is now rebuilt from the live configuration
  when reopened, and refreshed in place if it is open during a reload.
- Added explicit **Record** buttons next to both shortcut fields. Clicking
  Record focuses the recorder; pressing the keys updates the field, and Save
  registers the new shortcut and writes it to `config.toml`.
- Verified a config-only launch shortcut change: `hotkey = "cmd+space"` followed
  by menu-bar **Reload Configuration** registered `cmd+space`, and reopening
  Settings showed `cmd+space` instead of the old `opt+space`.

## 1.7.2 — 2026-11-03

### Fixed

- Reworked the **Siri-style pill** so the whole launcher is cohesive instead of
  only the search field: a floating search capsule, soft accent pill outlines
  for the active tab, result, and action, capsule grid selection and badges, and
  a more rounded panel. Unselected rows stay flat, matching native macOS lists.
- The pill panel background is near-opaque, removing the text ghosting seen
  through the old translucent panel.
- Replaced the clipped native placeholder with a custom aligned placeholder;
  it now renders cleanly in both styles.
- The tab strip fades at its trailing edge instead of cutting the last chip,
  and pill row height/spacing is included in the panel-size calculation.
- Contrast on selected rows is fixed: accent text, readable subtitles, and
  selected provider labels.

## 1.7.1 — 2026-11-03

### Changed

- **Bitwarden sessions now survive app restarts for six hours.** The CLI session
  key is sealed with AES-GCM next to the vault cache instead of living only in
  memory. Logout or a real CLI expiry still removes it; **Refresh Bitwarden
  Cache** keeps the session.
- The status-bar menu no longer carries a Clipboard Paste Permissions item.
  macOS asks for Accessibility on the first paste that needs it, like other
  apps, and the menu never opens System Settings and a second OS prompt at the
  same time.

### Fixed

- Removed the **Bottom** launcher position. It fought with the normal top-first
  layout; **Top** and **Center** remain, and existing `search_position =
  "bottom"` configs migrate to **Center**.
- Added an optional **Siri-style pill** chrome (`search_style = "pill"`),
  selectable in Settings → General. The search field and tab rail become
  capsules, result/action selections become capsules, and the panel corners
  round further. Classic remains the default.
- Bitwarden only discards the session when the CLI reports an actual auth
  failure, not whenever a log line happens to contain the word “session”.
- Session clears now log their reason.

## 1.7.0 — 2026-11-03

### Added

- **Six-hour Bitwarden cache**, encrypted with AES-GCM under
  `~/Library/Caches/Palette/Bitwarden` and scoped per CLI profile. The first
  search reads the vault once; every prefix, keystroke, and copy after that uses
  the snapshot. **Refresh Bitwarden Cache** in the menu-bar menu forces a fresh
  read and deletes the local copy.
- **Most used** app order in Settings → General. Alphabetical stays the default;
  the frequent order ranks by the launch counts already stored in SQLite.
- Clipboard rows now **paste on Enter/click** instead of only copying. With
  Accessibility granted this is an immediate ⌘V into the previous app.
- The menu-bar icon is now a flower-shaped paint palette matching the app icon.
- README has the new logo and documents Bitwarden caching, app ordering, and
  the Advanced settings tab.

### Changed

- Settings moved `config.toml`, providers, themes, and the log into **Advanced**;
  the everyday tabs no longer expose file paths.
- The empty-query screen shows apps plus pinned items only. Unpinned web apps,
  sessions, and search rows no longer mix into the default app list. Pinned web
  apps still lead the list.
- The empty-query app limit was raised from 24 to 500 so the full app library is
  searchable and sortable.

### Fixed

- Punctuation-only entries such as `[` or `]`, broken symlinks, control
  characters, and wrong-kind files are filtered out of `/neo`, `/neof`, and
  path browsing.
- The menu-bar permission item disappears once Accessibility is granted.
- Global empty searches no longer wait on provider spawning for every keystroke.

## 1.6.0 — 2026-11-03

### Added

- Bitwarden rows and prompts now show the account email, and the unlock prompt
  reads “Master password for you@example.com”, so it is clear which vault is
  being unlocked.
- Web apps open in a Chromium app window (`--app=…`) with a dedicated Palette
  profile. Hammerspoon exports the browser executable and arguments, so
  shortcuts open the same standalone window instead of Safari.
- Launcher position is a segmented Top / Center / Bottom control in Settings,
  plus a **Launcher Position** submenu in the menu-bar menu.

### Fixed

- Bitwarden no longer clears the in-memory session on every list failure.
  Timeouts (now 60 s), network errors, and server errors keep the session and
  show a retry row; only genuine session/auth failures ask for the password
  again. Failures and stderr are logged under `[bitwarden]`.

## 1.5.1 — 2026-11-03

Fixes found during the physical 1.5.0 test round.

### Fixed

- The shortcut recorder is now an accessibility button with a label and value,
  and recording a shortcut was verified end-to-end from the installed app.
- Config.toml now opens in Neovide with Homebrew's `nvim` on `PATH`; GUI apps
  previously inherited launchd's minimal PATH and Neovide failed to start.
- Leaving `/clip` (Tab, another prefix, or clearing the query) drops the preview
  pane and wide layout instead of leaving it over the next provider.
- Panel show/hide no longer animates, cutting Enter-to-panel-hidden latency from
  ~423 ms to ~84–105 ms in the same measurement.
- Web-app browser validation was exercised in the real Settings window: saving
  with an uninstalled browser shows the install message and leaves the config
  untouched.

## 1.5.0 — 2026-11-02

Daily-use release. Existing configs keep working; new fields (`search_position`,
`web_app_browser`) default to top and Helium.

### Added

- **Provider tabs** under the search field: Apps plus every triggered provider.
  `Tab` / `⇧Tab` cycle them, clicking opens one with an empty query.
- **Search position**: `top`, `center`, or `bottom`. Bottom stacks results and
  tabs above the field and anchors the panel to the bottom of the screen.
- **Shortcut recorder** in Settings: press the keys instead of typing
  `opt+space`.
- **Web-app browser** setting with a Chromium-only picker (Helium default).
  Saving is blocked with a clear message when the selected browser is missing.
- **App icon** (pink command palette) bundled as `AppIcon.icns`.
- Clipboard: pinned entries sort to the top and filter tabs switch between All,
  Text, Images, and Files.
- Bitwarden: in-app login and unlock (prompt or `BW_EMAIL` / `BW_PASSWORD`),
  shared session across all five prefixes.

### Fixed

- Config.toml from the menu now opens in the configured editor (Neovide), not
  whatever macOS has registered for `.toml`.
- Themes no longer stay stuck on a stale `/theme` override after Settings or
  config changes; a config save clears the override.
- Finder appears in app search; CoreServices helper daemons do not.
- Enter reaches the action faster: the frecency write now happens after the
  action instead of ahead of it.
- Only one Palette can run; a second launch activates the existing instance.
- Web apps always offer an Add row, even with no saved apps.
- Bitwarden values are concealed and excluded from clipboard history.
- Homebrew cask uses `postflight_steps` instead of deprecated `postflight`.

## 1.4.1 — 2026-11-02

### Fixed

- `⌥Space` did nothing when the clipboard hotkey was also enabled: each
  `HotKeyManager` installed its own Carbon event handler on the same target, and
  the second installation replaced the first. A single shared router now
  dispatches by hotkey id, so both `opt+space` and `opt+v` work together.
- Hotkey display strings are normalized (`opt+ space` → `opt+space`).

## 1.4.0 — 2026-11-02

Clipboard and emoji release.

### Added

- **Clipboard browser hotkey** (`⌥V`, configurable as `clipboard_hotkey`):
  opens `/clip` in a wide panel with a live preview pane.
- **Clipboard previews**: full text, image thumbnails at their real dimensions,
  and Finder selections with icons, sizes, paths, and a `bat` text render.
- **File clipboard entries**: Finder copies are stored separately with Copy
  Files, Paste Files, and Reveal in Finder.
- **Clipboard categories**: Text, Images, and Files are grouped in the browser
  and filterable with `/clip text`, `/clip images`, and `/clip files`.
- **Full macOS emoji catalog**: 3,967 entries merged from Unicode 18 and the
  system `CoreEmoji` names, so search matches Spotlight and Character Viewer.
- `clipboard_hotkey` is editable in Settings.

### Changed

- Bound provider results are capped at 5,000 so the complete emoji list is
  reachable.

## 1.3.0 — 2026-11-02

Parity and daily-use release.

### Added

- **Settings window** (`⌘,`): hotkey, prefix, terminal, editor, app grid, theme
  mode/pair, clipboard retention, and web-search engines. Saving applies
  immediately; manual file edits reload with `⌘R`.
- **Web search provider**: global rows for Google, DuckDuckGo, GitHub, and
  YouTube (configurable), opened in the default browser.
- **Favicons for web apps**, fetched and cached under
  `~/Library/Caches/Palette/Favicons`.
- **Gruvbox Dark/Light and Aetheria Pink** built-in themes.
- **Full Unicode emoji catalog** (3,963 names) with literal-name search.
- **Breadth-first path browsing**: `/neo ~/dev/` shows direct children before
  deeper levels; directories sort before files at each depth.
- Clipboard default history is now **5,000** entries; the Settings window can
  change it.
- Bitwarden unlock now keeps the in-memory session across all five prefixes,
  and the test vault was verified against `/bw` and `/bwn`.

### Fixed

- A lone `/` no longer creates a Zellij session or offers web searches for
  `/`; it returns to the normal app list.
- Zellij only offers session creation in `/zj`, not from global search.
- App grid defaults to **off**; enable it in Settings or `app_grid = true`.
- Emoji search no longer returns unrelated names from loose subsequence matches.

## 1.2.0 — 2026-11-02

Noctalia parity release. No migration is required; existing `config.toml` keeps
working, and new defaults fill in the missing home scope and app grid.

### Added

- `/neo` now searches files **and** folders across `$HOME` and accepts typed
  absolute, `~`, or relative paths; `/neof` mirrors Noctalia as folders-only.
- Clipboard history stores images as well as text, with thumbnails, dimensions,
  pin/delete, Copy Image, and Paste Image actions.
- Bitwarden is split into the Noctalia prefixes: `/bw` passwords, `/bwu`
  usernames, `/bwt` TOTP, `/bwn` notes, `/bwo` URLs, sharing one in-memory
  session per app run.
- Zellij is global, with fixed **New Zellij session** and **Work** rows plus
  every running session.
- Pinned items: `⌘K` on any result can pin it; pinned results lead the grid and
  global search.
- Emoji picker at `/emoji`.
- App grid for the empty query, with 2D arrow-key navigation and
  `app_grid` / `app_grid_columns` configuration.
- Web apps participate in global search.
- `[scopes.home]` default scope, excluding Library, Movies, Music, Pictures,
  and Trash.

### Verified

- `swift test`: 23 tests, 0 failures.
- Live UI: `/neo` file/folder/freeform paths, `/neof` folders, image clipboard
  capture and copy, `/zj` fixed/running rows, Safari pin/unpin, emoji copy,
  and grid navigation.

## 1.1.0 — 2026-11-01

Polish and reliability release. No configuration changes are required.

### Fixed

- **Application search no longer matches unrelated apps.** Each app field is
  scored separately, so typing `Safari` cannot match letters stitched together
  from an app's name, bundle ID and path keywords.
- **Symlinked apps are indexed.** Safari and other apps that are symlinks in
  `/Applications` now appear in results.
- **Stale results can no longer overwrite a newer query.** A cancelled search
  now stops before applying its results.
- **Paste explains itself when Accessibility is missing.** Palette keeps the
  panel open, copies the text, and shows
  “Copied — enable Accessibility to paste automatically.”
- **A failed hotkey change keeps the previous hotkey** instead of leaving
  Palette unreachable.
- **Reloading the hotkey no longer leaves a stale Carbon handler.** The handler
  is removed on rebind, so a press cannot fire a deallocated manager.
- **Copy actions return focus to the previous app**, so the next `⌘V` lands
  where you expect.
- **Provider restarts no longer inherit a bogus backoff.** A provider killed by
  a timeout or idle shutdown is not treated as a crash, and a late exit from an
  old process cannot detach the new one.
- **The action overlay follows its item.** If a background refresh removes the
  selected entry, actions mode closes instead of acting on a different row.
- **Clicking another app no longer bounces focus back.** Auto-hide on resign-key
  leaves the clicked app in front.
- Clipboard counts use proper singular/plural (`1 char`, `2 chars`).
- **Bitwarden login and install use the configured terminal.** Both now open
  `terminal_app` (kitty by default) instead of hard-coded Terminal.app.
- **Panel activation uses the supported AppKit API** (`NSApp.activate()`),
  avoiding the deprecated `ignoringOtherApps` path on current macOS.
- The panel opens on the screen containing the pointer, not always the primary
  display.

### Added

- Application actions in `⌘K`: Open, Show in Finder, Copy Bundle ID, Copy Path.
- Meaningful icons for actions (pin, delete, reveal, copy, unlock, and so on).
- An in-process `PALETTE_SCRIPT` harness for unattended live UI tests. See
  `TESTING.md`.
- `PALETTE_SNAPSHOT_DELAY` for providers that need longer to answer.
- Provider names are hidden while a provider is bound, since the scope pill
  already says which provider you are in.
- **Web apps provider (`/web`).** Add a domain, name it, open/copy/remove it,
  and let usage rise to the top. Web apps can also carry a keyboard shortcut;
  Palette exports `~/.hammerspoon/palette-webapps.lua`, which Hammerspoon loads
  and watches automatically.
- **Homebrew Cask packaging.** `make release` builds the zip, updates the
  checksum, and prints tap/release steps. No App Store or paid account.
- **Hammerspoon keybind table.** `keybinds.lua` maps mods + key to app, path,
  script, URL, shell, or window actions, Hyprland-style.

### Verified

- `swift test`: 21 tests, 0 failures.
- Homebrew zip builds and its checksum matches the Cask.
- Live synthetic-key runs: calculator copy, clipboard capture, action overlay,
  theme switching, `/neof`, `/zj` create row, and Accessibility paste fallback.
- Final bundle installed at `~/Applications/Palette.app` (ad-hoc signed).
