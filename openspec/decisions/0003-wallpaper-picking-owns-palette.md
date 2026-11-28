# 0003. Picking a wallpaper owns the palette when the source is wallpaper

- Status: accepted
- Date: 2026-11-27

## Context

A wallpaper card can mean two things: "change my desktop picture" and "give me
the colours of this picture". 2.19 sometimes enabled cross-app theming as a side
effect of picking a picture, which surprised users and made the desktop change
depend on an unrelated toggle. The source (`theme` or `wallpaper`) already
exists, but nothing tied it to the card action.

## Options considered

- **Always sample the new picture.** One keystroke for the wallpaper-colour flow,
  but a desktop change silently repaints every app and can leave `[theme]`
  naming a palette that no longer matches.
- **Never sample from a card; require a separate Apply.** Predictable, but the
  documented "one keystroke" flow disappears.
- **Sample only when cross-app theming is on and `source = "wallpaper"`.**
  Explicit source, explicit opt-in.

## Decision

Applying a picture card sets the picture on every screen first. Only when
theming is enabled **and** `source = "wallpaper"` does it sample the picture and
apply the palette; otherwise only the picture changes and the status line says
the palette was left alone. While `source = "wallpaper"`, a colour card is
refused with a message until the source is set back to Theme. `follow_wallpaper`
re-checks the desktop URL every five seconds.

## Consequences

- The card action is predictable: it never turns theming on by itself.
- With `source = "wallpaper"` the picture, launcher, terminal and generated
  files move together, which is the intended flow.
- Users who want both a new picture and a new theme set the source once, not per
  card.

## Links

- [specs/theme-deck](../specs/theme-deck/spec.md)
- [specs/theming](../specs/theming/spec.md)
