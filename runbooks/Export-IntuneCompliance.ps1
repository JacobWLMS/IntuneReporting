<#
.SYNOPSIS
    Exports Intune device compliance data to ADX or Log Analytics.

.DESCRIPTION
    This runbook exports:
    - Managed devices
    - Compliance policies
    - Per-device compliance states

    Runs every 6 hours via Azure Automation schedule.

.NOTES
    Requires Microsoft.Graph.DeviceManagement module
    Requires managed identity with Graph API permissions
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement

$ErrorActionPreference = "Stop"

# ============================================================================
# Configuration
# ============================================================================

$Backend = Get-AutomationVariable -Name 'AnalyticsBackend'
Write-Output "Analytics Backend: $Backend"

if ($Backend -eq 'ADX') {
    $AdxCluster = Get-AutomationVariable -Name 'AdxClusterUri'
    $AdxDatabase = Get-AutomationVariable -Name 'AdxDatabase'
    Write-Output "ADX Cluster: $AdxCluster"
    Write-Output "ADX Database: $AdxDatabase"
} else {
    $LaWorkspace = Get-AutomationVariable -Name 'LogAnalyticsWorkspaceId'
    $LaDce = Get-AutomationVariable -Name 'LogAnalyticsDce'
    $LaDcrId = Get-AutomationVariable -Name 'LogAnalyticsDcrId'
    Write-Output "Log Analytics Workspace: $LaWorkspace"
}

# ============================================================================
# Helper Functions
# ============================================================================

function Send-ToAdx {
    param(
        [string]$Table,
        [array]$Data
    )

    if ($Data.Count -eq 0) { return 0 }

    # Convert to JSON lines format
    $jsonLines = $Data | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }
    $body = $jsonLines -join "`n"

    # Get access token for ADX
    $token = (Get-AzAccessToken -ResourceUrl $AdxCluster).Token

    # Ingest to ADX
    $ingestUri = $AdxCluster -replace 'https://', 'https://ingest-'
    $uri = "$ingestUri/v1/rest/ingest/$AdxDatabase/$Table`?streamFormat=json"

    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body

    return $Data.Count
}

function Send-ToLogAnalytics {
    param(
        [string]$StreamName,
        [array]$Data
    )

    if ($Data.Count -eq 0) { return 0 }

    # Add TimeGenerated to each record
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $Data | ForEach-Object { $_['TimeGenerated'] = $now }

    # Get access token for Monitor
    $token = (Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com').Token

    $uri = "$LaDce/dataCollectionRules/$LaDcrId/streams/$StreamName`?api-version=2023-01-01"

    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    $body = $Data | ConvertTo-Json -Depth 10

    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body

    return $Data.Count
}

function Send-Data {
    param(
        [string]$Table,
        [string]$StreamName,
        [array]$Data
    )

    if ($Backend -eq 'ADX') {
        return Send-ToAdx -Table $Table -Data $Data
    } else {
        return Send-ToLogAnalytics -StreamName $StreamName -Data $Data
    }
}

# ============================================================================
# Connect to Graph API
# ============================================================================

Write-Output "Connecting to Microsoft Graph..."
Connect-MgGraph -Identity -NoWelcome
Write-Output "Connected successfully"

# ============================================================================
# Export Managed Devices
# ============================================================================

Write-Output "Fetching managed devices..."
$devices = @()
$response = Get-MgDeviceManagementManagedDevice -All

foreach ($d in $response) {
    $devices += @{
        DeviceId = $d.Id
        DeviceName = $d.DeviceName
        UserId = $d.UserId
        UserPrincipalName = $d.UserPrincipalName
        UserDisplayName = $d.UserDisplayName
        OperatingSystem = $d.OperatingSystem
        OSVersion = $d.OsVersion
        ComplianceState = $d.ComplianceState.ToString()
        ManagementAgent = $d.ManagementAgent.ToString()
        EnrolledDateTime = $d.EnrolledDateTime.ToString('o')
        LastSyncDateTime = $d.LastSyncDateTime.ToString('o')
        Model = $d.Model
        Manufacturer = $d.Manufacturer
        SerialNumber = $d.SerialNumber
        IsEncrypted = $d.IsEncrypted
        IsSupervised = $d.IsSupervised
        AzureADDeviceId = $d.AzureADDeviceId
        IngestionTime = (Get-Date).ToUniversalTime().ToString('o')
        SourceSystem = 'GraphAPI'
    }
}

$count = Send-Data -Table 'ManagedDevices' -StreamName 'Custom-IntuneDevices_CL' -Data $devices
Write-Output "Ingested $count devices"

# ============================================================================
# Export Compliance Policies
# ============================================================================

Write-Output "Fetching compliance policies..."
$policies = @()
$response = Get-MgDeviceManagementDeviceCompliancePolicy -All

foreach ($p in $response) {
    $policies += @{
        PolicyId = $p.Id
        PolicyName = $p.DisplayName
        Description = $p.Description
        CreatedDateTime = $p.CreatedDateTime.ToString('o')
        LastModifiedDateTime = $p.LastModifiedDateTime.ToString('o')
        PolicyType = $p.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', ''
        IngestionTime = (Get-Date).ToUniversalTime().ToString('o')
        SourceSystem = 'GraphAPI'
    }
}

$count = Send-Data -Table 'CompliancePolicies' -StreamName 'Custom-IntuneCompliancePolicies_CL' -Data $policies
Write-Output "Ingested $count policies"

# ============================================================================
# Export Compliance States (per device per policy)
# ============================================================================

Write-Output "Fetching compliance states..."
$allStates = @()

$statusMap = @{
    1 = 'unknown'
    2 = 'compliant'
    3 = 'inGracePeriod'
    4 = 'noncompliant'
    5 = 'error'
    6 = 'conflict'
    7 = 'notApplicable'
}

foreach ($policy in $policies) {
    Write-Output "  Processing: $($policy.PolicyName)"

    # Use Reports API for compliance states
    $body = @{
        filter = "(PolicyId eq '$($policy.PolicyId)')"
        select = @()
        skip = 0
        top = 1000
        orderBy = @()
    } | ConvertTo-Json

    $uri = "https://graph.microsoft.com/beta/deviceManagement/reports/getDeviceStatusByCompliacePolicyReport"

    try {
        $response = Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType 'application/json'

        if ($response.Values) {
            $columns = $response.Schema | ForEach-Object { $_.Name }

            foreach ($row in $response.Values) {
                $record = @{}
                for ($i = 0; $i -lt $columns.Count; $i++) {
                    $record[$columns[$i]] = $row[$i]
                }

                $allStates += @{
                    DeviceId = $record.DeviceId
                    DeviceName = $record.DeviceName
                    UserId = $record.UserId
                    UserPrincipalName = $record.UPN
                    PolicyId = $record.PolicyId
                    PolicyName = $record.PolicyName
                    Status = $statusMap[[int]$record.Status]
                    StatusRaw = $record.Status
                    SettingCount = $record.SettingCount
                    FailedSettingCount = $record.FailedSettingCount
                    LastContact = $record.LastContact
                    InGracePeriodCount = $record.InGracePeriodCount
                    IngestionTime = (Get-Date).ToUniversalTime().ToString('o')
                    SourceSystem = 'GraphAPI'
                }
            }
        }
    } catch {
        Write-Warning "Failed to get compliance states for policy $($policy.PolicyName): $_"
    }
}

$count = Send-Data -Table 'DeviceComplianceStates' -StreamName 'Custom-IntuneComplianceStates_CL' -Data $allStates
Write-Output "Ingested $count compliance states"

# ============================================================================
# Summary
# ============================================================================

Write-Output ""
Write-Output "=== Export Complete ==="
Write-Output "Devices: $($devices.Count)"
Write-Output "Policies: $($policies.Count)"
Write-Output "Compliance States: $($allStates.Count)"
