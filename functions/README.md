# Intune Reporting - Azure Functions

Serverless Azure Functions that export Intune data to Log Analytics or Azure Data Explorer.

## Quick Start

### Prerequisites

1. **Azure CLI** - [Install](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
2. **Azure Functions Core Tools** - [Install](https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local)
   ```powershell
   # Windows
   winget install Microsoft.Azure.FunctionsCoreTools

   # macOS
   brew tap azure/functions && brew install azure-functions-core-tools@4
   ```
3. **Azure subscription** with permissions to create resources

### Deploy

```powershell
# Login to Azure
az login

# Run the deployment script
.\deploy.ps1                    # Windows (PowerShell 7+)
./deploy.sh                     # macOS/Linux
```

The script creates everything:
- Resource Group
- Storage Account
- Log Analytics Workspace + custom tables
- Data Collection Endpoint + Rule
- Function App
- App Registration (for Graph API)

### Post-Deployment

1. **Grant Graph API permissions** (script provides the link):
   - `DeviceManagementManagedDevices.Read.All`
   - `DeviceManagementConfiguration.Read.All`
   - `DeviceManagementServiceConfig.Read.All`

2. **Test manually**:
   ```
   https://<function-app>.azurewebsites.net/api/export/devices?code=<function-key>
   ```

## Functions

| Function | Schedule | Description |
|----------|----------|-------------|
| `export_devices` | Every 4 hours | Device inventory from Intune |
| `export_compliance` | Every 6 hours | Compliance policies and per-device compliance states |
| `export_endpoint_analytics` | Daily 8 AM UTC | Health scores, startup performance, app reliability |
| `export_autopilot` | Daily 6 AM UTC | Autopilot devices and deployment profiles |
| `export_users` | Daily 2 AM UTC | Entra ID user profiles for device enrichment |
| `alert_engine` | Daily 9 AM UTC | Config-driven alerting with email notifications |
| `manual_trigger` | HTTP (on-demand) | Manually trigger any export via REST API |

## Manual Trigger API

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET/POST` | `/api/export` | List available export types |
| `GET/POST` | `/api/export/devices` | Export device inventory (~8,000+ records) |
| `GET/POST` | `/api/export/compliance` | Export compliance policies & states (~13,000+ records) |
| `GET/POST` | `/api/export/analytics` | Export endpoint analytics (~4,000+ records) |
| `GET/POST` | `/api/export/autopilot` | Export Autopilot devices & profiles |
| `GET/POST` | `/api/export/users` | Export Entra ID user profiles |
| `GET/POST` | `/api/export/alerts` | Run alert engine (query and send emails) |
| `GET/POST` | `/api/export/all` | Run all exports sequentially |

### Authentication

All endpoints require a function key:
- Query string: `?code=<function-key>`
- Header: `x-functions-key: <function-key>`

Get your function key:
```powershell
az functionapp keys list -g <resource-group> -n <function-app> --query "functionKeys.default" -o tsv
```

### Usage Examples

**PowerShell:**
```powershell
$key = "<function-key>"
$url = "https://<function-app>.azurewebsites.net/api/export"

# Run device export
Invoke-RestMethod -Uri "$url/devices?code=$key" -Method POST -TimeoutSec 300

# Run all exports (takes several minutes)
Invoke-RestMethod -Uri "$url/all?code=$key" -Method POST -TimeoutSec 600
```

**curl:**
```bash
# Run compliance export
curl -X POST "https://<app>.azurewebsites.net/api/export/compliance?code=<key>"
```

### Response Format

Single export:
```json
{
  "message": "Export Devices completed",
  "export_type": "devices",
  "records": 8656,
  "duration_seconds": 45.23
}
```

All exports:
```json
{
  "message": "All exports completed",
  "results": [
    {"export_type": "devices", "records": 8656, "status": "success"},
    {"export_type": "compliance", "records": 13070, "status": "success"},
    {"export_type": "analytics", "records": 4046, "status": "success"},
    {"export_type": "autopilot", "records": 0, "status": "error", "error": "Permission denied"}
  ],
  "total_duration_seconds": 120.5
}
```

## Configuration

Environment variables (set automatically by deploy script):

| Variable | Description | Required |
|----------|-------------|----------|
| `AZURE_TENANT_ID` | Entra ID tenant ID | Yes |
| `AZURE_CLIENT_ID` | App registration client ID | Yes |
| `AZURE_CLIENT_SECRET` | App registration secret | Yes |
| `LOG_ANALYTICS_DCE` | Data Collection Endpoint URL | Yes |
| `LOG_ANALYTICS_DCR_ID` | Data Collection Rule immutable ID (`dcr-...`) | Yes |
| `LOG_ANALYTICS_WORKSPACE_ID` | Workspace GUID (for alert engine KQL queries) | For alerts |
| `ALERT_SENDER_ADDRESS` | Email address (shared mailbox) for alert notifications | For alerts |
| `ALERT_RECIPIENTS` | Comma-separated default alert recipient list | For alerts |

## Local Development

1. Copy settings:
   ```bash
   cp local.settings.json.example local.settings.json
   ```

2. Fill in your values in `local.settings.json`

3. Run locally:
   ```bash
   func start
   ```

4. Test:
   ```bash
   curl http://localhost:7071/api/export/devices
   ```

## Project Structure

```
functions/
├── host.json                      # Function app settings
├── requirements.txt               # Python dependencies
├── local.settings.json.example    # Template for local dev
├── shared/
│   └── __init__.py               # Shared utilities (auth, ingestion, retry)
├── export_devices/               # Timer: every 4 hours
├── export_compliance/            # Timer: every 6 hours
├── export_endpoint_analytics/    # Timer: daily 8 AM
├── export_autopilot/             # Timer: daily 6 AM
├── export_users/                 # Timer: daily 2 AM
├── alert_engine/                 # Timer: daily 9 AM
└── manual_trigger/               # HTTP: on-demand testing
```

## Troubleshooting

### Function times out
- Default timeout is 10 minutes
- For large tenants (10k+ devices), consider Flex Consumption with higher timeout
- Compliance export iterates per-policy and may take longer

### Rate limited by Graph API
- Retry logic handles 429s automatically (exponential backoff)
- Check function logs for retry messages
- If persistent, reduce schedule frequency

### Authentication errors (401/403)
- Verify App Registration has correct API permissions
- Ensure admin consent was granted in Entra ID
- Check `AZURE_*` environment variables are set

### No data in Log Analytics
- Data can take 5-10 minutes to appear after ingestion
- Check function logs: `func azure functionapp logstream <app-name>`
- Verify Managed Identity has `Monitoring Metrics Publisher` role on DCR
- Run manual trigger to see detailed errors
