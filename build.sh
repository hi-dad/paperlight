#!/bin/zsh
# Builds ReaderMode.app next to this script.
set -e
cd "$(dirname "$0")"
APP=ReaderMode.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
# Universal binary: Apple Silicon + Intel Macs.
for arch in arm64 x86_64; do
  swiftc -parse-as-library -swift-version 5 -O -target $arch-apple-macos13 main.swift -o /tmp/ReaderMode-$arch
done
lipo -create /tmp/ReaderMode-arm64 /tmp/ReaderMode-x86_64 -output $APP/Contents/MacOS/ReaderMode
rm /tmp/ReaderMode-arm64 /tmp/ReaderMode-x86_64
cp AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Reader Mode</string>
  <key>CFBundleIdentifier</key><string>com.danielryan.readermode</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ReaderMode</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP
echo "Built $APP"

# ./build.sh dist  ->  makes dist/ReaderMode.dmg to share with friends
if [[ "$1" == "dist" ]]; then
  rm -rf dist && mkdir -p dist/stage
  cp -R $APP dist/stage/
  ln -s /Applications "dist/stage/Applications"
  cp "How to install.txt" dist/stage/
  hdiutil create -volname "Reader Mode" -srcfolder dist/stage -ov -format UDZO dist/ReaderMode.dmg >/dev/null
  rm -rf dist/stage
  echo "Made dist/ReaderMode.dmg"
fi

# Install: move the app into /Applications so there's only ever one copy on this Mac.
pkill -x ReaderMode || true
sleep 1
rm -rf /Applications/$APP
mv $APP /Applications/
open /Applications/$APP
echo "Installed to /Applications"
