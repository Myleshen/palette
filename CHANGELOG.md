# Changelog

## Unreleased

### Changed

- The paths picker is now editor-agnostic: **Editor** and **Editor Folders**
  use the configured `editor_open_with`, with `/edit` and `/editf` as the
  canonical triggers. `/neo` and `/neof` remain aliases for existing muscle
  memory.
- Settings → General gained a **Defaults** section showing the current editor,
  terminal, browser, theme, and Ask model, with installed-app detection and a
  scoped reset for app/theme/Ask/terminal-session defaults.
- First-run onboarding is now two steps: shortcuts/startup, then a lean
  **Essentials / Developer / Everything** starting set. Essentials stays small;
  editor and terminal choices appear only in the larger presets.

## 2.2.3 — 2026-11-06

### Changed

- Releases run from a `v*` tag now. CI runs the tests, builds
  `Palette-<version>.zip`, publishes the release with this entry as the notes,
  and moves the Homebrew cask, instead of the local `make release` ritual.

### Verified

- `swift test`: 81 tests, 0 failures.
- The `build` CI job is green on the release pull request.
- `Resources/Info.plist` and the tag agree, or the release job refuses to run.

## 2.2.2 — 2026-11-06

### Added

- **Keep Awake** controls in Settings → General, with ON/OFF toggles for
  **Keep Mac Awake** and **Clamshell Mode (Lid Closed)**. Both reflect the live
  service state and can be changed without leaving Settings.

### Verified

- `swift test`: 81 tests, 0 failures.
- Settings toggle tests prove keeping awake can be turned off while clamshell
  remains armed, and clamshell can be turned off without stopping a timer.

## 2.2.1 — 2026-11-06

### Changed

- Clamshell mode is now a real ON/OFF toggle instead of a one-shot command.
  Turning it on arms the root guard without starting an idle keep-awake timer;
  turning it off leaves any active timer alone. Starting a timer preserves an
  armed clamshell guard, and Stop clears both.
- The `/awake` row and menu item both show the toggle state consistently.

### Verified

- `swift test`: 80 tests, 0 failures.
- Clamshell toggle tests use a fake guard: arm while idle, start a timer while
  armed, turn clamshell off without stopping the timer, then stop both.
- Live `/awake` snapshot shows the clamshell row as **OFF**; cancelling the
  admin prompt leaves it OFF and creates no keep-awake assertions.

## 2.2.0 — 2026-11-06

### Added

- **`/awake` keep-awake provider** with timed sessions (15 min–8 h), an
  indefinite mode, and a native `IOPMAssertion` implementation. Assertions are
  recreated after wake/display changes and expire automatically.
- **Clamshell mode (lid closed)**. macOS treats a lid close as forced sleep, so
  Palette arms a small root guard with the standard administrator prompt. The
  guard holds `pmset disablesleep` only while Palette is running, clamshell is
  on, and the Mac is on AC power; it restores normal sleep on stop, quit, or
  unplug.
- **Keep Awake menu-bar submenu** for quick toggles and durations.
- Five new `KeepAwakeTests` (start/stop, timed expiry, provider rows/actions,
  clamshell flag cleanup, and AC/battery transitions through the root guard
  helper).

## 2.1.0 — 2026-11-05

### Added

- Global shortcuts for the embedded terminal (`⌘⌥T`), scratchpad (`⌘⌥S`), and
  Ask (`⌘⌥A`), with Settings recorders, duplicate validation, and empty values
  to disable any of them.
- Scratchpad history: named notes stored in Palette's database, with `/scratch`
  search, create, edit, and delete.
- **Open in Embedded Terminal** from project, path, port, command, Git, recent,
  and Finder-file rows.
- QuickLook previews for files in the preview pane.
- `/recent` for recently opened projects and files.
- `/snip` with `~/.config/palette/snippets.toml` and safe placeholder expansion.
- Application actions for **Quit App** and **Move App to the Trash…**.
- Settings search field, shortcut summary, and duplicate-shortcut warning.

## 2.0.4 — 2026-11-04

### Added

- Embedded terminal font and size settings: `[terminal_session] font`,
  `font_size`, plus fields in Settings. Empty values auto-detect Kitty's
  `font_family` / `font_size`, then the theme mono font.

### Fixed

- `/term` now uses the detected Nerd Font instead of the system monospace font,
  so Zellij/fish icons and Powerline glyphs render correctly.

### Verified

- `swift test`: 70 tests, 0 failures.
- Terminal picked up `DepartureMonoNF` at `18.0` from Kitty's config.

## 2.0.3 — 2026-11-04

### Added

- Terminal session configuration: multiplexer `auto | zellij | tmux | none`,
  session name, and shell (`fish`, `zsh`, or a custom executable), editable in
  Settings → General → Embedded terminal and stored in `[terminal_session]`.

### Fixed

- The embedded terminal now sets `SHELL` for the multiplexer process, so new
  Zellij/tmux panes use fish instead of falling back to `sh`.
- `auto` prefers Zellij, then tmux, then a plain shell.

### Verified

- `swift test`: 70 tests, 0 failures.
- Config round-trip test covers the terminal session settings.
- Zellij Palette session shows fish 4.9.3; `/cmd` Run in Panel still executes.

## 2.0.2 — 2026-11-04

### Changed

- `/term` now attaches or creates a persistent Zellij session named **Palette**.
  Closing the panel detaches the client; long-running commands keep going and
  the next `/term` reattaches. Fish is the initial shell.
- `/cmd` → **Run in Panel** waits for the Zellij session to be ready before
  sending the command.

### Verified

- `zellij list-sessions` shows one `Palette` session.
- Reopening `/term` reattached to the same session.
- Terminal state showed the Zellij Palette tab, fish 4.9.3, and a live shell.
- `swift test`: 70 tests, 0 failures.

## 2.0.1 — 2026-11-04

### Fixed

- Existing configs that still name `opencode-zen` or an old Zen model now migrate
  cleanly to the Go default instead of keeping an invalid model id.
- Onboarding uses an explicit dark background, so its header and footer remain
  readable.

### Verified

- `swift test`: 70 tests, 0 failures.
- Embedded terminal logs a real zsh prompt and command output.
- `/cmd` → **Run in Panel** executed `/bin/echo hello-from-panel` inside the
  embedded terminal.

## 2.0.0 — 2026-11-04

### Added

- **Scratchpad** (`/scratch`): persistent in-panel editor seeded from clipboard
  text, with Paste, Copy All, Clear, and Save & Close.
- **Terminal** (`/term`): SwiftTerm login shell embedded in the content panel.
  `/cmd` items can now **Run in Panel** through the same terminal.
- **First-run setup** window for shortcuts, login item, provider visibility,
  terminal/editor, and an optional Go key.
- **YAML and TOML format** clipboard transforms.
- Preview keyboard scrolling: `⌥P` focuses the preview; `Ctrl+J/K`, `Ctrl+D/U`,
  `Ctrl+F/B`, `Ctrl+G`, and `Shift+G` scroll; `⌘C` copies selected text.

### Changed

- `/ask` is Go-only. OpenAI and Zen were removed; Zen free models are only
  supported inside OpenCode itself, not third-party clients.
- Ask keys moved to an encrypted user-only file, avoiding repeated Keychain
  prompts from ad-hoc debug builds.
- `/git` no longer opens a terminal for status/log or mutations. Commands run as
  managed subprocesses and their output appears in the panel. Only **Open
  LazyGit** launches a terminal.
- Search settings now show simple engine toggles; custom URL templates live
  under an Advanced disclosure.
- Provider tabs are grouped: Neovide (Files/Folders), Bitwarden (five modes),
  and Ask (Ask/History).
- Ask model chooser lists every OpenAI-compatible Go model, cheapest first,
  with input/output prices.

### Verified

- `swift test`: 69 tests, 0 failures.
- `/term` opens an embedded login shell; `/scratch` opens the editor.
- `/git` status/log output renders in the panel and does not launch zsh.
- `/ask` lists Go models only, with costs and cheapest-first ordering.
- New profiles show the setup window; existing profiles are unchanged.

## 1.9.6 — 2026-11-04

### Added

- `/sys` now has **Open Palette Settings**, so the Settings window is reachable
  from the launcher without the menu bar or `⌘,`.
- `/ask` now includes every OpenAI-compatible OpenCode Go chat model, ordered by
  output price with input/output costs shown. Cheaper models no longer disappear
  behind a fixed "small model" list.
- Ask keys moved from the login Keychain to an encrypted user-only file under
  Palette's config directory. Ad-hoc debug builds no longer trigger repeated
  Keychain access prompts.

### Changed

- Summary subtitles say "local key file", not Keychain. You may need to re-enter
  an existing key once after this migration.

### Verified

- `/sys settings` shows the row; pressing Return opens the Settings window.
- `swift test`: 69 tests, 0 failures.

## 1.9.5 — 2026-11-04

### Changed

- Settings is reorganized around user tasks: General (shortcuts, apps, window,
  app order), Appearance, Clipboard, Search, Ask, Providers, and Advanced.
- Provider visibility, order, and aliases now live together under **Providers**
  instead of being buried in Advanced. Aliases are collapsed unless needed.
- The command prefix moved to Advanced; General no longer asks users to edit
  low-level options.
- The launcher is pill-only. The classic layout and its `search_style` config
  key are removed; old configs with that key continue to load normally.

### Verified

- `swift test`: 69 tests, 0 failures.
- Empty-query snapshot shows the two-surface pill layout with no classic branch.

## 1.9.4 — 2026-11-04

### Changed

- Added per-provider enable/disable controls in Settings → Advanced. Disabled
  providers disappear from the tab bar, Tab cycling, and trigger parsing.
  `[providers] disabled = ["port"]` stores the same choice in config.toml.

### Verified

- `swift test`: 69 tests, 0 failures.
- Registry test confirms a disabled provider is absent from tabs and its
  trigger falls back to global search.

## 1.9.2 — 2026-11-03

### Fixed

- Finder-launched Palette now prepends Homebrew, `/usr/local`, and MacPorts
  paths to its child environment, so devx, Bitwarden, Zellij, and workspace
  tools resolve even though launchd starts apps with a minimal `PATH`.

### Verified

- Devx doctor reports **devx is ready** with the configured terminal, editor,
  profiles, fzf, and LazyGit.
- A manifest command with `terminal = false` ran and wrote its expected output.

## 1.9.1 — 2026-11-03

### Fixed

- `/proj` now parses devx's tab-separated project list correctly, including
  registered worktrees, and uses the reported path instead of guessing
  `~/dev/<name>`.
- `/web` accepts local development URLs such as `http://localhost:5173` and
  `http://127.0.0.1:8080`.

### Verified

- Installed devx 0.1.2, configured Neovide/kitty/lazygit, and reached
  `devx doctor` → **devx is ready**.
- Created and removed a real devx worktree; Palette listed it with **WORKTREE**.
- Killed test HTTP servers through `/port` with both SIGTERM and SIGKILL.
- Exercised Git stage, commit, push, pull `--ff-only`, and copy branch against a
  disposable repository and bare remote.
- Added, opened, and removed a local test URL as a Web App.
- `swift test`: 65 tests, 0 failures.

## 1.9.0 — 2026-11-03

### Added

- **Clipboard transforms**: 16 built-ins available from `⌘K` on any text entry,
  with a full preview before the clipboard is replaced. No scripts run
  automatically.
- **Typography overrides**: `[typography]` ui/mono family and sizes, resolved as
  config → theme → system, with pickers, free text, live preview, and reset in
  Settings.
- **`/port`**: listening TCP ports with process, PID, user, and working
  directory; open localhost, copy port/PID, SIGTERM, and confirmed SIGKILL.
- **`/cmd`**: manifest-based commands in `~/.config/palette/commands.toml` for
  Gradle, Go, Java, make, Docker, and project-specific tasks.
- **`/proj`**: devx projects and worktrees with Open in Neovide/Terminal/
  Workspace, worktree create/remove, and config apply. Falls back to `~/dev`
  repositories when devx is absent.
- **`/git`**: repository list with branch/dirty state plus stage all, commit,
  fast-forward pull, push, log, and LazyGit. No force-push or history rewriting.
- **Provider aliases and order**: extra trigger words and persisted tab order,
  editable in Settings with duplicate validation.

### Verified

- `swift test`: 64 tests, 0 failures.
- Live harness: transforms previewed the full result; `/port` listed real
  listeners with cwd; `/git` listed clean/dirty repositories; `/proj` listed
  projects; `/cmd` loaded a manifest command.

## 1.8.0 — 2026-11-03

### Added

- **`/ask` one-shot AI answers** over OpenCode Zen, OpenCode Go, and any
  OpenAI-compatible chat-completions endpoint.
- **Free-first model chooser.** `/ask` with no question lists the selected
  endpoint's models with free options first and badges, and remembers the pick.
  Quota or availability failures automatically fall back to other free models,
  then to small paid models when the key has access.
- **Ask History sub-tab and `/askh`** with fuzzy search over questions and
  answers, model/endpoint/time/duration/token metadata, answer preview, copy,
  ask-again, and per-row delete.
- **Keychain-only API keys.** A key is visible only before saving; afterward
  Settings reports that a key exists without ever showing it. Nothing is written
  to `config.toml`, logs, or history.
- **`[ask]` config and Settings tab** for endpoint, model, answer tokens,
  fallback, retained Q&A count, and retention age.

### Verified

- `swift test`: 60 tests, 0 failures, including free-first ordering, model
  scoping, quota fallback, invalid-key endpoint skipping, config round-trip
  without secrets, response parsing, and history trimming.
- Live mock OpenAI-compatible endpoint: `/ask hello openai` answered in 0.35 s,
  persisted the Q&A, and `/askh` displayed model, provider, latency, and token
  metadata.
- Real OpenCode endpoints: free Zen key returned 429 quota and expired Go key
  returned 401, both handled without crashing and with a readable status.

## 1.7.13 — 2026-11-03

### Fixed

- Clearing `/clip` with `Esc` now closes the clipboard preview pane and
  restores the normal launcher width. Previously the empty app list kept the
  right-hand preview open, showing “No preview available.”

### Verified

- `swift test`: 51 tests, 0 failures.
- Harness: opened the clipboard browser, pressed `Esc`, and snapshotted the
  empty app list with the preview pane gone.

## 1.7.12 — 2026-11-03

### Fixed

- **Pasting images into a terminal TUI now waits for the terminal to be
  frontmost.** Palette yields activation, re-activates the target, and only
  posts Ctrl+V once it is actually frontmost, instead of assuming 220 ms was
  enough. This fixes image paste into the OpenCode TUI in kitty.
- Clipboard fuzzy search no longer stops at 5,000 entries. It scans the full
  configured history, and only skips thumbnails while ranking so large
  histories stay responsive.

### Changed

- **Bitwarden cache and session lifetime: six hours → thirty days.** The
  encrypted vault snapshot and CLI session key now survive restart for 30 days;
  the same AES-GCM cache and per-profile scoping are unchanged. **Refresh
  Bitwarden Cache** still forces a fresh read without logging out.

### Verified

- `swift test`: 51 tests, 0 failures.
- Live image-paste probe: a real terminal TUI received `0x16` (Ctrl+V) after
  Palette pasted an image; the pre-1.7.12 220 ms delay did not deliver it.

## 1.7.11 — 2026-11-03

### Changed

- **fzf-style fuzzy search everywhere.** The in-process matcher now scores
  abbreviations and non-contiguous terms by runs, word boundaries, and gaps, so
  `actmon` finds Activity Monitor, `vsc` finds Visual Studio Code, and `qbf`
  finds “The quick brown fox”.
- Clipboard search no longer relies on a SQL `LIKE` prefix. It ranks recent
  history in memory, so non-contiguous searches and file-name searches work
  across text, images, and files.
- Bitwarden item matching uses the same fuzzy scoring across name, username,
  URL, and notes, and sorts matching vault rows by match quality.
- Emoji search accepts abbreviations (`drgn` → Dragon) while still preferring
  literal names so `dragon` does not surface “Red Triangle”.
- `/neo` and `/neof` keep the real `fzf` path ranker with `--scheme=path`.

### Verified

- `swift test`: 49 tests, 0 failures.
- Live harness: `/clip qbf` matched “The quick brown fox…” in clipboard history,
  and `actmon` ranked Activity Monitor first.

## 1.7.10 — 2026-11-03

### Removed

- **App grid mode is gone.** Every provider, including applications, now uses
  the single list layout. `app_grid` and `app_grid_columns` are no longer read
  or written; the keys are simply ignored, with no migration or compatibility
  path. Arrow keys always move one row at a time.

## 1.7.9 — 2026-11-03

### Changed

- **Image paste now matches the target app.** Terminal/TUI hosts such as kitty
  receive Ctrl+V for images, so OpenCode's image paste handler fires; regular
  apps such as WhatsApp and TextEdit keep Cmd+V. Text pastes are unchanged.
- Settings → Advanced now lists every registered provider with its trigger and
  startup diagnostics.
- Added **Export Backup…**, which packages `config.toml`, themes, providers, and
  the SQLite state (including WAL/SHM) into a zip.
- Added a crash breadcrumb for uncaught exceptions at
  `~/.local/state/palette/crash.log`, with an **Open Crash Log** action.

### Fixed

- The app logs Accessibility trust at launch so a stale TCC grant is visible
  instead of silently only copying.

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
