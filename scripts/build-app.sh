#!/bin/bash
set -e

APP_NAME="ShellDock"
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

echo "Done! ${APP_NAME}.app created."
echo "Run: open ${APP_NAME}.app"
