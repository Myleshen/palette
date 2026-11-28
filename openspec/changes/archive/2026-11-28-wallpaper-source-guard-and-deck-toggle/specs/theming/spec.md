## MODIFIED Requirements

### Requirement: Palette source

`[theming] source` SHALL accept `theme` or `wallpaper`. While it is `wallpaper`,
applying a theme SHALL be refused with a visible explanation; the source SHALL
only change through an explicit control (Settings source picker or the deck
toggle).

#### Scenario: Theme source

- **WHEN** `source = "theme"` and `theme = "catppuccin-mocha"`
- **THEN** the generated files carry that theme's palette

#### Scenario: Off by default

- **WHEN** `[theming]` is absent
- **THEN** no app config is touched and no generated files are written

#### Scenario: Theme pick while wallpaper owns the palette

- **WHEN** the user applies a theme from the browser, `/theme` or the deck and
  `source = "wallpaper"`
- **THEN** nothing is written, the source stays `wallpaper`, and a status names
  the reason and how to switch

#### Scenario: Explicit switch to theme colours

- **WHEN** the user picks Theme in the Settings source control or the deck toggle
- **THEN** the source becomes `theme` and the current theme is applied
