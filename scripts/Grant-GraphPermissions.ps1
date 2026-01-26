<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to the Intune Analytics Function App managed identity.

.DESCRIPTION
    This script must be run by a user with one of the following roles:
    - Global Administrator
    - Application Administrator  
    - Cloud Application Administrator

    Run this AFTER deploying the ARM template.

.PARAMETER FunctionAppName
    The name of the deployed Function App (shown in deployment outputs)

.PARAMETER ResourceGroupName
    The resource group containing the Function App

.EXAMPLE
    .\Grant-GraphPermissions.ps1 -FunctionAppName "intune-analytics-fn-abc123" -ResourceGroupName "rg-intune-analytics"

.EXAMPLE
    # Or use the managed identity Object ID directly:
    .\Grant-GraphPermissions.ps1 -ManagedIdentityObjectId "12345678-1234-1234-1234-123456789012"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ManagedIdentityObjectId
)

$ErrorActionPreference = "Stop"

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
        Id = "dc377aa6-52d8-4e23-b271-2a7ae6b159e6"
        Description = "Read Intune compliance policies"
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

# Get the managed identity Object ID
if (-not $ManagedIdentityObjectId) {
    if (-not $FunctionAppName -or -not $ResourceGroupName) {
        Write-Error "Please provide either -ManagedIdentityObjectId OR both -FunctionAppName and -ResourceGroupName"
        exit 1
    }

    Write-Host "Getting Function App managed identity..." -ForegroundColor Yellow
    $functionApp = Get-AzWebApp -Name $FunctionAppName -ResourceGroupName $ResourceGroupName
    
    if (-not $functionApp.Identity.PrincipalId) {
        Write-Error "Function App '$FunctionAppName' does not have a system-assigned managed identity enabled"
        exit 1
    }
    
    $ManagedIdentityObjectId = $functionApp.Identity.PrincipalId
}

Write-Host "Managed Identity Object ID: $ManagedIdentityObjectId" -ForegroundColor Cyan
Write-Host ""

# Get Microsoft Graph service principal
Write-Host "Getting Microsoft Graph service principal..." -ForegroundColor Yellow
$graphSp = Get-AzADServicePrincipal -ApplicationId $GraphAppId

if (-not $graphSp) {
    Write-Error "Could not find Microsoft Graph service principal. This should not happen."
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
            -ServicePrincipalId $ManagedIdentityObjectId `
            -ResourceId $graphSp.Id `
            -AppRoleId $permission.Id `
            -ErrorAction Stop | Out-Null
        
        Write-Host "    ✓ Granted" -ForegroundColor Green
        $successCount++
    }
    catch {
        if ($_.Exception.Message -like "*already exists*" -or $_.Exception.Message -like "*Permission being assigned already exists*") {
            Write-Host "    ○ Already assigned" -ForegroundColor DarkGray
            $skipCount++
        }
        else {
            Write-Host "    ✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
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
    Write-Host "✓ Permissions configured successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "The Function App can now access Microsoft Graph to read Intune data." -ForegroundColor Gray
    Write-Host "Data collection will begin on the next timer trigger (every 6 hours)." -ForegroundColor Gray
}
else {
    Write-Host "✗ Some permissions could not be granted." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ensure you have one of these Entra ID roles:" -ForegroundColor Yellow
    Write-Host "  - Global Administrator" -ForegroundColor White
    Write-Host "  - Application Administrator" -ForegroundColor White
    Write-Host "  - Cloud Application Administrator" -ForegroundColor White
    exit 1
}
