# Intune Reporting

Export Microsoft Intune data to Azure Log Analytics for compliance monitoring, endpoint analytics, and custom alerting using **Azure Functions**.

## Quick Start

### Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Azure Functions Core Tools v4](https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local)
- [Az PowerShell Module](https://docs.microsoft.com/en-us/powershell/azure/install-az-ps) (for permission scripts)

```powershell
# Windows - Install prerequisites
winget install Microsoft.Azure.FunctionsCoreTools
Install-Module -Name Az -Scope CurrentUser -Force
Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force

# macOS
brew tap azure/functions && brew install azure-functions-core-tools@4
```

### Deploy

```powershell
# Clone the repo
git clone https://github.com/JacobWLMS/IntuneReporting.git
cd IntuneReporting

# Login to Azure
az login
Connect-AzAccount

# Deploy everything (creates all Azure resources)
.\deployment\deploy.ps1 -Name "intune-reports" -Location "uksouth"
```

The script creates:

- Resource Group
- Log Analytics Workspace with 9 custom tables
- Data Collection Endpoint & Rule (DCE/DCR)
- Function App (Flex Consumption, Python 3.11)
- App Registration with client secret

### Post-Deployment: Grant Permissions

After deployment, grant the required permissions:

```powershell
# Option 1: Use the permissions script (recommended)
.\deployment\scripts\Grant-GraphPermissions.ps1 -ServicePrincipalObjectId "<object-id-from-deploy-output>"

# Option 2: Quick script for Managed Identity
.\deployment\scripts\Configure-Permissions.ps1
```

**Required Graph API Permissions:**

| Permission | Purpose |
| ------------ | --------- |
| `DeviceManagementManagedDevices.Read.All` | Read device inventory |
| `DeviceManagementConfiguration.Read.All` | Read compliance policies & endpoint analytics |
| `DeviceManagementServiceConfig.Read.All` | Read Autopilot devices & profiles |

**Required Azure Role:**

| Role | Scope | Purpose |
| ------ | ------- | --------- |
| `Monitoring Metrics Publisher` | Data Collection Rule | Ingest data to Log Analytics |

---

## Manual Export API

Trigger exports on-demand without waiting for scheduled timers. Useful for testing and initial data population.

### Endpoints

| Method | Endpoint | Description |
| -------- | ---------- | ------------- |
| `GET/POST` | `/api/export` | List available export types |
| `GET/POST` | `/api/export/devices` | Export device inventory |
| `GET/POST` | `/api/export/compliance` | Export compliance policies & states |
| `GET/POST` | `/api/export/analytics` | Export endpoint analytics scores |
| `GET/POST` | `/api/export/autopilot` | Export Autopilot devices & profiles |
| `GET/POST` | `/api/export/all` | Run all exports sequentially |

### Authentication

All endpoints require a function key. Get it from Azure Portal or CLI:

```powershell
# Get function key
az functionapp keys list -g <resource-group> -n <function-app> --query "functionKeys.default" -o tsv
```

### Usage Examples

**PowerShell:**

```powershell
$functionKey = "<your-function-key>"
$baseUrl = "https://<function-app>.azurewebsites.net/api/export"

# Run single export
$response = Invoke-RestMethod -Uri "$baseUrl/devices?code=$functionKey" -Method POST -TimeoutSec 300
$response | Format-List

# Run all exports
$response = Invoke-RestMethod -Uri "$baseUrl/all?code=$functionKey" -Method POST -TimeoutSec 600
$response.results | Format-Table
```

**curl:**

```bash
# Run device export
curl -X POST "https://<function-app>.azurewebsites.net/api/export/devices?code=<function-key>"

# Run all exports
curl -X POST "https://<function-app>.azurewebsites.net/api/export/all?code=<function-key>"
```

### Response Format

```json
{
  "message": "Export Devices completed",
  "export_type": "devices",
  "records": 8656,
  "duration_seconds": 45.23
}
```

For `/api/export/all`:

```json
{
  "message": "All exports completed",
  "results": [
    {"export_type": "devices", "records": 8656, "status": "success"},
    {"export_type": "compliance", "records": 13070, "status": "success"},
    {"export_type": "analytics", "records": 4046, "status": "success"},
    {"export_type": "autopilot", "records": 0, "status": "error", "error": "..."}
  ],
  "total_duration_seconds": 120.5
}
```

---

## Data Collection

| Function | Schedule | Tables | Data |
| ---------- | ---------- | -------- | ------ |
| `export_devices` | Every 4 hours | `IntuneDevices_CL` | Device inventory, hardware, compliance state |
| `export_compliance` | Every 6 hours | `IntuneCompliancePolicies_CL`, `IntuneComplianceStates_CL` | Policies & per-device compliance |
| `export_endpoint_analytics` | Daily 8 AM | `IntuneDeviceScores_CL`, `IntuneStartupPerformance_CL`, `IntuneAppReliability_CL` | Health scores, performance metrics |
| `export_autopilot` | Daily 6 AM | `IntuneAutopilotDevices_CL`, `IntuneAutopilotProfiles_CL` | Autopilot enrollment status |

### Log Analytics Tables

| Table | Key Fields |
| ------- | ------------ |
| `IntuneDevices_CL` | DeviceId, DeviceName, UserPrincipalName, ComplianceState, OperatingSystem, LastSyncDateTime |
| `IntuneCompliancePolicies_CL` | PolicyId, PolicyName, PolicyType, CreatedDateTime |
| `IntuneComplianceStates_CL` | DeviceId, PolicyId, Status, LastContact |
| `IntuneDeviceScores_CL` | DeviceId, EndpointAnalyticsScore, StartupPerformanceScore, AppReliabilityScore |
| `IntuneStartupPerformance_CL` | DeviceId, CoreBootTimeInMs, TotalBootTimeInMs |
| `IntuneAppReliability_CL` | AppName, AppCrashCount, AppHealthScore |
| `IntuneAutopilotDevices_CL` | SerialNumber, EnrollmentState, GroupTag |
| `IntuneAutopilotProfiles_CL` | ProfileId, DisplayName, DeviceNameTemplate |

---

## Architecture

```
┌──────────────────┐     ┌────────────────────┐     ┌──────────────────┐
│   Microsoft      │     │   Azure Functions  │     │   Log Analytics  │
│   Graph API      │────▶│   (Python 3.11)    │────▶│   Workspace      │
│   (Intune Data)  │     │   Flex Consumption │     │   (DCE/DCR)      │
└──────────────────┘     └────────────────────┘     └──────────────────┘
        │                         │                          │
        │                         ▼                          ▼
        │                ┌────────────────────┐     ┌──────────────────┐
        │                │  Timer Triggers    │     │  Azure Workbooks │
        │                │  HTTP Triggers     │     │  + Alerts        │
        │                └────────────────────┘     └──────────────────┘
        │
        ▼
┌──────────────────┐
│ App Registration │
│ (Graph Perms)    │
└──────────────────┘
```

**Cost**: ~$0/month on Flex Consumption (pay per execution, scales to zero)

---

## Workbooks

Import Azure Monitor workbooks for visualization. In Azure Portal:

1. Go to **Log Analytics workspace** → **Workbooks**
2. Click **New** → **Advanced Editor**
3. Paste the JSON from any workbook file
4. Click **Apply** then **Done Editing**

| Workbook | Purpose |
| ---------- | --------- |
| [device-inventory.workbook](deployment/workbooks/device-inventory.workbook) | Complete device fleet overview with filtering |
| [compliance-overview.workbook](deployment/workbooks/compliance-overview.workbook) | Compliance rates, policy analysis, non-compliant devices |
| [device-health.workbook](deployment/workbooks/device-health.workbook) | Health scores, sync freshness, devices needing attention |
| [autopilot-deployment.workbook](deployment/workbooks/autopilot-deployment.workbook) | Autopilot enrollment tracking and failures |

---

## Configuration

Environment variables (set automatically by deploy script):

| Variable | Description |
| ---------- | ------------- |
| `AZURE_TENANT_ID` | Entra ID tenant ID |
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_CLIENT_SECRET` | App registration secret |
| `LOG_ANALYTICS_DCE` | Data Collection Endpoint URL |
| `LOG_ANALYTICS_DCR_ID` | Data Collection Rule immutable ID (starts with `dcr-`) |

---

## Scripts

| Script | Purpose |
| -------- | --------- |
| `deployment/deploy.ps1` | Full deployment (resources + code) |
| `deployment/scripts/Grant-GraphPermissions.ps1` | Grant Graph API permissions to service principal |
| `deployment/scripts/Configure-Permissions.ps1` | Quick permission setup for Managed Identity |
| `deployment/scripts/Update-DCRSchema.ps1` | Update DCR schema if tables change |

---

## Troubleshooting

### No data in Log Analytics

1. Check function executed: Azure Portal → Function App → Functions → Monitor
2. Check for errors in logs: `func azure functionapp logstream <function-app>`
3. Verify DCR permissions: Managed Identity needs `Monitoring Metrics Publisher` on DCR
4. Data ingestion delay: Allow 5-10 minutes for data to appear

### Authentication errors (401/403)

1. Verify App Registration has correct Graph API permissions
2. Ensure **admin consent** was granted (Enterprise Applications → Permissions)
3. Check client secret hasn't expired

### Function timeout

- Default timeout: 10 minutes
- For large tenants (10k+ devices), consider:
  - Flex Consumption with higher timeout
  - Split exports into smaller batches

### Rate limiting (429)

- Built-in retry with exponential backoff handles this automatically
- Check logs for retry messages
- Reduce schedule frequency if persistent

---

## Updating

**Redeploy code only** (after making changes):

```powershell
cd functions
func azure functionapp publish <function-app-name> --python
```

**Update DCR schema** (if table columns change):

```powershell
.\deployment\scripts\Update-DCRSchema.ps1
```

---

## Local Development

```powershell
cd functions

# Create local settings
cp local.settings.json.example local.settings.json
# Edit local.settings.json with your values

# Run locally
func start

# Test
curl http://localhost:7071/api/export/devices
```

---

## License

MIT
