#!/bin/zsh
# Release build: .app bundle → ad-hoc podpis (--deep) → NotchOverlay.dmg.
# DMG obsahuje symlink na /Applications (drag & drop instalace).
# Použití: ./release.sh [verze]   (default: obsah souboru VERSION, jinak 1.0.0)
set -e
cd "$(dirname "$0")"

VERSION="${1:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"
./build.sh

DIST="dist"
APP="$DIST/NotchOverlay.app"
rm -rf "$DIST" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bin/NotchOverlay "$APP/Contents/MacOS/NotchOverlay"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>NotchOverlay</string>
	<key>CFBundleIdentifier</key><string>com.matejkrcek.notchoverlay</string>
	<key>CFBundleName</key><string>NotchOverlay</string>
	<key>CFBundleDisplayName</key><string>NotchOverlay</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# ad-hoc podpis ("-" = bez certifikátu); bez něj Apple Silicon binárku nespustí
codesign --force --deep --sign - "$APP"

# staging s odkazem na /Applications → v DMG jde appku rovnou přetáhnout
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DIST/NotchOverlay.dmg"
hdiutil create -volname "NotchOverlay" -srcfolder "$STAGE" -ov -format UDZO \
	"$DIST/NotchOverlay.dmg" >/dev/null
rm -rf "$STAGE"

echo "OK -> $DIST/NotchOverlay.dmg (verze $VERSION)"
shasum -a 256 "$DIST/NotchOverlay.dmg"
