# Supplemental Data Opportunities

**Goal:** Add 3-5 lightweight API calls that enhance existing dashboards without significant ingestion costs.

**Design Principles:**
- ✅ Aggregate/summary endpoints only (1-200 rows)
- ✅ Failures and exceptions only (not successes)
- ❌ Per-device state data

---

## Recommended Endpoints (Priority Order)

### 1. Battery Health by Device ⭐ HIGHEST VALUE
**Why:** Per-device battery status for replacement planning and user outreach.

| Endpoint | Rows | Frequency |
|----------|------|-----------|
| `GET /deviceManagement/userExperienceAnalyticsBatteryHealthDevicePerformance` | **~10-20k** | Daily |

**Table:** `IntuneBatteryHealth_CL`

**Fields:**
- `deviceId`, `deviceName`
- `model`, `manufacturer`
- `maxCapacityPercentage`
- `estimatedRuntimeInMinutes`
- `batteryAgeInDays`
- `healthStatus` (sufficient, insufficientData, needsAttention, poorHealth)
- `fullBatteryDrainCount`

**Dashboard Use:** 
- "Devices Needing Battery Replacement" table (filter `healthStatus ne 'sufficient'`)
- Battery health distribution charts
- Aggregate by model to identify problematic hardware lines
- Sort by `maxCapacityPercentage` to prioritize worst cases

**Alert:** Devices with `healthStatus eq 'poorHealth'`

**Why this is OK:** One row per device (~10-20k), not per-device × per-policy.

---

### 2. Device Encryption Status (BitLocker) ⭐ HIGHEST VALUE
**Why:** Current dashboards show encryption as 0 - this endpoint has the actual BitLocker state.

| Endpoint | Rows | Frequency |
|----------|------|-----------|
| `GET /deviceManagement/managedDeviceEncryptionStates` | **~10-20k** | Daily |

**Table:** `IntuneEncryptionStatus_CL`

**Fields:**
- `id`, `deviceName`, `userPrincipalName`
- `osVersion`, `deviceType`
- `encryptionState` (notEncrypted, encrypted)
- `encryptionPolicySettingState` (compliant, nonCompliant, error, notApplicable)
- `advancedBitLockerStates` (detailed flags like tpmAndPinProtector, recoveryKeyEscrowed, etc.)
- `encryptionReadinessState` (ready, notReady)
- `fileVaultStates` (for macOS)

**Dashboard Use:** 
- "Unencrypted Devices" list (filter `encryptionState eq 'notEncrypted'`)
- Encryption compliance pie chart
- BitLocker readiness tracking
- Recovery key escrow status

**Alert:** Devices where `encryptionState eq 'notEncrypted'` and `encryptionReadinessState eq 'ready'`

**Why this is OK:** One row per device with encryption state - not per-policy.

---

### 3. Model Scores (Endpoint Analytics by Model)
**Why:** Identify problematic hardware models fleet-wide, not just individual devices.

| Endpoint | Rows | Frequency |
|----------|------|-----------|
| `GET /deviceManagement/userExperienceAnalyticsModelScores` | **~20-50** | Daily |

**Table:** `IntuneModelScores_CL`

**Fields:**
- `model`, `manufacturer`
- `modelDeviceCount`
- `endpointAnalyticsScore`
- `startupPerformanceScore`
- `appReliabilityScore`
- `workFromAnywhereScore`
- `healthStatus`

**Dashboard Use:** "Model Performance Comparison" table, hardware procurement decisions

**Alert:** `healthStatus eq 'needsAttention'` with `modelDeviceCount > 50`

---

### 4. Compliance Setting Summary (Compliance Dashboard)
**Why:** Know which specific compliance settings are failing most - not just policy-level status.

| Endpoint | Rows | Frequency |
|----------|------|-----------|
| `GET /deviceManagement/deviceCompliancePolicySettingStateSummaries` | **~50-100** | Daily |

**Table:** `IntuneComplianceSettingSummary_CL`

**Fields:**
- `settingName` (e.g., "Require BitLocker", "Minimum OS Version")
- `compliantDeviceCount`
- `nonCompliantDeviceCount`
- `errorDeviceCount`
- `conflictDeviceCount`
- `notApplicableDeviceCount`

**Dashboard Use:** 
- "Top 10 Failing Compliance Settings" bar chart
- Prioritize remediation efforts
- "BitLocker is causing 60% of noncompliance"

**Alert:** `nonCompliantDeviceCount` increased by >10% from previous day

---

### 5. Configuration Profile Summary (Device Health Dashboard)
**Why:** Know which config profiles have issues without per-device data.

| Endpoint | Rows | Frequency |
|----------|------|-----------|
| `GET /deviceManagement/deviceConfigurations?$expand=deviceStatusOverview` | **~50-200** | Daily |

**Table:** `IntuneConfigProfileSummary_CL`

**Fields:**
- `id`, `displayName`, `lastModifiedDateTime`
- `deviceStatusOverview.configuredDeviceCount` (total assigned)
- `deviceStatusOverview.errorDeviceCount`
- `deviceStatusOverview.failedDeviceCount`
- `deviceStatusOverview.conflictDeviceCount`

**Dashboard Use:** "Config Profiles with Errors" table, profile health heatmap

**Alert:** `errorDeviceCount > 0` or `failedDeviceCount > 10`

---

### 6. Configuration Profile Failures (Exception-Only)
**Why:** When a profile has errors, you need to know which devices.

| Endpoint | Rows | Frequency |
|----------|------|-----------|
| `GET /deviceManagement/deviceConfigurations/{id}/deviceStatuses?$filter=status eq 'error' or status eq 'failed' or status eq 'conflict'` | **~10-100 per profile** | Daily |

**Note:** Only query profiles where `errorDeviceCount > 0` from the summary above.

**Table:** `IntuneConfigProfileFailures_CL`

**Fields:**
- `profileId`, `profileDisplayName`
- `deviceDisplayName`, `userName`
- `status`, `lastReportedDateTime`

**Dashboard Use:** Drill-down from profile summary to specific failed devices

---

## Summary

| # | Data | Dashboard | Daily Rows | Row Type |
|---|------|-----------|------------|----------|
| 1 | Battery Health | Device Health | ~10-20k | Per device |
| 2 | **Encryption Status** | Device Health | ~10-20k | Per device |
| 3 | Model Scores | Device Health | ~30 | Per model |
| 4 | Compliance Setting Summary | Compliance | ~80 | Per setting |
| 5 | Config Profile Summary | Device Health | ~100 | Per profile |
| 6 | Config Profile Failures | Device Health | ~50-500 | Per failure |

**Total estimated daily ingestion:** ~20-40k rows

**What we avoid:** Per-device × per-policy × per-setting (millions of rows)

**What's OK:** Per-device with a single state (battery, encryption) - one row per device

---

## Implementation

### Required Permissions
```
DeviceManagementConfiguration.Read.All
DeviceManagementManagedDevices.Read.All
```

### Suggested Functions
```
functions/
  export_battery_health/             # Daily
  export_encryption_status/          # Daily
  export_model_scores/               # Daily
  export_compliance_setting_summary/ # Daily
  export_config_profile_summary/     # Daily
  export_config_profile_failures/    # Daily (after summary)
```
