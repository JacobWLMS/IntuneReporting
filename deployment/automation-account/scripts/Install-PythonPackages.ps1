#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Installs Python packages into an Azure Automation Account Runtime Environment from PyPI.

.DESCRIPTION
    This script creates a Runtime Environment (if needed) and installs Python packages
    by name from PyPI. It automatically resolves wheel URLs from PyPI.

.PARAMETER SubscriptionId
    Azure Subscription ID

.PARAMETER ResourceGroupName
    Resource Group containing the Automation Account

.PARAMETER AutomationAccountName
    Name of the Automation Account

.PARAMETER RuntimeEnvironmentName
    Name of the Runtime Environment to create/use

.PARAMETER Packages
    Array of package names to install (e.g., 'azure-identity', 'msgraph-beta-sdk')

.EXAMPLE
    ./Install-PythonPackages.ps1 -SubscriptionId "xxx" -ResourceGroupName "rg" `
        -AutomationAccountName "auto" -RuntimeEnvironmentName "Python310-Intune" `
        -Packages @('azure-identity', 'msgraph-beta-sdk', 'azure-monitor-ingestion')
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [string]$RuntimeEnvironmentName,

    [Parameter(Mandatory = $true)]
    [string[]]$Packages
)

$ErrorActionPreference = 'Stop'

# Get access token
Write-Host "Getting Azure access token..." -ForegroundColor Cyan
$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
$headers = @{
    'Authorization' = "Bearer $token"
    'Content-Type'  = 'application/json'
}

$baseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
$apiVersion = "2024-10-23"

# Function to get wheel URL from PyPI
function Get-PyPIWheelUrl {
    param([string]$PackageName)
    
    $normalizedName = $PackageName.ToLower() -replace '_', '-'
    $pypiUrl = "https://pypi.org/pypi/$normalizedName/json"
    
    try {
        $response = Invoke-RestMethod -Uri $pypiUrl -Method Get -TimeoutSec 30
        
        # Find the best wheel (py3-none-any preferred, then cp310)
        $wheel = $response.urls | Where-Object { 
            $_.packagetype -eq 'bdist_wheel' -and 
            ($_.filename -match 'py3-none-any\.whl$' -or $_.filename -match 'cp310.*linux.*\.whl$')
        } | Sort-Object { 
            # Prefer py3-none-any over platform-specific
            if ($_.filename -match 'py3-none-any') { 0 } else { 1 }
        } | Select-Object -First 1
        
        if ($wheel) {
            return @{
                Name    = $normalizedName -replace '-', '_'
                Version = $response.info.version
                Url     = $wheel.url
            }
        }
        
        Write-Warning "No suitable wheel found for $PackageName"
        return $null
    }
    catch {
        Write-Warning "Failed to get package info for $PackageName : $_"
        return $null
    }
}

# Create Runtime Environment
Write-Host "`nCreating Runtime Environment '$RuntimeEnvironmentName'..." -ForegroundColor Cyan
$runtimeEnvUrl = "$baseUrl/runtimeEnvironments/$RuntimeEnvironmentName`?api-version=$apiVersion"

$runtimeEnvBody = @{
    properties = @{
        runtime = @{
            language = "Python"
            version  = "3.10"
        }
        description = "Runtime environment for Intune reporting runbooks"
    }
    name = $RuntimeEnvironmentName
} | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod -Uri $runtimeEnvUrl -Method Put -Headers $headers -Body $runtimeEnvBody
    Write-Host "  Runtime Environment created/updated successfully" -ForegroundColor Green
}
catch {
    if ($_.Exception.Response.StatusCode -eq 'Conflict') {
        Write-Host "  Runtime Environment already exists" -ForegroundColor Yellow
    }
    else {
        throw $_
    }
}

# Install packages
Write-Host "`nInstalling packages..." -ForegroundColor Cyan

foreach ($package in $Packages) {
    Write-Host "  Processing $package..." -ForegroundColor White
    
    $pkgInfo = Get-PyPIWheelUrl -PackageName $package
    if (-not $pkgInfo) {
        Write-Warning "  Skipping $package - could not resolve"
        continue
    }
    
    Write-Host "    Found: $($pkgInfo.Name) v$($pkgInfo.Version)" -ForegroundColor Gray
    
    $packageUrl = "$baseUrl/runtimeEnvironments/$RuntimeEnvironmentName/packages/$($pkgInfo.Name)`?api-version=$apiVersion"
    
    $packageBody = @{
        properties = @{
            contentLink = @{
                uri = $pkgInfo.Url
            }
        }
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri $packageUrl -Method Put -Headers $headers -Body $packageBody
        Write-Host "    Queued for installation" -ForegroundColor Green
    }
    catch {
        $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($errorMessage.error.code -eq 'Conflict') {
            Write-Host "    Already installed" -ForegroundColor Yellow
        }
        else {
            Write-Warning "    Failed: $($_.Exception.Message)"
        }
    }
    
    # Small delay to avoid rate limiting
    Start-Sleep -Milliseconds 500
}

Write-Host "`nPackage installation queued. Packages may take several minutes to complete." -ForegroundColor Cyan
Write-Host "Check the Runtime Environment in the Azure portal to monitor progress." -ForegroundColor Cyan
