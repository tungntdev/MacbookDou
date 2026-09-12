#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MacbookDou"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
RUN_AFTER_BUILD=false
MAKE_DMG=false

# Screen Recording (and similar TCC) grants are pinned to the exact code
# signature. An ad-hoc signature ("-") gets a brand new identity every
# single rebuild (each binary embeds a fresh, unique UUID), so macOS treats
# each rebuild as a different app and makes you grant access again. A real
# certificate's identity stays stable across rebuilds instead, so the grant
# sticks. Prefer one already in the login keychain -- e.g. the free "Apple
# Development" certificate Xcode creates the first time you sign in with an
# Apple ID -- and only fall back to ad-hoc signing if none exists.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  AUTO_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -o '"Apple Development:[^"]*"' | tr -d '"')"
  SIGN_IDENTITY="${AUTO_IDENTITY:--}"
fi

for arg in "$@"; do
  case "$arg" in
    --run) RUN_AFTER_BUILD=true ;;
    --dmg) MAKE_DMG=true ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Building $APP_NAME (release)"
swift build -c release --product "$APP_NAME"

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Assembling app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

RESOURCE_BUNDLE="$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  # Flatten the *.lproj folders straight into Contents/Resources, the
  # standard place AppKit/Foundation look for localizations in a real .app
  # bundle. (SwiftPM's own Bundle.module accessor instead expects its whole
  # resource bundle sitting next to Bundle.main.bundleURL, i.e. the .app's
  # top level outside Contents/ -- which codesign then refuses to seal.
  # Localization.swift reads via Bundle.main, so it never calls that
  # accessor in a packaged build.)
  for lproj in "$RESOURCE_BUNDLE"/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
  done
fi

echo "==> Signing (identity: $SIGN_IDENTITY)"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
codesign -dv "$APP_BUNDLE" 2>&1 | head -5 || true

echo "==> Done: $APP_BUNDLE"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "    Signed ad-hoc: macOS will ask for Screen Recording permission again"
  echo "    after every rebuild. Sign in to Xcode with an Apple ID once (Xcode >"
  echo "    Settings > Accounts > +) to get a free 'Apple Development' certificate --"
  echo "    this script picks it up automatically afterwards, and the permission"
  echo "    grant will then survive rebuilds."
fi

if [ "$MAKE_DMG" = true ]; then
  echo "==> Building disk image at $DMG_PATH"
  STAGING="$BUILD_DIR/dmg-staging"
  rm -rf "$STAGING" "$DMG_PATH"
  mkdir -p "$STAGING"
  cp -R "$APP_BUNDLE" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
  rm -rf "$STAGING"
  echo "==> Done: $DMG_PATH"
fi

if [ "$RUN_AFTER_BUILD" = true ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  open "$APP_BUNDLE"
fi
