## ADDED Requirements

### Requirement: System appearance follows the palette

With `system_appearance = "auto"`, applying a light or dark palette SHALL switch
the macOS appearance to match it, and SHALL report when the automation
permission is denied rather than failing silently.

#### Scenario: Light palette while macOS is dark

- **WHEN** a light theme is applied and macOS is in dark mode
- **THEN** macOS switches to light and the apply reports it

#### Scenario: Off

- **WHEN** `system_appearance = "off"`
- **THEN** the macOS appearance is never changed

#### Scenario: Permission denied

- **WHEN** the System Events automation is denied
- **THEN** the palette still applies and a notice names the permission
