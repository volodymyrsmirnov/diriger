#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Diriger"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ENTITLEMENTS="${ENTITLEMENTS_PATH:-$PROJECT_DIR/Resources/Diriger.entitlements}"
APP_VERSION="${APP_VERSION:-}"

echo "Building $APP_NAME..."
cd "$PROJECT_DIR"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

echo "Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Copy SPM resource bundles (e.g. KeyboardShortcuts localization)
for bundle in "$BIN_PATH"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

# Inject version if provided
if [ -n "$APP_VERSION" ]; then
    echo "Setting version to $APP_VERSION..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
fi

# Determine signing identity
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    IDENTITY="$SIGNING_IDENTITY"
else
    IDENTITY=$(security find-identity -v -p codesigning | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi

echo "Signing app bundle..."
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    echo "  Using identity: $IDENTITY"
    # Sign the binary first, then the bundle (Apple best practice, no --deep)
    codesign --force --sign "$IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    codesign --force --sign "$IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        "$APP_BUNDLE"
else
    echo "  Warning: No signing identity found, using ad-hoc signing"
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "Built $APP_BUNDLE"
