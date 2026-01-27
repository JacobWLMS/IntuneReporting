// ============================================================================
// Intune Analytics Platform - Log Analytics Backend
// ============================================================================
// Deploys a Function App that exports Intune data to Log Analytics.
//
// After deployment:
// 1. Add app registration credentials in Function App > Configuration
// 2. Grant "Monitoring Metrics Publisher" role on the DCR to your app
// 3. Grant Graph API permissions to your app registration
// 4. Upload function code via Deployment Center
// ============================================================================

@description('Base name for all resources (max 11 chars)')
@maxLength(11)
param baseName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Data retention in days (30 minimum)')
@minValue(30)
@maxValue(730)
param retentionDays int = 30

// ============================================================================
// Variables
// ============================================================================

var suffix = uniqueString(resourceGroup().id)
var storageName = toLower('${take(baseName, 11)}${take(suffix, 13)}')
var funcName = '${baseName}-func-${suffix}'
var planName = '${baseName}-plan-${suffix}'
var workspaceName = '${baseName}-law-${suffix}'
var dceName = '${baseName}-dce-${suffix}'
var dcrName = '${baseName}-dcr-${suffix}'

// ============================================================================
// Storage Account
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
// Log Analytics Workspace & Custom Tables
// ============================================================================

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
  }
}

var tableSchemas = {
  IntuneDevices_CL: [
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
  IntuneCompliancePolicies_CL: [
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
  IntuneComplianceStates_CL: [
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
  IntuneDeviceScores_CL: [
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
  IntuneStartupPerformance_CL: [
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
  IntuneAppReliability_CL: [
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
  IntuneSyncState_CL: [
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

resource tables 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = [for table in items(tableSchemas): {
  parent: workspace
  name: table.key
  properties: {
    plan: 'Analytics'
    schema: { name: table.key, columns: table.value }
  }
}]

// ============================================================================
// Data Collection Endpoint & Rule
// ============================================================================

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dceName
  location: location
  properties: { networkAcls: { publicNetworkAccess: 'Enabled' } }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  dependsOn: [tables]
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-IntuneDevices_CL': { columns: tableSchemas.IntuneDevices_CL }
      'Custom-IntuneCompliancePolicies_CL': { columns: tableSchemas.IntuneCompliancePolicies_CL }
      'Custom-IntuneComplianceStates_CL': { columns: tableSchemas.IntuneComplianceStates_CL }
      'Custom-IntuneDeviceScores_CL': { columns: tableSchemas.IntuneDeviceScores_CL }
      'Custom-IntuneStartupPerformance_CL': { columns: tableSchemas.IntuneStartupPerformance_CL }
      'Custom-IntuneAppReliability_CL': { columns: tableSchemas.IntuneAppReliability_CL }
      'Custom-IntuneSyncState_CL': { columns: tableSchemas.IntuneSyncState_CL }
    }
    destinations: {
      logAnalytics: [{ workspaceResourceId: workspace.id, name: 'workspace' }]
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
// App Service Plan & Function App
// ============================================================================

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  kind: 'functionapp'
  properties: { reserved: true }
}

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
        { name: 'ANALYTICS_BACKEND', value: 'LogAnalytics' }
        { name: 'LOG_ANALYTICS_DCE', value: dce.properties.logsIngestion.endpoint }
        { name: 'LOG_ANALYTICS_DCR_ID', value: dcr.properties.immutableId }
        { name: 'LOG_ANALYTICS_WORKSPACE_ID', value: workspace.properties.customerId }
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
output workspaceName string = workspace.name
output workspaceId string = workspace.properties.customerId
output dcrName string = dcr.name
output dcrId string = dcr.id

output postDeploymentSteps string = '''
After deployment, complete these steps:

1. Add app registration credentials in Function App > Configuration > Application settings:
   - AZURE_TENANT_ID = your tenant ID
   - AZURE_CLIENT_ID = your app registration client ID
   - AZURE_CLIENT_SECRET = your app registration client secret

2. Grant "Monitoring Metrics Publisher" role to your app registration on the DCR:
   - Go to the Data Collection Rule > Access control (IAM)
   - Add role assignment > Monitoring Metrics Publisher
   - Select your app registration

3. Grant Graph API permissions to your app registration:
   - DeviceManagementManagedDevices.Read.All
   - DeviceManagementConfiguration.Read.All

4. Upload function code via Deployment Center (ZIP deploy)
'''
