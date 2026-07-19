#!/bin/bash
# Sestaví NotchOverlay.app, nainstaluje do /Applications a zaregistruje
# LaunchAgent (start po přihlášení, restart po pádu, Quit z menu = zůstane
# vypnutá do dalšího přihlášení / ručního spuštění).
#
# Instalace bez klonování repa:
#   curl -fsSL https://raw.githubusercontent.com/MatejKrcek/NotchOverlay/main/install.sh | bash
#
# Odinstalace:
#   launchctl bootout gui/$UID/com.matejkrcek.notchoverlay
#   rm -rf /Applications/NotchOverlay.app ~/Library/LaunchAgents/com.matejkrcek.notchoverlay.plist
set -e

REPO="https://github.com/MatejKrcek/NotchOverlay.git"

# --- prerekvizity ---
if ! command -v swiftc >/dev/null 2>&1; then
	echo "CHYBA: swiftc nenalezen. Nainstaluj Xcode Command Line Tools:" >&2
	echo "  xcode-select --install" >&2
	exit 1
fi

# --- remote režim (curl | bash): bez zdrojáků vedle skriptu → naklonovat ---
SRC="${BASH_SOURCE[0]:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC" ] || [ ! -d "$(cd "$(dirname "$SRC")" && pwd)/Sources/NotchOverlay" ]; then
	if ! command -v git >/dev/null 2>&1; then
		echo "CHYBA: git nenalezen." >&2
		exit 1
	fi
	TMP="$(mktemp -d /tmp/notchoverlay.XXXXXX)"
	trap 'rm -rf "$TMP"' EXIT
	echo "Klonuju $REPO ..."
	git clone --depth 1 "$REPO" "$TMP/NotchOverlay"
	bash "$TMP/NotchOverlay/install.sh"
	exit 0
fi
cd "$(dirname "$SRC")"

./build.sh

APP="/Applications/NotchOverlay.app"
LABEL="com.matejkrcek.notchoverlay"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

# --- bundle ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bin/NotchOverlay "$APP/Contents/MacOS/NotchOverlay"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
	<key>CFBundleIconFile</key><string>AppIcon</string>
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
	<array><string>$APP/Contents/MacOS/NotchOverlay</string><string>--agent</string></array>
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
# bootout je asynchronní — bootstrap hned po něm občas vrátí EIO, proto retry
for i in 1 2 3 4 5; do
	if launchctl bootstrap "gui/$UID" "$AGENT" 2>/dev/null; then
		break
	fi
	if [ "$i" = 5 ]; then
		echo "CHYBA: launchctl bootstrap se nepovedl ani po 5 pokusech" >&2
		exit 1
	fi
	sleep 1
done
echo "OK: $APP nainstalováno, LaunchAgent $LABEL běží (start po přihlášení zapnutý)"
