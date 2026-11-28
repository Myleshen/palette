# Theme Catalogue Specification

## Purpose

The bundled theme set and the gates that keep every shipped theme readable:
contrast repair, role separation, ANSI distinctness, and migration of ids
removed from the catalogue. See [ADR 0002](../../decisions/0002-curated-theme-catalogue.md).

## Requirements

### Requirement: Curated catalogue

The bundled catalogue SHALL be 69 families (138 files), each with exactly one
dark and one light variant. Built-in defaults SHALL remain Default Dark,
Default Light, Catppuccin Mocha/Latte, Gruvbox Dark/Light, Aetheria Pink and
Siri Silver/Graphite. A family SHALL be dropped rather than ship one unusable
appearance.

#### Scenario: Family without a light port

- **WHEN** a candidate family has no light variant
- **THEN** neither file ships

#### Scenario: Dark variant fails roles

- **WHEN** a family's dark variant cannot separate accent from foreground without changing hue
- **THEN** both files are removed from the catalogue

### Requirement: Contrast gates

A resolved theme SHALL clear: `fg` on `bg` 7.0:1; `fg_muted` on `bg` 4.5:1;
`accent` on `bg`, `surface` and `elevated` 4.5:1; `accent`/`accent_fg`,
`selection_bg`/`selection_fg`, `badge_bg`/`badge_fg` and
`states.selected.bg`/`states.selected.fg` 4.5:1; `danger`, `warning`, `success`
and `info` on `bg` 3.0:1.

#### Scenario: Derived accent text

- **WHEN** `accent_fg` is omitted
- **THEN** it is computed from accent contrast and then measured against the table

#### Scenario: Selected state

- **WHEN** `states.selected` sets a background and foreground
- **THEN** that pair takes part in both the check and the repair

### Requirement: Contrast repair

A failing foreground SHALL be repaired rather than shipped: only lightness
moves in OKLab, hue stays fixed, and chroma is reduced only when sRGB requires
it. The repair SHALL take the smallest lightness change that clears the bar.
`bg` SHALL never change, and every adjustment SHALL be recorded as a warning
diagnostic for user themes.

#### Scenario: Muted text too dim

- **WHEN** `fg_muted` measures 3.9:1 on `bg`
- **THEN** its lightness is raised until it reaches 4.5:1 with the hue unchanged

#### Scenario: Mid-tone background

- **WHEN** `bg` is mid-grey and limits the best possible ratio
- **THEN** the theme keeps the best reachable ratio and the diagnostic says so

### Requirement: Role separation gates

In OKLab, UI roles SHALL stay visibly apart: `fg`/`fg_muted` at least 12 ΔE,
`fg_muted`/`border` at least 8, `accent`/`fg` at least 15, `accent`/`selection_bg`
at least 8, `surface`/`bg` between 1.5 and 12, `elevated`/`surface` at least
1.5, and `selection_fg`/`selection_bg` at least 12 ΔE while clearing 4.5:1.

#### Scenario: Accent too close to foreground

- **WHEN** an audit measures `accent`/`fg` at 9 ΔE
- **THEN** the theme is not admitted to the catalogue

#### Scenario: Surface too close to background

- **WHEN** `surface`/`bg` measures below 1.5 ΔE
- **THEN** the theme is rejected by the audit

### Requirement: Semantic and ANSI gates

`danger`, `success`, `warning` and `info` SHALL remain four separate hues. ANSI
red and green SHALL be at least 5 ΔE apart in both normal and bright slots, and
every ANSI text slot SHALL clear 2.5:1 on the background.

#### Scenario: One decorative status colour

- **WHEN** a theme uses one colour for danger and success
- **THEN** it is not admitted to the catalogue

#### Scenario: Colour-blind red/green

- **WHEN** ANSI 1 and ANSI 2 measure 3 ΔE apart
- **THEN** the theme is rejected

### Requirement: Machine-generated ANSI separation

A wallpaper-derived palette SHALL have colliding ANSI pairs separated in OKLCH,
while a pywal scheme that already separates its slots SHALL be returned
untouched. Hand-authored theme ANSI SHALL NOT be silently rewritten.

#### Scenario: Two identical blues

- **WHEN** a wallpaper palette lands ANSI 4 and 5 on the same hue
- **THEN** one slot is moved to a distinct OKLCH hue

#### Scenario: Already distinct

- **WHEN** a pywal scheme separates every ANSI slot
- **THEN** the palette is returned unchanged

### Requirement: Contrast audit tooling

The bundled files SHALL be measurable with the same repair pass used at runtime,
through `swift run ThemeRepair Resources/Themes`, so shipped files are rewritten
ahead of time instead of repaired at load.

#### Scenario: Auditing the catalogue

- **WHEN** the audit runs over `Resources/Themes`
- **THEN** every file reports its pairs and any repaired file is rewritten

### Requirement: Pruned id migration

`ThemeCuration` SHALL map every pruned id to the kept sibling variant or, when
the family is gone, to the built-in default. Launch SHALL rewrite
`theme.dark`, `theme.light`, `theming.theme` and card favourites once, and SHALL
report each move. A reference that still resolves to a user theme SHALL be left
alone.

#### Scenario: Pruned sibling

- **WHEN** config names `ghostty-catppuccin-frappe`
- **THEN** it is rewritten to `ghostty-catppuccin-mocha` with a notice

#### Scenario: Dropped family

- **WHEN** config names a theme whose whole family was removed
- **THEN** it is rewritten to the built-in default for its appearance with a notice

#### Scenario: User theme with a pruned id

- **WHEN** a file in `~/.config/palette/themes` uses a pruned id
- **THEN** the reference resolves to that user file and is not rewritten

### Requirement: Missing theme handling

A theme name that resolves to no file SHALL keep the last good theme and record
a warning, and SHALL NOT break the panel. The fallback SHALL follow the resolved
appearance.

#### Scenario: Deleted user theme

- **WHEN** the active user theme file is deleted and `⌘R` reloads
- **THEN** the last good theme stays on screen with a diagnostic

### Requirement: Theme composition

`extends` SHALL load the parent first and deep-merge the child: tables merge key
by key, scalars and arrays replace, and `states.*` merge per state. A cycle
SHALL be rejected with a diagnostic, and `default-dark`/`default-light` SHALL
always exist.

#### Scenario: Overlay theme

- **WHEN** a theme extends `default-dark` and sets only `accent`
- **THEN** every other token comes from the base

#### Scenario: Cycle

- **WHEN** two themes extend each other
- **THEN** the cycle is reported and the fallback theme loads

### Requirement: User themes win

A user theme with the same file name in `~/.config/palette/themes` SHALL override
the bundled file. Theme reload SHALL happen on `⌘R` and when the theme directory
changes.

#### Scenario: Overriding a bundled theme

- **WHEN** `~/.config/palette/themes/default-dark.toml` exists
- **THEN** it is loaded instead of the bundled Default Dark
