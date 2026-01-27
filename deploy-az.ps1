<#
.SYNOPSIS
    Intune Reporting - Production Deployment Script (Pure Az PowerShell)

.DESCRIPTION
    Deploys all Azure resources for Intune Reporting using ONLY Az PowerShell modules:
    - Resource Group
    - Log Analytics Workspace with custom tables (30-day retention)
    - Data Collection Endpoint & Rule
    - Function App (Flex Consumption - scales to zero)
    - App Registration for Microsoft Graph access
    - Azure Monitor Workbooks for visualization

    This script requires Az PowerShell modules. For environments without Az modules,
    use deploy.ps1 which supports az CLI fallback.

.PARAMETER Name
    Naming prefix for resources (e.g., 'contoso-intune')

.PARAMETER Location
    Azure region (default: eastus)

.PARAMETER ResourceGroup
    Resource group name (default: rg-{Name})

.PARAMETER SkipConfirmation
    Skip confirmation prompt

.EXAMPLE
    .\deploy-az.ps1 -Name "contoso-intune" -Location "westeurope"

.NOTES
    Requires: Az PowerShell modules (Az.Accounts, Az.Resources, Az.Storage,
              Az.OperationalInsights, Az.Functions), Azure Functions Core Tools

    Install Az modules: Install-Module -Name Az -Scope CurrentUser -Force
    Login: Connect-AzAccount
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
$ProgressPreference = "SilentlyContinue"

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

function Get-AzureToken {
    param([string]$Resource = "https://management.azure.com")
    return (Get-AzAccessToken -ResourceUrl $Resource).Token
}

function Invoke-AzureRestMethod {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [object]$Body = $null
    )
    $token = Get-AzureToken
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    $params = @{
        Uri = $Uri
        Method = $Method
        Headers = $headers
    }

    if ($Body) {
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 }
    }

    return Invoke-RestMethod @params
}
#endregion

#region Prerequisites Check
function Test-Prerequisites {
    Write-Log "Checking prerequisites" -Level STEP

    # Check required Az modules
    $requiredModules = @("Az.Accounts", "Az.Resources", "Az.Storage", "Az.OperationalInsights", "Az.Functions")
    $missingModules = @()

    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $missingModules += $module
        }
    }

    if ($missingModules.Count -gt 0) {
        Write-Log "Missing Az modules: $($missingModules -join ', ')" -Level ERROR
        Write-Host "Install with: Install-Module -Name Az -Scope CurrentUser -Force"
        Write-Host ""
        Write-Host "Or use deploy.ps1 which supports az CLI fallback"
        exit 1
    }
    Write-Log "Az PowerShell modules installed" -Level SUCCESS

    # Import modules
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Resources -ErrorAction Stop
    Import-Module Az.Storage -ErrorAction Stop
    Import-Module Az.OperationalInsights -ErrorAction Stop
    Import-Module Az.Functions -ErrorAction Stop

    # Check func core tools
    try {
        $null = & func --version 2>$null
        Write-Log "Functions Core Tools installed" -Level SUCCESS
    } catch {
        Write-Log "Azure Functions Core Tools (func) is not installed" -Level ERROR
        Write-Host "Install: npm install -g azure-functions-core-tools@4"
        exit 1
    }

    # Check logged in
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "Not logged in to Azure" -Level ERROR
        Write-Host "Run: Connect-AzAccount"
        exit 1
    }

    $script:SubscriptionName = $context.Subscription.Name
    $script:SubscriptionId = $context.Subscription.Id
    $script:TenantId = $context.Tenant.Id
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

    $existing = Get-AzResourceGroup -Name $script:ResourceGroupName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Resource group $($script:ResourceGroupName) already exists" -Level WARN
    } else {
        New-AzResourceGroup -Name $script:ResourceGroupName -Location $Location | Out-Null
        Write-Log "Created resource group: $($script:ResourceGroupName)" -Level SUCCESS
    }
}

function New-StorageAccount {
    Write-Log "Creating Storage Account" -Level STEP

    $existing = Get-AzStorageAccount -ResourceGroupName $script:ResourceGroupName -Name $script:StorageAccountName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Storage account $($script:StorageAccountName) already exists" -Level WARN
    } else {
        New-AzStorageAccount -ResourceGroupName $script:ResourceGroupName -Name $script:StorageAccountName -Location $Location -SkuName Standard_LRS -Kind StorageV2 | Out-Null
        Write-Log "Created storage account: $($script:StorageAccountName)" -Level SUCCESS
    }
}

function New-LogAnalyticsWorkspace {
    Write-Log "Creating Log Analytics Workspace" -Level STEP

    $existing = Get-AzOperationalInsightsWorkspace -ResourceGroupName $script:ResourceGroupName -Name $script:LogAnalyticsName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Log Analytics workspace $($script:LogAnalyticsName) already exists" -Level WARN
        $script:WorkspaceResourceId = $existing.ResourceId
        $script:WorkspaceCustomerId = $existing.CustomerId
    } else {
        $workspace = New-AzOperationalInsightsWorkspace -ResourceGroupName $script:ResourceGroupName -Name $script:LogAnalyticsName -Location $Location -RetentionInDays 30
        Write-Log "Created Log Analytics workspace: $($script:LogAnalyticsName)" -Level SUCCESS
        $script:WorkspaceResourceId = $workspace.ResourceId
        $script:WorkspaceCustomerId = $workspace.CustomerId
    }

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
        }

        $uri = "https://management.azure.com$($script:WorkspaceResourceId)/tables/$($tableName)?api-version=2022-10-01"

        try {
            Invoke-AzureRestMethod -Uri $uri -Method Put -Body $tableBody | Out-Null
        } catch {
            Write-Log "Table $tableName may already exist" -Level WARN
        }
    }

    Write-Log "Custom tables created" -Level SUCCESS
}

function New-DataCollectionEndpoint {
    Write-Log "Creating Data Collection Endpoint" -Level STEP

    $script:DceResourceId = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.Insights/dataCollectionEndpoints/$($script:DceName)"
    $uri = "https://management.azure.com$($script:DceResourceId)?api-version=2022-06-01"

    $dceBody = @{
        location = $Location
        properties = @{
            networkAcls = @{
                publicNetworkAccess = "Enabled"
            }
        }
    }

    try {
        $dce = Invoke-AzureRestMethod -Uri $uri -Method Put -Body $dceBody
        Write-Log "Created DCE: $($script:DceName)" -Level SUCCESS
    } catch {
        Write-Log "DCE may already exist, fetching..." -Level WARN
        $dce = Invoke-AzureRestMethod -Uri $uri -Method Get
    }

    $script:DceEndpoint = $dce.properties.logsIngestion.endpoint
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
    }

    $script:DcrResourceId = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.Insights/dataCollectionRules/$($script:DcrName)"
    $uri = "https://management.azure.com$($script:DcrResourceId)?api-version=2022-06-01"

    try {
        $dcr = Invoke-AzureRestMethod -Uri $uri -Method Put -Body $dcrBody
    } catch {
        Write-Log "DCR may already exist, fetching..." -Level WARN
        $dcr = Invoke-AzureRestMethod -Uri $uri -Method Get
    }

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

    # Check if exists
    $existing = Get-AzFunctionApp -ResourceGroupName $script:ResourceGroupName -Name $script:FunctionAppName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Function App $($script:FunctionAppName) already exists" -Level WARN
        return
    }

    # Try Flex Consumption via REST API (not yet in Az module)
    $flexUri = "https://management.azure.com/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.Web/sites/$($script:FunctionAppName)?api-version=2023-12-01"

    $storageAccount = Get-AzStorageAccount -ResourceGroupName $script:ResourceGroupName -Name $script:StorageAccountName
    $storageKey = (Get-AzStorageAccountKey -ResourceGroupName $script:ResourceGroupName -Name $script:StorageAccountName)[0].Value
    $storageConnectionString = "DefaultEndpointsProtocol=https;AccountName=$($script:StorageAccountName);AccountKey=$storageKey;EndpointSuffix=core.windows.net"

    $flexBody = @{
        location = $Location
        kind = "functionapp,linux"
        properties = @{
            reserved = $true
            siteConfig = @{
                appSettings = @(
                    @{ name = "AzureWebJobsStorage"; value = $storageConnectionString }
                    @{ name = "FUNCTIONS_EXTENSION_VERSION"; value = "~4" }
                    @{ name = "FUNCTIONS_WORKER_RUNTIME"; value = "python" }
                    @{ name = "PYTHON_VERSION"; value = "3.11" }
                )
                linuxFxVersion = "Python|3.11"
            }
        }
        sku = @{
            name = "FC1"
            tier = "FlexConsumption"
        }
    }

    try {
        $result = Invoke-AzureRestMethod -Uri $flexUri -Method Put -Body $flexBody
        Write-Log "Created Function App (Flex Consumption): $($script:FunctionAppName)" -Level SUCCESS
        return
    } catch {
        Write-Log "Flex Consumption not available, using Consumption plan" -Level WARN
    }

    # Fallback to standard Consumption plan via Az module
    New-AzFunctionApp -ResourceGroupName $script:ResourceGroupName -Name $script:FunctionAppName -StorageAccountName $script:StorageAccountName -Location $Location -Runtime Python -RuntimeVersion 3.11 -FunctionsVersion 4 -OSType Linux | Out-Null
    Write-Log "Created Function App (Consumption): $($script:FunctionAppName)" -Level SUCCESS
}

function New-AppRegistration {
    Write-Log "Creating App Registration" -Level STEP

    $existingApp = Get-AzADApplication -DisplayName $script:AppRegistrationName -ErrorAction SilentlyContinue

    if ($existingApp) {
        Write-Log "App Registration already exists" -Level WARN
        $script:AppClientId = $existingApp.AppId
    } else {
        $app = New-AzADApplication -DisplayName $script:AppRegistrationName
        $script:AppClientId = $app.AppId

        # Create service principal
        New-AzADServicePrincipal -ApplicationId $script:AppClientId | Out-Null
        Write-Log "Created App Registration: $($script:AppRegistrationName)" -Level SUCCESS
    }

    # Create new secret (2 years)
    $endDate = (Get-Date).AddYears(2)
    $secret = New-AzADAppCredential -ApplicationId $script:AppClientId -EndDate $endDate
    $script:AppClientSecret = $secret.SecretText

    Write-Log "Client ID: $($script:AppClientId)" -Level INFO
}

function Grant-DcrPermissions {
    Write-Log "Granting DCR Permissions" -Level STEP

    $sp = Get-AzADServicePrincipal -ApplicationId $script:AppClientId -ErrorAction SilentlyContinue
    if (-not $sp) {
        Write-Log "Could not find service principal, skipping DCR permission" -Level WARN
        return
    }

    # Monitoring Metrics Publisher role
    $roleDefId = "3913510d-42f4-4e42-8a64-420c390055eb"

    try {
        New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionId $roleDefId -Scope $script:DcrResourceId -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Granted Monitoring Metrics Publisher role on DCR" -Level SUCCESS
    } catch {
        Write-Log "DCR permission may already exist" -Level WARN
    }
}

function Set-FunctionAppConfiguration {
    Write-Log "Configuring Function App" -Level STEP

    $settings = @{
        "AZURE_TENANT_ID" = $script:TenantId
        "AZURE_CLIENT_ID" = $script:AppClientId
        "AZURE_CLIENT_SECRET" = $script:AppClientSecret
        "ANALYTICS_BACKEND" = "LogAnalytics"
        "LOG_ANALYTICS_DCE" = $script:DceEndpoint
        "LOG_ANALYTICS_DCR_ID" = $script:DcrImmutableId
    }

    Update-AzFunctionAppSetting -ResourceGroupName $script:ResourceGroupName -Name $script:FunctionAppName -AppSetting $settings | Out-Null

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
        & func azure functionapp publish $script:FunctionAppName --python
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

        # Generate deterministic GUID from name prefix and file
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $hashBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$($script:NamePrefix)-$file"))
        $hexString = [BitConverter]::ToString($hashBytes) -replace '-', ''
        $workbookUuid = $hexString.Substring(0,8) + "-" + $hexString.Substring(8,4) + "-" + $hexString.Substring(12,4) + "-" + $hexString.Substring(16,4) + "-" + $hexString.Substring(20,12)
        $workbookUuid = $workbookUuid.ToLower()

        Write-Log "Deploying: $displayName" -Level INFO

        $serializedData = Get-Content $workbookPath -Raw

        $workbookBody = @{
            location = $Location
            kind = "shared"
            properties = @{
                displayName = $displayName
                category = "workbook"
                sourceId = $script:WorkspaceResourceId
                serializedData = $serializedData
            }
        }

        $uri = "https://management.azure.com/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.Insights/workbooks/$($workbookUuid)?api-version=2022-04-01"

        try {
            Invoke-AzureRestMethod -Uri $uri -Method Put -Body $workbookBody | Out-Null
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
Write-Host "  (Pure Az PowerShell Module Version)" -ForegroundColor Cyan
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
