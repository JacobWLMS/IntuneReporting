// ============================================================================
// Intune Analytics Platform - Log Analytics Backend with Managed Identity
// ============================================================================
// This template deploys an Azure Function App with Log Analytics workspace
// using a User-Assigned Managed Identity for storage authentication.
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

// Role definition IDs
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

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
// ============================================================================

resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, managedIdentity.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
  }
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
    dataCollectionRule
  ]
}

// ============================================================================
// Role Assignment: Managed Identity -> Monitoring Metrics Publisher (DCR)
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

output nextStep string = 'IMPORTANT: Run scripts/Grant-GraphPermissions.ps1 to grant Microsoft Graph API permissions to the Managed Identity. This requires the Application Administrator role in Entra ID.'
output grantPermissionsCommand string = '.\\scripts\\Grant-GraphPermissions.ps1 -ManagedIdentityObjectId "${managedIdentity.properties.principalId}"'
