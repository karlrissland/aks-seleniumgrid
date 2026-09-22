@description('Azure Region for all resources')
param location string

@description('Azure Bastion Host Name')
param bastionHostName string = 'bas-selenium-grid'

@description('Resource ID of the Virtual Network the Bastion Developer host attaches to')
param virtualNetworkId string

// Developer SKU Bastion: no public IP and no AzureBastionSubnet required.
// It attaches directly to the VNet and provides browser-based SSH/RDP.
resource bastionHost 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: bastionHostName
  location: location
  sku: {
    name: 'Developer'
  }
  properties: {
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}

output bastionHostId string = bastionHost.id
output bastionHostName string = bastionHost.name
