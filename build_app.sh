#!/bin/bash
#
# Builds dist/ScreenDrawOverlay.app (universal, ad-hoc signed) and a zip next to it.
# Requires the Xcode command line tools. No Xcode project needed.
#
set -euo pipefail

APP_NAME="ScreenDrawOverlay"
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

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> Architectures: $(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME")"

echo "==> Signing (ad-hoc)"
# Ad-hoc: no Developer ID, no notarization. macOS will warn on first launch;
# see the install section of README.md.
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "==> Zipping"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo
echo "Built: $APP_DIR"
echo "Zip:   $ZIP_PATH"
echo "Open it with: open \"$APP_DIR\""
