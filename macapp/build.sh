#!/bin/bash
# Build phona.app, and optionally a distributable disk image.
#
#   ./build.sh          release build plus phona.app
#   ./build.sh --dmg    also package phona-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Phona"
BUNDLE="build/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

echo "==> compiling"
swift build -c release --disable-sandbox

echo "==> icon"
python3 make_icon.py >/dev/null

echo "==> assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp .build/release/PhonaApp "${BUNDLE}/Contents/MacOS/PhonaApp"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
if [[ -d Resources/Sounds ]]; then
  mkdir -p "${BUNDLE}/Contents/Resources/Sounds"
  cp Resources/Sounds/*.aiff "${BUNDLE}/Contents/Resources/Sounds/" 2>/dev/null || true
fi
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

echo "==> signing"
# Ad-hoc signature, but with the designated requirement pinned to the bundle identifier
# rather than the code hash.
#
# This matters more than it looks. An ad-hoc signature's default designated requirement IS
# the cdhash, so TCC binds an Accessibility or Microphone grant to one exact build. Every
# rebuild changes the hash, silently orphaning the grant: the permission still shows as
# enabled in System Settings while the app is denied. Pinning to the identifier keeps the
# grant valid across rebuilds.
#
# The tradeoff is a weaker requirement, since anything claiming this identifier satisfies
# it. That is acceptable for a locally built personal tool and would not be for something
# shipped with a Developer ID.
codesign --force --deep --sign - \
  --identifier com.basalona.phona \
  -r='designated => identifier "com.basalona.phona"' \
  "${BUNDLE}"

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
