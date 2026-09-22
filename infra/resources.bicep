targetScope = 'resourceGroup'

@description('The Azure region for deploying all resources.')
param location string = resourceGroup().location

@description('Environment or workload prefix for resource naming.')
param resourcePrefix string = 'sel-aks'

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

@description('Tags applied to all resources.')
param tags object = {}

// User-assigned managed identity for the Jumpbox VM
resource jumpboxIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${resourcePrefix}-jumpbox'
  location: location
  tags: tags
}

// Network Module (VNet, Subnets, NSGs)
module network 'modules/network.bicep' = {
  name: 'deploy-network'
  params: {
    location: location
    vnetName: 'vnet-${resourcePrefix}'
    vnetAddressPrefix: '10.0.0.0/16'
    bastionSubnetPrefix: '10.0.1.0/24'
    jumpboxSubnetPrefix: '10.0.2.0/24'
    aksSubnetPrefix: '10.0.4.0/22'
  }
}

// Azure Bastion Module (Developer SKU: no public IP, attaches to the VNet)
module bastion 'modules/bastion.bicep' = {
  name: 'deploy-bastion'
  params: {
    location: location
    bastionHostName: 'bas-${resourcePrefix}'
    virtualNetworkId: network.outputs.vnetId
  }
}

// AKS Cluster Module (2 nodes)
module aks 'modules/aks.bicep' = {
  name: 'deploy-aks'
  params: {
    location: location
    clusterName: 'aks-${resourcePrefix}'
    subnetId: network.outputs.aksSubnetId
    nodeVmSize: aksNodeVmSize
    nodeCount: aksNodeCount
    adminUsername: adminUsername
    enablePrivateCluster: enablePrivateAksCluster
  }
}

// Jumpbox VM Module
module jumpbox 'modules/jumpbox.bicep' = {
  name: 'deploy-jumpbox'
  params: {
    location: location
    vmName: 'vm-${resourcePrefix}-jumpbox'
    subnetId: network.outputs.jumpboxSubnetId
    vmSize: jumpboxVmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    userAssignedIdentityId: jumpboxIdentity.id
    identityClientId: jumpboxIdentity.properties.clientId
    aksClusterName: aks.outputs.clusterName
  }
  // Ensure the identity has AKS admin rights before the bootstrap fetches kubeconfig.
  dependsOn: [
    jumpboxAksAdminRole
  ]
}

// Azure RBAC: Azure Kubernetes Service Cluster Admin Role definition ID
var aksClusterAdminRoleId = '0ab0b1a8-8aac-4efd-b8c2-3ee1fb270be8'
// Azure Kubernetes Service Contributor Role
var aksContributorRoleId = 'ed7f3fbd-7b88-4dd4-9017-9adb7ce333f8'

// Assign AKS permissions to Jumpbox Identity
resource jumpboxAksAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, resourcePrefix, jumpboxIdentity.id, aksClusterAdminRoleId)
  scope: resourceGroup()
  properties: {
    principalId: jumpboxIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksClusterAdminRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource jumpboxAksContribRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, resourcePrefix, jumpboxIdentity.id, aksContributorRoleId)
  scope: resourceGroup()
  properties: {
    principalId: jumpboxIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

output aksClusterName string = aks.outputs.clusterName
output jumpboxVmName string = jumpbox.outputs.vmName
output jumpboxPrivateIp string = jumpbox.outputs.privateIpAddress
output bastionHostName string = bastion.outputs.bastionHostName
output bastionHostId string = bastion.outputs.bastionHostId
output jumpboxVmId string = jumpbox.outputs.vmId
