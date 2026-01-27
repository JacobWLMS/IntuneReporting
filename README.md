# Intune Reporting

Export Microsoft Intune data to Azure Log Analytics for compliance monitoring, endpoint analytics, and custom alerting using **Azure Functions**.

## Quick Start

### Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Azure Functions Core Tools](https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local)
  ```powershell
  # Windows
  winget install Microsoft.Azure.FunctionsCoreTools

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

# Deploy everything
.\deploy.ps1      # Windows
./deploy.sh       # macOS/Linux
```

The script creates all Azure resources:
- Resource Group
- Log Analytics Workspace with custom tables
- Data Collection Endpoint & Rule
- Function App (Python 3.11, Consumption plan)
- App Registration for Microsoft Graph

### Post-Deployment

**Grant Graph API permissions** (the script provides a portal link):
- `DeviceManagementManagedDevices.Read.All`
- `DeviceManagementConfiguration.Read.All`
- `DeviceManagementServiceConfig.Read.All`

**Test the deployment**:
```
https://<function-app>.azurewebsites.net/api/export/devices?code=<function-key>
```

## What Data Is Collected

| Function | Schedule | Data |
|----------|----------|------|
| `export_devices` | Every 4 hours | Device inventory (OS, compliance state, encryption, storage) |
| `export_compliance` | Every 6 hours | Compliance policies and per-device states |
| `export_endpoint_analytics` | Daily 8 AM | Health scores, startup performance, app reliability |
| `export_autopilot` | Daily 6 AM | Autopilot devices and deployment profiles |

## Architecture

```
┌──────────────────┐     ┌────────────────────┐     ┌──────────────────┐
│   Microsoft      │     │   Azure Functions  │     │   Log Analytics  │
│   Graph API      │────▶│   (Python 3.11)    │────▶│   Workspace      │
│   (Intune Data)  │     │                    │     │                  │
└──────────────────┘     └────────────────────┘     └──────────────────┘
                                  │                          │
                                  ▼                          ▼
                         ┌────────────────────┐     ┌──────────────────┐
                         │  Timer Triggers    │     │  Azure Workbooks │
                         │  (CRON schedules)  │     │  + Alerts        │
                         └────────────────────┘     └──────────────────┘
```

**Cost**: Near zero on Consumption plan (pay per execution)

## Manual Trigger API

Test exports on-demand without waiting for the timer:

```bash
GET /api/export              # List available exports
GET /api/export/devices      # Run device export
GET /api/export/compliance   # Run compliance export
GET /api/export/analytics    # Run endpoint analytics
GET /api/export/autopilot    # Run autopilot export
GET /api/export/all          # Run all exports
```

Returns JSON with record counts and duration.

## Project Structure

```
├── deploy.ps1                 # Windows deployment script
├── deploy.sh                  # macOS/Linux deployment script
├── functions/                 # Azure Functions app
│   ├── README.md             # Detailed function docs
│   ├── host.json             # Function app config
│   ├── requirements.txt      # Python dependencies (pinned)
│   ├── shared/               # Auth, ingestion, retry logic
│   ├── export_devices/       # Timer: every 4 hours
│   ├── export_compliance/    # Timer: every 6 hours
│   ├── export_endpoint_analytics/  # Timer: daily 8 AM
│   ├── export_autopilot/     # Timer: daily 6 AM
│   └── manual_trigger/       # HTTP: on-demand testing
├── scripts/
│   └── Grant-GraphPermissions.ps1  # Grant Graph API permissions
├── workbooks/                 # Azure Monitor workbook templates
├── dashboards/                # ADX dashboard definitions (if using ADX)
└── database/                  # ADX schema (if using ADX)
```

## Configuration

Environment variables (set automatically by deploy script):

| Variable | Description |
|----------|-------------|
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_CLIENT_SECRET` | App registration secret |
| `ANALYTICS_BACKEND` | `LogAnalytics` (default) or `ADX` |
| `LOG_ANALYTICS_DCE` | Data Collection Endpoint URL |
| `LOG_ANALYTICS_DCR_ID` | Data Collection Rule ID |

## Workbooks

Import these Azure Monitor workbook templates for visualization:

| Workbook | Purpose |
|----------|---------|
| [compliance-overview.workbook](workbooks/compliance-overview.workbook) | Compliance rates, non-compliant devices |
| [device-health.workbook](workbooks/device-health.workbook) | Device inventory, stale devices |
| [device-inventory.workbook](workbooks/device-inventory.workbook) | Device listing and search |
| [autopilot-deployment.workbook](workbooks/autopilot-deployment.workbook) | Autopilot enrollment tracking |

## Features

- **Retry with exponential backoff** - Handles Graph API rate limiting (429)
- **Configuration validation** - Fails fast with clear errors if misconfigured
- **Pinned dependencies** - Reproducible deployments
- **HTTP trigger** - Test exports immediately after deployment
- **Batched ingestion** - Handles large datasets efficiently

## Troubleshooting

**Function times out**
- Default is 10 minutes (Consumption plan max)
- For large tenants (10k+ devices), consider Premium plan

**Rate limited by Graph API**
- Retry logic handles this automatically
- Check function logs for backoff messages

**Authentication errors**
- Verify App Registration has correct API permissions
- Ensure admin consent was granted

**No data in Log Analytics**
- Data can take 5-10 minutes to appear
- Run manual trigger to see detailed errors
- Check DCE and DCR configuration

## Updating

Redeploy code only:
```bash
cd functions
func azure functionapp publish <function-app-name> --python
```

## License

MIT
