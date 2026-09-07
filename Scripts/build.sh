#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h:P}"
DERIVED_DATA_DIR="${PROJECT_DIR}/build/ReleaseDerivedData"
OUTPUT_DIR="${WIIMOTEPAIR_OUTPUT_DIR:-${PROJECT_DIR}/dist-candidate}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
ENTITLEMENTS="${PROJECT_DIR}/WiimotePair/WiimotePair.entitlements"
SIGN_IDENTITY="${WIIMOTEPAIR_SIGN_IDENTITY:--}"

if [[ "${OUTPUT_DIR}" == "${PROJECT_DIR}" || "${OUTPUT_DIR}" != "${PROJECT_DIR}/"* ]]; then
    print -u2 "Output directory must be a child of the project directory: ${OUTPUT_DIR}"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="${OUTPUT_DIR:P}"
if [[ "${OUTPUT_DIR}" == "${PROJECT_DIR}" || "${OUTPUT_DIR}" != "${PROJECT_DIR}/"* ]]; then
    print -u2 "Output directory resolves outside the project directory: ${OUTPUT_DIR}"
    exit 1
fi

BUILT_APP="${DERIVED_DATA_DIR}/Build/Products/Release/WiimotePair.app"
OUTPUT_APP="${OUTPUT_DIR}/WiimotePair.app"
OUTPUT_ZIP="${OUTPUT_DIR}/WiimotePair.zip"

xcodebuild \
    -project "${PROJECT_DIR}/WiimotePair.xcodeproj" \
    -scheme WiimotePair \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA_DIR}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ ! -d "${BUILT_APP}" ]]; then
    print -u2 "The build completed without producing ${BUILT_APP}"
    exit 1
fi

EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${BUILT_APP}/Contents/Info.plist")
BUILT_EXECUTABLE="${BUILT_APP}/Contents/MacOS/${EXECUTABLE_NAME}"
for ARCH in arm64 x86_64; do
    if ! lipo "${BUILT_EXECUTABLE}" -verify_arch "${ARCH}"; then
        print -u2 "The release executable is missing the ${ARCH} architecture"
        exit 1
    fi
done

rm -rf "${OUTPUT_APP}"
rm -f "${OUTPUT_ZIP}"
ditto "${BUILT_APP}" "${OUTPUT_APP}"
mkdir -p "${OUTPUT_APP}/Contents/Resources"
cp "${PROJECT_DIR}/LICENSES/GPL-2.0-or-later.txt" "${OUTPUT_APP}/Contents/Resources/LICENSE.txt"

codesign \
    --force \
    --deep \
    --sign "${SIGN_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    "${OUTPUT_APP}"

codesign --verify --deep --strict --verbose=2 "${OUTPUT_APP}"
ditto -c -k --sequesterRsrc --keepParent "${OUTPUT_APP}" "${OUTPUT_ZIP}"
(cd "${OUTPUT_DIR}" && shasum -a 256 WiimotePair.zip > WiimotePair.zip.sha256)

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${OUTPUT_APP}/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${OUTPUT_APP}/Contents/Info.plist")

print ""
print "Build completed:"
print "  Version: ${VERSION} (${BUILD})"
print "  App:    ${OUTPUT_APP}"
print "  ZIP:    ${OUTPUT_ZIP}"
