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
- Log Analytics Workspace with 10 custom tables
- Data Collection Endpoint & Rule (DCE/DCR)
- Function App (Flex Consumption, Python 3.11) with system-assigned managed identity

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
| --- | --- |
| `DeviceManagementManagedDevices.Read.All` | Read device inventory & endpoint analytics |
| `DeviceManagementConfiguration.Read.All` | Read compliance policies & device status reports |
| `DeviceManagementServiceConfig.Read.All` | Read Autopilot devices & profiles |
| `User.Read.All` | Read Entra ID user profiles |
| `AuditLog.Read.All` | Read user sign-in activity (last sign-in dates) |
| `Mail.Send` | Send alert notification emails via Graph API |

**Required Azure Role:**

| Role | Scope | Purpose |
| ------ | ------- | --------- |
| `Monitoring Metrics Publisher` | Data Collection Rule | Ingest data to Log Analytics |
| `Log Analytics Reader` | Log Analytics Workspace | Query data for alert engine KQL rules |

---

## Manual Export API

Trigger exports on-demand without waiting for scheduled timers. Useful for testing and initial data population.

### Endpoints

| Method | Endpoint | Description |
| --- | --- | --- |
| `GET/POST` | `/api/export` | List available export types |
| `GET/POST` | `/api/export/devices` | Export device inventory |
| `GET/POST` | `/api/export/compliance` | Export compliance policies & states |
| `GET/POST` | `/api/export/analytics` | Export endpoint analytics scores |
| `GET/POST` | `/api/export/autopilot` | Export Autopilot devices & profiles |
| `GET/POST` | `/api/export/users` | Export Entra ID user profiles |
| `GET/POST` | `/api/export/alerts` | Run alert engine (query and send emails) |
| `GET/POST` | `/api/export/all` | Run all exports sequentially |
| `GET/POST` | `/api/export/test` | Send a test record to Log Analytics |
| `GET/POST` | `/api/export/health` | Check auth, Graph API, and ingestion connectivity |

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
| --- | --- | --- | --- |
| `export_devices` | Every 4 hours | `IntuneManagedDevices_CL` | Device inventory, hardware, compliance state |
| `export_compliance` | Every 6 hours | `IntuneCompliancePolicies_CL`, `IntuneComplianceStates_CL` | Policies & per-device compliance |
| `export_endpoint_analytics` | Daily 8 AM | `IntuneDeviceScores_CL`, `IntuneStartupPerformance_CL`, `IntuneAppReliability_CL` | Health scores, performance metrics |
| `export_autopilot` | Daily 6 AM | `IntuneAutopilotDevices_CL`, `IntuneAutopilotProfiles_CL` | Autopilot enrollment status |
| `export_users` | Daily 2 AM | `IntuneUsers_CL` | Entra ID user profiles, department, sign-in activity |
| `alert_engine` | Daily 9 AM | `IntuneAlertState_CL` | Config-driven alerting with email notifications |

### Log Analytics Tables

| Table | Key Fields |
| --- | --- |
| `IntuneManagedDevices_CL` | DeviceId, DeviceName, UserPrincipalName, ComplianceState, OperatingSystem, LastSyncDateTime, JoinType, ChassisType |
| `IntuneUsers_CL` | UserId, UserPrincipalName, Department, AccountEnabled, LastSignInDateTime |
| `IntuneCompliancePolicies_CL` | PolicyId, PolicyName, PolicyType, CreatedDateTime |
| `IntuneComplianceStates_CL` | DeviceId, PolicyId, Status, LastContact |
| `IntuneDeviceScores_CL` | DeviceId, EndpointAnalyticsScore, StartupPerformanceScore, AppReliabilityScore |
| `IntuneStartupPerformance_CL` | DeviceId, CoreBootTimeInMs, TotalBootTimeInMs |
| `IntuneAppReliability_CL` | AppName, AppCrashCount, AppHealthScore |
| `IntuneAutopilotDevices_CL` | SerialNumber, EnrollmentState, GroupTag |
| `IntuneAutopilotProfiles_CL` | ProfileId, DisplayName, DeviceNameTemplate |
| `IntuneAlertState_CL` | AlertId, EntityId, EntityName, State, Severity, AlertedAt, ResolvedAt |
| `IntuneSyncState_CL` | ExportType, RecordCount, DurationSeconds, Status |

---

## Architecture

```text
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
| [stale-devices.workbook](deployment/workbooks/stale-devices.workbook) | Guided stale device investigation and cleanup workflow |

---

## Configuration

**Set automatically by `deploy.ps1`** (managed identity mode):

| Variable | Description |
| --- | --- |
| `USE_MANAGED_IDENTITY` | Set to `true` — uses the Function App's managed identity for all auth |
| `AZURE_TENANT_ID` | Entra ID tenant ID |
| `LOG_ANALYTICS_DCE` | Data Collection Endpoint URL |
| `LOG_ANALYTICS_DCR_ID` | Data Collection Rule immutable ID (starts with `dcr-`) |

**For app registration / local development** (set `USE_MANAGED_IDENTITY=false`):

| Variable | Description |
| --- | --- |
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_CLIENT_SECRET` | App registration client secret |

When all three of `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and `AZURE_CLIENT_SECRET` are present and `USE_MANAGED_IDENTITY` is not `true`, `ClientSecretCredential` is used for both Graph API and Log Analytics ingestion. The app registration's service principal must have `Monitoring Metrics Publisher` on the DCR.

---

## Scripts

| Script | Purpose |
| --- | --- |
| `setup-local.ps1` | Set up local development environment (venv, dependencies, settings file) |
| `deployment/deploy.ps1` | Full deployment (resources + code) |
| `deployment/scripts/Grant-GraphPermissions.ps1` | Grant Graph API permissions to service principal or managed identity |
| `deployment/scripts/Configure-Permissions.ps1` | Quick permission setup for Managed Identity |
| `deployment/scripts/Update-DCRSchema.ps1` | Update DCR schema when adding tables or columns |
| `deployment/scripts/Invoke-IntuneExport.ps1` | Manually trigger exports (interactive menu or `-Export` flag) |
| `deployment/scripts/Clear-LogAnalyticsTables.ps1` | Purge data from Log Analytics tables |
| `deployment/scripts/Deploy-SavedFunctions.ps1` | Deploy KQL saved functions to Log Analytics |

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

### Adding a new column to an existing table

1. Add the field to the Python export dict in `functions/export_*/`
2. Add the column to `deployment/scripts/Update-DCRSchema.ps1`
3. Run the schema update, then deploy the code:

```powershell
.\deployment\scripts\Update-DCRSchema.ps1
cd functions && func azure functionapp publish <function-app-name> --python
```

Schema update must go first — if the code deploys before the column exists in the DCR, Log Analytics silently drops that field.

### Adding a new table

The Log Analytics table must exist before the DCR will accept a new stream referencing it. Create the table first, then update the schema:

```powershell
# 1. Create the table (see New-CustomTables pattern in deploy.ps1)
# 2. Update DCR schema
.\deployment\scripts\Update-DCRSchema.ps1
# 3. Deploy code
cd functions && func azure functionapp publish <function-app-name> --python
```

### Redeploy code only

```powershell
cd functions
func azure functionapp publish <function-app-name> --python
```

---

## Local Development

### Local prerequisites

- Python 3.11 (`winget install Python.Python.3.11`)
- [Azure Functions Core Tools v4](https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local) (`winget install Microsoft.Azure.FunctionsCoreTools`)
- [Azurite](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azurite) — local Azure Storage emulator (`npm install -g azurite`)

### Automated setup

```powershell
.\setup-local.ps1
```

This checks prerequisites, creates a Python virtual environment at `functions/.venv/`, installs dependencies, and copies `local.settings.json.example` → `local.settings.json`.

### Manual setup (if preferred)

```powershell
cd functions
python3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
cp local.settings.json.example local.settings.json
```

### Configure credentials

Edit `functions/local.settings.json` and fill in:

| Setting | Value |
| ------- | ----- |
| `AZURE_TENANT_ID` | Your Entra tenant ID |
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_CLIENT_SECRET` | App registration client secret |
| `LOG_ANALYTICS_DCE` | Data Collection Endpoint URL |
| `LOG_ANALYTICS_DCR_ID` | DCR immutable ID (starts with `dcr-`) |
| `LOG_ANALYTICS_WORKSPACE_ID` | Workspace GUID (for alert engine KQL queries) |
| `ALERT_SENDER_ADDRESS` | Email address (shared mailbox) for alert notifications |
| `ALERT_RECIPIENTS` | Comma-separated default alert recipient list |

The app registration needs `Monitoring Metrics Publisher` on the DCR, `Log Analytics Reader` on the workspace, and the Graph API permissions listed above.

### Run

Start Azurite in one terminal (required for `AzureWebJobsStorage`):

```powershell
azurite --location .azurite
```

Start the Functions host in another terminal:

```powershell
cd functions
.\.venv\Scripts\Activate.ps1
func start
```

### Verify

```powershell
# Check auth + Graph API connectivity
curl http://localhost:7071/api/export/health

# Send a test record to Log Analytics
curl -X POST http://localhost:7071/api/export/test

# Trigger a full export
curl -X POST http://localhost:7071/api/export/devices
```

No function key is required locally — Core Tools accepts requests without one by default.

### VS Code debugging

Install the [Azure Functions](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-azurefunctions) extension, then press **F5**. This starts the Functions host and attaches the Python debugger so you can set breakpoints in any export function.

---

## License

MIT
