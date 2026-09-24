#!/usr/bin/env bash
# Deregisters the self-hosted runner from the GitHub repo (call before azd down,
# so the runner does not linger as "offline" after the VM is destroyed).
# Ported from github.com/karlrissland/github-runner-setup (src/scripts/deprovisionrunner.ps1).
set -euo pipefail

REPO_OWNER="${REPO_OWNER:?REPO_OWNER is required}"
REPO_NAME="${REPO_NAME:?REPO_NAME is required}"
RUNNER_NAME="${RUNNER_NAME:-gh-runner-vm}"
GH_RUNNER_PAT="${GH_RUNNER_PAT:?GH_RUNNER_PAT is required}"

API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners"

echo "=== Deregistering runner '${RUNNER_NAME}' from ${REPO_OWNER}/${REPO_NAME} ==="

# Look up the runner id by name.
RUNNER_ID=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_RUNNER_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}" \
    | python3 -c "import sys, json; print(next((r['id'] for r in json.load(sys.stdin).get('runners', []) if r['name'] == '${RUNNER_NAME}'), ''))")

if [ -z "${RUNNER_ID}" ]; then
    echo "Runner '${RUNNER_NAME}' not found (already removed?). Nothing to do."
    exit 0
fi

echo "Found runner id ${RUNNER_ID}; deleting..."
curl -fsSL -X DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_RUNNER_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/${RUNNER_ID}"

echo "=== Runner '${RUNNER_NAME}' (id ${RUNNER_ID}) removed. ==="
