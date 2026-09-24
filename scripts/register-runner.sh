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
GH_RUNNER_PAT="${GH_RUNNER_PAT:?GH_RUNNER_PAT is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
AUTH_HEADER="Authorization: Bearer ${GH_RUNNER_PAT}"

echo "=== Registering GitHub Actions runner '${RUNNER_NAME}' on ${RUNNER_VM_NAME} ==="

# Pin an explicit version only if the caller forced one; otherwise auto-detect the
# latest release. GitHub rejects registration from deprecated runner versions, so a
# stale hardcoded version silently fails on the VM and no runner ever comes online.
RUNNER_VERSION="${RUNNER_VERSION:-}"
if [ -z "${RUNNER_VERSION}" ]; then
    echo "0. Detecting latest GitHub Actions runner version..."
    RUNNER_VERSION=$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "${AUTH_HEADER}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/actions/runner/releases/latest" \
        | python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")
    if [ -z "${RUNNER_VERSION}" ]; then
        echo "WARNING: Could not detect latest runner version; falling back to 2.328.0." >&2
        RUNNER_VERSION="2.328.0"
    fi
fi
echo "   Using runner version: ${RUNNER_VERSION}"

# Mint a short-lived (1h) runner registration token via the GitHub REST API.
echo "1. Requesting a runner registration token..."
TOKEN=$(curl -fsSL -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "${AUTH_HEADER}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/actions/runners/registration-token" \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])")

if [ -z "${TOKEN}" ]; then
    echo "ERROR: Failed to obtain a registration token." >&2
    exit 1
fi

# Run the on-VM setup script through the VM agent (no inbound SSH needed).
# NOTE: `az vm run-command invoke` exits 0 even when the in-VM script fails, so we
# capture the full output and inspect it rather than trusting the exit code.
echo "2. Executing setup-runner.sh on ${RUNNER_VM_NAME} via az vm run-command..."
RUN_OUTPUT=$(az vm run-command invoke \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${RUNNER_VM_NAME}" \
    --command-id RunShellScript \
    --scripts "@${SCRIPT_DIR}/setup-runner.sh" \
    --parameters "${REPO_URL}" "${RUNNER_NAME}" "${RUNNER_VERSION}" "${TOKEN}" \
    --query "value[0].message" -o tsv)

echo "----- setup-runner.sh output (from VM) -----"
echo "${RUN_OUTPUT}"
echo "--------------------------------------------"

# The VM agent reports both stdout and stderr; a non-empty stderr section means the
# in-VM script failed even though the az command returned success.
if echo "${RUN_OUTPUT}" | grep -qiE '\[stderr\][[:space:]]*[^[:space:]]'; then
    echo "ERROR: setup-runner.sh reported errors on the VM (see [stderr] above)." >&2
    exit 1
fi

# Poll the runners API until this runner is registered AND online. This is what
# converts the silent 'test job waits forever' hang into a fast, clear failure.
echo "3. Waiting for runner '${RUNNER_NAME}' to come online..."
MAX_ATTEMPTS=20
SLEEP_SECONDS=15
for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
    STATUS=$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "${AUTH_HEADER}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${API}/actions/runners" \
        | python3 -c "import sys, json; runners=json.load(sys.stdin).get('runners', []); print(next((r['status'] for r in runners if r['name']=='${RUNNER_NAME}'), 'absent'))")

    if [ "${STATUS}" = "online" ]; then
        echo "   Runner '${RUNNER_NAME}' is online (attempt ${attempt})."
        echo "=== Runner registration complete. ==="
        exit 0
    fi
    echo "   attempt ${attempt}/${MAX_ATTEMPTS}: status='${STATUS}', retrying in ${SLEEP_SECONDS}s..."
    sleep "${SLEEP_SECONDS}"
done

echo "ERROR: Runner '${RUNNER_NAME}' did not come online within $((MAX_ATTEMPTS * SLEEP_SECONDS))s." >&2
echo "       Check the setup-runner.sh output above and the VM's runner service logs." >&2
exit 1
