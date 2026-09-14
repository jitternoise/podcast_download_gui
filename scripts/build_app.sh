#!/bin/bash
# Builds a release binary with Swift Package Manager and wraps it in a
# double-clickable macOS .app bundle at build/Podcast Downloader.app.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Podcast Downloader"
EXEC_NAME="PodcastDownloader"
APP="build/${APP_NAME}.app"

echo "▸ Building release binary…"
swift build -c release

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/${EXEC_NAME}" "$APP/Contents/MacOS/${EXEC_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so macOS is happy to launch it locally.
echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Done: $APP"
echo "  Run it with:  open \"$APP\""
