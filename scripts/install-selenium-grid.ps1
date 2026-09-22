<#
.SYNOPSIS
    azd postprovision hook (Windows / PowerShell).
    Installs / upgrades Selenium Grid on the AKS cluster provisioned by azd.

.DESCRIPTION
    Reads the AKS cluster name and resource group from azd output environment
    variables (AKS_CLUSTER_NAME / AZURE_RESOURCE_GROUP), pulls kubeconfig
    credentials, and deploys the docker-selenium Helm chart.
#>
[CmdletBinding()]
param(
    [string]$Namespace = 'selenium',
    [string]$ValuesFile = 'helm/selenium-grid/values.yaml',
    [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
    [string]$ClusterName = $env:AKS_CLUSTER_NAME
)

$ErrorActionPreference = 'Stop'

Write-Host '=== Installing / Upgrading Selenium Grid on AKS ===' -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($ResourceGroup) -or [string]::IsNullOrWhiteSpace($ClusterName)) {
    throw "Resource group or AKS cluster name not found. Ensure this runs as an azd postprovision hook, or pass -ResourceGroup and -ClusterName."
}

# azd may spawn this hook with a stale PATH that predates recent tool installs
# (e.g. helm installed after the azd terminal was opened). Rebuild PATH from the
# machine + user registry so newly installed tools resolve.
$env:Path = @(
    [System.Environment]::GetEnvironmentVariable('Path', 'Machine'),
    [System.Environment]::GetEnvironmentVariable('Path', 'User')
) -join ';'

# Fallback: locate a winget-installed helm if it is still not on PATH.
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    $wingetPackages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $helmExe = Get-ChildItem -Path $wingetPackages -Recurse -Filter helm.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($helmExe) { $env:Path = "$($helmExe.DirectoryName);$env:Path" }
}

foreach ($tool in @('az', 'kubectl', 'helm')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required tool '$tool' is not installed or not on PATH. Install it, then re-run: azd hooks run postprovision"
    }
}

Write-Host "1. Fetching AKS credentials for '$ClusterName' in '$ResourceGroup'..." -ForegroundColor Yellow
az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --overwrite-existing
if ($LASTEXITCODE -ne 0) { throw "Failed to get AKS credentials (exit $LASTEXITCODE)." }

Write-Host '2. Adding docker-selenium Helm repository...' -ForegroundColor Yellow
helm repo add docker-selenium https://www.selenium.dev/docker-selenium
helm repo update

Write-Host "3. Ensuring namespace '$Namespace' exists..." -ForegroundColor Yellow
kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -

Write-Host '4. Deploying Selenium Grid Helm chart...' -ForegroundColor Yellow
# Retry to ride out transient AKS API connection resets.
$maxAttempts = 3
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    helm upgrade --install selenium-grid docker-selenium/selenium-grid `
        --namespace $Namespace `
        --values $ValuesFile
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq $maxAttempts) { throw "Helm deployment failed after $maxAttempts attempts (exit $LASTEXITCODE)." }
    Write-Warning "Helm deployment attempt $attempt failed (exit $LASTEXITCODE). Retrying in 15s..."
    Start-Sleep -Seconds 15
}

Write-Host '5. Waiting for the Selenium Grid hub to be ready...' -ForegroundColor Yellow
kubectl rollout status deployment/selenium-grid-selenium-hub -n $Namespace --timeout=180s

# The browser-node pods can stay 0/1 Ready due to a known docker-selenium chart
# readiness-probe quirk even while they are registered. Poll the hub's /status
# endpoint (the authoritative grid-readiness signal) instead.
Write-Host '6. Waiting for the Selenium Grid to report ready...' -ForegroundColor Yellow
$ready = $false
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $status = kubectl exec -n $Namespace deploy/selenium-grid-selenium-hub -- curl -s http://localhost:4444/status 2>$null
    if ($status -match '"ready":\s*true') { $ready = $true; break }
    Start-Sleep -Seconds 10
}
if ($ready) {
    Write-Host 'Selenium Grid is ready.' -ForegroundColor Green
} else {
    Write-Warning 'Selenium Grid did not report ready within the timeout; check pod logs with: kubectl logs -n selenium -l app=selenium-grid-selenium-hub'
}

Write-Host '=== Deployment Details ===' -ForegroundColor Green
kubectl get pods -n $Namespace -o wide
Write-Host ''
kubectl get svc -n $Namespace
