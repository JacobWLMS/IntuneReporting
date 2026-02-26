<#
.SYNOPSIS
    Deploys saved functions to Log Analytics workspace
.DESCRIPTION
    Creates reusable KQL functions in your Log Analytics workspace
    that can be called like tables in queries and workbooks
.EXAMPLE
    .\Deploy-SavedFunctions.ps1 -WorkspaceId "your-workspace-id" -ResourceGroup "your-rg"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId
)

# Connect to Azure if needed
$context = Get-AzContext
if (-not $context) {
    Connect-AzAccount
}

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId
}

# Define functions to create
$functions = @(
    @{
        Name = "LatestDevices"
        DisplayName = "Latest Devices"
        Description = "Returns the most recent record for each device (deduplicates IntuneDevices_CL)"
        Category = "Intune"
        Query = @"
IntuneDevices_CL
| summarize arg_max(TimeGenerated, *) by DeviceId
"@
    },
    @{
        Name = "LatestCompliance"
        DisplayName = "Latest Compliance States"
        Description = "Returns the most recent compliance state per device per policy"
        Category = "Intune"
        Query = @"
IntuneComplianceStates_CL
| summarize arg_max(TimeGenerated, *) by DeviceId, PolicyId
"@
    },
    @{
        Name = "LatestScores"
        DisplayName = "Latest Device Scores"
        Description = "Returns the most recent Endpoint Analytics scores per device"
        Category = "Intune"
        Query = @"
IntuneDeviceScores_CL
| summarize arg_max(TimeGenerated, *) by DeviceId
"@
    },
    @{
        Name = "LatestStartup"
        DisplayName = "Latest Startup Performance"
        Description = "Returns the most recent startup performance metrics per device"
        Category = "Intune"
        Query = @"
IntuneStartupPerformance_CL
| summarize arg_max(TimeGenerated, *) by DeviceId
"@
    },
    @{
        Name = "LatestAutopilot"
        DisplayName = "Latest Autopilot Devices"
        Description = "Returns the most recent Autopilot device records"
        Category = "Intune"
        Query = @"
IntuneAutopilotDevices_CL
| summarize arg_max(TimeGenerated, *) by AutopilotDeviceId
"@
    },
    @{
        Name = "NonCompliantDevices"
        DisplayName = "Non-Compliant Devices"
        Description = "Returns devices with at least one non-compliant policy"
        Category = "Intune"
        Query = @"
IntuneComplianceStates_CL
| summarize arg_max(TimeGenerated, *) by DeviceId, PolicyId
| where StatusRaw == 4
| distinct DeviceId, DeviceName, UserPrincipalName, PolicyName
"@
    },
    @{
        Name = "LatestUsers"
        DisplayName = "Latest Users"
        Description = "Returns the most recent user record for each user (deduplicates IntuneUsers_CL)"
        Category = "Intune"
        Query = @"
IntuneUsers_CL
| summarize arg_max(TimeGenerated, *) by UserPrincipalName
"@
    },
    @{
        Name = "StaleDevices"
        DisplayName = "Stale Devices (14+ days)"
        Description = "Returns devices with no Intune sync AND no interactive user logon in 14+ days"
        Category = "Intune"
        Query = @"
IntuneDevices_CL
| summarize arg_max(TimeGenerated, *) by DeviceId
| extend LastSyncDaysAgo = datetime_diff('day', now(), todatetime(LastSyncDateTime))
| extend LastLogonDaysAgo = iff(isnotempty(LastLoggedOnDateTime),
    datetime_diff('day', now(), todatetime(LastLoggedOnDateTime)),
    int(null))
| extend StalestActivityDaysAgo = coalesce(
    iff(isnotempty(LastLoggedOnDateTime), LastLogonDaysAgo, int(null)),
    LastSyncDaysAgo)
| where LastSyncDaysAgo > 14
| project DeviceId, DeviceName, UserPrincipalName, LastSyncDateTime, LastSyncDaysAgo,
          LastLoggedOnDateTime, LastLogonDaysAgo, StalestActivityDaysAgo,
          Model, OperatingSystem, ComplianceState, JoinType
| order by StalestActivityDaysAgo desc
"@
    },
    @{
        Name = "OrphanedDevices"
        DisplayName = "Orphaned Devices"
        Description = "Returns devices whose primary user account is disabled in Entra ID - likely candidates for decommission"
        Category = "Intune"
        Query = @"
IntuneDevices_CL
| summarize arg_max(TimeGenerated, *) by DeviceId
| where isnotempty(UserPrincipalName)
| join kind=inner (
    IntuneUsers_CL
    | summarize arg_max(TimeGenerated, *) by UserPrincipalName
    | where AccountEnabled == false
    | project UserPrincipalName, Department, JobTitle, AccountEnabled
) on UserPrincipalName
| extend LastSyncDaysAgo = datetime_diff('day', now(), todatetime(LastSyncDateTime))
| project DeviceId, DeviceName, UserPrincipalName, Department, JobTitle,
          LastSyncDateTime, LastSyncDaysAgo, Model, OperatingSystem, ComplianceState
| order by LastSyncDaysAgo desc
"@
    },
    @{
        Name = "PoorHealthDevices"
        DisplayName = "Poor Health Devices"
        Description = "Returns devices with Endpoint Analytics score below 50"
        Category = "Intune"
        Query = @"
IntuneDeviceScores_CL
| summarize arg_max(TimeGenerated, *) by DeviceId
| where EndpointAnalyticsScore < 50
| project DeviceId, DeviceName, Model, Manufacturer, EndpointAnalyticsScore, StartupPerformanceScore, AppReliabilityScore, HealthStatus
"@
    }
)

Write-Host "Deploying $($functions.Count) functions to workspace $WorkspaceId..." -ForegroundColor Cyan

foreach ($func in $functions) {
    Write-Host "  Creating function: $($func.Name)..." -NoNewline
    
    try {
        # Create the saved search (function)
        $savedSearch = New-AzOperationalInsightsSavedSearch `
            -ResourceGroupName $ResourceGroup `
            -WorkspaceName $WorkspaceId `
            -SavedSearchId $func.Name `
            -DisplayName $func.DisplayName `
            -Category $func.Category `
            -Query $func.Query `
            -FunctionAlias $func.Name `
            -Force
        
        Write-Host " Done" -ForegroundColor Green
    }
    catch {
        Write-Host " Failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Usage examples:" -ForegroundColor Yellow
Write-Host "  LatestDevices | where OperatingSystem startswith 'Windows'"
Write-Host "  LatestCompliance | where StatusRaw == 4 | summarize count() by PolicyName"
Write-Host "  NonCompliantDevices | summarize count() by PolicyName"
Write-Host "  StaleDevices | order by LastSyncDaysAgo desc"
