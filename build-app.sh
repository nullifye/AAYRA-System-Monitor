#!/bin/bash
# Builds AAYRA.app from the Swift package. Usage: ./build-app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 -Xswiftc -Osize   # optimise for size: keeps the app under 1 MB

APP="AAYRA.app"
BIN="$(swift build -c release --arch arm64 --show-bin-path)/AAYRA"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AAYRA"
strip -x "$APP/Contents/MacOS/AAYRA"     # drop debug symbols (roughly halves the binary)
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $(pwd)/$APP"
if [[ "${1:-}" == "--open" ]]; then
    pkill -x AAYRA 2>/dev/null || true
    open "$APP"
fi
