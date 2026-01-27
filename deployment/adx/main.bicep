// ============================================================================
// Intune Analytics Platform - ADX Backend
// ============================================================================
// Deploys a Function App that exports Intune data to Azure Data Explorer.
//
// After deployment:
// 1. Add app registration credentials in Function App > Configuration:
//    - AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET
// 2. Grant Graph API permissions to your app registration
// 3. Upload function code via Deployment Center
// ============================================================================

@description('Base name for all resources (max 11 chars)')
@maxLength(11)
param baseName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Azure Data Explorer cluster URI (e.g., https://mycluster.uksouth.kusto.windows.net)')
param adxClusterUri string = ''

@description('Azure Data Explorer database name')
param adxDatabase string = 'IntuneAnalytics'

// ============================================================================
// Variables
// ============================================================================

var suffix = uniqueString(resourceGroup().id)
var storageName = toLower('${take(baseName, 11)}${take(suffix, 13)}')
var funcName = '${baseName}-func-${suffix}'
var planName = '${baseName}-plan-${suffix}'

// ============================================================================
// Storage Account (required for Function App)
// ============================================================================

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// ============================================================================
// App Service Plan (Flex Consumption)
// ============================================================================

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  kind: 'functionapp'
  properties: { reserved: true }
}

// ============================================================================
// Function App
// ============================================================================

resource func 'Microsoft.Web/sites@2024-04-01' = {
  name: funcName
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
      runtime: { name: 'python', version: '3.11' }
    }
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ANALYTICS_BACKEND', value: 'ADX' }
        { name: 'ADX_CLUSTER_URI', value: adxClusterUri }
        { name: 'ADX_DATABASE', value: adxDatabase }
        // Add these manually in portal after deployment:
        // AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET
      ]
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

output functionAppName string = func.name
output functionAppUrl string = 'https://${func.properties.defaultHostName}'
output storageAccountName string = storage.name

output postDeploymentSteps string = '''
After deployment, complete these steps:

1. Add app registration credentials in Function App > Configuration > Application settings:
   - AZURE_TENANT_ID = your tenant ID
   - AZURE_CLIENT_ID = your app registration client ID
   - AZURE_CLIENT_SECRET = your app registration client secret

2. Grant Graph API permissions to your app registration:
   - DeviceManagementManagedDevices.Read.All
   - DeviceManagementConfiguration.Read.All

3. Grant your app registration "Ingestor" role on the ADX database

4. Upload function code via Deployment Center (ZIP deploy)
'''
