targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment; used to name the resource group and tag resources.')
param environmentName string

@minLength(1)
@description('Primary Azure region for deploying all resources.')
param location string

@description('Admin password for the Jumpbox VM.')
@secure()
param adminPassword string

@description('VM Size for the AKS worker nodes (4 vCPU / 16GB RAM recommended for multi-browser Selenium nodes).')
param aksNodeVmSize string = 'Standard_D4s_v5'

@description('Number of worker nodes in the AKS cluster.')
param aksNodeCount int = 2

@description('VM Size for the Jumpbox.')
param jumpboxVmSize string = 'Standard_D2s_v5'

@description('Admin username for the Jumpbox and AKS Linux nodes.')
param adminUsername string = 'azureuser'

@description('Deploy AKS in private cluster mode.')
param enablePrivateAksCluster bool = false

var resourcePrefix = 'sel-aks'
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    resourcePrefix: resourcePrefix
    adminPassword: adminPassword
    aksNodeVmSize: aksNodeVmSize
    aksNodeCount: aksNodeCount
    jumpboxVmSize: jumpboxVmSize
    adminUsername: adminUsername
    enablePrivateAksCluster: enablePrivateAksCluster
    tags: tags
  }
}

// Outputs are captured by azd into the environment and exposed as
// environment variables to hooks (e.g. the postprovision Selenium Grid install).
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AKS_CLUSTER_NAME string = resources.outputs.aksClusterName
output JUMPBOX_VM_NAME string = resources.outputs.jumpboxVmName
output JUMPBOX_PRIVATE_IP string = resources.outputs.jumpboxPrivateIp
output JUMPBOX_VM_ID string = resources.outputs.jumpboxVmId
output BASTION_HOST_NAME string = resources.outputs.bastionHostName
output ADMIN_USERNAME string = adminUsername
