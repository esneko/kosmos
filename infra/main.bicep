metadata description = 'Provisions resources for a web application that uses Azure SDK for Python to connect to Azure Cosmos DB for Table.'

targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name of the environment that can be used as part of naming resource convention.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Id of the principal to assign database and application roles.')
param deploymentUserPrincipalId string = ''

// serviceName is used as value for the tag (azd-service-name) azd uses to identify deployment host
param serviceName string = 'web'

var resourceToken = toLower(uniqueString(resourceGroup().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
  repo: 'https://github.com/azure-samples/cosmos-db-table-python-quickstart'
}

var tableName = 'cosmicworks-products'

module keyVault 'br/public:avm/res/key-vault/vault:0.10.2' = {
  name: 'key-vault'
  params: {
    name: 'key-vault-${resourceToken}'
    location: location
    sku: 'standard'
    enablePurgeProtection: false
    enableSoftDelete: false
    publicNetworkAccess: 'Enabled'
    enableRbacAuthorization: true
    secrets: [
      {
        name: 'key-vault-secret-azure-cosmos-db-table-key'
        value: ''
      }
    ]
  }
}

module cosmosDbAccount 'br/public:avm/res/document-db/database-account:0.8.1' = {
  name: 'cosmos-db-account'
  params: {
    name: 'cosmos-db-table-${resourceToken}'
    location: location
    locations: [
      {
        failoverPriority: 0
        locationName: location
        isZoneRedundant: false
      }
    ]
    tags: tags
    disableKeyBasedMetadataWriteAccess: false
    disableLocalAuth: false
    networkRestrictions: {
      publicNetworkAccess: 'Enabled'
      ipRules: []
      virtualNetworkRules: []
    }
    capabilitiesToAdd: [
      'EnableServerless'
      'EnableTable'
    ]
    secretsExportConfiguration: {
      keyVaultResourceId: keyVault.outputs.resourceId
      primaryWriteKeySecretName: 'key-vault-secret-azure-cosmos-db-table-key'
    }
    tables: [
      {
        name: tableName
      }
    ]
  }
}

module containerRegistry 'br/public:avm/res/container-registry/registry:0.5.1' = {
  name: 'container-registry'
  params: {
    name: 'containerreg${resourceToken}'
    location: location
    tags: tags
    acrAdminUserEnabled: false
    anonymousPullEnabled: true
    publicNetworkAccess: 'Enabled'
    acrSku: 'Standard'
  }
}

var containerRegistryRole = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '8311e382-0749-4cb8-b61a-304f252e45ec'
) // AcrPush built-in role

module registryUserAssignment 'br/public:avm/ptn/authorization/resource-role-assignment:0.1.1' = if (!empty(deploymentUserPrincipalId)) {
  name: 'container-registry-role-assignment-push-user'
  params: {
    principalId: deploymentUserPrincipalId
    resourceId: containerRegistry.outputs.resourceId
    roleDefinitionId: containerRegistryRole
  }
}

module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.7.0' = {
  name: 'log-analytics-workspace'
  params: {
    name: 'log-analytics-${resourceToken}'
    location: location
    tags: tags
  }
}

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.8.0' = {
  name: 'container-apps-env'
  params: {
    name: 'container-env-${resourceToken}'
    location: location
    tags: tags
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
    zoneRedundant: false
  }
}

module managedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'user-assigned-identity'
  params: {
    name: 'managed-identity-${resourceToken}'
    location: location
    tags: tags
  }
}

var keyVaultRole = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
) // Key Vault Secrets User built-in role

module keyVaultAppAssignment 'br/public:avm/ptn/authorization/resource-role-assignment:0.1.1' = {
  name: 'key-vault-role-assignment-secrets-user'
  params: {
    principalId: managedIdentity.outputs.principalId
    resourceId: keyVault.outputs.resourceId
    roleDefinitionId: keyVaultRole
  }
}

module containerAppsApp 'br/public:avm/res/app/container-app:0.9.0' = {
  name: 'container-apps-app'
  dependsOn: [
    keyVaultAppAssignment // Need to wait for the role assignment to complete before creating the container app
  ]
  params: {
    name: 'container-app-${resourceToken}'
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': serviceName })
    ingressTargetPort: 8000
    ingressExternal: true
    ingressTransport: 'auto'
    stickySessionsAffinity: 'sticky'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
    corsPolicy: {
      allowCredentials: true
      allowedOrigins: [
        '*'
      ]
    }
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        managedIdentity.outputs.resourceId
      ]
    }
    secrets: {
      secureList: [
        {
          name: 'azure-cosmos-db-table-endpoint'
          value: 'https://${cosmosDbAccount.outputs.name}.table.cosmos.azure.com:443/'
        }
        {
          name: 'azure-cosmos-db-table-account-name'
          value: cosmosDbAccount.outputs.name
        }
        {
          identity: managedIdentity.outputs.resourceId
          name: 'azure-cosmos-db-table-write-key'
          keyVaultUrl: cosmosDbAccount.outputs.exportedSecrets['key-vault-secret-azure-cosmos-db-table-key'].secretUri
        }
      ]
    }
    containers: [
      {
        image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'web-front-end'
        resources: {
          cpu: '0.25'
          memory: '.5Gi'
        }
        env: [
          {
            name: 'CONFIGURATION__AZURECOSMOSDB__ACCOUNTNAME'
            secretRef: 'azure-cosmos-db-table-account-name'
          }
          {
            name: 'CONFIGURATION__AZURECOSMOSDB__ENDPOINT'
            secretRef: 'azure-cosmos-db-table-endpoint'
          }
          {
            name: 'CONFIGURATION__AZURECOSMOSDB__KEY'
            secretRef: 'azure-cosmos-db-table-write-key'
          }
          {
            name: 'CONFIGURATION__AZURECOSMOSDB__TABLENAME'
            value: tableName
          }
        ]
      }
    ]
  }
}

// Azure Cosmos DB for Table outputs
output CONFIGURATION__AZURECOSMOSDB__ACCOUNTNAME string = cosmosDbAccount.outputs.name
output CONFIGURATION__AZURECOSMOSDB__ENDPOINT string = 'https://${cosmosDbAccount.outputs.name}.table.cosmos.azure.com:443/'
#disable-next-line outputs-should-not-contain-secrets // This secret is required
output CONFIGURATION__AZURECOSMOSDB__KEY string = listKeys(
  resourceId('Microsoft.DocumentDB/databaseAccounts', 'cosmos-db-table-${resourceToken}'),
  '2021-04-15'
).primaryMasterKey
output CONFIGURATION__AZURECOSMOSDB__TABLENAME string = tableName

// Azure Container Registry outputs
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
