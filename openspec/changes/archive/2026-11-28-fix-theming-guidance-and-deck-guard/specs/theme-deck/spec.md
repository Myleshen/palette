## ADDED Requirements

### Requirement: Visible refusal for theme cards in wallpaper mode

When `[theming] source = "wallpaper"`, the deck SHALL disable Apply for theme
cards and SHALL keep the reason visible, rather than accepting the key and
showing a transient status.

#### Scenario: Theme card in wallpaper mode

- **WHEN** the Colours deck is open with source wallpaper
- **THEN** Apply is disabled for theme cards and the footer states that the
  wallpaper owns the palette and how to switch

#### Scenario: Wallpaper card

- **WHEN** a wallpaper card is selected in the same mode
- **THEN** Apply stays enabled

#### Scenario: Source changes back

- **WHEN** the source is switched to Theme while the deck is open
- **THEN** Apply becomes enabled for theme cards without reopening the deck
