# 0010. Archive an OpenSpec change only after merged-tree verification

- Status: accepted
- Date: 2026-11-28

## Context

OpenSpec archives a change by merging its delta into the main specs. Archiving
at "code written" would make the baseline claim behaviour that has never run on
`main`, and a later revert or a failed CI run would leave the specs ahead of the
product. Release changes add a second gate: the tag is the release.

## Options considered

- **Archive when tasks are checked off locally.** Fast, but the merge and the
  real build are unverified.
- **Archive at PR open.** Worse: review can still change behaviour.
- **Archive only after the behaviour is verified on the merged tree; keep a
  release change open until its tag exists.**

## Decision

A feature or fix change is archived after it is merged and its scenarios have
been exercised on `main` (tests, e2e, a scripted dump or a manual check recorded
in the change). A `release-<version>` change stays open until the `v<version>`
tag is pushed and the release workflow publishes. Archiving is the last step,
and the archive commit carries the final spec state.

## Consequences

- The baseline never describes unmerged or unreleased behaviour.
- A release change is a live checklist until the tag, not a plan.
- If a merged change is reverted, its change is reopened or superseded rather
  than left archived.

## Links

- [specs/release-process](../specs/release-process/spec.md)
- [decision-tree.md](decision-tree.md)
