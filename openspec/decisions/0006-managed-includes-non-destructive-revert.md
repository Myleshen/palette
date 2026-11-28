# 0006. Managed include blocks with a non-destructive, non-stacking Revert

- Status: accepted
- Date: 2026-11-27

## Context

Cross-app theming edits configs Palette does not own. 2.19 kept a first-install
snapshot and Revert restored it, which deleted every setting the user added
after the first Apply. Revert could also stack: a second Revert walked further
back. A partial failure could leave a half-written config.

## Options considered

- **Own the whole config file.** Simple to generate, destroys user edits.
- **Snapshot and restore the whole file.** Restores edits made before the
  snapshot but loses later ones, and stacking is ambiguous.
- **Edit only a marked block; Revert removes blocks and rolls the generated set
  back one step.**

## Decision

Palette only changes an app config inside
`# >>> palette theme >>>` / `# <<< palette theme <<<`, using that file's comment
token. Unchecking one target removes one block; disabling theming removes all.
Revert strips the blocks, restores the previous generated set in one atomic
step, keeps edits outside the block, and does not stack. A Palette-created file
is deleted only when nothing else remains. A failed Revert leaves no partial
state and is retryable. Backup copies remain under `theme/previous/` for manual
restoration.

## Consequences

- User edits outside the block always survive.
- There is exactly one block per file after any number of applies.
- Revert restores the palette set, not the launcher's own theme.
- A target whose config is unreadable reports the path without blocking others.

## Links

- [specs/theming](../specs/theming/spec.md)
