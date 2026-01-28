<#
.SYNOPSIS
    Manually trigger Intune data exports to Log Analytics.

.DESCRIPTION
    Provides an interactive menu to select which exports to run, or allows
    specifying exports via command line parameters.

.PARAMETER FunctionAppName
    Name of the Azure Function App. Default: graphreports-func

.PARAMETER FunctionKey
    The function key for authentication. If not provided, will attempt to retrieve from Azure.

.PARAMETER ResourceGroup
    Resource group containing the Function App. Default: ancIntuneReporting-Dev

.PARAMETER Export
    Specific export(s) to run. Valid values: devices, compliance, analytics, autopilot, all
    If not specified, shows interactive menu.

.PARAMETER TimeoutSeconds
    Timeout for each export request. Default: 300 (5 minutes)

.EXAMPLE
    .\Invoke-IntuneExport.ps1
    # Shows interactive menu

.EXAMPLE
    .\Invoke-IntuneExport.ps1 -Export devices
    # Run only device export

.EXAMPLE
    .\Invoke-IntuneExport.ps1 -Export devices,compliance
    # Run device and compliance exports

.EXAMPLE
    .\Invoke-IntuneExport.ps1 -Export all
    # Run all exports
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$FunctionAppName = "graphreports-func",

    [Parameter(Mandatory = $false)]
    [string]$FunctionKey,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = "ancIntuneReporting-Dev",

    [Parameter(Mandatory = $false)]
    [ValidateSet("devices", "compliance", "analytics", "autopilot", "all")]
    [string[]]$Export,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

# Export descriptions
$ExportInfo = @{
    devices    = @{ Name = "Device Inventory"; Table = "IntuneDevices_CL"; Description = "Managed device details from Intune" }
    compliance = @{ Name = "Compliance States"; Table = "IntuneCompliancePolicies_CL, IntuneComplianceStates_CL"; Description = "Compliance policies and per-device status" }
    analytics  = @{ Name = "Endpoint Analytics"; Table = "IntuneDeviceScores_CL, IntuneStartupPerformance_CL, IntuneAppReliability_CL"; Description = "Device scores, startup performance, app reliability" }
    autopilot  = @{ Name = "Autopilot"; Table = "IntuneAutopilotDevices_CL, IntuneAutopilotProfiles_CL"; Description = "Autopilot devices and deployment profiles" }
}

function Get-FunctionKey {
    param([string]$AppName, [string]$RG)
    
    try {
        # Try Az module first
        if (Get-Module -ListAvailable -Name Az.Functions) {
            Import-Module Az.Functions -ErrorAction SilentlyContinue
            $keys = Invoke-AzResourceAction -ResourceGroupName $RG -ResourceType "Microsoft.Web/sites" `
                -ResourceName $AppName -Action "host/default/listkeys" -ApiVersion "2022-03-01" -Force -ErrorAction Stop
            return $keys.functionKeys.default
        }
        
        # Fall back to Azure CLI
        $result = az functionapp keys list --name $AppName --resource-group $RG --query "functionKeys.default" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0) {
            return $result
        }
    } catch {
        # Silently fail - will prompt user
    }
    return $null
}

function Show-Menu {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " Intune Data Export" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Select exports to run:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [1] Devices      - Device inventory (~8,000+ records)" -ForegroundColor White
    Write-Host "  [2] Compliance   - Policies & device compliance (~13,000+ records)" -ForegroundColor White
    Write-Host "  [3] Analytics    - Endpoint analytics scores & performance" -ForegroundColor White
    Write-Host "  [4] Autopilot    - Autopilot devices & profiles" -ForegroundColor White
    Write-Host ""
    Write-Host "  [A] All          - Run all exports sequentially" -ForegroundColor Green
    Write-Host "  [Q] Quit         - Exit without running" -ForegroundColor DarkGray
    Write-Host ""
    
    $selection = Read-Host "Enter selection (e.g., 1,2 or A)"
    return $selection
}

function Invoke-Export {
    param(
        [string]$ExportType,
        [string]$BaseUrl,
        [string]$Key,
        [int]$Timeout
    )
    
    $info = $ExportInfo[$ExportType]
    Write-Host ""
    Write-Host "[$ExportType] $($info.Name)" -ForegroundColor Cyan
    Write-Host "  Tables: $($info.Table)" -ForegroundColor DarkGray
    Write-Host "  Running..." -NoNewline
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        $response = Invoke-RestMethod -Uri "$BaseUrl/$ExportType`?code=$Key" -Method POST -TimeoutSec $Timeout
        $stopwatch.Stop()
        
        $records = $response.records
        if ($null -eq $records) { $records = "N/A" }
        
        Write-Host " Done!" -ForegroundColor Green
        Write-Host "  Records: $records | Duration: $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green
        
        return @{
            Export   = $ExportType
            Status   = "Success"
            Records  = $records
            Duration = $stopwatch.Elapsed.TotalSeconds
            Message  = $response.message
        }
    }
    catch {
        $stopwatch.Stop()
        Write-Host " Failed!" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        
        return @{
            Export   = $ExportType
            Status   = "Failed"
            Records  = 0
            Duration = $stopwatch.Elapsed.TotalSeconds
            Error    = $_.Exception.Message
        }
    }
}

# Main script
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Intune Reporting - Data Export" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Function App: $FunctionAppName" -ForegroundColor White
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor DarkGray

# Get function key if not provided
if (-not $FunctionKey) {
    Write-Host ""
    Write-Host "Retrieving function key..." -ForegroundColor Yellow
    $FunctionKey = Get-FunctionKey -AppName $FunctionAppName -RG $ResourceGroup
    
    if (-not $FunctionKey) {
        Write-Host "Could not retrieve function key automatically." -ForegroundColor Yellow
        $FunctionKey = Read-Host "Enter function key"
        
        if (-not $FunctionKey) {
            Write-Error "Function key is required"
            exit 1
        }
    } else {
        Write-Host "Function key retrieved successfully" -ForegroundColor Green
    }
}

$baseUrl = "https://$FunctionAppName.azurewebsites.net/api/export"

# Determine what to export
$exportsToRun = @()

if ($Export) {
    # Use command line parameter
    if ($Export -contains "all") {
        $exportsToRun = @("devices", "compliance", "analytics", "autopilot")
    } else {
        $exportsToRun = $Export
    }
} else {
    # Interactive menu
    $selection = Show-Menu
    
    switch -Regex ($selection.ToUpper()) {
        "^Q$" {
            Write-Host "Exiting." -ForegroundColor Yellow
            exit 0
        }
        "^A$" {
            $exportsToRun = @("devices", "compliance", "analytics", "autopilot")
        }
        default {
            # Parse numeric selections (e.g., "1,2" or "1 2" or "12")
            $nums = $selection -replace '[^1-4]', '' -split '' | Where-Object { $_ }
            $mapping = @{ "1" = "devices"; "2" = "compliance"; "3" = "analytics"; "4" = "autopilot" }
            foreach ($n in $nums) {
                if ($mapping.ContainsKey($n)) {
                    $exportsToRun += $mapping[$n]
                }
            }
            $exportsToRun = $exportsToRun | Select-Object -Unique
        }
    }
}

if ($exportsToRun.Count -eq 0) {
    Write-Host "No valid exports selected. Exiting." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Exports to run: $($exportsToRun -join ', ')" -ForegroundColor Cyan

# Run exports
$results = @()
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($export in $exportsToRun) {
    $result = Invoke-Export -ExportType $export -BaseUrl $baseUrl -Key $FunctionKey -Timeout $TimeoutSeconds
    $results += $result
}

$totalStopwatch.Stop()

# Summary
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

$successCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
$failCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count
$totalRecords = ($results | Where-Object { $_.Records -ne "N/A" } | Measure-Object -Property Records -Sum).Sum

foreach ($r in $results) {
    $statusColor = if ($r.Status -eq "Success") { "Green" } else { "Red" }
    $statusIcon = if ($r.Status -eq "Success") { "[OK]" } else { "[X]" }
    Write-Host "  $statusIcon $($r.Export): $($r.Records) records ($([math]::Round($r.Duration, 1))s)" -ForegroundColor $statusColor
}

Write-Host ""
Write-Host "  Total: $totalRecords records | $([math]::Round($totalStopwatch.Elapsed.TotalSeconds, 1))s" -ForegroundColor White
Write-Host "  Success: $successCount | Failed: $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
Write-Host ""

# Return results for pipeline usage
return $results
