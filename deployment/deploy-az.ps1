<#
.SYNOPSIS
    Intune Reporting - Production Deployment Script (Az PowerShell Modules)

.DESCRIPTION
    Deploys all Azure resources for Intune Reporting using Az PowerShell modules:
    - Resource Group (New-AzResourceGroup)
    - Storage Account (New-AzStorageAccount)
    - Log Analytics Workspace with custom tables (New-AzOperationalInsightsWorkspace)
    - Data Collection Endpoint & Rule (New-AzDataCollectionEndpoint, New-AzDataCollectionRule)
    - Function App (Flex Consumption only - via REST API or az CLI)
    - App Registration (New-AzADApplication, New-AzADServicePrincipal)
    - Azure Monitor Workbooks (New-AzApplicationInsightsWorkbook)

    NOTE: Function App uses Flex Consumption plan only. Linux Consumption (Y1) is
    deprecated and retiring September 2028. Az PowerShell modules do not yet support
    Flex Consumption, so az CLI is used as fallback. See:
    https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to

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
    Requires:
    - Az PowerShell modules: Az.Accounts, Az.Resources, Az.Storage,
      Az.OperationalInsights, Az.Functions, Az.Monitor, Az.ApplicationInsights
    - Azure CLI (for Flex Consumption Function App fallback)
    - Azure Functions Core Tools

    Install Az modules: Install-Module -Name Az -Scope CurrentUser -Force
    Install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
    Login: Connect-AzAccount

.LINK
    https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell
    https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to
    https://learn.microsoft.com/en-us/powershell/module/az.monitor/new-azdatacollectionrule
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [string]$Location = "uksouth",

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
        [object]$Body = $null,
        [switch]$IgnoreError
    )

    # Get fresh token using Az module
    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.accounts/get-azaccesstoken
    try {
        $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com" -AsSecureString
        # Convert SecureString to plain text for use with REST API
        $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenResponse.Token)
        )
    } catch {
        # Fallback to older syntax if -AsSecureString not supported
        $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
        $token = $tokenResponse.Token
    }

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    $params = @{
        Uri = $Uri
        Method = $Method
        Headers = $headers
        ErrorAction = "Stop"
    }

    if ($Body) {
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 }
    }

    try {
        return Invoke-RestMethod @params
    } catch {
        if ($IgnoreError) {
            return $null
        }
        throw
    }
}
#endregion

#region Prerequisites Check
function Test-Prerequisites {
    Write-Log "Checking prerequisites" -Level STEP

    # Check required Az modules
    # Reference: https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell
    $requiredModules = @("Az.Accounts", "Az.Resources", "Az.Storage", "Az.OperationalInsights", "Az.Functions", "Az.Monitor", "Az.ApplicationInsights")
    $missingModules = @()

    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $missingModules += $module
        }
    }

    if ($missingModules.Count -gt 0) {
        Write-Log "Missing required Az modules: $($missingModules -join ', ')" -Level ERROR
        Write-Host "Install with: Install-Module -Name Az -Scope CurrentUser -Force"
        Write-Host ""
        Write-Host "Or use deploy.ps1 which supports az CLI fallback"
        exit 1
    }
    Write-Log "All required Az PowerShell modules installed" -Level SUCCESS

    # Import all required modules
    # Reference: https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Resources -ErrorAction Stop
    Import-Module Az.Storage -ErrorAction Stop
    Import-Module Az.OperationalInsights -ErrorAction Stop
    Import-Module Az.Functions -ErrorAction Stop
    Import-Module Az.Monitor -ErrorAction Stop
    Import-Module Az.ApplicationInsights -ErrorAction Stop

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

    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azresourcegroup
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

    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.storage/new-azstorageaccount
    $existing = Get-AzStorageAccount -ResourceGroupName $script:ResourceGroupName -Name $script:StorageAccountName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Storage account $($script:StorageAccountName) already exists" -Level WARN
    } else {
        New-AzStorageAccount `
            -ResourceGroupName $script:ResourceGroupName `
            -Name $script:StorageAccountName `
            -Location $Location `
            -SkuName Standard_LRS `
            -Kind StorageV2 | Out-Null
        Write-Log "Created storage account: $($script:StorageAccountName)" -Level SUCCESS
    }
}

function New-LogAnalyticsWorkspace {
    Write-Log "Creating Log Analytics Workspace" -Level STEP

    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.operationalinsights/new-azoperationalinsightsworkspace
    $existing = Get-AzOperationalInsightsWorkspace -ResourceGroupName $script:ResourceGroupName -Name $script:LogAnalyticsName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Log Analytics workspace $($script:LogAnalyticsName) already exists" -Level WARN
        $script:WorkspaceResourceId = $existing.ResourceId
        $script:WorkspaceCustomerId = $existing.CustomerId
    } else {
        $workspace = New-AzOperationalInsightsWorkspace `
            -ResourceGroupName $script:ResourceGroupName `
            -Name $script:LogAnalyticsName `
            -Location $Location `
            -RetentionInDays 30
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

    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.monitor/new-azdatacollectionendpoint
    $existing = Get-AzDataCollectionEndpoint -ResourceGroupName $script:ResourceGroupName -Name $script:DceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "DCE $($script:DceName) already exists" -Level WARN
        $script:DceResourceId = $existing.Id
        # Az module property is LogIngestionEndpoint (singular), not LogsIngestionEndpoint
        $script:DceEndpoint = $existing.LogIngestionEndpoint
    } else {
        $dce = New-AzDataCollectionEndpoint `
            -ResourceGroupName $script:ResourceGroupName `
            -Name $script:DceName `
            -Location $Location `
            -NetworkAclsPublicNetworkAccess "Enabled"
        Write-Log "Created DCE: $($script:DceName)" -Level SUCCESS
        $script:DceResourceId = $dce.Id
        # Az module property is LogIngestionEndpoint (singular), not LogsIngestionEndpoint
        $script:DceEndpoint = $dce.LogIngestionEndpoint
    }

    # If LogIngestionEndpoint is empty, re-fetch using Get-AzDataCollectionEndpoint
    if (-not $script:DceEndpoint) {
        Write-Log "Fetching DCE endpoint..." -Level INFO
        Start-Sleep -Seconds 3  # Brief wait for Azure to propagate
        $dceRefresh = Get-AzDataCollectionEndpoint -ResourceGroupName $script:ResourceGroupName -Name $script:DceName
        $script:DceEndpoint = $dceRefresh.LogIngestionEndpoint
    }

    if (-not $script:DceEndpoint) {
        Write-Log "Could not retrieve DCE endpoint - this may indicate a configuration issue" -Level ERROR
        exit 1
    }

    Write-Log "DCE Endpoint: $($script:DceEndpoint)" -Level INFO
}

function New-DataCollectionRule {
    Write-Log "Creating Data Collection Rule" -Level STEP

    $existing = Get-AzDataCollectionRule -ResourceGroupName $script:ResourceGroupName -Name $script:DcrName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "DCR $($script:DcrName) already exists" -Level WARN
        $script:DcrResourceId = $existing.Id
        $script:DcrImmutableId = $existing.ImmutableId
        Write-Log "DCR ID: $($script:DcrImmutableId)" -Level INFO
        return
    }

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

    # Build stream declarations for JSON (per Microsoft documentation)
    $streamDeclarations = @{}
    foreach ($table in $tableNames) {
        $streamName = "Custom-$table"
        $streamDeclarations[$streamName] = @{
            columns = @(
                @{name="TimeGenerated"; type="datetime"}
                @{name="IngestionTime"; type="datetime"}
                @{name="SourceSystem"; type="string"}
            )
        }
    }

    # Build data flows for JSON (per Microsoft documentation)
    $dataFlows = @()
    foreach ($table in $tableNames) {
        $streamName = "Custom-$table"
        $dataFlows += @{
            streams = @($streamName)
            destinations = @("logAnalyticsWorkspace")
            outputStream = $streamName
            transformKql = "source"
        }
    }

    # Build complete DCR JSON structure matching ARM template format
    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.monitor/new-azdatacollectionrule
    $dcrJson = @{
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

    # Write to temp file with UTF8 encoding (no BOM for JSON compatibility)
    $tempJsonPath = Join-Path $env:TEMP "dcr-$($script:DcrName).json"
    $jsonContent = $dcrJson | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($tempJsonPath, $jsonContent, [System.Text.UTF8Encoding]::new($false))

    Write-Log "DCR configuration written to: $tempJsonPath" -Level INFO

    try {
        # Create DCR using -JsonFilePath parameter (recommended by Microsoft for complex configurations)
        # Reference: https://learn.microsoft.com/en-us/powershell/module/az.monitor/new-azdatacollectionrule
        $dcr = New-AzDataCollectionRule -Name $script:DcrName -ResourceGroupName $script:ResourceGroupName -JsonFilePath $tempJsonPath

        $script:DcrResourceId = $dcr.Id
        $script:DcrImmutableId = $dcr.ImmutableId

        if ($script:DcrImmutableId) {
            Write-Log "Created DCR: $($script:DcrName) (ID: $($script:DcrImmutableId))" -Level SUCCESS
        } else {
            Write-Log "DCR created but ImmutableId not returned, fetching..." -Level WARN
            Start-Sleep -Seconds 3
            $dcrFetched = Get-AzDataCollectionRule -ResourceGroupName $script:ResourceGroupName -Name $script:DcrName
            $script:DcrImmutableId = $dcrFetched.ImmutableId
            $script:DcrResourceId = $dcrFetched.Id
            Write-Log "DCR ID: $($script:DcrImmutableId)" -Level SUCCESS
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-Log "Failed to create DCR: $errorMessage" -Level ERROR
        Write-Log "DCR JSON saved at: $tempJsonPath (for debugging)" -Level INFO

        # Show JSON content for debugging
        Write-Host "DCR JSON content:" -ForegroundColor Yellow
        Get-Content $tempJsonPath | Write-Host
        exit 1
    } finally {
        # Clean up temp file on success
        if ($script:DcrImmutableId -and (Test-Path $tempJsonPath)) {
            Remove-Item $tempJsonPath -Force
        }
    }
}

function New-FunctionApp {
    Write-Log "Creating Function App" -Level STEP

    # Check if exists using Az module cmdlet
    $existing = Get-AzFunctionApp -ResourceGroupName $script:ResourceGroupName -Name $script:FunctionAppName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Function App $($script:FunctionAppName) already exists" -Level WARN
        return
    }

    # Get storage account key using Az module
    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.storage/get-azstorageaccountkey
    $storageKeys = Get-AzStorageAccountKey -ResourceGroupName $script:ResourceGroupName -Name $script:StorageAccountName
    $storageKey = $storageKeys[0].Value
    $storageConnectionString = "DefaultEndpointsProtocol=https;AccountName=$($script:StorageAccountName);AccountKey=$storageKey;EndpointSuffix=core.windows.net"

    # NOTE: Flex Consumption is NOT supported by New-AzFunctionApp cmdlet as of 2026
    # Reference: https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to
    # The documentation only shows Azure CLI, Portal, VS Code, and Maven for Flex Consumption creation.
    # We must use ARM/REST API for Flex Consumption until Az module adds support.

    # Try Flex Consumption via REST API (ARM template equivalent)
    Write-Log "Attempting Flex Consumption plan (via ARM API)..." -Level INFO
    $flexUri = "https://management.azure.com/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.Web/sites/$($script:FunctionAppName)?api-version=2023-12-01"

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
        Invoke-AzureRestMethod -Uri $flexUri -Method Put -Body $flexBody | Out-Null
        Write-Log "Created Function App (Flex Consumption): $($script:FunctionAppName)" -Level SUCCESS
        return
    } catch {
        Write-Log "REST API method not available, using az CLI..." -Level INFO
    }

    # Use az CLI for Flex Consumption (Az PowerShell modules don't support it yet)
    # Reference: https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to
    $cliOutput = & az functionapp create `
        --resource-group $script:ResourceGroupName `
        --flexconsumption-location $Location `
        --runtime python `
        --runtime-version 3.11 `
        --name $script:FunctionAppName `
        --storage-account $script:StorageAccountName `
        --output none 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Log "Created Function App (Flex Consumption): $($script:FunctionAppName)" -Level SUCCESS
        return
    }

    Write-Log "Failed to create Function App" -Level ERROR
    Write-Log "CLI output: $cliOutput" -Level ERROR
    exit 1
}

function New-AppRegistration {
    Write-Log "Creating App Registration" -Level STEP

    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azadapplication
    $existingApp = Get-AzADApplication -DisplayName $script:AppRegistrationName -ErrorAction SilentlyContinue

    if ($existingApp) {
        Write-Log "App Registration already exists" -Level WARN
        $script:AppClientId = $existingApp.AppId
    } else {
        $app = New-AzADApplication -DisplayName $script:AppRegistrationName
        $script:AppClientId = $app.AppId

        # Create service principal
        # Reference: https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azadserviceprincipal
        New-AzADServicePrincipal -ApplicationId $script:AppClientId | Out-Null
        Write-Log "Created App Registration: $($script:AppRegistrationName)" -Level SUCCESS
    }

    # Create new secret (2 years)
    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azadappcredential
    $endDate = (Get-Date).AddYears(2)
    $secret = New-AzADAppCredential -ApplicationId $script:AppClientId -EndDate $endDate
    $script:AppClientSecret = $secret.SecretText

    Write-Log "Client ID: $($script:AppClientId)" -Level INFO
}

function Grant-DcrPermissions {
    Write-Log "Granting DCR Permissions" -Level STEP

    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.resources/get-azadserviceprincipal
    $sp = Get-AzADServicePrincipal -ApplicationId $script:AppClientId -ErrorAction SilentlyContinue
    if (-not $sp) {
        Write-Log "Could not find service principal, skipping DCR permission" -Level WARN
        return
    }

    # Monitoring Metrics Publisher role (required for DCR data ingestion)
    # Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview
    $roleDefId = "3913510d-42f4-4e42-8a64-420c390055eb"

    try {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azroleassignment
        New-AzRoleAssignment `
            -ObjectId $sp.Id `
            -RoleDefinitionId $roleDefId `
            -Scope $script:DcrResourceId `
            -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Granted Monitoring Metrics Publisher role on DCR" -Level SUCCESS
    } catch {
        Write-Log "DCR permission may already exist" -Level WARN
    }
}

function Set-FunctionAppConfiguration {
    Write-Log "Configuring Function App" -Level STEP

    # Reference: https://learn.microsoft.com/en-us/powershell/module/az.functions/update-azfunctionappsetting
    $settings = @{
        "AZURE_TENANT_ID" = $script:TenantId
        "AZURE_CLIENT_ID" = $script:AppClientId
        "AZURE_CLIENT_SECRET" = $script:AppClientSecret
        "ANALYTICS_BACKEND" = "LogAnalytics"
        "LOG_ANALYTICS_DCE" = $script:DceEndpoint
        "LOG_ANALYTICS_DCR_ID" = $script:DcrImmutableId
    }

    Update-AzFunctionAppSetting `
        -ResourceGroupName $script:ResourceGroupName `
        -Name $script:FunctionAppName `
        -AppSetting $settings | Out-Null

    Write-Log "Function App configured" -Level SUCCESS
}

function Publish-FunctionCode {
    Write-Log "Deploying Function Code" -Level STEP

    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Get-Location }
    $functionsDir = Join-Path (Split-Path $scriptDir -Parent) "functions"

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

        # Deploy using Az.ApplicationInsights cmdlet
        # Reference: https://learn.microsoft.com/en-us/powershell/module/az.applicationinsights/new-azapplicationinsightsworkbook
        try {
            $existingWorkbook = Get-AzApplicationInsightsWorkbook -ResourceGroupName $script:ResourceGroupName -Name $workbookUuid -ErrorAction SilentlyContinue
            if ($existingWorkbook) {
                Write-Log "Workbook already exists: $displayName" -Level WARN
                continue
            }

            New-AzApplicationInsightsWorkbook `
                -ResourceGroupName $script:ResourceGroupName `
                -Name $workbookUuid `
                -Location $Location `
                -DisplayName $displayName `
                -Category "workbook" `
                -SourceId $script:WorkspaceResourceId `
                -SerializedData $serializedData | Out-Null

            Write-Log "Deployed: $displayName" -Level SUCCESS
        } catch {
            Write-Log "Failed to deploy workbook: $displayName - $_" -Level ERROR
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
