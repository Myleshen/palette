## ADDED Requirements

### Requirement: Standard palette export

Every successful apply SHALL write the active palette as a base16 scheme and as
terminal.sexy JSON in the generated theme directory, so another tool can read
Palette's colours without an adapter.

#### Scenario: Apply writes both files

- **WHEN** a theme or wallpaper palette is applied
- **THEN** `palette.yaml` and `palette.terminal-sexy.json` exist and carry that
  palette's colours

#### Scenario: Slot mapping

- **WHEN** the files are read
- **THEN** `base00` is the background, `base05` the foreground, `base08`–`base0F`
  the ANSI hues in base16 order, and terminal.sexy's `color_01`…`color_16` are
  ANSI 0…15

#### Scenario: Backup and revert

- **WHEN** the palette is reverted
- **THEN** both files return to the previous palette with the rest of the set
