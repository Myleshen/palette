# Accessibility Specification

## Purpose

The accessibility overrides that always win over theme values, and the
keyboard and non-colour cues the launcher depends on. The measurable contrast
gates live in the theme-catalogue spec.

## Requirements

### Requirement: Reduce Transparency

When macOS Reduce Transparency is on, a theme's `material` SHALL resolve to
`none` and `opacity` to 1, so no surface relies on a desktop-tinted blend.

#### Scenario: Glass theme with Reduce Transparency

- **WHEN** a theme sets `material = "hudWindow"` and `glass = true`
- **THEN** the launcher renders an opaque surface with no material

### Requirement: Increase Contrast

When Increase Contrast is on, borders and separators SHALL strengthen by one
step and launcher cards, search, preview and Settings SHALL render opaque. Focus
rings SHALL be full opacity.

#### Scenario: Increased contrast panel

- **WHEN** Increase Contrast is on
- **THEN** the search field, result card, preview and Settings use opaque backgrounds

#### Scenario: Focus ring

- **WHEN** a focus ring is drawn under Increase Contrast
- **THEN** it is fully opaque

### Requirement: Reduce Motion

When Reduce Motion is on, a theme's motion `style` SHALL resolve to `none`, the
theme deck SHALL skip its deal-in spring and fan animation, and no interface
transition SHALL be required to reach a state.

#### Scenario: Opening the deck

- **WHEN** Reduce Motion is on and the user opens theme cards
- **THEN** the hand appears settled with no animation

### Requirement: Theme accessibility overrides win

Accessibility overrides SHALL apply after theme resolution and composition and
SHALL win over theme values, including a user theme that sets the opposite.

#### Scenario: User theme sets material

- **WHEN** a user theme sets `material = "popover"` and Reduce Transparency is on
- **THEN** the material is still `none`

### Requirement: Text size floor

The system text size SHALL be respected as a floor. A theme or typography
setting MAY increase text size but SHALL NOT shrink it below the accessibility
setting.

#### Scenario: Small theme size

- **WHEN** the system text size is larger than the theme's `typography.size`
- **THEN** the larger system size is used

### Requirement: Font fallback

A font family that is unavailable SHALL fall back to the system font without
breaking layout, and the configured value SHALL be preserved and marked
**(missing)** in Settings.

#### Scenario: Uninstalled mono font

- **WHEN** `mono_family` names a font that is not installed
- **THEN** text renders in the system mono fallback and Settings marks the value

### Requirement: Non-colour state cues

Selection, focus and status SHALL NOT rely on colour alone. A selected row SHALL
carry a weight change and a leading-bar or fill shape, menus SHALL mark the
active row, and status colours SHALL come from the theme rather than system red
and green.

#### Scenario: Selected row

- **WHEN** a row is selected
- **THEN** its weight and leading cue change as well as its colours

#### Scenario: Status colour

- **WHEN** an error badge is drawn
- **THEN** it uses the theme's danger colour and a label, not only a red tint

### Requirement: Keyboard operation

Every launcher surface SHALL be operable from the keyboard: Tab walks the four
focus zones, arrows move within the focused zone, Return confirms, Esc unwinds,
and `⌘1`…`⌘9` open a result. A visible focus ring SHALL mark the active zone.

#### Scenario: Reaching the rail

- **WHEN** the user presses Tab from search
- **THEN** focus moves to the list, then the rail, then the strip, each with a focus ring

### Requirement: Accessible contrast

A resolved theme, generated app file or wallpaper palette SHALL meet the
contrast gates, and a repair or failure SHALL be written to the diagnostic log
rather than hidden. See [ADR 0002](../../decisions/0002-curated-theme-catalogue.md).

#### Scenario: Repaired user theme

- **WHEN** a user theme fails a contrast pair
- **THEN** the theme is repaired and the adjustment is logged
