<#
.SYNOPSIS
    Grants required Azure role assignments for the Intune Analytics Function App.

.DESCRIPTION
    This script grants the necessary Azure RBAC roles to the Function App's managed identity:
    - Storage Blob Data Owner on the storage account (required for identity-based storage auth)
    - Monitoring Metrics Publisher on the DCR (required for Log Analytics backend only)

    Run this script if you deployed with createRoleAssignments=false, or if the deployment
    failed due to missing permissions.

.PARAMETER ResourceGroupName
    The name of the resource group containing the deployed resources.

.PARAMETER ManagedIdentityName
    The name of the user-assigned managed identity (optional - will auto-detect if not provided).

.PARAMETER Backend
    The analytics backend: 'ADX' or 'LogAnalytics'. Determines which role assignments to create.

.EXAMPLE
    .\Grant-AzureRoles.ps1 -ResourceGroupName "rg-intune-analytics"

.EXAMPLE
    .\Grant-AzureRoles.ps1 -ResourceGroupName "rg-intune-analytics" -Backend "LogAnalytics"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$ManagedIdentityName,

    [Parameter()]
    [ValidateSet('ADX', 'LogAnalytics')]
    [string]$Backend = 'ADX'
)

$ErrorActionPreference = "Stop"

Write-Host "🔐 Granting Azure role assignments for Intune Analytics..." -ForegroundColor Cyan
Write-Host "   Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "   Backend: $Backend" -ForegroundColor Gray

# Check if logged in to Azure
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "⚠️  Not logged in to Azure. Running Connect-AzAccount..." -ForegroundColor Yellow
        Connect-AzAccount
    }
    Write-Host "   Subscription: $($context.Subscription.Name)" -ForegroundColor Gray
} catch {
    Write-Error "Failed to connect to Azure. Please run Connect-AzAccount first."
    exit 1
}

# Find the managed identity
Write-Host "`n📋 Finding managed identity..." -ForegroundColor Cyan

if ($ManagedIdentityName) {
    $mi = Get-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName -Name $ManagedIdentityName -ErrorAction SilentlyContinue
} else {
    # Auto-detect: find managed identity in resource group
    $identities = Get-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($identities.Count -eq 0) {
        Write-Error "No managed identities found in resource group '$ResourceGroupName'."
        exit 1
    } elseif ($identities.Count -gt 1) {
        Write-Host "   Multiple managed identities found. Please specify -ManagedIdentityName:" -ForegroundColor Yellow
        $identities | ForEach-Object { Write-Host "     - $($_.Name)" -ForegroundColor Gray }
        exit 1
    }
    $mi = $identities[0]
}

if (-not $mi) {
    Write-Error "Managed identity not found."
    exit 1
}

Write-Host "   ✓ Found: $($mi.Name)" -ForegroundColor Green
Write-Host "   Principal ID: $($mi.PrincipalId)" -ForegroundColor Gray

# Find the storage account
Write-Host "`n📦 Finding storage account..." -ForegroundColor Cyan
$storageAccounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName
if ($storageAccounts.Count -eq 0) {
    Write-Error "No storage accounts found in resource group."
    exit 1
}
$storage = $storageAccounts | Where-Object { $_.StorageAccountName -notlike "*diag*" } | Select-Object -First 1
Write-Host "   ✓ Found: $($storage.StorageAccountName)" -ForegroundColor Green

# Grant Storage Blob Data Owner role
Write-Host "`n🔑 Granting Storage Blob Data Owner role..." -ForegroundColor Cyan
$storageBlobDataOwnerRoleId = "b7e6dc6d-f1e8-4753-8033-0f276bb0955b"

try {
    $existingAssignment = Get-AzRoleAssignment -ObjectId $mi.PrincipalId -RoleDefinitionId $storageBlobDataOwnerRoleId -Scope $storage.Id -ErrorAction SilentlyContinue
    if ($existingAssignment) {
        Write-Host "   ✓ Role already assigned" -ForegroundColor Green
    } else {
        New-AzRoleAssignment -ObjectId $mi.PrincipalId -RoleDefinitionId $storageBlobDataOwnerRoleId -Scope $storage.Id | Out-Null
        Write-Host "   ✓ Role assigned successfully" -ForegroundColor Green
    }
} catch {
    if ($_.Exception.Message -like "*already exists*") {
        Write-Host "   ✓ Role already assigned" -ForegroundColor Green
    } else {
        Write-Error "Failed to assign Storage Blob Data Owner role: $_"
        exit 1
    }
}

# For Log Analytics backend, also grant Monitoring Metrics Publisher on DCR
if ($Backend -eq 'LogAnalytics') {
    Write-Host "`n📊 Finding Data Collection Rule..." -ForegroundColor Cyan
    
    # Find DCR in resource group
    $dcrs = Get-AzDataCollectionRule -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($dcrs.Count -eq 0) {
        Write-Warning "No Data Collection Rules found. Skipping DCR role assignment."
    } else {
        $dcr = $dcrs | Select-Object -First 1
        Write-Host "   ✓ Found: $($dcr.Name)" -ForegroundColor Green
        
        Write-Host "`n🔑 Granting Monitoring Metrics Publisher role on DCR..." -ForegroundColor Cyan
        $monitoringMetricsPublisherRoleId = "3913510d-42f4-4e42-8a64-420c390055eb"
        
        try {
            $existingAssignment = Get-AzRoleAssignment -ObjectId $mi.PrincipalId -RoleDefinitionId $monitoringMetricsPublisherRoleId -Scope $dcr.Id -ErrorAction SilentlyContinue
            if ($existingAssignment) {
                Write-Host "   ✓ Role already assigned" -ForegroundColor Green
            } else {
                New-AzRoleAssignment -ObjectId $mi.PrincipalId -RoleDefinitionId $monitoringMetricsPublisherRoleId -Scope $dcr.Id | Out-Null
                Write-Host "   ✓ Role assigned successfully" -ForegroundColor Green
            }
        } catch {
            if ($_.Exception.Message -like "*already exists*") {
                Write-Host "   ✓ Role already assigned" -ForegroundColor Green
            } else {
                Write-Error "Failed to assign Monitoring Metrics Publisher role: $_"
                exit 1
            }
        }
    }
}

Write-Host "`n✅ Azure role assignments complete!" -ForegroundColor Green
Write-Host ""
Write-Host "⚠️  Don't forget to also run Grant-GraphPermissions.ps1 to grant Microsoft Graph API permissions." -ForegroundColor Yellow
Write-Host "   .\scripts\Grant-GraphPermissions.ps1 -ManagedIdentityObjectId `"$($mi.PrincipalId)`"" -ForegroundColor Gray
