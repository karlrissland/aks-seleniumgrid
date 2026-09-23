@description('Private DNS zone name (e.g. dev.lab).')
param zoneName string

@description('Record (host) name under the zone (e.g. seleniumgrid).')
param recordName string

@description('Target IPv4 address for the A record (the pinned hub internal LB IP).')
param targetIp string

@description('Resource ID of the VNet to link the zone to for resolution.')
param virtualNetworkId string

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: zoneName
  location: 'global'
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'link-${uniqueString(virtualNetworkId)}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}

resource aRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: zone
  name: recordName
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: targetIp
      }
    ]
  }
}

output fqdn string = '${recordName}.${zoneName}'
