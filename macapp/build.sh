#!/bin/bash
# Build vfix.app, and optionally a distributable disk image.
#
#   ./build.sh          release build plus vfix.app
#   ./build.sh --dmg    also package vfix-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="vfix"
BUNDLE="build/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

echo "==> compiling"
swift build -c release --disable-sandbox

echo "==> icon"
python3 make_icon.py >/dev/null

echo "==> assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp .build/release/VfixApp "${BUNDLE}/Contents/MacOS/VfixApp"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

echo "==> signing"
# Ad-hoc signature. Enough for the app to hold Accessibility and Microphone grants on
# this machine. Distributing to other people without a Developer ID means they get a
# Gatekeeper warning on first launch, which the README explains how to clear.
codesign --force --deep --sign - \
  --identifier com.basalona.vfix \
  --options runtime \
  --entitlements Resources/vfix.entitlements \
  "${BUNDLE}" 2>/dev/null || codesign --force --deep --sign - \
  --identifier com.basalona.vfix "${BUNDLE}"

codesign --verify --verbose=1 "${BUNDLE}" && echo "signature ok"

echo "==> built ${BUNDLE} (version ${VERSION})"

if [[ "${1:-}" == "--dmg" ]]; then
  DMG="build/${APP_NAME}-${VERSION}.dmg"
  STAGE="build/dmg"
  echo "==> packaging ${DMG}"
  rm -rf "${STAGE}" "${DMG}"
  mkdir -p "${STAGE}"
  cp -R "${BUNDLE}" "${STAGE}/"
  ln -s /Applications "${STAGE}/Applications"
  cp ../README.md "${STAGE}/README.md" 2>/dev/null || true
  hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
  rm -rf "${STAGE}"
  echo "==> packaged ${DMG}"
  shasum -a 256 "${DMG}"
fi
