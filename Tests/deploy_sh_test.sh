#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/../deploy.sh"

pkill_line="$(grep -n 'pkill -KILL -x "\${APP_PROCESS}"' "${DEPLOY_SCRIPT}" | cut -d: -f1 || true)"
pgrep_line="$(grep -n 'pgrep -x "\${APP_PROCESS}"' "${DEPLOY_SCRIPT}" | cut -d: -f1 || true)"
install_line="$(grep -n 'rm -rf "\${INSTALL_PATH}"' "${DEPLOY_SCRIPT}" | cut -d: -f1 || true)"
open_line="$(grep -n 'open "\${INSTALL_PATH}"' "${DEPLOY_SCRIPT}" | cut -d: -f1 || true)"

[[ -n "${pkill_line}" ]] || { echo "expected force-kill step in deploy.sh"; exit 1; }
[[ -n "${pgrep_line}" ]] || { echo "expected running-process check in deploy.sh"; exit 1; }
[[ -n "${install_line}" ]] || { echo "expected install step in deploy.sh"; exit 1; }
[[ -n "${open_line}" ]] || { echo "expected relaunch step in deploy.sh"; exit 1; }

[[ "${pkill_line}" -lt "${install_line}" ]] || {
    echo "expected force-kill to happen before install"
    exit 1
}

[[ "${open_line}" -gt "${install_line}" ]] || {
    echo "expected relaunch to happen after install"
    exit 1
}

echo "deploy.sh force-kill and relaunch flow looks correct"
