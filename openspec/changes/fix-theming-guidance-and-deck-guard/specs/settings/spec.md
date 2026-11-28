## ADDED Requirements

### Requirement: Theming conflict recommendations

Palette SHALL scan the supported apps' configuration files for directives that
override the generated palette and SHALL show each conflict with its file, line,
what it overrides and how to fix it, without modifying those files.

#### Scenario: LazyVim sets a colorscheme

- **WHEN** the user's nvim config sets `colorscheme` in a plugin spec
- **THEN** Recommendations lists that file and line and suggests removing it or
  disabling the LazyVim colorscheme option

#### Scenario: Clean configuration

- **WHEN** no scanning rule matches
- **THEN** no Recommendations card is shown

### Requirement: Apply summary mentions conflicts

After an apply, when blocking conflicts exist, the status SHALL name their count
and point to Recommendations.

#### Scenario: Apply with conflicts

- **WHEN** a palette is applied while a blocking conflict is detected
- **THEN** the status includes the number of conflicts and where to read them
