<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to a service principal (app registration or managed identity).

.DESCRIPTION
    This script grants the required Graph API permissions for reading Intune data.
    Works with both app registrations and managed identities.

    Must be run by a user with one of the following Entra ID roles:
    - Global Administrator
    - Application Administrator
    - Cloud Application Administrator

.PARAMETER ServicePrincipalObjectId
    The Object ID of the service principal (app registration) or managed identity.
    For app registrations: Find this in Entra ID > App registrations > Your app > Overview > "Object ID" (not Application ID)
    For managed identities: The Principal ID from the managed identity resource.

.EXAMPLE
    # For app registration:
    .\Grant-GraphPermissions.ps1 -ServicePrincipalObjectId "12345678-1234-1234-1234-123456789012"

.EXAMPLE
    # For function app with managed identity:
    .\Grant-GraphPermissions.ps1 -FunctionAppName "intune-func-abc123" -ResourceGroupName "rg-intune"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ServicePrincipalObjectId,

    [Parameter(Mandatory = $false)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    # Legacy parameter alias for backwards compatibility
    [Parameter(Mandatory = $false)]
    [Alias("ManagedIdentityObjectId")]
    [string]$ObjectId
)

$ErrorActionPreference = "Stop"

# Handle legacy parameter
if ($ObjectId -and -not $ServicePrincipalObjectId) {
    $ServicePrincipalObjectId = $ObjectId
}

# Microsoft Graph App ID (constant)
$GraphAppId = "00000003-0000-0000-c000-000000000000"

# Required permissions
$RequiredPermissions = @(
    @{
        Name = "DeviceManagementManagedDevices.Read.All"
        Id = "dc377aa6-52d8-4e23-b271-2a7ae04cedf3"
        Description = "Read Intune device information"
    },
    @{
        Name = "DeviceManagementConfiguration.Read.All"
        Id = "5ac13192-7ace-4fcf-b828-1a26f28068ee"
        Description = "Read Intune compliance policies and endpoint analytics"
    },
    @{
        Name = "DeviceManagementServiceConfig.Read.All"
        Id = "06a5fe6d-c49d-46a7-b082-56b1b14103c7"
        Description = "Read Autopilot deployment profiles and device identities"
    }
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Intune Analytics - Grant Graph Permissions" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if Az module is available
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Azure PowerShell module (Az) is required. Install with: Install-Module -Name Az -Scope CurrentUser"
    exit 1
}

# Ensure connected to Azure
$context = Get-AzContext
if (-not $context) {
    Write-Host "Not connected to Azure. Please sign in..." -ForegroundColor Yellow
    Connect-AzAccount
    $context = Get-AzContext
}

Write-Host "Connected as: $($context.Account.Id)" -ForegroundColor Green
Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Green
Write-Host ""

# Get the service principal Object ID
if (-not $ServicePrincipalObjectId) {
    if (-not $FunctionAppName -or -not $ResourceGroupName) {
        Write-Error "Please provide -ServicePrincipalObjectId OR both -FunctionAppName and -ResourceGroupName"
        exit 1
    }

    Write-Host "Getting Function App identity..." -ForegroundColor Yellow
    $functionApp = Get-AzWebApp -Name $FunctionAppName -ResourceGroupName $ResourceGroupName

    if ($functionApp.Identity.PrincipalId) {
        $ServicePrincipalObjectId = $functionApp.Identity.PrincipalId
    } elseif ($functionApp.Identity.UserAssignedIdentities) {
        $ServicePrincipalObjectId = ($functionApp.Identity.UserAssignedIdentities.Values | Select-Object -First 1).PrincipalId
    } else {
        Write-Error "Function App '$FunctionAppName' does not have a managed identity"
        exit 1
    }
}

Write-Host "Service Principal Object ID: $ServicePrincipalObjectId" -ForegroundColor Cyan
Write-Host ""

# Get Microsoft Graph service principal
Write-Host "Getting Microsoft Graph service principal..." -ForegroundColor Yellow
$graphSp = Get-AzADServicePrincipal -ApplicationId $GraphAppId

if (-not $graphSp) {
    Write-Error "Could not find Microsoft Graph service principal."
    exit 1
}

Write-Host "Microsoft Graph SP ID: $($graphSp.Id)" -ForegroundColor Green
Write-Host ""

# Grant each permission
Write-Host "Granting permissions..." -ForegroundColor Yellow
Write-Host ""

$successCount = 0
$skipCount = 0
$errorCount = 0

foreach ($permission in $RequiredPermissions) {
    Write-Host "  $($permission.Name)" -ForegroundColor White -NoNewline
    Write-Host " - $($permission.Description)" -ForegroundColor Gray

    try {
        New-AzADServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $ServicePrincipalObjectId `
            -ResourceId $graphSp.Id `
            -AppRoleId $permission.Id `
            -ErrorAction Stop | Out-Null

        Write-Host "    + Granted" -ForegroundColor Green
        $successCount++
    }
    catch {
        if ($_.Exception.Message -like "*already exists*" -or $_.Exception.Message -like "*Permission being assigned already exists*") {
            Write-Host "    = Already assigned" -ForegroundColor DarkGray
            $skipCount++
        }
        else {
            Write-Host "    x Failed: $($_.Exception.Message)" -ForegroundColor Red
            $errorCount++
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Granted:  $successCount" -ForegroundColor Green
Write-Host "  Skipped:  $skipCount (already assigned)" -ForegroundColor DarkGray
Write-Host "  Failed:   $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($errorCount -eq 0) {
    Write-Host "Permissions configured successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "The app can now access Microsoft Graph to read Intune data." -ForegroundColor Gray
}
else {
    Write-Host "Some permissions could not be granted." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ensure you have one of these Entra ID roles:" -ForegroundColor Yellow
    Write-Host "  - Global Administrator" -ForegroundColor White
    Write-Host "  - Application Administrator" -ForegroundColor White
    Write-Host "  - Cloud Application Administrator" -ForegroundColor White
    exit 1
}
