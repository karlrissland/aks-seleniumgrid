#!/bin/bash
# Runs ON the gh-runner-vm (via `az vm run-command`). Installs and registers a
# GitHub Actions self-hosted runner as a systemd service with the `selenium` label.
# Ported from github.com/karlrissland/github-runner-setup (src/scripts/setuprunner.sh).
set -e

REPO_URL="$1"
RUNNER_NAME="$2"
RUNNER_VERSION="$3"
TOKEN="$4"
RUNNER_USER="azureuser"
RUNNER_HOME="/home/$RUNNER_USER"
RUNNER_DIR="$RUNNER_HOME/actions-runner"

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

echo "Downloading GitHub Actions Runner..."
su - "$RUNNER_USER" -c "cd '$RUNNER_DIR' && curl -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

echo "Extracting runner package..."
su - "$RUNNER_USER" -c "cd '$RUNNER_DIR' && tar xzf ./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

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
