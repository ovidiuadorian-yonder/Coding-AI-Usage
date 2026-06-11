#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="Coding AI Usage"
APP_BUNDLE="${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-Coding AI Usage Self-Signed}"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "error: ${APP_BUNDLE} not found. Run ./build.sh first." >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
    cat >&2 <<EOF
error: code-signing identity "${SIGN_IDENTITY}" not found.

A stable identity is required so the macOS Keychain "Always Allow" grant
persists across rebuilds. Create a free self-signed identity once:

  1. Open Keychain Access.app
  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate...
  3. Name:            ${SIGN_IDENTITY}
     Identity Type:   Self Signed Root
     Certificate Type: Code Signing
  4. Click Create, then keep it in the "login" keychain.

Already have an Apple Developer ID? Re-run with:
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
EOF
    exit 1
fi

echo "Signing ${APP_BUNDLE} with \"${SIGN_IDENTITY}\"..."
codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
codesign --verify --strict --verbose=2 "${APP_BUNDLE}"
echo "Signed ${APP_BUNDLE} (stable identity: ${SIGN_IDENTITY})."
