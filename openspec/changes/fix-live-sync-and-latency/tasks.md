# Tasks

## 1. Theming

- [ ] 1.1 Add a launch-time palette push to running kitty, reusing the existing
  socket reload rather than rewriting files.
- [ ] 1.2 Run it after a successful launch repair and when the app starts with
  theming enabled and a starting kitty present.
- [ ] 1.3 Test: a launched app pushes once, does not push when theming is off,
  and never rewrites the generated files.

## 2. Theme deck thumbnails

- [ ] 2.1 Decode wallpaper thumbnails with bounded concurrency instead of one
  serial queue.
- [ ] 2.2 Keep the existing two-level cache and the palette-colour placeholder.
- [ ] 2.3 Test: a cold visible window completes in under 1 s on this machine's
  wallpapers, and the warm path is unchanged.

## 3. Provider first response

- [ ] 3.1 Prewarm `bw status` at launch so the first `/bw` does not pay the CLI
  cost.
- [ ] 3.2 Run the GitHub PR and issue queries concurrently.
- [ ] 3.3 Test: cached status is used for the first search, and the two GitHub
  calls overlap instead of summing.

## 4. Verify

- [ ] 4.1 `swift build` with zero warnings, targeted tests for each fix.
- [ ] 4.2 Full suite, e2e, layout, `make specs` on the merged tree.
- [ ] 4.3 Reinstall and measure the three numbers again.
