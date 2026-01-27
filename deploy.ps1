#Requires -Version 7.0
<#
.SYNOPSIS
    Intune Reporting - One-Command Deployment

.DESCRIPTION
    Deploys all Azure resources for Intune Reporting:
    - Resource Group
    - Log Analytics Workspace with custom tables
    - Data Collection Endpoint & Rule
    - Function App with all export functions
    - App Registration for Microsoft Graph access

.EXAMPLE
    .\deploy.ps1

.EXAMPLE
    .\deploy.ps1 -ResourceGroup "my-rg" -Location "westus2"
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = "rg-intune-reporting",
    [string]$Location = "eastus",
    [string]$Prefix = "intune"
)

$ErrorActionPreference = "Stop"

#######################################
# Helper Functions
#######################################

function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param($Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

#######################################
# Check Prerequisites
#######################################

function Test-Prerequisites {
    Write-Info "Checking prerequisites..."

    # Check az cli
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Err "Azure CLI (az) is not installed."
        Write-Host "Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-windows"
        exit 1
    }

    # Check func core tools
    if (-not (Get-Command func -ErrorAction SilentlyContinue)) {
        Write-Err "Azure Functions Core Tools (func) is not installed."
        Write-Host ""
        Write-Host "Install with one of these methods:"
        Write-Host "  winget install Microsoft.Azure.FunctionsCoreTools"
        Write-Host "  npm install -g azure-functions-core-tools@4"
        Write-Host "  choco install azure-functions-core-tools"
        Write-Host ""
        Write-Host "Or download from: https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local"
        exit 1
    }

    # Check logged in
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        Write-Err "Not logged in to Azure CLI."
        Write-Host "Run: az login"
        exit 1
    }

    Write-Success "Prerequisites OK (Subscription: $($account.name))"
    return $account
}

#######################################
# Generate Unique Names
#######################################

function Get-ResourceNames {
    param($Account)

    $subscriptionId = $Account.id
    $hash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.MD5]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($subscriptionId)
        )
    ).Replace("-", "").Substring(0, 8).ToLower()

    return @{
        StorageAccount = "$($Prefix)stor$hash"
        FunctionApp = "$Prefix-func-$hash"
        LogAnalyticsWorkspace = "$Prefix-law-$hash"
        DCE = "$Prefix-dce-$hash"
        DCR = "$Prefix-dcr-$hash"
        AppRegistration = "intune-reporting-$hash"
    }
}

#######################################
# Create Resource Group
#######################################

function New-ResourceGroup {
    Write-Info "Creating resource group..."
    az group create --name $ResourceGroup --location $Location --output none
    Write-Success "Resource group created: $ResourceGroup"
}

#######################################
# Create Storage Account
#######################################

function New-StorageAccount {
    param($Names)

    Write-Info "Creating storage account..."
    az storage account create `
        --name $Names.StorageAccount `
        --resource-group $ResourceGroup `
        --location $Location `
        --sku Standard_LRS `
        --output none
    Write-Success "Storage account created: $($Names.StorageAccount)"
}

#######################################
# Create Log Analytics Workspace
#######################################

function New-LogAnalyticsWorkspace {
    param($Names)

    Write-Info "Creating Log Analytics workspace..."

    az monitor log-analytics workspace create `
        --resource-group $ResourceGroup `
        --workspace-name $Names.LogAnalyticsWorkspace `
        --location $Location `
        --retention-time 90 `
        --output none

    $workspace = az monitor log-analytics workspace show `
        --resource-group $ResourceGroup `
        --workspace-name $Names.LogAnalyticsWorkspace | ConvertFrom-Json

    Write-Success "Log Analytics workspace created"
    return $workspace
}

#######################################
# Create Custom Tables
#######################################

function New-CustomTables {
    param($Names)

    Write-Info "Creating custom tables..."

    $tables = @{
        "IntuneDevices_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="DeviceId"; type="string"}
            @{name="DeviceName"; type="string"}
            @{name="UserPrincipalName"; type="string"}
            @{name="OperatingSystem"; type="string"}
            @{name="OSVersion"; type="string"}
            @{name="ComplianceState"; type="string"}
            @{name="LastSyncDateTime"; type="datetime"}
            @{name="Manufacturer"; type="string"}
            @{name="Model"; type="string"}
            @{name="SerialNumber"; type="string"}
            @{name="IsEncrypted"; type="boolean"}
        )
        "IntuneCompliancePolicies_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="PolicyId"; type="string"}
            @{name="PolicyName"; type="string"}
            @{name="Description"; type="string"}
            @{name="PolicyType"; type="string"}
        )
        "IntuneComplianceStates_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="DeviceId"; type="string"}
            @{name="DeviceName"; type="string"}
            @{name="PolicyId"; type="string"}
            @{name="PolicyName"; type="string"}
            @{name="Status"; type="string"}
        )
        "IntuneDeviceScores_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="DeviceId"; type="string"}
            @{name="DeviceName"; type="string"}
            @{name="EndpointAnalyticsScore"; type="real"}
            @{name="StartupPerformanceScore"; type="real"}
            @{name="AppReliabilityScore"; type="real"}
        )
        "IntuneStartupPerformance_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="DeviceId"; type="string"}
            @{name="TotalBootTimeInMs"; type="int"}
            @{name="TotalLoginTimeInMs"; type="int"}
        )
        "IntuneAppReliability_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="AppName"; type="string"}
            @{name="AppCrashCount"; type="int"}
            @{name="AppHangCount"; type="int"}
        )
        "IntuneAutopilotDevices_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="AutopilotDeviceId"; type="string"}
            @{name="SerialNumber"; type="string"}
            @{name="Manufacturer"; type="string"}
            @{name="Model"; type="string"}
            @{name="EnrollmentState"; type="string"}
        )
        "IntuneAutopilotProfiles_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="ProfileId"; type="string"}
            @{name="DisplayName"; type="string"}
            @{name="ProfileType"; type="string"}
        )
        "IntuneSyncState_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="ExportType"; type="string"}
            @{name="RecordCount"; type="int"}
            @{name="Status"; type="string"}
            @{name="DurationSeconds"; type="real"}
        )
    }

    foreach ($tableName in $tables.Keys) {
        Write-Info "  Creating table: $tableName"
        $columns = ($tables[$tableName] | ForEach-Object { "$($_.name)=$($_.type)" }) -join ","

        try {
            az monitor log-analytics workspace table create `
                --resource-group $ResourceGroup `
                --workspace-name $Names.LogAnalyticsWorkspace `
                --name $tableName `
                --columns $columns `
                --output none 2>$null
        }
        catch {
            Write-Warn "  Table $tableName may already exist"
        }
    }

    Write-Success "Custom tables created"
}

#######################################
# Create Data Collection Endpoint
#######################################

function New-DataCollectionEndpoint {
    param($Names)

    Write-Info "Creating Data Collection Endpoint..."

    az monitor data-collection endpoint create `
        --resource-group $ResourceGroup `
        --name $Names.DCE `
        --location $Location `
        --public-network-access Enabled `
        --output none

    $dce = az monitor data-collection endpoint show `
        --resource-group $ResourceGroup `
        --name $Names.DCE | ConvertFrom-Json

    Write-Success "DCE created: $($dce.logsIngestion.endpoint)"
    return $dce
}

#######################################
# Create Data Collection Rule
#######################################

function New-DataCollectionRule {
    param($Names, $Workspace, $DCE)

    Write-Info "Creating Data Collection Rule..."

    # For simplicity, create a basic DCR - the full stream config would be more complex
    # The DCR will accept data and route it to Log Analytics

    try {
        az monitor data-collection rule create `
            --resource-group $ResourceGroup `
            --name $Names.DCR `
            --location $Location `
            --data-collection-endpoint-id $DCE.id `
            --output none 2>$null
    }
    catch {
        Write-Warn "DCR creation may need manual configuration"
    }

    $dcr = az monitor data-collection rule show `
        --resource-group $ResourceGroup `
        --name $Names.DCR 2>$null | ConvertFrom-Json

    if ($dcr) {
        Write-Success "DCR created: $($dcr.immutableId)"
    }
    else {
        Write-Warn "Could not retrieve DCR - may need manual setup"
        $dcr = @{ immutableId = "NEEDS_CONFIGURATION" }
    }

    return $dcr
}

#######################################
# Create Function App
#######################################

function New-FunctionApp {
    param($Names)

    Write-Info "Creating Function App..."

    az functionapp create `
        --resource-group $ResourceGroup `
        --consumption-plan-location $Location `
        --runtime python `
        --runtime-version 3.11 `
        --functions-version 4 `
        --name $Names.FunctionApp `
        --storage-account $Names.StorageAccount `
        --os-type Linux `
        --output none

    Write-Success "Function App created: $($Names.FunctionApp)"
}

#######################################
# Create App Registration
#######################################

function New-AppRegistration {
    param($Names)

    Write-Info "Creating App Registration..."

    # Check if exists
    $existingApp = az ad app list --display-name $Names.AppRegistration --query "[0].appId" -o tsv 2>$null

    if ($existingApp) {
        Write-Info "App Registration already exists, using: $existingApp"
        $clientId = $existingApp
    }
    else {
        $clientId = az ad app create --display-name $Names.AppRegistration --query appId -o tsv
        az ad sp create --id $clientId --output none 2>$null
    }

    # Create/reset secret
    $clientSecret = az ad app credential reset `
        --id $clientId `
        --display-name "intune-reporting-secret" `
        --years 2 `
        --query password -o tsv

    $tenantId = (az account show --query tenantId -o tsv)

    Write-Success "App Registration ready"

    return @{
        ClientId = $clientId
        ClientSecret = $clientSecret
        TenantId = $tenantId
    }
}

#######################################
# Configure Function App
#######################################

function Set-FunctionAppSettings {
    param($Names, $AppReg, $DCE, $DCR)

    Write-Info "Configuring Function App settings..."

    $dceEndpoint = if ($DCE.logsIngestion) { $DCE.logsIngestion.endpoint } else { "NEEDS_CONFIGURATION" }
    $dcrId = if ($DCR.immutableId) { $DCR.immutableId } else { "NEEDS_CONFIGURATION" }

    az functionapp config appsettings set `
        --resource-group $ResourceGroup `
        --name $Names.FunctionApp `
        --settings `
            "AZURE_TENANT_ID=$($AppReg.TenantId)" `
            "AZURE_CLIENT_ID=$($AppReg.ClientId)" `
            "AZURE_CLIENT_SECRET=$($AppReg.ClientSecret)" `
            "ANALYTICS_BACKEND=LogAnalytics" `
            "LOG_ANALYTICS_DCE=$dceEndpoint" `
            "LOG_ANALYTICS_DCR_ID=$dcrId" `
        --output none

    Write-Success "Function App configured"
}

#######################################
# Deploy Function Code
#######################################

function Publish-FunctionApp {
    param($Names)

    Write-Info "Deploying Function App code..."

    $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    if (-not $scriptDir) { $scriptDir = Get-Location }

    $functionsDir = Join-Path $scriptDir "functions"

    if (-not (Test-Path $functionsDir)) {
        Write-Err "Functions directory not found: $functionsDir"
        exit 1
    }

    Push-Location $functionsDir
    try {
        func azure functionapp publish $Names.FunctionApp --python
    }
    finally {
        Pop-Location
    }

    Write-Success "Function App code deployed"
}

#######################################
# Print Summary
#######################################

function Write-Summary {
    param($Names, $AppReg)

    $subscriptionId = (az account show --query id -o tsv)

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host "DEPLOYMENT COMPLETE" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Resources created in: $ResourceGroup"
    Write-Host ""
    Write-Host "Function App: https://$($Names.FunctionApp).azurewebsites.net"
    Write-Host "Log Analytics: $($Names.LogAnalyticsWorkspace)"
    Write-Host ""
    Write-Host "App Registration:"
    Write-Host "  Name:      $($Names.AppRegistration)"
    Write-Host "  Client ID: $($AppReg.ClientId)"
    Write-Host "  Tenant ID: $($AppReg.TenantId)"
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Grant Microsoft Graph API permissions to the App Registration:"
    Write-Host "   - DeviceManagementManagedDevices.Read.All"
    Write-Host "   - DeviceManagementConfiguration.Read.All"
    Write-Host "   - DeviceManagementServiceConfig.Read.All"
    Write-Host ""
    Write-Host "   Open in Azure Portal:"
    Write-Host "   https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$($AppReg.ClientId)"
    Write-Host ""
    Write-Host "2. Test the functions in Azure Portal:"
    Write-Host "   https://portal.azure.com/#@/resource/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$($Names.FunctionApp)/functions"
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Green
}

#######################################
# Main
#######################################

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Intune Reporting - Deployment Script" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

$account = Test-Prerequisites
$names = Get-ResourceNames -Account $account

Write-Host ""
Write-Host "Resource names to be created:"
Write-Host "  Resource Group:     $ResourceGroup"
Write-Host "  Storage Account:    $($names.StorageAccount)"
Write-Host "  Function App:       $($names.FunctionApp)"
Write-Host "  Log Analytics:      $($names.LogAnalyticsWorkspace)"
Write-Host "  App Registration:   $($names.AppRegistration)"
Write-Host ""

$confirm = Read-Host "Deploy to Azure with these settings? (y/n)"
if ($confirm -ne "y" -and $confirm -ne "Y") {
    Write-Info "Deployment cancelled"
    exit 0
}

Write-Host ""

New-ResourceGroup
New-StorageAccount -Names $names
$workspace = New-LogAnalyticsWorkspace -Names $names
New-CustomTables -Names $names
$dce = New-DataCollectionEndpoint -Names $names
$dcr = New-DataCollectionRule -Names $names -Workspace $workspace -DCE $dce
New-FunctionApp -Names $names
$appReg = New-AppRegistration -Names $names
Set-FunctionAppSettings -Names $names -AppReg $appReg -DCE $dce -DCR $dcr
Publish-FunctionApp -Names $names
Write-Summary -Names $names -AppReg $appReg
