<#
.SYNOPSIS
    Deploys the function app code to Azure Storage after ARM/Bicep deployment.

.DESCRIPTION
    Downloads the latest release from GitHub and uploads it to the deployment container.
    Run this after the ARM/Bicep deployment completes.

.PARAMETER StorageAccountName
    The name of the storage account (from deployment outputs)

.PARAMETER ResourceGroupName
    The resource group containing the storage account

.EXAMPLE
    .\Deploy-FunctionCode.ps1 -StorageAccountName "intunegraphdmnzulmhc3a3e" -ResourceGroupName "IntuneAnalyticsV2"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName
)

$ErrorActionPreference = "Stop"

Write-Host "📦 Deploying function code to Azure Storage..." -ForegroundColor Cyan

# Download latest release from GitHub
$releaseUrl = "https://github.com/JacobWLMS/IntuneReporting/releases/download/latest/released-package.zip"
$tempFile = Join-Path $env:TEMP "released-package.zip"

Write-Host "⬇️  Downloading from GitHub..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $releaseUrl -OutFile $tempFile

Write-Host "☁️  Uploading to Azure Storage..." -ForegroundColor Yellow

# Get storage account key
$keys = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $keys[0].Value

# Upload to deployment container
Set-AzStorageBlobContent `
    -File $tempFile `
    -Container "deploymentpackage" `
    -Blob "released-package.zip" `
    -Context $context `
    -Force

# Cleanup
Remove-Item $tempFile -Force

Write-Host "✅ Function code deployed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "The function app will automatically pick up the new code." -ForegroundColor Cyan
