# Setup Guide

Complete setup instructions for deploying the Intune Analytics Platform.

## Prerequisites

- Azure subscription with permissions to create resources
- Global Admin or Intune Admin role (for granting Graph API permissions)
- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) installed
- [Azure Functions Core Tools](https://docs.microsoft.com/azure/azure-functions/functions-run-local) v4+

## Step 1: Deploy Infrastructure

### Option A: Azure Portal (One-Click)

1. Click the "Deploy to Azure" button in the README
2. Fill in parameters:
   - **baseName**: Short name for resources (e.g., `intune-analytics`)
   - **deployAdxCluster**: `true` for new free-tier cluster, `false` if using existing
3. Click "Review + Create"

### Option B: Azure CLI

```bash
# Login and set subscription
az login
az account set --subscription "YOUR-SUBSCRIPTION-ID"

# Create resource group
az group create --name rg-intune-analytics --location uksouth

# Deploy
az deployment group create \
  --resource-group rg-intune-analytics \
  --template-file deployment/deploy-function-app.json \
  --parameters baseName=intune-analytics
```

**Save the outputs** - you'll need the Function App name and principal ID.

## Step 2: Grant Graph API Permissions

The Function App's managed identity needs permissions to read Intune data.

### Required Permissions

| Permission | Type | Purpose |
|------------|------|---------|
| `DeviceManagementManagedDevices.Read.All` | Application | Read devices, compliance |
| `DeviceManagementConfiguration.Read.All` | Application | Read endpoint analytics |

### Grant via Azure Portal

1. Go to **Azure Portal** → **Microsoft Entra ID** → **Enterprise applications**
2. Change filter to "Managed Identities" and search for your Function App name
3. Click on the managed identity → **Permissions** → **Grant admin consent**

### Grant via PowerShell (Recommended)

```powershell
# Install Microsoft Graph module if needed
Install-Module Microsoft.Graph -Scope CurrentUser

# Connect with admin permissions
Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"

# Get the Function App's managed identity (from deployment output)
$principalId = "YOUR-FUNCTION-APP-PRINCIPAL-ID"

# Get Microsoft Graph service principal
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

# Get the required app roles
$permissions = @(
    "DeviceManagementManagedDevices.Read.All",
    "DeviceManagementConfiguration.Read.All"
)

foreach ($permission in $permissions) {
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $permission }
    
    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $principalId `
        -PrincipalId $principalId `
        -ResourceId $graphSp.Id `
        -AppRoleId $appRole.Id
}

Write-Host "Permissions granted successfully"
```

## Step 3: Create ADX Schema

1. Open the [ADX Web UI](https://dataexplorer.azure.com/)
2. Connect to your cluster (URI from deployment output)
3. Select the `IntuneAnalytics` database
4. Open `database/Schema-Focused.kql`
5. Run each command block (Ctrl+Shift+E for each `.create` statement)

This creates:
- **Tables** with 7-day retention for raw data
- **Materialized views** for current state (no duplicates)
- **Functions** for common queries and alerts

## Step 4: Deploy Function Code

```bash
# Navigate to function app folder
cd function-app

# Deploy to Azure
func azure functionapp publish YOUR-FUNCTION-APP-NAME --python
```

Replace `YOUR-FUNCTION-APP-NAME` with the name from deployment output.

## Step 5: Verify Deployment

### Check Function App

1. Azure Portal → Function App → Functions
2. You should see:
   - `fn_compliance` (runs every 6 hours)
   - `fn_endpoint_analytics` (runs daily at 8 AM UTC)

### Check Logs

1. Function App → Monitor → Logs
2. Or: Application Insights → Logs → query:
   ```kusto
   traces
   | where timestamp > ago(1h)
   | where message contains "Intune"
   | order by timestamp desc
   ```

### Trigger Manual Run

To test immediately without waiting for schedule:

1. Function App → Functions → `fn_compliance` → Code + Test → Test/Run
2. Or via CLI:
   ```bash
   az functionapp function invoke \
     --resource-group rg-intune-analytics \
     --name YOUR-FUNCTION-APP-NAME \
     --function-name fn_compliance
   ```

## Step 6: Import Dashboards

1. Open [ADX Web UI](https://dataexplorer.azure.com/)
2. Go to **Dashboards** → **Import from file**
3. Import each dashboard from the `dashboards/` folder:
   - `ComplianceOverview.json`
   - `DeviceHealth.json`
   - `EndpointAnalyticsDeep.json`

## Troubleshooting

### "Unauthorized" errors in Function logs

- Permissions not granted correctly
- Run the PowerShell script in Step 2 again
- Verify permissions: Entra ID → Enterprise apps → [Function App] → Permissions

### No data appearing in ADX

- Check Function executed: Function App → Monitor
- Check ADX ingestion: `SyncState | order by IngestionTime desc | take 10`
- Verify managed identity has "Ingestor" role on ADX database

### ADX cluster not accessible

- Free tier clusters auto-pause after 4 hours of inactivity
- Wake it by running any query in ADX Web UI

### Rate limiting (429 errors)

- Normal during first run with large tenants
- Built-in retry logic handles this automatically
- Check logs for "Rate limited, waiting" messages

## Cost Estimate

| Resource | SKU | Monthly Cost |
|----------|-----|--------------|
| Function App | Consumption | ~$0 (free tier) |
| Storage Account | Standard LRS | ~$0.50 |
| ADX Cluster | Dev/Free | ~$0 |
| Application Insights | Free tier | ~$0 |
| **Total** | | **< $1/month** |

## Next Steps

- Set up [alerts](#alerting) for compliance drift
- Customize dashboards for your needs
- Add additional data exports (extend Function App)
