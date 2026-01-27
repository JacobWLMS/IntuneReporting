// ============================================================================
// Intune Analytics Platform - Azure Automation Account
// ============================================================================
// Simpler alternative to Azure Functions. No storage account required.
// Uses PowerShell runbooks with Microsoft.Graph module.
//
// After deployment:
// 1. Grant Graph API permissions to the managed identity
// 2. Grant ADX Ingestor role (if using ADX backend)
// 3. Runbooks will run on schedule automatically
// ============================================================================

@description('Base name for all resources (max 11 chars)')
@maxLength(11)
param baseName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Analytics backend: ADX or LogAnalytics')
@allowed(['ADX', 'LogAnalytics'])
param analyticsBackend string = 'ADX'

@description('ADX cluster URI (required if backend is ADX)')
param adxClusterUri string = ''

@description('ADX database name')
param adxDatabase string = 'IntuneAnalytics'

@description('Log Analytics workspace ID (required if backend is LogAnalytics)')
param logAnalyticsWorkspaceId string = ''

@description('Data Collection Endpoint URL (required if backend is LogAnalytics)')
param logAnalyticsDce string = ''

@description('Data Collection Rule ID (required if backend is LogAnalytics)')
param logAnalyticsDcrId string = ''

// ============================================================================
// Variables
// ============================================================================

var suffix = uniqueString(resourceGroup().id)
var automationName = '${baseName}-auto-${suffix}'

// ============================================================================
// Automation Account
// ============================================================================

resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationName
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
// Variables (Automation Account variables for runbook configuration)
// ============================================================================

resource varBackend 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automation
  name: 'AnalyticsBackend'
  properties: {
    value: '"${analyticsBackend}"'
    isEncrypted: false
  }
}

resource varAdxCluster 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'ADX') {
  parent: automation
  name: 'AdxClusterUri'
  properties: {
    value: '"${adxClusterUri}"'
    isEncrypted: false
  }
}

resource varAdxDatabase 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'ADX') {
  parent: automation
  name: 'AdxDatabase'
  properties: {
    value: '"${adxDatabase}"'
    isEncrypted: false
  }
}

resource varLaWorkspace 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automation
  name: 'LogAnalyticsWorkspaceId'
  properties: {
    value: '"${logAnalyticsWorkspaceId}"'
    isEncrypted: false
  }
}

resource varLaDce 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automation
  name: 'LogAnalyticsDce'
  properties: {
    value: '"${logAnalyticsDce}"'
    isEncrypted: false
  }
}

resource varLaDcr 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (analyticsBackend == 'LogAnalytics') {
  parent: automation
  name: 'LogAnalyticsDcrId'
  properties: {
    value: '"${logAnalyticsDcrId}"'
    isEncrypted: false
  }
}

// ============================================================================
// PowerShell Modules
// ============================================================================

resource moduleAzAccounts 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automation
  name: 'Az.Accounts'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/3.0.0'
    }
  }
}

resource moduleMgGraph 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automation
  name: 'Microsoft.Graph.Authentication'
  dependsOn: [moduleAzAccounts]
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication/2.15.0'
    }
  }
}

resource moduleMgDeviceManagement 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automation
  name: 'Microsoft.Graph.DeviceManagement'
  dependsOn: [moduleMgGraph]
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.DeviceManagement/2.15.0'
    }
  }
}

resource moduleAzKusto 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = if (analyticsBackend == 'ADX') {
  parent: automation
  name: 'Az.Kusto'
  dependsOn: [moduleAzAccounts]
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Kusto/2.3.0'
    }
  }
}

// ============================================================================
// Runbooks
// ============================================================================

resource runbookCompliance 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automation
  name: 'Export-IntuneCompliance'
  dependsOn: [moduleMgDeviceManagement, moduleAzKusto]
  properties: {
    runbookType: 'PowerShell72'
    logProgress: true
    logVerbose: false
    description: 'Exports Intune device compliance data every 6 hours'
  }
}

resource runbookEndpointAnalytics 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automation
  name: 'Export-EndpointAnalytics'
  dependsOn: [moduleMgDeviceManagement, moduleAzKusto]
  properties: {
    runbookType: 'PowerShell72'
    logProgress: true
    logVerbose: false
    description: 'Exports Endpoint Analytics data daily at 8 AM'
  }
}

// ============================================================================
// Schedules
// ============================================================================

resource scheduleCompliance 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automation
  name: 'Every6Hours'
  properties: {
    frequency: 'Hour'
    interval: 6
    startTime: dateTimeAdd(utcNow(), 'PT1H')
    timeZone: 'UTC'
  }
}

resource scheduleEndpointAnalytics 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automation
  name: 'Daily8AM'
  properties: {
    frequency: 'Day'
    interval: 1
    startTime: '2024-01-01T08:00:00+00:00'
    timeZone: 'UTC'
  }
}

// ============================================================================
// Schedule Links
// ============================================================================

resource linkCompliance 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automation
  name: guid(automation.id, 'compliance-schedule')
  properties: {
    runbook: {
      name: runbookCompliance.name
    }
    schedule: {
      name: scheduleCompliance.name
    }
  }
}

resource linkEndpointAnalytics 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automation
  name: guid(automation.id, 'endpoint-analytics-schedule')
  properties: {
    runbook: {
      name: runbookEndpointAnalytics.name
    }
    schedule: {
      name: scheduleEndpointAnalytics.name
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

output automationAccountName string = automation.name
output automationAccountId string = automation.id
output principalId string = automation.identity.principalId

output postDeploymentSteps string = '''
After deployment, complete these steps:

1. Upload runbook code:
   - Go to Automation Account > Runbooks
   - Edit each runbook and paste the PowerShell code from /runbooks folder
   - Publish the runbooks

2. Grant Graph API permissions to the managed identity:
   Run: ./scripts/Grant-GraphPermissions.ps1 -ServicePrincipalObjectId "<principalId from output>"

   Required permissions:
   - DeviceManagementManagedDevices.Read.All
   - DeviceManagementConfiguration.Read.All

3. For ADX backend: Grant "Ingestor" role on the ADX database

4. For Log Analytics backend: Grant "Monitoring Metrics Publisher" on the DCR

5. Test by manually running each runbook once
'''
