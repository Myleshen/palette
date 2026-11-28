# 0001. Adopt OpenSpec with specs as the source of truth

- Status: accepted
- Date: 2026-11-28

## Context

Palette's behaviour was documented in README.md, THEMING.md, TESTING.md and
CHANGELOG.md. Those guides are readable but not testable, and they drift: a
release note and a guide could disagree about Revert, and nothing failed when a
documented branch was missing from the code. The product is a single macOS app
with no external API, so behaviour lives in the panel, Settings, the terminal,
the generated app files and the release process.

## Options considered

- **Keep prose guides only.** No new tooling, but no validation and no place for
  a pending proposal to live.
- **Adopt a full issue tracker.** More process than a single-maintainer repo
  needs; issues do not describe behaviour precisely.
- **Adopt OpenSpec with one capability per behaviour area.** Adds a validator,
  delta specs and an archive step, and keeps the guides.

## Decision

`openspec/specs/` is the behavioural source of truth. README, THEMING and
TESTING stay as guides and link to the capability specs. Every code change gets
a kebab-case change under `openspec/changes/` before implementation; only pure
documentation edits are exempt. `openspec validate --all --strict` gates CI and
the release checklist. Significant technical choices are recorded as ADRs under
`openspec/decisions/`.

## Consequences

- A behaviour change has to state its scenarios before code, and CI fails on a
  requirement without a WHEN/THEN scenario or an over-long description.
- The guides must not restate a rule that lives in a spec; they point at it.
- The release change is packaging-only, so behaviour and version work cannot
  hide in one change.
- Contributors must install the OpenSpec CLI (`@fission-ai/openspec`).

## Links

- [specs/launcher](../specs/launcher/spec.md)
- [decision-tree.md](decision-tree.md)
- [matrix.md](matrix.md)
