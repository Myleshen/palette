## ADDED Requirements

### Requirement: Transparency is preserved

When the user's terminal or Neovide is configured to be translucent, the
generated nvim file SHALL NOT paint an opaque normal background over it.

#### Scenario: Auto detection

- **WHEN** `[theming] transparent = "auto"` and kitty, ghostty or the nvim lua
  files configure an opacity below 1
- **THEN** `Normal` and `NormalNC` carry the foreground without a background

#### Scenario: Explicit off

- **WHEN** `transparent = "off"`
- **THEN** `Normal` keeps the palette background even if a terminal is
  translucent

#### Scenario: No transparency configured

- **WHEN** `transparent = "auto"` and no opacity setting is found
- **THEN** the opaque palette background is emitted as before
