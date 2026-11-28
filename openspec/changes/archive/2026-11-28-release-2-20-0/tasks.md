# Tasks

## 1. Verify the build

- [ ] 1.1 Run `make test` on the release tree and confirm the suite is green.
- [ ] 1.2 Run `make specs` and confirm `openspec validate --all --strict` passes.
- [ ] 1.3 Run `make e2e` with no installed Palette running, then `make layout-check`.
- [ ] 1.4 Manual pass on the deck: arrow keys, type-to-filter, Tab favourites, Return apply, Esc, preview, Reduce Motion, second display and a portrait frame.
- [ ] 1.5 Manual pass on theming: apply, uncheck one target, Revert twice, reset the pane, and confirm hand edits outside the block survive.
- [ ] 1.6 Manual pass on capture: `⌘⇧3/4/6`, a recording with audio, pins to the ninth, OCR and the annotator crop.
- [ ] 1.7 Manual pass on Ask: a saved chat, web search on and off, an https-image answer, and a key save/restart.

## 2. Version and changelog

- [ ] 2.1 Confirm `CFBundleShortVersionString` is `2.20.0` and `CFBundleVersion` is bumped in `Resources/Info.plist`.
- [ ] 2.2 Confirm the `CHANGELOG.md` `## 2.20.0` entry is complete and is the release body.

## 3. PR and CI

- [ ] 3.1 Open the PR for the release branch.
- [ ] 3.2 Confirm the CI `build` job is green, including the `Validate specs` step.
- [ ] 3.3 Squash merge to `main`.

## 4. Tag and publish

- [ ] 4.1 Push `v2.20.0` from `main` and confirm the release workflow accepts it.
- [ ] 4.2 Confirm the draft release carries `Palette-2.20.0.zip`, `SHA256SUMS` and provenance.
- [ ] 4.3 Confirm the post-release verification job passes the checksum and signature checks.
- [ ] 4.4 Publish the draft.

## 5. Homebrew

- [ ] 5.1 Confirm `palette.rb` in `Myleshen/homebrew-tap` points at 2.20.0 with the new checksum.
- [ ] 5.2 `brew update && brew upgrade --cask palette`, then confirm the installed version and that quarantine is cleared.

## 6. Archive

- [ ] 6.1 Re-run `make specs` on `main` after the tag and confirm the baseline still matches.
- [ ] 6.2 Archive this change with `openspec archive release-2-20-0` only after 4.4 and 5.2 are done.
