#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-1.1.0}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/SleepGuard.app"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/SleepGuard-${VERSION}-macOS-universal.dmg"
ZIP_PATH="$DIST_DIR/SleepGuard-${VERSION}-macOS-universal.zip"

echo "==> Building SleepGuard ($VERSION / universal arm64+x86_64) in release mode..."
cd "$ROOT_DIR"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SleepGuard"
if [ ! -x "$BIN_PATH" ]; then
  echo "Error: Release binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling SleepGuard.app bundle..."
rm -rf "$APP_DIR" "$DMG_STAGING" "$DMG_PATH" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/SleepGuard"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist" >/dev/null

echo "==> Generating AppIcon.icns..."
swift "$ROOT_DIR/scripts/generate_icon.swift" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Code signing bundle (ad-hoc)..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Creating ZIP archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "==> Creating DMG installer..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "SleepGuard $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGING"

echo "==> Binary architectures:"
lipo -info "$APP_DIR/Contents/MacOS/SleepGuard"
echo "==> Build complete:"
ls -lh "$APP_DIR/Contents/MacOS/SleepGuard" "$ZIP_PATH" "$DMG_PATH"
