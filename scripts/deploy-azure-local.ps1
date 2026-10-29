#Requires -Version 7.2
<#
.SYNOPSIS
    Interactively deploys AKS and Selenium Grid to an existing Azure Local environment.
.DESCRIPTION
    Run on a management machine with direct network access to the local Kubernetes
    API. Requires az (2.77+), kubectl, helm, Azure permissions, and a healthy Azure
    Local resource bridge, custom location, and logical network. Does not deploy
    Azure Local itself, DNS, a jumpbox, or a GitHub runner. Uses MetalLB ARP mode.
    Logs may contain infrastructure details; kubeconfig contains admin credentials.
.EXAMPLE
    ./scripts/deploy-azure-local.ps1
.EXAMPLE
    ./scripts/deploy-azure-local.ps1 -ResourceBridgeId /subscriptions/SUB/resourceGroups/RG/providers/Microsoft.ResourceConnector/appliances/BRIDGE -Verbose
#>
[CmdletBinding()]
param(
    [string]$ResourceBridgeId,
    [string]$ResourceGroup,
    [string]$ClusterName,
    [string]$Namespace = 'selenium',
    [string]$ValuesFile = (Join-Path $PSScriptRoot '../helm/selenium-grid/values.yaml'),
    [ValidateRange(5, 180)]
    [int]$TimeoutMinutes = 45,
    [string]$LogDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'selenium-azure-local')
)

function Write-DeploymentStatus {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Get-DeploymentProperties {
    param($Resource)
    if ($null -ne $Resource.properties) { return $Resource.properties }
    return $Resource
}

function Read-DeploymentInput {
    param([string]$Label, [string]$Default, [switch]$Optional)
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $answer = Read-Host "$Label$suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        if (-not [string]::IsNullOrWhiteSpace($answer)) { return $answer.Trim() }
        if ($Optional) { return '' }
        Write-Warning 'A value is required.'
    }
}

function Invoke-DeploymentTool {
    param([string]$Tool, [string[]]$Arguments, [switch]$Capture)
    Write-Verbose "$Tool $($Arguments -join ' ')"
    $stderrFile = [IO.Path]::GetTempFileName()
    $outputLines = [Collections.Generic.List[string]]::new()
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        & $Tool @Arguments 2> $stderrFile | ForEach-Object {
            $outputLines.Add([string]$_)
            if (-not $Capture) { Write-Host $_ }
        }
        $commandExitCode = $LASTEXITCODE
        $stderrText = Get-Content -LiteralPath $stderrFile -Raw
        if ($stderrText) { Write-Host $stderrText -ForegroundColor DarkYellow }
        if ($commandExitCode -ne 0) {
            throw "Command failed (exit $commandExitCode): $Tool $($Arguments -join ' ')`n$stderrText`n$($outputLines -join "`n")"
        }
        if ($Capture) { return ($outputLines -join "`n") }
    } finally {
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DeploymentAz {
    param([string[]]$Arguments, [switch]$Json)
    if ($script:DeploymentSubscription -and $Arguments[0] -notin @('login', 'account', 'extension', 'version')) {
        $Arguments += @('--subscription', $script:DeploymentSubscription)
    }
    if ($Json) {
        $text = Invoke-DeploymentTool az ($Arguments + @('--output', 'json')) -Capture
        try {
            return ($text | ConvertFrom-Json -Depth 100 -ErrorAction Stop)
        } catch {
            throw [InvalidOperationException]::new(
                "Azure CLI returned invalid JSON for: az $($Arguments -join ' ') --output json`nRaw stdout:`n$text",
                $_.Exception
            )
        }
    }
    Invoke-DeploymentTool az ($Arguments + @('--verbose', '--output', 'none'))
}

function Invoke-DeploymentKubectl {
    param([string[]]$Arguments, [switch]$Capture)
    Invoke-DeploymentTool kubectl (@('--kubeconfig', $script:DeploymentKubeconfig, '--request-timeout=30s') + $Arguments) -Capture:$Capture
}

function Wait-DeploymentCondition {
    param([string]$Description, [scriptblock]$Check, [int]$Minutes = 10)
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
        if (& $Check) { Write-DeploymentStatus "${Description}: ready"; return }
        if ((Get-Date) -ge $deadline) { throw "Timed out after $Minutes minutes: $Description" }
        Write-DeploymentStatus "Waiting: $Description"
        Start-Sleep -Seconds 10
    } while ($true)
}

function Read-DeploymentIPv4 {
    param([string]$Label)
    while ($true) {
        $address = Read-DeploymentInput $Label
        $parsed = $null
        if ($address -match '^\d{1,3}(\.\d{1,3}){3}$' -and
            [Net.IPAddress]::TryParse($address, [ref]$parsed) -and
            $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { return $address }
        Write-Warning 'Enter a valid dotted-decimal IPv4 address.'
    }
}

function Invoke-AzureLocalDeployment {
    $ErrorActionPreference = 'Stop'
    $script:DeploymentSubscription = $null
    $script:DeploymentKubeconfig = $null
    $script:DeploymentClusterArgs = $null
    $script:DeploymentClusterAvailable = $false
    $script:DeploymentKubernetesAvailable = $false
    foreach ($tool in @('az', 'kubectl', 'helm')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool '$tool' is missing from PATH." }
    }
    if (-not (Test-Path -LiteralPath $ValuesFile -PathType Leaf)) { throw "Helm values file not found: $ValuesFile" }
    $cliVersion = Invoke-DeploymentAz @('version') -Json
    if ([version]$cliVersion.'azure-cli' -lt [version]'2.77.0') { throw 'Azure CLI 2.77.0 or newer is required.' }
    $accounts = @(Invoke-DeploymentAz @('account', 'list') -Json)
    if ($accounts.Count -eq 0) { Invoke-DeploymentTool az @('login', '--output', 'none') }

    $bridgeId = $ResourceBridgeId
    if (-not $bridgeId) { $bridgeId = Read-DeploymentInput 'Resource bridge ARM resource ID' }
    if ($bridgeId -notmatch '^/subscriptions/([^/]+)/resourceGroups/[^/]+/providers/Microsoft\.ResourceConnector/appliances/[^/]+$') {
        throw 'Expected a full Microsoft.ResourceConnector/appliances resource ID.'
    }
    $script:DeploymentSubscription = $Matches[1]
    Write-DeploymentStatus "Validating bridge in subscription $script:DeploymentSubscription"
    $bridge = Invoke-DeploymentAz @('resource', 'show', '--ids', $bridgeId, '--api-version', '2022-10-27') -Json
    if ($bridge.properties.provisioningState -ne 'Succeeded' -or $bridge.properties.status -ne 'Running') {
        throw "Resource bridge must be Succeeded/Running. Current state: $($bridge.properties | ConvertTo-Json -Depth 20)"
    }
    foreach ($extension in @('aksarc', 'customlocation', 'k8s-runtime')) {
        Write-DeploymentStatus "Ensuring Azure CLI extension: $extension"
        Invoke-DeploymentAz @('extension', 'add', '--name', $extension, '--upgrade', '--yes')
    }

    $locations = @(Invoke-DeploymentAz @('customlocation', 'list') -Json | Where-Object {
        $_.hostResourceId -eq $bridgeId -or $_.properties.hostResourceId -eq $bridgeId
    })
    if ($locations.Count -eq 0) { throw 'No custom locations found for this resource bridge. Check permissions and Azure Local health.' }
    $locations | Select-Object name, id | Format-Table -AutoSize | Out-Host
    $defaultLocation = if ($locations.Count -eq 1) { $locations[0].id } else { '' }
    $customLocationId = Read-DeploymentInput 'Custom location ARM resource ID' $defaultLocation
    if ($customLocationId -notin $locations.id) { throw 'Select a custom location attached to the supplied bridge.' }
    $customLocation = $locations | Where-Object id -eq $customLocationId | Select-Object -First 1
    $networks = @(Invoke-DeploymentAz @('resource', 'list', '--resource-type', 'Microsoft.AzureStackHCI/logicalNetworks') -Json)
    $networks | Select-Object name, id | Format-Table -AutoSize | Out-Host
    $networkId = Read-DeploymentInput 'Azure Local logical network ARM resource ID'
    if ($networkId -notin $networks.id) { throw 'Logical network was not found in the selected subscription.' }
    $network = Invoke-DeploymentAz @('resource', 'show', '--ids', $networkId, '--api-version', '2024-01-01') -Json
    if ($network.extendedLocation.name -ne $customLocationId -or $network.properties.provisioningState -ne 'Succeeded') {
        throw 'Logical network must be provisioned successfully in the selected custom location.'
    }

    $targetGroup = $ResourceGroup
    if (-not $targetGroup) { $targetGroup = Read-DeploymentInput 'Target resource group' 'rg-selenium-local' }
    $targetCluster = $ClusterName
    if (-not $targetCluster) { $targetCluster = Read-DeploymentInput 'AKS cluster name' 'aks-selenium-local' }
    if ($targetCluster -notmatch '^[a-z][a-z0-9-]{0,61}[a-z0-9]$') { throw 'Use a 2-63 character lowercase cluster name, starting with a letter and ending with a letter or digit.' }
    if ($Namespace -notmatch '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$') { throw 'Namespace must be a Kubernetes DNS label.' }
    $script:DeploymentClusterArgs = @('--resource-group', $targetGroup, '--name', $targetCluster)
    $expectedClusterId = "/subscriptions/$script:DeploymentSubscription/resourceGroups/$targetGroup/providers/Microsoft.Kubernetes/connectedClusters/$targetCluster"
    $clusters = @(Invoke-DeploymentAz @('resource', 'list', '--resource-type', 'Microsoft.Kubernetes/connectedClusters') -Json)
    $existingCluster = $null
    if ($expectedClusterId -in $clusters.id) {
        $existingCluster = Invoke-DeploymentAz (@('aksarc', 'show') + $script:DeploymentClusterArgs) -Json
    }
    $createArgs = @()
    $controlPlaneIp = $null
    if ($existingCluster) {
        $existingProperties = Get-DeploymentProperties $existingCluster
        $controlPlaneIp = $existingProperties.controlPlane.controlPlaneEndpoint.hostIP
        if ($existingCluster.extendedLocation.name -ne $customLocationId -or $networkId -notin $existingProperties.cloudProviderProfile.infraNetworkProfile.vnetSubnetIds) {
            throw 'Existing cluster belongs to a different custom location or logical network.'
        }
        $script:DeploymentClusterAvailable = $true
        Write-Warning 'Existing cluster will be reused without changing its size or Kubernetes version.'
    } else {
        Invoke-DeploymentTool az @('aksarc', 'vmsize', 'list', '--custom-location', $customLocationId, '--subscription', $script:DeploymentSubscription, '--output', 'table')
        $workerSize = Read-DeploymentInput 'Supported Linux worker VM size (4 vCPU / 16 GB or greater recommended)'
        $controlPlaneSize = Read-DeploymentInput 'Supported control-plane VM size'
        $workerCountText = Read-DeploymentInput 'Worker node count' '2'
        $workerCount = 0
        if (-not [int]::TryParse($workerCountText, [ref]$workerCount) -or $workerCount -lt 1) { throw 'Worker node count must be a positive integer.' }
        $controlPlaneIp = Read-DeploymentIPv4 'Reserved control-plane IP (in the logical network subnet)'
        $adminGroup = Read-DeploymentInput 'Microsoft Entra cluster administrator group object ID'
        $parsedGuid = [guid]::Empty
        if (-not [guid]::TryParse($adminGroup, [ref]$parsedGuid)) { throw 'Administrator group object ID must be a GUID.' }
        $sshKey = Read-DeploymentInput 'Existing SSH public key file path'
        $sshKey = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($sshKey)
        if (-not (Test-Path -LiteralPath $sshKey -PathType Leaf)) { throw "SSH public key file not found: $sshKey" }
        if ((Get-Content -LiteralPath $sshKey -Raw) -notmatch '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-\S+)\s+') { throw 'The SSH key file must contain an OpenSSH public key, not a private key.' }
        Invoke-DeploymentTool az @('aksarc', 'get-versions', '--custom-location', $customLocationId, '--subscription', $script:DeploymentSubscription, '--output', 'table')
        $kubernetesVersion = Read-DeploymentInput 'Kubernetes version (Enter for platform default)' -Optional
        $podCidr = Read-DeploymentInput 'Pod CIDR (must not overlap your local networks)' '10.244.0.0/16'
        $createArgs = @('aksarc', 'create') + $script:DeploymentClusterArgs + @(
            '--custom-location', $customLocationId, '--vnet-ids', $networkId,
            '--location', $customLocation.location, '--node-count', "$workerCount", '--node-vm-size', $workerSize,
            '--control-plane-count', '1', '--control-plane-vm-size', $controlPlaneSize,
            '--control-plane-ip', $controlPlaneIp, '--load-balancer-count', '0', '--pod-cidr', $podCidr,
            '--aad-admin-group-object-ids', $adminGroup, '--ssh-key-value', $sshKey
        )
        if ($kubernetesVersion) { $createArgs += @('--kubernetes-version', $kubernetesVersion) }
    }

    $hubIp = Read-DeploymentIPv4 'Reserved Selenium load-balancer IP (same L2 subnet as workers, outside node/DHCP pools)'
    if ($controlPlaneIp -and $hubIp -eq $controlPlaneIp) { throw 'Hub IP and control-plane IP must differ.' }
    $chartVersion = Read-DeploymentInput 'Selenium Helm chart version (Enter for latest)' -Optional
    Write-Warning 'Confirm both IPs are reserved and unused, pod CIDR does not overlap local networks, and this machine can reach the local Kubernetes API.'
    Write-Warning 'Grid and noVNC are unauthenticated with the repository defaults. Restrict access to a trusted test network.'
    Write-Warning 'MetalLB setup requires Azure role-assignment permissions and Microsoft Graph Application.Read.All (or an administrator-preconfigured extension).'
    Write-Host "Target: $targetGroup / $targetCluster`nCustom location: $customLocationId`nNetwork: $networkId`nGrid IP: $hubIp`nReuse existing cluster: $([bool]$existingCluster)"
    if ((Read-DeploymentInput 'Type DEPLOY to create/update these resources') -cne 'DEPLOY') { throw 'Deployment cancelled. No deployment resources were changed.' }

    Write-DeploymentStatus 'Creating or validating target resource group'
    Invoke-DeploymentAz @('group', 'create', '--name', $targetGroup, '--location', $customLocation.location)
    if (-not $existingCluster) {
        Write-DeploymentStatus 'Validating AKS deployment inputs'
        Invoke-DeploymentAz ($createArgs + @('--validate'))
        Write-DeploymentStatus 'Starting AKS provisioning'
        $script:DeploymentClusterAvailable = $true
        Invoke-DeploymentAz ($createArgs + @('--no-wait'))
    }
    Wait-DeploymentCondition 'AKS provisioning' {
        $state = Invoke-DeploymentAz (@('aksarc', 'show') + $script:DeploymentClusterArgs) -Json
        $stateProperties = Get-DeploymentProperties $state
        Write-DeploymentStatus "AKS provisioning state: $($stateProperties.provisioningState)"
        if ($stateProperties.provisioningState -in @('Failed', 'Canceled', 'Deleting')) { throw ($state | ConvertTo-Json -Depth 50) }
        return $stateProperties.provisioningState -eq 'Succeeded'
    } $TimeoutMinutes

    $script:DeploymentKubeconfig = Join-Path $LogDirectory "$targetCluster-$([guid]::NewGuid().ToString('N')).kubeconfig"
    Write-DeploymentStatus 'Retrieving dedicated admin kubeconfig (direct local API access required)'
    Invoke-DeploymentAz (@('aksarc', 'get-credentials') + $script:DeploymentClusterArgs + @('--admin', '--file', $script:DeploymentKubeconfig, '--overwrite-existing'))
    Invoke-DeploymentKubectl @('get', 'nodes', '-o', 'wide')
    $script:DeploymentKubernetesAvailable = $true
    Invoke-DeploymentKubectl @('wait', '--for=condition=Ready', 'nodes', '--all', '--timeout=600s')

    Write-DeploymentStatus 'Enabling Arc MetalLB extension'
    $clusterUri = $expectedClusterId.TrimStart('/')
    Invoke-DeploymentAz @('k8s-runtime', 'load-balancer', 'enable', '--resource-uri', $clusterUri)
    Write-DeploymentStatus 'Configuring single-IP MetalLB ARP pool selenium-grid'
    Invoke-DeploymentAz @('k8s-runtime', 'load-balancer', 'create', '--resource-uri', $clusterUri, '--load-balancer-name', 'selenium-grid', '--addresses', "$hubIp-$hubIp", '--advertise-mode', 'ARP')

    $overridePath = Join-Path $LogDirectory "$targetCluster-local-values.json"
    $localAnnotations = @{
        'metallb.universe.tf/address-pool' = 'selenium-grid'
        'metallb.universe.tf/loadBalancerIPs' = $hubIp
    }
    @{
        hub = @{
            serviceAnnotations = $localAnnotations
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $overridePath -Encoding utf8
    Write-DeploymentStatus 'Rendering and validating Selenium Helm configuration'
    Invoke-DeploymentTool helm @('repo', 'add', 'docker-selenium', 'https://www.selenium.dev/docker-selenium', '--force-update')
    Invoke-DeploymentTool helm @('repo', 'update', 'docker-selenium')
    $helmArgs = @('selenium-grid', 'docker-selenium/selenium-grid', '--namespace', $Namespace, '--values', $ValuesFile,
        '--values', $overridePath, '--set-json', "hub.serviceAnnotations=$($localAnnotations | ConvertTo-Json -Compress)")
    if ($chartVersion) { $helmArgs += @('--version', $chartVersion) }
    $rendered = Invoke-DeploymentTool helm (@('template') + $helmArgs) -Capture
    if ($rendered -match 'service\.beta\.kubernetes\.io/azure-load-balancer') { throw 'Rendered chart still contains Azure cloud load-balancer annotations.' }
    Write-DeploymentStatus 'Installing or upgrading Selenium Grid'
    Invoke-DeploymentTool helm (@('upgrade', '--install') + $helmArgs + @('--kubeconfig', $script:DeploymentKubeconfig, '--create-namespace', '--timeout', '10m'))
    Invoke-DeploymentKubectl @('rollout', 'status', 'deployment/selenium-grid-selenium-hub', '-n', $Namespace, '--timeout=600s')
    Wait-DeploymentCondition 'Grid ready with two registered nodes per browser' {
        $statusText = Invoke-DeploymentKubectl @('exec', '-n', $Namespace, 'deploy/selenium-grid-selenium-hub', '--', 'curl', '--fail', '--silent', '--show-error', 'http://localhost:4444/status') -Capture
        $status = $statusText | ConvertFrom-Json -Depth 50
        if (-not $status.value.ready) { return $false }
        foreach ($browser in @('chrome', 'firefox', 'MicrosoftEdge')) {
            $registered = @($status.value.nodes | Where-Object {
                $_.availability -eq 'UP' -and $browser -in $_.slots.stereotype.browserName
            })
            Write-DeploymentStatus "Registered $browser nodes: $($registered.Count)/2"
            if ($registered.Count -lt 2) { return $false }
        }
        return $true
    } 10
    Wait-DeploymentCondition 'Selenium load-balancer IP assignment' {
        $service = Invoke-DeploymentKubectl @('get', 'svc', 'selenium-grid-selenium-hub', '-n', $Namespace, '-o', 'json') -Capture | ConvertFrom-Json
        return $hubIp -in $service.status.loadBalancer.ingress.ip
    } 10
    Invoke-DeploymentKubectl @('get', 'pods,svc', '-n', $Namespace, '-o', 'wide')
    Write-DeploymentStatus 'Deployment succeeded'
    Write-Host "Grid console: http://${hubIp}:4444/ui/`nWebDriver: http://${hubIp}:4444/wd/hub`nKubeconfig (sensitive): $script:DeploymentKubeconfig" -ForegroundColor Green
    Write-Host 'The IP is assigned; client routing/firewall reachability has not been tested. Configure local DNS separately if desired.'
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $transcriptStarted = $false
    try {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        $LogDirectory = (Resolve-Path -LiteralPath $LogDirectory).Path
        $logPath = Join-Path $LogDirectory "deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N')).log"
        Start-Transcript -Path $logPath | Out-Null
        $transcriptStarted = $true
        Write-DeploymentStatus "Azure Local Selenium deployment. Transcript: $logPath"
        Invoke-AzureLocalDeployment
    } catch {
        $deploymentError = $_
        Write-Host ($deploymentError | Format-List * -Force | Out-String) -ForegroundColor Red
        Write-Host "Stack trace: $($deploymentError.ScriptStackTrace)" -ForegroundColor Red
        Write-Warning 'Deployment stopped. Resources are retained for diagnosis; rerun after resolving the error.'
        if ($script:DeploymentClusterAvailable) {
            try { Invoke-DeploymentAz (@('aksarc', 'show') + $script:DeploymentClusterArgs) -Json | ConvertTo-Json -Depth 50 | Out-Host } catch { Write-Warning "Azure diagnostics failed: $_" }
        }
        if ($script:DeploymentKubernetesAvailable) {
            foreach ($diagnosticArgs in @(
                @('get', 'pods,svc', '-n', $Namespace, '-o', 'wide'),
                @('get', 'events', '-n', $Namespace, '--sort-by=.lastTimestamp'),
                @('describe', 'pods', '-n', $Namespace),
                @('logs', '-n', $Namespace, 'deploy/selenium-grid-selenium-hub', '--all-containers=true', '--tail=100')
            )) {
                try { Invoke-DeploymentKubectl $diagnosticArgs } catch { Write-Warning "Kubernetes diagnostics failed: $_" }
            }
        }
        throw $deploymentError
    } finally {
        if ($transcriptStarted) { Stop-Transcript | Out-Null; Write-Host "Deployment log: $logPath" }
    }
}