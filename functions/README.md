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
| `export_compliance` | Every 6 hours | Compliance policies and device states |
| `export_endpoint_analytics` | Daily 8 AM UTC | Health scores, startup performance, app reliability |
| `export_autopilot` | Daily 6 AM UTC | Autopilot devices and deployment profiles |
| `manual_trigger` | HTTP (on-demand) | Manually trigger any export |

## Manual Trigger API

```bash
# List available exports
GET /api/export

# Run specific export
GET /api/export/devices
GET /api/export/compliance
GET /api/export/analytics
GET /api/export/autopilot

# Run all exports
GET /api/export/all
```

Requires function key (pass as `?code=<key>` or `x-functions-key` header).

## Configuration

Environment variables (set automatically by deploy script):

| Variable | Description | Required |
|----------|-------------|----------|
| `AZURE_TENANT_ID` | Azure AD tenant ID | Yes |
| `AZURE_CLIENT_ID` | App registration client ID | Yes |
| `AZURE_CLIENT_SECRET` | App registration secret | Yes |
| `ANALYTICS_BACKEND` | `LogAnalytics` or `ADX` | No (default: LogAnalytics) |
| `LOG_ANALYTICS_DCE` | Data Collection Endpoint URL | If using Log Analytics |
| `LOG_ANALYTICS_DCR_ID` | Data Collection Rule ID | If using Log Analytics |
| `ADX_CLUSTER_URI` | ADX cluster URL | If using ADX |
| `ADX_DATABASE` | ADX database name | If using ADX |

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
├── requirements.txt               # Python dependencies (pinned)
├── local.settings.json.example    # Template for local dev
├── shared/
│   └── __init__.py               # Shared utilities (auth, ingestion, retry)
├── export_devices/               # Timer: every 4 hours
├── export_compliance/            # Timer: every 6 hours
├── export_endpoint_analytics/    # Timer: daily 8 AM
├── export_autopilot/             # Timer: daily 6 AM
└── manual_trigger/               # HTTP: on-demand testing
```

## Troubleshooting

### Function times out
- Default timeout is 10 minutes (Consumption plan max)
- For large tenants (10k+ devices), consider Premium plan
- Check if a specific export is slow (compliance iterates per-policy)

### Rate limited by Graph API
- Retry logic handles 429s automatically (exponential backoff)
- If persistent, reduce schedule frequency
- Check [Graph throttling limits](https://docs.microsoft.com/en-us/graph/throttling)

### Authentication errors
- Verify App Registration has correct API permissions
- Ensure admin consent was granted
- Check `AZURE_*` environment variables are set

### No data in Log Analytics
- Data can take 5-10 minutes to appear
- Check function logs in Azure Portal
- Verify DCE and DCR are configured correctly
- Run manual trigger to see detailed errors

## Updating

To update dependencies:
```bash
pip install --upgrade -r requirements.txt
pip freeze > requirements.txt
```

To redeploy code only:
```bash
cd functions
func azure functionapp publish <function-app-name> --python
```
