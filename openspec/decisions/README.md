# Decision records

Short ADRs for choices that shape Palette's behaviour or process. A decision
record explains why; a capability spec explains what the product must do. When a
decision changes the contract, update the spec through an OpenSpec change and
supersede the ADR instead of editing history.

## Format

Each file is `NNNN-kebab-title.md`:

```
# NNNN. Title

- Status: proposed | accepted | superseded by NNNN
- Date: YYYY-MM-DD

## Context
## Options considered
## Decision
## Consequences
## Links
```

Add a row to the index when a record is added. A significant choice — new
dependency, data model, security or migration policy, cross-cutting workflow —
needs an ADR; a routine implementation detail does not. See
[decision-tree.md](decision-tree.md).

## Index

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-adopt-openspec.md) | Adopt OpenSpec with specs as the behavioural source of truth | accepted |
| [0002](0002-curated-theme-catalogue.md) | Curate 69 families / 138 themes behind contrast and role gates | accepted |
| [0003](0003-wallpaper-picking-owns-palette.md) | Picking a wallpaper owns the palette when the source is wallpaper | accepted |
| [0004](0004-pywal-wallpaper-extraction.md) | Extract wallpaper palettes with pywal's pipeline and separate ANSI only there | accepted |
| [0005](0005-theme-deck-geometry.md) | Bottom-anchored arc deck on the pointer's screen | accepted |
| [0006](0006-managed-includes-non-destructive-revert.md) | Managed include blocks with a non-destructive, non-stacking Revert | accepted |
| [0007](0007-silent-chromium-managed-policy.md) | Theme Chromium browsers through the user-scoped managed plist | superseded by 2.20.1 |
| [0008](0008-adhoc-signing.md) | Ship ad-hoc signed without notarisation or hardened runtime | accepted |
| [0009](0009-strict-ssrf-url-policy.md) | Strict SSRF policy for every automatic fetch and redirect | accepted |
| [0010](0010-archive-after-verification.md) | Archive an OpenSpec change only after merged-tree verification | accepted |

## Other maps

- [matrix.md](matrix.md): capability → code entry points → surfaces → tests.
- [decision-tree.md](decision-tree.md): which workflow a task needs.
