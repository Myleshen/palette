## ADDED Requirements

### Requirement: Source toggle in the deck

The deck SHALL offer a `Wallpaper colours | Theme colours` control that flips
`[theming] source`, persists it, and applies the palette that matches, without
closing the deck.

#### Scenario: Switch to wallpaper colours

- **WHEN** the user selects Wallpaper colours in the deck
- **THEN** the source is wallpaper, the desktop palette is extracted and applied,
  and the control shows wallpaper as active

#### Scenario: Switch to theme colours

- **WHEN** the user selects Theme colours
- **THEN** the source is theme, the current theme is applied, and theme cards
  become applicable again
