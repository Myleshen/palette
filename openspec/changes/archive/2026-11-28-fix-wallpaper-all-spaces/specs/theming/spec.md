## ADDED Requirements

### Requirement: One wallpaper on every Space

Applying a wallpaper SHALL set the same picture on every Space of every display,
not only the Space that is active when the apply runs.

#### Scenario: Several Spaces

- **WHEN** the user applies a wallpaper while the Mac has more than one Space
- **THEN** every Space's desktop picture is that wallpaper after the apply

#### Scenario: Space switched later

- **WHEN** the user switches to another Space
- **THEN** the wallpaper and the palette Palette sampled match

#### Scenario: Store unavailable

- **WHEN** the wallpaper store cannot be read or written
- **THEN** the per-display picture is still set, the failure is logged, and the
  apply reports success for the picture itself
