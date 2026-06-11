#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/../build.sh"

cp_line="$(grep -n 'cp .build-release/release/CodingAIUsage' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"
sign_line="$(grep -n 'sign.sh' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"

[[ -n "${cp_line}" ]] || { echo "expected executable copy step in build.sh"; exit 1; }
[[ -n "${sign_line}" ]] || { echo "expected sign.sh invocation in build.sh"; exit 1; }
[[ "${sign_line}" -gt "${cp_line}" ]] || { echo "expected signing after bundle assembly"; exit 1; }

icon_line="$(grep -n 'AppIcon.icns' "${BUILD_SCRIPT}" | head -1 | cut -d: -f1 || true)"

[[ -n "${icon_line}" ]] || { echo "expected icon copy step in build.sh"; exit 1; }
[[ "${sign_line}" -gt "${icon_line}" ]] || { echo "expected signing after the icon copy (so the signature seals the complete bundle)"; exit 1; }

echo "build.sh signing wiring looks correct"
