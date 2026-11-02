# Homebrew

Palette ships as a Cask. It is ad-hoc signed, not notarized, so there is no
Apple Developer subscription involved. Homebrew downloads the release zip
without the quarantine flag, so the installed app opens normally.

## First release

1. Run `./scripts/release.sh`. It builds the bundle, writes
   `dist/Palette-<version>.zip`, updates the version and checksum in
   `Casks/palette.rb`, and prints the upload instructions.
2. Create the GitHub release `v<version>` in `Myleshen/palette` and upload the
   zip.
3. Create a tap repository named `Myleshen/homebrew-tap` and copy
   `Casks/palette.rb` into its `Casks/` directory.

Users install with:

```sh
brew install --cask Myleshen/tap/palette
```

Upgrades:

```sh
brew upgrade --cask palette
```

## Why a Cask instead of a Formula

The product is a GUI `.app` bundle, so a Cask is the right Homebrew shape.
A source-building Formula was considered, but it would make every user install
Xcode Command Line Tools and build Swift for several minutes. A Cask download
is faster and matches how other launchers are distributed.

## Signing

The app is signed with `codesign --sign -` because notarization requires a paid
Apple Developer account. That is enough for local use and Homebrew installs.
If someone downloads the zip manually, macOS may quarantine it; they can use
System Settings > Privacy & Security > Open Anyway.

Notarization can be added later without changing the Cask: sign with a Developer
ID, notarize, and upload the stapled zip. The Cask's `sha256` then changes and
nothing else does.

## Dependencies

`fd` and `fzf` are declared as Cask dependencies because `/neo` and `/neof` need
them. `zellij`, `kitty`, and `bw` stay optional: the relevant providers show an
install row if they are missing.
