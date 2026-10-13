#!/bin/bash
#
# Build, repair, sign, and verify VebeVoice.app.
#
# The transcribe-cpp-swift binary artifact ships a malformed macOS framework:
# CTranscribe.framework/Versions/Current is a duplicated real directory instead
# of a symlink, and the top-level entries are real files instead of symlinks.
# codesign --deep --strict rejects that layout, so we rebuild the bundle into a
# correct versioned layout and re-sign.
#
# Usage: ./scripts/package-release.sh [output-dir]
#        Default output-dir is ~/Desktop
#
# Environment:
#   SIGN_ID         codesign identity. Defaults to the first "Developer ID
#                   Application" identity in the keychain, else ad-hoc ("-").
#   NOTARY_PROFILE  notarytool keychain profile. When set, the app is
#                   notarized and stapled (requires a Developer ID SIGN_ID).
#   ZIP=1           also write VebeVoice-<version>.zip next to the app.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$HOME/Desktop}"
DERIVED="${PROJECT_DIR}/.build-release"
ENTITLEMENTS="${PROJECT_DIR}/VebeVoice.entitlements"
APP="${DERIVED}/Build/Products/Release/VebeVoice.app"

if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    SIGN_ID="${SIGN_ID:--}"
fi
if [ "${SIGN_ID}" = "-" ]; then
    TIMESTAMP_FLAG="--timestamp=none"
    echo "==> No Developer ID identity found; signing ad-hoc"
else
    TIMESTAMP_FLAG="--timestamp"
    echo "==> Signing as: ${SIGN_ID}"
fi
if [ -n "${NOTARY_PROFILE:-}" ] && [ "${SIGN_ID}" = "-" ]; then
    echo "NOTARY_PROFILE requires a Developer ID SIGN_ID"
    exit 1
fi

cd "${PROJECT_DIR}"

echo "==> Building Release..."
# Built unsigned; the explicit Developer ID re-sign below is authoritative.
xcodebuild -project VebeVoice.xcodeproj -scheme VebeVoice \
    -destination 'platform=macOS' -configuration Release \
    -derivedDataPath "${DERIVED}" \
    CODE_SIGNING_ALLOWED=NO \
    build > /dev/null
[ -d "${APP}" ] || { echo "Build produced no app bundle at ${APP}"; exit 1; }

repair_framework() {
    local fw="$1"
    local name
    name="$(basename "${fw}" .framework)"
    [ -d "${fw}/Versions/A" ] || return 0
    # Already correct?
    if [ -L "${fw}/Versions/Current" ]; then return 0; fi

    echo "    repairing ${name}.framework layout"
    # Versions/A is the canonical copy. Fold anything only present at the top
    # level (Headers, Modules) into it, then replace the rest with symlinks.
    for item in Headers Modules Resources; do
        if [ -e "${fw}/${item}" ] && [ ! -L "${fw}/${item}" ] && [ ! -e "${fw}/Versions/A/${item}" ]; then
            mv "${fw}/${item}" "${fw}/Versions/A/${item}"
        fi
    done

    rm -rf "${fw}/Versions/Current"
    ln -s "A" "${fw}/Versions/Current"

    for item in "${name}" Headers Modules Resources; do
        rm -rf "${fw:?}/${item}"
        if [ -e "${fw}/Versions/Current/${item}" ]; then
            ln -s "Versions/Current/${item}" "${fw}/${item}"
        fi
    done
}

echo "==> Repairing embedded framework layouts..."
for fw in "${APP}/Contents/Frameworks/"*.framework; do
    [ -d "${fw}" ] || continue
    repair_framework "${fw}"
done

echo "==> Re-signing (hardened runtime)..."
# Inside-out: frameworks first, then the app.
for fw in "${APP}/Contents/Frameworks/"*.framework; do
    [ -d "${fw}" ] || continue
    codesign --force --sign "${SIGN_ID}" --options runtime "${TIMESTAMP_FLAG}" \
        "${fw}/Versions/A" 2>/dev/null || \
    codesign --force --sign "${SIGN_ID}" --options runtime "${TIMESTAMP_FLAG}" "${fw}"
done

codesign --force --sign "${SIGN_ID}" --options runtime "${TIMESTAMP_FLAG}" \
    --entitlements "${ENTITLEMENTS}" "${APP}"

echo "==> Verifying..."
codesign --verify --deep --strict --verbose=2 "${APP}"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing..."
    NOTARY_ZIP="${DERIVED}/VebeVoice-notary.zip"
    ditto -c -k --keepParent "${APP}" "${NOTARY_ZIP}"
    xcrun notarytool submit "${NOTARY_ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${APP}"
    rm -f "${NOTARY_ZIP}"
fi

echo "==> Delivering to ${OUTPUT_DIR}..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/VebeVoice.app"
ditto "${APP}" "${OUTPUT_DIR}/VebeVoice.app"

if [ "${ZIP:-0}" = "1" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")"
    ZIP_PATH="${OUTPUT_DIR}/VebeVoice-${VERSION}.zip"
    rm -f "${ZIP_PATH}"
    ditto -c -k --keepParent "${OUTPUT_DIR}/VebeVoice.app" "${ZIP_PATH}"
    echo "Zip: ${ZIP_PATH}"
fi

echo
echo "Done: ${OUTPUT_DIR}/VebeVoice.app"
