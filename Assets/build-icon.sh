#!/bin/zsh
# Vygeneruje Assets/AppIcon.icns z make-icon.swift (CoreGraphics, žádné assety).
set -e
cd "$(dirname "$0")"
swift make-icon.swift AppIcon.png
ICONSET="AppIcon.iconset"
rm -rf "$ICONSET" && mkdir "$ICONSET"
for s in 16 32 128 256 512; do
	sips -z $s $s AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
	d=$((s * 2))
	sips -z $d $d AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET"
echo "OK -> Assets/AppIcon.icns"
