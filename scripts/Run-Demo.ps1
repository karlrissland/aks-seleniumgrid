<#
.SYNOPSIS
    One-click Selenium Grid demo: installs the test dependencies, runs the UI
    suite against the grid via its private DNS name, then opens the HTML report.
.NOTES
    Backing the "Run Selenium Demo" desktop shortcut created on the Jumpbox.
#>
param(
    [string]$GridDnsName = 'seleniumgrid.dev.lab',
    [ValidateSet('all', 'chrome', 'firefox', 'edge')]
    [string]$Browser = 'all'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$gridUrl = "http://${GridDnsName}:4444/wd/hub"
Write-Host '=== Selenium Grid Demo ===' -ForegroundColor Cyan
Write-Host "Grid      : $gridUrl"
Write-Host "Browser(s): $Browser"
Write-Host "Console   : http://${GridDnsName}:4444/ui/  (watch sessions live)" -ForegroundColor DarkGray

python -m pip install -r tests/requirements.txt

python -m pytest tests/ `
    --grid-url $gridUrl `
    --browser-name $Browser `
    --alluredir allure-results `
    --html=test-results/report.html --self-contained-html -v

$report = Join-Path $repoRoot 'test-results/report.html'
if (Test-Path $report) { Start-Process $report }
