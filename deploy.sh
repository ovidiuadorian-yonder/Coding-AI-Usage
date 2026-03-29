#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="Coding AI Usage"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_BUNDLE}"

echo "Deploying ${APP_NAME}..."
echo ""

"${SCRIPT_DIR}/build.sh"

echo ""
echo "Installing ${APP_BUNDLE} to /Applications..."
rm -rf "${INSTALL_PATH}"
cp -R "${APP_BUNDLE}" /Applications/

echo "Launching ${APP_BUNDLE}..."
open "${INSTALL_PATH}"

echo ""
echo "Deploy complete: ${INSTALL_PATH}"
