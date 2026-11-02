#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP="dist/Palette-$VERSION.zip"
CASK="packaging/homebrew/Casks/palette.rb"

make app
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent build/Palette.app "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
sed -i '' "s/version \"[^\"]*\"/version \"$VERSION\"/" "$CASK"
sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"$SHA\"/" "$CASK"

echo "Built $ZIP"
echo "sha256 $SHA"
echo
echo "Next:"
echo "  1. Create a GitHub release v$VERSION at https://github.com/Myleshen/palette/releases"
echo "  2. Upload $ZIP"
echo "  3. Copy $CASK into Myleshen/homebrew-tap/Casks/"
echo
echo "Users then run: brew install --cask Myleshen/tap/palette"
