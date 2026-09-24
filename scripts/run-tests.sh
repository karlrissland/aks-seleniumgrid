#!/usr/bin/env bash
set -euo pipefail

# Determine Selenium Grid Hub URL
# If not provided, attempts to discover the internal LoadBalancer IP of the selenium-grid-hub service in namespace 'selenium'
GRID_URL="${1:-}"

if [ -z "$GRID_URL" ]; then
    echo "Attempting to discover Selenium Grid Hub internal IP via kubectl..."
    if command -v kubectl &> /dev/null; then
        HUB_IP=$(kubectl get svc selenium-grid-selenium-hub -n selenium -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [ -n "$HUB_IP" ]; then
            GRID_URL="http://${HUB_IP}:4444/wd/hub"
            echo "Discovered Selenium Grid Hub at: $GRID_URL"
        fi
    fi
fi

if [ -z "$GRID_URL" ]; then
    GRID_URL="http://localhost:4444/wd/hub"
    echo "Using default fallback Grid URL: $GRID_URL"
fi

BROWSER="${2:-all}"

echo "=== Running Selenium UI Tests ==="
echo "Target Grid URL: $GRID_URL"
echo "Target Browser:  $BROWSER"

# Ensure dependencies are installed
if [ -d "$HOME/.venv" ]; then
    source "$HOME/.venv/bin/activate"
fi

pytest tests/ \
    --grid-url="$GRID_URL" \
    --browser-name="$BROWSER" \
    --alluredir=allure-results \
    --html=test-results/report.html \
    --self-contained-html \
    -v
