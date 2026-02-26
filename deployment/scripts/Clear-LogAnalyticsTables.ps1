<#
.SYNOPSIS
    Clears data from custom Log Analytics tables.

.DESCRIPTION
    Deletes all data from the Intune Reporting custom tables in Log Analytics.
    Uses the Azure REST API with async operation tracking.
    
    Note: The API requires at least one filter, so we use a TimeGenerated filter
    with a very wide date range (2020-01-01 to 2099-12-31) to match all records.
    
    Requires: Az PowerShell module, logged in with appropriate permissions.

.PARAMETER ResourceGroup
    Resource group containing the Log Analytics workspace.

.PARAMETER Workspace
    Name of the Log Analytics workspace.

.PARAMETER Tables
    Array of table names to clear. Defaults to all Intune Reporting tables.

.PARAMETER PollIntervalSeconds
    Seconds between status polls when using -WaitForCompletion. Default: 30

.PARAMETER Force
    Skip the confirmation prompt. USE WITH CAUTION.

.EXAMPLE
    .\Clear-LogAnalyticsTables.ps1 -ResourceGroup "ancIntuneReporting-Dev" -Workspace "graphreports-law"

.EXAMPLE
    .\Clear-LogAnalyticsTables.ps1 -ResourceGroup "rg-intune" -Workspace "law-intune" -WaitForCompletion

.EXAMPLE
    # Clear specific tables only (with confirmation prompt)
    .\Clear-LogAnalyticsTables.ps1 -ResourceGroup "rg-intune" -Workspace "law-intune" -Tables @("IntuneManagedDevices_CL", "IntuneComplianceStates_CL")

.EXAMPLE
    # Skip confirmation (for automation)
    .\Clear-LogAnalyticsTables.ps1 -ResourceGroup "rg-intune" -Workspace "law-intune" -Force -WaitForCompletion
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [Parameter(Mandatory = $false)]
    [string[]]$Tables = @(
        "IntuneManagedDevices_CL",
        "IntuneUsers_CL",
        "IntuneCompliancePolicies_CL",
        "IntuneComplianceStates_CL",
        "IntuneDeviceScores_CL",
        "IntuneStartupPerformance_CL",
        "IntuneAppReliability_CL",
        "IntuneAutopilotDevices_CL",
        "IntuneAutopilotProfiles_CL",
        "IntuneSyncState_CL"
    ),

    [Parameter(Mandatory = $false)]
    [switch]$WaitForCompletion,

    [Parameter(Mandatory = $false)]
    [int]$PollIntervalSeconds = 30,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Clear Log Analytics Tables" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Check Az module
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Az PowerShell module required. Install with: Install-Module -Name Az -Scope CurrentUser"
    exit 1
}

Import-Module Az.OperationalInsights -ErrorAction SilentlyContinue

# Check logged in
$context = Get-AzContext
if (-not $context) {
    Write-Host "Not logged in to Azure. Please sign in..." -ForegroundColor Yellow
    Connect-AzAccount
    $context = Get-AzContext
}

$subscriptionId = $context.Subscription.Id

# SAFETY CHECK: Verify the workspace exists and get its details
Write-Host "Verifying workspace..." -ForegroundColor Yellow
try {
    $workspaceObj = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup -Name $Workspace -ErrorAction Stop
} catch {
    Write-Error "Workspace '$Workspace' not found in resource group '$ResourceGroup'. Aborting."
    exit 1
}

$workspaceId = $workspaceObj.CustomerId
$workspaceLocation = $workspaceObj.Location

Write-Host ""
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " TARGET WORKSPACE DETAILS" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "  Subscription:    $($context.Subscription.Name)" -ForegroundColor White
Write-Host "  Subscription ID: $subscriptionId" -ForegroundColor DarkGray
Write-Host "  Resource Group:  $ResourceGroup" -ForegroundColor White
Write-Host "  Workspace Name:  $Workspace" -ForegroundColor White
Write-Host "  Workspace ID:    $workspaceId" -ForegroundColor DarkGray
Write-Host "  Location:        $workspaceLocation" -ForegroundColor DarkGray
Write-Host "  Tables to clear: $($Tables.Count)" -ForegroundColor White
Write-Host ""
Write-Host "  Tables:" -ForegroundColor Cyan
foreach ($t in $Tables) {
    Write-Host "    - $t" -ForegroundColor White
}
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

# Confirmation prompt unless -Force is specified
if (-not $Force) {
    Write-Host "WARNING: This will DELETE ALL DATA from the tables listed above!" -ForegroundColor Red
    Write-Host "This action CANNOT be undone." -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "Type the workspace name '$Workspace' to confirm deletion"
    
    if ($confirm -ne $Workspace) {
        Write-Host "Confirmation failed. Aborting." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# Get access token
$tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
$token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenResponse.Token)
)

$headers = @{
    Authorization  = "Bearer $token"
    "Content-Type" = "application/json"
}

# API version that supports deleteData operation
$apiVersion = "2023-09-01"

# Body with TimeGenerated filter to match ALL data (API requires at least one filter)
# Using a very wide date range to capture everything
$body = @{
    filters = @(
        @{
            column   = "TimeGenerated"
            operator = ">="
            value    = "2020-01-01T00:00:00Z"
        }
    )
} | ConvertTo-Json -Depth 3

# Track operations for polling
$operations = @()

Write-Host "Initiating delete operations..." -ForegroundColor Yellow
Write-Host ""

foreach ($tableName in $Tables) {
    Write-Host "  $tableName" -NoNewline
    
    $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$Workspace/tables/$tableName/deleteData?api-version=$apiVersion"
    
    try {
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
        
        # Get operation tracking URL
        $operationUrl = $response.Headers["Azure-AsyncOperation"]
        if (-not $operationUrl) {
            $operationUrl = $response.Headers["Location"]
        }
        
        if ($operationUrl) {
            $operations += @{
                Table = $tableName
                Url   = $operationUrl[0]
            }
            Write-Host " - initiated" -ForegroundColor Green
        } else {
            Write-Host " - initiated (no tracking)" -ForegroundColor Green
        }
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorMsg = ""
        
        if ($_.ErrorDetails.Message) {
            try {
                $errorDetails = $_.ErrorDetails.Message | ConvertFrom-Json
                $errorMsg = $errorDetails.error.message
            } catch {
                $errorMsg = $_.ErrorDetails.Message
            }
        }
        
        switch ($statusCode) {
            404 { Write-Host " - table not found" -ForegroundColor DarkGray }
            403 { Write-Host " - access denied" -ForegroundColor Red }
            default { Write-Host " - error ($statusCode): $errorMsg" -ForegroundColor Red }
        }
    }
}

Write-Host ""

# Poll for completion if requested or always poll (operations are async)
if ($operations.Count -gt 0) {
    if ($WaitForCompletion) {
        Write-Host "Waiting for operations to complete..." -ForegroundColor Yellow
        Write-Host "(Polling every $PollIntervalSeconds seconds)" -ForegroundColor DarkGray
        Write-Host ""
    } else {
        Write-Host "Delete operations initiated. Use -WaitForCompletion to track status." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To verify later, run this query in Log Analytics:" -ForegroundColor Cyan
        Write-Host "  IntuneManagedDevices_CL | count" -ForegroundColor White
        Write-Host ""
        exit 0
    }
    
    $pending = [System.Collections.ArrayList]@($operations)
    
    while ($pending.Count -gt 0) {
        Start-Sleep -Seconds $PollIntervalSeconds
        
        $toRemove = @()
        
        foreach ($op in $pending) {
            try {
                $statusResponse = Invoke-RestMethod -Uri $op.Url -Headers $headers -Method Get
                $status = $statusResponse.status
                
                if ($status -eq "Succeeded") {
                    Write-Host "  $($op.Table) - completed successfully" -ForegroundColor Green
                    $toRemove += $op
                } elseif ($status -eq "Failed") {
                    $errorMsg = $statusResponse.error.message
                    Write-Host "  $($op.Table) - FAILED: $errorMsg" -ForegroundColor Red
                    $toRemove += $op
                } else {
                    Write-Host "  $($op.Table) - $status..." -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "  $($op.Table) - error checking status" -ForegroundColor Yellow
            }
        }
        
        # Remove completed operations
        foreach ($r in $toRemove) {
            $pending.Remove($r) | Out-Null
        }
        
        if ($pending.Count -gt 0) {
            Write-Host "  ($($pending.Count) operations still running...)" -ForegroundColor DarkGray
        }
    }
    
    Write-Host ""
    Write-Host "All operations completed!" -ForegroundColor Green
}

Write-Host ""
