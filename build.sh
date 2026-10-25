#!/bin/zsh
# Builds Paperlight.app next to this script.
set -e
cd "$(dirname "$0")"
source tools/sparkle.sh && sparkle_fetch   # self-updating (see tools/sparkle.sh)
APP=Paperlight.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
# Universal binary: Apple Silicon + Intel Macs.
for arch in arm64 x86_64; do
  swiftc -parse-as-library -swift-version 5 -O -target $arch-apple-macos13 "${SPARKLE_SWIFTC_FLAGS[@]}" main.swift -o /tmp/Paperlight-$arch
done
lipo -create /tmp/Paperlight-arm64 /tmp/Paperlight-x86_64 -output $APP/Contents/MacOS/Paperlight
rm /tmp/Paperlight-arm64 /tmp/Paperlight-x86_64
cp AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Paperlight</string>
  <key>CFBundleIdentifier</key><string>com.danielryan.readermode</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Paperlight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
sparkle_embed $APP
sparkle_plist $APP paperlight
# GitHub's release builds sign with Developer ID + hardened runtime + timestamp, as Apple's notarization needs.
if [[ -n "$SIGN_IDENTITY" ]]; then
  sparkle_sign $APP --force --sign "$SIGN_IDENTITY" --options runtime --timestamp
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp $APP
else
  sparkle_sign $APP --force --sign -
  codesign --force --sign - $APP
fi
echo "Built $APP"

# ./build.sh dist  ->  makes dist/Paperlight.dmg to share with friends
if [[ "$1" == "dist" ]]; then
  rm -rf dist && mkdir -p dist/stage
  cp -R $APP dist/stage/
  ln -s /Applications "dist/stage/Applications"
  cp "How to install.txt" dist/stage/
  hdiutil create -volname "Paperlight" -srcfolder dist/stage -ov -format UDZO dist/Paperlight.dmg >/dev/null
  rm -rf dist/stage
  echo "Made dist/Paperlight.dmg"
fi

# On GitHub's build machines (CI is set there), stop here: the DMG is what gets published.
[[ -n "$CI" ]] && exit 0

# Install: move the app into /Applications so there's only ever one copy on this Mac.
pkill -x Paperlight || true
pkill -x ReaderMode || true            # the app's name before it became Paperlight
rm -rf /Applications/ReaderMode.app
sleep 1
rm -rf /Applications/$APP
mv $APP /Applications/
open /Applications/$APP
echo "Installed to /Applications"
