#!/bin/zsh
# Builds Jarvis.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Jarvis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/Jarvis"
cp Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity when one exists so macOS remembers mic/speech permissions across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"

mkdir -p ~/Applications
pkill -x Jarvis 2>/dev/null || true
rm -rf ~/Applications/Jarvis.app
ditto "$APP" ~/Applications/Jarvis.app
echo "Installed to ~/Applications/Jarvis.app"

if [[ "${1:-}" != "--no-launch" ]]; then
  open ~/Applications/Jarvis.app
fi
