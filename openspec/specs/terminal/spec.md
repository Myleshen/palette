# Terminal Specification

## Purpose

The embedded PTY panel: `/term`, multiplexer selection, zellij attach, restart,
presentation, and guaranteed child cleanup when Palette quits.

## Requirements

### Requirement: Embedded terminal

`/term` SHALL open a real login shell in the launcher's content panel using the
configured shell, with `/cmd` rows able to run in the same shell. `⌘W` SHALL
close the panel and detach rather than kill a multiplexed session.

#### Scenario: Opening the terminal

- **WHEN** the user runs `/term`
- **THEN** a live shell appears in the content panel

#### Scenario: Closing the panel

- **WHEN** the user presses `⌘W` on the terminal panel
- **THEN** the panel closes and any zellij or tmux session keeps running

### Requirement: Shell selection

`[terminal_session] shell` SHALL choose the shell; an empty value SHALL use fish
when installed, otherwise zsh. The chosen shell SHALL be exported as `SHELL` to
the multiplexer so new panes inherit it. A missing configured shell SHALL fall
back to the system shell and report the substitution.

#### Scenario: Empty shell value

- **WHEN** `shell = ""` and fish is installed
- **THEN** fish starts and `SHELL` points at fish

#### Scenario: Missing shell

- **WHEN** `shell = "/opt/homebrew/bin/fish"` and that binary is absent
- **THEN** the system shell starts and a diagnostic names the missing path

### Requirement: Multiplexer selection

`[terminal_session] multiplexer` SHALL accept `auto`, `zellij`, `tmux` or
`none`. `auto` SHALL use zellij when installed, then tmux, then a plain shell.
An explicit value whose tool is missing SHALL fall through to the next option
rather than failing to open.

#### Scenario: Auto with only tmux installed

- **WHEN** `multiplexer = "auto"` and zellij is absent
- **THEN** tmux starts with `new-session -A -s Palette`

#### Scenario: No multiplexer

- **WHEN** `multiplexer = "none"`
- **THEN** a plain login shell starts

#### Scenario: Explicit zellij missing

- **WHEN** `multiplexer = "zellij"` and zellij is absent
- **THEN** tmux or a plain shell opens and the row explains the fallback

### Requirement: Session name

`[terminal_session] name` SHALL name the multiplexer session and SHALL default
to `Palette` when empty or whitespace. The name SHALL be stable across opens so
re-running `/term` reattaches.

#### Scenario: Empty name

- **WHEN** `name = "  "`
- **THEN** the session is created as `Palette`

### Requirement: Zellij name sanitising

Before attaching, Palette SHALL restrict the session name to letters, digits,
`.`, `_` and `-`, cap it at 64 characters and trim leading/trailing `-._`. A
name with nothing usable left SHALL become a stable `palette-<hash>` so two
unusable names never collide.

#### Scenario: Unsafe characters

- **WHEN** the requested name contains `:` or a space
- **THEN** those characters become `-` and the attach uses the cleaned name

#### Scenario: Nothing usable remains

- **WHEN** the requested name is only punctuation
- **THEN** the session name is `palette-` plus a stable hash of the original

### Requirement: Zellij dead-session handling

Palette SHALL read `zellij list-sessions --no-formatting` before attaching. A
same-named session shown as exited or resurrectable SHALL be deleted and the
attach SHALL create a fresh session. If deletion fails, Palette SHALL still try
to attach and SHALL print the warning in the pane.

#### Scenario: Stale session owns the name

- **WHEN** the listing shows the name as exited
- **THEN** Palette deletes it and starts a fresh session

#### Scenario: Delete fails

- **WHEN** `zellij delete-session --force` fails
- **THEN** the pane prints the warning and still attempts an attach

### Requirement: Zellij attach retry

A failed attach that matches zellij's stale-session errors SHALL get one
automatic rebuild for that pane. A second failure SHALL leave the exit visible
instead of looping.

#### Scenario: Resurrect prompt

- **WHEN** attach fails asking to resurrect a dead session
- **THEN** the pane rebuilds once and starts the session cleanly

#### Scenario: Repeated failure

- **WHEN** the rebuilt attach also exits non-zero
- **THEN** the pane stops retrying and shows the exit code

### Requirement: Terminal restart

When the child exits, the pane SHALL stay open with its last output readable.
An explicit restart SHALL clear the exit state and start the initial command
again.

#### Scenario: Restart after exit

- **WHEN** the shell exits and the user chooses restart
- **THEN** the pane runs the initial command in a new process

### Requirement: Quit and process cleanup

Palette SHALL keep a live PID registry for its PTY children. Quitting SHALL
send `SIGTERM` to each child's process group, then `SIGKILL` after a short wait,
so no shell or job outlives the app.

#### Scenario: Quitting with a running sleep

- **WHEN** a `sleep` runs in the embedded terminal and Palette quits
- **THEN** neither the shell nor the `sleep` survives

### Requirement: Terminal presentation and palette

The embedded terminal SHALL open at 90% of the launcher width and 85% of its
height, centred, SHALL use the configured font size or Kitty's, and SHALL
recolour in place when the palette changes without restarting the shell.

#### Scenario: Palette change while running

- **WHEN** the active theme changes with a live terminal pane
- **THEN** background, foreground, caret and all 16 ANSI colours update
- **AND** the running shell is not restarted

#### Scenario: Missing Nerd Font

- **WHEN** the configured terminal font is not installed
- **THEN** the pane falls back to the theme mono font and reports the fallback

### Requirement: SSH sessions in the terminal

`/ssh <query>` SHALL list aliases from `~/.ssh/config`; `⏎` SHALL run `ssh
<alias>` in the embedded terminal with one session per host, so the same host
reattaches. The external terminal SHALL remain the secondary action.

#### Scenario: Re-running a host

- **WHEN** the user opens `ssh myhost` twice
- **THEN** the second run reattaches to the existing pane rather than opening a second connection
