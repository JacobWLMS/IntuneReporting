# Supplemental Data Opportunities for Intune Dashboards

This document identifies opportunities to enhance the Device Health, Device Inventory, and Autopilot Deployment dashboards with additional data from Microsoft Graph API endpoints.

---

## 📊 Device Health Workbook

### Current Data Sources
- `IntuneDevices_CL` - Basic device info and sync status
- `IntuneDeviceScores_CL` - Endpoint Analytics scores
- `IntuneStartupPerformance_CL` - Boot/login performance
- `IntuneAppReliability_CL` - Application crash/hang data

### Supplemental Data Opportunities

#### 1. Windows Update Status
**Gap:** No visibility into update compliance, pending updates, or update history.

**Benefit:** Identify devices missing critical security updates, track update deployment success rates.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/windowsUpdateCatalogItems` | Available Windows updates |
| `GET /deviceManagement/softwareUpdateStatusSummary` | Update deployment status summary |
| `GET /deviceManagement/deviceConfigurations/{id}/deviceStatuses` | Per-device update ring status |
| `GET /admin/windows/updates/deployments` | Windows Update for Business deployments |
| `GET /admin/windows/updates/updatableAssets` | Assets eligible for updates |

**Suggested Table:** `IntuneWindowsUpdates_CL`

---

#### 2. Microsoft Defender Status
**Gap:** No security health information (antivirus status, threat detections, firewall state).

**Benefit:** Correlate health scores with security posture, identify compromised devices.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/managedDevices/{id}/windowsProtectionState` | Defender status per device |
| `GET /security/alerts_v2` | Security alerts and threats |
| `GET /deviceManagement/deviceProtectionOverview` | Protection summary stats |
| `GET /security/secureScores` | Tenant security score |

**Suggested Table:** `IntuneDefenderStatus_CL`

**Key Fields to Capture:**
- `antiMalwareVersion`
- `engineVersion`
- `signatureVersion`
- `malwareProtectionEnabled`
- `realTimeProtectionEnabled`
- `networkInspectionSystemEnabled`
- `quickScanOverdue`, `fullScanOverdue`, `signatureUpdateOverdue`
- `rebootRequired`
- `lastQuickScanDateTime`, `lastFullScanDateTime`

---

#### 3. Battery Health Details
**Gap:** Only have BatteryHealthScore in IntuneDeviceScores_CL, no cycle count or capacity data.

**Benefit:** Proactively identify devices needing battery replacement.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/userExperienceAnalyticsBatteryHealthDevicePerformance` | Per-device battery metrics |
| `GET /deviceManagement/userExperienceAnalyticsBatteryHealthModelPerformance` | Battery health by model |
| `GET /deviceManagement/userExperienceAnalyticsBatteryHealthOsPerformance` | Battery health by OS |

**Suggested Table:** `IntuneBatteryHealth_CL`

**Key Fields to Capture:**
- `estimatedRuntimeInMinutes`
- `maxCapacityPercentage`
- `healthStatus` (good, degraded, replace, unknown)
- `batteryAgeInDays`
- `fullBatteryDrainCount`
- `activeDevices`

---

#### 4. Resource Performance (CPU/Memory Spikes)
**Gap:** Have MeanResourceSpikeTimeScore but no detailed resource utilization data.

**Benefit:** Identify devices with performance bottlenecks, memory leaks.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/userExperienceAnalyticsResourcePerformance` | CPU/memory performance data |
| `GET /deviceManagement/userExperienceAnalyticsDevicePerformance` | Device performance summary |

**Suggested Table:** `IntuneResourcePerformance_CL`

**Key Fields to Capture:**
- `cpuSpikeTimePercentage`
- `ramSpikeTimePercentage`
- `cpuSpikeTimeScore`
- `ramSpikeTimeScore`
- `deviceResourcePerformanceScore`

---

#### 5. Model/Hardware Quality Insights
**Gap:** Can identify problematic models but lack context on why.

**Benefit:** Make data-driven hardware procurement decisions.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/userExperienceAnalyticsModelScores` | Aggregate scores by model |
| `GET /deviceManagement/userExperienceAnalyticsDeviceScopes` | Custom device scopes for comparison |

**Suggested Table:** `IntuneModelScores_CL`

---

## 📦 Device Inventory Workbook

### Current Data Sources
- `IntuneDevices_CL` - Device inventory with basic properties

### Supplemental Data Opportunities

#### 1. Installed Applications
**Gap:** No visibility into what software is installed on devices.

**Benefit:** Software license management, identify unauthorized apps, security vulnerability assessment.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/managedDevices/{id}/detectedApps` | Apps detected on a device |
| `GET /deviceManagement/detectedApps` | All detected apps with device counts |
| `GET /deviceManagement/detectedApps/{id}/managedDevices` | Devices with specific app |

**Suggested Table:** `IntuneDetectedApps_CL`

**Key Fields to Capture:**
- `displayName`
- `version`
- `platform`
- `publisher`
- `deviceCount`
- `sizeInByte`

---

#### 2. Hardware Inventory Details
**Gap:** Missing RAM, CPU, TPM version, BIOS version, Secure Boot status.

**Benefit:** Hardware lifecycle management, Windows 11 readiness, security compliance.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/managedDevices/{id}?$select=hardwareInformation` | Detailed hardware info |
| `GET /deviceManagement/windowsAutopilotDeviceIdentities/{id}` | Hardware hash, TPM info |

**Suggested Table:** `IntuneHardwareInventory_CL`

**Key Fields to Capture:**
- `totalStorageSpace`, `freeStorageSpace` (already have)
- `physicalMemoryInBytes`
- `processorArchitecture`
- `tpmSpecificationVersion`
- `tpmManufacturer`
- `systemManagementBIOSVersion`
- `isSharedDevice`
- `sharedDeviceCachedUsers`

---

#### 3. Configuration Profile Status
**Gap:** No visibility into which profiles are applied and their status.

**Benefit:** Troubleshoot configuration issues, verify policy deployment.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/managedDevices/{id}/deviceConfigurationStates` | Config profiles on device |
| `GET /deviceManagement/deviceConfigurations/{id}/deviceStatuses` | Devices and their status for a profile |
| `GET /deviceManagement/deviceConfigurations` | All configuration profiles |

**Suggested Table:** `IntuneConfigurationStatus_CL`

**Key Fields to Capture:**
- `displayName` (profile name)
- `state` (succeeded, failed, conflict, error, notApplicable)
- `version`
- `platformType`
- `settingCount`

---

#### 4. Group Memberships
**Gap:** Can't see what Entra ID groups devices belong to.

**Benefit:** Understand targeting, troubleshoot policy application.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /devices/{id}/memberOf` | Groups a device belongs to |
| `GET /deviceManagement/managedDevices/{id}/deviceCategory` | Assigned device category |

**Suggested Table:** `IntuneDeviceGroups_CL`

---

#### 5. App Protection Policy Status
**Gap:** No visibility into MAM policies applied to devices.

**Benefit:** Verify data protection on BYOD devices.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceAppManagement/managedAppRegistrations` | MAM registered apps |
| `GET /deviceAppManagement/mdmWindowsInformationProtectionPolicies` | WIP policies |
| `GET /deviceAppManagement/managedAppStatuses` | MAM status summary |

**Suggested Table:** `IntuneAppProtectionStatus_CL`

---

#### 6. Certificates
**Gap:** No visibility into certificate deployment status.

**Benefit:** Troubleshoot Wi-Fi/VPN issues, certificate expiration monitoring.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/managedDevices/{id}/managedDeviceCertificateStates` | Certificates on device |

**Suggested Table:** `IntuneDeviceCertificates_CL`

**Key Fields to Capture:**
- `certificateSubjectName`
- `certificateExpirationDateTime`
- `certificateIssuanceState`
- `certificateIssuer`
- `certificateThumbprint`

---

## 🚀 Autopilot Deployment Workbook

### Current Data Sources
- `IntuneAutopilotDevices_CL` - Autopilot device identities
- `IntuneAutopilotProfiles_CL` - Deployment profiles

### Supplemental Data Opportunities

#### 1. Enrollment Status Page (ESP) Results
**Gap:** Know devices failed but not which apps/policies caused failures.

**Benefit:** Identify blocking apps, reduce deployment time.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/deviceEnrollmentConfigurations` | ESP configurations |
| `GET /deviceManagement/depOnboardingSettings/{id}/enrollmentProfiles` | Enrollment profiles |
| `GET /deviceManagement/autopilotEvents` | Detailed deployment events |

**Suggested Table:** `IntuneAutopilotEvents_CL`

**Key Fields to Capture:**
- `deviceId`
- `eventDateTime`
- `deviceRegisteredDateTime`
- `enrollmentStartDateTime`
- `enrollmentType`
- `deviceSetupDuration`
- `accountSetupDuration`
- `deviceSetupStatus`
- `accountSetupStatus`
- `enrollmentState`
- `targetedAppCount`
- `targetedPolicyCount`

---

#### 2. App Installation Status During Enrollment
**Gap:** Can't see which required apps succeeded/failed during Autopilot.

**Benefit:** Identify apps causing enrollment delays or failures.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/autopilotEvents/{id}/policyStatusDetails` | Policy install status during Autopilot |
| `GET /deviceAppManagement/mobileApps/{id}/deviceStatuses` | App install status per device |

**Suggested Table:** `IntuneAutopilotAppStatus_CL`

---

#### 3. Pre-provisioning (White Glove) Status
**Gap:** No visibility into technician pre-provisioning phase results.

**Benefit:** Track partner/IT pre-provisioning success rates.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/windowsAutopilotDeploymentProfiles/{id}` | Profile with pre-provisioning settings |
| `GET /deviceManagement/autopilotEvents?$filter=deploymentState eq 'preProvisioned'` | Pre-provisioned events |

**Key Fields to Capture:**
- `osVersion`
- `deploymentState`
- `deploymentDuration`
- `deploymentTotalDuration`
- `devicePreparationDuration`
- `deviceSetupDuration`
- `accountSetupDuration`

---

#### 4. Enrollment Failure Details
**Gap:** Know enrollment failed but not the specific error codes/messages.

**Benefit:** Faster troubleshooting, pattern identification.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/troubleshootingEvents` | Enrollment troubleshooting events |
| `GET /deviceManagement/importedWindowsAutopilotDeviceIdentities` | Import status with errors |

**Suggested Table:** `IntuneEnrollmentErrors_CL`

**Key Fields to Capture:**
- `correlationId`
- `eventDateTime`
- `eventName`
- `troubleshootingErrorDetails` (contains error code, message, remediation)
- `enrollmentType`
- `failureCategory`
- `failureReason`

---

#### 5. Device Preparation Policy Status
**Gap:** New Device Preparation feature data not captured.

**Benefit:** Track modern enrollment experience success.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/deviceEnrollmentConfigurations?$filter=deviceEnrollmentConfigurationType eq 'devicePreparation'` | Device preparation configs |

---

#### 6. Deployment Profile Assignment Details
**Gap:** Know profile assignment status but not which groups are targeted.

**Benefit:** Troubleshoot why devices aren't getting expected profiles.

**Graph API Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `GET /deviceManagement/windowsAutopilotDeploymentProfiles/{id}/assignments` | Profile group assignments |
| `GET /deviceManagement/windowsAutopilotDeploymentProfiles/{id}/assignedDevices` | Devices assigned to profile |

**Suggested Table:** `IntuneAutopilotAssignments_CL`

---

## 📋 Summary: Priority Recommendations

### High Priority (High Impact, Commonly Needed)
| Data | Dashboard | Endpoint |
|------|-----------|----------|
| Windows Update Status | Device Health | `/deviceManagement/softwareUpdateStatusSummary` |
| Defender Status | Device Health | `/deviceManagement/managedDevices/{id}/windowsProtectionState` |
| Detected Apps | Device Inventory | `/deviceManagement/detectedApps` |
| Autopilot Events | Autopilot | `/deviceManagement/autopilotEvents` |
| Configuration Status | Device Inventory | `/deviceManagement/managedDevices/{id}/deviceConfigurationStates` |

### Medium Priority (Valuable for Specific Use Cases)
| Data | Dashboard | Endpoint |
|------|-----------|----------|
| Battery Health | Device Health | `/deviceManagement/userExperienceAnalyticsBatteryHealthDevicePerformance` |
| Hardware Details | Device Inventory | `/deviceManagement/managedDevices/{id}?$select=hardwareInformation` |
| Device Certificates | Device Inventory | `/deviceManagement/managedDevices/{id}/managedDeviceCertificateStates` |
| Enrollment Errors | Autopilot | `/deviceManagement/troubleshootingEvents` |

### Lower Priority (Nice to Have)
| Data | Dashboard | Endpoint |
|------|-----------|----------|
| Resource Performance | Device Health | `/deviceManagement/userExperienceAnalyticsResourcePerformance` |
| Group Memberships | Device Inventory | `/devices/{id}/memberOf` |
| Profile Assignments | Autopilot | `/deviceManagement/windowsAutopilotDeploymentProfiles/{id}/assignments` |

---

## 🔧 Implementation Notes

### Required Graph API Permissions
```
DeviceManagementManagedDevices.Read.All
DeviceManagementConfiguration.Read.All
DeviceManagementApps.Read.All
SecurityEvents.Read.All (for Defender data)
WindowsUpdates.Read.All (for Windows Update data)
```

### Export Function Structure
For each new data source, create a function following the existing pattern:
```
functions/
  export_windows_updates/
    __init__.py
    function.json
  export_defender_status/
    __init__.py
    function.json
  export_detected_apps/
    __init__.py
    function.json
  export_autopilot_events/
    __init__.py
    function.json
```

### Data Freshness Considerations
| Data Type | Recommended Sync Frequency |
|-----------|---------------------------|
| Windows Updates | Daily |
| Defender Status | Every 6 hours |
| Detected Apps | Daily |
| Autopilot Events | Hourly during business hours |
| Battery Health | Weekly |
| Hardware Inventory | Weekly |

---

## 📚 Reference Documentation

- [Microsoft Graph Device Management API](https://learn.microsoft.com/en-us/graph/api/resources/intune-graph-overview)
- [Endpoint Analytics API](https://learn.microsoft.com/en-us/graph/api/resources/intune-devices-userexperienceanalyticsoverview)
- [Windows Update for Business API](https://learn.microsoft.com/en-us/graph/api/resources/adminwindowsupdates-windowsupdates-overview)
- [Security API](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview)
