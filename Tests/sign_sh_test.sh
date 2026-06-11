#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGN_SCRIPT="${SCRIPT_DIR}/../sign.sh"

[[ -f "${SIGN_SCRIPT}" ]] || { echo "sign.sh is missing"; exit 1; }
[[ -x "${SIGN_SCRIPT}" ]] || { echo "sign.sh is not executable"; exit 1; }

grep -q 'codesign --force' "${SIGN_SCRIPT}" || { echo "expected 'codesign --force' in sign.sh"; exit 1; }
grep -q 'SIGN_IDENTITY' "${SIGN_SCRIPT}" || { echo "expected overridable SIGN_IDENTITY in sign.sh"; exit 1; }
grep -q 'find-identity' "${SIGN_SCRIPT}" || { echo "expected an identity-existence check in sign.sh"; exit 1; }

# With a guaranteed-missing identity the script must fail loudly (missing bundle or missing identity).
if SIGN_IDENTITY="nonexistent-identity-$$" bash "${SIGN_SCRIPT}" >/dev/null 2>&1; then
    echo "expected sign.sh to exit non-zero for a missing identity"
    exit 1
fi

echo "sign.sh checks passed"
