#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/WORKFLOW.md"
SETUP_DOC="${REPO_ROOT}/docs/symphony-setup.md"

require_grep() {
    local pattern="$1"
    local file="$2"
    local message="$3"

    if ! grep -Fqi -- "$pattern" "$file"; then
        echo "$message"
        exit 1
    fi
}

[[ -f "${WORKFLOW_FILE}" ]] || {
    echo "expected WORKFLOW.md to exist"
    exit 1
}

[[ -f "${SETUP_DOC}" ]] || {
    echo "expected docs/symphony-setup.md to exist"
    exit 1
}

require_grep "tracker:" "${WORKFLOW_FILE}" "expected tracker section in WORKFLOW.md"
require_grep "kind: linear" "${WORKFLOW_FILE}" "expected Linear tracker in WORKFLOW.md"
require_grep "project_slug:" "${WORKFLOW_FILE}" "expected project slug in WORKFLOW.md"
require_grep "active_states:" "${WORKFLOW_FILE}" "expected active states in WORKFLOW.md"
require_grep "- Ready" "${WORKFLOW_FILE}" "expected Ready state gate in WORKFLOW.md"
require_grep "- Todo" "${WORKFLOW_FILE}" "expected Todo state gate in WORKFLOW.md"
require_grep "terminal_states:" "${WORKFLOW_FILE}" "expected terminal states in WORKFLOW.md"
require_grep "after_create: |" "${WORKFLOW_FILE}" "expected after_create hook in WORKFLOW.md"
require_grep "git clone" "${WORKFLOW_FILE}" "expected repository clone hook in WORKFLOW.md"
require_grep "command: codex app-server" "${WORKFLOW_FILE}" "expected Codex app-server command in WORKFLOW.md"
require_grep "swift test" "${WORKFLOW_FILE}" "expected swift test guidance in WORKFLOW.md"
require_grep "./build.sh" "${WORKFLOW_FILE}" "expected build.sh guidance in WORKFLOW.md"
require_grep "keep the Linear issue updated" "${WORKFLOW_FILE}" "expected Linear update guidance in WORKFLOW.md"

require_grep "# Symphony Setup" "${SETUP_DOC}" "expected Symphony setup title in docs"
require_grep "project slug" "${SETUP_DOC}" "expected project slug guidance in docs"
require_grep "Ready" "${SETUP_DOC}" "expected Ready state guidance in docs"
require_grep "Todo" "${SETUP_DOC}" "expected Todo state guidance in docs"
require_grep "codex app-server" "${SETUP_DOC}" "expected Codex app-server reference in docs"
require_grep "LINEAR_API_KEY" "${SETUP_DOC}" "expected Linear API key setup in docs"

echo "Symphony setup files look complete"
