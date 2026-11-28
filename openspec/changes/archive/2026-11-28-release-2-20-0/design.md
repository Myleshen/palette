# Design

## Context

See [proposal.md](proposal.md). The app is built by SwiftPM, signed ad-hoc, and
released by pushing a `v*` tag; `.github/workflows/release.yml` already checks
the tag against `Resources/Info.plist`, runs the tests, builds and zips the
bundle, publishes a draft with checksums and provenance, and updates the cask.
The only new gate is OpenSpec validation in CI and before the tag.

## Goals / Non-Goals

**Goals:**

- A released 2.20.0 whose assets verify.
- The tap cask points at the new zip and checksum.
- The specs stay the baseline for the shipped build.

**Non-Goals:**

- Any behaviour change, hotfix or catalogue edit before the tag.
- A Developer ID, notarisation or App Store distribution
  ([ADR 0008](../../decisions/0008-adhoc-signing.md)).
- Archiving this change before the release is published
  ([ADR 0010](../../decisions/0010-archive-after-verification.md)).

## Decisions

1. **Version lives in `Resources/Info.plist`; the tag must match it.** The
   release workflow already enforces this, so a mistyped tag cannot publish a
   mislabelled build.
2. **Tag only from `main`.** The workflow checks ancestry, so a side-branch tag
   never reaches the release environment.
3. **Validate before tagging.** `make specs` runs
   `openspec validate --all --strict`; CI now runs the same command as its own
   step, so a broken spec blocks both the PR and the release checklist.
4. **Publish as a draft first.** Checksums and provenance are attached, then a
   verification job downloads them back before the release is considered done.
5. **No spec delta.** The baseline records the 2.20.0 behaviour; a packaging
   change must not restate it. The 2.19 → 2.20 difference stays in
   `CHANGELOG.md` and the ADRs.

## Risks / Trade-offs

- [TCC grants are re-requested after the released build replaces the local one]
  → Documented in README and `security` spec; expected under ad-hoc signing.
- [The tap deploy key is missing] → The release still publishes and the run
  warns that the cask was left behind; re-run the cask step or bump manually.
- [A spec change lands after the tag] → The release change stays open; the
  follow-up change supersedes the baseline after verification.

## Migration Plan

No data migration. Users upgrade with `brew upgrade --cask palette`; the
catalogue migration for pruned theme ids already runs on launch.

Rollback: delete the tag before publication (no number is burned). After
publication, cut a patch release rather than rewriting the tag.
