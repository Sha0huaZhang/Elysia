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
#     OUT_DIR        where the DMG is written (default: dmg/)
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
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dmg}"

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
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
elif codesign --force --sign "$SIGN_IDENTITY" --timestamp "$APP" 2>/dev/null; then
    :
else
    # The timestamp service lives on the network; fall back so packaging still
    # works offline. The signature stays valid, it just carries no secure timestamp.
    echo "warning: timestamp service unavailable, signing without a secure timestamp" >&2
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier'

# ---------------------------------------------------------------- layout

# Geometry of the disk image window, in points.
WINDOW_WIDTH=460
WINDOW_HEIGHT=349
ICON_SIZE=128                            # 4x the area of the 64pt Finder default
TEXT_SIZE=13
ICON_TOP=52
# Two icons centred as a pair: their centres sit at 1/4 and 3/4 of the width.
ICON_LEFT=$((WINDOW_WIDTH / 4 - ICON_SIZE / 2))
ICON_RIGHT=$((WINDOW_WIDTH * 3 / 4 - ICON_SIZE / 2))
# No background picture: drag-to-install needs no caption, and without a picture
# Finder lets the window follow the system appearance, so it turns dark in dark
# mode. A picture would pin the window to one colour instead.

# ---------------------------------------------------------------- stage

STAGE="$(mktemp -d)"
TMP_DMG="$(mktemp -u).dmg"
trap 'rm -rf "$STAGE"; rm -f "$TMP_DMG"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# ---------------------------------------------------------------- dmg

mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"

# A read-write image is needed first: Finder records the window layout in
# .DS_Store, which cannot be written to a compressed image.
echo "==> laying out the disk image window"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW "$TMP_DMG" >/dev/null

MOUNT_POINT="$(hdiutil attach "$TMP_DMG" -nobrowse -noautoopen | grep -o '/Volumes/.*' | tail -1)"
[[ -n "$MOUNT_POINT" ]] || { echo "error: could not mount the working image" >&2; exit 1; }
echo "    mounted at $MOUNT_POINT"

# Finder records the layout in .DS_Store on its own schedule, so the result is
# checked rather than assumed: an earlier version waited a fixed two seconds and
# sometimes produced an image with no layout at all.
layout_attempts=5
for (( attempt = 1; attempt <= layout_attempts; attempt++ )); do
    osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
  tell disk "$APP_NAME"
    open
    delay 1
    set current view of container window to icon view
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON_SIZE
    set text size of theViewOptions to $TEXT_SIZE
    set shows icon preview of theViewOptions to true
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 160, $((200 + WINDOW_WIDTH)), $((160 + WINDOW_HEIGHT))}
    set position of item "$APP_NAME.app" of container window to {$ICON_LEFT, $ICON_TOP}
    set position of item "Applications" of container window to {$ICON_RIGHT, $ICON_TOP}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

    sync
    if [[ -s "$MOUNT_POINT/.DS_Store" ]]; then
        break
    fi
    if (( attempt == layout_attempts )); then
        echo "error: Finder did not record the window layout after $layout_attempts attempts" >&2
        hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
        exit 1
    fi
    echo "    Finder has not written .DS_Store yet, retrying ($attempt/$layout_attempts)"
done

sleep 2
hdiutil detach "$MOUNT_POINT" >/dev/null

echo "==> compressing"
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG" >/dev/null

echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
