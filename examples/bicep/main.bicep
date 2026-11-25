// Primed Hardened Runner (Ubuntu) - one runner VM, registered at first boot by cloud-init.
// Same VM settings as docs/QUICKSTART.md Step 2 and the same registration as Steps R1 to R4(a).
// The registration credential never passes through this template: you put it in the vault
// yourself between the two deployments (see ../README.md).

@description('Marketplace image version. An exact version matches one release\'s published evidence; latest follows new releases.')
param imageVersion string = '1.0.4'

@description('The Azure region to deploy in.')
param location string = resourceGroup().location

param vmName string = 'runner-01'

@description('The size the image is built and tested on.')
param vmSize string = 'Standard_D4ads_v7'

param adminUsername string = 'azureuser'

@description('An SSH public key. Azure requires one. The image firewall allows SSH (Ubuntu 1.0.3 and earlier: it does not); your network decides who can reach it.')
param adminSshPublicKey string

@description('Globally unique, 3-24 characters, a-z 0-9 -. Holds only this runner registration credential.')
param keyVaultName string

param secretName string = 'runner-01-reg'

@description('Object ID of whoever will write the credential into the vault: az ad signed-in-user show --query id -o tsv')
param operatorObjectId string

@allowed([
  'github'
  'azdo'
])
param platform string

@description('https://github.com/<owner>[/<repo>] or https://dev.azure.com/<org>')
param url string

@description('GitHub only.')
param labels array = [
  'self-hosted'
  'linux'
  'x64'
  'primed-hardened'
]

@description('Azure DevOps only.')
param pool string = 'Default'

@description('Leave false for the first deployment; set true once the credential is in the vault.')
param deployVm bool = false

@description('Set false and deploy again once the runner is online (QUICKSTART Step R6).')
param attachIdentity bool = true

var readRoleId = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
var writeRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' // Key Vault Secrets Officer

// --- Identity and vault (QUICKSTART Step R1) ---

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'mi-${vmName}'
  location: location
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
  }
}

// The VM's identity may read secrets in this one vault and nothing else.
resource runnerReadsSecret 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, identity.id, readRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// You may write the credential into the vault.
resource operatorWritesSecret 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, operatorObjectId, writeRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', writeRoleId)
    principalId: operatorObjectId
  }
}

// --- Network: no public IP, no inbound rule (QUICKSTART Step 2) ---

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${vmName}'
  location: location
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${vmName}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${vmName}'
  location: location
  properties: {
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// --- Registration config: facts only, no credential (QUICKSTART Steps R3 and R4a) ---

var secretId = '${vault.properties.vaultUri}secrets/${secretName}'
var commonConfig = {
  platform: platform
  url: url
  agent_name: vmName
  token_source: 'vault'
  token_secret_id: secretId
  identity_client_id: identity.properties.clientId
}
var runnerConfig = union(commonConfig, platform == 'github' ? { labels: labels } : { pool: pool })
var cloudInit = '''#cloud-config
write_files:
  - path: /etc/primed/runner-config.json
    permissions: '0600'
    owner: root:root
    encoding: b64
    content: '''

// --- The VM (QUICKSTART Step 2) ---

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = if (deployVm) {
  name: vmName
  location: location
  // The Marketplace purchase plan. Accept the terms once per subscription first:
  //   az vm image terms accept --publisher primed-systems --offer hardened-runners --plan ubuntu-2404
  plan: {
    publisher: 'primed-systems'
    product: 'hardened-runners'
    name: 'ubuntu-2404'
  }
  identity: attachIdentity
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${identity.id}': {}
        }
      }
    : {
        type: 'None'
      }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    // Trusted Launch: the boot configuration the image is built, scanned and tested under.
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'primed-systems'
        offer: 'hardened-runners'
        sku: 'ubuntu-2404'
        version: imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64('${cloudInit}${base64(string(runnerConfig))}\n')
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
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
  dependsOn: [
    runnerReadsSecret
  ]
}

@description('A URL, not a credential.')
output secretId string = secretId
