# Clipboard Specification

## Purpose

Capture, storage, search and paste of clipboard history across text, images and
Finder file selections, with secrets excluded by policy and visible errors.

## Requirements

### Requirement: Capture policy

The clipboard monitor SHALL record a new pasteboard item only when it is not
marked concealed or transient and the frontmost app is not in
`[clipboard] ignored_apps`. A concealed or transient mark SHALL win over the
ignore list, and the ignore list SHALL win over an unmarked copy.

#### Scenario: Password manager copy

- **WHEN** a copy is marked concealed by any app
- **THEN** no history row is written

#### Scenario: Ignored app

- **WHEN** the frontmost bundle id is in `ignored_apps` and the copy is unmarked
- **THEN** no history row is written

#### Scenario: No frontmost app

- **WHEN** the frontmost bundle id is unavailable
- **THEN** the copy is recorded unless it is marked concealed or transient

### Requirement: Disabled clipboard history

`[clipboard] enabled = false` SHALL stop new captures and SHALL remove the
`/clip` surface from plain search and the rail, while existing rows remain in
state until the user clears them.

#### Scenario: Disabling history

- **WHEN** `[clipboard] enabled = false` and the config reloads
- **THEN** new copies are not recorded and `/clip` is unavailable

### Requirement: Per-kind limits

Text, images and file selections SHALL be trimmed independently. Defaults SHALL
be 100 text, 20 image and 20 file rows, and the oldest unpinned entry of that
kind SHALL be evicted first. The legacy `max_entries` key SHALL map to text and
SHALL be dropped the next time the file is written.

#### Scenario: Screenshot flood

- **WHEN** more than 20 unpinned images are captured
- **THEN** the oldest images go and the text history is untouched

#### Scenario: Legacy key

- **WHEN** a config written before per-kind limits has `max_entries = 200`
- **THEN** `max_text` becomes 200 and the old key is no longer written

### Requirement: Clamped limits

Loaded values SHALL be clamped: `max_text` at least 10, `max_images` and
`max_files` at least 1, `poll_ms` at least 150, and `clear_after_ms`,
`retention_days` and `max_image_bytes` at least 0. A negative value SHALL NOT
disable prompts or crash the monitor.

#### Scenario: Zero retention

- **WHEN** `retention_days = 0`
- **THEN** age-based trimming is off and rows are kept until a limit evicts them

### Requirement: Retention

Unpinned rows older than `retention_days` (default 30) SHALL be dropped on
launch and periodically. Image blobs SHALL be capped at `max_image_bytes`
(default 200 MB) and the oldest images evicted first. Pinned rows SHALL be
exempt from every trim.

#### Scenario: Retention sweep

- **WHEN** an unpinned row is older than `retention_days`
- **THEN** it is dropped on launch or the next periodic sweep

#### Scenario: Image byte cap

- **WHEN** new images would exceed `max_image_bytes`
- **THEN** the oldest unpinned image blobs are removed first

### Requirement: Pins

`⌘K` on any clipboard row SHALL offer Pin and Delete. A pinned row SHALL keep
its badge and rank higher in search while the list itself stays chronological,
and it SHALL survive trimming and retention.

#### Scenario: Pinning an old row

- **WHEN** the user chooses Pin on an old entry
- **THEN** the row keeps its list position, gains the pin badge and is never trimmed

#### Scenario: Unpin

- **WHEN** the user chooses Unpin
- **THEN** the row returns to normal trimming and ranking

### Requirement: Images stored as files

Clipboard images SHALL be stored as PNG files under the state directory as
`images/<first2>/<sha256>.png`, with thumbnails under `thumbs/`, content
addressed so identical bytes map to one file. Files SHALL be written `0600`
under a `0700` directory, paths SHALL be stored relative to the state directory,
and each write SHALL be read back before the row is committed.

#### Scenario: Copying the same image twice

- **WHEN** identical image bytes are copied again
- **THEN** the existing content-addressed file is reused and no second blob is written

#### Scenario: Write failure

- **WHEN** the PNG cannot be written or read back
- **THEN** no row is committed and the failure is logged

### Requirement: Clear deadlines for secrets

A copy written as concealed SHALL clear after `[clipboard] clear_after_ms`
(default 30000), and SHALL clear only if no newer copy has replaced it. The
pending clear SHALL survive a restart. A zero deadline SHALL keep the value
until the user clears it.

#### Scenario: Concealed copy expires

- **WHEN** a concealed value is written and 30 seconds pass with no new copy
- **THEN** the pasteboard is cleared

#### Scenario: Newer copy survives

- **WHEN** the user copies something else before the deadline
- **THEN** that newer value is not cleared

#### Scenario: Restart during the deadline

- **WHEN** Palette restarts with a pending clear still in the future
- **THEN** the pending clear is restored and fires at its original time

### Requirement: Bitwarden values never enter history

Values copied from Bitwarden SHALL always be written as concealed, SHALL clear
after 30 seconds, and SHALL NOT be recorded in clipboard history even when the
app is not ignored.

#### Scenario: Copying a password

- **WHEN** the user copies a Bitwarden password
- **THEN** the pasteboard clears after 30 seconds and no history row appears

### Requirement: Paste semantics

`⏎` on a clipboard row SHALL paste into the app Palette was invoked from. With
Accessibility granted that SHALL be a real ⌘V; without it Palette SHALL copy the
entry and open the permission prompt. A paste whose target never comes forward
SHALL report the failure and keep the panel usable.

#### Scenario: Paste into the source app

- **WHEN** the user presses ⏎ on a text row with Accessibility granted
- **THEN** the text is pasted and the clipboard browser closes

#### Scenario: No Accessibility

- **WHEN** the user presses ⏎ without Accessibility
- **THEN** the entry is copied and the permission prompt is shown

#### Scenario: Target never activates

- **WHEN** the source app does not come forward within the paste attempt
- **THEN** a status line says the paste did not reach the app

### Requirement: Clipboard search

Clipboard search SHALL scan the whole configured history with the same folded
fuzzy matching as the launcher, and SHALL search text, image labels/metadata and
file names. The snapshot SHALL rebuild only when history changes, and pinned
rows SHALL rank above equal unpinned matches.

#### Scenario: Non-contiguous search

- **WHEN** the user types `drgn` and a clipboard row contains `Dragon`
- **THEN** that row is found

#### Scenario: Snapshot reuse

- **WHEN** the user types several keystrokes without a history change
- **THEN** the search reuses one folded snapshot
