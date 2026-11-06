# Homebrew

Palette ships as a Cask from the public tap
`https://github.com/Myleshen/homebrew-tap`. It is ad-hoc signed, not notarized,
so there is no Apple Developer subscription involved. Homebrew applies the
quarantine flag to downloads, so the cask removes it in `postflight`; otherwise
Gatekeeper would refuse the unnotarized app.

Users install with:

```sh
brew install --cask Myleshen/tap/palette
```

Upgrades:

```sh
brew upgrade --cask palette
```

## Publishing a release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in
   `Resources/Info.plist`.
2. Add the release to `CHANGELOG.md`.
3. Merge the PR, then push a tag:

   ```sh
   git tag v<version>
   git push origin v<version>
   ```

4. CI does the rest: `swift test`, `make app`, `dist/Palette-<version>.zip`,
   the GitHub release (CHANGELOG entry as notes), and the `version` + `sha256`
   update in `Casks/palette.rb` in `Myleshen/homebrew-tap`.

`Scripts/release.sh` still exists for a local unsigned build and to refresh
`packaging/homebrew/Casks/palette.rb`, which is now a reference copy: the tap is
what users install and CI keeps it current.

## Why a Cask instead of a Formula

The product is a GUI `.app` bundle, so a Cask is the right Homebrew shape.
A source-building Formula was considered, but it would make every user install
Xcode Command Line Tools and build Swift for several minutes. A Cask download
is faster and matches how other launchers are distributed.

## Signing

The app is signed with `codesign --sign -` because notarization requires a paid
Apple Developer account. The tap's `postflight` clears the download quarantine
so the app opens normally. A manual zip download may still be quarantined; allow
it in System Settings > Privacy & Security.

Notarization can be added later without changing the Cask: sign with a Developer
ID, notarize, and upload the stapled zip. The Cask's `sha256` then changes and
nothing else does.

## Dependencies

`fd` and `fzf` are declared as Cask dependencies because `/neo` and `/neof` need
them. `zellij`, `kitty`, and `bw` stay optional: the relevant providers show an
install row if they are missing.
