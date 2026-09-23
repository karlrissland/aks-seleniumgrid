#!/usr/bin/env bash
# Registers the self-hosted GitHub Actions runner on the in-VNet gh-runner-vm.
# Runs on the GitHub-hosted provision job (has az login + GH_RUNNER_PAT).
# Ported from github.com/karlrissland/github-runner-setup (src/scripts/provisionrunner.ps1).
set -euo pipefail

REPO_OWNER="${REPO_OWNER:?REPO_OWNER is required}"
REPO_NAME="${REPO_NAME:?REPO_NAME is required}"
RESOURCE_GROUP="${RESOURCE_GROUP:?RESOURCE_GROUP is required}"
RUNNER_VM_NAME="${RUNNER_VM_NAME:-gh-runner-vm}"
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_VM_NAME}}"
RUNNER_VERSION="${RUNNER_VERSION:-2.319.1}"
GH_RUNNER_PAT="${GH_RUNNER_PAT:?GH_RUNNER_PAT is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"

echo "=== Registering GitHub Actions runner '${RUNNER_NAME}' on ${RUNNER_VM_NAME} ==="

# Mint a short-lived (1h) runner registration token via the GitHub REST API.
echo "1. Requesting a runner registration token..."
TOKEN=$(curl -fsSL -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_RUNNER_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/registration-token" \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])")

if [ -z "${TOKEN}" ]; then
    echo "ERROR: Failed to obtain a registration token." >&2
    exit 1
fi

# Run the on-VM setup script through the VM agent (no inbound SSH needed).
echo "2. Executing setup-runner.sh on ${RUNNER_VM_NAME} via az vm run-command..."
az vm run-command invoke \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${RUNNER_VM_NAME}" \
    --command-id RunShellScript \
    --scripts "@${SCRIPT_DIR}/setup-runner.sh" \
    --parameters "${REPO_URL}" "${RUNNER_NAME}" "${RUNNER_VERSION}" "${TOKEN}" \
    --query "value[0].message" -o tsv

echo "=== Runner registration complete. ==="
