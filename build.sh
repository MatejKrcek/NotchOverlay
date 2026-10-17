#!/bin/zsh
# swift build je na tomto stroji rozbité (CLT ManifestAPI mismatch),
# kompilujeme přímo přes swiftc.
#
# -target je povinný: swiftc z novějších CLT má jako výchozí deployment target
# verzi vyšší než běžící macOS (např. CLT 26.6 → macosx28.0), a taková binárka
# se na starším systému odmítne spustit („nefunguje s touto verzí macOS").
# Verze musí odpovídat LSMinimumSystemVersion v install.sh / release.sh.
set -e
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -target arm64-apple-macos13.0 Sources/NotchOverlay/*.swift -o bin/NotchOverlay
echo "OK -> bin/NotchOverlay"
