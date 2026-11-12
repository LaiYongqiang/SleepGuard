#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/SleepSkip.app"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/SleepSkip-${VERSION}-macOS-universal.dmg"
ZIP_PATH="$DIST_DIR/SleepSkip-${VERSION}-macOS-universal.zip"

echo "==> Building SleepSkip ($VERSION / universal arm64+x86_64) in release mode..."
cd "$ROOT_DIR"

# Keep the CLI banner and settings panel in sync with the bundle version.
CORE_SOURCE="$ROOT_DIR/Sources/SleepSkipCore/GuardMode.swift"
if grep -q 'public static let version = "' "$CORE_SOURCE"; then
  /usr/bin/sed -i '' -E "s/public static let version = \"[^\"]*\"/public static let version = \"$VERSION\"/" "$CORE_SOURCE"
fi

swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SleepSkip"
if [ ! -x "$BIN_PATH" ]; then
  echo "Error: Release binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling SleepSkip.app bundle..."
rm -rf "$APP_DIR" "$DMG_STAGING" "$DMG_PATH" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/SleepSkip"
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
hdiutil create -volname "SleepSkip $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGING"

echo "==> Binary architectures:"
lipo -info "$APP_DIR/Contents/MacOS/SleepSkip"
echo "==> Build complete:"
ls -lh "$APP_DIR/Contents/MacOS/SleepSkip" "$ZIP_PATH" "$DMG_PATH"
