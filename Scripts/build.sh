#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA_DIR="${PROJECT_DIR}/build/ReleaseDerivedData"
OUTPUT_DIR="${PROJECT_DIR}/dist"
BUILT_APP="${DERIVED_DATA_DIR}/Build/Products/Release/WiimotePair.app"
OUTPUT_APP="${OUTPUT_DIR}/WiimotePair.app"
OUTPUT_ZIP="${OUTPUT_DIR}/WiimotePair.zip"
ENTITLEMENTS="${PROJECT_DIR}/WiimotePair/WiimotePair.entitlements"

if [[ "${OUTPUT_DIR}" != "${PROJECT_DIR}/dist" ]]; then
    print -u2 "Unexpected output path: ${OUTPUT_DIR}"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

xcodebuild \
    -project "${PROJECT_DIR}/WiimotePair.xcodeproj" \
    -scheme WiimotePair \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA_DIR}" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ ! -d "${BUILT_APP}" ]]; then
    print -u2 "The build completed without producing ${BUILT_APP}"
    exit 1
fi

rm -rf "${OUTPUT_APP}"
rm -f "${OUTPUT_ZIP}"
ditto "${BUILT_APP}" "${OUTPUT_APP}"

codesign \
    --force \
    --deep \
    --sign - \
    --entitlements "${ENTITLEMENTS}" \
    "${OUTPUT_APP}"

codesign --verify --deep --strict --verbose=2 "${OUTPUT_APP}"
ditto -c -k --sequesterRsrc --keepParent "${OUTPUT_APP}" "${OUTPUT_ZIP}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${OUTPUT_APP}/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${OUTPUT_APP}/Contents/Info.plist")

print ""
print "Build completed:"
print "  Version: ${VERSION} (${BUILD})"
print "  App:    ${OUTPUT_APP}"
print "  ZIP:    ${OUTPUT_ZIP}"
