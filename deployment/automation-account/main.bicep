// ============================================================================
// Intune Analytics Platform - Full Infrastructure Deployment
// ============================================================================
// Deploys complete infrastructure for Intune data export and analytics:
// - Azure Automation Account with Python 3.10 runbooks
// - Log Analytics Workspace with custom tables (if LogAnalytics backend)
// - Data Collection Endpoint and Rules (if LogAnalytics backend)
// - Azure Data Explorer cluster (optional, if ADX backend)
// - Role assignments for managed identity
//
// POST-DEPLOYMENT: Run Setup-RuntimeEnvironment.ps1 to install Python packages
// ============================================================================

targetScope = 'resourceGroup'

// ============================================================================
// Parameters
// ============================================================================

@description('Base name for all resources (max 11 characters)')
@maxLength(11)
param baseName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Analytics backend: LogAnalytics or ADX')
@allowed(['LogAnalytics', 'ADX'])
param analyticsBackend string = 'LogAnalytics'

@description('Azure AD Tenant ID')
param tenantId string = subscription().tenantId

@description('App Registration Client ID for Microsoft Graph API (leave empty to use Managed Identity)')
param graphClientId string = ''

@description('App Registration Client Secret for Microsoft Graph API')
@secure()
param graphClientSecret string = ''

@description('Create new ADX cluster (only if analyticsBackend = ADX)')
param createAdxCluster bool = false

@description('Existing ADX cluster URI (if not creating new, e.g., https://mycluster.region.kusto.windows.net)')
param existingAdxClusterUri string = ''

@description('ADX database name')
param adxDatabaseName string = 'IntuneAnalytics'

@description('Log Analytics workspace retention in days')
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionDays int = 90

@description('Start time for schedules (ISO 8601 format)')
param scheduleStartTime string = dateTimeAdd(utcNow(), 'PT1H')

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var automationAccountName = '${baseName}-auto-${uniqueSuffix}'
var logAnalyticsWorkspaceName = '${baseName}-law-${uniqueSuffix}'
var dceName = '${baseName}-dce-${uniqueSuffix}'
var dcrName = '${baseName}-dcr-${uniqueSuffix}'
var adxClusterName = '${baseName}adx${uniqueSuffix}'
var runtimeEnvironmentName = 'IntuneExport-Python310'

var runbookBaseUrl = 'https://raw.githubusercontent.com/JacobWLMS/IntuneReporting/main/runbooks'

// Runbook configurations
var runbookConfigs = [
  { name: 'Export-IntuneDevices', file: 'export_devices.py', desc: 'Exports Intune managed device inventory', freq: 'Hour', interval: 4 }
  { name: 'Export-IntuneCompliance', file: 'export_compliance.py', desc: 'Exports compliance policies and states', freq: 'Hour', interval: 6 }
  { name: 'Export-EndpointAnalytics', file: 'export_endpoint_analytics.py', desc: 'Exports Endpoint Analytics data', freq: 'Day', interval: 1 }
  { name: 'Export-Autopilot', file: 'export_autopilot.py', desc: 'Exports Autopilot devices and profiles', freq: 'Day', interval: 1 }
]

// ============================================================================
// Log Analytics Workspace (if LogAnalytics backend)
// ============================================================================

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (analyticsBackend == 'LogAnalytics') {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logAnalyticsRetentionDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ============================================================================
// Custom Tables in Log Analytics (must exist before DCR)
// ============================================================================

var customTables = [
  {
    name: 'IntuneDevices_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'DeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'UserPrincipalName', type: 'string' }
      { name: 'OperatingSystem', type: 'string' }
      { name: 'OSVersion', type: 'string' }
      { name: 'ComplianceState', type: 'string' }
      { name: 'ManagementState', type: 'string' }
      { name: 'Model', type: 'string' }
      { name: 'Manufacturer', type: 'string' }
      { name: 'SerialNumber', type: 'string' }
      { name: 'OwnerType', type: 'string' }
      { name: 'JoinType', type: 'string' }
    ]
  }
  {
    name: 'IntuneCompliance_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'DeviceId', type: 'string' }
      { name: 'PolicyId', type: 'string' }
      { name: 'PolicyName', type: 'string' }
      { name: 'State', type: 'string' }
      { name: 'SettingName', type: 'string' }
    ]
  }
  {
    name: 'IntuneCompliancePolicies_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'PolicyId', type: 'string' }
      { name: 'PolicyName', type: 'string' }
      { name: 'Platform', type: 'string' }
    ]
  }
  {
    name: 'IntuneDeviceScores_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'DeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'EndpointAnalyticsScore', type: 'real' }
      { name: 'StartupPerformanceScore', type: 'real' }
      { name: 'AppReliabilityScore', type: 'real' }
      { name: 'HealthStatus', type: 'string' }
    ]
  }
  {
    name: 'IntuneStartupPerformance_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'DeviceId', type: 'string' }
      { name: 'DeviceName', type: 'string' }
      { name: 'CoreBootTimeInMs', type: 'long' }
      { name: 'TotalBootTimeInMs', type: 'long' }
    ]
  }
  {
    name: 'IntuneAppReliability_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'AppName', type: 'string' }
      { name: 'AppPublisher', type: 'string' }
      { name: 'DeviceCount', type: 'int' }
      { name: 'AppCrashCount', type: 'int' }
    ]
  }
  {
    name: 'IntuneAutopilotDevices_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'Id', type: 'string' }
      { name: 'SerialNumber', type: 'string' }
      { name: 'Model', type: 'string' }
      { name: 'Manufacturer', type: 'string' }
      { name: 'EnrollmentState', type: 'string' }
    ]
  }
  {
    name: 'IntuneAutopilotProfiles_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'ProfileId', type: 'string' }
      { name: 'DisplayName', type: 'string' }
      { name: 'DeviceNameTemplate', type: 'string' }
    ]
  }
  {
    name: 'IntuneSyncState_CL'
    columns: [
      { name: 'TimeGenerated', type: 'datetime' }
      { name: 'DataType', type: 'string' }
      { name: 'RecordCount', type: 'int' }
      { name: 'Status', type: 'string' }
    ]
  }
]

resource customLogTables 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = [for table in customTables: if (analyticsBackend == 'LogAnalytics') {
  parent: logAnalyticsWorkspace
  name: table.name
  properties: {
    schema: {
      name: table.name
      columns: table.columns
    }
    retentionInDays: logAnalyticsRetentionDays
    totalRetentionInDays: logAnalyticsRetentionDays
    plan: 'Analytics'
  }
}]

// ============================================================================
// Data Collection Endpoint (if LogAnalytics backend)
// ============================================================================

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = if (analyticsBackend == 'LogAnalytics') {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ============================================================================
// Data Collection Rule (if LogAnalytics backend)
// ============================================================================

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2022-06-01' = if (analyticsBackend == 'LogAnalytics') {
  name: dcrName
  location: location
  dependsOn: [customLogTables]
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    streamDeclarations: {
      'Custom-IntuneDevices_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'DeviceId', type: 'string' }
          { name: 'DeviceName', type: 'string' }
          { name: 'UserPrincipalName', type: 'string' }
          { name: 'OperatingSystem', type: 'string' }
          { name: 'OSVersion', type: 'string' }
          { name: 'ComplianceState', type: 'string' }
          { name: 'ManagementState', type: 'string' }
          { name: 'Model', type: 'string' }
          { name: 'Manufacturer', type: 'string' }
          { name: 'SerialNumber', type: 'string' }
          { name: 'OwnerType', type: 'string' }
          { name: 'JoinType', type: 'string' }
        ]
      }
      'Custom-IntuneCompliance_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'DeviceId', type: 'string' }
          { name: 'PolicyId', type: 'string' }
          { name: 'PolicyName', type: 'string' }
          { name: 'State', type: 'string' }
          { name: 'SettingName', type: 'string' }
        ]
      }
      'Custom-IntuneCompliancePolicies_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'PolicyId', type: 'string' }
          { name: 'PolicyName', type: 'string' }
          { name: 'Platform', type: 'string' }
        ]
      }
      'Custom-IntuneDeviceScores_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'DeviceId', type: 'string' }
          { name: 'DeviceName', type: 'string' }
          { name: 'EndpointAnalyticsScore', type: 'real' }
          { name: 'StartupPerformanceScore', type: 'real' }
          { name: 'AppReliabilityScore', type: 'real' }
          { name: 'HealthStatus', type: 'string' }
        ]
      }
      'Custom-IntuneStartupPerformance_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'DeviceId', type: 'string' }
          { name: 'DeviceName', type: 'string' }
          { name: 'CoreBootTimeInMs', type: 'long' }
          { name: 'TotalBootTimeInMs', type: 'long' }
        ]
      }
      'Custom-IntuneAppReliability_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'AppName', type: 'string' }
          { name: 'AppPublisher', type: 'string' }
          { name: 'DeviceCount', type: 'int' }
          { name: 'AppCrashCount', type: 'int' }
        ]
      }
      'Custom-IntuneAutopilotDevices_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'Id', type: 'string' }
          { name: 'SerialNumber', type: 'string' }
          { name: 'Model', type: 'string' }
          { name: 'Manufacturer', type: 'string' }
          { name: 'EnrollmentState', type: 'string' }
        ]
      }
      'Custom-IntuneAutopilotProfiles_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'ProfileId', type: 'string' }
          { name: 'DisplayName', type: 'string' }
          { name: 'DeviceNameTemplate', type: 'string' }
        ]
      }
      'Custom-IntuneSyncState_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'DataType', type: 'string' }
          { name: 'RecordCount', type: 'int' }
          { name: 'Status', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspace.id
          name: 'logAnalyticsDestination'
        }
      ]
    }
    dataFlows: [
      { streams: ['Custom-IntuneDevices_CL'], destinations: ['logAnalyticsDestination'], transformKql: 'source', outputStream: 'Custom-IntuneDevices_CL' }
      { streams: ['Custom-IntuneCompliance_CL'], destinations: ['logAnalyticsDestination'], transformKql: 'source', outputStream: 'Custom-IntuneCompliance_CL' }
      { streams: ['Custom-IntuneCompliancePolicies_CL'], destinations: ['logAnalyticsDestination'], transformKql: 'source', outputStream: 'Custom-IntuneCompliancePolicies_CL' }
      { streams: ['Custom-IntuneDeviceScores_CL'], destinations: ['logAnalyticsDestination'], transformKql: 'source', outputStream: 'Custom-IntuneDeviceScores_CL' }
      { streams: ['Custom-IntuneStartupPerformance_CL'], destinations: ['logAnalyticsDestination'], transformKql: 'source', outputStream: 'Custom-IntuneStartupPerformance_CL' }
      { streams: ['Custom-IntuneAppReliability_CL'], destinations: ['logAnalyticsDestination'], transformKql: 'source', outputStream: 'Custom-IntuneAppReliability_CL' }
      { streams: ['Custom-IntuneAutopilotDevices_CL'], destinations: ['logAnalyticsDestination'], transformKql: 'source', outputStream: 'Custom-IntuneAutopilotDevices_CL' }
      { streams: ['Custom-IntuneAutopilotProfiles_CL'], destinations: ['logAnalyticsDestination'], transformKql: 'source', outputStream: 'Custom-IntuneAutopilotProfiles_CL' }
      { streams: ['Custom-IntuneSyncState_CL'], destinations: ['logAnalyticsDestination'], transformKql: 'source', outputStream: 'Custom-IntuneSyncState_CL' }
    ]
  }
}

// ============================================================================
// Azure Data Explorer Cluster (optional)
// ============================================================================

resource adxCluster 'Microsoft.Kusto/clusters@2023-08-15' = if (analyticsBackend == 'ADX' && createAdxCluster) {
  name: adxClusterName
  location: location
  sku: {
    name: 'Dev(No SLA)_Standard_E2a_v4'
    tier: 'Basic'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    enableStreamingIngest: true
    enableAutoStop: true
    publicNetworkAccess: 'Enabled'
  }
}

resource adxDatabase 'Microsoft.Kusto/clusters/databases@2023-08-15' = if (analyticsBackend == 'ADX' && createAdxCluster) {
  parent: adxCluster
  name: adxDatabaseName
  location: location
  kind: 'ReadWrite'
  properties: {
    softDeletePeriod: 'P365D'
    hotCachePeriod: 'P31D'
  }
}

// ============================================================================
// Automation Account
// ============================================================================

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
  }
}

// ============================================================================
// NOTE: Python packages are installed via post-deployment script
// Run: ./scripts/Setup-RuntimeEnvironment.ps1 after deployment
// This approach ensures packages are always installed from the latest PyPI versions
// ============================================================================

// ============================================================================
// Automation Variables
// ============================================================================

resource varTenantId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'AZURE_TENANT_ID'
  properties: {
    value: '"${tenantId}"'
    isEncrypted: false
  }
}

resource varClientId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'AZURE_CLIENT_ID'
  properties: {
    value: '"${graphClientId}"'
    isEncrypted: false
  }
}

resource varClientSecret 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'AZURE_CLIENT_SECRET'
  properties: {
    value: '"${graphClientSecret}"'
    isEncrypted: true
  }
}

resource varAnalyticsBackend 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ANALYTICS_BACKEND'
  properties: {
    value: '"${analyticsBackend}"'
    isEncrypted: false
  }
}

resource varAdxCluster 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'ADX') {
  parent: automationAccount
  name: 'ADX_CLUSTER_URI'
  properties: {
    value: createAdxCluster ? '"${adxCluster!.properties.uri}"' : '"${existingAdxClusterUri}"'
    isEncrypted: false
  }
}

resource varAdxDatabase 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'ADX') {
  parent: automationAccount
  name: 'ADX_DATABASE'
  properties: {
    value: '"${adxDatabaseName}"'
    isEncrypted: false
  }
}

resource varLogAnalyticsDce 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automationAccount
  name: 'LOG_ANALYTICS_DCE'
  properties: {
    value: '"${dataCollectionEndpoint!.properties.logsIngestion.endpoint}"'
    isEncrypted: false
  }
}

resource varLogAnalyticsDcrId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automationAccount
  name: 'LOG_ANALYTICS_DCR_ID'
  properties: {
    value: '"${dataCollectionRule!.properties.immutableId}"'
    isEncrypted: false
  }
}

resource varLogAnalyticsWorkspaceId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automationAccount
  name: 'LOG_ANALYTICS_WORKSPACE_ID'
  properties: {
    value: '"${logAnalyticsWorkspace!.properties.customerId}"'
    isEncrypted: false
  }
}

// ============================================================================
// Runbooks, Schedules, and Job Links
// ============================================================================

resource runbooks 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = [for cfg in runbookConfigs: {
  parent: automationAccount
  name: cfg.name
  location: location
  properties: {
    runbookType: 'Python3'
    logProgress: true
    logVerbose: true
    description: cfg.desc
    publishContentLink: { uri: '${runbookBaseUrl}/${cfg.file}' }
  }
}]

resource schedules 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = [for cfg in runbookConfigs: {
  parent: automationAccount
  name: '${cfg.name}-Schedule'
  properties: {
    frequency: cfg.freq
    interval: cfg.interval
    startTime: scheduleStartTime
    timeZone: 'UTC'
  }
}]

resource jobSchedules 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = [for (cfg, i) in runbookConfigs: {
  parent: automationAccount
  #disable-next-line use-stable-resource-identifiers
  name: guid(automationAccount.id, cfg.name)
  properties: {
    runbook: { name: runbooks[i].name }
    schedule: { name: schedules[i].name }
  }
}]

// ============================================================================
// Role Assignments
// ============================================================================

resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (analyticsBackend == 'LogAnalytics') {
  name: guid(dataCollectionRule.id, automationAccount.id, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: dataCollectionRule
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource adxRoleAssignment 'Microsoft.Kusto/clusters/databases/principalAssignments@2023-08-15' = if (analyticsBackend == 'ADX' && createAdxCluster) {
  parent: adxDatabase
  name: guid(adxDatabase.id, automationAccount.id)
  properties: {
    principalId: automationAccount.identity.principalId
    principalType: 'App'
    role: 'Ingestor'
    tenantId: tenantId
  }
}

// ============================================================================
// Outputs
// ============================================================================

output automationAccountName string = automationAccount.name
output automationAccountId string = automationAccount.id
output managedIdentityPrincipalId string = automationAccount.identity.principalId
output runtimeEnvironmentName string = runtimeEnvironmentName

output logAnalyticsWorkspaceId string = analyticsBackend == 'LogAnalytics' ? logAnalyticsWorkspace!.properties.customerId : 'N/A'
output logAnalyticsWorkspaceName string = analyticsBackend == 'LogAnalytics' ? logAnalyticsWorkspace!.name : 'N/A'
output dataCollectionEndpointUri string = analyticsBackend == 'LogAnalytics' ? dataCollectionEndpoint!.properties.logsIngestion.endpoint : 'N/A'
output dataCollectionRuleId string = analyticsBackend == 'LogAnalytics' ? dataCollectionRule!.properties.immutableId : 'N/A'

output adxClusterUri string = analyticsBackend == 'ADX' && createAdxCluster ? adxCluster!.properties.uri : (analyticsBackend == 'ADX' ? existingAdxClusterUri : 'N/A')
output adxDatabaseNameOutput string = analyticsBackend == 'ADX' ? adxDatabaseName : 'N/A'

output setupRuntimeEnvironmentCommand string = './scripts/Setup-RuntimeEnvironment.ps1 -AutomationAccountName "${automationAccount.name}" -ResourceGroupName "${resourceGroup().name}" -AnalyticsBackend "${analyticsBackend}"'
output grantGraphPermissionsCommand string = './scripts/Grant-GraphPermissions.ps1 -ManagedIdentityObjectId "${automationAccount.identity.principalId}"'

output nextSteps string = '''
DEPLOYMENT COMPLETE! Next steps:

1. Install Python packages (REQUIRED):
   Run: ./scripts/Setup-RuntimeEnvironment.ps1 -AutomationAccountName "<name>" -ResourceGroupName "<rg>" -AnalyticsBackend "<backend>"
   This creates a Runtime Environment and installs packages from PyPI.

2. Grant Microsoft Graph API permissions to the Managed Identity:
   Run: ./scripts/Grant-GraphPermissions.ps1 -ManagedIdentityObjectId "<managedIdentityPrincipalId>"
   
   Required permissions:
   - DeviceManagementManagedDevices.Read.All
   - DeviceManagementConfiguration.Read.All  
   - DeviceManagementServiceConfig.Read.All

3. If using ADX with existing cluster, grant Database Ingestor role and run Schema-Focused.kql

4. Test: Automation Account > Runbooks > Export-IntuneDevices > Start
'''
