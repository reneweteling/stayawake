#!/usr/bin/env bash
set -euo pipefail

# StayAwake build script.
# Builds the app and the helper with SwiftPM, wraps them into a .app bundle with
# Info.plist and the launchd plist, and signs them. By default this is an ad-hoc signature (local dev builds).
# Set SIGN_IDENTITY to a "Developer ID Application" identity for release
# builds; that also enables the hardened runtime, required for notarization.

APP_NAME="StayAwake"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Debug builds accept XPC peers by identifier alone. Such a build must never
# carry a real signature, or any app claiming that identifier could talk to it.
if [[ "$CONFIGURATION" != "release" && "$SIGN_IDENTITY" != "-" ]]; then
    echo "✗ Refusing to sign a $CONFIGURATION build with '$SIGN_IDENTITY'. Use CONFIGURATION=release."
    exit 1
fi

echo "→ Building SwiftPM executable ($CONFIGURATION)..."
cd "$REPO_ROOT"
swift build -c "$CONFIGURATION" --arch arm64

BIN_PATH="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"
HELPER_NAME="StayAwakeHelper"
HELPER_PLIST="com.weteling.stayawake.helper.plist"
EXEC_SRC="$BIN_PATH/$APP_NAME"
HELPER_SRC="$BIN_PATH/$HELPER_NAME"
for f in "$EXEC_SRC" "$HELPER_SRC"; do
    if [[ ! -f "$f" ]]; then
        echo "✗ Could not find built executable at $f"
        exit 1
    fi
done

DESIGN_ICNS="$REPO_ROOT/design/icon/AppIcon.icns"
mkdir -p "$BUILD_DIR"
if [[ -f "$DESIGN_ICNS" ]]; then
    echo "→ Using design icon $DESIGN_ICNS"
    cp "$DESIGN_ICNS" "$BUILD_DIR/AppIcon.icns"
else
    echo "→ Design icon missing, generating fallback app icon..."
    if swift "$REPO_ROOT/scripts/make-icon.swift"; then
        if iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"; then
            echo "✓ AppIcon.icns created"
        else
            echo "⚠ iconutil failed, AppIcon.icns will be missing"
        fi
    else
        echo "⚠ make-icon.swift failed, skipping icon generation"
    fi
fi

echo "→ Assembling $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RES" "$CONTENTS/Library/LaunchDaemons"
cp "$EXEC_SRC" "$MACOS/$APP_NAME"
cp "$HELPER_SRC" "$MACOS/$HELPER_NAME"
# SMAppService.daemon(plistName:) looks in Contents/Library/LaunchDaemons;
# BundleProgram in that plist is relative to the app bundle.
cp "$REPO_ROOT/Sources/StayAwakeHelper/Resources/$HELPER_PLIST" "$CONTENTS/Library/LaunchDaemons/$HELPER_PLIST"
cp "$REPO_ROOT/Sources/StayAwake/Resources/Info.plist" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Library/LaunchDaemons/$HELPER_PLIST" "$CONTENTS/Info.plist"
BUNDLE_PROGRAM="$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "$CONTENTS/Library/LaunchDaemons/$HELPER_PLIST")"
if [[ ! -x "$APP_DIR/$BUNDLE_PROGRAM" ]]; then
    echo "✗ BundleProgram $BUNDLE_PROGRAM is not an executable inside the bundle"
    exit 1
fi
# The About tab reads the logo through Bundle.main.
cp "$REPO_ROOT/Sources/StayAwake/Resources/weteling-logo.svg" "$RES/weteling-logo.svg"
if [[ -f "$BUILD_DIR/AppIcon.icns" ]]; then
    cp "$BUILD_DIR/AppIcon.icns" "$RES/AppIcon.icns"
    echo "✓ AppIcon.icns copied into bundle"
fi


# The helper is signed first, then the app, so the app seal covers the signed
# helper. No --deep: each executable gets its own signature.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "→ Ad-hoc signing helper, then app..."
    codesign --force --sign - --identifier com.weteling.stayawake.helper "$MACOS/$HELPER_NAME"
    codesign --force --sign - "$APP_DIR"
else
    echo "→ Signing helper, then app, with '$SIGN_IDENTITY' (hardened runtime)..."
    codesign --force --options runtime --timestamp --identifier com.weteling.stayawake.helper \
        --sign "$SIGN_IDENTITY" "$MACOS/$HELPER_NAME"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
fi

echo "→ Verifying signatures..."
codesign --verify --strict "$MACOS/$HELPER_NAME"
codesign --verify --strict --deep "$APP_DIR"
HELPER_ID="$(codesign -dv "$MACOS/$HELPER_NAME" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$HELPER_ID" != "com.weteling.stayawake.helper" ]]; then
    echo "✗ Helper identifier is '$HELPER_ID'"
    exit 1
fi
echo "✓ Signatures valid, helper identifier $HELPER_ID"

echo "→ Removing quarantine flag..."
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

echo "✓ Built $APP_DIR"
echo ""
echo "  Run: open '$APP_DIR'"
echo "  Install: cp -R '$APP_DIR' /Applications/"
