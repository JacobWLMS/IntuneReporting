# Update DCR Schema to match Python export fields
# Run this to fix the Log Analytics ingestion

$ResourceGroup = "ancIntuneReporting-Dev"
$DcrName = "graphreports-dcr"
$SubscriptionId = "1a51ea5e-d9ee-453e-94e5-cb61b5cd93cf"
$Location = "uksouth"

# Get auth token (handle SecureString in newer Az versions)
$tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
if ($tokenResponse.Token -is [System.Security.SecureString]) {
    $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenResponse.Token))
} else {
    $token = $tokenResponse.Token
}
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# Get existing DCR to preserve settings
$dcrUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$DcrName`?api-version=2022-06-01"
$existingDcr = Invoke-RestMethod -Uri $dcrUri -Headers $headers -Method Get
Write-Host "Got existing DCR, preserving DCE and workspace settings..."

# Build complete stream declarations
$streamDeclarations = @{
    "Custom-IntuneDevices_CL" = @{
        columns = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            # Identity
            @{name="DeviceId"; type="string"}
            @{name="DeviceName"; type="string"}
            @{name="ManagedDeviceName"; type="string"}
            @{name="AzureADDeviceId"; type="string"}
            @{name="SerialNumber"; type="string"}
            @{name="IMEI"; type="string"}
            # Primary user
            @{name="UserPrincipalName"; type="string"}
            @{name="UserDisplayName"; type="string"}
            @{name="EmailAddress"; type="string"}
            # Last logged-on user (key for stale device detection)
            @{name="LastLoggedOnUserId"; type="string"}
            @{name="LastLoggedOnDateTime"; type="datetime"}
            @{name="UsersLoggedOnCount"; type="int"}
            @{name="UsersLoggedOnJson"; type="string"}
            # OS & hardware
            @{name="OperatingSystem"; type="string"}
            @{name="OSVersion"; type="string"}
            @{name="Manufacturer"; type="string"}
            @{name="Model"; type="string"}
            @{name="ChassisType"; type="string"}
            @{name="ProcessorArchitecture"; type="string"}
            @{name="SkuFamily"; type="string"}
            @{name="TotalStorageGB"; type="real"}
            @{name="FreeStorageGB"; type="real"}
            @{name="PhysicalMemoryGB"; type="real"}
            @{name="WiFiMacAddress"; type="string"}
            @{name="EthernetMacAddress"; type="string"}
            # Enrollment & management
            @{name="EnrolledDateTime"; type="datetime"}
            @{name="LastSyncDateTime"; type="datetime"}
            @{name="ManagementState"; type="string"}
            @{name="ManagementAgent"; type="string"}
            @{name="ManagementFeatures"; type="string"}
            @{name="ManagementCertificateExpirationDate"; type="datetime"}
            @{name="RetireAfterDateTime"; type="datetime"}
            @{name="OwnerType"; type="string"}
            @{name="DeviceEnrollmentType"; type="string"}
            @{name="EnrollmentProfileName"; type="string"}
            @{name="AutopilotEnrolled"; type="string"}
            @{name="JoinType"; type="string"}
            # Registration & compliance
            @{name="AzureADRegistered"; type="string"}
            @{name="DeviceRegistrationState"; type="string"}
            @{name="ComplianceState"; type="string"}
            @{name="DeviceCategory"; type="string"}
            # Security
            @{name="IsEncrypted"; type="string"}
            @{name="IsSupervised"; type="string"}
            @{name="JailBroken"; type="string"}
            @{name="LostModeState"; type="string"}
            @{name="PartnerReportedThreatState"; type="string"}
            @{name="WindowsActiveMalwareCount"; type="int"}
            @{name="WindowsRemediatedMalwareCount"; type="int"}
            # Notes
            @{name="Notes"; type="string"}
        )
    }
    "Custom-IntuneUsers_CL" = @{
        columns = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            # Identity
            @{name="UserId"; type="string"}
            @{name="UserPrincipalName"; type="string"}
            @{name="DisplayName"; type="string"}
            @{name="GivenName"; type="string"}
            @{name="Surname"; type="string"}
            @{name="Mail"; type="string"}
            # Role & org
            @{name="JobTitle"; type="string"}
            @{name="Department"; type="string"}
            @{name="EmployeeId"; type="string"}
            @{name="EmployeeType"; type="string"}
            # Location
            @{name="OfficeLocation"; type="string"}
            @{name="City"; type="string"}
            @{name="State"; type="string"}
            @{name="Country"; type="string"}
            @{name="UsageLocation"; type="string"}
            # Account status
            @{name="AccountEnabled"; type="boolean"}
            @{name="CreatedDateTime"; type="datetime"}
            # Hybrid identity
            @{name="OnPremisesSyncEnabled"; type="boolean"}
            @{name="OnPremisesDistinguishedName"; type="string"}
            # Sign-in activity (requires AuditLog.Read.All)
            @{name="LastSignInDateTime"; type="datetime"}
            @{name="LastNonInteractiveSignInDateTime"; type="datetime"}
        )
    }
    "Custom-IntuneCompliancePolicies_CL" = @{
        columns = @(
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
    }
    "Custom-IntuneComplianceStates_CL" = @{
        columns = @(
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
            @{name="LastContact"; type="string"}
        )
    }
    "Custom-IntuneDeviceScores_CL" = @{
        columns = @(
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
    }
    "Custom-IntuneStartupPerformance_CL" = @{
        columns = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="DeviceId"; type="string"}
            @{name="StartTime"; type="datetime"}
            @{name="CoreBootTimeInMs"; type="long"}
            @{name="GroupPolicyBootTimeInMs"; type="long"}
            @{name="GroupPolicyLoginTimeInMs"; type="long"}
            @{name="CoreLoginTimeInMs"; type="long"}
            @{name="TotalBootTimeInMs"; type="long"}
            @{name="TotalLoginTimeInMs"; type="long"}
            @{name="IsFirstLogin"; type="boolean"}
            @{name="IsFeatureUpdate"; type="boolean"}
            @{name="OperatingSystemVersion"; type="string"}
            @{name="RestartCategory"; type="string"}
            @{name="RestartFaultBucket"; type="string"}
        )
    }
    "Custom-IntuneAppReliability_CL" = @{
        columns = @(
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
    }
    "Custom-IntuneAutopilotDevices_CL" = @{
        columns = @(
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
    }
    "Custom-IntuneAutopilotProfiles_CL" = @{
        columns = @(
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
    }
    "Custom-IntuneSyncState_CL" = @{
        columns = @(
            @{name="TimeGenerated"; type="datetime"}
            @{name="IngestionTime"; type="datetime"}
            @{name="SourceSystem"; type="string"}
            @{name="ExportType"; type="string"}
            @{name="RecordCount"; type="long"}
            @{name="DurationSeconds"; type="real"}
            @{name="Status"; type="string"}
        )
    }
}

# Build data flows
$dataFlows = @()
foreach ($streamName in $streamDeclarations.Keys) {
    $dataFlows += @{
        streams = @($streamName)
        destinations = @("logAnalyticsWorkspace")
        transformKql = "source"
        outputStream = $streamName
    }
}

# Build updated DCR body preserving existing settings
$dcrBody = @{
    location = $Location
    properties = @{
        dataCollectionEndpointId = $existingDcr.properties.dataCollectionEndpointId
        streamDeclarations = $streamDeclarations
        destinations = $existingDcr.properties.destinations
        dataFlows = $dataFlows
    }
} | ConvertTo-Json -Depth 15

Write-Host "Updating DCR with full schema..."
$result = Invoke-RestMethod -Uri $dcrUri -Headers $headers -Method Put -Body $dcrBody
Write-Host "DCR updated! Immutable ID: $($result.properties.immutableId)" -ForegroundColor Green
