#!/bin/bash
#
# Build, sign and package Elysia as a DMG.
#
# Usage:
#     Scripts/package-dmg.sh
#
# Environment overrides:
#     SIGN_IDENTITY  codesigning identity (default: first "Apple Development" one)
#     DERIVED_DATA   derived data directory
#     OUT_DIR        where the DMG is written (default: dist/)
#
# The build is universal (arm64 + x86_64) so Intel Macs are supported too.
#
# Signing notes: the app sends Apple events to Music, and an Apple Development
# certificate is enough to give it a stable identity, so macOS remembers the
# Automation grant instead of asking again after every rebuild. Hardened runtime
# is deliberately *not* enabled: it would require the
# com.apple.security.automation.apple-events entitlement to keep controlling
# Music, and it buys nothing here because a personal team cannot notarize anyway.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Elysia"
SCHEME="Elysia"
DERIVED_DATA="${DERIVED_DATA:-/tmp/elysia-package-derived}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"

# ---------------------------------------------------------------- signing identity

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "warning: no Apple Development identity found, falling back to ad-hoc signing" >&2
    SIGN_IDENTITY="-"
fi

echo "==> signing identity: $SIGN_IDENTITY"

# ---------------------------------------------------------------- build

echo "==> building $APP_NAME (Release, universal)"
xcodebuild \
    -project "$REPO_ROOT/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    clean build >/dev/null

APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "error: build produced no app at $APP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "==> version: $VERSION"
echo "==> architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

# ---------------------------------------------------------------- sign

echo "==> signing"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier'

# ---------------------------------------------------------------- stage

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# ---------------------------------------------------------------- dmg

mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"

echo "==> creating $DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
