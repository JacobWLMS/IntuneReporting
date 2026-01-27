// ============================================================================
// Intune Analytics Platform - Log Analytics Backend
// ============================================================================
// This template deploys an Azure Function App with Log Analytics workspace
// using connection string auth for deployment storage.
// ============================================================================

@description('Base name for all resources (max 11 characters, will be appended with unique suffix)')
@maxLength(11)
param baseName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Data retention in days (30 days free, then pay-per-GB)')
@minValue(30)
@maxValue(730)
param retentionDays int = 30

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var storageAccountName = toLower('${take(baseName, 11)}${take(uniqueSuffix, 13)}')
var functionAppName = '${baseName}-func-${uniqueSuffix}'
var appServicePlanName = '${baseName}-asp-${uniqueSuffix}'
var managedIdentityName = '${baseName}-mi-${uniqueSuffix}'
var workspaceName = '${baseName}-law-${uniqueSuffix}'
var dceName = '${baseName}-dce-${uniqueSuffix}'
var dcrName = '${baseName}-dcr-${uniqueSuffix}'

// Role definition ID for Monitoring Metrics Publisher (needed for DCR)
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

// ============================================================================
// User-Assigned Managed Identity (for Graph API and DCR access)
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
// Deployment Script: Copy function app code from GitHub to storage
// ============================================================================

resource deploymentScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${baseName}-deploy-code'
  location: location
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.52.0'
    timeout: 'PT10M'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'STORAGE_ACCOUNT', value: storageAccount.name }
      { name: 'STORAGE_KEY', secureValue: storageAccount.listKeys().keys[0].value }
      { name: 'CONTAINER_NAME', value: 'deploymentpackage' }
      { name: 'ZIP_URL', value: 'https://github.com/JacobWLMS/IntuneReporting/releases/download/latest/released-package.zip' }
    ]
    scriptContent: '''
set -e
echo "Starting deployment script..."
echo "Downloading from GitHub: $ZIP_URL"
curl -L -f -o /tmp/released-package.zip "$ZIP_URL"
echo "Download complete. File size: $(stat -c%s /tmp/released-package.zip) bytes"
echo "Uploading to storage account: $STORAGE_ACCOUNT"
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --container-name "$CONTAINER_NAME" \
  --name "released-package.zip" \
  --file /tmp/released-package.zip \
  --overwrite
echo "Upload complete"
echo "{\"status\": \"success\", \"blobName\": \"released-package.zip\"}" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
  }
  dependsOn: [
    deploymentContainer
  ]
}

// ============================================================================
// Log Analytics Workspace
// ============================================================================

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionDays
  }
}

// ============================================================================
// Custom Tables for Intune Data
// ============================================================================

resource tableDevices 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'IntuneDevices_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'IntuneDevices_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'DeviceId', type: 'string' }
        { name: 'DeviceName', type: 'string' }
        { name: 'UserId', type: 'string' }
        { name: 'UserPrincipalName', type: 'string' }
        { name: 'UserDisplayName', type: 'string' }
        { name: 'OperatingSystem', type: 'string' }
        { name: 'OSVersion', type: 'string' }
        { name: 'ComplianceState', type: 'string' }
        { name: 'ManagementAgent', type: 'string' }
        { name: 'EnrolledDateTime', type: 'datetime' }
        { name: 'LastSyncDateTime', type: 'datetime' }
        { name: 'Model', type: 'string' }
        { name: 'Manufacturer', type: 'string' }
        { name: 'SerialNumber', type: 'string' }
        { name: 'IsEncrypted', type: 'boolean' }
        { name: 'IsSupervised', type: 'boolean' }
        { name: 'AzureADDeviceId', type: 'string' }
        { name: 'IngestionTime', type: 'datetime' }
        { name: 'SourceSystem', type: 'string' }
      ]
    }
  }
}

resource tableCompliancePolicies 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'IntuneCompliancePolicies_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'IntuneCompliancePolicies_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'PolicyId', type: 'string' }
        { name: 'PolicyName', type: 'string' }
        { name: 'Description', type: 'string' }
        { name: 'CreatedDateTime', type: 'datetime' }
        { name: 'LastModifiedDateTime', type: 'datetime' }
        { name: 'PolicyType', type: 'string' }
        { name: 'IngestionTime', type: 'datetime' }
        { name: 'SourceSystem', type: 'string' }
      ]
    }
  }
}

resource tableComplianceStates 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'IntuneComplianceStates_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'IntuneComplianceStates_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'DeviceId', type: 'string' }
        { name: 'DeviceName', type: 'string' }
        { name: 'UserId', type: 'string' }
        { name: 'UserPrincipalName', type: 'string' }
        { name: 'PolicyId', type: 'string' }
        { name: 'PolicyName', type: 'string' }
        { name: 'Status', type: 'string' }
        { name: 'StatusRaw', type: 'int' }
        { name: 'SettingCount', type: 'int' }
        { name: 'FailedSettingCount', type: 'int' }
        { name: 'LastContact', type: 'datetime' }
        { name: 'InGracePeriodCount', type: 'int' }
        { name: 'IngestionTime', type: 'datetime' }
        { name: 'SourceSystem', type: 'string' }
      ]
    }
  }
}

resource tableDeviceScores 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'IntuneDeviceScores_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'IntuneDeviceScores_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'DeviceId', type: 'string' }
        { name: 'DeviceName', type: 'string' }
        { name: 'Model', type: 'string' }
        { name: 'Manufacturer', type: 'string' }
        { name: 'HealthStatus', type: 'string' }
        { name: 'EndpointAnalyticsScore', type: 'real' }
        { name: 'StartupPerformanceScore', type: 'real' }
        { name: 'AppReliabilityScore', type: 'real' }
        { name: 'WorkFromAnywhereScore', type: 'real' }
        { name: 'MeanResourceSpikeTimeScore', type: 'real' }
        { name: 'BatteryHealthScore', type: 'real' }
        { name: 'IngestionTime', type: 'datetime' }
        { name: 'SourceSystem', type: 'string' }
      ]
    }
  }
}

resource tableStartupPerformance 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'IntuneStartupPerformance_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'IntuneStartupPerformance_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'DeviceId', type: 'string' }
        { name: 'StartTime', type: 'datetime' }
        { name: 'CoreBootTimeInMs', type: 'int' }
        { name: 'GroupPolicyBootTimeInMs', type: 'int' }
        { name: 'GroupPolicyLoginTimeInMs', type: 'int' }
        { name: 'CoreLoginTimeInMs', type: 'int' }
        { name: 'TotalBootTimeInMs', type: 'int' }
        { name: 'TotalLoginTimeInMs', type: 'int' }
        { name: 'IsFirstLogin', type: 'boolean' }
        { name: 'IsFeatureUpdate', type: 'boolean' }
        { name: 'OperatingSystemVersion', type: 'string' }
        { name: 'RestartCategory', type: 'string' }
        { name: 'RestartFaultBucket', type: 'string' }
        { name: 'IngestionTime', type: 'datetime' }
        { name: 'SourceSystem', type: 'string' }
      ]
    }
  }
}

resource tableAppReliability 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'IntuneAppReliability_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'IntuneAppReliability_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'AppName', type: 'string' }
        { name: 'AppDisplayName', type: 'string' }
        { name: 'AppPublisher', type: 'string' }
        { name: 'ActiveDeviceCount', type: 'int' }
        { name: 'AppCrashCount', type: 'int' }
        { name: 'AppHangCount', type: 'int' }
        { name: 'MeanTimeToFailureInMinutes', type: 'int' }
        { name: 'AppHealthScore', type: 'real' }
        { name: 'AppHealthStatus', type: 'string' }
        { name: 'IngestionTime', type: 'datetime' }
        { name: 'SourceSystem', type: 'string' }
      ]
    }
  }
}

resource tableSyncState 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'IntuneSyncState_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'IntuneSyncState_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'ExportType', type: 'string' }
        { name: 'RecordCount', type: 'int' }
        { name: 'StartTime', type: 'datetime' }
        { name: 'EndTime', type: 'datetime' }
        { name: 'DurationSeconds', type: 'real' }
        { name: 'Status', type: 'string' }
        { name: 'ErrorMessage', type: 'string' }
        { name: 'IngestionTime', type: 'datetime' }
        { name: 'SourceSystem', type: 'string' }
      ]
    }
  }
}

// ============================================================================
// Data Collection Endpoint
// ============================================================================

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ============================================================================
// Data Collection Rule
// ============================================================================

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  dependsOn: [
    tableDevices
    tableCompliancePolicies
    tableComplianceStates
    tableDeviceScores
    tableStartupPerformance
    tableAppReliability
    tableSyncState
  ]
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    streamDeclarations: {
      'Custom-IntuneDevices_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'DeviceId', type: 'string' }
          { name: 'DeviceName', type: 'string' }
          { name: 'UserId', type: 'string' }
          { name: 'UserPrincipalName', type: 'string' }
          { name: 'UserDisplayName', type: 'string' }
          { name: 'OperatingSystem', type: 'string' }
          { name: 'OSVersion', type: 'string' }
          { name: 'ComplianceState', type: 'string' }
          { name: 'ManagementAgent', type: 'string' }
          { name: 'EnrolledDateTime', type: 'datetime' }
          { name: 'LastSyncDateTime', type: 'datetime' }
          { name: 'Model', type: 'string' }
          { name: 'Manufacturer', type: 'string' }
          { name: 'SerialNumber', type: 'string' }
          { name: 'IsEncrypted', type: 'boolean' }
          { name: 'IsSupervised', type: 'boolean' }
          { name: 'AzureADDeviceId', type: 'string' }
          { name: 'IngestionTime', type: 'datetime' }
          { name: 'SourceSystem', type: 'string' }
        ]
      }
      'Custom-IntuneCompliancePolicies_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'PolicyId', type: 'string' }
          { name: 'PolicyName', type: 'string' }
          { name: 'Description', type: 'string' }
          { name: 'CreatedDateTime', type: 'datetime' }
          { name: 'LastModifiedDateTime', type: 'datetime' }
          { name: 'PolicyType', type: 'string' }
          { name: 'IngestionTime', type: 'datetime' }
          { name: 'SourceSystem', type: 'string' }
        ]
      }
      'Custom-IntuneComplianceStates_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'DeviceId', type: 'string' }
          { name: 'DeviceName', type: 'string' }
          { name: 'UserId', type: 'string' }
          { name: 'UserPrincipalName', type: 'string' }
          { name: 'PolicyId', type: 'string' }
          { name: 'PolicyName', type: 'string' }
          { name: 'Status', type: 'string' }
          { name: 'StatusRaw', type: 'int' }
          { name: 'SettingCount', type: 'int' }
          { name: 'FailedSettingCount', type: 'int' }
          { name: 'LastContact', type: 'datetime' }
          { name: 'InGracePeriodCount', type: 'int' }
          { name: 'IngestionTime', type: 'datetime' }
          { name: 'SourceSystem', type: 'string' }
        ]
      }
      'Custom-IntuneDeviceScores_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'DeviceId', type: 'string' }
          { name: 'DeviceName', type: 'string' }
          { name: 'Model', type: 'string' }
          { name: 'Manufacturer', type: 'string' }
          { name: 'HealthStatus', type: 'string' }
          { name: 'EndpointAnalyticsScore', type: 'real' }
          { name: 'StartupPerformanceScore', type: 'real' }
          { name: 'AppReliabilityScore', type: 'real' }
          { name: 'WorkFromAnywhereScore', type: 'real' }
          { name: 'MeanResourceSpikeTimeScore', type: 'real' }
          { name: 'BatteryHealthScore', type: 'real' }
          { name: 'IngestionTime', type: 'datetime' }
          { name: 'SourceSystem', type: 'string' }
        ]
      }
      'Custom-IntuneStartupPerformance_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'DeviceId', type: 'string' }
          { name: 'StartTime', type: 'datetime' }
          { name: 'CoreBootTimeInMs', type: 'int' }
          { name: 'GroupPolicyBootTimeInMs', type: 'int' }
          { name: 'GroupPolicyLoginTimeInMs', type: 'int' }
          { name: 'CoreLoginTimeInMs', type: 'int' }
          { name: 'TotalBootTimeInMs', type: 'int' }
          { name: 'TotalLoginTimeInMs', type: 'int' }
          { name: 'IsFirstLogin', type: 'boolean' }
          { name: 'IsFeatureUpdate', type: 'boolean' }
          { name: 'OperatingSystemVersion', type: 'string' }
          { name: 'RestartCategory', type: 'string' }
          { name: 'RestartFaultBucket', type: 'string' }
          { name: 'IngestionTime', type: 'datetime' }
          { name: 'SourceSystem', type: 'string' }
        ]
      }
      'Custom-IntuneAppReliability_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'AppName', type: 'string' }
          { name: 'AppDisplayName', type: 'string' }
          { name: 'AppPublisher', type: 'string' }
          { name: 'ActiveDeviceCount', type: 'int' }
          { name: 'AppCrashCount', type: 'int' }
          { name: 'AppHangCount', type: 'int' }
          { name: 'MeanTimeToFailureInMinutes', type: 'int' }
          { name: 'AppHealthScore', type: 'real' }
          { name: 'AppHealthStatus', type: 'string' }
          { name: 'IngestionTime', type: 'datetime' }
          { name: 'SourceSystem', type: 'string' }
        ]
      }
      'Custom-IntuneSyncState_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'ExportType', type: 'string' }
          { name: 'RecordCount', type: 'int' }
          { name: 'StartTime', type: 'datetime' }
          { name: 'EndTime', type: 'datetime' }
          { name: 'DurationSeconds', type: 'real' }
          { name: 'Status', type: 'string' }
          { name: 'ErrorMessage', type: 'string' }
          { name: 'IngestionTime', type: 'datetime' }
          { name: 'SourceSystem', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspace.id
          name: 'workspace'
        }
      ]
    }
    dataFlows: [
      { streams: ['Custom-IntuneDevices_CL'], destinations: ['workspace'], transformKql: 'source', outputStream: 'Custom-IntuneDevices_CL' }
      { streams: ['Custom-IntuneCompliancePolicies_CL'], destinations: ['workspace'], transformKql: 'source', outputStream: 'Custom-IntuneCompliancePolicies_CL' }
      { streams: ['Custom-IntuneComplianceStates_CL'], destinations: ['workspace'], transformKql: 'source', outputStream: 'Custom-IntuneComplianceStates_CL' }
      { streams: ['Custom-IntuneDeviceScores_CL'], destinations: ['workspace'], transformKql: 'source', outputStream: 'Custom-IntuneDeviceScores_CL' }
      { streams: ['Custom-IntuneStartupPerformance_CL'], destinations: ['workspace'], transformKql: 'source', outputStream: 'Custom-IntuneStartupPerformance_CL' }
      { streams: ['Custom-IntuneAppReliability_CL'], destinations: ['workspace'], transformKql: 'source', outputStream: 'Custom-IntuneAppReliability_CL' }
      { streams: ['Custom-IntuneSyncState_CL'], destinations: ['workspace'], transformKql: 'source', outputStream: 'Custom-IntuneSyncState_CL' }
    ]
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
        // Log Analytics backend configuration
        {
          name: 'ANALYTICS_BACKEND'
          value: 'LogAnalytics'
        }
        {
          name: 'LOG_ANALYTICS_DCE'
          value: dataCollectionEndpoint.properties.logsIngestion.endpoint
        }
        {
          name: 'LOG_ANALYTICS_DCR_ID'
          value: dataCollectionRule.properties.immutableId
        }
        {
          name: 'LOG_ANALYTICS_WORKSPACE_ID'
          value: workspace.properties.customerId
        }
        {
          name: 'TENANT_ID'
          value: subscription().tenantId
        }
        // Managed Identity client ID for Graph API and DCR access
        {
          name: 'AZURE_CLIENT_ID'
          value: managedIdentity.properties.clientId
        }
      ]
    }
  }
  dependsOn: [
    deploymentScript
  ]
}

// ============================================================================
// Role Assignment: Managed Identity -> Monitoring Metrics Publisher (DCR)
// This is required for the Function App to write to Log Analytics via DCR
// ============================================================================

resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataCollectionRule.id, managedIdentity.id, monitoringMetricsPublisherRoleId)
  scope: dataCollectionRule
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
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
output logAnalyticsWorkspaceId string = workspace.properties.customerId
output logAnalyticsWorkspaceName string = workspace.name
output dataCollectionEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint

output nextStep string = 'IMPORTANT: Run scripts/Grant-GraphPermissions.ps1 to grant Microsoft Graph API permissions to the Managed Identity.'
output grantPermissionsCommand string = '.\\scripts\\Grant-GraphPermissions.ps1 -ManagedIdentityObjectId "${managedIdentity.properties.principalId}"'
