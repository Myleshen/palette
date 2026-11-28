# Release Process Specification

## Purpose

How a change becomes a shipped build: worktrees, PR and CI gates, versioning and
tagging, the release workflow, the Homebrew tap, and when a change is archived.
See [ADR 0010](../../decisions/0010-archive-after-verification.md) and
[ADR 0008](../../decisions/0008-adhoc-signing.md).

## Requirements

### Requirement: Worktree work

Code work SHALL happen in a git worktree under `~/dev/.worktrees/palette/`, not
the main checkout, and build caches SHALL be shared rather than rebuilt per
worktree. Build artefacts, `node_modules` and secrets SHALL never be committed.

#### Scenario: Working on a change

- **WHEN** a feature branch is started
- **THEN** it lives in its own worktree and the main checkout stays clean

### Requirement: Proposal before code

Every code change SHALL have an OpenSpec change proposal before implementation,
including refactors, fixes and test-only work. Pure documentation edits SHALL be
the only exception. A change SHALL be named kebab-case for the behaviour it
changes (`add-theme-deck`, `fix-revert-clobber`); a release change SHALL be used
only for packaging and version work.

#### Scenario: A bug fix

- **WHEN** a fix changes behaviour
- **THEN** a `fix-…` change exists with its delta specs before code merges

#### Scenario: Docs-only edit

- **WHEN** a change touches only Markdown or HTML docs
- **THEN** no OpenSpec change is required

### Requirement: Spec validation gate

CI SHALL run `openspec validate --all --strict` as its own failing step.
`make specs` SHALL run the same command locally, and the release checklist SHALL
include it.

#### Scenario: Invalid spec

- **WHEN** a spec has a requirement without a WHEN/THEN scenario
- **THEN** CI fails on the validation step

#### Scenario: Local check

- **WHEN** the author runs `make specs`
- **THEN** every spec and pending change is validated

### Requirement: Pull request and merge

A change SHALL reach `main` through a pull request with CI green, then a squash
merge. A PR SHALL NOT be opened and a tag SHALL NOT be pushed without an
explicit request in that turn.

#### Scenario: Green PR

- **WHEN** CI passes on the pull request
- **THEN** the PR is squash merged and the branch deleted

#### Scenario: No request

- **WHEN** the work is finished but the user did not ask for a PR
- **THEN** the branch stays local

### Requirement: Version and changelog

A release SHALL bump `CFBundleShortVersionString` and `CFBundleVersion` in
`Resources/Info.plist` and add a `CHANGELOG.md` entry before the tag. The tag
SHALL be `v<version>` and SHALL match the plist exactly.

#### Scenario: Version mismatch

- **WHEN** the tag is `v2.21.0` and the plist says `2.20.0`
- **THEN** the release workflow refuses to publish

### Requirement: Tag must be on main

The release workflow SHALL refuse a tag whose commit is not an ancestor of
`origin/main`, so a side branch can never publish.

#### Scenario: Tag on a branch

- **WHEN** a `v*` tag is pushed on a feature branch
- **THEN** the release job fails before building

### Requirement: Release artefacts

The release workflow SHALL run the tests, build the app bundle, publish
`Palette-<version>.zip` and `SHA256SUMS` as a draft with the CHANGELOG entry as
notes, attach GitHub build provenance, and verify the assets after publishing.

#### Scenario: Successful release

- **WHEN** a valid tag is pushed
- **THEN** a draft release holds the zip, checksums and provenance
- **AND** the verification job confirms both checksum and signature

### Requirement: Homebrew tap

The release SHALL update the cask in `Myleshen/homebrew-tap` to the new version
and checksum. Installing SHALL require `brew trust --tap Myleshen/tap` once and
SHALL clear the quarantine flag because the app is ad-hoc signed.

#### Scenario: First install

- **WHEN** a user runs `brew install --cask Myleshen/tap/palette` for the first time
- **THEN** Homebrew may ask to trust the tap, then installs and clears quarantine

### Requirement: Debug build isolation

`make debug-app` SHALL build `Palette Debug.app` with
`dev.myleshen.palette.debug` and separate config, state, cache and support
directories, launch it through LaunchServices so TCC attributes to the debug
bundle, and SHALL NOT read or write the installed app's data.

#### Scenario: Debug permission prompt

- **WHEN** the debug app first needs Accessibility
- **THEN** the prompt names Palette Debug, not the terminal that launched it

### Requirement: Build artefact hygiene

Debug builds and temporary build artefacts SHALL be deleted when the task is
done, and a task SHALL NOT leave background processes or stray Palette
instances behind.

#### Scenario: Finishing a UI task

- **WHEN** the debug build is no longer needed
- **THEN** it is removed and no Palette process is left running

### Requirement: Archive after verification

A change SHALL be archived only after its behaviour is verified on the merged
tree. A release change SHALL stay open until its tag exists and the release is
published; archiving it SHALL be the last step.

#### Scenario: Feature change

- **WHEN** the feature is merged and its scenarios pass on `main`
- **THEN** the change is archived and its specs become the baseline

#### Scenario: Release change

- **WHEN** the release change is written but the tag is not pushed
- **THEN** the change stays open

### Requirement: Test gates

Before a PR, the author SHALL run `make test`, the affected end-to-end flows and
`make layout-check` after UI changes, and SHALL state what was run. `make test`,
`make e2e` and `make layout-check` SHALL run at low priority so they yield to
the user.

#### Scenario: UI change

- **WHEN** a UI change is proposed
- **THEN** the layout check and a rendered screenshot are part of the evidence
