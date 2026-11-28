## ADDED Requirements

### Requirement: Refusal is visible in Settings

When a theme apply is refused because wallpaper colours are enabled, the
Theming pane SHALL show that refusal next to the theme browser instead of
failing silently.

#### Scenario: Use Theme while wallpaper is on

- **WHEN** the user presses "Use Theme" with `source = "wallpaper"`
- **THEN** the pane shows that wallpaper colours are enabled and points at the
  source control
