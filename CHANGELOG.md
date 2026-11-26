# Changelog

## 2.19.0 — 2026-11-26

### Added

- **Cross-app theming.** A new **Theming** section (its own sidebar group, above
  Advanced) owns the Palette theme, optional theming of other apps (off by
  default), and the target list. A palette is generated from the chosen theme or
  extracted from the wallpaper, written as managed includes under
  `~/.config/palette/theme/` (kitty, Ghostty, zellij, Neovim, fish, starship,
  bat, delta, btop, yazi), with include lines to copy, Apply and one-step
  Revert. Wallpaper palettes re-apply automatically when the wallpaper changes;
  theme palettes apply on demand. Palette never edits the apps' own configs.
- **Chromium browser theming via managed policy.** Installed Chromium browsers
  (Helium, Chrome, Edge, Brave, Vivaldi, Chromium) can inherit the palette
  background as `BrowserThemeColor` through a per-browser `.mobileconfig`,
  installed with one native Touch ID/password prompt, removable the same way.
  App-wide per browser and approximate by design; Arc is listed as unsupported.
- **19 Omarchy themes** (`omarchy-*`), MIT, contrast-checked, alongside the 914
  Ghostty themes in the theme browser.
- Action-routing contract and store-level wiring tests with mutation checks.

- **914 Ghostty themes** bundled as `ghostty-*` (MIT, contrast-checked; user
  themes with the same name still win). Rex's palettes are proprietary and were
  deliberately not ported.
- **Theme browser** in Settings → Appearance: search across Built-in / Ghostty /
  Custom, per-row colour swatches and a live preview of the launcher. Selecting
  only previews; **Use Theme** applies and **Revert** restores.
- **Per-kind clipboard limits**: text, images and files trim independently
  (defaults 100 / 20 / 20); the old `max_entries` becomes the text limit and is
  rewritten on the next save.
- **Preview text size**: 13 pt by default (was hardcoded 11), configurable
  9–24 under Appearance → Typography, applied to every preview surface.
- **Action-routing contract** and store-level wiring tests, with mutation checks
  (reverting the OCR fix or the setup-file creation now fails the suite).

### Changed

- `/clip` is a flat chronological list across text, images and files — no
  kind grouping, pins keep their badge without jumping the queue. Filter chips
  still narrow by kind.
- Provider speed: GitHub caches by repo instead of query (no `gh` per
  keystroke), `/zj` stops spawning `zellij` on plain keystrokes, emoji fields
  are pre-folded, `docker ps` and stats are cached, `/port` batches one `lsof`,
  `/shots` paints immediately with lazy thumbnails, favicon fetches are gated,
  the theme catalogue is cached, and Bitwarden shows a progress row with a 15 s
  cap.
- Global searches race a **300 ms per-provider deadline**, so one slow source
  cannot hold every result; late sources are reported once.
- Paste prefers the target's **Edit ▸ Paste** menu via Accessibility; Neovide
  falls back to "Copied — press ⌘V" instead of typing `<d+v>`. kitty and other
  terminals keep synthetic ⌘V.
- Opening files no longer happens after hiding the panel; only setup rows create
  missing files, everything else reports that the file is gone.
- Timers, bindings, Docker actions, theme saves, shot copies and eyedropper
  cancels all report success/failure; a config reload with a parse error now
  reports the error instead of "reloaded".

### Fixed

- Palette screenshots and recordings now appear in `/clip`: the capture,
  recording and annotator copies record the bytes explicitly (deduped by hash)
  while the monitor still ignores the duplicate pasteboard poll.
- Capture storage reuses the already-captured bytes and thumbnail and does the
  hash/write/insert off the main actor (store hold time 73 ms → 8 ms; pasteboard
  write 41 ms → ~0 ms).
- Atlas 1.8.0: tool resolution goes through `ToolLocator` (no dot-files
  fallback), and missing/review paths report instead of failing silently.
- Return on a row with no action says so; missing clipboard images say so; paste
  failure keeps the panel and tells you to press ⌘V.

## 2.18.2 — 2026-11-24

### Changed

- The embedded terminal now fills the whole area below the search pill — the
  provider rail and the actions footer step aside — instead of sitting inside the
  content card. The window frame is unchanged; there is a single 12 pt gap from
  the window edge.

### Fixed

- **`/neo` no longer hangs or quits the app.** The file index is answered from
  the last snapshot (memory or the 24 h disk cache) in about a millisecond and
  refreshed in the background, re-running the query when it lands. The `fd` walk
  is streamed and capped at 150 000 entries, fuzzy filtering under 20 000 paths
  runs in-process instead of spawning `fzf` per keystroke, and the deep home
  walk only runs with indexing consent.
- **SIGPIPE no longer terminates Palette.** Writing a child's stdin after it
  exited (for example a cancelled `fzf`) killed the process silently; SIGPIPE is
  ignored at startup and a closed stdin stops the write and logs it.
- Clipboard images are no longer stored as SQLite BLOBs. They live as
  content-addressed files under the state directory with a `clipboard_images`
  reference table, cascading deletes, dedupe, a 200 MB cap and an orphan sweep;
  existing databases migrate with a verified backup and one VACUUM. In the test
  fixture the database dropped from 31.8 MB to 284 KiB.
- Clipboard queries use `(pinned, created)` and `(kind, created)` indexes.
- Panel moves and the Settings window swap are deferred out of the SwiftUI layout
  pass, removing the reentrant-layout fault, and the AppKit `ProgressView`
  configuration fault (hundreds of lines per session) is replaced by a small
  SwiftUI spinner.
- The Hammerspoon bridge and its legacy cache cleanup are gone.
- **Copy Text (OCR) did nothing.** The clipboard action routed on the value
  (which holds the entry id) instead of the action id, so it fell through
  silently. It copies the recognised text now, reports the character count, and
  records the text in Palette's own clipboard history (concealed copies never).
- Typing in a bound provider no longer blanks the list between keystrokes; the
  previous rows stay visible until the next results replace them, so `/neo`
  (and other process-backed searches) stop flickering.

## 2.18.1 — 2026-11-23

### Fixed

- The launcher window no longer shrinks and re-centres when the embedded terminal
  opens. Every mode keeps the same fixed frame (up to 60% of the display on each
  axis); the terminal is now inset inside that frame, 24 pt at the sides and 82%
  of the content height, instead of resizing the window.

## 2.18.0 — 2026-11-23

### Added

- **Provider groups in the rail, and Apps.** **Everything** and **Apps** stay
  pinned at the top; below them is one row per provider group and then one per
  ungrouped provider. A group row opens its first member and shows a secondary
  strip of its children above the list (in the top-bar layout too): Bitwarden —
  Passwords, Usernames, TOTP, Notes, URLs; GitHub — Overview, PRs, Issues,
  Actions, Notifications, Repositories. Apps opens the app list without a
  prefix and keeps filtering it while plain text is typed.
- **Nineteen Settings panes in four sidebar groups.** **Embedded Terminal**,
  **Bookmarks**, **Cheatsheets**, **Web Apps**, **Screenshots**, **After a
  capture**, **Recordings** and **Captures** each have their own pane;
  **About** moved under System, an **Advanced** section holds **Provider
  Files**, **Config Files** and **Diagnostics**, and the command prefix lives in
  **General**. The search index, per-pane resets and tab order follow, and the
  sidebar's collapse button is gone.
- **Recording asks first.** The recording hotkey, `/rec` and the menu all open
  a compact options panel — audio, microphone, display, region — that remembers
  the last choice. The status menu gains a capture section (**Start**,
  **Stop** with elapsed time, **Copy Last Path**, **Reveal Last Capture**,
  **Show Last Recording/Screenshot**), feedback always goes through one path
  (panel status when the launcher is open, otherwise a Notification Center
  banner plus a menu-bar flash), the launcher and HUD hide before the first
  frame, and one reusable preview window keeps its frame autosave and no longer
  hides when Palette deactivates, so **Show Last…** reopens the last capture.
- **Pinned screenshots.** **Pin** in the annotator (`⇧⌘P`), **Pin to Screen**
  on `/shots` rows and **Pin Last Screenshot** in the menu bar float the image
  above other apps and pass every click through until Option is held; Option
  shows the grip and enables drag, resize and scroll zoom. Pins cascade 24 pt
  from the last one, clamp to the screen under the pointer, cap at 8 (the
  oldest closes), and reuse the file already on disk.
- **On-device OCR and QR/link detection.** Vision text recognition (accurate,
  language correction) and QR/EAN/Code128 detection run locally on clipboard
  images, the last screenshot, pinned images and the annotator, with
  **Copy Text** and **Open Detected Link** wherever an image appears. `/ocr`
  turns the clipboard image (or a path) into rows that copy text, open a
  validated http(s) link, or search the web.
- **Learned ranking.** Palette remembers which row a short plain query led to
  and boosts it as a tie-breaker (at most +2.0, so a better text match still
  wins), so `chr` opens the Chrome you actually chose. Only a SHA-256 digest of
  the normalised 12-character prefix is stored, capped at 4 rows per prefix and
  400 prefixes; Settings → Search → Learning has the toggle and a confirmed
  **Forget**, and trigger and actions-mode activations are never recorded.
- **Clipboard ignore list.** `[clipboard] ignored_apps` names bundle ids whose
  copies are not recorded — password managers and token viewers that copy
  without marking the pasteboard. Concealed and transient pasteboard types
  still always win, so a marked copy is skipped even when the app is not
  listed. Settings → General → Clipboard → **Never record from** adds an
  installed or running app, or a typed bundle id, and removes it again.
- **Clipboard search is indexed.** The history is folded once into an in-memory
  snapshot that is rebuilt only when the store's clipboard revision moves (or
  after 60 s), the query scores that snapshot, and the displayed rows are
  fetched by id afterwards. At 5,000 short entries that is 2.9× faster and
  drops the full-text read from every keystroke.
- **Remote-desktop paste targets copy only.** RDC, Citrix, Parallels and
  Horizon turn a synthesised ⌘V into a literal `v`, so Palette writes the
  clipboard, says **Copied — paste with ⌘V**, and leaves the keystroke to you.
- **Rows say what is wrong.** A row that needs `devx`, `git`, `atlas`, `gh`,
  `bw` or Accessibility shows a warning glyph and the fix in its subtitle, the
  footer reads **Fix in Settings**, and Return opens the exact pane and card
  (missing tools, or Permissions) instead of failing silently. `⌘K` still lists
  the row's actions, and VoiceOver reads the trouble.
- **Update nudge.** Palette checks the GitHub releases page once a day (a failed
  check backs off 15 minutes, doubling up to the daily interval) and, when a
  newer version exists, shows one notification per version plus **Palette
  <version> available — Update…** and **Release notes** in the menu. Update runs
  `brew update && brew upgrade --cask palette` in the embedded terminal;
  Settings → General → **Updates** has the automatic toggle, **Check now** and
  the last-check time.
- **First-run tool prompts name the tap.** Missing tools offer the exact
  first-party formula (`brew install Myleshen/tap/devx`, `…/atlas`) and the
  Settings missing-tools card keeps the Enable/Disable answer. Indexing the
  whole home folder is opt-in, asked once (`[indexing] home_consent`), and skips
  Library and the standard user folders.
- **Window titles without Screen Recording.** When CG window names are
  unavailable, Palette reads the owning app's Accessibility titles and matches
  them by frame (2 pt), cached per pid for 5 s. Untitled windows keep distinct
  entries keyed by window number and fall back to `Untitled window · app · WxH`.
- **Web-app windows tile.** Web apps launch Chromium profiles with
  `--force-renderer-accessibility`, so Amethyst and other window managers can
  see and tile their windows.
- **The terminal ends, it does not freeze.** A finished session shows an end
  card with the exit code and **Restart** / **Close** in its own row, keeping
  the last output readable; Esc closes a finished session. Zellij attach
  recovers from a stale session once (shared by the embedded pane and `/zj`),
  and `/neo` and `/editor` launch neovide with `--fork` so each project gets its
  own instance; editors that can only reuse a window say so.
- **`⌘⌥S` opens the scratchpad list** with **New Scratch Note** first; a second
  press over a visible list closes it.
- **Focus zones.** `Tab`/`⇧Tab` walk search → list → rail → group strip and
  wrap, arrows act on the focused zone, Return confirms a rail or strip row and
  moves to the list, and Esc returns to search first. Tab never changes the
  provider.
- Config keys: `[updates] automatic`, `[search] learn`, `[indexing]
  home_consent`.

### Changed

- **One fixed panel geometry per display.** The frame is derived from the screen
  alone — at most 60% of each axis, an absolute cap only when smaller, and a
  usable floor on tiny displays — so result count, preview, rail and mode never
  resize it. The embedded terminal is 90% × 85% of that frame, centred;
  scratchpad and Ask keep the launcher frame; the provider rail is always
  220 pt and scrolls instead of collapsing; the preview takes space from the
  list card instead of the window.
- The Providers table shows a group label above each child and the group name is
  searchable; unselected rail chips no longer carry a filled background, and the
  group strip keeps a fixed height.
- Tests: `make test`, `make e2e` and `make layout-check` run at background QoS
  (`taskpolicy -b`, `nice -n 10`), every run gets its own temp config, state,
  cache and support directories, windows are presented without activation, and
  a scripted launch no longer asks for Accessibility. Timing-sensitive flows
  poll with `wait_until=` instead of sleeping. The Settings layout check now
  covers all 19 panes.

### Fixed

- **Worktree dialog.** Branch names are checked per keystroke against git's own
  rules, with the reason inline and **Create** disabled until it is valid; git
  remains the final authority. The prompt lays out at a fixed width, a created
  or failed worktree reports in the palette, and the project and git caches
  refresh immediately so `/proj` shows the new worktree.
- **One selection, and scrolling keeps it.** The focused zone gets a single
  accent ring instead of a second row painted like the selection, so only one
  row ever looks selected, and scrolling the result list no longer clears the
  selected row or its preview.
- **`/proj` no longer stalls.** Rows come from cache and never wait on git, the
  selected row's git preview is fetched after the list appears, git state is
  cached for 5 minutes behind a HEAD/index fingerprint, and project and clone
  changes invalidate the caches.
- **`/atlas` is cheap.** The parsed index is cached by `state.json` mtime and
  size, the review marker is read from an 8 KB head, and preview digests are
  built only for visible rows. `/atlas` and `/proj` filter through `fzf` on
  large lists. `/gh*` caches for 20 s and kills its child on a cancelled
  keystroke; `/shots` and `/cheat` cache listings for 5 s behind folder mtime.
- **Return pastes** for every text result: emoji (previously copied only),
  calculator results, clipboard transform output, and snippets, which gained a
  Paste action for the expanded text. Copy stays the second action everywhere,
  and rows now say "paste" in their subtitle.

### Removed

- Manual panel sizing: the Settings **Size** card, and `[window]` no longer
  reads `auto_size`, `scale`, `width`, `max_height`, `visible_rows`,
  `clipboard_width`, `preview_width` or `terminal_width`. Old files still parse
  and those keys are dropped on the next save; `preview_layout`, `provider_bar`
  and `favicons` remain.
- The Settings sidebar collapse button.

## 2.17.0 — 2026-11-22

### Added

- **State survives quitting.** A running timer resumes on relaunch (and says so
  once if it finished while Palette was closed), an in-progress recording is
  adopted, a pending clipboard clear is finished or re-armed, and the last Ask
  chat, its badge and interrupted answers come back with the window.
- **Clamshell and keep-awake are real across launches.** The caffeinate session
  and the clamshell flag are re-adopted at startup; the guard now has a 12-hour
  cap, re-arms on AC, disarms on battery, and an expired caffeinate session
  leaves the clamshell guard armed.
- **Config safety.** `config.toml` is backed up before every write as
  `config.toml.bak`, an unparseable file is refused instead of overwritten, and
  `[meta] config_version` migrates the old provider allowlist.
- **Hotkey availability in Settings.** Every global shortcut is planned in one
  ordered pass (built-ins, web apps, `[[binding]]`, catalogue) and registered
  transactionally; a key another app owns is reported on its row.
- **Backup now carries the whole state**: bookmarks, commands, snippets and the
  encrypted Ask key files, with plain-text clipboard history stripped and the
  database vacuumed.
- **Favicons for web apps** (async fetch, cached, toggleable), an icon cache
  size limit, an annotation text box, and tool-cache misses are retried on the
  next lookup.
- **About Palette, and a licence.** A proper About window (app menu) shows the
  version, build, commit, author and licence, with GitHub, Releases and Issues
  links plus **Copy Diagnostics**; the same lives in Settings → General, so the
  version is findable again. The build stamps the commit hash into the bundle,
  and Palette is now released under the **MIT licence**.
- Database retention for clipboard and Ask history, with periodic checkpointing.

### Changed

- The Settings window follows `config.toml` live and keeps the field you are
  typing in focused; theme picks are written to config instead of a side file.
- The annotator asks before closing with unsaved marks, and the scratchpad saves
  a draft on quit.
- Ask history entry was consolidated onto the Ask row (the `askh` alias is
  gone); reopening the window restores the last chat.
- Settings gained real terminal/terminal-app fields, an automatic terminal font
  size, and honest bookmark save failures.

### Fixed

- **Security:** child processes no longer inherit Palette's environment, Ask keys
  go through the Keychain wrapper, concealed copies are marked and cleared, web
  search carries a role plus SSRF guards, images and links are size-capped, and
  process-group kills reach helpers.
- **Correctness:** ⌘K no longer crashes when the list empties, chat/scratchpad
  loads cannot paint over newer state, a `200 {"error"}` reply falls through the
  model chain, and command ids, `gh` checkout paths, Docker, SSH and devx paths
  are fixed.
- Bookmarks refuse to overwrite a file they cannot parse, SSE streams truncate
  cleanly, the notification permission is re-read, and icons no longer leak.
- Twelve Settings defects: dropped or renamed web-search engines, duplicate
  engine/hotkey detection (modifier order), wrong terminal field, missing
  automatic font size, deleted themes shown as blank, browser auto-detect
  overwriting the choice, ignored bookmark save errors, and binding values that
  registered truncated while typing.

## 2.16.0 — 2026-11-22

### Added

- **Notification Center banners** for completed answers when Palette is in the
  background (permission is asked on the first post, not at launch). Timers use
  the same path.
- **Custom hotkeys** — `[[binding]]` entries in `config.toml` map any shortcut to
  an action: launch an app or path, run a shell command, open a provider, or open
  a URL. Managed in Settings → Shortcuts with the same recorder as the built-in
  hotkeys, and re-registered on reload.
- Onboarding lists the real screenshot shortcuts it will take and says they
  replace macOS's, and **Skip** now applies the Essentials set instead of leaving
  every provider enabled.
- Font pickers are dropdowns of installed families, with an Inherit option; a
  configured family that is no longer installed is shown as missing.
- Web search is on by default for new chats.

### Changed

- **Hammerspoon integration removed.** Web-app shortcuts have been Palette's own
  since 2.14.0; the generated `palette-webapps.lua` and the exporter are gone.

## 2.15.1 — 2026-11-22

### Changed

- Dependency updates: SwiftTerm 1.99.3, Yams 6.2.2, actions/checkout 7,
  actions/cache 6 and actions/attest-build-provenance 4. The bumped actions run
  on Node 24, so CI no longer emits Node 20 deprecation warnings.

### Fixed

- The build is warning-free again: unused results on the GitHub open-URL and
  annotator drag/save paths, an unused Docker status field, a non-Sendable
  stream callback, and a test lock taken from an async context are cleaned up.
- `NSApp.activate(ignoringOtherApps:)` replaced with `NSApp.activate()` on
  macOS 14, where the old call is deprecated.

## 2.15.0 — 2026-11-22

### Added

- **Ask is a chat.** ⌘⌥A opens a real conversation window with token streaming,
  multi-turn context, a saved-chats sidebar that survives relaunches, and Stop.
  Closing the window no longer cancels: the answer finishes in the background,
  the Dock badge appears, and the sound plays when it lands.
- **Markdown answers** — headings, lists, quotes, links, fenced code with a Copy
  button, GFM tables, and images (https only), all selectable and theme-styled.
- **Web search** — an optional single search per turn (DuckDuckGo), with the
  fetched pages injected as untrusted context and a numbered Sources list.
- **NVIDIA NIM endpoint** alongside OpenCode Go: 16 free chat models, key from
  `NVIDIA_API_KEY` or the Settings key field, fallback only to endpoints that
  have a key.
- **GitHub providers** — `ghr` repositories (clone into `~/dev` via devx),
  `ghp` pull requests (authored / review requested), `ghi` issues, `gha` Actions
  runs (view log, re-run, cancel) and `ghn` notifications.
- **`/proj` can start work** — clone a repository through `devx project clone`,
  or create a new project directory and register it.
- **Provider rail** — a full-height left rail listing every provider, with
  Everything pinned on top; it narrows to icons when the preview pane is open or
  the panel is tight.

### Changed

- **Settings is rebuilt**: 12 panes folded into 7 (General, Launcher, Appearance,
  Shortcuts, Search, Ask, Providers), auto-applied instead of Save/Cancel, one
  left-aligned 640pt column, ⌘F search across panes, section-scoped resets, file
  pickers instead of typed paths, and an inline error instead of a silent revert.
- Theme contrast is measured and enforced: accent, selection, badge and muted
  pairs must clear their thresholds, and failing pairs are corrected
  (Gruvbox Light 3.3 → 5.0, Siri Silver 3.7 → 5.1).
- CI caches per job and per commit; the end-to-end job dropped from ~7 min to
  under 2.

### Fixed

- `/gh` works outside a git repository instead of claiming auth was broken.
- Confirm dialogs show each provider's warning instead of "cannot be undone".
- `/recent` opens the file, not Neovide; `/stats cpu` and `/stats ram` work.
- `/proj`, `/recent` and `/git` previews show real information (or nothing)
  instead of repeating the row.
- Copies confirm with a status; `/scratch` deletes ask first; `/zj` no longer
  creates a session on Enter; `/theme` shows the active theme.
- The footer bar, cards and gaps share one spacing scale, and the panel never
  paints a transparent footer.

## 2.14.0 — 2026-11-21

### Added

- `/ask` opens a dedicated answer window: one question, one answer, with an
  "Asking <model>…" state, a selectable answer, Copy, Ask Again and a model
  picker. Cancel (or Esc) stops a request in flight without recording it.
  Still single-shot — no sessions.
- The ask model list now mirrors the live OpenCode Go endpoint: all 31 models,
  including Grok 4.7, GPT-6 Luna, Claude Haiku 5.5, Qwen4 Max and Hy4.
- Web app shortcuts are registered by Palette itself, so ⌃⌥F opens your web app
  directly without Hammerspoon; the generated Lua file no longer binds keys.
- The launcher and the answer window stay open together: the answer docks 12pt
  under the panel, so you can keep searching while it loads.
- A sound plays when an answer arrives, plus a Dock bounce when Palette is in the
  background. Toggle in Settings → Ask (`[ask] notify`, default on).

### Fixed

- `/atlas <query>` now filters the index fuzzily instead of listing everything.
- Marking an Atlas document reviewed no longer closes the launcher.
- `/bookmark <text>` now filters with the same fuzzy matcher as every other
  provider (it was ignoring the typed text).
- "Mark Reviewed" clears the review badge: the inbox now follows atlas's own
  rule (only files that still carry the marker), instead of treating every
  artifact as unreviewed forever.
- ⌘Q with the launcher open dismisses it instead of quitting the app, so a stray
  ⌘Q no longer leaves you without a launcher when Spotlight is disabled. A
  second ⌘Q quits, and logout/shutdown are never blocked.

### Changed

- CI caches build products keyed on the Swift toolchain version and only
  collects coverage on `main`, so warm PR runs finish in minutes.

## 2.13.1 — 2026-11-21

### Fixed

- Switching between the scratchpad, the ask panel and the terminal now closes the
  other one instead of overlaying (e.g. ⌘S then ⌘A no longer leaves the scratchpad
  on top of the ask panel).
- An empty model reply (e.g. the Hy3 model) now falls back to the next model, and a
  reasoning-only reply is used instead of discarded.
- `/ask` `max_tokens` defaults to 8192 so answers are no longer truncated.

## 2.13.0 — 2026-11-21

### Changed

- **Default (unprefixed) search is now an allowlist** — `[providers] global` lists
  exactly which providers answer a plain query (`apps` always does), with a
  **Default** checkbox per provider in the Providers table (add *and* remove, e.g.
  drop `calc`). Existing additive configs migrate to the full default set (now
  includes `cheat`).
- **Friendlier web-search engine editor** — each engine is a labelled card
  (Name · Search URL · `!keyword` · Browser · Open in web app).

### Added

- **`app_mode` for `!` bangs** — "Open in web app" opens the search in the
  SSB/web-app (Chromium) instead of a browser tab.

### Fixed

- **`/ask` reliability** — request timeout raised to 120 s with a 130 s deadline
  and a dedicated session, models fall back on a timeout, `max_tokens` default
  2048 with truncation flagged, "Ask Again" really re-asks, failures are
  persisted and logged, the progress status persists, and the stale `glm-5.2`
  model is gone.
- **macOS UI/HIG pass** — Settings window minimum size, fullscreen and position
  autosave; right-click context menus on launcher rows; save errors are shown
  instead of silently discarding; readable Providers table (`Show`/`Order`
  headers); `.labelsHidden()` engine fields; result-row accessibility plus a
  Reduce Motion guard; Window and Help menus; better scoped empty state;
  accessibility labels on icon buttons; `⌘⇧3`-style shortcut display.

## 2.12.1 — 2026-11-21

### Fixed

- The Atlas provider is now `/atlas`-only instead of participating in the
  unprefixed/global search, so a plain query like `settings` no longer surfaces
  Atlas artifacts. Under `/atlas` it still shows the document preview; Enter opens
  the artifact and "Mark Reviewed" stays in the ⌘K menu.

## 2.12.0 — 2026-11-21

### Added

- **Atlas provider** — native `/atlas` (and global) search over the `atlas` index:
  artifacts and docs with `project · path`, an inbox "review" badge, a document
  preview, and a "Mark reviewed" action that runs `atlas review <path>`.
- **Adaptive preview layout** (`preview_layout = "auto"`, the default) — beside on
  wide screens, below on narrow/portrait ones.
- **Providers table** — the Providers settings tab is now a single table per
  provider (enable · name · trigger · aliases · order) instead of three sections.
- **Debug build workflow** — `make debug-app` builds a separate `Palette Debug.app`
  (own bundle id + isolated config) and launches it via LaunchServices.

### Fixed

- **Portrait-screen clipping** — the launcher panel width is clamped to the screen,
  so the preview pane no longer runs off the right edge of a narrow display.
- The Terminal settings tab is no longer last in the sidebar.

### Changed

- `preview_layout` accepts `auto` (the default); `beside`/`below` remain explicit.

## 2.11.1 — 2026-11-21

### Fixed

- Provider "setup" and "empty" rows no longer leak into global search. A plain
  query such as `settings` no longer shows "Set up cheatsheets" or other
  install/setup hints from providers that aren't in scope; those rows now appear
  only inside their own `/trigger` scope. Affects Cheatsheets, Zellij, paths
  (`fd`/`fzf`), snippets, commands and captures.

## 2.11.0 — 2026-11-21

### Added

- **Cheatsheets / Reference** — a `cheat` provider lists PDF, HTML, Markdown,
  text and image files from folders you configure (Settings → Cheatsheets) and
  previews them in the launcher via QuickLook; press ⌥P to enlarge.
- **`/ssh` in the embedded terminal** — SSH hosts run `ssh <alias>` in your shell
  inside the embedded terminal, each in its own session, so re-running reattaches
  to the same connection. The external terminal stays as a secondary action.
- **`/shots` "Paste image"** — a new ⌘K action pastes the selected screenshot into
  the previously-focused app.

### Changed

- The preview pane's ⌥P enlarge now actually resizes (beside pane up to 640 pt).
- New **Cheatsheets** Settings tab (folder + extension config).

### Security

- **GitHub release hardening**: tags-only release workflow (no `workflow_dispatch`),
  a "tag must be on `main`" check, SHA-pinned actions, build provenance + a
  `SHA256SUMS` asset, draft-first publish, and a post-release smoke job.
- Server-side: immutable `v*` tag ruleset, a `release` environment restricted to
  `v*` tags, immutable releases, a GitHub-owned-only action allowlist with SHA
  pinning, and Dependabot alerts / security updates / private vulnerability
  reporting enabled.
- CI now builds `main` pushes with a timeout, concurrency and a SwiftPM cache.

## 2.10.0 — 2026-11-21

### Added

- **Terminal settings tab** — the embedded-terminal session, shell and font
  settings moved out of General into their own Terminal tab.
- **Universal default search** — a plain query can search a configurable set of
  providers in addition to the built-in ones. `[providers] global` controls it
  (default: `system`, `timer`, `awake`), with a "Search without a prefix"
  multi-select in Settings → Search. Calculator already participates.
- **E2E harness + coverage** — `PALETTE_SCRIPT` gained `dump=`, `assert=` and
  `wait_until=` with a non-zero exit on failure, plus script-mode isolation (no
  global hotkeys or clipboard monitor). `make e2e` runs the flow suite; CI
  reports coverage and runs an E2E job.

### Fixed

- **Screenshotting the launcher** — a screenshot hotkey no longer dismisses the
  open launcher; it stays visible and is captured. Captures suppress auto-hide
  and re-focus the panel afterwards.
- **Empty-query position** — closing and reopening the launcher resets to the top
  instead of restoring the previous row/scroll position.
- **`/neo` `/edit` first-launch speed** — the path enumeration is cached to disk,
  de-duplicated in flight and prewarmed at launch, and the path debounce was
  raised, cutting the first `/edit` from ~3.5 s to milliseconds once warm.

## 2.9.0 — 2026-11-21

### Changed

- **New default themes**: Siri Silver (light) and Siri Graphite (dark) — silvery
  surfaces with a Siri blue/purple accent. These are only the defaults; built-in
  and user `themes/*.toml` themes still work and can be picked in Appearance.
- **Liquid Glass everywhere**: the launcher card, search bar, prompt, scratchpad,
  preview, screenshot HUD, annotator and media-preview chrome use the system glass
  effect on macOS 26+, with the existing material below 26.
- **Honours system preferences**: glass falls back to an opaque fill when Reduce
  Transparency is on, and gains a contrast stroke when Increase Contrast is on;
  the macOS glass-intensity setting is applied by the system itself.
- **The theme reaches every window**: Onboarding, the screenshot HUD, annotator and
  media preview follow the theme's light/dark appearance and palette (media
  canvases stay neutral); the status-bar and main menus follow the theme light/dark.
- **Launcher footer** is a live primary-action pill: it shows what Enter will do
  on the selected row (e.g. the primary action title) next to "Actions ⌘K",
  replacing the six static hints (which now live in the ⌘K keyboard reference).

### Fixed

- The annotator's selection outline stays neutral white so it reads over any image.

## 2.8.0 — 2026-11-21

### Changed

- **Settings reorganized into 10 focused tabs** — General, Launcher, Appearance,
  Shortcuts, Clipboard, Search, Capture, Ask, Providers, Advanced — with duplicate
  controls removed and clearer section labels and footers.
- **Every input now reads as editable**: text fields have a visible bezel, and
  every numeric control is an editable value field paired with stepper arrows
  (with units such as `pt`, `%`, `s`, `ms`, `days`).
- **Settings sidebar** groups the tabs (General / Features / System) and gives each
  a tinted icon tile; the window keeps a native titlebar band.
- **Settings search jumps to the matched row** and briefly highlights it, instead
  of only switching tabs.
- **Search ranking** uses tier bands (exact > prefix > word-start > substring >
  subsequence) with word-start and run bonuses.
- **Launcher rows** show a hover highlight only after the pointer actually moves
  (3 pt), and the selection always outranks hover.
- **⌘K** includes a keyboard reference section.
- Capture and timer settings moved out of the Providers tab; `Show provider tabs`
  moved to the top of the Launcher tab.

### Fixed

- Empty states now suggest a next step ("Try a different spelling, or press ⌘, to
  enable more sources") instead of a bare "No results".
- Existing configs now pick up the default bang keywords (`!g`, `!ddg`, `!gh`,
  `!yt`) on load, so `!` works after upgrading without pressing Restore Defaults.
- Typing `!` when no engine has a keyword shows "No bangs configured" with a hint,
  instead of a bare "No results".

## 2.7.0 — 2026-11-17

### Added

- **Provider-tab toggle**: `[window] show_tabs` hides the chip strip above the
  launcher list; `/trigger` commands and Tab cycling still work.
- **Bookmarks**: `bookmarks.toml` entries that open a URL in a chosen browser as
  a normal window (not the `/webapp` app mode). Managed in Settings → Search →
  Bookmarks.
- **`!` bangs**: `!keyword query` searches a configured engine (keyword, URL
  template, and browser) straight from the launcher; `!` alone lists available
  bangs.
- **Microphone picker** for recordings (`screencapture -G`), alongside the
  system default input.
- **Thumbnails in `/shots` rows**, reusing the existing preview cache.

### Fixed

- Hidden provider tabs no longer leave a stray separator line at the top of the
  launcher card.

## 2.6.0 — 2026-11-16

### Added

- **Pointer tool** in the annotator, now the default: click a mark to select it
  (dashed outline), drag to move, `delete` to remove. Drawing tools no longer
  grab a mark that happens to sit under the cursor.
- **Text size** for new text, with an `Aa` stepper while the text tool is active.
- `[capture] gallery = "all" | "palette"` and a Settings picker, so `/shots` can
  list only Palette's own captures instead of everything in the folder.
- `make layout-check`: renders all eight Settings sections and fails when one
  drifts more than 2% from `Tests/Snapshots/`. Re-introducing the old clipped
  shortcut row produces a 14.30% diff.

### Fixed

- The Dock icon stayed after the annotator or player closed: the accessory
  policy was derived by scanning every visible window, so the launcher panel,
  the capture HUD or Settings counted as "still editing". The policy now follows
  only real editor and preview windows.
- The setup window had a blank title bar (clear background plus a transparent
  bar); it is opaque with a normal title bar.
- Documentation covers uninstalling (`--zap` and the two `tccutil` resets) and
  the one-time `brew trust` step. Docs are Markdown again, as GitHub does not
  render HTML files.

## 2.4.1 — 2026-11-15

### Added

- **Captures** provider (`/shots`): every screenshot and recording in the capture directory, newest first, grouped by day, with a thumbnail preview (a poster frame for videos), open, annotate, copy image and reveal in Finder.
- A shutter sound and a brief thumbnail after every capture, so a screenshot never looks like nothing happened. Both toggle in Settings → Capture.

## 2.4.0 — 2026-11-15

### Added

- **Universal capture shortcuts** that replace the system ones: `⌘⇧3` full screen, `⌘⇧4` region, `⌘⇧6` window, `⌘⇧5` recording. All four are rebindable in the new **Shortcuts** tab in Settings.
- **Recording targets**: record the whole screen, one display, or a fixed region, with optional audio (`-g`). `/rec` lists every active display by name and size.
- **Annotate** window for screenshots: arrow, rectangle, text and crop, six colours, a line-width slider, undo, copy, and save over the original. `/shot` gains "capture and annotate" rows, and `[capture] edit_after_capture` opens the editor after every screenshot.
- **Recording preview**: a player window with scrub, reveal and copy path when a recording stops (`[capture] preview_recording`, on by default).

### Fixed

- The editor drew a light border and title bar around the image, and Done closed the window without saving; the window is now a dark floating card that saves on Done and closes after Save/Copy with a confirmation toast.
- The editor and the recording player are floating panels excluded from tiling window managers, so Amethyst no longer stretches them across the screen.
- Capture shortcuts that are already owned by another app (Shottr, Raycast) now say so instead of failing silently; every capture shortcut can be rebound or cleared in Settings → Shortcuts.
- Provider tabs, clipboard filter chips, mode chips and footer hints ignored the theme's `typography.ui_family`; they now use it like the rest of the UI.

## 2.3.4 — 2026-11-15

### Added

- Global shortcuts for **Screenshot** (`⌘⌥⇧S`) and **Recording** (`⌘⌥⇧R`), configurable in Settings → Shortcuts. While recording, the menu bar shows a live **Stop recording · m:ss** item.
- **Screenshot** (`/shot`) and **Recording** (`/rec`) through the system capture engine: full screen, region, or window; configurable directory, format, action (save/copy/save-and-copy/preview), delay, cursor and click indicators. Failures report the capture error instead of returning nothing.
- **Window switcher** (`/win`): every open window, keyboard-first, raises the selected window through the accessibility API.
- **Colour picker** (`/color`): system sampler, copies the hex value, keeps recent picks.
- **Convert** (`/unit`): length, mass, volume, data and temperature offline; currency through a one-hour cached rate table.
- **System stats** (`/stats`): disk, memory, load, battery and uptime.
- **SSH** (`/ssh`): hosts from `~/.ssh/config`, opened in the configured terminal.
- **Docker** (`/docker`): containers with start/stop/restart and following logs.
- **GitHub** (`/gh`): pull requests and issues via the `gh` CLI, with a clear prompt when auth is missing.
- **Timers** provider (`/timer`): `25m`, `1h30m`, `1:30`, presets from `[timer] presets`, one timer at a time, a live countdown in the row, a chime and a notification when it finishes. Toggle sound/notification in Settings → Providers → Timers.

### Fixed

- Clamshell mode could report "on" while nothing kept the lid awake: a leftover flag made the guard look armed, and the root guard was a background shell that died with the authorisation session. It now runs as a launchd daemon, verifies `pmset` really reports `SleepDisabled 1`, re-checks after arming, and warns if it stops. The installer asked for a password and then failed because it called `/bin/chown`, which does not exist; it now uses `/usr/sbin/chown`.
- Provider tabs wrap instead of clipping the last chip at the card edge, and the panel height follows the wrapped strip.
- A capture that fails because Screen Recording is not granted now says so, in the log and on screen, instead of finishing silently.

## 2.3.3 — 2026-11-14

### Changed

- Panel sizing moved out of themes and into `config.toml` under `[window]`: `scale`, `width`, `max_height`, `visible_rows`, and per-view widths for clipboard, Ask, preview, terminal, and scratchpad. Themes now cover colours, fonts, and typography only.
- `scale` is a rem-style multiplier (0.8-1.6) over every default size. Explicit `width` / `visible_rows` / per-view widths win over it, and `0` means "default times scale".
- Settings → General → Launcher gained **Width** and **Scale** steppers next to **Visible rows**.

### Added

- The launcher sizes itself to the screen under the cursor. Landscape screens get a 45% column (620-980 pt), portrait screens get most of the width, and the row count follows screen height (5-10). Explicit `width` / `visible_rows` still win; set `[window] auto_size = false` to pin one size. Clipboard, Ask, preview, terminal, and scratchpad widths keep the panel's proportions.

### Added

- Clipboard/Ask preview can sit **below** the list instead of beside it: `[window] preview_layout = "beside" | "below"`, also a picker in Settings. Beside stays the default; below suits narrow and portrait screens.

### Fixed

- Typing while the action list is open (⌘K) now filters the actions instead of re-running the search; the owning item is remembered so Enter still runs the action, and the original query is restored when you leave the list.

- The clipboard preview pane and its divider now have real padding: scrollbars no longer sit flush on the divider or the card edge.

- Theme files that set `[window] width` or `max_height` no longer resize the panel; sizing is config-only. `visible_rows` at the config root (2.3.2) still maps into `[window]`.

## 2.3.2 — 2026-11-06

### Changed

- The launcher and Settings now use real behind-window liquid-glass materials instead of only SwiftUI color overlays. Glass is applied per surface, Settings has a transparent window backdrop, and the launcher/Settings edges use theme-tinted specular highlights.
- Removed the full-panel blur view behind the launcher. It painted a tinted rounded rectangle in the inset around the cards, which read as a background halo, most visibly on light themes.
- The launcher footer also sits on a glass strip.
- Glass treatment now covers result-row and action-row selection, prompts, the clipboard preview pane, scratchpad chrome, and onboarding, not just the main cards.
- Only the outer card carries a glass layer. Prompts, the preview pane, the scratchpad, the footer, and the tab strip use plain theme tints, so they no longer stack into darker or lighter bands.
- `glass_opacity` defaults to 0.7: enough theme colour to tell Catppuccin from Aetheria, still translucent over the desktop.
- Settings uses a full-size content view with a transparent titlebar, so the glass reaches the top of the window and the window drags from its background.
- The launcher panel no longer grows past the screen: the SwiftUI host no longer resizes the window, height is clamped to the visible screen area, and long lists scroll inside it.
- Panel height is driven by a row count instead of per-view chrome: Settings → General → Launcher has a **Visible rows** stepper (5-10, default 7, also `visible_rows` in config.toml or `[list] visible_rows` in a theme). That count is the panel's fixed height, so it neither grows with a long list nor shrinks with a short one.
- Settings shows the tab bar above the search field, so tabs stay visible while searching.
- The Settings titlebar keeps AppKit's native window drag and is tinted with the theme background instead of a transparent, undraggable strip.
- Themes can control the effect with `[window] glass` and `glass_opacity`; `glass = false` keeps an opaque surface.

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

### Verified

- Settings and launcher full-screen screenshots show the desktop blurred behind the glass rather than an opaque card.
- `swift test`: 81 tests, 0 failures.

## 2.3.1 — 2026-11-06

### Changed

- Settings uses a custom horizontal, scrollable tab bar again, so every section is visible and directly clickable instead of collapsing into a hamburger menu.
- Settings is wider (780 pt) to fit the tab bar and forms comfortably.
- Added theme-driven liquid-glass surfaces to the launcher search field, result card, and Settings. Themes can set `[window] glass` and `glass_opacity`; setting `glass = false` keeps the opaque surface.

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

### Verified

- Settings screenshot shows General through Advanced as direct tab buttons.
- Launcher and Settings screenshots show the translucent material with the active theme tint.
- `swift test`: 81 tests, 0 failures.
## 2.3.0 — 2026-11-06

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

### Verified

- `swift test`: 81 tests, 0 failures.
- `/edit` and the `/neo` alias both resolve a file in the Editor tab; the
  Editor group shows Editor/Folders sub-tabs.
- Settings → Defaults shows the editor, terminal, browser, theme, and Ask model,
  with Detect Installed Apps and Reset App and Theme Defaults.
- Onboarding Step 2 shows the Essentials/Developer/Everything presets, Back,
  and Finish.

## 2.2.3 — 2026-11-06

### Changed

- Releases run from a `v*` tag now. CI runs the tests, builds
  `Palette-<version>.zip`, publishes the release with this entry as the notes,
  and moves the Homebrew cask, instead of the local `make release` ritual.

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

### Verified

- `swift test`: 81 tests, 0 failures.
- The `build` CI job is green on the release pull request.
- `Resources/Info.plist` and the tag agree, or the release job refuses to run.

## 2.2.2 — 2026-11-06

### Added

- **Keep Awake** controls in Settings → General, with ON/OFF toggles for
  **Keep Mac Awake** and **Clamshell Mode (Lid Closed)**. Both reflect the live
  service state and can be changed without leaving Settings.

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

### Verified

- `swift test`: 69 tests, 0 failures.
- Empty-query snapshot shows the two-surface pill layout with no classic branch.

## 1.9.4 — 2026-11-04

### Changed

- Added per-provider enable/disable controls in Settings → Advanced. Disabled
  providers disappear from the tab bar, Tab cycling, and trigger parsing.
  `[providers] disabled = ["port"]` stores the same choice in config.toml.

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

### Verified

- `swift test`: 69 tests, 0 failures.
- Registry test confirms a disabled provider is absent from tabs and its
  trigger falls back to global search.

## 1.9.2 — 2026-11-03

### Fixed

- Finder-launched Palette now prepends Homebrew, `/usr/local`, and MacPorts
  paths to its child environment, so devx, Bitwarden, Zellij, and workspace
  tools resolve even though launchd starts apps with a minimal `PATH`.

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

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

### Fixed

- Keep Awake → **Open Battery Settings** did nothing: the launcher's URL allowlist rejected the `x-apple.systempreferences` scheme, so the deep link was dropped with only a log line.

### Verified

- `swift test`: 21 tests, 0 failures.
- Homebrew zip builds and its checksum matches the Cask.
- Live synthetic-key runs: calculator copy, clipboard capture, action overlay,
  theme switching, `/neof`, `/zj` create row, and Accessibility paste fallback.
- Final bundle installed at `~/Applications/Palette.app` (ad-hoc signed).
