#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="Coding AI Usage"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_BUNDLE}"
APP_PROCESS="CodingAIUsage"

echo "Deploying ${APP_NAME}..."
echo ""

"${SCRIPT_DIR}/build.sh"

if pgrep -x "${APP_PROCESS}" >/dev/null 2>&1; then
    echo "Stopping running ${APP_NAME}..."
    pkill -KILL -x "${APP_PROCESS}" >/dev/null 2>&1 || true

    for _ in {1..20}; do
        if ! pgrep -x "${APP_PROCESS}" >/dev/null 2>&1; then
            break
        fi
        sleep 0.25
    done

    if pgrep -x "${APP_PROCESS}" >/dev/null 2>&1; then
        echo "Failed to stop ${APP_NAME}." >&2
        exit 1
    fi
fi

echo ""
echo "Installing ${APP_BUNDLE} to /Applications..."
rm -rf "${INSTALL_PATH}"
cp -R "${APP_BUNDLE}" /Applications/

echo "Launching ${APP_BUNDLE}..."
open "${INSTALL_PATH}"

echo ""
echo "Deploy complete: ${INSTALL_PATH}"
