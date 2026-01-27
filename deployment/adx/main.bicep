// ============================================================================
// Intune Analytics Platform - ADX Backend (Simplified)
// ============================================================================
// Deploys a Function App that exports Intune data to Azure Data Explorer.
// Uses app registration (client secret) for authentication.
// Upload function code manually via Deployment Center after deployment.
// ============================================================================

@description('Base name for all resources (max 11 chars)')
@maxLength(11)
param baseName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Azure Data Explorer cluster URI (e.g., https://mycluster.uksouth.kusto.windows.net)')
param adxClusterUri string

@description('Azure Data Explorer database name')
param adxDatabaseName string = 'IntuneAnalytics'

@description('App Registration - Tenant ID')
param tenantId string = subscription().tenantId

@description('App Registration - Client ID')
param clientId string

@secure()
@description('App Registration - Client Secret')
param clientSecret string

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var functionAppName = '${baseName}-func-${uniqueSuffix}'
var appServicePlanName = '${baseName}-asp-${uniqueSuffix}'
var storageAccountName = toLower('${take(baseName, 11)}${take(uniqueSuffix, 13)}')

// ============================================================================
// Storage Account (required for Flex Consumption timer triggers)
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
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
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    functionAppConfig: {
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        // Analytics backend
        { name: 'ANALYTICS_BACKEND', value: 'ADX' }
        { name: 'ADX_CLUSTER_URI', value: adxClusterUri }
        { name: 'ADX_DATABASE', value: adxDatabaseName }
        // App registration credentials
        { name: 'AZURE_TENANT_ID', value: tenantId }
        { name: 'AZURE_CLIENT_ID', value: clientId }
        { name: 'AZURE_CLIENT_SECRET', value: clientSecret }
      ]
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output deploymentCenterUrl string = 'https://portal.azure.com/#@${tenantId}/resource${functionApp.id}/vstscd'

output nextSteps string = '''
1. Grant Graph API permissions to your app registration:
   - DeviceManagementManagedDevices.Read.All
   - DeviceManagementConfiguration.Read.All
2. Grant your app registration "Ingestor" role on the ADX database
3. Upload function code via Deployment Center (ZIP deploy)
'''
