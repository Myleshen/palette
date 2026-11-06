# Contributing

Palette is a SwiftPM macOS app: SwiftUI shell, one package, no Xcode project.

## Build and test

```sh
make test     # swift test
make          # release .app bundle at build/Palette.app
make run      # build and launch it
```

`swift test` runs the whole suite. Provider tests skip themselves when their
external tool (`fd`, `fzf`, `python3`, `bw`) is missing, so a green run locally
does not prove the provider works; the manual checks for that are in
`TESTING.md`.

## Where things live

| Path | What it is |
| --- | --- |
| `Sources/PaletteApp` | App shell: delegate, launcher window, settings, onboarding |
| `Sources/PaletteCore` | Parsing, ranking, calculator, snippets, themes, config |
| `Sources/PalettePlatform` | macOS pieces: hotkey, pasteboard, database, icons, keep-awake |
| `Sources/PaletteProviders` | One file per `/slash` provider |
| `Sources/PaletteRuntime` | External provider process, NDJSON protocol |
| `Tests/PaletteTests` | The test suite |
| `Resources/` | Info.plist, app icon, bundled themes, providers, examples |
| `Scripts/` | Icon generation and the local `release.sh` helper |

Deeper notes: `ARCHITECTURE.md`, `PROVIDERS.md`, `THEMING.md`, `TESTING.md`.

## Rules of the road

- `main` takes pull requests only: a PR and a green `build` check are required,
  and force-pushes and deletions are blocked. There are no bypass actors.
- No version bump in a PR. The maintainer sets the version and tags the release.
- User-visible changes get a `CHANGELOG.md` entry: a `## x.y.z — YYYY-MM-DD`
  heading with `Added` / `Changed` / `Fixed` / `Verified` sections.
- New behaviour gets a test. Prefer a unit test in `Tests/PaletteTests`; the
  fake-based patterns in `KeepAwakeTests` are the model for anything touching
  system services.
- No new dependencies without a reason. The package stays small on purpose.

## Pull requests

CI builds every PR: `swift test`, then `make app`, then an arch check. Fix the
red check rather than admin-merging; the `build` check is what stands between a
merge and a release.

## Releasing

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist` (and
   `CFBundleVersion`, which Settings shows alongside it).
2. Add the `CHANGELOG.md` entry. Its text becomes the release body.
3. Merge the PR.
4. Tag and push:

   ```sh
   git tag v2.2.3
   git push origin v2.2.3
   ```

Tagging is the release. `.github/workflows/release.yml` refuses a tag that
disagrees with `Resources/Info.plist`, runs the tests, builds the app, publishes
`Palette-<version>.zip` with the CHANGELOG entry as notes, and moves `palette.rb`
in [Myleshen/homebrew-tap](https://github.com/Myleshen/homebrew-tap) so users get
it with `brew upgrade --cask palette`.

If the run fails before publishing, delete the tag, fix, and tag again — no
release number is burned, because nothing was published. The cask step needs the
`TAP_DEPLOY_KEY` secret: the private half of an SSH deploy key with write access
to the tap. Without it the release still publishes and the run warns that the
cask was left behind.
