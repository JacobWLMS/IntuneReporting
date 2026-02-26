<#
.SYNOPSIS
    Intune Reporting - Production Deployment Script (PowerShell)

.DESCRIPTION
    Deploys all Azure resources for Intune Reporting:
    - Resource Group
    - Log Analytics Workspace with custom tables (30-day retention)
    - Data Collection Endpoint & Rule
    - Function App (Flex Consumption - scales to zero) with Managed Identity
    - Azure Monitor Workbooks for visualization

    Uses System-Assigned Managed Identity for:
    - Microsoft Graph API access (Intune data)
    - Log Analytics data ingestion (DCR)

    No secrets or App Registrations required!

    Supports two modes:
    - Az PowerShell module (preferred, if installed)
    - Azure CLI fallback (if Az module not available)

.PARAMETER Name
    Naming prefix for resources (e.g., 'contoso-intune')

.PARAMETER Location
    Azure region (default: uksouth)

.PARAMETER ResourceGroup
    Resource group name (default: ancIntuneReporting-Dev)

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

    Post-Deployment Requirements (require elevated permissions):
    1. DCR Role: 'Monitoring Metrics Publisher' on the Data Collection Rule
    2. Graph Permissions: Grant Graph API permissions to the Managed Identity

    The summary will show the exact commands to run if these fail.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [string]$Location = "uksouth",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = "ancIntuneReporting-Dev",

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
        $tokenObj = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
        # Handle both old (string) and new (SecureString) Az module versions
        if ($tokenObj.Token -is [System.Security.SecureString]) {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
            )
        } else {
            return $tokenObj.Token
        }
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

    Write-Host ""
    Write-Host "Resources to be created:"
    Write-Host "  Resource Group:     $($script:ResourceGroupName)"
    Write-Host "  Location:           $Location"
    Write-Host "  Storage Account:    $($script:StorageAccountName)"
    Write-Host "  Function App:       $($script:FunctionAppName) (with Managed Identity)"
    Write-Host "  Log Analytics:      $($script:LogAnalyticsName)"
    Write-Host "  DCE:                $($script:DceName)"
    Write-Host "  DCR:                $($script:DcrName)"
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
        "IntuneManagedDevices_CL",
        "IntuneUsers_CL",
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

    # Define complete schemas for each stream based on Python export fields
    $streamSchemas = @{
        "Custom-IntuneManagedDevices_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="DeviceId"; type="string"}
            @{name="DeviceName"; type="string"}
            @{name="UserPrincipalName"; type="string"}
            @{name="UserDisplayName"; type="string"}
            @{name="OperatingSystem"; type="string"}
            @{name="OSVersion"; type="string"}
            @{name="ComplianceState"; type="string"}
            @{name="ManagementState"; type="string"}
            @{name="EnrolledDateTime"; type="datetime"}
            @{name="LastSyncDateTime"; type="datetime"}
            @{name="Manufacturer"; type="string"}
            @{name="Model"; type="string"}
            @{name="SerialNumber"; type="string"}
            @{name="IMEI"; type="string"}
            @{name="ManagementAgent"; type="string"}
            @{name="OwnerType"; type="string"}
            @{name="DeviceEnrollmentType"; type="string"}
            @{name="EmailAddress"; type="string"}
            @{name="AzureADRegistered"; type="boolean"}
            @{name="AzureADDeviceId"; type="string"}
            @{name="DeviceRegistrationState"; type="string"}
            @{name="IsEncrypted"; type="boolean"}
            @{name="IsSupervised"; type="boolean"}
            @{name="JailBroken"; type="string"}
            @{name="AutopilotEnrolled"; type="boolean"}
            @{name="DeviceCategory"; type="string"}
            @{name="TotalStorageGB"; type="real"}
            @{name="FreeStorageGB"; type="real"}
            @{name="PhysicalMemoryGB"; type="real"}
            @{name="WiFiMacAddress"; type="string"}
            @{name="EthernetMacAddress"; type="string"}
        )
        "Custom-IntuneCompliancePolicies_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="PolicyId"; type="string"}
            @{name="PolicyName"; type="string"}
            @{name="Description"; type="string"}
            @{name="CreatedDateTime"; type="datetime"}
            @{name="LastModifiedDateTime"; type="datetime"}
            @{name="PolicyType"; type="string"}
        )
        "Custom-IntuneComplianceStates_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="DeviceId"; type="string"}
            @{name="DeviceName"; type="string"}
            @{name="UserId"; type="string"}
            @{name="UserPrincipalName"; type="string"}
            @{name="PolicyId"; type="string"}
            @{name="PolicyName"; type="string"}
            @{name="Status"; type="string"}
            @{name="StatusRaw"; type="int"}
            @{name="SettingCount"; type="int"}
            @{name="FailedSettingCount"; type="int"}
            @{name="LastContact"; type="datetime"}
        )
        "Custom-IntuneDeviceScores_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="DeviceId"; type="string"}
            @{name="DeviceName"; type="string"}
            @{name="Model"; type="string"}
            @{name="Manufacturer"; type="string"}
            @{name="HealthStatus"; type="string"}
            @{name="EndpointAnalyticsScore"; type="real"}
            @{name="StartupPerformanceScore"; type="real"}
            @{name="AppReliabilityScore"; type="real"}
            @{name="WorkFromAnywhereScore"; type="real"}
            @{name="MeanResourceSpikeTimeScore"; type="real"}
            @{name="BatteryHealthScore"; type="real"}
        )
        "Custom-IntuneStartupPerformance_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="DeviceId"; type="string"}
            @{name="StartTime"; type="datetime"}
            @{name="CoreBootTimeInMs"; type="int"}
            @{name="GroupPolicyBootTimeInMs"; type="int"}
            @{name="GroupPolicyLoginTimeInMs"; type="int"}
            @{name="CoreLoginTimeInMs"; type="int"}
            @{name="TotalBootTimeInMs"; type="int"}
            @{name="TotalLoginTimeInMs"; type="int"}
            @{name="IsFirstLogin"; type="boolean"}
            @{name="IsFeatureUpdate"; type="boolean"}
            @{name="OperatingSystemVersion"; type="string"}
            @{name="RestartCategory"; type="string"}
            @{name="RestartFaultBucket"; type="string"}
        )
        "Custom-IntuneAppReliability_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="AppName"; type="string"}
            @{name="AppDisplayName"; type="string"}
            @{name="AppPublisher"; type="string"}
            @{name="ActiveDeviceCount"; type="int"}
            @{name="AppCrashCount"; type="int"}
            @{name="AppHangCount"; type="int"}
            @{name="MeanTimeToFailureInMinutes"; type="int"}
            @{name="AppHealthScore"; type="real"}
            @{name="AppHealthStatus"; type="string"}
        )
        "Custom-IntuneAutopilotDevices_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="AutopilotDeviceId"; type="string"}
            @{name="SerialNumber"; type="string"}
            @{name="ProductKey"; type="string"}
            @{name="Manufacturer"; type="string"}
            @{name="Model"; type="string"}
            @{name="GroupTag"; type="string"}
            @{name="PurchaseOrderIdentifier"; type="string"}
            @{name="EnrollmentState"; type="string"}
            @{name="DeploymentProfileAssignmentStatus"; type="string"}
            @{name="DeploymentProfileAssignedDateTime"; type="datetime"}
            @{name="LastContactedDateTime"; type="datetime"}
            @{name="AddressableUserName"; type="string"}
            @{name="UserPrincipalName"; type="string"}
            @{name="ResourceName"; type="string"}
            @{name="AzureActiveDirectoryDeviceId"; type="string"}
            @{name="ManagedDeviceId"; type="string"}
            @{name="DisplayName"; type="string"}
        )
        "Custom-IntuneAutopilotProfiles_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="ProfileId"; type="string"}
            @{name="DisplayName"; type="string"}
            @{name="Description"; type="string"}
            @{name="CreatedDateTime"; type="datetime"}
            @{name="LastModifiedDateTime"; type="datetime"}
            @{name="Language"; type="string"}
            @{name="DeviceNameTemplate"; type="string"}
            @{name="DeviceType"; type="string"}
            @{name="EnableWhiteGlove"; type="boolean"}
            @{name="ExtractHardwareHash"; type="boolean"}
            @{name="OutOfBoxExperienceSettings"; type="string"}
            @{name="ProfileType"; type="string"}
        )
        "Custom-IntuneSyncState_CL" = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="ExportType"; type="string"}
            @{name="RecordCount"; type="int"}
            @{name="DurationSeconds"; type="real"}
            @{name="Status"; type="string"}
        )
    }

    $streamDeclarations = @{}
    $dataFlows = @()

    foreach ($streamName in $streamSchemas.Keys) {
        $streamDeclarations[$streamName] = @{
            columns = $streamSchemas[$streamName]
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
    } else {
        # Create using az CLI (Az module doesn't support Flex Consumption yet)
        try {
            $null = Invoke-Expression "az functionapp create --resource-group $($script:ResourceGroupName) --flexconsumption-location $Location --runtime python --runtime-version 3.11 --name $($script:FunctionAppName) --storage-account $($script:StorageAccountName) --output none 2>&1"

            if ($LASTEXITCODE -eq 0) {
                Write-Log "Created Function App (Flex Consumption): $($script:FunctionAppName)" -Level SUCCESS
            } else {
                throw "Flex consumption failed"
            }
        } catch {
            Write-Log "Flex Consumption not available, using legacy Consumption plan" -Level WARN
            Invoke-AzCli "functionapp create --resource-group $($script:ResourceGroupName) --consumption-plan-location $Location --runtime python --runtime-version 3.11 --functions-version 4 --name $($script:FunctionAppName) --storage-account $($script:StorageAccountName) --os-type Linux --output none"
            Write-Log "Created Function App (Consumption): $($script:FunctionAppName)" -Level SUCCESS
        }
    }

    # Enable system-assigned managed identity
    Write-Log "Enabling system-assigned managed identity" -Level INFO
    if ($script:UseAzModule) {
        $identity = Set-AzWebApp -ResourceGroupName $script:ResourceGroupName -Name $script:FunctionAppName -AssignIdentity $true
        $script:FunctionAppPrincipalId = $identity.Identity.PrincipalId
    } else {
        $identityResult = Invoke-AzCli "functionapp identity assign --resource-group $($script:ResourceGroupName) --name $($script:FunctionAppName)" -ReturnJson
        $script:FunctionAppPrincipalId = $identityResult.principalId
    }

    if ($script:FunctionAppPrincipalId) {
        Write-Log "Managed Identity enabled (Principal ID: $($script:FunctionAppPrincipalId))" -Level SUCCESS
    } else {
        Write-Log "Failed to enable managed identity" -Level ERROR
    }
}

function Grant-DcrPermissions {
    Write-Log "DCR Permissions Required" -Level STEP

    # Don't attempt assignment - just track what's needed for summary
    # Monitoring Metrics Publisher role ID: 3913510d-42f4-4e42-8a64-420c390055eb
    Write-Log "DCR role assignment will be shown in summary" -Level INFO
    $script:DcrRoleAssignmentNeeded = $true
}

function Grant-GraphPermissions {
    Write-Log "Graph API Permissions Required" -Level STEP

    # Don't attempt assignment - requires Global Admin or Privileged Role Admin
    # Just track what's needed for summary
    Write-Log "Graph API permissions will be shown in summary" -Level INFO
    $script:GraphPermissionsNeeded = $true
}

function Set-FunctionAppConfiguration {
    Write-Log "Configuring Function App" -Level STEP

    # Managed Identity is used for both Graph API and Log Analytics ingestion
    # No secrets required!
    $settings = @{
        "USE_MANAGED_IDENTITY" = "true"
        "AZURE_TENANT_ID" = $script:TenantId
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
function Get-FunctionKey {
    # Get the function host key for API calls
    try {
        if ($script:UseAzModule) {
            $keys = Invoke-AzResourceAction -ResourceGroupName $script:ResourceGroupName -ResourceType "Microsoft.Web/sites" -ResourceName $script:FunctionAppName -Action "host/default/listkeys" -ApiVersion "2022-03-01" -Force -ErrorAction SilentlyContinue
            return $keys.functionKeys.default
        } else {
            $keysJson = Invoke-AzCli "functionapp keys list --name $($script:FunctionAppName) --resource-group $($script:ResourceGroupName)" -ReturnJson
            return $keysJson.functionKeys.default
        }
    } catch {
        return $null
    }
}

function Show-Summary {
    # Get function key for test URLs
    $functionKey = Get-FunctionKey

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host "DEPLOYMENT COMPLETE" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Resources created in: $($script:ResourceGroupName)"
    Write-Host ""
    Write-Host "Function App:     https://$($script:FunctionAppName).azurewebsites.net"
    Write-Host "Log Analytics:    $($script:LogAnalyticsName)"
    Write-Host "DCE Endpoint:     $($script:DceEndpoint)"
    Write-Host "DCR Immutable ID: $($script:DcrImmutableId)"
    Write-Host ""
    Write-Host "Managed Identity:"
    Write-Host "  Principal ID:   $($script:FunctionAppPrincipalId)"
    Write-Host "  Tenant ID:      $($script:TenantId)"

    # Permission commands section
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Yellow
    Write-Host "ACTION REQUIRED: Permission Assignments" -ForegroundColor Yellow
    Write-Host "==============================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "The following commands require elevated permissions." -ForegroundColor Yellow
    Write-Host "Ask someone with Owner/User Access Administrator (for DCR)" -ForegroundColor Yellow
    Write-Host "and Global Admin or Privileged Role Admin (for Graph) to run:" -ForegroundColor Yellow

    # DCR Role Assignment
    Write-Host ""
    Write-Host "1. DCR ROLE ASSIGNMENT (Log Analytics Ingestion)" -ForegroundColor Cyan
    Write-Host "   Grants 'Monitoring Metrics Publisher' role to Managed Identity"
    Write-Host ""
    Write-Host "   az role assignment create ``" -ForegroundColor White
    Write-Host "     --assignee-object-id `"$($script:FunctionAppPrincipalId)`" ``" -ForegroundColor White
    Write-Host "     --assignee-principal-type ServicePrincipal ``" -ForegroundColor White
    Write-Host "     --role `"Monitoring Metrics Publisher`" ``" -ForegroundColor White
    Write-Host "     --scope `"$($script:DcrResourceId)`"" -ForegroundColor White

    # Graph API Permissions
    Write-Host ""
    Write-Host "2. GRAPH API PERMISSIONS (Intune Data Access)" -ForegroundColor Cyan
    Write-Host "   Grants Microsoft Graph permissions to Managed Identity"
    Write-Host ""
    Write-Host "   # Get Microsoft Graph service principal ID" -ForegroundColor Gray
    Write-Host "   `$graphSpId = (az ad sp list --filter `"appId eq '00000003-0000-0000-c000-000000000000'`" --query `"[0].id`" -o tsv)" -ForegroundColor White
    Write-Host ""
    Write-Host "   # DeviceManagementManagedDevices.Read.All" -ForegroundColor Gray
    Write-Host "   az rest --method POST ``" -ForegroundColor White
    Write-Host "     --uri `"https://graph.microsoft.com/v1.0/servicePrincipals/$($script:FunctionAppPrincipalId)/appRoleAssignments`" ``" -ForegroundColor White
    Write-Host "     --body `"{\`"principalId\`":\`"$($script:FunctionAppPrincipalId)\`",\`"resourceId\`":\`"`$graphSpId\`",\`"appRoleId\`":\`"dc377aa6-52d8-4e23-b271-2a7ae04cedf3\`"}`"" -ForegroundColor White
    Write-Host ""
    Write-Host "   # DeviceManagementConfiguration.Read.All" -ForegroundColor Gray
    Write-Host "   az rest --method POST ``" -ForegroundColor White
    Write-Host "     --uri `"https://graph.microsoft.com/v1.0/servicePrincipals/$($script:FunctionAppPrincipalId)/appRoleAssignments`" ``" -ForegroundColor White
    Write-Host "     --body `"{\`"principalId\`":\`"$($script:FunctionAppPrincipalId)\`",\`"resourceId\`":\`"`$graphSpId\`",\`"appRoleId\`":\`"5ac13192-7ace-4fcf-b828-1a26f28068ee\`"}`"" -ForegroundColor White
    Write-Host ""
    Write-Host "   # DeviceManagementServiceConfig.Read.All" -ForegroundColor Gray
    Write-Host "   az rest --method POST ``" -ForegroundColor White
    Write-Host "     --uri `"https://graph.microsoft.com/v1.0/servicePrincipals/$($script:FunctionAppPrincipalId)/appRoleAssignments`" ``" -ForegroundColor White
    Write-Host "     --body `"{\`"principalId\`":\`"$($script:FunctionAppPrincipalId)\`",\`"resourceId\`":\`"`$graphSpId\`",\`"appRoleId\`":\`"06a5fe6d-c49d-46a7-b082-56b1b14103c7\`"}`"" -ForegroundColor White

    Write-Host ""
    Write-Host "   Or use the helper script:" -ForegroundColor Gray
    Write-Host "   .\\deployment\\scripts\\Grant-GraphPermissions.ps1 -ServicePrincipalObjectId `"$($script:FunctionAppPrincipalId)`"" -ForegroundColor White

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Test endpoints (after permissions are granted):"
    if ($functionKey) {
        Write-Host "  Function Key:  $functionKey" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Health:  https://$($script:FunctionAppName).azurewebsites.net/api/export/health?code=$functionKey"
        Write-Host "  Devices: https://$($script:FunctionAppName).azurewebsites.net/api/export/devices?code=$functionKey"
        Write-Host "  Test:    https://$($script:FunctionAppName).azurewebsites.net/api/export/test?code=$functionKey"
    } else {
        Write-Host "  (Get function key from Azure Portal or run:)"
        Write-Host "  az functionapp keys list --name $($script:FunctionAppName) --resource-group $($script:ResourceGroupName)"
        Write-Host ""
        Write-Host "  Health:  https://$($script:FunctionAppName).azurewebsites.net/api/export/health?code=<FUNCTION_KEY>"
        Write-Host "  Devices: https://$($script:FunctionAppName).azurewebsites.net/api/export/devices?code=<FUNCTION_KEY>"
    }
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
Grant-DcrPermissions
Grant-GraphPermissions
Set-FunctionAppConfiguration
Publish-FunctionCode
Deploy-Workbooks
Show-Summary
#endregion
