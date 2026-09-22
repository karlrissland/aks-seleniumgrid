@description('Azure Region for all resources')
param location string

@description('AKS Cluster Name')
param clusterName string = 'aks-selenium'

@description('Subnet ID for the AKS node pool')
param subnetId string

@description('Kubernetes Version (leave empty for default supported version)')
param kubernetesVersion string = ''

@description('VM Size for agent pool nodes')
param nodeVmSize string = 'Standard_D4s_v5'

@description('Node count for the cluster (default 2 as requested)')
param nodeCount int = 2

@description('Admin username for the Linux nodes')
param adminUsername string = 'azureuser'

@description('Optional SSH public key for Linux nodes. When empty, no SSH access is configured on the nodes.')
@secure()
param adminPublicKey string = ''

@description('Enable Private Cluster mode (API server private endpoint in VNet)')
param enablePrivateCluster bool = false

// User-assigned identity for the AKS control plane
resource aksIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${clusterName}'
  location: location
}

// AKS Cluster
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksIdentity.id}': {}
    }
  }
  properties: {
    kubernetesVersion: !empty(kubernetesVersion) ? kubernetesVersion : null
    dnsPrefix: '${clusterName}-dns'
    enableRBAC: true
    apiServerAccessProfile: {
      enablePrivateCluster: enablePrivateCluster
    }
    agentPoolProfiles: [
      {
        name: 'agentpool'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        mode: 'System'
        vnetSubnetID: subnetId
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: false
        maxPods: 60
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'azure'
      serviceCidr: '172.16.0.0/16'
      dnsServiceIP: '172.16.0.10'
      podCidr: '10.244.0.0/16'
      loadBalancerSku: 'standard'
    }
    linuxProfile: !empty(adminPublicKey) ? {
      adminUsername: adminUsername
      ssh: {
        publicKeys: [
          {
            keyData: adminPublicKey
          }
        ]
      }
    } : null
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
  }
}

// Built-in Azure RBAC Role definition IDs
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'

// Assign Network Contributor role to AKS control plane identity on the AKS subnet
resource aksSubnetNetworkContribRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksCluster.id, aksIdentity.id, networkContributorRoleId)
  scope: resourceGroup()
  properties: {
    principalId: aksIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

output clusterId string = aksCluster.id
output clusterName string = aksCluster.name
output aksIdentityPrincipalId string = aksIdentity.properties.principalId
output aksControlPlaneFqdn string = aksCluster.properties.fqdn
output oidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL
