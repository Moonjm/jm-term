#!/bin/bash
set -e

APP_NAME="JMTerm"
BUILD_DIR=".build/release"
APP_DIR="${APP_NAME}.app/Contents"

echo "Building ${APP_NAME}..."
swift build -c release

echo "Creating app bundle..."
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_DIR}/MacOS"
mkdir -p "${APP_DIR}/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/MacOS/"
cp "Info.plist" "${APP_DIR}/"
cp "Sources/JMTerm/Resources/AppIcon.icns" "${APP_DIR}/Resources/"

# 빌드 시각을 Info.plist에 박아넣어 런타임에 변하지 않도록 함 (KST)
BUILD_TIMESTAMP=$(TZ=Asia/Seoul date +"%y%m%d.%H%M")
/usr/libexec/PlistBuddy -c "Add :BuildTimestamp string ${BUILD_TIMESTAMP}" "${APP_DIR}/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :BuildTimestamp ${BUILD_TIMESTAMP}" "${APP_DIR}/Info.plist"
echo "Build timestamp: ${BUILD_TIMESTAMP}"

echo "Installing to /Applications..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${APP_NAME}.app" "/Applications/${APP_NAME}.app"

echo "Done! Installed to /Applications/${APP_NAME}.app"
echo "Run: open /Applications/${APP_NAME}.app"
