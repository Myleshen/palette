# 0008. Ship ad-hoc signed without notarisation or hardened runtime

- Status: accepted
- Date: 2026-11-27

## Context

Palette needs Accessibility, Screen Recording and Apple Events to paste, capture
and drive other apps. It is not sandboxed and is not distributed through the App
Store. An Apple Developer account, Developer ID certificate and notarisation
would cost money and add a signing pipeline; the app is maintained by one person
and installed through a Homebrew tap.

## Options considered

- **Developer ID + notarisation.** Removes the Gatekeeper warning and stabilises
  TCC grants, but needs a paid account, hardened runtime entitlements and a
  notarisation step on every release.
- **Unsigned zip.** Worst TCC behaviour and the most warnings.
- **Ad-hoc signing (`codesign --sign -`) with a fixed bundle id.** Keeps a
  stable designated requirement without an account.

## Decision

The app is ad-hoc signed with the bundle id `dev.myleshen.palette`, no hardened
runtime, no library validation and no notarisation. The Homebrew cask clears the
quarantine flag. TCC grants are keyed only to the bundle identifier, so a rebuild
may re-request Accessibility or Screen Recording, and any app with the same
identifier can inherit a grant. The README warns to run only self-built or
official builds. Debug builds use a separate bundle id and data directories.

## Consequences

- No Apple account or notarisation dependency.
- Rebuilds may prompt for permissions again; this is documented and expected.
- The trust model is explicit: the bundle id is not a security boundary.
- A future Developer ID would supersede this ADR, not silently change it.

## Links

- [specs/security](../specs/security/spec.md)
- [specs/release-process](../specs/release-process/spec.md)
