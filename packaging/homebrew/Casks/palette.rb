cask "palette" do
  version "2.0.4"
  sha256 "b3f09a88f3698fb165cdab2b2f1123beba4ecbcaaf1e6dd713b6f2293d8fa621"

  url "https://github.com/Myleshen/palette/releases/download/v#{version}/Palette-#{version}.zip"
  name "Palette"
  desc "Keyboard-first launcher with extensible providers"
  homepage "https://github.com/Myleshen/palette"

  depends_on macos: :sonoma
  depends_on formula: "fd"
  depends_on formula: "fzf"

  app "Palette.app"

  # Ad-hoc signed, so Gatekeeper cannot verify it; clear the download flag the
  # same way `--no-quarantine` does for other unsigned casks.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "/Applications/Palette.app"]
  end

  uninstall quit: "dev.myleshen.palette"

  zap trash: [
    "~/.config/palette",
    "~/.local/state/palette",
    "~/Library/Caches/Palette",
    "~/Library/Preferences/dev.myleshen.palette.plist",
  ]

  caveats <<~EOS
    Palette is free and ad-hoc signed, so it is not notarized by Apple. If macOS
    blocks the first launch, allow it in System Settings > Privacy & Security, or
    reinstall with:
      brew install --cask --no-quarantine Myleshen/tap/palette

    Grant Accessibility to enable direct paste:
      System Settings > Privacy & Security > Accessibility

    Config and providers: ~/.config/palette
    Logs: ~/.local/state/palette/palette.log
  EOS
end
