# Intune Reporting - Project Status & Test Results

## Current State
**Date:** 2026-01-27
**Status:** Working prototype - deployment scripts tested
**Deployment Scripts:** Both Bash (deploy.sh) and PowerShell (deploy.ps1) tested and working

---

## Test Results Summary (rg-intune-test2)

### Infrastructure Tests

| Test | Status | Notes |
|------|--------|-------|
| Resource Group created | PASS | rg-intune-test2 in eastus |
| Storage Account created | PASS | intunetest2stor (Standard_LRS) |
| Log Analytics Workspace created | PASS | intune-test2-law |
| Custom Tables (9) created | PASS | All 9 Intune*_CL tables exist |
| DCE created | PASS | Endpoint: https://intune-test2-dce-jypo.eastus-1.ingest.monitor.azure.com |
| DCR created with 9 streams | PASS | ID: dcr-6923d9d4ea9e41c6bdb1d92321db2651 |
| Function App created | PASS | intune-test2-func |
| Function App uses Flex Consumption | PASS | FC1 tier - scales to zero when idle |
| Function App settings configured | PASS | All required env vars set |
| Functions deployed (5 core) | PASS | export_devices, export_compliance, export_endpoint_analytics, export_autopilot, manual_trigger |
| App Registration created | PASS | intune-test2-app (38695d44-0df2-4909-8535-73cdce40a2f9) |
| DCR role assignment | PASS | Monitoring Metrics Publisher granted |
| Workbooks deployed (4) | PARTIAL | Deployed but sourceId not properly linked (Azure CLI bug with Git Bash path conversion) |

### Functional Tests

| Test | Status | Notes |
|------|--------|-------|
| Manual trigger endpoint responds | PASS | Returns list of available exports |
| Test ingestion endpoint | PASS | Returns success, 1 record sent |
| Data appears in Log Analytics | PENDING | 2-5 minute ingestion latency - test record was sent |
| Health check endpoint | PASS | Returns healthy status with all checks OK |

---

## What Works

1. **Full deployment automation** - deploy.sh creates all Azure resources
2. **Resource naming** - User-friendly names (no random hashes)
3. **Flex Consumption plan** - Scales to zero, minimizes costs
4. **Data ingestion pipeline** - DCE/DCR properly configured, test ingestion succeeds
5. **Timer triggers** - Functions scheduled on CRON (4h, 6h, daily)
6. **Manual triggers** - HTTP endpoints for on-demand exports
7. **Health monitoring** - Health check validates config, auth, Graph API, Log Analytics
8. **Graph API authentication** - Service principal with client secret

---

## What Doesn't Work / Known Issues

### Critical
1. **Workbook sourceId not set** - Azure CLI doesn't properly apply --source-id when run from Git Bash (path conversion issue). Workbooks must be accessed via Resource Group view in Portal.

### Medium
2. ~~**Workbooks are basic**~~ - **RESOLVED**: Workbooks now have time ranges, trends, filtering, and conditional formatting
3. ~~No PowerShell deployment script~~ - **RESOLVED**: deploy.ps1 now available
4. ~~**No alert rules**~~ - **RESOLVED**: Sample alert rules in /alerts folder

### Low
5. **Dashboard is optional** - Moved to /optional folder, not deployed by default
6. **Graph API permissions manual** - User must manually grant Microsoft Graph permissions in Azure Portal after deployment

---

## What's Missing / TODO

### High Priority
- [x] **PowerShell deployment script** (deploy.ps1) with same functionality as deploy.sh
- [x] **Improved workbooks** with rich KQL queries and visualizations
  - Added time range parameters to all workbooks
  - Added trend line charts showing changes over time
  - Added conditional formatting (color-coded cells)
  - Added multi-filter support (OS, compliance, manufacturer)
  - Added section headers for better organization
- [ ] **Test documentation** - Formal test cases with expected outcomes
- [x] **Sample alert rules** (2) for Intune data scenarios
  - `alerts/noncompliant-devices.json` - Alert when non-compliant devices exceed threshold
  - `alerts/stale-devices.json` - Alert when devices haven't synced for extended period

### Medium Priority
- [ ] Consider **Azure Dashboards** instead of/in addition to Workbooks
- [ ] **Query Pack** deployment for reusable KQL queries in Log Analytics
- [ ] **Automated Graph API permission** granting (if possible via CLI)
- [ ] **Log Analytics saved queries** for common use cases

### Low Priority
- [ ] Dashboard improvements (if keeping optional dashboard)
- [ ] Documentation for custom workbook creation
- [ ] CI/CD pipeline for deployments

---

## Test Environment Details

### rg-intune-test2 (Bash Script Test - deploy.sh)
- **Subscription:** Azure for Students
- **Location:** eastus
- **Function App:** https://intune-test2-func.azurewebsites.net
- **Log Analytics Workspace ID:** 8b8c5d88-6165-4fb5-bbc4-597dfe1670e1
- **App Registration Client ID:** 38695d44-0df2-4909-8535-73cdce40a2f9

### rg-intune-ps-test (PowerShell Script Test - deploy.ps1)
- **Subscription:** Azure for Students
- **Location:** eastus
- **Result:** All resources created successfully
- **Notes:** Script uses Az modules when available, falls back to Azure CLI
- **Health Check:** Passed (config, auth, graph_api, log_analytics all OK)

### Test Endpoints
```
Health: /api/export/health (requires function key)
Test:   /api/export/test (requires function key)
List:   /api/export (requires function key)
```

---

## Required Graph API Permissions

These must be granted manually after deployment:
- `DeviceManagementManagedDevices.Read.All`
- `DeviceManagementConfiguration.Read.All`
- `DeviceManagementServiceConfig.Read.All`

---

## Cost Considerations

1. **Flex Consumption Plan** - Pay only when functions run (scales to zero)
2. **Timer schedules** - Functions run on schedule, not continuously
3. **Log Analytics retention** - Set to 30 days (configurable)
4. **No always-on resources** - Everything scales to zero when idle

---

## Next Steps

1. ~~Create PowerShell deployment script~~ - **DONE** (deploy.ps1 tested and working)
2. Improve workbooks with proper visualizations
3. Add sample alert rules for Intune data
4. Create formal test documentation
5. ~~Commit current state to git~~ - **DONE**
