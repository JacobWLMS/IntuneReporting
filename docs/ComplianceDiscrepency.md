# Compliance Data Discrepancies

This document explains the observed discrepancies between compliance data in the Intune Reporting solution.

---

## Summary

When comparing compliance counts between data sources, numbers don't match:

| Source | Noncompliant Count |
|--------|-------------------|
| `IntuneManagedDevices_CL.ComplianceState` | 2,064 |
| `IntuneComplianceStates_CL` (StatusRaw=4) | 1,261 |
| **Gap** | **803 devices** |

---

## Data Sources Explained

### IntuneManagedDevices_CL
- **API**: `deviceManagement/managedDevices`
- **Field**: `ComplianceState`
- **Values**: `compliant`, `noncompliant`, `unknown`, `inGracePeriod`, `configManager`
- **Represents**: Intune's **overall device compliance determination**
- **Matches**: Intune Admin Portal device compliance status ✅

### IntuneComplianceStates_CL
- **API**: `deviceManagement/reports/getDeviceStatusByCompliacePolicyReport`
- **Field**: `StatusRaw` (integer) / `Status` (string)
- **Values**: 1=unknown, 2=compliant, 3=inGracePeriod, 4=noncompliant, 5=error, 6=conflict, 7=notApplicable
- **Represents**: **Per-policy compliance status** for each device

---

## Root Causes of Discrepancy

### 1. Devices Without Policy Records (231 devices)

Some devices in `IntuneManagedDevices_CL` have **no entries** in `IntuneComplianceStates_CL`:

| OS | Count |
|----|-------|
| Android | 197 |
| Windows | 30 |
| iOS | 4 |

**Possible reasons:**
- No compliance policies assigned to device
- Policies not yet evaluated (newly enrolled)
- Graph API not returning data for these devices
- Stale devices that haven't synced recently

### 2. Noncompliant Devices with Compliant Policies (~572 devices)

These devices show `ComplianceState = 'noncompliant'` but all their policy statuses are compliant/notApplicable.

**Policy statuses for these devices:**
| Status | Count |
|--------|-------|
| Compliant | ~1,000 |
| Unknown | 27 |
| Error | 11 |

**Intune marks devices noncompliant for reasons beyond policy evaluation:**
- Device Health Attestation failures
- Conditional Access requirements
- SafetyNet/Play Integrity failures (Android)
- Jailbreak detection (iOS)
- Grace period expiration at device level
- Co-management with ConfigMgr
- Encryption requirements not met
- Threat level from Microsoft Defender

---

## Technical Details

### Why the APIs Return Different Data

1. **`managedDevices` API** returns Intune's calculated overall compliance state, which considers:
   - All assigned compliance policies
   - Device health signals
   - Threat protection status
   - Platform-specific checks
   - Grace period status

2. **`getDeviceStatusByCompliacePolicyReport` API** returns only the evaluation result of each **compliance policy** assigned to a device. It does NOT include:
   - Device-level health checks
   - Conditional Access evaluation
   - Threat level assessments

### Known Limitation

The `Status` field from the compliance report API may have inconsistent formatting:
- API returns: `"Not compliant"` (with space)
- Expected: `"noncompliant"` (no space)

**Solution implemented**: Use `StatusRaw` (integer) instead of `Status` (string) in all queries.

---

## Recommendations

### Short-term (Implemented)
1. Use `IntuneManagedDevices_CL.ComplianceState` for accurate device counts (matches portal)
2. Use `StatusRaw` instead of `Status` for policy-level queries
3. Added Diagnostics tab to identify and explain discrepancies

### Long-term (To Investigate)

1. **Investigate missing policy records**
   - Query: Why do 231 devices have no entries in `getDeviceStatusByCompliacePolicyReport`?
   - Check if these devices have compliance policies assigned in Intune
   - Consider if these are legacy/stale devices that should be cleaned up

2. **Explore additional data sources**
   - `deviceManagement/deviceCompliancePolicyDeviceStateSummary` - aggregated compliance data
   - `deviceManagement/deviceHealthAttestationStates` - device health data
   - Consider if these APIs would provide the missing context

3. **Add explanatory context to dashboards**
   - Make it clear when data comes from different sources
   - Explain that "policy failures" ≠ "noncompliant devices"

4. **Consider Python export enhancements**
   - The `export_compliance.py` uses `PolicyStatus_loc` which can have inconsistent formatting
   - Option: Always use `STATUS_MAP` from `StatusRaw` for consistent values
   - Current behavior preserved pending further investigation

---

## Diagnostic Queries

### Find devices without policy records
```kql
let LatestDevices = IntuneManagedDevices_CL
| where TimeGenerated > ago(7d)
| summarize arg_max(TimeGenerated, *) by DeviceId;
let DevicesWithStates = IntuneComplianceStates_CL
| where TimeGenerated > ago(7d)
| distinct DeviceId;
LatestDevices
| join kind=leftanti (DevicesWithStates) on DeviceId
| project DeviceName, OS = OperatingSystem, ComplianceState, LastSyncDateTime
```

### Find noncompliant devices with no policy failures
```kql
let LatestDevices = IntuneManagedDevices_CL
| where TimeGenerated > ago(7d)
| summarize arg_max(TimeGenerated, *) by DeviceId
| where tolower(ComplianceState) == 'noncompliant';
let DevicesWithPolicyFailures = IntuneComplianceStates_CL
| where TimeGenerated > ago(7d)
| summarize arg_max(TimeGenerated, *) by DeviceId, PolicyId
| where StatusRaw == 4
| distinct DeviceId;
LatestDevices
| join kind=leftanti (DevicesWithPolicyFailures) on DeviceId
| project DeviceName, OS = OperatingSystem, ComplianceState, LastSyncDateTime
```

### Check policy statuses for mystery devices
```kql
let MysteryDevices = /* use query above */;
IntuneComplianceStates_CL
| where TimeGenerated > ago(7d)
| summarize arg_max(TimeGenerated, *) by DeviceId, PolicyId
| join kind=inner (MysteryDevices) on DeviceId
| extend StatusLabel = case(
    StatusRaw == 1, 'Unknown',
    StatusRaw == 2, 'Compliant',
    StatusRaw == 3, 'InGracePeriod',
    StatusRaw == 4, 'NonCompliant',
    StatusRaw == 5, 'Error',
    StatusRaw == 6, 'Conflict',
    StatusRaw == 7, 'NotApplicable',
    'Other')
| summarize count() by StatusLabel
```

---

## References

- [Microsoft Graph Compliance APIs](https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-devicecompliancepolicy)
- [Intune Device Compliance](https://learn.microsoft.com/en-us/mem/intune/protect/device-compliance-get-started)
- [Compliance Policy Settings](https://learn.microsoft.com/en-us/mem/intune/protect/compliance-policy-create-windows)

---

*Document created: January 28, 2026*
*Last updated: January 28, 2026*
