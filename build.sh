#!/bin/bash
set -e

echo "Building Coding AI Usage..."

# Build the Swift package
swift build -c release 2>&1

# Create the app bundle
APP_NAME="Coding AI Usage"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}"

# Copy executable
cp .build/release/CodingAIUsage "${MACOS}/CodingAIUsage"

# Copy Info.plist
cp CodingAIUsage/Info.plist "${CONTENTS}/Info.plist"

echo ""
echo "Build complete: ${APP_BUNDLE}"
echo ""
echo "To run:"
echo "  open \"${APP_BUNDLE}\""
echo ""
echo "To install:"
echo "  cp -r \"${APP_BUNDLE}\" /Applications/"
echo "  open /Applications/\"${APP_BUNDLE}\""
