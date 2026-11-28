# Proposal

## Why

2.20.0 is implemented and has a CHANGELOG entry, but the release has not been
tagged. The work is merged on `main` and needs the packaging and publication
steps that turn it into a shipped build.

## What Changes

- Ship the 2.20.0 build already on `main`: fanned theme cards and wallpaper
  cards, the curated 138-theme catalogue, pywal wallpaper palettes, Starship
  theming, the accessibility pass and the Revert/config/security fixes.
- No behaviour is added by this change. The baseline specs were written from the
  2.20.0 tree, so they already describe the shipped behaviour; the 2.19 → 2.20
  difference is recorded in `CHANGELOG.md` and in the ADRs under
  `openspec/decisions/` rather than as a delta here.

## Capabilities

### New Capabilities

None. The baseline under `openspec/specs/` already describes 2.20.0, including
`theming`, `theme-deck`, `theme-catalogue`, `accessibility`, `security` and
`release-process`.

### Modified Capabilities

None. Under [ADR 0001](../../decisions/0001-adopt-openspec.md) a
`release-<version>` change is packaging-only, so `.openspec.yaml` sets
`skip_specs: true`. A behaviour change in 2.20.0 would have had its own
feature change; none is pending.

## Impact

- `Resources/Info.plist` version, `CHANGELOG.md`, git tag `v2.20.0`.
- `.github/workflows/release.yml` publishes the draft, assets and provenance and
  bumps `Myleshen/homebrew-tap`.
- No source, config or generated-file behaviour changes.
