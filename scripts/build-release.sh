#!/bin/bash
set -e

APP_NAME="JMTerm"
BUILD_DIR=".build/release"
APP_DIR="${APP_NAME}.app/Contents"
DIST_DIR="dist"

# 서명 정보는 환경변수 또는 scripts/sign.env에서 로드
# (sign.env는 .gitignore에 추가되어 깃에 올라가지 않음)
if [ -f "scripts/sign.env" ]; then
    source "scripts/sign.env"
fi

: "${SIGN_ID:?SIGN_ID 환경변수가 필요합니다. scripts/sign.env.example 참고}"
: "${NOTARY_PROFILE:=AC_NOTARY}"

echo "Building ${APP_NAME} (release)..."
swift build -c release

echo "Creating app bundle..."
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_DIR}/MacOS"
mkdir -p "${APP_DIR}/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/MacOS/"
cp "Info.plist" "${APP_DIR}/"
cp "Sources/JMTerm/Resources/AppIcon.icns" "${APP_DIR}/Resources/"

BUILD_TIMESTAMP=$(TZ=Asia/Seoul date +"%y%m%d.%H%M")
/usr/libexec/PlistBuddy -c "Add :BuildTimestamp string ${BUILD_TIMESTAMP}" "${APP_DIR}/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :BuildTimestamp ${BUILD_TIMESTAMP}" "${APP_DIR}/Info.plist"
echo "Build timestamp: ${BUILD_TIMESTAMP}"

echo "Signing with Developer ID..."
codesign --force --deep --options runtime --timestamp \
    --sign "${SIGN_ID}" "${APP_NAME}.app"
codesign --verify --deep --strict --verbose=1 "${APP_NAME}.app"

mkdir -p "${DIST_DIR}"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${BUILD_TIMESTAMP}.zip"

echo "Packaging for notarization..."
ditto -c -k --keepParent "${APP_NAME}.app" "${ZIP_PATH}"

echo "Submitting to Apple Notary Service (이거 5~15분 걸립니다)..."
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "${APP_NAME}.app"

echo "Verifying Gatekeeper acceptance..."
spctl -a -vv "${APP_NAME}.app"

echo "Repacking final distributable..."
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_NAME}.app" "${ZIP_PATH}"

echo "Installing to /Applications..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${APP_NAME}.app" "/Applications/${APP_NAME}.app"

echo ""
echo "Done!"
echo "  Installed:     /Applications/${APP_NAME}.app"
echo "  Distributable: ${ZIP_PATH}"
echo "  배포할 땐 이 zip 파일을 전달하세요."
echo "  Run: open /Applications/${APP_NAME}.app"
