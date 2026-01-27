// ============================================================================
// Intune Analytics Platform - ADX Backend with Managed Identity
// ============================================================================
// This template deploys an Azure Function App that uses a User-Assigned 
// Managed Identity for storage authentication instead of connection strings.
// This is the recommended security practice for Azure Functions.
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

@description('Create role assignments (requires Owner or User Access Administrator role). Set to false if you lack permissions - you can grant roles manually after deployment.')
param createRoleAssignments bool = true

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var storageAccountName = toLower('${take(baseName, 11)}${take(uniqueSuffix, 13)}')
var functionAppName = '${baseName}-func-${uniqueSuffix}'
var appServicePlanName = '${baseName}-asp-${uniqueSuffix}'
var managedIdentityName = '${baseName}-mi-${uniqueSuffix}'

// Storage Blob Data Owner role definition ID
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

// ============================================================================
// User-Assigned Managed Identity
// ============================================================================

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
}

// ============================================================================
// Storage Account (with shared key access disabled)
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
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
    allowSharedKeyAccess: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// ============================================================================
// Role Assignment: Managed Identity -> Storage Blob Data Owner
// (Conditional - requires Owner or User Access Administrator role)
// ============================================================================

resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (createRoleAssignments) {
  name: guid(storageAccount.id, managedIdentity.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
  }
}

// ============================================================================
// App Service Plan (Consumption/Serverless)
// ============================================================================

resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

// ============================================================================
// Function App with User-Assigned Managed Identity
// ============================================================================

resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
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
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      appSettings: [
        // Identity-based storage connection
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: managedIdentity.properties.clientId
        }
        // Function runtime settings
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
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
        // Deploy from GitHub releases
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: 'https://github.com/JacobWLMS/IntuneReporting/releases/latest/download/function-app.zip'
        }
      ]
    }
  }
  dependsOn: [
    storageRoleAssignment
  ]
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
