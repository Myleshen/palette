# Decision tree

How to pick the workflow. Commands assume the OpenSpec CLI is installed.

## 1. What is the task?

| Task | Workflow |
|---|---|
| Pure documentation edit (README, HTML notes, comments only) | Edit directly; no change. Run `atlas` for HTML/Markdown artifacts. |
| New behaviour in a new area | `openspec new change add-<thing>` with a new capability spec (include `## Purpose`). |
| Behaviour change in an existing capability | `openspec new change <verb>-<thing>` with a MODIFIED delta copied from the whole existing requirement block. |
| Bug fix that restores behaviour the spec already states | `openspec new change fix-<thing>`; set `skip_specs: true` in `.openspec.yaml` and add a regression test. If the spec was wrong or silent, add the missing delta instead. |
| Refactor or test-only work with no observable change | `openspec new change refactor-<thing>`; `skip_specs: true`. |
| Version bump, changelog, tag, brew | `openspec new change release-<version>`; packaging only, `skip_specs: true`. Stays open until the tag exists. |
| Reversal of a previous decision | New change plus a new ADR that supersedes the old one. Do not edit the old ADR. |

Naming is kebab-case and describes the behaviour, not the implementation:
`add-theme-deck`, `fix-revert-clobber`, `release-2-20-0`.

## 2. Does the change need a spec delta?

- **New capability**: yes. `specs/<capability>/spec.md` with `## Purpose` and
  `## ADDED Requirements`. Every requirement needs a WHEN/THEN scenario.
- **Changed behaviour**: yes. `## MODIFIED Requirements` with the entire
  existing requirement block, edited. A partial copy loses detail at archive.
- **Removed behaviour**: yes. `## REMOVED Requirements` with **Reason** and
  **Migration**.
- **No observable change**: `skip_specs: true`. Do not invent a requirement.
- **Rename only**: `## RENAMED Requirements` with FROM/TO.

## 3. Does it need a `design.md`?

Yes when any of these is true:

- more than one module or surface changes (launcher + Settings + generated file);
- a new dependency, process, file format or data model;
- security, privacy, performance or migration risk;
- the approach is ambiguous or two options are close.

Otherwise put the approach in the proposal and skip design.md.

## 4. Does it need an ADR?

Yes for a significant choice someone will ask "why?" about later:

- a new external dependency or a new trust boundary;
- a data model, migration or deletion policy;
- a security or privacy rule (URL policy, secret storage, signing);
- a cross-cutting workflow change (OpenSpec itself, release, archive);
- reversing an accepted decision.

No for routine implementation choices, naming, or a library used inside one
file. Record the ADR as `openspec/decisions/NNNN-kebab-title.md`, add it to the
index, and link it from the affected spec or design.

## 5. Implement and verify

1. `openspec validate <change> --strict` before code.
2. Write the code and the tests the scenarios imply.
3. `make test`; `make e2e` for bundle behaviour; `make layout-check` after UI.
4. `make specs` (`openspec validate --all --strict`).
5. Exercise the changed behaviour on the merged tree: a test, a scripted dump,
   or a recorded manual check.

## 6. Merge, release, archive

- PR → CI green → squash merge. No PR or tag without an explicit request.
- Release: bump `Resources/Info.plist`, add the CHANGELOG entry, merge, push
  `v<version>`. The workflow checks the tag is on `main` and matches the plist.
- Archive a feature or fix change only after verification on `main`:
  `openspec archive <change>`.
- Archive the release change only after the tag is pushed and the release is
  published.
- If a merged change is reverted, reopen or supersede it; never leave an
  archived spec describing behaviour the product does not have.
