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
    ]
    source: {
      script: '''
param(
    [string]$ClusterName,
    [string]$ResourceGroupName,
    [string]$IdentityClientId
)

$ErrorActionPreference = 'Continue'
Start-Transcript -Path 'C:\Windows\Temp\jumpbox-bootstrap.log' -Append

# winget runs from the SYSTEM context here, so resolve its full path under WindowsApps.
$winget = (Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe' -ErrorAction SilentlyContinue |
    Sort-Object FullName | Select-Object -Last 1).FullName

function Install-Pkg([string]$id) {
    if (-not $winget) { Write-Host "winget not found; cannot install $id"; return }
    Write-Host "Installing $id ..."
    & $winget install --id $id --scope machine --silent --accept-source-agreements --accept-package-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        # Some packages don't support machine scope; retry with the default scope.
        & $winget install --id $id --silent --accept-source-agreements --accept-package-agreements --disable-interactivity
    }
}

foreach ($id in 'Microsoft.AzureCLI', 'Kubernetes.kubectl', 'Helm.Helm', 'Python.Python.3.12', 'Git.Git', 'Microsoft.OpenJDK.21', 'OpenJS.NodeJS.LTS') {
    Install-Pkg $id
}

# Refresh PATH from the registry so the freshly installed tools resolve in this session.
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

Stop-Transcript
'''
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output principalId string = !empty(userAssignedIdentityId) ? '' : vm.identity.principalId
