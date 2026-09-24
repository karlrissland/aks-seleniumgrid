#!/bin/bash
# Runs ON the gh-runner-vm (via `az vm run-command`). Installs and registers a
# GitHub Actions self-hosted runner as a systemd service with the `selenium` label.
# Ported from github.com/karlrissland/github-runner-setup (src/scripts/setuprunner.sh).
set -e

REPO_URL="$1"
RUNNER_NAME="$2"
# Trim stray whitespace so a malformed value can't corrupt the download URL.
RUNNER_VERSION="$(echo "$3" | tr -d '[:space:]')"
TOKEN="$4"
RUNNER_USER="azureuser"
RUNNER_HOME="/home/$RUNNER_USER"
RUNNER_DIR="$RUNNER_HOME/actions-runner"

# Fall back to auto-detecting the latest release when no version is passed in.
# GitHub rejects registration from deprecated runner versions, so we never want a
# stale hardcoded value; this keeps the script self-sufficient if run directly.
# The call is unauthenticated on purpose: actions/runner is public and a
# fine-grained PAT scoped to another repo can 403 on it.
if [ -z "${RUNNER_VERSION}" ]; then
    echo "No runner version supplied; detecting the latest release..."
    RUNNER_VERSION=$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/actions/runner/releases/latest" \
        | python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || true)
    if [ -z "${RUNNER_VERSION}" ]; then
        echo "WARNING: Could not detect latest runner version; falling back to 2.328.0." >&2
        RUNNER_VERSION="2.328.0"
    fi
fi

echo "Setting up GitHub Actions Runner: $RUNNER_NAME for repo $REPO_URL"
echo "Using runner version: $RUNNER_VERSION"
echo "---------------------------------------------"

# Test + runner prerequisites (the runner ships its own Node for JS actions).
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl python3 python3-pip python3-venv

# If a runner is already configured, remove it before reconfiguring.
if [ -f "$RUNNER_DIR/.runner" ]; then
    echo "Existing runner config found; removing it first..."
    if [ -f "$RUNNER_DIR/svc.sh" ]; then
        (cd "$RUNNER_DIR" && ./svc.sh stop || true; ./svc.sh uninstall || true)
    fi
    su - "$RUNNER_USER" -c "cd '$RUNNER_DIR' && ./config.sh remove --token '$TOKEN'" || true
fi

echo "Preparing runner directory..."
su - "$RUNNER_USER" -c "mkdir -p '$RUNNER_DIR'"

RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"
echo "Downloading GitHub Actions Runner from: ${RUNNER_URL}"
# -f makes curl fail on HTTP errors instead of silently saving the error body
# (a 404 'Not Found' page is what caused 'gzip: stdin: not in gzip format').
if ! su - "$RUNNER_USER" -c "cd '$RUNNER_DIR' && curl -fSL --retry 3 --retry-delay 5 -o '$RUNNER_TARBALL' '$RUNNER_URL'"; then
    echo "ERROR: Failed to download the runner (version '${RUNNER_VERSION}') from ${RUNNER_URL}" >&2
    exit 1
fi

# Guard against a saved error page: confirm the file is a valid gzip archive.
if ! su - "$RUNNER_USER" -c "gzip -t '$RUNNER_DIR/$RUNNER_TARBALL'" 2>/dev/null; then
    echo "ERROR: Downloaded file is not a valid gzip archive. First bytes:" >&2
    su - "$RUNNER_USER" -c "head -c 200 '$RUNNER_DIR/$RUNNER_TARBALL'" >&2 || true
    echo >&2
    exit 1
fi

echo "Extracting runner package..."
su - "$RUNNER_USER" -c "cd '$RUNNER_DIR' && tar xzf './$RUNNER_TARBALL'"

# `selenium` label lets the test job target this in-VNet runner (the only host
# that can reach the private Selenium Grid hub).
echo "Configuring the runner (labels: self-hosted,linux,X64,selenium)..."
su - "$RUNNER_USER" -c "cd '$RUNNER_DIR' && ./config.sh --url '$REPO_URL' --token '$TOKEN' --name '$RUNNER_NAME' --labels 'self-hosted,linux,X64,selenium' --work _work --unattended --replace"

echo "Installing runner as a service..."
cd "$RUNNER_DIR"
./svc.sh install "$RUNNER_USER"

echo "Starting runner service..."
./svc.sh start

echo "Runner '$RUNNER_NAME' configured and started as a service."
