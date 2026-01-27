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

    Supports two modes:
    - Az PowerShell module (preferred, if installed)
    - Azure CLI fallback (if Az module not available)

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

.NOTES
    Requires: Azure CLI OR Az PowerShell module, Azure Functions Core Tools
    Install Az module: Install-Module -Name Az -Scope CurrentUser -Force
    Install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
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

$ErrorActionPreference = "Continue"  # Don't stop on az CLI stderr output
$ProgressPreference = "SilentlyContinue"

# Track which Azure tooling mode we're using
$script:UseAzModule = $false

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

function Invoke-AzCli {
    param([string]$Command, [switch]$ReturnJson)
    $result = Invoke-Expression "az $Command 2>&1"
    if ($LASTEXITCODE -ne 0) {
        # Filter out "not found" errors which are expected when checking existence
        $errorText = $result | Out-String
        if ($errorText -notmatch "could not be found|does not exist|was not found") {
            throw "Azure CLI error: $errorText"
        }
        return $null
    }
    if ($ReturnJson -and $result) {
        return $result | ConvertFrom-Json
    }
    return $result
}

function Get-AzureAccessToken {
    if ($script:UseAzModule) {
        return (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    } else {
        $tokenResult = Invoke-AzCli "account get-access-token --resource https://management.azure.com" -ReturnJson
        return $tokenResult.accessToken
    }
}
#endregion

#region Prerequisites Check
function Test-Prerequisites {
    Write-Log "Checking prerequisites" -Level STEP

    # Check for Az module first (preferred)
    $hasAzModule = Get-Module -ListAvailable -Name Az.Accounts

    # Check for Azure CLI as fallback
    $hasAzCli = $false
    try {
        $null = & az --version 2>$null
        if ($LASTEXITCODE -eq 0) { $hasAzCli = $true }
    } catch { }

    if ($hasAzModule) {
        $script:UseAzModule = $true
        Write-Log "Using Az PowerShell module" -Level SUCCESS

        # Import Az modules
        Import-Module Az.Accounts -ErrorAction SilentlyContinue
        Import-Module Az.Resources -ErrorAction SilentlyContinue
        Import-Module Az.Storage -ErrorAction SilentlyContinue
        Import-Module Az.OperationalInsights -ErrorAction SilentlyContinue
        Import-Module Az.Functions -ErrorAction SilentlyContinue
    } elseif ($hasAzCli) {
        $script:UseAzModule = $false
        Write-Log "Az module not found, using Azure CLI fallback" -Level WARN
    } else {
        Write-Log "Neither Az PowerShell module nor Azure CLI is installed" -Level ERROR
        Write-Host "Install one of:"
        Write-Host "  Az module:  Install-Module -Name Az -Scope CurrentUser -Force"
        Write-Host "  Azure CLI:  https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    }

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
    if ($script:UseAzModule) {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $context) {
            Write-Log "Not logged in to Azure" -Level ERROR
            Write-Host "Run: Connect-AzAccount"
            exit 1
        }
        $script:SubscriptionName = $context.Subscription.Name
        $script:SubscriptionId = $context.Subscription.Id
        $script:TenantId = $context.Tenant.Id
    } else {
        $account = Invoke-AzCli "account show" -ReturnJson
        if (-not $account) {
            Write-Log "Not logged in to Azure" -Level ERROR
            Write-Host "Run: az login"
            exit 1
        }
        $script:SubscriptionName = $account.name
        $script:SubscriptionId = $account.id
        $script:TenantId = $account.tenantId
    }

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

    if ($script:UseAzModule) {
        $existing = Get-AzResourceGroup -Name $script:ResourceGroupName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "Resource group $($script:ResourceGroupName) already exists" -Level WARN
        } else {
            New-AzResourceGroup -Name $script:ResourceGroupName -Location $Location | Out-Null
            Write-Log "Created resource group: $($script:ResourceGroupName)" -Level SUCCESS
        }
    } else {
        $existing = Invoke-AzCli "group show --name $($script:ResourceGroupName)" -ReturnJson
        if ($existing) {
            Write-Log "Resource group $($script:ResourceGroupName) already exists" -Level WARN
        } else {
            Invoke-AzCli "group create --name $($script:ResourceGroupName) --location $Location --output none"
            Write-Log "Created resource group: $($script:ResourceGroupName)" -Level SUCCESS
        }
    }
}

function New-StorageAccount {
    Write-Log "Creating Storage Account" -Level STEP

    if ($script:UseAzModule) {
        $existing = Get-AzStorageAccount -ResourceGroupName $script:ResourceGroupName -Name $script:StorageAccountName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "Storage account $($script:StorageAccountName) already exists" -Level WARN
        } else {
            New-AzStorageAccount -ResourceGroupName $script:ResourceGroupName -Name $script:StorageAccountName -Location $Location -SkuName Standard_LRS | Out-Null
            Write-Log "Created storage account: $($script:StorageAccountName)" -Level SUCCESS
        }
    } else {
        $existing = Invoke-AzCli "storage account show --resource-group $($script:ResourceGroupName) --name $($script:StorageAccountName)" -ReturnJson
        if ($existing) {
            Write-Log "Storage account $($script:StorageAccountName) already exists" -Level WARN
        } else {
            Invoke-AzCli "storage account create --resource-group $($script:ResourceGroupName) --name $($script:StorageAccountName) --location $Location --sku Standard_LRS --output none"
            Write-Log "Created storage account: $($script:StorageAccountName)" -Level SUCCESS
        }
    }
}

function New-LogAnalyticsWorkspace {
    Write-Log "Creating Log Analytics Workspace" -Level STEP

    if ($script:UseAzModule) {
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
    } else {
        $existing = Invoke-AzCli "monitor log-analytics workspace show --resource-group $($script:ResourceGroupName) --workspace-name $($script:LogAnalyticsName)" -ReturnJson
        if ($existing) {
            Write-Log "Log Analytics workspace $($script:LogAnalyticsName) already exists" -Level WARN
            $script:WorkspaceResourceId = $existing.id
            $script:WorkspaceCustomerId = $existing.customerId
        } else {
            $workspace = Invoke-AzCli "monitor log-analytics workspace create --resource-group $($script:ResourceGroupName) --workspace-name $($script:LogAnalyticsName) --location $Location --retention-time 30" -ReturnJson
            Write-Log "Created Log Analytics workspace: $($script:LogAnalyticsName)" -Level SUCCESS
            $script:WorkspaceResourceId = $workspace.id
            $script:WorkspaceCustomerId = $workspace.customerId
        }
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

    $token = Get-AzureAccessToken
    $headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

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
            Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $tableBody | Out-Null
        } catch {
            Write-Log "Table $tableName may already exist" -Level WARN
        }
    }

    Write-Log "Custom tables created" -Level SUCCESS
}

function New-DataCollectionEndpoint {
    Write-Log "Creating Data Collection Endpoint" -Level STEP

    $token = Get-AzureAccessToken
    $headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

    $script:DceResourceId = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.Insights/dataCollectionEndpoints/$($script:DceName)"
    $uri = "https://management.azure.com$($script:DceResourceId)?api-version=2022-06-01"

    $dceBody = @{
        location = $Location
        properties = @{
            networkAcls = @{
                publicNetworkAccess = "Enabled"
            }
        }
    } | ConvertTo-Json -Depth 5

    try {
        $dce = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $dceBody
        Write-Log "Created DCE: $($script:DceName)" -Level SUCCESS
    } catch {
        Write-Log "DCE may already exist, fetching..." -Level WARN
        $dce = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    }

    $script:DceEndpoint = $dce.properties.logsIngestion.endpoint
    Write-Log "DCE Endpoint: $($script:DceEndpoint)" -Level INFO
}

function New-DataCollectionRule {
    Write-Log "Creating Data Collection Rule" -Level STEP

    $token = Get-AzureAccessToken
    $headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

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
        $dcr = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $dcrBody
    } catch {
        Write-Log "DCR may already exist, fetching..." -Level WARN
        $dcr = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
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

    # Check if exists (using az CLI as it's needed for Flex Consumption anyway)
    $existing = Invoke-AzCli "functionapp show --resource-group $($script:ResourceGroupName) --name $($script:FunctionAppName)" -ReturnJson
    if ($existing) {
        Write-Log "Function App $($script:FunctionAppName) already exists" -Level WARN
        return
    }

    # Create using az CLI (Az module doesn't support Flex Consumption yet)
    try {
        $null = Invoke-Expression "az functionapp create --resource-group $($script:ResourceGroupName) --flexconsumption-location $Location --runtime python --runtime-version 3.11 --name $($script:FunctionAppName) --storage-account $($script:StorageAccountName) --output none 2>&1"

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Created Function App (Flex Consumption): $($script:FunctionAppName)" -Level SUCCESS
            return
        }
    } catch { }

    Write-Log "Flex Consumption not available, using legacy Consumption plan" -Level WARN
    Invoke-AzCli "functionapp create --resource-group $($script:ResourceGroupName) --consumption-plan-location $Location --runtime python --runtime-version 3.11 --functions-version 4 --name $($script:FunctionAppName) --storage-account $($script:StorageAccountName) --os-type Linux --output none"
    Write-Log "Created Function App (Consumption): $($script:FunctionAppName)" -Level SUCCESS
}

function New-AppRegistration {
    Write-Log "Creating App Registration" -Level STEP

    if ($script:UseAzModule) {
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

        # Create new secret
        $secret = New-AzADAppCredential -ApplicationId $script:AppClientId -EndDate (Get-Date).AddYears(2)
        $script:AppClientSecret = $secret.SecretText
    } else {
        $existingApp = Invoke-AzCli "ad app list --display-name `"$($script:AppRegistrationName)`" --query `"[0]`"" -ReturnJson

        if ($existingApp) {
            Write-Log "App Registration already exists" -Level WARN
            $script:AppClientId = $existingApp.appId
        } else {
            $app = Invoke-AzCli "ad app create --display-name `"$($script:AppRegistrationName)`"" -ReturnJson
            $script:AppClientId = $app.appId

            # Create service principal
            Invoke-AzCli "ad sp create --id $($script:AppClientId) --output none"
            Write-Log "Created App Registration: $($script:AppRegistrationName)" -Level SUCCESS
        }

        # Create new secret (2 years) - use direct az command to avoid stderr mixing
        $endDate = (Get-Date).AddYears(2).ToString("yyyy-MM-dd")
        $secretOutput = & az ad app credential reset --id $script:AppClientId --end-date $endDate --query password --output tsv 2>$null
        $script:AppClientSecret = $secretOutput.Trim()
    }

    Write-Log "Client ID: $($script:AppClientId)" -Level INFO
}

function Grant-DcrPermissions {
    Write-Log "Granting DCR Permissions" -Level STEP

    # Monitoring Metrics Publisher role
    $roleDefId = "3913510d-42f4-4e42-8a64-420c390055eb"

    if ($script:UseAzModule) {
        $sp = Get-AzADServicePrincipal -ApplicationId $script:AppClientId -ErrorAction SilentlyContinue
        if (-not $sp) {
            Write-Log "Could not find service principal, skipping DCR permission" -Level WARN
            return
        }

        try {
            New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionId $roleDefId -Scope $script:DcrResourceId -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Granted Monitoring Metrics Publisher role on DCR" -Level SUCCESS
        } catch {
            Write-Log "DCR permission may already exist" -Level WARN
        }
    } else {
        $sp = Invoke-AzCli "ad sp show --id $($script:AppClientId)" -ReturnJson
        if (-not $sp) {
            Write-Log "Could not find service principal, skipping DCR permission" -Level WARN
            return
        }

        try {
            Invoke-AzCli "role assignment create --assignee-object-id $($sp.id) --role `"$roleDefId`" --scope `"$($script:DcrResourceId)`" --assignee-principal-type ServicePrincipal --output none"
            Write-Log "Granted Monitoring Metrics Publisher role on DCR" -Level SUCCESS
        } catch {
            Write-Log "DCR permission may already exist" -Level WARN
        }
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

    if ($script:UseAzModule) {
        Update-AzFunctionAppSetting -ResourceGroupName $script:ResourceGroupName -Name $script:FunctionAppName -AppSetting $settings | Out-Null
    } else {
        # Set each setting individually to avoid quoting issues
        foreach ($key in $settings.Keys) {
            $value = $settings[$key]
            $null = Invoke-Expression "az functionapp config appsettings set --resource-group `"$($script:ResourceGroupName)`" --name `"$($script:FunctionAppName)`" --settings `"$key=$value`" --output none 2>&1"
        }
    }

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

    $token = Get-AzureAccessToken
    $headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

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
        } | ConvertTo-Json -Depth 5

        $uri = "https://management.azure.com/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.Insights/workbooks/$($workbookUuid)?api-version=2022-04-01"

        try {
            Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $workbookBody | Out-Null
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
