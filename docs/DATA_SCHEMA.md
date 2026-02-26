# Intune Reporting - Data Schema Reference

This document defines the complete schema for all Log Analytics tables populated by the Intune Reporting solution.

---

## Table of Contents

- [Common Metadata Fields](#common-metadata-fields)
- [IntuneDevices_CL](#intunedevices_cl)
- [IntuneCompliancePolicies_CL](#intunecompliancepolicies_cl)
- [IntuneComplianceStates_CL](#intunecompliancestates_cl)
- [IntuneDeviceScores_CL](#intunedevicescores_cl)
- [IntuneStartupPerformance_CL](#intunestartupperformance_cl)
- [IntuneAppReliability_CL](#intuneappreliability_cl)
- [IntuneAutopilotDevices_CL](#intuneautopilotdevices_cl)
- [IntuneAutopilotProfiles_CL](#intuneautopilotprofiles_cl)
- [IntuneUsers_CL](#intuneusers_cl)
- [IntuneSyncState_CL](#intunesyncstate_cl)
- [Data Relationships](#data-relationships)
- [Sample Queries](#sample-queries)

---

## Common Metadata Fields

These fields are automatically added to every record in all tables:

| Column | Type | Description |
|--------|------|-------------|
| `TimeGenerated` | datetime | UTC timestamp when the record was ingested |
| `IngestionTime` | datetime | UTC timestamp when the record was ingested (same as TimeGenerated) |
| `SourceSystem` | string | Source identifier (e.g., `IntuneDeviceExport`, `IntuneComplianceExport`) |

---

## IntuneDevices_CL

**Description:** Managed device inventory from Intune  
**Update Frequency:** Every 4 hours  
**Source API:** `deviceManagement/managedDevices`

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `DeviceId` | string | Unique Intune device identifier | `12345678-abcd-1234-abcd-123456789012` |
| `DeviceName` | string | Device hostname/name | `DESKTOP-ABC123` |
| `UserPrincipalName` | string | Primary user UPN | `user@contoso.com` |
| `UserDisplayName` | string | Primary user display name | `John Smith` |
| `OperatingSystem` | string | Operating system name | `Windows`, `iOS`, `Android` |
| `OSVersion` | string | Operating system version | `10.0.19045.3803` |
| `ComplianceState` | string | Device compliance state | `compliant`, `noncompliant`, `unknown` |
| `ManagementState` | string | Management state | `managed`, `retirePending` |
| `EnrolledDateTime` | datetime | When the device was enrolled | `2024-01-15T10:30:00Z` |
| `LastSyncDateTime` | datetime | Last successful sync with Intune | `2024-03-20T14:22:00Z` |
| `Manufacturer` | string | Device manufacturer | `Dell Inc.`, `Apple`, `Microsoft Corporation` |
| `Model` | string | Device model | `Latitude 5520`, `iPhone 14 Pro` |
| `SerialNumber` | string | Device serial number | `ABC123DEF456` |
| `IMEI` | string | Mobile device IMEI (if applicable) | `123456789012345` |
| `ManagementAgent` | string | Management agent type | `mdm`, `easMdm`, `configurationManagerClient` |
| `OwnerType` | string | Device ownership type | `company`, `personal`, `unknown` |
| `DeviceEnrollmentType` | string | How the device was enrolled | `userEnrollment`, `deviceEnrollment`, `autopilot` |
| `EmailAddress` | string | Associated email address | `user@contoso.com` |
| `AzureADRegistered` | string | Whether registered in Azure AD | `"true"`, `"false"` |
| `AzureADDeviceId` | string | Azure AD device object ID | `abcd1234-5678-...` |
| `DeviceRegistrationState` | string | Azure AD registration state | `registered`, `notRegistered` |
| `IsEncrypted` | string | Whether device storage is encrypted | `"true"`, `"false"` |
| `IsSupervised` | string | Whether device is supervised (iOS) | `"true"`, `"false"` |
| `JailBroken` | string | Jailbreak/root status | `notJailBroken`, `jailBroken`, `unknown` |
| `AutopilotEnrolled` | string | Whether enrolled via Autopilot | `"true"`, `"false"` |
| `DeviceCategory` | string | Assigned device category | `Corporate`, `Kiosk`, `Shared` |
| `TotalStorageGB` | real | Total storage in GB | `512.00` |
| `FreeStorageGB` | real | Free storage in GB | `234.56` |
| `PhysicalMemoryGB` | real | RAM in GB | `16.00` |
| `WiFiMacAddress` | string | WiFi MAC address | `00:11:22:33:44:55` |
| `EthernetMacAddress` | string | Ethernet MAC address | `00:11:22:33:44:66` |
| `ManagedDeviceName` | string | Intune-assigned display name | `DESKTOP-ABC123_12345` |
| `LastLoggedOnUserId` | string | User ID of the most-recent logged-on user | `abcd1234-5678-...` |
| `LastLoggedOnDateTime` | datetime | Datetime of the most-recent logon | `2024-03-20T08:00:00Z` |
| `UsersLoggedOnCount` | int | Number of users in the logon history array | `1` |
| `UsersLoggedOnJson` | string | JSON array of recent logon records | `[{"userId":"...","lastLogOnDateTime":"..."}]` |
| `ChassisType` | string | Device form factor | `laptop`, `desktop`, `tablet` |
| `ProcessorArchitecture` | string | CPU architecture | `x64`, `arm64` |
| `SkuFamily` | string | Windows SKU family | `Professional` |
| `ManagementFeatures` | string | Additional management feature flags | `microsoftManagedDesktop` |
| `ManagementCertificateExpirationDate` | datetime | When the management certificate expires | `2025-01-15T00:00:00Z` |
| `RetireAfterDateTime` | datetime | Scheduled device retirement date | `2026-06-01T00:00:00Z` |
| `EnrollmentProfileName` | string | Autopilot/enrollment profile name | `Standard Corporate` |
| `JoinType` | string | How the device joined Azure AD | `azureADJoined`, `hybridAzureADJoined` |
| `LostModeState` | string | Lost mode status (iOS only) | `disabled`, `enabled` |
| `PartnerReportedThreatState` | string | Threat state reported by Defender/partner | `activated`, `deactivated` |
| `WindowsActiveMalwareCount` | int | Number of active malware detections | `0` |
| `WindowsRemediatedMalwareCount` | int | Number of remediated malware detections | `0` |
| `Notes` | string | Admin notes on the device | `Loaner device` |

### Key Relationships
- Join to `IntuneComplianceStates_CL` on `DeviceId`
- Join to `IntuneDeviceScores_CL` on `DeviceName` (note: scores use device name)
- Join to `IntuneUsers_CL` on `UserPrincipalName`

---

## IntuneUsers_CL

**Description:** Entra ID user profiles for device enrichment
**Update Frequency:** Daily at 2 AM UTC
**Source API:** `users`

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `UserId` | string | Entra ID object ID | `abcd1234-5678-...` |
| `UserPrincipalName` | string | User UPN | `user@contoso.com` |
| `DisplayName` | string | Display name | `John Smith` |
| `GivenName` | string | First name | `John` |
| `Surname` | string | Last name | `Smith` |
| `Mail` | string | Email address | `john.smith@contoso.com` |
| `JobTitle` | string | Job title | `Senior Engineer` |
| `Department` | string | Department | `Engineering` |
| `EmployeeId` | string | Employee ID | `E12345` |
| `EmployeeType` | string | Employee type | `Employee`, `Contractor` |
| `OfficeLocation` | string | Office location | `London HQ` |
| `City` | string | City | `London` |
| `State` | string | State/region | `England` |
| `Country` | string | Country | `United Kingdom` |
| `UsageLocation` | string | Usage location (2-letter code) | `GB` |
| `AccountEnabled` | bool | Whether the account is active | `true`, `false` |
| `CreatedDateTime` | datetime | Account creation date | `2022-06-01T09:00:00Z` |
| `OnPremisesSyncEnabled` | bool | Synced from on-premises AD | `true`, `false` |
| `OnPremisesDistinguishedName` | string | AD distinguished name | `CN=John Smith,OU=Users,DC=contoso,DC=com` |
| `LastSignInDateTime` | datetime | Last interactive sign-in (requires AuditLog.Read.All) | `2024-03-20T09:00:00Z` |
| `LastNonInteractiveSignInDateTime` | datetime | Last non-interactive sign-in | `2024-03-20T10:00:00Z` |

### Key Relationships
- Join to `IntuneDevices_CL` on `UserPrincipalName` for orphaned device detection and org filtering

---

## IntuneCompliancePolicies_CL

**Description:** Compliance policy definitions  
**Update Frequency:** Every 6 hours  
**Source API:** `deviceManagement/deviceCompliancePolicies`

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `PolicyId` | string | Unique policy identifier | `12345678-abcd-...` |
| `PolicyName` | string | Policy display name | `Windows 10 Compliance Policy` |
| `Description` | string | Policy description | `Requires encryption and PIN` |
| `CreatedDateTime` | datetime | When the policy was created | `2023-06-15T09:00:00Z` |
| `LastModifiedDateTime` | datetime | When the policy was last modified | `2024-02-20T11:30:00Z` |
| `PolicyType` | string | Type of compliance policy | `Windows10`, `iOS`, `Android` |

### Key Relationships
- Join to `IntuneComplianceStates_CL` on `PolicyId`

---

## IntuneComplianceStates_CL

**Description:** Per-device compliance status for each policy  
**Update Frequency:** Every 6 hours  
**Source API:** `deviceManagement/reports/getDeviceStatusByCompliacePolicyReport`

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `DeviceId` | string | Device identifier | `12345678-abcd-...` |
| `DeviceName` | string | Device hostname/name | `DESKTOP-ABC123` |
| `UserId` | string | User identifier | `abcd1234-5678-...` |
| `UserPrincipalName` | string | User UPN | `user@contoso.com` |
| `PolicyId` | string | Policy identifier | `12345678-abcd-...` |
| `PolicyName` | string | Policy display name | `Windows 10 Compliance Policy` |
| `Status` | string | Compliance status (human-readable) | `compliant`, `noncompliant`, `unknown`, `error` |
| `StatusRaw` | int | Compliance status code | `1`=unknown, `2`=compliant, `3`=inGracePeriod, `4`=noncompliant, `5`=error |
| `SettingCount` | int | Number of settings evaluated | (may be null) |
| `FailedSettingCount` | int | Number of failed settings | (may be null) |
| `LastContact` | datetime | Last compliance check time | `2024-03-20T14:00:00Z` |

### Status Code Reference
| Code | Status |
|------|--------|
| 1 | unknown |
| 2 | compliant |
| 3 | inGracePeriod |
| 4 | noncompliant |
| 5 | error |
| 6 | conflict |
| 7 | notApplicable |

### Key Relationships
- Join to `IntuneDevices_CL` on `DeviceId`
- Join to `IntuneCompliancePolicies_CL` on `PolicyId`

---

## IntuneDeviceScores_CL

**Description:** Endpoint Analytics device health scores  
**Update Frequency:** Daily at 8 AM UTC  
**Source API:** `deviceManagement/userExperienceAnalyticsDeviceScores`

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `DeviceId` | string | Device name (used as ID) | `DESKTOP-ABC123` |
| `DeviceName` | string | Device hostname | `DESKTOP-ABC123` |
| `Model` | string | Device model | `Latitude 5520` |
| `Manufacturer` | string | Device manufacturer | `Dell Inc.` |
| `HealthStatus` | string | Overall health status | `MeetsGoals`, `NeedsAttention` |
| `EndpointAnalyticsScore` | real | Overall endpoint analytics score (0-100) | `72.5` |
| `StartupPerformanceScore` | real | Startup performance score (0-100) | `68.0` |
| `AppReliabilityScore` | real | Application reliability score (0-100) | `85.0` |
| `WorkFromAnywhereScore` | real | Work from anywhere readiness score | `90.0` |
| `MeanResourceSpikeTimeScore` | real | Resource spike impact score | `75.0` |
| `BatteryHealthScore` | real | Battery health score (if applicable) | `95.0` |

### Score Interpretation
| Score Range | Rating |
|-------------|--------|
| 80-100 | Excellent |
| 60-79 | Good |
| 40-59 | Fair |
| 20-39 | Poor |
| 0-19 | Critical |

### Key Relationships
- Join to `IntuneDevices_CL` on `DeviceName` (note: use DeviceName, not DeviceId)

---

## IntuneStartupPerformance_CL

**Description:** Device startup/boot performance metrics  
**Update Frequency:** Daily at 8 AM UTC  
**Source API:** `deviceManagement/userExperienceAnalyticsDeviceStartupHistory`

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `DeviceId` | string | Device identifier | `12345678-abcd-...` |
| `StartTime` | datetime | When the startup occurred | `2024-03-20T08:30:00Z` |
| `CoreBootTimeInMs` | int | Core boot time in milliseconds | `15000` |
| `GroupPolicyBootTimeInMs` | int | Group Policy processing during boot (ms) | `5000` |
| `GroupPolicyLoginTimeInMs` | int | Group Policy processing during login (ms) | `3000` |
| `CoreLoginTimeInMs` | int | Core login time in milliseconds | `8000` |
| `TotalBootTimeInMs` | int | Total boot time in milliseconds | `45000` |
| `TotalLoginTimeInMs` | int | Total login time in milliseconds | `20000` |
| `IsFirstLogin` | bool | Whether this was user's first login | `false` |
| `IsFeatureUpdate` | bool | Whether a feature update was applied | `false` |
| `OperatingSystemVersion` | string | OS version at startup time | `10.0.19045.3803` |
| `RestartCategory` | string | Type of restart | `normalBoot`, `updateInitiated`, `blueScreen` |
| `RestartFaultBucket` | string | Fault bucket for crashes | (crash identifier if applicable) |

### Key Relationships
- Join to `IntuneDevices_CL` on `DeviceId`

---

## IntuneAppReliability_CL

**Description:** Application health and reliability metrics  
**Update Frequency:** Daily at 8 AM UTC  
**Source API:** `deviceManagement/userExperienceAnalyticsAppHealthApplicationPerformance`

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `AppName` | string | Application executable name | `outlook.exe` |
| `AppDisplayName` | string | Application display name | `Microsoft Outlook` |
| `AppPublisher` | string | Application publisher | `Microsoft Corporation` |
| `ActiveDeviceCount` | int | Number of devices with app installed | `5234` |
| `AppCrashCount` | int | Total crash count across all devices | `12` |
| `AppHangCount` | int | Total hang count across all devices | `5` |
| `MeanTimeToFailureInMinutes` | int | Average minutes between failures | `4320` |
| `AppHealthScore` | real | Application health score (0-100) | `92.5` |
| `AppHealthStatus` | string | Health status classification | `MeetsGoals`, `NeedsAttention` |

### Key Relationships
- This table contains aggregate app data, not per-device records
- Cross-reference with `IntuneDevices_CL` for device counts

---

## IntuneAutopilotDevices_CL

**Description:** Windows Autopilot device identities  
**Update Frequency:** Daily at 6 AM UTC  
**Source API:** `deviceManagement/windowsAutopilotDeviceIdentities`

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `AutopilotDeviceId` | string | Autopilot device identity ID | `12345678-abcd-...` |
| `SerialNumber` | string | Device serial number | `ABC123DEF456` |
| `ProductKey` | string | Windows product key (if captured) | `XXXXX-XXXXX-...` |
| `Manufacturer` | string | Device manufacturer | `Dell Inc.` |
| `Model` | string | Device model | `Latitude 5520` |
| `GroupTag` | string | Assigned group tag | `Corporate-Standard` |
| `PurchaseOrderIdentifier` | string | Purchase order reference | `PO-2024-001` |
| `EnrollmentState` | string | Current enrollment state | `enrolled`, `pendingReset`, `failed` |
| `DeploymentProfileAssignmentStatus` | string | Profile assignment status | `assignedInSync`, `notAssigned`, `pending` |
| `DeploymentProfileAssignedDateTime` | datetime | When profile was assigned | `2024-01-15T10:00:00Z` |
| `LastContactedDateTime` | datetime | Last communication with Autopilot | `2024-03-20T12:00:00Z` |
| `AddressableUserName` | string | Pre-assigned user name | `jsmith` |
| `UserPrincipalName` | string | Pre-assigned user UPN | `jsmith@contoso.com` |
| `ResourceName` | string | Resource name | `DESKTOP-ABC123` |
| `AzureActiveDirectoryDeviceId` | string | Azure AD device ID | `abcd1234-...` |
| `ManagedDeviceId` | string | Intune managed device ID | `12345678-...` |
| `DisplayName` | string | Device display name | `John's Laptop` |

### Enrollment State Reference
| Code | State |
|------|-------|
| 0 | unknown |
| 1 | enrolled |
| 2 | pendingReset |
| 3 | failed |
| 4 | notContacted |
| 5 | blocked |

### Assignment Status Reference
| Code | Status |
|------|--------|
| 0 | unknown |
| 1 | assignedInSync |
| 2 | assignedOutOfSync |
| 3 | assignedUnknownSyncState |
| 4 | notAssigned |
| 5 | pending |
| 6 | failed |

### Key Relationships
- Join to `IntuneDevices_CL` on `ManagedDeviceId` = `DeviceId` (for enrolled devices)
- Join to `IntuneAutopilotProfiles_CL` for profile information

---

## IntuneAutopilotProfiles_CL

**Description:** Windows Autopilot deployment profile configurations  
**Update Frequency:** Daily at 6 AM UTC  
**Source API:** `deviceManagement/windowsAutopilotDeploymentProfiles`

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `ProfileId` | string | Profile identifier | `12345678-abcd-...` |
| `DisplayName` | string | Profile name | `Standard Corporate Deployment` |
| `Description` | string | Profile description | `Default profile for corporate devices` |
| `CreatedDateTime` | datetime | When the profile was created | `2023-06-01T09:00:00Z` |
| `LastModifiedDateTime` | datetime | When the profile was last modified | `2024-02-15T14:00:00Z` |
| `Language` | string | Default language | `en-US` |
| `DeviceNameTemplate` | string | Device naming template | `CORP-%SERIAL%` |
| `DeviceType` | string | Target device type | `windowsPc`, `surfaceHub2` |
| `EnableWhiteGlove` | bool | White glove provisioning enabled | `true`, `false` |
| `ExtractHardwareHash` | bool | Extract hardware hash during OOBE | `true`, `false` |
| `OutOfBoxExperienceSettings` | string | OOBE settings (JSON) | `{"hidePrivacySettings": true, ...}` |
| `ProfileType` | string | Profile type classification | `AzureADJoined`, `HybridAzureADJoined` |

### OutOfBoxExperienceSettings JSON Structure
```json
{
  "hidePrivacySettings": true,
  "hideEULA": true,
  "userType": "standard",
  "deviceUsageType": "singleUser",
  "skipKeyboardSelectionPage": true,
  "hideEscapeLink": true
}
```

---

## IntuneSyncState_CL

**Description:** Sync operation tracking and health status  
**Update Frequency:** On-demand (via manual_trigger test endpoint)  
**Source:** Internal sync tracking

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `ExportType` | string | Type of export operation | `TestIngestion`, `devices`, `compliance` |
| `RecordCount` | int | Number of records in the operation | `1` |
| `Status` | string | Result status | `Success`, `Failed` |
| `DurationSeconds` | real | Operation duration in seconds | `0.5` |
| `ErrorMessage` | string | Error details if failed, null otherwise | `null` or error text |

---

## Data Relationships

```
┌─────────────────────────┐     ┌─────────────────────────┐
│   IntuneDevices_CL      │────▶│   IntuneUsers_CL        │
│   (DeviceId)            │     │   (UserPrincipalName)   │
└───────────┬─────────────┘     └─────────────────────────┘
            │
    ┌───────┴───────┬──────────────────┐
    │               │                  │
    ▼               ▼                  ▼
┌─────────────┐ ┌─────────────────┐ ┌─────────────────────┐
│ Compliance  │ │ DeviceScores    │ │ StartupPerformance  │
│ States_CL   │ │ (DeviceName)    │ │ (DeviceId)          │
│ (DeviceId)  │ └─────────────────┘ └─────────────────────┘
└──────┬──────┘
       │
       ▼
┌─────────────────────────┐
│ CompliancePolicies_CL   │
│ (PolicyId)              │
└─────────────────────────┘

┌─────────────────────────┐     ┌─────────────────────────┐
│ AutopilotDevices_CL     │────▶│ AutopilotProfiles_CL    │
│ (ManagedDeviceId)       │     │ (ProfileId)             │
└─────────────────────────┘     └─────────────────────────┘
```

### Join Keys Summary

| From Table | To Table | Join Columns |
|------------|----------|--------------|
| IntuneDevices_CL | IntuneComplianceStates_CL | DeviceId = DeviceId |
| IntuneDevices_CL | IntuneDeviceScores_CL | DeviceName = DeviceName |
| IntuneDevices_CL | IntuneStartupPerformance_CL | DeviceId = DeviceId |
| IntuneDevices_CL | IntuneUsers_CL | UserPrincipalName = UserPrincipalName |
| IntuneComplianceStates_CL | IntuneCompliancePolicies_CL | PolicyId = PolicyId |
| IntuneAutopilotDevices_CL | IntuneDevices_CL | ManagedDeviceId = DeviceId |

---

## Sample Queries

### Device Overview with Compliance
```kusto
IntuneDevices_CL
| where TimeGenerated > ago(1d)
| summarize arg_max(TimeGenerated, *) by DeviceId
| join kind=leftouter (
    IntuneComplianceStates_CL
    | where TimeGenerated > ago(1d)
    | summarize 
        NonCompliantPolicies = countif(Status == "noncompliant"),
        TotalPolicies = count() 
      by DeviceId
) on DeviceId
| project DeviceName, UserPrincipalName, OperatingSystem, ComplianceState, 
          NonCompliantPolicies, TotalPolicies, LastSyncDateTime
| order by NonCompliantPolicies desc
```

### Device Health with Inventory
```kusto
IntuneDeviceScores_CL
| where TimeGenerated > ago(1d)
| summarize arg_max(TimeGenerated, *) by DeviceName
| join kind=inner (
    IntuneDevices_CL
    | where TimeGenerated > ago(1d)
    | summarize arg_max(TimeGenerated, *) by DeviceId
    | project DeviceId, DeviceName, UserPrincipalName, OperatingSystem
) on DeviceName
| project DeviceName, UserPrincipalName, OperatingSystem, 
          EndpointAnalyticsScore, StartupPerformanceScore, AppReliabilityScore, HealthStatus
| order by EndpointAnalyticsScore asc
```

### Compliance by Policy
```kusto
IntuneComplianceStates_CL
| where TimeGenerated > ago(1d)
| summarize arg_max(TimeGenerated, *) by DeviceId, PolicyId
| summarize 
    Compliant = countif(Status == "compliant"),
    NonCompliant = countif(Status == "noncompliant"),
    Total = count()
  by PolicyName
| extend ComplianceRate = round(100.0 * Compliant / Total, 1)
| order by ComplianceRate asc
```

### Stale Devices
```kusto
IntuneDevices_CL
| where TimeGenerated > ago(1d)
| summarize arg_max(TimeGenerated, *) by DeviceId
| extend DaysSinceSync = datetime_diff('day', now(), LastSyncDateTime)
| where DaysSinceSync > 14
| project DeviceName, UserDisplayName, OperatingSystem, DaysSinceSync, LastSyncDateTime, ComplianceState
| order by DaysSinceSync desc
```

### Autopilot Deployment Status
```kusto
IntuneAutopilotDevices_CL
| where TimeGenerated > ago(1d)
| summarize arg_max(TimeGenerated, *) by AutopilotDeviceId
| summarize Count = count() by EnrollmentState, DeploymentProfileAssignmentStatus
| order by Count desc
```

### Application Reliability Issues
```kusto
IntuneAppReliability_CL
| where TimeGenerated > ago(7d)
| summarize arg_max(TimeGenerated, *) by AppName
| where AppCrashCount > 0 or AppHangCount > 0
| project AppDisplayName, AppPublisher, ActiveDeviceCount, AppCrashCount, AppHangCount, 
          MeanTimeToFailureInMinutes, AppHealthScore
| order by AppCrashCount desc
| take 20
```

---

## Data Retention

All custom tables are configured with **30-day retention** by default. This can be adjusted in the Log Analytics workspace settings.

## Update Schedule Summary

| Table | Schedule | Typical Records |
|-------|----------|-----------------|
| IntuneDevices_CL | Every 4 hours | 8,000+ |
| IntuneCompliancePolicies_CL | Every 6 hours | 10-50 |
| IntuneComplianceStates_CL | Every 6 hours | 13,000+ |
| IntuneDeviceScores_CL | Daily 8 AM UTC | 4,000+ |
| IntuneStartupPerformance_CL | Daily 8 AM UTC | Varies |
| IntuneAppReliability_CL | Daily 8 AM UTC | 100-500 |
| IntuneAutopilotDevices_CL | Daily 6 AM UTC | Varies |
| IntuneAutopilotProfiles_CL | Daily 6 AM UTC | 5-20 |
| IntuneUsers_CL | Daily 2 AM UTC | Varies |
