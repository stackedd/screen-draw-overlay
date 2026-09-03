#!/bin/bash
#
# Builds dist/Scrim.app (universal) and a zip next to it. Requires the Xcode
# command line tools; no Xcode project needed.
#
# Ad-hoc signed by default, which is what a machine without a Developer ID can do - macOS then
# warns on first launch and the user has to right-click > Open (see README).
#
# With a Developer ID it signs and notarises properly instead:
#
#     DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./build_app.sh
#     DEVELOPER_ID="..." NOTARY_PROFILE=my-profile ./build_app.sh    # also notarise + staple
#
# NOTARY_PROFILE is a keychain profile made once with:
#     xcrun notarytool store-credentials my-profile --apple-id ... --team-id ... --password ...
#
set -euo pipefail

APP_NAME="Scrim"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
INFO_PLIST="$ROOT_DIR/Packaging/Info.plist"

echo "==> Building universal release binary (arm64 + x86_64)"
swift build --package-path "$ROOT_DIR" -c release --arch arm64 --arch x86_64

BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release --arch arm64 --arch x86_64 --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"

if [ ! -f "$BINARY" ]; then
    echo "error: built binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Drawing the icon"
ICON="$ROOT_DIR/Packaging/AppIcon.icns"
if [ ! -f "$ICON" ] || [ "$ROOT_DIR/Tools/makeicon.swift" -nt "$ICON" ]; then
    swiftc -O "$ROOT_DIR/Tools/makeicon.swift" -o "$ROOT_DIR/.build/makeicon"
    "$ROOT_DIR/.build/makeicon" "$ROOT_DIR/Packaging"
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> Architectures: $(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME")"

if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "==> Signing with $DEVELOPER_ID"
    # Hardened runtime is what notarisation requires; the timestamp is what keeps the
    # signature valid after the certificate expires.
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP_DIR"
else
    echo "==> Signing (ad-hoc: no Developer ID, so macOS will warn on first launch)"
    codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "==> Zipping"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarising (this waits on Apple, usually a minute or two)"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    # The ticket is stapled to the app, then the zip is made again so the copy people
    # download carries it and opens without a network round trip.
    xcrun stapler staple "$APP_DIR"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
    echo "==> Notarised and stapled"
fi

echo
echo "Built: $APP_DIR"
echo "Zip:   $ZIP_PATH"
echo "Open it with: open \"$APP_DIR\""
