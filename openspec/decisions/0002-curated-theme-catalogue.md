# 0002. Curate 69 families / 138 themes behind contrast and role gates

- Status: accepted
- Date: 2026-11-27

## Context

2.19 shipped 933 bundled theme files imported from ports. An audit measured
them against the contrast table and found authored failures (worst 2.68:1),
themes whose accent and foreground were the same hue, status colours collapsed
into one decorative colour, and light variants that were washed-out copies of
their dark sibling. A large catalogue also made the deck slow and the theme list
noisy.

## Options considered

- **Ship all 933 and repair at runtime.** Every theme would keep working, but
  the picker stays noisy and the deck has to load hundreds of files.
- **Ship all 933 with a "broken" badge.** Pushes the decision to the user and
  keeps unusable themes in the product.
- **Cut to families that clear the gates, one dark and one light each.** A
  smaller catalogue where every card is usable, with a migration for saved ids.

## Decision

The bundled catalogue is 69 families (138 files). A family ships only if both
variants clear the contrast table and the role-separation gates, keep four
distinct status hues, keep ANSI red and green at least 5 ΔE apart and every ANSI
text slot at 2.5:1. A failing foreground is repaired in OKLab by lightness only;
`bg` never changes. 795 themes were removed and `ThemeCuration` maps every pruned
id to its kept sibling or the built-in default on launch.

## Consequences

- The deck opens in 17 ms and every card preview is usable.
- Saved references never dangle: config and card favourites are rewritten once.
- Families without a light port (Dracula, Sonokai, Oxocarbon, Vesper, Zenburn)
  and families that cannot separate accent from foreground (Seoul Bones) are
  gone.
- A contributor adding a theme must pass the audit before it ships.

## Links

- [specs/theme-catalogue](../specs/theme-catalogue/spec.md)
- [specs/accessibility](../specs/accessibility/spec.md)
