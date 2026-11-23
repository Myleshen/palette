# Providers

A provider turns a query into rows and knows what to do when one is chosen.
There are two kinds:

1. **Paths providers** — a TOML manifest backed by the built-in `fd` + `fzf`
   engine. No code.
2. **Command providers** — any executable speaking newline-delimited JSON over
   stdin/stdout.

Both are discovered from `~/.config/palette/providers/<id>/provider.toml`.
Bundled providers ship inside the app; a user provider with the same `id`
overrides the bundled one.

## 1. Manifest

```toml
id = "neof"                    # required, stable, [a-z0-9._-]
name = "Editor folders"        # display name
trigger = "editf"              # bare word; invoked as /editf
global = false                 # ambient; plain search follows [providers] global
icon = "symbol:doc.text"       # default icon for rows without one
keywords = ["file", "neo"]     # extra match terms
priority = 10                  # tie-break, higher first

# one of:
engine = "paths"               # built-in file engine
# command = ["./provider.py"]  # external process (argv, no shell)

timeout_ms = 1200              # per query
idle_timeout_s = 300           # external providers only
```

`trigger` is appended to the shared `provider_prefix` from `config.toml`
(default `/`), so `trigger = "edit"` is `/edit`. Changing the prefix character
moves every provider at once. Duplicate triggers produce a warning; the
lexicographically first `id` wins.

A provider with no `trigger` can only be reached through plain, unprefixed
search, so it needs an entry in `[providers] global`. `global = true` in a
manifest marks the provider as ambient (it may omit `trigger`); it does not by
itself join plain search.

Plain search is an **allowlist**: only the providers in `[providers] global`
answer an unprefixed query, and `apps` always does whether or not it is listed.
It covers providers you cannot edit — bundled and third-party ones alike — and
can be set in `config.toml` or with the **Plain queries** checkbox in
Settings → Providers:

```toml
[providers]
global = [
  "calc", "search", "web", "win", "unit", "zj",
  "bookmark", "pins", "system", "timer", "awake", "cheat",
]
```

The list is authoritative: removing an id removes that provider from plain
search, and `global = []` leaves only `apps`. An unlisted provider is still
reachable through its `/trigger`. The default applies when the key is absent;
a 2.12.x list of just `system`, `timer`, `awake` is upgraded to the full
allowlist on load, and an unknown id logs a warning.

## 2. Paths providers

```toml
id = "neo"
name = "Editor"
trigger = "edit"
engine = "paths"

kind = "any"                   # directories | files | any
scope = "home"                 # key in config [scopes]
open_with = "neovide"          # app name, or an absolute command
secondary = "reveal"           # reveal | open | copy
max_results = 2000
freeform = true                # accept typed absolute/~/relative paths
```

`kind = "any"` is `/edit` (files and folders); `kind = "directories"` is `/editf`. `/neo` and `/neof` remain aliases.
(folders only). With `freeform = true`, an existing absolute path, `~/…`, or
path containing `/` is offered directly even when it is outside the scope.

The engine runs `fd` once per scope root with `cwd` set to that root:

```
fd --hidden --no-ignore --print0 --max-depth N --type d|f .
```

then ranks with fzf:

```
fzf --filter "<query>" --scheme=path --read0 --print0
```

Scopes are defined once in `config.toml` and shared by every paths provider:

```toml
[scopes.projects]
roots = ["~/dev", "~/dot-files"]
exclude = [
  "**/node_modules/**", "**/.git/**", "**/.build/**",
  "**/target/**", "**/Library/**", "**/*.app/**",
]
include_hidden = false
max_depth = 12
respect_gitignore = false
```

Glob rules are gitignore-style: a bare name matches any path segment, a pattern
containing `/` is anchored at the root, a trailing `/` means directories only,
and `!` re-includes. Roots are an allow list: nothing outside them is searched.

Results display the path relative to its root. `⏎` runs `open_with`;
`⌘⏎` runs the secondary action. `open_with` may be an app name (`open -a`) or an
absolute executable. If the target app is missing, the action reports an error
instead of failing silently.

Missing `fd` or `fzf` produces a single row with the install command; the rest
of the launcher keeps working.

## 3. Command providers

### 3.1 Lifecycle

- Started lazily on the first query routed to it.
- Kept alive while idle, then terminated after `idle_timeout_s`.
- One query in flight at a time; a new query cancels the previous one.
- Restarted with backoff (1 s, 2 s, 5 s, 30 s) after a crash.
- Killed (with its process group) on timeout.
- stderr is captured to the Palette log with the provider id.

No shell is involved: `command` is an argv array. Use `["/bin/sh", "-lc", "..."]`
if you really want shell semantics.

### 3.2 Framing

One JSON object per line, UTF-8, no pretty-printing. Lines may arrive in any
order, but a response must reference a request `id`.

Host → provider:

```json
{"type":"init","api_version":1,"config":{}}
{"type":"query","id":"q7","text":"some","terms":["some"],"limit":20,"trigger":"neo"}
{"type":"cancel","id":"q7"}
{"type":"activate","id":"a3","item_id":"item-1","action_id":"open"}
{"type":"shutdown"}
```

Provider → host:

```json
{"type":"results","id":"q7","items":[...]}
{"type":"done","id":"q7"}
{"type":"error","id":"q7","message":"..."}
{"type":"prompt_result","id":"p1","value":"..."}
```

`results` may be sent multiple times to stream. `done` ends the query. An
`error` is shown as a diagnostic row but does not kill the provider.

### 3.3 Items

```json
{
  "id": "item-1",
  "title": "deploy.sh",
  "subtitle": "~/dev/infra/deploy.sh",
  "icon": {"type": "file", "value": "/Users/me/dev/infra/deploy.sh"},
  "badge": "script",
  "group": "Scripts",
  "accent": "#89b4fa",
  "score": 1.0,
  "actions": [
    {"id": "open", "title": "Open", "kind": "open_path", "value": "/Users/me/dev/infra/deploy.sh"},
    {"id": "run", "title": "Run", "kind": "run", "value": ["/bin/sh", "/Users/me/dev/infra/deploy.sh"]},
    {"id": "copy", "title": "Copy path", "kind": "copy_text", "value": "/Users/me/dev/infra/deploy.sh"}
  ]
}
```

- `id` must be stable for the same item; frecency is keyed on
  `<provider-id>:<item-id>`.
- `score` is an optional hint, added to the host's match score.
- `icon` types: `symbol` (SF Symbol name), `file` (path), `url`, `base64`
  (PNG). Omit it to use the manifest icon.
- The first action is the primary action (`⏎`); the second is the secondary
  (`⌘⏎`); the rest appear in the action list (`⌘K`).
- `group` renders a section header whenever the visible rows contain more than
  one distinct group; consecutive rows in the same group share one header.

### 3.4 Actions

| `kind` | `value` | Behavior |
|---|---|---|
| `open_path` | string | open with the default app |
| `open_path_with` | `{"path": "...", "app": "..."}` | open a path with an app |
| `open_url` | string | open in the default browser |
| `reveal` | string | reveal in Finder |
| `copy_text` | string | write to the clipboard; optional `concealed`, `clear_after_ms` |
| `paste_text` | string | copy, hide, and paste into the previous app |
| `run` | array of strings | run argv detached |
| `custom` | any JSON | sent back to the provider via `activate` |

Declarative actions mean most providers never need to implement side effects.

### 3.5 Host requests

Providers may ask the host for input or feedback at any time:

```json
{"type":"prompt","id":"p1","kind":"secure_text","title":"Unlock Bitwarden","placeholder":"Master password"}
{"type":"prompt","id":"p2","kind":"confirm","title":"Delete this item?"}
{"type":"notify","level":"info","message":"Synced 42 items"}
{"type":"copy","text":"secret","concealed":true,"clear_after_ms":30000}
```

`kind` is `text`, `secure_text`, or `confirm`. The host replies with
`prompt_result` and a string value (`"true"`/`"false"` for confirm). Prompts are
modal to the launcher, not the system.

`notify` shows a transient footer message. `copy` is a convenience for actions
that produce a value after activation.

### 3.6 Example

```python
#!/usr/bin/env python3
import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

send({"type": "init", "api_version": 1, "config": {}})

for line in sys.stdin:
    msg = json.loads(line)
    if msg["type"] == "query":
        q = msg["text"].lower()
        items = [
            {
                "id": "hello",
                "title": "Hello, " + (msg["text"] or "world"),
                "subtitle": "from an external provider",
                "icon": {"type": "symbol", "value": "hand.wave"},
                "actions": [
                    {"id": "copy", "title": "Copy", "kind": "copy_text",
                     "value": "Hello, " + (msg["text"] or "world")}
                ],
            }
        ] if q in "hello" or not q else []
        send({"type": "results", "id": msg["id"], "items": items})
        send({"type": "done", "id": msg["id"]})
    elif msg["type"] == "activate":
        send({"type": "notify", "level": "info", "message": "Activated"})
    elif msg["type"] == "shutdown":
        break
```

Run it with `chmod +x` and point a manifest at it. The full example lives in
`Resources/Examples/hello/`.

### 3.7 Installing

Drop a directory into `~/.config/palette/providers/` and press `⌘R`. No install
step, no signature, no sandbox. A provider is code running with your privileges;
only install providers you trust. First-run trust prompts and content hashes are
on the roadmap.

## 4. Bundled providers

The preview pane is only offered for a curated set — `clip`, `snip`, `recent`,
`neo`, `neof`, `proj`, `shots`, `cheat`, and `atlas` — while one of them is the
bound prefix, and only while the selected row has preview content. Other
providers fill the list but never widen the panel.

The rail shows **Everything** and **Apps** first, then one row per provider
group, then one row per ungrouped provider. Bundled families that answer one
trigger stem share a group: Bitwarden (`bw`, `bwu`, `bwt`, `bwn`, `bwo`) and
GitHub (`gh`, `ghr`, `ghp`, `ghi`, `gha`, `ghn`). Selecting a group opens its
first member and shows the others as a secondary strip; every trigger still
works on its own when typed. **Apps** is the one rail row that opens a provider
without a prefix, and plain text keeps filtering it until another scope is
chosen. Groups are declared in code, not in a manifest, so user providers simply
appear as their own rows.

| ID | Trigger | Backend | Notes |
|---|---|---|---|
| `apps` | — | native | applications, always searched for plain queries; the **Apps** rail row opens it without a prefix |
| `calc` | `calc` | native | arithmetic; unprefixed by default |
| `pins` | — | native | pinned items, in the default allowlist |
| `neo` | `edit` | paths | files and folders across home, freeform, opens in the configured editor (`/neo` alias) |
| `neof` | `editf` | paths | folders only, seeded user copy (`/neof` alias) |
| `zj` | `zj` | native | in the default allowlist; running sessions appear unprefixed, create rows only under `/zj` |
| `search` | — | native | web-search rows for configured engines by default; `!keyword` bangs when an engine has one, and per-engine `app_mode` opens that bang in a web app |
| `bw` | `bw` | native | Bitwarden passwords |
| `bwu` | `bwu` | native | Bitwarden usernames |
| `bwt` | `bwt` | native | Bitwarden TOTP codes |
| `bwn` | `bwn` | native | Bitwarden notes |
| `bwo` | `bwo` | native | Bitwarden URLs |
| `clip` | `clip` | native | clipboard history: text, images, Finder files; grouped and previewable; image rows copy text with on-device OCR and open detected http(s) links |
| `ocr` | `ocr` | native | on-device Vision text and QR/barcode reading of the clipboard image (or last screenshot); optional path argument; rows copy the text, open validated links, or search the web |
| `port` | `port` | native | listening TCP ports, process/cwd, confirmed kill |
| `cmd` | `cmd` | native | manifest commands from commands.toml |
| `proj` | `proj` | native | devx projects/worktrees, `~/dev` fallback; empty query adds **Clone a repository…** and **New project…** |
| `git` | `git` | native | repository status and safe Git actions |
| `github` | `gh` | native | current repo, an explicit `owner/repo`, or the account's open PRs and repo issues through `gh` |
| `ghr` | `ghr` | native | the account's repositories: open, clone into a devx root, copy slug |
| `ghp` | `ghp` | native | open PRs authored by you and awaiting your review; check out locally when a clone exists |
| `ghi` | `ghi` | native | open issues assigned to you |
| `gha` | `gha` | native | workflow runs for the current repo or `owner/repo`: view log, re-run failed jobs, cancel |
| `ghn` | `ghn` | native | notification inbox: open, mark done |
| `term` | `term` | native | embedded SwiftTerm login shell |
| `awake` | `awake` | native | keep-awake durations and lid-closed clamshell guard |
| `scratch` | `scratch` | native | named, searchable scratch notes and in-panel editor |
| `recent` | `recent` | native | recently opened projects and files |
| `snip` | `snip` | native | snippets from snippets.toml with safe placeholder expansion |
| `web` | `web` | native | web apps with optional in-app global shortcuts, in the default allowlist |
| `bookmark` | `bookmark` | native | bookmarks from `bookmarks.toml`, opened in a normal browser window, in the default allowlist |
| `emoji` | `emoji` | native | full Unicode emoji catalog with name search |
| `cheat` | `cheat` | native | cheatsheet folders from Settings → Cheatsheets, one level deep, QuickLook preview; in the default allowlist (plain queries) |
| `atlas` | `atlas` | native | artifacts and docs from `~/.config/atlas/state.json`, inbox first with a review badge and document preview; add it to the allowlist for plain queries |
| `ssh` | `ssh` | native | hosts from `~/.ssh/config`; connect in the embedded terminal, one session per host that reattaches on re-run |
| `system` | `sys` | native | sleep, lock, empty trash, reload, quit |
| `theme` | `theme` | native | live theme switching |

A provider that cannot answer yet returns a row instead of an empty list. The
GitHub family uses the badge to say which kind it is: `SETUP` for a missing
`gh`, a failed auth check, or `/gha` outside a checkout with no `owner/repo`
(**Pick a repository**); `SCOPE` when the token lacks the `notifications` scope
(the action runs `gh auth refresh -s notifications` in the panel); and `EMPTY`
when `/ghn` finds no notifications in the inbox. The `/gh` setup row carries a
**Run gh auth login** action.

## 5. Conformance checklist

A command provider is correct when:

- [ ] It starts and answers `init` without blocking.
- [ ] It emits `results` then `done` for every `query`, even when empty.
- [ ] It handles `cancel` by stopping work for that id.
- [ ] It never blocks reading stdin while waiting on slow I/O.
- [ ] It emits one JSON object per line and flushes after each.
- [ ] It returns within `timeout_ms` or streams partial results.
- [ ] Item `id`s are stable across identical queries.
- [ ] It exits cleanly on `shutdown`.
