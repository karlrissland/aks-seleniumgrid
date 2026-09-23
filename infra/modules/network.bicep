@description('Azure Region for all resources')
param location string

@description('Virtual Network Name')
param vnetName string = 'vnet-aks-selenium'

@description('Address space prefix for the Virtual Network')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet prefix for Azure Bastion (must be /26 or larger, named AzureBastionSubnet)')
param bastionSubnetPrefix string = '10.0.1.0/24'

@description('Subnet prefix for Jumpbox VM')
param jumpboxSubnetPrefix string = '10.0.2.0/24'

@description('Subnet prefix for the GitHub self-hosted runner VM')
param runnerSubnetPrefix string = '10.0.3.0/24'

@description('Subnet prefix for AKS Cluster nodes')
param aksSubnetPrefix string = '10.0.4.0/22'

// NSG for Jumpbox Subnet
resource jumpboxNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-jumpbox'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowBastionInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
          sourceAddressPrefix: bastionSubnetPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowVNetInbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// NSG for GitHub Runner Subnet
resource runnerNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-gh-runner'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowBastionInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: bastionSubnetPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowVNetInbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// NSG for AKS Subnet
resource aksNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-aks'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowVNetInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
    ]
  }
}

// Virtual Network with segmented subnets
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
      {
        name: 'snet-jumpbox'
        properties: {
          addressPrefix: jumpboxSubnetPrefix
          networkSecurityGroup: {
            id: jumpboxNsg.id
          }
        }
      }
      {
        name: 'snet-gh-runner'
        properties: {
          addressPrefix: runnerSubnetPrefix
          networkSecurityGroup: {
            id: runnerNsg.id
          }
        }
      }
      {
        name: 'snet-aks'
        properties: {
          addressPrefix: aksSubnetPrefix
          networkSecurityGroup: {
            id: aksNsg.id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output bastionSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'AzureBastionSubnet')
output jumpboxSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-jumpbox')
output runnerSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-gh-runner')
output aksSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-aks')
