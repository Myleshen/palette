## ADDED Requirements

### Requirement: Launch palette push

When theming is enabled and a supported terminal is already running, Palette
SHALL push the current generated palette to that terminal once at launch,
without rewriting generated files, restarting the terminal or changing the
configured source.

#### Scenario: Terminal was running before Palette

- **WHEN** Palette launches with `[theming] enabled = true` and a kitty process
  that Palette manages is already running
- **THEN** the running kitty adopts the current palette without a file rewrite

#### Scenario: Theming disabled

- **WHEN** Palette launches with `[theming] enabled = false`
- **THEN** no palette is pushed to any running terminal

#### Scenario: Push fails

- **WHEN** the terminal's socket is gone or refuses the command
- **THEN** the failure is logged and the launch continues; no restart prompt is
  raised for a terminal the user did not open through Palette
