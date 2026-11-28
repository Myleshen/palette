# Theme Deck Specification

## Purpose

The fanned hand of theme and wallpaper cards: geometry, arc motion, filtering,
favourites, preview and the apply rules for colour and wallpaper cards. See
[ADR 0005](../../decisions/0005-theme-deck-geometry.md).

## Requirements

### Requirement: Deck presentation

The deck SHALL be a non-activating panel with no native menu tracking. It SHALL
span the usable width of the display under the pointer and rest on that
display's bottom edge. The pointer's screen SHALL be resolved each time the deck
opens, falling back to the main screen when the pointer sits between displays.

#### Scenario: Opening on a second display

- **WHEN** the pointer is on the left display and the user presses `⌘⌥G`
- **THEN** the deck spans that display's usable width and rests on its bottom edge

#### Scenario: Pointer between displays

- **WHEN** the pointer is in the gap between two displays
- **THEN** the deck opens on the main screen

### Requirement: Deck sizing

The deck SHALL take 60% of the usable screen height, never below the 0.35
minimum card scale, with an 88 pt chrome allowance, 24 pt side and bottom
insets. Cards SHALL be 260×368 pt at full scale and the whole hand SHALL fit
inside the canvas at any resolution or orientation.

#### Scenario: Short screen

- **WHEN** the display has little vertical room
- **THEN** the cards scale down together and the hand stays fully visible

#### Scenario: Ultrawide

- **WHEN** the deck opens on a 3440×1440 display
- **THEN** the hand fans wider without exceeding the 34° maximum

### Requirement: Arc fan geometry

The hand SHALL ride a circular arc whose centre is below the deck: the selected
card is the apex, its neighbours descend and tilt by the tangent angle, side
cards are smaller and dimmed, and a short hand SHALL drop so its lowest visible
card rests on the bottom inset. Reach SHALL stay between 2 and 9 visible cards.

#### Scenario: One neighbour

- **WHEN** the selection moves one card right
- **THEN** that card becomes the apex and the previous card descends left

#### Scenario: Short hand

- **WHEN** a filter leaves only three cards
- **THEN** the hand drops to the bottom inset instead of floating mid-deck

### Requirement: Deal-in and motion

Opening the deck SHALL deal the cards in from below with a staggered spring,
and each card SHALL settle on the arc. Reduce Motion SHALL skip the deal and
the fan animation.

#### Scenario: Reduce Motion

- **WHEN** Reduce Motion is on and the deck opens
- **THEN** the hand appears settled with no spring animation

### Requirement: Deck navigation

Left/Right arrows and scroll SHALL flip the selection; typing SHALL filter
within the active mode; Tab SHALL show that mode's favourites; Ctrl+F SHALL
mark the front card as a favourite; Return or Space SHALL apply; Esc SHALL
close. Favourites and filters SHALL stay inside the active mode.

#### Scenario: Filtering colours

- **WHEN** the user types `gruv` in Colors mode
- **THEN** only matching colour cards remain and the wallpaper set is untouched

#### Scenario: Switch mode

- **WHEN** `⌘⌥W` opens the deck
- **THEN** it starts in Wallpapers mode with its own filter and favourites

#### Scenario: Esc

- **WHEN** the user presses Esc on the deck
- **THEN** the deck closes without applying anything

### Requirement: Card preview

`P` or Space SHALL open a full-screen preview of the front card: palette blocks,
all 16 ANSI colours and a live launcher mock for colour cards, and the picture
filling the panel with its palette dots for wallpaper cards. Esc SHALL collapse
the preview back to the fan without applying.

#### Scenario: Previewing a colour card

- **WHEN** the user presses P on a colour card
- **THEN** the preview shows the palette, ANSI slots and launcher mock

### Requirement: Wallpaper cards

Wallpaper cards SHALL come from `[theming] wallpaper_directory` (default
`~/wallpapers`), scanned without recursion. Images SHALL be picture cards;
videos SHALL be browse-only and SHALL refuse to apply. The current desktop
picture SHALL be marked, thumbnails SHALL load only near the selection, and each
visible card's dots SHALL come from its own picture.

#### Scenario: Video card

- **WHEN** the front wallpaper card is a video
- **THEN** the apply path says macOS cannot set a video as the desktop picture

#### Scenario: Empty directory

- **WHEN** `wallpaper_directory` is empty
- **THEN** the deck shows the current desktop card only

#### Scenario: Missing directory

- **WHEN** the configured wallpaper directory does not exist
- **THEN** the deck shows the missing path instead of an empty hand

### Requirement: Applying a wallpaper card

Choosing a picture card SHALL set it on every screen first. Only when cross-app
theming is enabled and `source = "wallpaper"` SHALL the new picture be sampled
and its palette applied; otherwise the status line SHALL say the palette was
left alone. The launcher and live terminal SHALL follow the new palette.

#### Scenario: Theming off

- **WHEN** a wallpaper card is applied with cross-app theming off
- **THEN** only the desktop picture changes and the status line says so

#### Scenario: Wallpaper source

- **WHEN** a wallpaper card is applied with theming on and `source = "wallpaper"`
- **THEN** the picture, the launcher palette and the generated app files move together

### Requirement: Applying a colour card

Applying a colour card SHALL switch the launcher theme, SHALL record the theme
id in `[theme]`, and SHALL regenerate the selected app targets when theming is
on. It SHALL NOT change the desktop picture.

#### Scenario: Apply a color card

- **WHEN** the user presses Return on `catppuccin-latte`
- **THEN** the launcher uses that theme and `[theme]` records its id

### Requirement: Source conflict

While `source = "wallpaper"`, a colour card SHALL be refused with a message
telling the user to set the source back to Theme; the refusal SHALL NOT change
any config.

#### Scenario: Colour card with wallpaper source

- **WHEN** the user presses Return on a colour card while `source = "wallpaper"`
- **THEN** the deck refuses and no theme or generated file changes
