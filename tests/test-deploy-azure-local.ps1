#Requires -Version 7.2
[CmdletBinding()]
param([switch]$RenderChart)

$ErrorActionPreference = 'Stop'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) "selenium-local-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testDirectory | Out-Null
. (Join-Path $PSScriptRoot '../scripts/deploy-azure-local.ps1') -LogDirectory $testDirectory

function Assert-DeploymentTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

try {
    $nativeFailed = $false
    try {
        Invoke-DeploymentTool pwsh @('-NoProfile', '-Command', '[Console]::Error.WriteLine("native-test-error"); exit 23')
    } catch {
        $nativeFailed = $_.Exception.Message -match 'exit 23' -and $_.Exception.Message -match 'native-test-error'
    }
    Assert-DeploymentTest $nativeFailed 'Native failures include exit code and stderr.'
    $nativeJson = Invoke-DeploymentTool pwsh @('-NoProfile', '-Command', '[Console]::Error.WriteLine("warning-only"); Write-Output ''{"ok":true}''') -Capture | ConvertFrom-Json
    Assert-DeploymentTest $nativeJson.ok 'Stderr does not corrupt captured JSON.'
    $nested = Get-DeploymentProperties ([pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded' } })
    $flat = Get-DeploymentProperties ([pscustomobject]@{ provisioningState = 'Succeeded' })
    Assert-DeploymentTest ($nested.provisioningState -eq $flat.provisioningState) 'ARM and flattened responses are supported.'
    $waitFailed = $false
    try { Wait-DeploymentCondition 'immediate timeout test' { $false } 0 } catch { $waitFailed = $_.Exception.Message -match 'Timed out' }
    Assert-DeploymentTest $waitFailed 'Unready conditions time out instead of reporting success.'
    Write-Host 'PASS: native errors, JSON capture, resource normalization, bounded waits'

    $script:bridgeId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/platform/providers/Microsoft.ResourceConnector/appliances/bridge'
    $script:customId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/platform/providers/Microsoft.ExtendedLocation/customLocations/local'
    $script:networkId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/platform/providers/Microsoft.AzureStackHCI/logicalNetworks/workload'
    $script:clusterId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-selenium-local/providers/Microsoft.Kubernetes/connectedClusters/aks-selenium-local'
    $script:keyPath = Join-Path $testDirectory 'test.pub'
    Set-Content -LiteralPath $script:keyPath -Value 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnly'
    $script:calls = [Collections.Generic.List[string]]::new()
    $script:answers = [Collections.Generic.Queue[string]]::new()
    $script:reuseCluster = $false
    $script:mismatchNetwork = $false
    $script:cancelDeployment = $false
    $script:failHelm = $false

    function Read-DeploymentInput {
        param([string]$Label, [string]$Default, [switch]$Optional)
        if ($script:answers.Count -eq 0) { throw "Unexpected prompt: $Label" }
        $answer = $script:answers.Dequeue()
        if ($answer -eq '<default>') { return $Default }
        return $answer
    }

    function Invoke-DeploymentTool {
        param([string]$Tool, [string[]]$Arguments, [switch]$Capture)
        $command = "$Tool $($Arguments -join ' ')"
        $script:calls.Add($command)
        if ($Tool -eq 'az') {
            $payload = switch -Regex ($command) {
                '^az version ' { @{ 'azure-cli' = '2.77.0' }; break }
                '^az account list ' { ,@(@{ id = 'test-subscription' }); break }
                '^az resource show .*appliances/' { @{ properties = @{ provisioningState = 'Succeeded'; status = 'Running' } }; break }
                '^az customlocation list ' { ,@(@{ id = $script:customId; name = 'local'; location = 'westeurope'; hostResourceId = $script:bridgeId }); break }
                '^az resource list ' { ,@(@{ id = $script:networkId; name = 'workload' }); break }
                '^az resource show .*logicalNetworks/' { @{ extendedLocation = @{ name = $script:customId }; properties = @{ provisioningState = 'Succeeded' } }; break }
                '^az aksarc list ' {
                    if ($script:reuseCluster) {
                        $selectedNetwork = if ($script:mismatchNetwork) { 'wrong-network' } else { $script:networkId }
                        ,@(@{ id = "$script:clusterId/providers/Microsoft.HybridContainerService/provisionedClusterInstances/default"; extendedLocation = @{ name = $script:customId }; properties = @{ cloudProviderProfile = @{ infraNetworkProfile = @{ vnetSubnetIds = @($selectedNetwork) } }; controlPlane = @{ controlPlaneEndpoint = @{ hostIP = '192.168.1.10' } } } })
                    } else { ,@() }
                    break
                }
                '^az aksarc show ' { @{ provisioningState = 'Succeeded' }; break }
                default { $null }
            }
            if ($Capture) { return (ConvertTo-Json -InputObject $payload -Depth 30 -Compress) }
            return
        }
        if ($Tool -eq 'helm') {
            if ($Arguments[0] -eq 'template') { return 'kind: Service' }
            if ($Arguments[0] -eq 'upgrade' -and $script:failHelm) { throw 'Mock Helm deployment failure' }
            return
        }
        if ($Tool -eq 'kubectl' -and $Capture) {
            if ('exec' -in $Arguments) {
                $nodes = foreach ($browser in @('chrome', 'firefox', 'MicrosoftEdge')) {
                    foreach ($replica in 1..2) { @{ availability = 'UP'; slots = @(@{ stereotype = @{ browserName = $browser } }) } }
                }
                return (@{ value = @{ ready = $true; nodes = @($nodes) } } | ConvertTo-Json -Depth 20)
            }
            return '{"status":{"loadBalancer":{"ingress":[{"ip":"192.168.1.20"}]}}}'
        }
    }

    function Set-DeploymentAnswers {
        $script:answers.Clear()
        foreach ($answer in @($script:bridgeId, '<default>', $script:networkId, '<default>', '<default>')) { $script:answers.Enqueue($answer) }
        if (-not $script:reuseCluster) {
            foreach ($answer in @('Standard_D4s_v3', 'Standard_A4_v2', '2', '192.168.1.10', '22222222-2222-2222-2222-222222222222', $script:keyPath, '', '<default>')) { $script:answers.Enqueue($answer) }
        }
        foreach ($answer in @('192.168.1.20', '', $(if ($script:cancelDeployment) { 'CANCEL' } else { 'DEPLOY' }))) { $script:answers.Enqueue($answer) }
        $script:calls.Clear()
    }

    Set-DeploymentAnswers
    Invoke-AzureLocalDeployment
    Assert-DeploymentTest ($script:answers.Count -eq 0) 'All new-cluster prompts consumed.'
    Assert-DeploymentTest (@($script:calls | Where-Object { $_ -match '^az aksarc create .*--validate' }).Count -eq 1) 'Validates before provisioning.'
    Assert-DeploymentTest (@($script:calls | Where-Object { $_ -match '^az aksarc create .*--no-wait' }).Count -eq 1) 'Creates AKS asynchronously for status polling.'
    Assert-DeploymentTest (@($script:calls | Where-Object { $_ -match '^helm upgrade --install' }).Count -eq 1) 'Installs Selenium.'
    $overrides = Get-Content (Join-Path $testDirectory 'aks-selenium-local-local-values.json') -Raw | ConvertFrom-Json
    Assert-DeploymentTest ($null -eq $overrides.hub.serviceAnnotations.'service.beta.kubernetes.io/azure-load-balancer-ipv4') 'Removes cloud IP annotation.'
    Assert-DeploymentTest ($overrides.hub.serviceAnnotations.'metallb.universe.tf/loadBalancerIPs' -eq '192.168.1.20') 'Requests the reserved local IP.'
    Write-Host 'PASS: new cluster prompts, validation, provisioning, MetalLB, Selenium, readiness'

    if ($RenderChart) {
        $overridePath = Join-Path $testDirectory 'aks-selenium-local-local-values.json'
        $annotationJson = $overrides.hub.serviceAnnotations | ConvertTo-Json -Compress
        $manifest = & helm template selenium-grid docker-selenium/selenium-grid --namespace selenium --values $ValuesFile --values $overridePath --set-json "hub.serviceAnnotations=$annotationJson"
        Assert-DeploymentTest ($LASTEXITCODE -eq 0) 'Real Helm rendering succeeds.'
        $manifestText = $manifest -join "`n"
        Assert-DeploymentTest ($manifestText -notmatch 'service\.beta\.kubernetes\.io/azure-load-balancer') 'Real manifest has no Azure annotations.'
        Assert-DeploymentTest ($manifestText -match 'metallb.universe.tf/loadBalancerIPs:.*192.168.1.20') 'Real manifest pins the local address.'
        Write-Host 'PASS: real Helm chart rendering and local annotation overrides'
    }

    $script:reuseCluster = $true
    Set-DeploymentAnswers
    Invoke-AzureLocalDeployment
    Assert-DeploymentTest (@($script:calls | Where-Object { $_ -match '^az aksarc create ' }).Count -eq 0) 'Rerun reuses the cluster.'
    Write-Host 'PASS: existing cluster reuse'

    $script:mismatchNetwork = $true
    Set-DeploymentAnswers
    $mismatchFailed = $false
    try { Invoke-AzureLocalDeployment } catch { $mismatchFailed = $_.Exception.Message -match 'different custom location or logical network' }
    Assert-DeploymentTest $mismatchFailed 'Rejects an existing cluster on the wrong network.'
    Write-Host 'PASS: wrong-network rejection'

    $script:mismatchNetwork = $false
    $script:cancelDeployment = $true
    Set-DeploymentAnswers
    $cancelled = $false
    try { Invoke-AzureLocalDeployment } catch { $cancelled = $_.Exception.Message -match 'cancelled' }
    Assert-DeploymentTest $cancelled 'Requires explicit deployment confirmation.'
    Assert-DeploymentTest (@($script:calls | Where-Object { $_ -match '^az group create |^helm upgrade |^az k8s-runtime ' }).Count -eq 0) 'Cancellation prevents resource changes.'
    Write-Host 'PASS: cancellation before resource changes'

    $script:cancelDeployment = $false
    $script:failHelm = $true
    Set-DeploymentAnswers
    $helmFailed = $false
    try { Invoke-AzureLocalDeployment } catch { $helmFailed = $_.Exception.Message -match 'Mock Helm deployment failure' }
    Assert-DeploymentTest $helmFailed 'Deployment propagates Helm failures.'
    Write-Host 'PASS: Helm failure propagation'
} finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}