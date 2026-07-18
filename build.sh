#!/bin/zsh
# swift build je na tomto stroji rozbité (CLT ManifestAPI mismatch),
# kompilujeme přímo přes swiftc.
set -e
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O Sources/NotchOverlay/*.swift -o bin/NotchOverlay
echo "OK -> bin/NotchOverlay"
