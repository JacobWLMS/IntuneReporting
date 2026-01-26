# Setup Guide

Complete setup instructions for deploying the Intune Analytics Platform.

## Prerequisites

- Azure subscription with permissions to create resources
- Global Admin or Intune Admin role (for granting Graph API permissions)
- Microsoft Intune with devices enrolled (requires M365 E3/E5 or Intune standalone license)

## What Gets Deployed Automatically

The deployment template creates and configures everything:

| Resource | Details |
|----------|--------|
| ✅ Storage Account | For Function App state |
| ✅ App Service Plan | Consumption (free tier) |
| ✅ Application Insights | Monitoring & logs |
| ✅ Function App | Python 3.11, with code deployed from GitHub |
| ✅ ADX Cluster | Dev/Free tier with auto-stop |
| ✅ ADX Database | IntuneAnalytics |
| ✅ ADX Schema | All tables, views, and functions |
| ✅ Permissions | Function App → ADX Ingestor role |

**Only manual step**: Grant Graph API permissions (security requirement - cannot be automated)

---

## Step 1: Deploy Infrastructure

### Option 1: Azure Portal (Recommended)

1. Click the **Deploy to Azure** button in the [README](README.md), or:
   - Go to [Azure Portal](https://portal.azure.com)
   - Search **"Deploy a custom template"**
   - Click **"Build your own template in the editor"**
   - Paste contents of [deploy-function-app.json](deployment/deploy-function-app.json)
   - Click **Save**

2. Fill in the parameters:

   | Parameter | Value |
   |-----------|-------|
   | **Subscription** | Your Azure subscription |
   | **Resource Group** | Create new or select existing |
   | **Region** | UK South (or your preferred region) |
   | **Base Name** | `intune-analytics` (max 15 chars) |
   | **Repo Url** | `https://github.com/jacobwlms/Intunereporting` |
   | **Repo Branch** | `main` |
   | **Deploy Adx Cluster** | `true` (unless using existing cluster) |

3. Click **Review + create** → **Create**

4. ⏳ Wait **15-25 minutes** (ADX cluster provisioning takes time)

### Option 2: Azure CLI

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

## Step 3: Verify Deployment

> **Note**: ADX schema and function code are deployed automatically by the ARM template. No manual steps needed!

### Verify ADX Schema (Optional)

1. Open the [ADX Web UI](https://dataexplorer.azure.com/)
2. Connect to your cluster (URI from deployment output)
3. Select the `IntuneAnalytics` database
4. Run: `.show tables` - you should see 7 tables
5. Run: `.show functions` - you should see 9 functions

## Step 4: Verify Function App

### Check Functions Deployed

1. Azure Portal → Function App → **Functions**
2. You should see:
   - `fn_compliance` (runs every 6 hours)
   - `fn_endpoint_analytics` (runs daily at 8 AM UTC)
3. Check **Deployment Center** → should show GitHub connected

### Check Logs

1. Function App → **Monitor** → Logs
2. Or: Application Insights → Logs → query:
   ```kusto
   traces
   | where timestamp > ago(1h)
   | where message contains "Intune"
   | order by timestamp desc
   ```

### Trigger Manual Run (Optional)

To test immediately without waiting for schedule:

**Option 1: Azure Portal**
1. Function App → Functions → `fn_compliance` → **Code + Test** → **Test/Run**

**Option 2: Azure CLI**
```bash
az functionapp function invoke \
  --resource-group rg-intune-analytics \
  --name YOUR-FUNCTION-APP-NAME \
  --function-name fn_compliance
```

## Step 5: Import Dashboards

1. Open [ADX Web UI](https://dataexplorer.azure.com/)
2. Go to **Dashboards** → **Import from file**
3. Import dashboards from the `dashboards/` folder:
   - `ComplianceOverview.json` - Compliance rates, non-compliant devices
   - `DeviceHealth.json` - Device inventory, encryption status
   - `DeviceInventory.json` - Full device list with details
   - `EndpointAnalyticsDeep.json` - Startup times, app reliability
   - `SecurityPosture.json` - Security overview
   - `UserOverview.json` - Per-user device view

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
