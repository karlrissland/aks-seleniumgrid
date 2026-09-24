#!/usr/bin/env bash
# azd postprovision hook (POSIX). Installs / upgrades Selenium Grid on AKS.
set -euo pipefail

NAMESPACE="${1:-selenium}"
VALUES_FILE="${2:-helm/selenium-grid/values.yaml}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
CLUSTER_NAME="${AKS_CLUSTER_NAME:-}"

echo "=== Installing / Upgrading Selenium Grid on AKS ==="

# Fetch AKS credentials when running as an azd hook (azd exports these outputs).
if [ -n "$RESOURCE_GROUP" ] && [ -n "$CLUSTER_NAME" ]; then
    echo "0. Fetching AKS credentials for '$CLUSTER_NAME' in '$RESOURCE_GROUP'..."
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing
fi

# Add official Selenium Helm repo
echo "1. Adding docker-selenium Helm repository..."
helm repo add docker-selenium https://www.selenium.dev/docker-selenium
helm repo update

# Create namespace if it does not exist
echo "2. Ensuring namespace '$NAMESPACE' exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Deploy Helm chart
echo "3. Deploying Selenium Grid Helm chart..."
# Retry to ride out transient AKS API connection resets.
attempt=1
until helm upgrade --install selenium-grid docker-selenium/selenium-grid \
    --namespace "$NAMESPACE" \
    --values "$VALUES_FILE"; do
    if [ "$attempt" -ge 3 ]; then
        echo "Helm deployment failed after $attempt attempts." >&2
        exit 1
    fi
    echo "Helm deployment attempt $attempt failed. Retrying in 15s..." >&2
    attempt=$((attempt + 1))
    sleep 15
done

echo "4. Waiting for the Selenium Grid hub to be ready..."
kubectl rollout status deployment/selenium-grid-selenium-hub -n "$NAMESPACE" --timeout=180s

# The browser-node pods can stay 0/1 Ready due to a known docker-selenium chart
# readiness-probe quirk even while they are registered. Poll the hub's /status
# endpoint (the authoritative grid-readiness signal) instead.
echo "5. Waiting for the Selenium Grid to report ready..."
deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if kubectl exec -n "$NAMESPACE" deploy/selenium-grid-selenium-hub -- curl -s http://localhost:4444/status | grep -Eq '"ready": ?true'; then
        echo "Selenium Grid is ready."
        break
    fi
    sleep 10
done

echo "=== Deployment Details ==="
kubectl get pods -n "$NAMESPACE" -o wide
echo ""
kubectl get svc -n "$NAMESPACE"
