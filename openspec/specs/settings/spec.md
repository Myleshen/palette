# Settings Specification

## Purpose

The Settings window, its panes and search, auto-apply behaviour, validation, and
the config file's persistence and safety rules.

## Requirements

### Requirement: Pane structure

Settings SHALL have twenty panes in five sidebar groups: Basics (General,
Launcher, Appearance, Shortcuts), Features (Search, Ask, Embedded Terminal,
Bookmarks, Cheatsheets, Web Apps, Screenshots, After a capture, Recordings,
Captures), Theming, Advanced (Provider Files, Config Files, Diagnostics) and
System (About, Providers).

#### Scenario: Opening Settings

- **WHEN** the user presses `⌘,`
- **THEN** the Settings window opens with the pane groups in the sidebar

### Requirement: Pane search

`⌘F` SHALL search pane names and section titles and SHALL select the matching
pane and row. Clearing the search SHALL restore the full pane list.

#### Scenario: Finding a setting

- **WHEN** the user types `clipboard` in Settings search
- **THEN** the panes and sections containing that control are listed

### Requirement: Auto-apply

A Settings change SHALL apply immediately; there SHALL be no Save or Cancel
button. The footer SHALL report **Saved** or the failure. A failed write SHALL
leave the last valid value in the file and SHALL be visible.

#### Scenario: Successful edit

- **WHEN** the user changes the panel size
- **THEN** the change applies at once and the footer says Saved

#### Scenario: Write failure

- **WHEN** the config file cannot be written
- **THEN** the footer reports the failure and the previous file is unchanged

### Requirement: Pane reset

**Reset `<pane>`…** SHALL restore that pane's defaults only, SHALL run through
the same validation as a manual edit, and SHALL NOT touch other panes.

#### Scenario: Resetting Theming

- **WHEN** the user resets the Theming pane
- **THEN** theming defaults return and installed include blocks are removed

### Requirement: Value validation

An invalid or duplicate value SHALL show an inline error and SHALL NOT be
written; the file SHALL keep the last valid value. A browser that is not
installed SHALL NOT be saved. A configured font that is no longer installed
SHALL stay selected and be marked **(missing)** instead of being reset.

#### Scenario: Duplicate hotkey

- **WHEN** a shortcut is already used by another action
- **THEN** an inline error appears and the file keeps the previous key

#### Scenario: Missing font

- **WHEN** `ui_family` names an uninstalled family
- **THEN** the control keeps the value and shows `(missing)`

#### Scenario: Uninstalled browser

- **WHEN** the user picks a browser that is not installed
- **THEN** the value is not written and the row explains why

### Requirement: Hotkey recording

Shortcuts SHALL be recorded by pressing the keys, using a short-lived session
event tap that captures macOS-reserved combinations such as `⌘Space` and stops
when Settings loses focus. Accessibility SHALL be requested for reserved-key
capture.

#### Scenario: Recording a reserved key

- **WHEN** the user presses `⌘Space` in the recorder
- **THEN** the combination is captured instead of being swallowed by the system

#### Scenario: Recorder loses focus

- **WHEN** the Settings window loses focus while recording
- **THEN** the event tap stops

### Requirement: Atomic config writes

Every config write SHALL write the previous file to a single rolling `.bak` with
`0600` permissions first, then write the canonical render atomically. If the
backup cannot be written, the original SHALL stay untouched.

#### Scenario: Successful save

- **WHEN** Settings writes the config
- **THEN** the previous content is in `config.toml.bak` and the new content is in `config.toml`

#### Scenario: Backup fails

- **WHEN** the backup cannot be written
- **THEN** the save fails and `config.toml` is unchanged

### Requirement: Parse-error refusal

If `config.toml` could not be parsed, every save path — Settings, theme pick,
launcher position, onboarding — SHALL refuse to write, SHALL keep both the file
and its `.bak`, and SHALL name the parse error and backup. The refusal SHALL be
retryable after the user fixes the file.

#### Scenario: Broken config

- **WHEN** `config.toml` has a TOML syntax error and the user changes the theme
- **THEN** nothing is saved and the message points at the broken file and its backup

#### Scenario: Fixed config

- **WHEN** the user repairs the file and reloads
- **THEN** saves work again

### Requirement: Oversized config

A config larger than 4 MB SHALL be refused whole: Palette SHALL use built-in
defaults, report the size problem and the path, and SHALL set the parse-error
state so no save overwrites it.

#### Scenario: Huge config

- **WHEN** `config.toml` is 5 MB
- **THEN** defaults load and the message asks the user to trim the file

### Requirement: First run

On first run Palette SHALL write a commented `config.toml`, seed
`providers/neof` and a commented `bookmarks.toml`, and create the config, state
and cache directories. A write failure SHALL be reported without preventing the
app from starting.

#### Scenario: Fresh home

- **WHEN** Palette starts with no config directory
- **THEN** the default config and seeded examples exist and Palette opens

#### Scenario: Read-only home

- **WHEN** the config directory cannot be created
- **THEN** Palette starts with defaults and reports the failure

### Requirement: Hand edits and reload

Editing files by hand SHALL remain supported; `⌘R` SHALL reload config, themes
and providers. A provider manifest change SHALL reload providers automatically.

#### Scenario: Hand-edited config

- **WHEN** the user edits `config.toml` and presses `⌘R`
- **THEN** the new values apply without restarting

#### Scenario: Manifest change

- **WHEN** a file under `providers/` changes
- **THEN** the provider set reloads

### Requirement: Backup export

The Advanced panes SHALL export a backup of config, providers, themes and
bookmarks, SHALL write it with user-only permissions, and SHALL NOT include API
keys, the Bitwarden session or clipboard history.

#### Scenario: Exporting

- **WHEN** the user exports a backup
- **THEN** the archive contains config and definitions but no secret material

### Requirement: Debug isolation

A debug build SHALL use its own bundle id, config, state and support directories,
so a debug run never reads or writes the installed app's files.

#### Scenario: Debug launch

- **WHEN** the user runs `make debug-app`
- **THEN** the app uses `dev.myleshen.palette.debug` and separate data directories
