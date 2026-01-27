// ============================================================================
// Intune Analytics Platform - Azure Automation Account Deployment
// ============================================================================
// Deploys Azure Automation Account with Python 3.10 runbooks for Intune data export
// Supports both Azure Data Explorer and Log Analytics backends
// ============================================================================

@description('Base name for all resources (max 11 characters)')
@maxLength(11)
param baseName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Analytics backend: LogAnalytics or ADX')
@allowed(['LogAnalytics', 'ADX'])
param analyticsBackend string = 'LogAnalytics'

// App Registration credentials (for Graph API access)
@description('Azure AD Tenant ID')
param tenantId string = subscription().tenantId

@description('App Registration Client ID for Microsoft Graph API')
param graphClientId string = ''

@description('App Registration Client Secret for Microsoft Graph API')
@secure()
param graphClientSecret string = ''

// ADX settings (only used if analyticsBackend = 'ADX')
@description('Azure Data Explorer cluster URI (e.g., https://mycluster.region.kusto.windows.net)')
param adxClusterUri string = ''

@description('Azure Data Explorer database name')
param adxDatabaseName string = 'IntuneAnalytics'

// Log Analytics settings (only used if analyticsBackend = 'LogAnalytics')
@description('Log Analytics Data Collection Endpoint')
param logAnalyticsDce string = ''

@description('Log Analytics Data Collection Rule ID')
param logAnalyticsDcrId string = ''

@description('Log Analytics Workspace ID')
param logAnalyticsWorkspaceId string = ''

@description('Start time for schedules (defaults to 1 hour from now)')
param scheduleStartTime string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

// ============================================================================
// Variables
// ============================================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var automationAccountName = '${baseName}-auto-${uniqueSuffix}'

// GitHub raw URLs for runbooks
var runbookBaseUrl = 'https://raw.githubusercontent.com/JacobWLMS/IntuneReporting/main/runbooks'
var devicesRunbookUrl = '${runbookBaseUrl}/export_devices.py'
var complianceRunbookUrl = '${runbookBaseUrl}/export_compliance.py'
var analyticsRunbookUrl = '${runbookBaseUrl}/export_endpoint_analytics.py'
var autopilotRunbookUrl = '${runbookBaseUrl}/export_autopilot.py'

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
// Python 3 Packages - Deployed in sequence using batchedFor loop
// ============================================================================

// Package definitions with order for sequential deployment
var pythonPackages = [
  // Batch 1: Core dependencies (no deps)
  { name: 'azure_core', uri: 'https://files.pythonhosted.org/packages/07/b7/76b7e144aa53bd206bf1ce59bc627b5a3d9112669bacb026ca7014ca55d0/azure_core-1.32.0-py3-none-any.whl', batch: 1 }
  { name: 'msal', uri: 'https://files.pythonhosted.org/packages/11/5e/5ebc968c4299df19d6b5d493d96d80b98b4a26f5e66d36adfe20e4c3d78a/msal-1.31.1-py3-none-any.whl', batch: 1 }
  { name: 'microsoft_kiota_abstractions', uri: 'https://files.pythonhosted.org/packages/16/b9/eb1dd22c2019b2b536e00536d744b59c0f72c2ae538b9fbfddcc39abe66a/microsoft_kiota_abstractions-1.7.1-py3-none-any.whl', batch: 1 }
  // Batch 2: Depends on batch 1
  { name: 'azure_identity', uri: 'https://files.pythonhosted.org/packages/30/10/5dbf755b368d10a28d55f1c99cb110549c2e5528ebe4380a8dd900fee93c/azure_identity-1.19.0-py3-none-any.whl', batch: 2 }
  { name: 'msal_extensions', uri: 'https://files.pythonhosted.org/packages/2d/38/ad49ef4c150fef8f651dc40852bd94c871736f7d37851d23b0a83c708a2b/msal_extensions-1.2.0-py3-none-any.whl', batch: 2 }
  { name: 'microsoft_kiota_http', uri: 'https://files.pythonhosted.org/packages/53/42/85e8c56cc2ab08e0d0fe73fd16d69c73c0f8bf6fc2db5d30d87e4db22e33/microsoft_kiota_http-1.7.0-py3-none-any.whl', batch: 2 }
  { name: 'microsoft_kiota_serialization_json', uri: 'https://files.pythonhosted.org/packages/9b/96/d94c35e1a6a5a22d6f12de9e4ecf7b1e8e16d6ef2d8e7a7c95aef01dc3ac/microsoft_kiota_serialization_json-1.7.0-py3-none-any.whl', batch: 2 }
  { name: 'microsoft_kiota_serialization_text', uri: 'https://files.pythonhosted.org/packages/36/72/07f1f7e14a5c5f6db9ec3d0d6e36c5c67de9de91b7c27db74edbbba0e1e3/microsoft_kiota_serialization_text-1.7.0-py3-none-any.whl', batch: 2 }
  { name: 'microsoft_kiota_serialization_form', uri: 'https://files.pythonhosted.org/packages/66/fa/d9a5e78cafc1c35bab8ea8f10abcf5c4de53e5c01d50ce40ab1fabc1a0cb/microsoft_kiota_serialization_form-0.1.0-py3-none-any.whl', batch: 2 }
  { name: 'microsoft_kiota_serialization_multipart', uri: 'https://files.pythonhosted.org/packages/a8/ca/93e4e1a8cab3c3cf8f82dd3b1b0e16c73b1c4e26f6d68af24e94ad97f9c6/microsoft_kiota_serialization_multipart-0.1.0-py3-none-any.whl', batch: 2 }
  // Batch 3: Depends on batch 2
  { name: 'msgraph_core', uri: 'https://files.pythonhosted.org/packages/30/4e/3e2fb8c6e89bd86fc4e5bf18f5bc5bfd9c09f7deb7f42eb93479f0a6326d/msgraph_core-1.2.0-py3-none-any.whl', batch: 3 }
  { name: 'microsoft_kiota_authentication_azure', uri: 'https://files.pythonhosted.org/packages/d9/6e/53893f3a4d0d0abb4fef32efb38a1b6caab6bf8f1df3d9ac397c2f8e9a09/microsoft_kiota_authentication_azure-1.7.0-py3-none-any.whl', batch: 3 }
  // Batch 4: Graph SDK (depends on all above)
  { name: 'msgraph_beta_sdk', uri: 'https://files.pythonhosted.org/packages/51/b0/95f7e4fd4f60e8c99d5ce4a2ff9eb2cfeb46f27db0be6c4a98f81e290db1/msgraph_beta_sdk-1.14.0-py3-none-any.whl', batch: 4 }
]

// Backend-specific packages
var adxPackages = [
  { name: 'azure_kusto_data', uri: 'https://files.pythonhosted.org/packages/25/c5/0ee2d87ac83c73cf64c5f5e5e58f61697f1a41dca0b6eb6eabdc438e4cd5/azure_kusto_data-4.6.1-py2.py3-none-any.whl' }
  { name: 'azure_kusto_ingest', uri: 'https://files.pythonhosted.org/packages/b1/7f/c83a7d1e9cf6c22d97c3fb9a52d0f55d52e0e9b23a56c3d37cff0e0c3a54/azure_kusto_ingest-4.6.1-py2.py3-none-any.whl' }
]

var logAnalyticsPackages = [
  { name: 'azure_monitor_ingestion', uri: 'https://files.pythonhosted.org/packages/b0/a0/c5e14cc42f78f2c36c4c19ef6a74e0e2d82c8e4c10acfbaa2f2f0b6a4d0a/azure_monitor_ingestion-1.0.4-py3-none-any.whl' }
]

// Deploy packages in batches using @batchSize decorator
@batchSize(1)
resource corePackages 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = [for pkg in pythonPackages: {
  parent: automationAccount
  name: pkg.name
  properties: {
    contentLink: { uri: pkg.uri }
  }
}]

@batchSize(1)
resource adxPkgs 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = [for pkg in adxPackages: if (analyticsBackend == 'ADX') {
  parent: automationAccount
  name: pkg.name
  properties: {
    contentLink: { uri: pkg.uri }
  }
  dependsOn: [corePackages]
}]

@batchSize(1)
resource logAnalyticsPkgs 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = [for pkg in logAnalyticsPackages: if (analyticsBackend == 'LogAnalytics') {
  parent: automationAccount
  name: pkg.name
  properties: {
    contentLink: { uri: pkg.uri }
  }
  dependsOn: [corePackages]
}]

// ============================================================================
// Automation Variables (Configuration)
// ============================================================================

resource varTenantId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'AZURE_TENANT_ID'
  properties: {
    value: '"${tenantId}"'
    isEncrypted: false
    description: 'Azure AD Tenant ID'
  }
}

resource varClientId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'AZURE_CLIENT_ID'
  properties: {
    value: '"${graphClientId}"'
    isEncrypted: false
    description: 'App Registration Client ID for Microsoft Graph'
  }
}

resource varClientSecret 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'AZURE_CLIENT_SECRET'
  properties: {
    value: '"${graphClientSecret}"'
    isEncrypted: true
    description: 'App Registration Client Secret for Microsoft Graph'
  }
}

resource varAnalyticsBackend 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ANALYTICS_BACKEND'
  properties: {
    value: '"${analyticsBackend}"'
    isEncrypted: false
    description: 'Analytics backend: ADX or LogAnalytics'
  }
}

// ADX Variables
resource varAdxCluster 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'ADX') {
  parent: automationAccount
  name: 'ADX_CLUSTER_URI'
  properties: {
    value: '"${adxClusterUri}"'
    isEncrypted: false
    description: 'Azure Data Explorer cluster URI'
  }
}

resource varAdxDatabase 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'ADX') {
  parent: automationAccount
  name: 'ADX_DATABASE'
  properties: {
    value: '"${adxDatabaseName}"'
    isEncrypted: false
    description: 'Azure Data Explorer database name'
  }
}

// Log Analytics Variables
resource varLogAnalyticsDce 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automationAccount
  name: 'LOG_ANALYTICS_DCE'
  properties: {
    value: '"${logAnalyticsDce}"'
    isEncrypted: false
    description: 'Log Analytics Data Collection Endpoint'
  }
}

resource varLogAnalyticsDcrId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automationAccount
  name: 'LOG_ANALYTICS_DCR_ID'
  properties: {
    value: '"${logAnalyticsDcrId}"'
    isEncrypted: false
    description: 'Log Analytics Data Collection Rule ID'
  }
}

resource varLogAnalyticsWorkspaceId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automationAccount
  name: 'LOG_ANALYTICS_WORKSPACE_ID'
  properties: {
    value: '"${logAnalyticsWorkspaceId}"'
    isEncrypted: false
    description: 'Log Analytics Workspace ID'
  }
}

// ============================================================================
// Runbooks, Schedules, and Job Links - Using loops for conciseness
// ============================================================================

var runbookConfigs = [
  { name: 'Export-IntuneDevices', url: devicesRunbookUrl, desc: 'Exports Intune managed device inventory', freq: 'Hour', interval: 4, scheduleName: 'DevicesExport-Every4Hours' }
  { name: 'Export-IntuneCompliance', url: complianceRunbookUrl, desc: 'Exports Intune compliance policies and states', freq: 'Hour', interval: 6, scheduleName: 'ComplianceExport-Every6Hours' }
  { name: 'Export-EndpointAnalytics', url: analyticsRunbookUrl, desc: 'Exports Endpoint Analytics data', freq: 'Day', interval: 1, scheduleName: 'AnalyticsExport-Daily' }
  { name: 'Export-Autopilot', url: autopilotRunbookUrl, desc: 'Exports Autopilot devices and profiles', freq: 'Day', interval: 1, scheduleName: 'AutopilotExport-Daily' }
]

resource runbooks 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = [for cfg in runbookConfigs: {
  parent: automationAccount
  name: cfg.name
  location: location
  properties: {
    runbookType: 'Python3'
    logProgress: true
    logVerbose: true
    description: cfg.desc
    publishContentLink: { uri: cfg.url }
  }
  dependsOn: [corePackages]
}]

resource schedules 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = [for cfg in runbookConfigs: {
  parent: automationAccount
  name: cfg.scheduleName
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
  name: guid(automationAccount.id, cfg.name, cfg.scheduleName)
  properties: {
    runbook: { name: runbooks[i].name }
    schedule: { name: schedules[i].name }
  }
}]

// ============================================================================
// Outputs
// ============================================================================

output automationAccountName string = automationAccount.name
output automationAccountId string = automationAccount.id
output managedIdentityPrincipalId string = automationAccount.identity.principalId
output managedIdentityTenantId string = automationAccount.identity.tenantId

output nextSteps string = '''
NEXT STEPS:
1. Grant Graph API permissions to either:
   a) Your App Registration (if using client credentials), OR
   b) The Automation Account's managed identity
   
   Required permissions:
     - DeviceManagementManagedDevices.Read.All
     - DeviceManagementConfiguration.Read.All
     - DeviceManagementServiceConfig.Read.All (for Autopilot)

2. If using ADX backend:
   - Create your ADX cluster and database if not already done
   - Run the Schema-Focused.kql script to create tables and views
   - Grant 'Database Ingestor' role to your App Registration or Managed Identity

3. If using Log Analytics backend:
   - Create Data Collection Endpoint (DCE) and Data Collection Rule (DCR)
   - Grant 'Monitoring Metrics Publisher' role to your App Registration or Managed Identity

4. Test the runbooks manually:
   - Go to Automation Account > Runbooks > Export-IntuneCompliance > Start

5. Monitor the scheduled runs in the Jobs tab
'''

output grantGraphPermissionsCommand string = '.\\scripts\\Grant-GraphPermissions.ps1 -ManagedIdentityObjectId "${automationAccount.identity.principalId}"'
