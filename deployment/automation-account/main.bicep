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

@description('Analytics backend: ADX or LogAnalytics')
@allowed(['ADX', 'LogAnalytics'])
param analyticsBackend string = 'ADX'

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
var complianceRunbookUrl = '${runbookBaseUrl}/export_compliance.py'
var analyticsRunbookUrl = '${runbookBaseUrl}/export_endpoint_analytics.py'

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
// Python 3 Packages (using Python 3 module resources)
// Note: Azure Automation Python packages are installed via module resources
// ============================================================================

// Core packages - installed via pip wheel URLs
resource packageAzureIdentity 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'azure_identity'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/30/10/5dbf755b368d10a28d55f1c99cb110549c2e5528ebe4380a8dd900fee93c/azure_identity-1.19.0-py3-none-any.whl'
    }
  }
}

resource packageMsal 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'msal'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/11/5e/5ebc968c4299df19d6b5d493d96d80b98b4a26f5e66d36adfe20e4c3d78a/msal-1.31.1-py3-none-any.whl'
    }
  }
}

resource packageMsalExtensions 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'msal_extensions'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/2d/38/ad49ef4c150fef8f651dc40852bd94c871736f7d37851d23b0a83c708a2b/msal_extensions-1.2.0-py3-none-any.whl'
    }
  }
  dependsOn: [packageMsal]
}

resource packageAzureCore 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'azure_core'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/07/b7/76b7e144aa53bd206bf1ce59bc627b5a3d9112669bacb026ca7014ca55d0/azure_core-1.32.0-py3-none-any.whl'
    }
  }
}

resource packageMsgraphCore 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'msgraph_core'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/30/4e/3e2fb8c6e89bd86fc4e5bf18f5bc5bfd9c09f7deb7f42eb93479f0a6326d/msgraph_core-1.2.0-py3-none-any.whl'
    }
  }
  dependsOn: [packageAzureIdentity]
}

resource packageKiotaAbstractions 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'microsoft_kiota_abstractions'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/16/b9/eb1dd22c2019b2b536e00536d744b59c0f72c2ae538b9fbfddcc39abe66a/microsoft_kiota_abstractions-1.7.1-py3-none-any.whl'
    }
  }
}

resource packageKiotaAuth 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'microsoft_kiota_authentication_azure'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/d9/6e/53893f3a4d0d0abb4fef32efb38a1b6caab6bf8f1df3d9ac397c2f8e9a09/microsoft_kiota_authentication_azure-1.7.0-py3-none-any.whl'
    }
  }
  dependsOn: [packageAzureIdentity, packageKiotaAbstractions]
}

resource packageKiotaHttp 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'microsoft_kiota_http'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/53/42/85e8c56cc2ab08e0d0fe73fd16d69c73c0f8bf6fc2db5d30d87e4db22e33/microsoft_kiota_http-1.7.0-py3-none-any.whl'
    }
  }
  dependsOn: [packageKiotaAbstractions]
}

resource packageKiotaSerialization 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'microsoft_kiota_serialization_json'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/9b/96/d94c35e1a6a5a22d6f12de9e4ecf7b1e8e16d6ef2d8e7a7c95aef01dc3ac/microsoft_kiota_serialization_json-1.7.0-py3-none-any.whl'
    }
  }
  dependsOn: [packageKiotaAbstractions]
}

resource packageKiotaSerializationText 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'microsoft_kiota_serialization_text'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/36/72/07f1f7e14a5c5f6db9ec3d0d6e36c5c67de9de91b7c27db74edbbba0e1e3/microsoft_kiota_serialization_text-1.7.0-py3-none-any.whl'
    }
  }
  dependsOn: [packageKiotaAbstractions]
}

resource packageKiotaSerializationForm 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'microsoft_kiota_serialization_form'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/66/fa/d9a5e78cafc1c35bab8ea8f10abcf5c4de53e5c01d50ce40ab1fabc1a0cb/microsoft_kiota_serialization_form-0.1.0-py3-none-any.whl'
    }
  }
  dependsOn: [packageKiotaAbstractions]
}

resource packageKiotaSerializationMultipart 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'microsoft_kiota_serialization_multipart'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/a8/ca/93e4e1a8cab3c3cf8f82dd3b1b0e16c73b1c4e26f6d68af24e94ad97f9c6/microsoft_kiota_serialization_multipart-0.1.0-py3-none-any.whl'
    }
  }
  dependsOn: [packageKiotaAbstractions]
}

resource packageMsgraphBeta 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = {
  parent: automationAccount
  name: 'msgraph_beta_sdk'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/51/b0/95f7e4fd4f60e8c99d5ce4a2ff9eb2cfeb46f27db0be6c4a98f81e290db1/msgraph_beta_sdk-1.14.0-py3-none-any.whl'
    }
  }
  dependsOn: [
    packageMsgraphCore
    packageKiotaAbstractions
    packageKiotaAuth
    packageKiotaHttp
    packageKiotaSerialization
    packageKiotaSerializationText
    packageKiotaSerializationForm
    packageKiotaSerializationMultipart
  ]
}

// ADX packages - only installed if using ADX backend
resource packageKustoData 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = if (analyticsBackend == 'ADX') {
  parent: automationAccount
  name: 'azure_kusto_data'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/25/c5/0ee2d87ac83c73cf64c5f5e5e58f61697f1a41dca0b6eb6eabdc438e4cd5/azure_kusto_data-4.6.1-py2.py3-none-any.whl'
    }
  }
  dependsOn: [packageAzureIdentity, packageAzureCore]
}

resource packageKustoIngest 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = if (analyticsBackend == 'ADX') {
  parent: automationAccount
  name: 'azure_kusto_ingest'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/b1/7f/c83a7d1e9cf6c22d97c3fb9a52d0f55d52e0e9b23a56c3d37cff0e0c3a54/azure_kusto_ingest-4.6.1-py2.py3-none-any.whl'
    }
  }
  dependsOn: [packageKustoData]
}

// Log Analytics packages - only installed if using Log Analytics backend
resource packageMonitorIngestion 'Microsoft.Automation/automationAccounts/python3Packages@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automationAccount
  name: 'azure_monitor_ingestion'
  properties: {
    contentLink: {
      uri: 'https://files.pythonhosted.org/packages/b0/a0/c5e14cc42f78f2c36c4c19ef6a74e0e2d82c8e4c10acfbaa2f2f0b6a4d0a/azure_monitor_ingestion-1.0.4-py3-none-any.whl'
    }
  }
  dependsOn: [packageAzureIdentity, packageAzureCore]
}

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
// Python Runbooks
// ============================================================================

resource runbookCompliance 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Export-IntuneCompliance'
  location: location
  properties: {
    runbookType: 'Python3'
    logProgress: true
    logVerbose: true
    description: 'Exports Intune device compliance data to analytics backend'
    publishContentLink: {
      uri: complianceRunbookUrl
    }
  }
  dependsOn: [packageMsgraphBeta]
}

resource runbookAnalytics 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Export-EndpointAnalytics'
  location: location
  properties: {
    runbookType: 'Python3'
    logProgress: true
    logVerbose: true
    description: 'Exports Endpoint Analytics data to analytics backend'
    publishContentLink: {
      uri: analyticsRunbookUrl
    }
  }
  dependsOn: [packageMsgraphBeta]
}

// ============================================================================
// Schedules
// ============================================================================

resource scheduleCompliance 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'ComplianceExport-Every6Hours'
  properties: {
    frequency: 'Hour'
    interval: 6
    startTime: scheduleStartTime
    timeZone: 'UTC'
    description: 'Runs compliance export every 6 hours'
  }
}

resource scheduleAnalytics 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'AnalyticsExport-Daily8AM'
  properties: {
    frequency: 'Day'
    interval: 1
    startTime: '2026-01-28T08:00:00Z'
    timeZone: 'UTC'
    description: 'Runs endpoint analytics export daily at 8 AM UTC'
  }
}

// ============================================================================
// Schedule-Runbook Links
// ============================================================================

resource jobScheduleCompliance 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automationAccount
  #disable-next-line use-stable-resource-identifiers
  name: guid(automationAccount.id, runbookCompliance.name, scheduleCompliance.name)
  properties: {
    runbook: {
      name: runbookCompliance.name
    }
    schedule: {
      name: scheduleCompliance.name
    }
  }
  dependsOn: [runbookCompliance, scheduleCompliance]
}

resource jobScheduleAnalytics 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automationAccount
  #disable-next-line use-stable-resource-identifiers
  name: guid(automationAccount.id, runbookAnalytics.name, scheduleAnalytics.name)
  properties: {
    runbook: {
      name: runbookAnalytics.name
    }
    schedule: {
      name: scheduleAnalytics.name
    }
  }
  dependsOn: [runbookAnalytics, scheduleAnalytics]
}

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
