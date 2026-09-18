#!/bin/bash
# Builds a release binary with Swift Package Manager and wraps it in a
# double-clickable macOS .app bundle at build/Podcast Downloader.app.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Podcast Downloader"
EXEC_NAME="PodcastDownloader"
APP="build/${APP_NAME}.app"

# Universal binary so the same .app runs natively on Apple Silicon and Intel.
# Set ARCHS="" to build only the host architecture (faster for local use).
ARCHS="${ARCHS-"--arch arm64 --arch x86_64"}"
echo "▸ Building release binary (${ARCHS:-host architecture})…"
# shellcheck disable=SC2086
swift build -c release $ARCHS
if [ -n "$ARCHS" ]; then
    BIN=".build/apple/Products/Release/${EXEC_NAME}"
else
    BIN=".build/release/${EXEC_NAME}"
fi

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${EXEC_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Signing. With no identity this is an ad-hoc signature, which is enough to
# run on this Mac. To give the app to other Macs without Gatekeeper's
# "damaged / unidentified developer" block, sign with a Developer ID and
# notarize:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build_app.sh
#   xcrun notarytool submit "build/Podcast Downloader.zip" --keychain-profile <profile> --wait
#   xcrun stapler staple "build/Podcast Downloader.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "▸ Signing ($([ "$SIGN_IDENTITY" = "-" ] && echo ad-hoc || echo "$SIGN_IDENTITY"))…"
codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"

echo "✓ Done: $APP"
lipo -archs "$APP/Contents/MacOS/${EXEC_NAME}" 2>/dev/null | sed 's/^/  Architectures: /'
echo "  Run it with:  open \"$APP\""
