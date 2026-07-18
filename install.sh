#!/bin/zsh
# Sestaví NotchOverlay.app, nainstaluje do ~/Applications a zaregistruje
# LaunchAgent (start po přihlášení, restart po pádu, Quit z menu = zůstane
# vypnutá do dalšího přihlášení / ručního spuštění).
#
# Odinstalace:
#   launchctl bootout gui/$UID/com.matejkrcek.notchoverlay
#   rm -rf /Applications/NotchOverlay.app ~/Library/LaunchAgents/com.matejkrcek.notchoverlay.plist
set -e
cd "$(dirname "$0")"

./build.sh

APP="/Applications/NotchOverlay.app"
LABEL="com.matejkrcek.notchoverlay"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

# --- bundle ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp bin/NotchOverlay "$APP/Contents/MacOS/NotchOverlay"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>NotchOverlay</string>
	<key>CFBundleIdentifier</key><string>com.matejkrcek.notchoverlay</string>
	<key>CFBundleName</key><string>NotchOverlay</string>
	<key>CFBundleDisplayName</key><string>NotchOverlay</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"

# --- launch agent ---
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$APP/Contents/MacOS/NotchOverlay</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key>
	<dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

# --- (re)start ---
pkill -f 'NotchOverlay' 2>/dev/null || true
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$AGENT"
echo "OK: $APP nainstalováno, LaunchAgent $LABEL běží (start po přihlášení zapnutý)"
