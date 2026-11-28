# 0004. Extract wallpaper palettes with pywal's pipeline and separate ANSI only there

- Status: accepted
- Date: 2026-11-27

## Context

2.19's wallpaper palette was a custom quantiser. It produced a saturated
mid-tone background for light pictures, ANSI 1–6 were fixed semantic hues rather
than the image's colours, and two slots could land on the same hue. pywal is the
reference implementation users already run for terminal palettes.

## Options considered

- **Keep the custom extractor and tune it.** No new dependency, but it would
  keep diverging from pywal and still need its own slot rules.
- **Shell out to pywal.** Exact parity, but adds an external tool requirement
  and a process per apply.
- **Reimplement pywal's pipeline in Swift and validate against pywal.** Parity
  without a runtime dependency.

## Decision

Wallpaper palettes use pywal's pipeline: quantise to sixteen colours, order dark
to light, pour into `color0`…`color15`, with `color0` as background and
`color15` as foreground. `saturation` and `contrast` mirror `--saturate` and
`--contrast`. Slots 1–14 are the image's own colours. The result was validated
slot-for-slot against pywal 3.8.15 on real wallpapers.

Machine-generated ANSI collisions are repaired in OKLCH by
`PalettePalette.distinctANSI`. Hand-authored theme ANSI is never rewritten: a
port whose accent is its ANSI blue may repeat that hue.

## Consequences

- A light wallpaper gets a light background rather than a saturated mid-tone.
- Two identical blues cannot come out of a wallpaper apply.
- The Swift pipeline must be kept in step with pywal if its algorithm changes;
  the parity test is the guard.

## Links

- [specs/theming](../specs/theming/spec.md)
- [specs/theme-catalogue](../specs/theme-catalogue/spec.md)
