#!/bin/zsh
# 撮影日セッター.app をビルドする
set -e
cd "$(dirname "$0")"
APP="build/撮影日セッター.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -enable-bare-slash-regex -target arm64-apple-macos14.0 Sources/main.swift -o "$APP/Contents/MacOS/PhotoDater"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PhotoDater</string>
  <key>CFBundleIdentifier</key><string>local.photodater</string>
  <key>CFBundleName</key><string>撮影日セッター</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ja</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "built: $APP"
