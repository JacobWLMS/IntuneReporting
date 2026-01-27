// ============================================================================
// Intune Analytics Platform - ADX Backend
// ============================================================================
// This template deploys an Azure Function App with connection string auth
// for deployment storage (simpler setup, no role assignments needed).
// ============================================================================

@description('Base name for all resources (max 11 characters, will be appended with unique suffix)')
@maxLength(11)
param baseName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Azure Data Explorer cluster URI (e.g., https://mycluster.uksouth.kusto.windows.net)')
param adxClusterUri string = ''

@description('Azure Data Explorer database name')
param adxDatabaseName string = 'IntuneAnalytics'

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var storageAccountName = toLower('${take(baseName, 11)}${take(uniqueSuffix, 13)}')
var functionAppName = '${baseName}-func-${uniqueSuffix}'
var appServicePlanName = '${baseName}-asp-${uniqueSuffix}'
var managedIdentityName = '${baseName}-mi-${uniqueSuffix}'

// ============================================================================
// User-Assigned Managed Identity (for Graph API access)
// ============================================================================

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
}

// ============================================================================
// Storage Account
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    defaultToOAuthAuthentication: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deploymentpackage'
  properties: {
    publicAccess: 'None'
  }
}

// ============================================================================
// App Service Plan (Flex Consumption)
// ============================================================================

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

// ============================================================================
// Function App
// ============================================================================

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}deploymentpackage'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
    siteConfig: {
      appSettings: [
        // Deployment storage connection string
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        // AzureWebJobsStorage connection string
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        // Function runtime settings
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        // Analytics backend configuration
        {
          name: 'ANALYTICS_BACKEND'
          value: 'ADX'
        }
        {
          name: 'ADX_CLUSTER_URI'
          value: adxClusterUri
        }
        {
          name: 'ADX_DATABASE'
          value: adxDatabaseName
        }
        {
          name: 'TENANT_ID'
          value: subscription().tenantId
        }
        // Managed Identity client ID for Graph API calls
        {
          name: 'AZURE_CLIENT_ID'
          value: managedIdentity.properties.clientId
        }
      ]
    }
  }
}

// ============================================================================
// One Deploy: Deploy function code from GitHub release
// ============================================================================

resource oneDeploy 'Microsoft.Web/sites/extensions@2024-04-01' = {
  parent: functionApp
  name: 'onedeploy'
  properties: {
    packageUri: 'https://github.com/JacobWLMS/IntuneReporting/releases/download/latest/released-package.zip'
    type: 'zip'
  }
}

// ============================================================================
// Outputs
// ============================================================================

output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output managedIdentityObjectId string = managedIdentity.properties.principalId
output managedIdentityClientId string = managedIdentity.properties.clientId
output storageAccountName string = storageAccount.name

output nextStep string = 'IMPORTANT: Run scripts/Grant-GraphPermissions.ps1 to grant Microsoft Graph API permissions to the Managed Identity. This requires the Application Administrator role in Entra ID.'
output grantPermissionsCommand string = '.\\scripts\\Grant-GraphPermissions.ps1 -ManagedIdentityObjectId "${managedIdentity.properties.principalId}"'
