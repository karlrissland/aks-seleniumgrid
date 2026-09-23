@description('Azure Region for all resources')
param location string

@description('VM Name for the Jumpbox')
param vmName string = 'vm-jumpbox'

@description('Subnet ID where Jumpbox NIC will be connected')
param subnetId string

@description('VM Size')
param vmSize string = 'Standard_D2s_v5'

@description('Administrator username for the VM')
param adminUsername string = 'azureuser'

@description('Administrator password for the VM')
@secure()
param adminPassword string

@description('Managed Identity ID for the Jumpbox VM (optional)')
param userAssignedIdentityId string = ''

@description('Client ID of the Jumpbox managed identity (used to log in and fetch the kubeconfig).')
param identityClientId string = ''

@description('Name of the AKS cluster to configure a machine-wide kubeconfig for.')
param aksClusterName string = ''

@description('Public Git repo URL to clone onto the Jumpbox for the demo.')
param repoUrl string = ''

@description('Private DNS name of the Selenium Grid hub (e.g. seleniumgrid.dev.lab).')
param gridDnsName string = ''

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  identity: !empty(userAssignedIdentityId) ? {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  } : {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      // Windows computer name must be <= 15 characters.
      computerName: 'jumpbox'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-24h2-pro'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 127
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// Bootstrap: install tooling with winget and configure a machine-wide kubeconfig.
resource bootstrap 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  name: 'install-tooling'
  location: location
  properties: {
    asyncExecution: false
    treatFailureAsDeploymentFailure: false
    timeoutInSeconds: 2700
    parameters: [
      { name: 'ClusterName', value: aksClusterName }
      { name: 'ResourceGroupName', value: resourceGroup().name }
      { name: 'IdentityClientId', value: identityClientId }
      { name: 'RepoUrl', value: repoUrl }
      { name: 'GridDnsName', value: gridDnsName }
    ]
    source: {
      script: '''
param(
    [string]$ClusterName,
    [string]$ResourceGroupName,
    [string]$IdentityClientId,
    [string]$RepoUrl,
    [string]$GridDnsName
)

$ErrorActionPreference = 'Continue'
Start-Transcript -Path 'C:\Windows\Temp\jumpbox-bootstrap.log' -Append

# winget does NOT work in the SYSTEM / run-command context (it exits with no
# effect), so Chocolatey is used for reliable headless, machine-wide installs.
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}
$choco = (Get-Command choco -ErrorAction SilentlyContinue).Source
if (-not $choco) { $choco = "$env:ProgramData\chocolatey\bin\choco.exe" }

if (Test-Path $choco) {
    & $choco install -y --no-progress azure-cli kubernetes-cli kubernetes-helm python git nodejs-lts microsoft-openjdk
}

# Refresh PATH so the freshly installed tools resolve in this session.
Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1" -ErrorAction SilentlyContinue
if (Get-Command refreshenv -ErrorAction SilentlyContinue) { refreshenv }
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

$azCmd = (Get-Command az -ErrorAction SilentlyContinue).Source
if (-not $azCmd) { $azCmd = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' }

# Machine-wide kubeconfig fetched via the VM's user-assigned managed identity.
if ($ClusterName -and $ResourceGroupName -and (Test-Path $azCmd)) {
    $kubeDir = 'C:\ProgramData\kube'
    New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null
    $kubeConfig = Join-Path $kubeDir 'config'

    & $azCmd login --identity --username $IdentityClientId | Out-Null

    for ($i = 1; $i -le 5; $i++) {
        & $azCmd aks get-credentials --resource-group $ResourceGroupName --name $ClusterName --admin --file $kubeConfig --overwrite-existing
        if ($LASTEXITCODE -eq 0) { break }
        Write-Host "get-credentials attempt $i failed; retrying in 30s..."
        Start-Sleep -Seconds 30
    }

    # Expose the kubeconfig to every interactive user on the box.
    [Environment]::SetEnvironmentVariable('KUBECONFIG', $kubeConfig, 'Machine')
}

# Install Python test dependencies for the Selenium suite.
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if ($py) {
    & $py -m pip install --upgrade pip pytest selenium pytest-html pytest-xdist allure-pytest requests
}

# Allure CLI (Node-based) for rich test reports; installed machine-wide so the
# interactive user gets it on PATH. Needs Java (Microsoft.OpenJDK, installed above).
$npm = (Get-Command npm -ErrorAction SilentlyContinue).Source
if ($npm) {
    $npmPrefix = 'C:\ProgramData\npm'
    New-Item -ItemType Directory -Path $npmPrefix -Force | Out-Null
    & $npm config set prefix $npmPrefix
    & $npm install -g allure-commandline
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$npmPrefix*") {
        [Environment]::SetEnvironmentVariable('Path', ($machinePath.TrimEnd(';') + ';' + $npmPrefix), 'Machine')
    }
}

# Clone the public demo repo to a machine-wide location.
$repoDir = 'C:\Demo\aks-seleniumgrid'
if ($RepoUrl) {
    New-Item -ItemType Directory -Path 'C:\Demo' -Force | Out-Null
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if (-not $git) { $git = 'C:\Program Files\Git\cmd\git.exe' }
    if (Test-Path $git) {
        if (Test-Path (Join-Path $repoDir '.git')) {
            & $git -C $repoDir pull --ff-only
        } else {
            & $git clone $RepoUrl $repoDir
        }
    }
    # Fallback: download the repo as a zip if git isn't available or the clone failed.
    if (-not (Test-Path (Join-Path $repoDir 'scripts\Run-Demo.ps1'))) {
        try {
            $zipUrl = ($RepoUrl -replace '\.git$', '') + '/archive/refs/heads/main.zip'
            $zip = Join-Path $env:TEMP 'repo.zip'
            Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
            $tmp = Join-Path $env:TEMP 'repoextract'
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
            if ($inner) {
                New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
                Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $repoDir -Recurse -Force
            }
        } catch {
            Write-Host "Repo zip fallback failed: $_"
        }
    }
}

# Desktop shortcuts on the Public Desktop so the interactive user sees them.
$publicDesktop = 'C:\Users\Public\Desktop'
New-Item -ItemType Directory -Path $publicDesktop -Force | Out-Null

if ($GridDnsName) {
    Set-Content -Path (Join-Path $publicDesktop 'Selenium Grid.url') -Encoding ASCII -Value @(
        '[InternetShortcut]',
        ('URL=http://{0}:4444/ui/' -f $GridDnsName)
    )
}

$runDemo = Join-Path $repoDir 'scripts\Run-Demo.ps1'
if (Test-Path $runDemo) {
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut((Join-Path $publicDesktop 'Run Selenium Demo.lnk'))
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = '-NoExit -ExecutionPolicy Bypass -File "' + $runDemo + '" -GridDnsName ' + $GridDnsName
    $lnk.WorkingDirectory = $repoDir
    $lnk.IconLocation = 'powershell.exe,0'
    $lnk.Save()
}

Stop-Transcript
'''
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output principalId string = !empty(userAssignedIdentityId) ? '' : vm.identity.principalId
