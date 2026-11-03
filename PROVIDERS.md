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
name = "Neovide files"         # display name
trigger = "neof"               # bare word; invoked as /neof
global = false                 # also participate in unprefixed search
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
(default `/`), so `trigger = "neo"` is `/neo`. Changing the prefix character
moves every provider at once. Duplicate triggers produce a warning; the
lexicographically first `id` wins.

A provider with no `trigger` and `global = false` is unreachable and warned
about. `global = true` without a trigger is valid for ambient providers.

## 2. Paths providers

```toml
id = "neo"
name = "Neovide"
trigger = "neo"
engine = "paths"

kind = "any"                   # directories | files | any
scope = "home"                 # key in config [scopes]
open_with = "neovide"          # app name, or an absolute command
secondary = "reveal"           # reveal | open | copy
max_results = 2000
freeform = true                # accept typed absolute/~/relative paths
```

`kind = "any"` is `/neo` (files and folders); `kind = "directories"` is `/neof`
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
- `group` renders a section header when results are grouped.

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

| ID | Trigger | Backend | Notes |
|---|---|---|---|
| `apps` | — | native | applications, always global |
| `calc` | `calc` | native | arithmetic, also inferred unprefixed |
| `pins` | — | native | pinned items, global |
| `neo` | `neo` | paths | files and folders across home, freeform paths, opens in Neovide |
| `neof` | `neof` | paths | folders only, seeded user copy |
| `zj` | `zj` | native | global; running sessions globally, create rows only under `/zj` |
| `search` | — | native | global web-search rows for configured engines |
| `bw` | `bw` | native | Bitwarden passwords |
| `bwu` | `bwu` | native | Bitwarden usernames |
| `bwt` | `bwt` | native | Bitwarden TOTP codes |
| `bwn` | `bwn` | native | Bitwarden notes |
| `bwo` | `bwo` | native | Bitwarden URLs |
| `clip` | `clip` | native | clipboard history: text, images, Finder files; grouped and previewable |
| `port` | `port` | native | listening TCP ports, process/cwd, confirmed kill |
| `cmd` | `cmd` | native | manifest commands from commands.toml |
| `proj` | `proj` | native | devx projects/worktrees, ~/dev fallback |
| `git` | `git` | native | repository status and safe Git actions |
| `finder` | `finder` | native | actions for the current Finder selection |
| `ask` | `ask` | native | one-shot AI Q&A over OpenCode Zen/Go or OpenAI; free models first |
| `askh` | `askh` | native | retained Ask history with fuzzy search and metadata |
| `web` | `web` | native | global web apps with optional Hammerspoon shortcuts |
| `emoji` | `emoji` | native | full Unicode emoji catalog with name search |
| `system` | `sys` | native | sleep, lock, empty trash, reload, quit |
| `theme` | `theme` | native | live theme switching |

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
