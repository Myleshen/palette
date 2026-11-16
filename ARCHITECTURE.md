# Architecture

## 1. What Palette is

A native macOS launcher in the Raycast / Noctalia / rofi class. One process, one
window, keyboard-first. The host owns search, ranking, clipboard, paste, and
launching. Providers are split into two lanes:

- **Bundled providers** for the opinionated core: apps, paths, calculator,
  clipboard, system, zellij, Bitwarden, themes.
- **External providers** discovered at runtime from `~/.config/palette/providers`,
  written in any language, speaking a documented JSON protocol.

Extensibility is a product requirement, not a plugin afterthought. The mistake
this design avoids is implementing core features by shelling out to a pile of
`list`/`act` scripts. Core behavior is native; the external lane exists for
everything the user wants to add.

Non-goals for v1: App Store distribution, sandboxing, a plugin UI protocol,
sync, AI, window management, theme marketplaces.

## 2. Stack and process model

- Swift 6.4 toolchain, Swift 5 language mode, macOS 14+ deployment target.
- AppKit owns the app lifecycle, `NSPanel`, global hotkey, focus, and key
  handling. SwiftUI renders the launcher contents.
- SwiftPM executable + a `make app` step that assembles `Palette.app`, writes
  `Info.plist`, and ad-hoc signs it. No Xcode project to keep in sync.
- `LSUIElement = true`: menu bar and `⌥Space`, no Dock icon.
- No IPC between UI and core; everything is in one process except external
  providers, which are supervised child processes.

Rationale for no in-process plugin loading: Swift has no stable ABI, a crashing
plugin would take the launcher down, and signing becomes fragile. Out-of-process
providers also make the extension API language-agnostic, which is what makes
rofi and wofi-style ecosystems work.

## 3. Modules

```
PaletteCore        no AppKit/SwiftUI
  models, query parser, ranking, frecency, calculator, scope matching,
  config + theme loading, storage contracts, provider protocols

PalettePlatform    macOS services
  hotkey, panel controller, pasteboard + clipboard monitor, fd enumeration,
  fzf ranking, process runner, tool locator, app/file icons, launching,
  SQLite store, permission checks

PaletteProviders   bundled providers
  apps, paths (/neo, /neof), calculator, clipboard, system, zellij,
  bitwarden, themes

PaletteRuntime     external providers
  manifest discovery, NDJSON codec, process supervision, registry

PaletteApp         shell
  AppDelegate, SearchCoordinator, SwiftUI views, prompt sheets, menu bar
```

Dependency direction:

```
PaletteApp → PaletteRuntime → PaletteProviders → PalettePlatform → PaletteCore
```

Providers depend on narrow service protocols (`FileEnumerating`,
`FuzzyRanking`, `Pasteboarding`, `Launching`, `Storing`) declared in Core, so
they can be tested with fakes.

## 4. Filesystem layout

| Purpose | Path | Notes |
|---|---|---|
| Config | `$XDG_CONFIG_HOME/palette` or `~/.config/palette` | hand-edited, dotfile-friendly |
| Providers | `…/palette/providers/<id>/` | user providers override bundled by `id` |
| Themes | `…/palette/themes/*.toml` | native theme files |
| State | `$XDG_STATE_HOME/palette` or `~/.local/state/palette` | SQLite, logs |
| Cache | `~/Library/Caches/Palette` | icons, thumbnails; disposable |
| Bundled providers | `Palette.app/Contents/Resources/Providers/` | read-only |
| Bundled themes | `Palette.app/Contents/Resources/Themes/` | read-only |

On first run the app writes a commented `config.toml`, seeds the bundled `neo`
provider into the user directory when absent, and copies `neof` from the bundled
examples. Nothing overwrites a user file.

## 5. Startup

1. Create directories, open SQLite, run migrations.
2. Load `config.toml` (defaults on missing keys, diagnostics on invalid ones).
3. Resolve the active theme (including `extends` chains) and keep the last good
   theme on failure.
4. Discover providers: bundled manifests, then user manifests by `id`.
5. Register the Carbon hotkey. Failure is reported, not fatal.
6. Warm background work: app index, clipboard poller, path caches.

The panel is built lazily on first show.

## 6. Query lifecycle

```
keystroke
  → debounce 30–40 ms (path providers; zero for prefix-bound immediate queries)
  → parse: trigger prefix? expression? plain terms?
  → generation += 1, cancel the previous task group
  → route:
       bound provider  → one provider, remainder as query
       plain query     → global providers + apps + commands, parallel
  → stream results, merge, rank, publish
  → preserve selection by stable item id
```

Rules:

- A prefix matches `provider_prefix + trigger` only when followed by a space or
  end of input, and triggers are matched longest-first. Absolute paths therefore
  never collide because triggers are bare words and the shared prefix is `/`.
- Changing the shared prefix character moves every provider at once. Duplicate
  triggers are a config warning; the first wins deterministically by `id`.
- No provider may block the list. Each gets a deadline and a result cap.
- `Esc` clears a non-empty query before dismissing.

## 7. Providers

### 7.1 Native providers

Compiled in, `@MainActor` where they touch UI services. They return the same
`PaletteItem` model as everything else.

### 7.2 Paths providers

Declarative manifests with `engine = "paths"`. The host runs:

```
fd --hidden --no-ignore --print0 --max-depth N --exclude … --type d|f .
```

with `cwd` at each scope root, then ranks with:

```
fzf --filter "<query>" --scheme=path --read0 --print0
```

NUL framing keeps odd filenames safe. `fd` was measured at 0.05 s for 37k
entries versus 0.75 s for `FileManager.enumerator`; enumeration is cached per
scope and invalidated by FSEvents plus a TTL. A full re-walk is cheap enough
that v1 has no persisted path index.

Scopes apply allow lists (`roots`) and gitignore-style excludes during
enumeration and again in-process (for `!` re-includes). Defaults exclude
`node_modules`, `.git`, build outputs, packages, and `Library`.

### 7.3 External providers

Any executable speaking NDJSON on stdin/stdout. Long-lived, lazy-started, idle
exited, restarted with backoff. Full protocol in [PROVIDERS.md](PROVIDERS.md).

## 8. Ranking and frecency

- Path results: fzf's score and order, `--scheme=path`.
- Apps and commands: tiered match (exact, prefix, word-boundary, substring,
  subsequence) on title, keywords, and subtitle.
- Global merge: base match score plus `0.30 * log1p(uses)` plus a recency boost
  with a 30-day half-life. Stable tie-break by provider priority then title.
- Every result has a stable id: `<provider-id>:<item-id>`. Frecency is keyed on
  it, so updates and streamed results never move the selection.
- Caps: 8 per provider in global search, 50 in bound mode.

## 9. Storage

SQLite via the system library, one actor, WAL mode.

```sql
items(id TEXT PRIMARY KEY, provider TEXT, uses INTEGER, last_used REAL);
clipboard(id TEXT PRIMARY KEY, hash TEXT UNIQUE, text TEXT, created REAL,
          pinned INTEGER DEFAULT 0);
meta(key TEXT PRIMARY KEY, value TEXT);
```

Clipboard cap is enforced after insert. Text only in v1; images are a roadmap
item. Frecency and clipboard writes happen off the main actor.

## 10. Clipboard and paste

- Poll `NSPasteboard.general.changeCount` every 500 ms.
- Ignore `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, and
  empty content.
- Deduplicate by SHA-256. Cap at `max_entries`.
- `copyText` writes the pasteboard; with `concealed` it also marks the item so
  Palette's own history skips it.
- `pasteText`: remember the previously frontmost app, hide the panel, reactivate
  that app, write the pasteboard, synthesize `⌘V` via `CGEvent` after a short
  delay. Requires Accessibility; without it the action degrades to copy and
  shows a hint.
- Copies from Bitwarden use a 30 s auto-clear timer.

## 11. Permissions

| Capability | Requirement |
|---|---|
| Hotkey, apps, paths, calculator, themes | none |
| Paste into another app, window actions | Accessibility |
| Lock screen / logout via System Events | Automation |
| Empty Trash via Finder | Automation |

Accessibility is requested only when the user first triggers a paste, never at
launch. Ad-hoc signing means the grant can reset after a rebuild; the app
detects this and re-prompts.

## 12. Tool resolution

GUI processes do not inherit the shell `PATH`. `ToolLocator` probes the inherited
`PATH`, then `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, and an
optional `tools_path` config entry, caching results. `fd`, `fzf`, `bw`,
`zellij`, `kitty`, and `open` all go through it.

## 13. Concurrency

- UI and view models: `@MainActor`.
- Search: one `Task` per generation; providers are `Sendable` and cancellation-
  aware. Process-backed work kills the child on cancellation.
- Storage: dedicated actor.
- Clipboard polling: background queue, hops to storage.
- No locks in provider code; shared mutable state is confined to actors.

## 14. Packaging

```
make            # swift build -c release, assemble .app, ad-hoc sign
make install    # copy to ~/Applications
make run        # build + install + open
make test       # swift test
```

`Palette.app/Contents/Info.plist` sets `LSUIElement`, `CFBundleIdentifier
dev.myleshen.palette`, `NSHighResolutionCapable`, and the minimum system version.
The app is re-signed with `codesign --force --deep --sign -` after every build.

## 15. Testing strategy

- Pure unit tests for parsing, ranking, theme merge, scope globs, calculator,
  protocol codec, and frecency.
- A provider conformance harness that runs the example external provider and
  asserts query/result/activate round-trips.
- An app-level smoke test that launches the built bundle, verifies the hotkey
  registers, opens the panel, types, and reads a screenshot.
- Manual checklist in [TESTING.md](TESTING.md) for permission and paste paths.

## 16. Roadmap after v1

- Wallpaper-derived palettes and theme export templates (kitty, Neovide, zellij).
- Persistent path index and incremental FSEvents updates.
- Image clipboard entries.
- Grid layout, pinned items, snippets.
- Window management via the Accessibility API.
- Provider trust prompts and content hashes.
- Optional native plugin lane behind the same model, if out-of-process latency
  ever becomes a problem.
