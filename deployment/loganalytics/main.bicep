// ============================================================================
// Intune Analytics Platform - Log Analytics Backend (Simplified)
// ============================================================================
// Deploys a Function App that exports Intune data to Log Analytics.
// Uses app registration (client secret) for authentication.
// Upload function code manually via Deployment Center after deployment.
// ============================================================================

@description('Base name for all resources (max 11 chars)')
@maxLength(11)
param baseName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Data retention in days (30 days minimum)')
@minValue(30)
@maxValue(730)
param retentionDays int = 30

@description('App Registration - Tenant ID')
param tenantId string = subscription().tenantId

@description('App Registration - Client ID')
param clientId string

@secure()
@description('App Registration - Client Secret')
param clientSecret string

@description('App Registration - Object ID (for role assignment)')
param servicePrincipalObjectId string

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var functionAppName = '${baseName}-func-${uniqueSuffix}'
var appServicePlanName = '${baseName}-asp-${uniqueSuffix}'
var storageAccountName = toLower('${take(baseName, 11)}${take(uniqueSuffix, 13)}')
var workspaceName = '${baseName}-law-${uniqueSuffix}'
var dceName = '${baseName}-dce-${uniqueSuffix}'
var dcrName = '${baseName}-dcr-${uniqueSuffix}'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

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
// Log Analytics Workspace
// ============================================================================

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
  }
}

// ============================================================================
// Custom Tables
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
// Data Collection Endpoint & Rule
// ============================================================================

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dceName
  location: location
  properties: {
    networkAcls: { publicNetworkAccess: 'Enabled' }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  dependsOn: [ tableDevices, tableCompliancePolicies, tableComplianceStates, tableDeviceScores, tableStartupPerformance, tableAppReliability, tableSyncState ]
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-IntuneDevices_CL': { columns: [ { name: 'TimeGenerated', type: 'datetime' }, { name: 'DeviceId', type: 'string' }, { name: 'DeviceName', type: 'string' }, { name: 'UserId', type: 'string' }, { name: 'UserPrincipalName', type: 'string' }, { name: 'UserDisplayName', type: 'string' }, { name: 'OperatingSystem', type: 'string' }, { name: 'OSVersion', type: 'string' }, { name: 'ComplianceState', type: 'string' }, { name: 'ManagementAgent', type: 'string' }, { name: 'EnrolledDateTime', type: 'datetime' }, { name: 'LastSyncDateTime', type: 'datetime' }, { name: 'Model', type: 'string' }, { name: 'Manufacturer', type: 'string' }, { name: 'SerialNumber', type: 'string' }, { name: 'IsEncrypted', type: 'boolean' }, { name: 'IsSupervised', type: 'boolean' }, { name: 'AzureADDeviceId', type: 'string' }, { name: 'IngestionTime', type: 'datetime' }, { name: 'SourceSystem', type: 'string' } ] }
      'Custom-IntuneCompliancePolicies_CL': { columns: [ { name: 'TimeGenerated', type: 'datetime' }, { name: 'PolicyId', type: 'string' }, { name: 'PolicyName', type: 'string' }, { name: 'Description', type: 'string' }, { name: 'CreatedDateTime', type: 'datetime' }, { name: 'LastModifiedDateTime', type: 'datetime' }, { name: 'PolicyType', type: 'string' }, { name: 'IngestionTime', type: 'datetime' }, { name: 'SourceSystem', type: 'string' } ] }
      'Custom-IntuneComplianceStates_CL': { columns: [ { name: 'TimeGenerated', type: 'datetime' }, { name: 'DeviceId', type: 'string' }, { name: 'DeviceName', type: 'string' }, { name: 'UserId', type: 'string' }, { name: 'UserPrincipalName', type: 'string' }, { name: 'PolicyId', type: 'string' }, { name: 'PolicyName', type: 'string' }, { name: 'Status', type: 'string' }, { name: 'StatusRaw', type: 'int' }, { name: 'SettingCount', type: 'int' }, { name: 'FailedSettingCount', type: 'int' }, { name: 'LastContact', type: 'datetime' }, { name: 'InGracePeriodCount', type: 'int' }, { name: 'IngestionTime', type: 'datetime' }, { name: 'SourceSystem', type: 'string' } ] }
      'Custom-IntuneDeviceScores_CL': { columns: [ { name: 'TimeGenerated', type: 'datetime' }, { name: 'DeviceId', type: 'string' }, { name: 'DeviceName', type: 'string' }, { name: 'Model', type: 'string' }, { name: 'Manufacturer', type: 'string' }, { name: 'HealthStatus', type: 'string' }, { name: 'EndpointAnalyticsScore', type: 'real' }, { name: 'StartupPerformanceScore', type: 'real' }, { name: 'AppReliabilityScore', type: 'real' }, { name: 'WorkFromAnywhereScore', type: 'real' }, { name: 'MeanResourceSpikeTimeScore', type: 'real' }, { name: 'BatteryHealthScore', type: 'real' }, { name: 'IngestionTime', type: 'datetime' }, { name: 'SourceSystem', type: 'string' } ] }
      'Custom-IntuneStartupPerformance_CL': { columns: [ { name: 'TimeGenerated', type: 'datetime' }, { name: 'DeviceId', type: 'string' }, { name: 'StartTime', type: 'datetime' }, { name: 'CoreBootTimeInMs', type: 'int' }, { name: 'GroupPolicyBootTimeInMs', type: 'int' }, { name: 'GroupPolicyLoginTimeInMs', type: 'int' }, { name: 'CoreLoginTimeInMs', type: 'int' }, { name: 'TotalBootTimeInMs', type: 'int' }, { name: 'TotalLoginTimeInMs', type: 'int' }, { name: 'IsFirstLogin', type: 'boolean' }, { name: 'IsFeatureUpdate', type: 'boolean' }, { name: 'OperatingSystemVersion', type: 'string' }, { name: 'RestartCategory', type: 'string' }, { name: 'RestartFaultBucket', type: 'string' }, { name: 'IngestionTime', type: 'datetime' }, { name: 'SourceSystem', type: 'string' } ] }
      'Custom-IntuneAppReliability_CL': { columns: [ { name: 'TimeGenerated', type: 'datetime' }, { name: 'AppName', type: 'string' }, { name: 'AppDisplayName', type: 'string' }, { name: 'AppPublisher', type: 'string' }, { name: 'ActiveDeviceCount', type: 'int' }, { name: 'AppCrashCount', type: 'int' }, { name: 'AppHangCount', type: 'int' }, { name: 'MeanTimeToFailureInMinutes', type: 'int' }, { name: 'AppHealthScore', type: 'real' }, { name: 'AppHealthStatus', type: 'string' }, { name: 'IngestionTime', type: 'datetime' }, { name: 'SourceSystem', type: 'string' } ] }
      'Custom-IntuneSyncState_CL': { columns: [ { name: 'TimeGenerated', type: 'datetime' }, { name: 'ExportType', type: 'string' }, { name: 'RecordCount', type: 'int' }, { name: 'StartTime', type: 'datetime' }, { name: 'EndTime', type: 'datetime' }, { name: 'DurationSeconds', type: 'real' }, { name: 'Status', type: 'string' }, { name: 'ErrorMessage', type: 'string' }, { name: 'IngestionTime', type: 'datetime' }, { name: 'SourceSystem', type: 'string' } ] }
    }
    destinations: {
      logAnalytics: [ { workspaceResourceId: workspace.id, name: 'workspace' } ]
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
// Role Assignment: App Registration -> Monitoring Metrics Publisher (DCR)
// ============================================================================

resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, servicePrincipalObjectId, monitoringMetricsPublisherRoleId)
  scope: dcr
  properties: {
    principalId: servicePrincipalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
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
        { name: 'ANALYTICS_BACKEND', value: 'LogAnalytics' }
        { name: 'LOG_ANALYTICS_DCE', value: dce.properties.logsIngestion.endpoint }
        { name: 'LOG_ANALYTICS_DCR_ID', value: dcr.properties.immutableId }
        { name: 'LOG_ANALYTICS_WORKSPACE_ID', value: workspace.properties.customerId }
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
output workspaceName string = workspace.name
output workspaceId string = workspace.properties.customerId
output dceEndpoint string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId

output nextSteps string = '''
1. Grant Graph API permissions to your app registration:
   - DeviceManagementManagedDevices.Read.All
   - DeviceManagementConfiguration.Read.All
2. Upload function code via Deployment Center (ZIP deploy)
'''
