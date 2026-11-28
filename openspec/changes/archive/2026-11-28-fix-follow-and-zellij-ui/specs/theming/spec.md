## ADDED Requirements

### Requirement: Wallpaper follow starts at launch

When `[theming] enabled = true`, `source = "wallpaper"` and
`follow_wallpaper = true`, Palette SHALL poll the desktop picture from launch,
so a desktop change is picked up without touching Settings or relaunching.

#### Scenario: Launch then change the desktop

- **WHEN** Palette launches in wallpaper-follow mode and the desktop picture
  later changes
- **THEN** the palette files and Palette's own theme update on the next poll

#### Scenario: Follow disabled

- **WHEN** `follow_wallpaper = false`
- **THEN** no poll is installed and a desktop change does nothing

### Requirement: Zellij UI roles follow the palette

The generated zellij theme SHALL define the tab bar, status bar, pane frames and
exit-code roles from the palette, with readable foregrounds, not only the base
ANSI palette.

#### Scenario: Tab bar and frames

- **WHEN** the generated zellij theme is active
- **THEN** the tab bar, status bar, selected/unselected tabs and pane frames use
  the palette's accent, surface and muted roles

#### Scenario: Exit codes

- **WHEN** a command succeeds or fails in a pane
- **THEN** the exit-code indicator uses the palette's green or red with a
  readable foreground
