#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Post-deployment script to set up Runtime Environment and install packages.

.DESCRIPTION
    This script runs after the main Bicep deployment to:
    1. Create a custom Runtime Environment (Python 3.10)
    2. Install required packages from PyPI
    3. Link runbooks to the Runtime Environment

.PARAMETER AutomationAccountName
    Name of the deployed Automation Account

.PARAMETER ResourceGroupName
    Resource Group name

.PARAMETER RuntimeEnvironmentName
    Name for the Runtime Environment (default: IntuneExport-Python310)

.PARAMETER AnalyticsBackend
    Backend type: LogAnalytics or ADX
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$RuntimeEnvironmentName = "IntuneExport-Python310",

    [ValidateSet('LogAnalytics', 'ADX')]
    [string]$AnalyticsBackend = 'LogAnalytics'
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Intune Export - Runtime Environment Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Ensure logged in
$context = Get-AzContext
if (-not $context) {
    throw "Please run Connect-AzAccount first"
}

$subscriptionId = $context.Subscription.Id
Write-Host "Subscription: $subscriptionId" -ForegroundColor Gray
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "Automation Account: $AutomationAccountName" -ForegroundColor Gray
Write-Host "Runtime Environment: $RuntimeEnvironmentName" -ForegroundColor Gray
Write-Host "Analytics Backend: $AnalyticsBackend" -ForegroundColor Gray

# Get access token
$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
$headers = @{
    'Authorization' = "Bearer $token"
    'Content-Type'  = 'application/json'
}

$baseUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
$apiVersion = "2024-10-23"

# Function to get wheel URL from PyPI
function Get-PyPIWheelUrl {
    param([string]$PackageName)
    
    $normalizedName = $PackageName.ToLower() -replace '_', '-'
    $pypiUrl = "https://pypi.org/pypi/$normalizedName/json"
    
    try {
        $response = Invoke-RestMethod -Uri $pypiUrl -Method Get -TimeoutSec 30
        
        $wheel = $response.urls | Where-Object { 
            $_.packagetype -eq 'bdist_wheel' -and 
            ($_.filename -match 'py3-none-any\.whl$' -or $_.filename -match 'cp310.*linux.*\.whl$')
        } | Sort-Object { 
            if ($_.filename -match 'py3-none-any') { 0 } else { 1 }
        } | Select-Object -First 1
        
        if ($wheel) {
            return @{
                Name    = $normalizedName -replace '-', '_'
                Version = $response.info.version
                Url     = $wheel.url
            }
        }
        return $null
    }
    catch {
        Write-Warning "Failed to get package info for $PackageName"
        return $null
    }
}

# Define packages
$corePackages = @(
    'azure-core',
    'azure-identity',
    'msal',
    'msal-extensions',
    'msgraph-beta-sdk'
)

$logAnalyticsPackages = @(
    'azure-monitor-ingestion'
)

$adxPackages = @(
    'azure-kusto-data',
    'azure-kusto-ingest'
)

# Determine which packages to install
$packagesToInstall = $corePackages
if ($AnalyticsBackend -eq 'LogAnalytics') {
    $packagesToInstall += $logAnalyticsPackages
}
else {
    $packagesToInstall += $adxPackages
}

Write-Host "`n[1/3] Creating Runtime Environment..." -ForegroundColor Yellow
$runtimeEnvUrl = "$baseUrl/runtimeEnvironments/$RuntimeEnvironmentName`?api-version=$apiVersion"

$runtimeEnvBody = @{
    properties = @{
        runtime = @{
            language = "Python"
            version  = "3.10"
        }
        description = "Runtime environment for Intune data export runbooks"
    }
    name = $RuntimeEnvironmentName
} | ConvertTo-Json -Depth 10

try {
    Invoke-RestMethod -Uri $runtimeEnvUrl -Method Put -Headers $headers -Body $runtimeEnvBody | Out-Null
    Write-Host "  Created Runtime Environment" -ForegroundColor Green
}
catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "  Runtime Environment already exists" -ForegroundColor Yellow
    }
    else {
        throw
    }
}

Write-Host "`n[2/3] Installing packages from PyPI..." -ForegroundColor Yellow
$installedCount = 0
$failedPackages = @()

foreach ($package in $packagesToInstall) {
    Write-Host "  $package" -NoNewline
    
    $pkgInfo = Get-PyPIWheelUrl -PackageName $package
    if (-not $pkgInfo) {
        Write-Host " - FAILED (not found)" -ForegroundColor Red
        $failedPackages += $package
        continue
    }
    
    $packageUrl = "$baseUrl/runtimeEnvironments/$RuntimeEnvironmentName/packages/$($pkgInfo.Name)`?api-version=$apiVersion"
    
    $packageBody = @{
        properties = @{
            contentLink = @{
                uri = $pkgInfo.Url
            }
        }
    } | ConvertTo-Json -Depth 10
    
    try {
        Invoke-RestMethod -Uri $packageUrl -Method Put -Headers $headers -Body $packageBody | Out-Null
        Write-Host " - v$($pkgInfo.Version) queued" -ForegroundColor Green
        $installedCount++
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 409) {
            Write-Host " - already installed" -ForegroundColor Yellow
            $installedCount++
        }
        else {
            Write-Host " - FAILED" -ForegroundColor Red
            $failedPackages += $package
        }
    }
    
    Start-Sleep -Milliseconds 300
}

Write-Host "`n[3/3] Linking runbooks to Runtime Environment..." -ForegroundColor Yellow
$runbooks = @(
    'Export-IntuneDevices',
    'Export-IntuneCompliance',
    'Export-EndpointAnalytics',
    'Export-Autopilot'
)

foreach ($runbookName in $runbooks) {
    Write-Host "  $runbookName" -NoNewline
    
    $runbookUrl = "$baseUrl/runbooks/$runbookName`?api-version=$apiVersion"
    
    $runbookBody = @{
        properties = @{
            runtimeEnvironment = $RuntimeEnvironmentName
        }
    } | ConvertTo-Json -Depth 10
    
    try {
        Invoke-RestMethod -Uri $runbookUrl -Method Patch -Headers $headers -Body $runbookBody | Out-Null
        Write-Host " - linked" -ForegroundColor Green
    }
    catch {
        Write-Host " - FAILED" -ForegroundColor Red
    }
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Packages queued: $installedCount" -ForegroundColor Gray

if ($failedPackages.Count -gt 0) {
    Write-Host "Failed packages: $($failedPackages -join ', ')" -ForegroundColor Red
}

Write-Host "`nNote: Packages may take several minutes to fully install." -ForegroundColor Yellow
Write-Host "Monitor progress in Azure Portal > Automation Account > Runtime Environments" -ForegroundColor Yellow
