#!/usr/bin/env bash
# One-time helper to set up GitHub -> Azure OIDC federation for the CI/CD workflow.
# Creates an Entra app registration + service principal, a federated credential
# scoped to this repo, and grants Contributor on the subscription. Prints the
# GitHub variables/secrets to configure. Requires: az login (Owner/UAA on the sub).
set -euo pipefail

REPO_OWNER="${REPO_OWNER:?Set REPO_OWNER (GitHub org/user)}"
REPO_NAME="${REPO_NAME:?Set REPO_NAME}"
APP_NAME="${APP_NAME:-gh-oidc-${REPO_NAME}}"
BRANCH="${BRANCH:-main}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
TENANT_ID="$(az account show --query tenantId -o tsv)"

echo "App: ${APP_NAME}  Repo: ${REPO_OWNER}/${REPO_NAME}  Branch: ${BRANCH}"
echo "Subscription: ${SUBSCRIPTION_ID}  Tenant: ${TENANT_ID}"

# Create (or reuse) the app registration.
APP_ID=$(az ad app list --display-name "${APP_NAME}" --query "[0].appId" -o tsv)
if [ -z "${APP_ID}" ]; then
    APP_ID=$(az ad app create --display-name "${APP_NAME}" --query appId -o tsv)
    echo "Created app registration ${APP_ID}"
else
    echo "Reusing app registration ${APP_ID}"
fi

# Ensure a service principal exists for the app.
if [ -z "$(az ad sp list --filter "appId eq '${APP_ID}'" --query "[0].id" -o tsv)" ]; then
    az ad sp create --id "${APP_ID}" >/dev/null
    echo "Created service principal for ${APP_ID}"
fi

# Federated credential for the main-branch ref (the workflow_dispatch runs on it).
SUBJECT="repo:${REPO_OWNER}/${REPO_NAME}:ref:refs/heads/${BRANCH}"
if [ -z "$(az ad app federated-credential list --id "${APP_ID}" --query "[?subject=='${SUBJECT}'] | [0].id" -o tsv)" ]; then
    az ad app federated-credential create --id "${APP_ID}" --parameters "{
        \"name\": \"gh-${REPO_NAME}-${BRANCH}\",
        \"issuer\": \"https://token.actions.githubusercontent.com\",
        \"subject\": \"${SUBJECT}\",
        \"audiences\": [\"api://AzureADTokenExchange\"]
    }" >/dev/null
    echo "Created federated credential for subject: ${SUBJECT}"
else
    echo "Federated credential already exists for subject: ${SUBJECT}"
fi

# Grant roles so the workflow can provision + tear down. Contributor covers
# resource CRUD; User Access Administrator is required because the infra creates
# role assignments (Jumpbox identity -> AKS roles), which Contributor cannot do.
SP_OBJECT_ID=$(az ad sp show --id "${APP_ID}" --query id -o tsv)
for ROLE in "Contributor" "User Access Administrator"; do
    az role assignment create \
        --assignee-object-id "${SP_OBJECT_ID}" \
        --assignee-principal-type ServicePrincipal \
        --role "${ROLE}" \
        --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null || true
    echo "Granted ${ROLE} on subscription ${SUBSCRIPTION_ID}"
done

cat <<EOF

============================================================
Configure these in GitHub (Settings -> Secrets and variables -> Actions):

  Repository VARIABLES:
    AZURE_CLIENT_ID        = ${APP_ID}
    AZURE_TENANT_ID        = ${TENANT_ID}
    AZURE_SUBSCRIPTION_ID  = ${SUBSCRIPTION_ID}

  Repository SECRETS:
    ADMIN_PASSWORD         = <a strong VM admin password>
    GH_RUNNER_PAT          = <PAT with Administration: Read & write on this repo>
============================================================
EOF
