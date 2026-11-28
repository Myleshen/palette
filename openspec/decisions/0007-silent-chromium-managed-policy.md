# 0007. Theme Chromium browsers through the user-scoped managed plist

- Status: accepted
- Date: 2026-11-27

## Context

Chromium browsers accept a `BrowserThemeColor` managed preference, but the
only path in 2.19 was a `.mobileconfig` profile the user approved under Device
Management, then re-approved after every palette change. That made a live
theming feature into a settings chore and left stale profiles behind.

## Options considered

- **Keep the profile flow.** No admin step to build, but re-approval per apply
  and untrusted-profile warnings.
- **Edit each browser's Local State or Preferences.** Undocumented, per-profile,
  and likely to be overwritten or corrupt the browser.
- **Write the user-scoped managed preference plist once enabled.**

## Decision

Palette writes `BrowserThemeColor` to
`/Library/Managed Preferences/<user>/<bundleID>.plist`. The first enable is the
only administrator step: it removes old Palette profiles, creates the plist,
hands it to the user and seeds the current colour. Later applies rewrite it as
the user with no prompt. A running browser is asked to refresh with
`--refresh-platform-policy --no-startup-window`; if that fails the row says a
restart picks the colour up. The `.mobileconfig` download and a Remove action
remain. Helium is always supported; Chrome, Edge, Brave, Vivaldi and Chromium
are supported when installed.

## Consequences

- A palette change recolours every profile of a browser at once.
- The colour is app-wide and approximate, not a per-window theme.
- Enable and Remove are the only password prompts.
- A stale palette profile from an earlier version is cleaned up on enable.

## Links

- [specs/theming](../specs/theming/spec.md)
