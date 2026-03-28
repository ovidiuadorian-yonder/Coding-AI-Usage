#!/bin/bash
set -e

echo "Building Coding AI Usage..."

# Build the Swift package
export CLANG_MODULE_CACHE_PATH="${PWD}/.build-release/ModuleCache"
swift build -c release --scratch-path .build-release 2>&1

# Create the app bundle
APP_NAME="Coding AI Usage"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}"

# Copy executable
cp .build-release/release/CodingAIUsage "${MACOS}/CodingAIUsage"

# Copy Info.plist
cp CodingAIUsage/Info.plist "${CONTENTS}/Info.plist"

# Copy app icon
cp Assets/Icon/AppIcon.icns "${RESOURCES}/AppIcon.icns"

echo ""
echo "Build complete: ${APP_BUNDLE}"
echo ""
echo "To run:"
echo "  open \"${APP_BUNDLE}\""
echo ""
echo "To install:"
echo "  cp -r \"${APP_BUNDLE}\" /Applications/"
echo "  open /Applications/\"${APP_BUNDLE}\""
