<#
.SYNOPSIS
    Intune Reporting - Production Deployment Script (PowerShell)

.DESCRIPTION
    Deploys all Azure resources for Intune Reporting:
    - Resource Group
    - Log Analytics Workspace with custom tables (30-day retention)
    - Data Collection Endpoint & Rule
    - Function App (Flex Consumption - scales to zero)
    - App Registration for Microsoft Graph access
    - Azure Monitor Workbooks for visualization

.PARAMETER Name
    Naming prefix for resources (e.g., 'contoso-intune')

.PARAMETER Location
    Azure region (default: eastus)

.PARAMETER ResourceGroup
    Resource group name (default: rg-{Name})

.PARAMETER SkipConfirmation
    Skip confirmation prompt

.EXAMPLE
    .\deploy.ps1 -Name "contoso-intune" -Location "westeurope"

.EXAMPLE
    .\deploy.ps1 -Name "test-intune" -SkipConfirmation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [switch]$SkipConfirmation
)

$ErrorActionPreference = "Stop"

#region Helper Functions
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "STEP"    { "Magenta" }
        default   { "White" }
    }
    $prefix = switch ($Level) {
        "INFO"    { "[INFO]" }
        "SUCCESS" { "[OK]" }
        "WARN"    { "[WARN]" }
        "ERROR"   { "[ERROR]" }
        "STEP"    { "===" }
        default   { "" }
    }
    if ($Level -eq "STEP") {
        Write-Host ""
        Write-Host "$prefix $Message $prefix" -ForegroundColor $color
    } else {
        Write-Host "$prefix $Message" -ForegroundColor $color
    }
}
#endregion

#region Prerequisites Check
function Test-Prerequisites {
    Write-Log "Checking prerequisites" -Level STEP

    # Check az cli
    try {
        $null = az version 2>$null
        Write-Log "Azure CLI installed" -Level SUCCESS
    } catch {
        Write-Log "Azure CLI (az) is not installed" -Level ERROR
        Write-Host "Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    }

    # Check func core tools
    try {
        $null = func --version 2>$null
        Write-Log "Functions Core Tools installed" -Level SUCCESS
    } catch {
        Write-Log "Azure Functions Core Tools (func) is not installed" -Level ERROR
        Write-Host "Install: npm install -g azure-functions-core-tools@4"
        exit 1
    }

    # Check logged in
    $accountJson = az account show 2>$null
    if (-not $accountJson) {
        Write-Log "Not logged in to Azure CLI" -Level ERROR
        Write-Host "Run: az login"
        exit 1
    }

    $account = $accountJson | ConvertFrom-Json
    $script:SubscriptionName = $account.name
    $script:SubscriptionId = $account.id
    $script:TenantId = $account.tenantId
    Write-Log "Logged in to: $($script:SubscriptionName)" -Level SUCCESS
}
#endregion

#region Configuration
function Get-Configuration {
    Write-Log "Configuration" -Level STEP

    if (-not $Name) {
        Write-Host ""
        Write-Host "Enter a naming prefix for your resources."
        Write-Host "This will be used to create readable resource names like:"
        Write-Host "  - {prefix}-law (Log Analytics Workspace)"
        Write-Host "  - {prefix}-func (Function App)"
        Write-Host ""
        $script:NamePrefix = Read-Host "Naming prefix (e.g., contoso-intune)"

        if (-not $script:NamePrefix) {
            Write-Log "Naming prefix is required" -Level ERROR
            exit 1
        }
    } else {
        $script:NamePrefix = $Name
    }

    # Sanitize name prefix
    $script:NamePrefix = ($script:NamePrefix -replace '[^a-zA-Z0-9-]', '-').ToLower()

    # Set resource names
    if (-not $ResourceGroup) {
        $script:ResourceGroupName = "rg-$($script:NamePrefix)"
    } else {
        $script:ResourceGroupName = $ResourceGroup
    }

    $script:StorageAccountName = ($script:NamePrefix -replace '-', '') + "stor"
    if ($script:StorageAccountName.Length -gt 24) {
        $script:StorageAccountName = $script:StorageAccountName.Substring(0, 24)
    }

    $script:FunctionAppName = "$($script:NamePrefix)-func"
    $script:LogAnalyticsName = "$($script:NamePrefix)-law"
    $script:DceName = "$($script:NamePrefix)-dce"
    $script:DcrName = "$($script:NamePrefix)-dcr"
    $script:AppRegistrationName = "$($script:NamePrefix)-app"

    Write-Host ""
    Write-Host "Resources to be created:"
    Write-Host "  Resource Group:     $($script:ResourceGroupName)"
    Write-Host "  Location:           $Location"
    Write-Host "  Storage Account:    $($script:StorageAccountName)"
    Write-Host "  Function App:       $($script:FunctionAppName)"
    Write-Host "  Log Analytics:      $($script:LogAnalyticsName)"
    Write-Host "  DCE:                $($script:DceName)"
    Write-Host "  DCR:                $($script:DcrName)"
    Write-Host "  App Registration:   $($script:AppRegistrationName)"
    Write-Host ""

    if (-not $SkipConfirmation) {
        $confirm = Read-Host "Deploy with these settings? (y/n)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Log "Deployment cancelled" -Level INFO
            exit 0
        }
    }
}
#endregion

#region Resource Creation
function New-ResourceGroup {
    Write-Log "Creating Resource Group" -Level STEP

    $existing = az group show --name $script:ResourceGroupName 2>$null
    if ($existing) {
        Write-Log "Resource group $($script:ResourceGroupName) already exists" -Level WARN
    } else {
        az group create --name $script:ResourceGroupName --location $Location --output none
        Write-Log "Created resource group: $($script:ResourceGroupName)" -Level SUCCESS
    }
}

function New-StorageAccount {
    Write-Log "Creating Storage Account" -Level STEP

    $existing = az storage account show --name $script:StorageAccountName --resource-group $script:ResourceGroupName 2>$null
    if ($existing) {
        Write-Log "Storage account $($script:StorageAccountName) already exists" -Level WARN
    } else {
        az storage account create `
            --name $script:StorageAccountName `
            --resource-group $script:ResourceGroupName `
            --location $Location `
            --sku Standard_LRS `
            --output none
        Write-Log "Created storage account: $($script:StorageAccountName)" -Level SUCCESS
    }
}

function New-LogAnalyticsWorkspace {
    Write-Log "Creating Log Analytics Workspace" -Level STEP

    $existing = az monitor log-analytics workspace show --resource-group $script:ResourceGroupName --workspace-name $script:LogAnalyticsName 2>$null
    if ($existing) {
        Write-Log "Log Analytics workspace $($script:LogAnalyticsName) already exists" -Level WARN
    } else {
        az monitor log-analytics workspace create `
            --resource-group $script:ResourceGroupName `
            --workspace-name $script:LogAnalyticsName `
            --location $Location `
            --retention-time 30 `
            --output none
        Write-Log "Created Log Analytics workspace: $($script:LogAnalyticsName)" -Level SUCCESS
    }

    $workspaceJson = az monitor log-analytics workspace show `
        --resource-group $script:ResourceGroupName `
        --workspace-name $script:LogAnalyticsName 2>$null

    $workspace = $workspaceJson | ConvertFrom-Json
    $script:WorkspaceResourceId = $workspace.id
    $script:WorkspaceCustomerId = $workspace.customerId

    Write-Log "Workspace ID: $($script:WorkspaceCustomerId)" -Level INFO
}

function New-CustomTables {
    Write-Log "Creating Custom Tables" -Level STEP

    $tableNames = @(
        "IntuneDevices_CL",
        "IntuneCompliancePolicies_CL",
        "IntuneComplianceStates_CL",
        "IntuneDeviceScores_CL",
        "IntuneStartupPerformance_CL",
        "IntuneAppReliability_CL",
        "IntuneAutopilotDevices_CL",
        "IntuneAutopilotProfiles_CL",
        "IntuneSyncState_CL"
    )

    foreach ($tableName in $tableNames) {
        Write-Log "Creating table: $tableName" -Level INFO

        $tableBody = @{
            properties = @{
                schema = @{
                    name = $tableName
                    columns = @(
                        @{name="TimeGenerated"; type="datetime"}
                        @{name="IngestionTime"; type="datetime"}
                        @{name="SourceSystem"; type="string"}
                    )
                }
                retentionInDays = 30
                plan = "Analytics"
            }
        } | ConvertTo-Json -Depth 10

        $uri = "https://management.azure.com$($script:WorkspaceResourceId)/tables/$($tableName)?api-version=2022-10-01"

        try {
            az rest --method PUT --uri $uri --body $tableBody --output none 2>$null
        } catch {
            Write-Log "Table $tableName may already exist" -Level WARN
        }
    }

    Write-Log "Custom tables created" -Level SUCCESS
}

function New-DataCollectionEndpoint {
    Write-Log "Creating Data Collection Endpoint" -Level STEP

    $existing = az monitor data-collection endpoint show --resource-group $script:ResourceGroupName --name $script:DceName 2>$null
    if ($existing) {
        Write-Log "DCE $($script:DceName) already exists" -Level WARN
    } else {
        az monitor data-collection endpoint create `
            --resource-group $script:ResourceGroupName `
            --name $script:DceName `
            --location $Location `
            --public-network-access Enabled `
            --output none
        Write-Log "Created DCE: $($script:DceName)" -Level SUCCESS
    }

    $dceJson = az monitor data-collection endpoint show `
        --resource-group $script:ResourceGroupName `
        --name $script:DceName 2>$null

    $dce = $dceJson | ConvertFrom-Json
    $script:DceEndpoint = $dce.logsIngestion.endpoint
    $script:DceResourceId = $dce.id

    Write-Log "DCE Endpoint: $($script:DceEndpoint)" -Level INFO
}

function New-DataCollectionRule {
    Write-Log "Creating Data Collection Rule" -Level STEP

    $streams = @(
        "IntuneDevices_CL",
        "IntuneCompliancePolicies_CL",
        "IntuneComplianceStates_CL",
        "IntuneDeviceScores_CL",
        "IntuneStartupPerformance_CL",
        "IntuneAppReliability_CL",
        "IntuneAutopilotDevices_CL",
        "IntuneAutopilotProfiles_CL",
        "IntuneSyncState_CL"
    )

    $streamDeclarations = @{}
    $dataFlows = @()

    foreach ($stream in $streams) {
        $streamName = "Custom-$stream"
        $streamDeclarations[$streamName] = @{
            columns = @(
                @{name="TimeGenerated"; type="datetime"}
                @{name="IngestionTime"; type="datetime"}
                @{name="SourceSystem"; type="string"}
            )
        }
        $dataFlows += @{
            streams = @($streamName)
            destinations = @("logAnalyticsWorkspace")
            transformKql = "source"
            outputStream = $streamName
        }
    }

    $dcrBody = @{
        location = $Location
        properties = @{
            dataCollectionEndpointId = $script:DceResourceId
            streamDeclarations = $streamDeclarations
            destinations = @{
                logAnalytics = @(
                    @{
                        workspaceResourceId = $script:WorkspaceResourceId
                        name = "logAnalyticsWorkspace"
                    }
                )
            }
            dataFlows = $dataFlows
        }
    } | ConvertTo-Json -Depth 10

    $script:DcrResourceId = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.Insights/dataCollectionRules/$($script:DcrName)"
    $uri = "https://management.azure.com$($script:DcrResourceId)?api-version=2022-06-01"

    try {
        az rest --method PUT --uri $uri --body $dcrBody --output none 2>$null
    } catch {
        Write-Log "DCR may already exist" -Level WARN
    }

    $dcrJson = az rest --method GET --uri $uri 2>$null
    $dcr = $dcrJson | ConvertFrom-Json
    $script:DcrImmutableId = $dcr.properties.immutableId

    if ($script:DcrImmutableId) {
        Write-Log "Created DCR: $($script:DcrName) (ID: $($script:DcrImmutableId))" -Level SUCCESS
    } else {
        Write-Log "Failed to create DCR" -Level ERROR
        exit 1
    }
}

function New-FunctionApp {
    Write-Log "Creating Function App" -Level STEP

    $existing = az functionapp show --resource-group $script:ResourceGroupName --name $script:FunctionAppName 2>$null
    if ($existing) {
        Write-Log "Function App $($script:FunctionAppName) already exists" -Level WARN
        return
    }

    # Try Flex Consumption first
    try {
        az functionapp create `
            --resource-group $script:ResourceGroupName `
            --flexconsumption-location $Location `
            --runtime python `
            --runtime-version 3.11 `
            --name $script:FunctionAppName `
            --storage-account $script:StorageAccountName `
            --output none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Created Function App (Flex Consumption): $($script:FunctionAppName)" -Level SUCCESS
            return
        }
    } catch { }

    Write-Log "Flex Consumption not available, using legacy Consumption plan" -Level WARN
    az functionapp create `
        --resource-group $script:ResourceGroupName `
        --consumption-plan-location $Location `
        --runtime python `
        --runtime-version 3.11 `
        --functions-version 4 `
        --name $script:FunctionAppName `
        --storage-account $script:StorageAccountName `
        --os-type Linux `
        --output none
    Write-Log "Created Function App (Consumption): $($script:FunctionAppName)" -Level SUCCESS
}

function New-AppRegistration {
    Write-Log "Creating App Registration" -Level STEP

    $existingApp = az ad app list --display-name $script:AppRegistrationName --query "[0].appId" -o tsv 2>$null

    if ($existingApp) {
        Write-Log "App Registration already exists: $existingApp" -Level WARN
        $script:AppClientId = $existingApp
    } else {
        $script:AppClientId = az ad app create --display-name $script:AppRegistrationName --query appId -o tsv
        az ad sp create --id $script:AppClientId --output none 2>$null
        Write-Log "Created App Registration: $($script:AppRegistrationName)" -Level SUCCESS
    }

    $credentialJson = az ad app credential reset `
        --id $script:AppClientId `
        --display-name "intune-reporting-secret" `
        --years 2 2>$null

    $credential = $credentialJson | ConvertFrom-Json
    $script:AppClientSecret = $credential.password

    Write-Log "Client ID: $($script:AppClientId)" -Level INFO
}

function Grant-DcrPermissions {
    Write-Log "Granting DCR Permissions" -Level STEP

    $spObjectId = az ad sp list --filter "appId eq '$($script:AppClientId)'" --query "[0].id" -o tsv 2>$null

    if (-not $spObjectId) {
        Write-Log "Could not find service principal, skipping DCR permission" -Level WARN
        return
    }

    $roleDefId = "/subscriptions/$($script:SubscriptionId)/providers/Microsoft.Authorization/roleDefinitions/3913510d-42f4-4e42-8a64-420c390055eb"
    $assignmentId = [guid]::NewGuid().ToString()

    $assignmentBody = @{
        properties = @{
            roleDefinitionId = $roleDefId
            principalId = $spObjectId
            principalType = "ServicePrincipal"
        }
    } | ConvertTo-Json

    $uri = "https://management.azure.com$($script:DcrResourceId)/providers/Microsoft.Authorization/roleAssignments/$($assignmentId)?api-version=2022-04-01"

    try {
        az rest --method PUT --uri $uri --body $assignmentBody --output none 2>$null
        Write-Log "Granted Monitoring Metrics Publisher role on DCR" -Level SUCCESS
    } catch {
        Write-Log "DCR permission may already exist" -Level WARN
    }
}

function Set-FunctionAppConfiguration {
    Write-Log "Configuring Function App" -Level STEP

    az functionapp config appsettings set `
        --resource-group $script:ResourceGroupName `
        --name $script:FunctionAppName `
        --settings `
            "AZURE_TENANT_ID=$($script:TenantId)" `
            "AZURE_CLIENT_ID=$($script:AppClientId)" `
            "AZURE_CLIENT_SECRET=$($script:AppClientSecret)" `
            "ANALYTICS_BACKEND=LogAnalytics" `
            "LOG_ANALYTICS_DCE=$($script:DceEndpoint)" `
            "LOG_ANALYTICS_DCR_ID=$($script:DcrImmutableId)" `
        --output none

    Write-Log "Function App configured" -Level SUCCESS
}

function Publish-FunctionCode {
    Write-Log "Deploying Function Code" -Level STEP

    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Get-Location }
    $functionsDir = Join-Path $scriptDir "functions"

    if (-not (Test-Path $functionsDir)) {
        Write-Log "Functions directory not found: $functionsDir" -Level ERROR
        exit 1
    }

    Push-Location $functionsDir
    try {
        func azure functionapp publish $script:FunctionAppName --python
        Write-Log "Function code deployed" -Level SUCCESS
    } finally {
        Pop-Location
    }
}

function Deploy-Workbooks {
    Write-Log "Deploying Workbooks" -Level STEP

    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Get-Location }
    $workbooksDir = Join-Path $scriptDir "workbooks"

    if (-not (Test-Path $workbooksDir)) {
        Write-Log "Workbooks directory not found, skipping" -Level WARN
        return
    }

    az extension add --name application-insights --yes 2>$null

    $workbooks = @{
        "device-inventory.workbook" = "Intune Device Inventory"
        "compliance-overview.workbook" = "Intune Compliance Overview"
        "device-health.workbook" = "Intune Device Health"
        "autopilot-deployment.workbook" = "Intune Autopilot Deployment"
    }

    foreach ($file in $workbooks.Keys) {
        $workbookPath = Join-Path $workbooksDir $file
        $displayName = $workbooks[$file]

        if (-not (Test-Path $workbookPath)) {
            Write-Log "Workbook not found: $file" -Level WARN
            continue
        }

        $hashBytes = [System.Security.Cryptography.MD5]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes("$($script:NamePrefix)-$file")
        )
        $guid = [guid]::new($hashBytes[0..15])
        $workbookUuid = $guid.ToString()

        Write-Log "Deploying: $displayName" -Level INFO

        try {
            az monitor app-insights workbook create `
                --resource-group $script:ResourceGroupName `
                --name $workbookUuid `
                --display-name $displayName `
                --kind shared `
                --category workbook `
                --location $Location `
                --source-id $script:WorkspaceResourceId `
                --serialized-data "@$workbookPath" `
                --output none 2>$null
        } catch {
            Write-Log "Workbook may already exist: $displayName" -Level WARN
        }
    }

    Write-Log "Workbooks deployed" -Level SUCCESS
}
#endregion

#region Summary
function Show-Summary {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host "DEPLOYMENT COMPLETE" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Resources created in: $($script:ResourceGroupName)"
    Write-Host ""
    Write-Host "Function App:    https://$($script:FunctionAppName).azurewebsites.net"
    Write-Host "Log Analytics:   $($script:LogAnalyticsName)"
    Write-Host ""
    Write-Host "App Registration:"
    Write-Host "  Name:          $($script:AppRegistrationName)"
    Write-Host "  Client ID:     $($script:AppClientId)"
    Write-Host "  Tenant ID:     $($script:TenantId)"
    Write-Host ""
    Write-Host "IMPORTANT: Grant Microsoft Graph API permissions" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Open Azure Portal > App Registrations > $($script:AppRegistrationName)"
    Write-Host "2. Go to API Permissions > Add a permission > Microsoft Graph"
    Write-Host "3. Select Application permissions and add:"
    Write-Host "   - DeviceManagementManagedDevices.Read.All"
    Write-Host "   - DeviceManagementConfiguration.Read.All"
    Write-Host "   - DeviceManagementServiceConfig.Read.All"
    Write-Host "4. Click 'Grant admin consent'"
    Write-Host ""
    Write-Host "Quick link:"
    Write-Host "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$($script:AppClientId)"
    Write-Host ""
    Write-Host "Test endpoints:"
    Write-Host "  Health:  https://$($script:FunctionAppName).azurewebsites.net/api/export/health"
    Write-Host "  Test:    https://$($script:FunctionAppName).azurewebsites.net/api/export/test"
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Green
}
#endregion

#region Main
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Intune Reporting - Production Deployment" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Test-Prerequisites
Get-Configuration
New-ResourceGroup
New-StorageAccount
New-LogAnalyticsWorkspace
New-CustomTables
New-DataCollectionEndpoint
New-DataCollectionRule
New-FunctionApp
New-AppRegistration
Grant-DcrPermissions
Set-FunctionAppConfiguration
Publish-FunctionCode
Deploy-Workbooks
Show-Summary
#endregion
