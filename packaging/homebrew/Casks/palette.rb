cask "palette" do
  version "1.1.0"
  sha256 "45cdf8157bcf7c4780e2d83d09ca4063bf596a8e971830f695b6fd0ec82960c6"

  url "https://github.com/Myleshen/palette/releases/download/v#{version}/Palette-#{version}.zip"
  name "Palette"
  desc "Keyboard-first launcher with extensible providers"
  homepage "https://github.com/Myleshen/palette"

  depends_on macos: ">= :sonoma"
  depends_on formula: "fd"
  depends_on formula: "fzf"

  app "Palette.app"

  uninstall quit: "dev.myleshen.palette"

  zap trash: [
    "~/.config/palette",
    "~/.local/state/palette",
    "~/Library/Caches/Palette",
    "~/Library/Preferences/dev.myleshen.palette.plist",
  ]

  caveats <<~EOS
    Palette is free and ad-hoc signed, so it is not notarized by Apple. Homebrew
    installs the downloaded app without the quarantine flag; a manual download
    may need System Settings > Privacy & Security > Open Anyway.

    Grant Accessibility to enable direct paste:
      System Settings > Privacy & Security > Accessibility

    Config and providers: ~/.config/palette
    Logs: ~/.local/state/palette/palette.log
  EOS
end
