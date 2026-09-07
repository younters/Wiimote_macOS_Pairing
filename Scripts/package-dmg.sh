#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${WIIMOTEPAIR_OUTPUT_DIR:-${PROJECT_DIR}/dist-candidate}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
APP="${OUTPUT_DIR}/WiimotePair.app"
[[ -d "${APP}" ]] || { print -u2 "Run Scripts/build.sh first"; exit 1; }
codesign --verify --deep --strict "${APP}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")
DMG="${OUTPUT_DIR}/WiimotePair-${VERSION}.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp/}wiimote-dmg.XXXXXX")
trap 'rm -rf "${STAGING}"' EXIT
ditto "${APP}" "${STAGING}/WiimotePair.app"
ln -s /Applications "${STAGING}/Applications"
cp "${PROJECT_DIR}/LICENSES/GPL-2.0-or-later.txt" "${STAGING}/LICENSE.txt"
cat > "${STAGING}/READ ME.txt" <<'TEXT'
Drag WiimotePair.app to Applications, then open it and allow Bluetooth access.
Requires macOS 12 or later. Includes Apple silicon and Intel executables.

This community build is ad hoc signed and is not Apple-notarized. macOS may
block first launch. If you trust this download, use System Settings > Privacy
& Security > Open Anyway after attempting to open the installed app.

Pairing is per Mac. Discover your remote or import its identity profile using
the Remotes menu, then pair it on this Mac. No controller identities or pairing
keys are bundled. Some clones cannot be discovered by macOS; a third tested
clone still fails authentication. See the release notes for limitations.
TEXT
hdiutil create -ov -format UDZO -volname "WiimotePair ${VERSION}" -srcfolder "${STAGING}" "${DMG}"
hdiutil verify "${DMG}"
(cd "${OUTPUT_DIR}" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
print "DMG: ${DMG}"
