<#
.SYNOPSIS
    Exports Endpoint Analytics data to ADX or Log Analytics.

.DESCRIPTION
    This runbook exports:
    - Device health scores
    - Startup performance history
    - App reliability metrics

    Runs daily at 8 AM via Azure Automation schedule.

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
# Export Device Health Scores
# ============================================================================

Write-Output "Fetching device health scores..."
$scores = @()

$uri = "https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsDeviceScores"
$response = Invoke-MgGraphRequest -Method GET -Uri $uri

foreach ($d in $response.value) {
    $scores += @{
        DeviceId = $d.deviceName  # Note: this is actually the device ID in this API
        DeviceName = $d.deviceName
        Model = $d.model
        Manufacturer = $d.manufacturer
        HealthStatus = $d.healthStatus
        EndpointAnalyticsScore = $d.endpointAnalyticsScore
        StartupPerformanceScore = $d.startupPerformanceScore
        AppReliabilityScore = $d.appReliabilityScore
        WorkFromAnywhereScore = $d.workFromAnywhereScore
        MeanResourceSpikeTimeScore = $d.meanResourceSpikeTimeScore
        BatteryHealthScore = $d.batteryHealthScore
        IngestionTime = (Get-Date).ToUniversalTime().ToString('o')
        SourceSystem = 'EndpointAnalytics'
    }
}

# Handle pagination
while ($response.'@odata.nextLink') {
    $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink'
    foreach ($d in $response.value) {
        $scores += @{
            DeviceId = $d.deviceName
            DeviceName = $d.deviceName
            Model = $d.model
            Manufacturer = $d.manufacturer
            HealthStatus = $d.healthStatus
            EndpointAnalyticsScore = $d.endpointAnalyticsScore
            StartupPerformanceScore = $d.startupPerformanceScore
            AppReliabilityScore = $d.appReliabilityScore
            WorkFromAnywhereScore = $d.workFromAnywhereScore
            MeanResourceSpikeTimeScore = $d.meanResourceSpikeTimeScore
            BatteryHealthScore = $d.batteryHealthScore
            IngestionTime = (Get-Date).ToUniversalTime().ToString('o')
            SourceSystem = 'EndpointAnalytics'
        }
    }
}

$count = Send-Data -Table 'DeviceScores' -StreamName 'Custom-IntuneDeviceScores_CL' -Data $scores
Write-Output "Ingested $count device scores"

# ============================================================================
# Export Startup Performance History
# ============================================================================

Write-Output "Fetching startup performance..."
$startup = @()

$uri = "https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsDeviceStartupHistory"
$response = Invoke-MgGraphRequest -Method GET -Uri $uri

foreach ($s in $response.value) {
    $startup += @{
        DeviceId = $s.deviceId
        StartTime = if ($s.startTime) { $s.startTime } else { $null }
        CoreBootTimeInMs = $s.coreBootTimeInMs
        GroupPolicyBootTimeInMs = $s.groupPolicyBootTimeInMs
        GroupPolicyLoginTimeInMs = $s.groupPolicyLoginTimeInMs
        CoreLoginTimeInMs = $s.coreLoginTimeInMs
        TotalBootTimeInMs = $s.totalBootTimeInMs
        TotalLoginTimeInMs = $s.totalLoginTimeInMs
        IsFirstLogin = $s.isFirstLogin
        IsFeatureUpdate = $s.isFeatureUpdate
        OperatingSystemVersion = $s.operatingSystemVersion
        RestartCategory = $s.restartCategory
        RestartFaultBucket = $s.restartFaultBucket
        IngestionTime = (Get-Date).ToUniversalTime().ToString('o')
        SourceSystem = 'EndpointAnalytics'
    }
}

# Handle pagination
while ($response.'@odata.nextLink') {
    $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink'
    foreach ($s in $response.value) {
        $startup += @{
            DeviceId = $s.deviceId
            StartTime = if ($s.startTime) { $s.startTime } else { $null }
            CoreBootTimeInMs = $s.coreBootTimeInMs
            GroupPolicyBootTimeInMs = $s.groupPolicyBootTimeInMs
            GroupPolicyLoginTimeInMs = $s.groupPolicyLoginTimeInMs
            CoreLoginTimeInMs = $s.coreLoginTimeInMs
            TotalBootTimeInMs = $s.totalBootTimeInMs
            TotalLoginTimeInMs = $s.totalLoginTimeInMs
            IsFirstLogin = $s.isFirstLogin
            IsFeatureUpdate = $s.isFeatureUpdate
            OperatingSystemVersion = $s.operatingSystemVersion
            RestartCategory = $s.restartCategory
            RestartFaultBucket = $s.restartFaultBucket
            IngestionTime = (Get-Date).ToUniversalTime().ToString('o')
            SourceSystem = 'EndpointAnalytics'
        }
    }
}

$count = Send-Data -Table 'StartupPerformance' -StreamName 'Custom-IntuneStartupPerformance_CL' -Data $startup
Write-Output "Ingested $count startup records"

# ============================================================================
# Export App Reliability
# ============================================================================

Write-Output "Fetching app reliability..."
$apps = @()

try {
    $uri = "https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsAppHealthApplicationPerformance"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri

    foreach ($a in $response.value) {
        $apps += @{
            AppName = $a.appName
            AppDisplayName = $a.appDisplayName
            AppPublisher = $a.appPublisher
            ActiveDeviceCount = $a.activeDeviceCount
            AppCrashCount = $a.appCrashCount
            AppHangCount = $a.appHangCount
            MeanTimeToFailureInMinutes = $a.meanTimeToFailureInMinutes
            AppHealthScore = $a.appHealthScore
            AppHealthStatus = $a.appHealthStatus
            IngestionTime = (Get-Date).ToUniversalTime().ToString('o')
            SourceSystem = 'EndpointAnalytics'
        }
    }

    # Handle pagination
    while ($response.'@odata.nextLink') {
        $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink'
        foreach ($a in $response.value) {
            $apps += @{
                AppName = $a.appName
                AppDisplayName = $a.appDisplayName
                AppPublisher = $a.appPublisher
                ActiveDeviceCount = $a.activeDeviceCount
                AppCrashCount = $a.appCrashCount
                AppHangCount = $a.appHangCount
                MeanTimeToFailureInMinutes = $a.meanTimeToFailureInMinutes
                AppHealthScore = $a.appHealthScore
                AppHealthStatus = $a.appHealthStatus
                IngestionTime = (Get-Date).ToUniversalTime().ToString('o')
                SourceSystem = 'EndpointAnalytics'
            }
        }
    }
} catch {
    Write-Warning "App reliability data not available: $_"
}

$count = Send-Data -Table 'AppReliability' -StreamName 'Custom-IntuneAppReliability_CL' -Data $apps
Write-Output "Ingested $count app reliability records"

# ============================================================================
# Summary
# ============================================================================

Write-Output ""
Write-Output "=== Export Complete ==="
Write-Output "Device Scores: $($scores.Count)"
Write-Output "Startup Records: $($startup.Count)"
Write-Output "App Reliability: $($apps.Count)"
