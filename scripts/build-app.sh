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

echo "Installing to /Applications..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${APP_NAME}.app" "/Applications/${APP_NAME}.app"

echo "Done! Installed to /Applications/${APP_NAME}.app"
echo "Run: open /Applications/${APP_NAME}.app"
