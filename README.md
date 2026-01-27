# Intune Analytics Platform

Export Microsoft Intune data to Azure for compliance monitoring, endpoint analytics, and custom alerting using **Azure Automation Account** with Python 3.10 runbooks.

## 🚀 One-Click Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FJacobWLMS%2FIntuneReporting%2Fmain%2Fdeployment%2Fautomation-account%2Fazuredeploy.json)

> ☝️ This single deployment creates **everything you need** - just select your backend and go!

### What Gets Deployed

| Backend | Created Resources |
|---------|-------------------|
| **Log Analytics** | Workspace + DCE + DCR (with all table schemas) + Automation Account + Role assignments |
| **ADX** | Optional free-tier cluster + Database + Automation Account + Role assignments |

### Which Backend Should I Choose?

| Feature | Azure Data Explorer | Log Analytics |
|---------|---------------------|---------------|
| **Cost** | Free dev tier (1 cluster/subscription) | ~$2.76/GB ingested |
| **Query Language** | KQL (full power) | KQL (subset) |
| **Materialized Views** | ✅ Yes | ❌ No |
| **Azure Monitor Alerts** | Via export | ✅ Native |
| **Sentinel Integration** | Via export | ✅ Native |
| **Setup Complexity** | Run schema script | ✅ Fully automated |

**Recommendation**: Start with **Log Analytics** for easiest setup, or **ADX** for powerful analytics.

## 🎯 Why This Exists

Microsoft Intune portal is great for day-to-day management, but limited for:
- **Custom alerting** - Get notified when devices become non-compliant
- **Historical trends** - Track compliance rates over time  
- **Cross-data analysis** - Correlate compliance with endpoint health
- **Flexible reporting** - Build exactly the reports you need

## 📊 What Data Is Collected

| Runbook | Data | Schedule |
|---------|------|----------|
| **Export-IntuneDevices** | Device inventory (core table all others reference) | Every 4 hours |
| **Export-IntuneCompliance** | Compliance policies and per-device states | Every 6 hours |
| **Export-EndpointAnalytics** | Health scores, startup performance, app reliability | Daily |
| **Export-Autopilot** | Autopilot devices and deployment profiles | Daily |

## 🏗️ Architecture

```
┌──────────────────┐     ┌────────────────────┐     ┌──────────────────┐
│   Microsoft      │     │  Azure Automation  │     │   Log Analytics  │
│   Graph API      │────▶│  Python 3.10       │────▶│   Workspace      │
│   (Intune Data)  │     │  Runbooks          │     │   (or ADX)       │
└──────────────────┘     └────────────────────┘     └──────────────────┘
        │                         │                          │
        │                         ▼                          ▼
        │               ┌────────────────────┐     ┌──────────────────┐
        │               │  DCE + DCR         │     │  Azure Workbooks │
        │               │  (auto-created)    │     │  + Alerts        │
        └──────────────▶└────────────────────┘     └──────────────────┘
```

**Cost**: ~$0/month with free tiers

## 🚀 Quick Start

### 1. Deploy Infrastructure (One-Click)

1. Click the **Deploy to Azure** button above
2. Fill in required parameters:
   - **baseName**: Short prefix for resources (max 11 chars)
   - **analyticsBackend**: Choose `LogAnalytics` or `ADX`
3. Optional parameters:
   - **graphClientId/Secret**: App Registration credentials (leave empty to use Managed Identity)
   - **createAdxCluster**: Set to `true` to create a free-tier ADX cluster
   - **logAnalyticsRetentionDays**: Data retention (default 90 days)
4. Click **Review + create** → **Create**
5. ⏳ Wait 5-10 minutes

### 2. Install Python Packages (Required)

After deployment, run the setup script to create a Runtime Environment and install packages from PyPI:

```powershell
# Get values from deployment outputs
./scripts/Setup-RuntimeEnvironment.ps1 `
    -AutomationAccountName "<automationAccountName>" `
    -ResourceGroupName "<resourceGroupName>" `
    -AnalyticsBackend "LogAnalytics"  # or "ADX"
```

This script:
- Creates a Python 3.10 Runtime Environment
- Installs packages dynamically from PyPI (never stale URLs!)
- Links all runbooks to the Runtime Environment

> ℹ️ The script fetches the latest package versions from PyPI at runtime.

### 3. Grant Graph API Permissions

The Automation Account's **Managed Identity** needs Microsoft Graph permissions.

Run the provided script (requires Azure AD admin rights):

```powershell
# Get the managed identity object ID from deployment outputs, then run:
./scripts/Grant-GraphPermissions.ps1 -ManagedIdentityObjectId "<managedIdentityPrincipalId>"
```

This grants:
| Permission | Purpose |
|------------|---------|
| `DeviceManagementManagedDevices.Read.All` | Read devices and compliance |
| `DeviceManagementConfiguration.Read.All` | Read endpoint analytics |
| `DeviceManagementServiceConfig.Read.All` | Read Autopilot data |

> **Alternative**: Use an App Registration by providing `graphClientId` and `graphClientSecret` during deployment.

### 4. Backend Permissions (Auto-Configured!)

**Log Analytics**: ✅ Monitoring Metrics Publisher role is automatically assigned to the Managed Identity on the DCR.

**ADX (new cluster)**: ✅ Database Ingestor role is automatically assigned. Just run `database/Schema-Focused.kql` to create tables.

**ADX (existing cluster)**: Manually grant Database Ingestor role to the Managed Identity.

### 5. Test the Runbooks

1. Azure Portal → **Automation Account** → **Runbooks**
2. Select `Export-IntuneDevices` → **Start**
3. Monitor the job output for success/errors

## 📁 Project Structure

```
├── runbooks/
│   ├── export_devices.py             # Device inventory (run first - core table)
│   ├── export_compliance.py          # Compliance policies and states
│   ├── export_endpoint_analytics.py  # Health scores, startup perf
│   └── export_autopilot.py           # Autopilot devices and profiles
├── database/
│   └── Schema-Focused.kql            # ADX schema + views + functions
├── dashboards/                       # ADX dashboard definitions
│   ├── ComplianceOverview.json
│   ├── DeviceHealth.json
│   ├── EndpointAnalyticsDeep.json
│   └── AutopilotOverview.json
├── workbooks/                        # Azure Monitor workbook definitions
│   ├── compliance-overview.workbook
│   ├── device-health.workbook
│   └── autopilot-deployment.workbook
├── deployment/
│   └── automation-account/
│       ├── main.bicep                # Bicep template (source)
│       └── azuredeploy.json          # ARM template (one-click deploy)
├── scripts/
│   ├── Grant-GraphPermissions.ps1    # Grants Graph API permissions to MI
│   ├── Setup-RuntimeEnvironment.ps1  # Creates Runtime Environment + installs packages
│   └── Install-PythonPackages.ps1    # Helper for package installation
└── README.md
```

## ⚙️ Configuration Variables

The Automation Account stores configuration in encrypted variables:

| Variable | Purpose | Required |
|----------|---------|----------|
| `AZURE_TENANT_ID` | Azure AD tenant | Yes |
| `AZURE_CLIENT_ID` | App Registration client ID | If using App Reg |
| `AZURE_CLIENT_SECRET` | App Registration secret | If using App Reg |
| `ANALYTICS_BACKEND` | `ADX` or `LogAnalytics` | Yes |
| `ADX_CLUSTER_URI` | ADX cluster URL | If using ADX |
| `ADX_DATABASE` | ADX database name | If using ADX |
| `LOG_ANALYTICS_DCE` | Data Collection Endpoint | If using LA |
| `LOG_ANALYTICS_DCR_ID` | Data Collection Rule ID | If using LA |

## 📈 Dashboards

Import these ADX dashboard definitions:

| Dashboard | Purpose |
|-----------|---------|
| [ComplianceOverview.json](dashboards/ComplianceOverview.json) | Compliance rates, non-compliant devices |
| [DeviceHealth.json](dashboards/DeviceHealth.json) | Device inventory, stale devices |
| [EndpointAnalyticsDeep.json](dashboards/EndpointAnalyticsDeep.json) | Startup times, app reliability |
| [AutopilotOverview.json](dashboards/AutopilotOverview.json) | Autopilot enrollment, profiles, failures |

### Azure Workbooks

For Azure Monitor/Log Analytics, import these workbook templates:

| Workbook | Purpose |
|----------|---------|
| [compliance-overview.workbook](workbooks/compliance-overview.workbook) | Compliance monitoring |
| [device-health.workbook](workbooks/device-health.workbook) | Device health metrics |
| [autopilot-deployment.workbook](workbooks/autopilot-deployment.workbook) | Autopilot deployment tracking |

## 🔔 Alerting

Query alert functions from Logic Apps, Power Automate, or ADX alerts:

```kql
// New non-compliant devices in last 6 hours
AlertNewNonCompliant()

// Devices with health score drop >20 points  
AlertHealthScoreDrop(20.0)

// Autopilot enrollment failures in last 24 hours
AlertAutopilotFailures()

// Devices pending enrollment (for proactive tracking)
AutopilotPendingEnrollment()
```

## 🔧 Handling Duplicates

ADX doesn't have UPSERT. We solve this with:

1. **Raw tables** - 7-day retention, receives all ingested data
2. **Materialized views** - `arg_max(IngestionTime, *)` returns latest record

**Always query `_Current` views**, not raw tables:

```kql
// ✅ Do this - gets latest state per device
ManagedDevices_Current | where ComplianceState == "noncompliant"

// ❌ Not this - returns duplicates
ManagedDevices | where ComplianceState == "noncompliant"
```

## 🔐 Security

- **Managed Identity** - Automation Account uses system-assigned identity
- **Encrypted Variables** - Client secrets stored encrypted
- **Least Privilege** - Only read permissions for Graph, ingest-only for ADX

## 🐛 Troubleshooting

**Runbook fails with "No Graph credential configured"**
- Check that `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` variables are set in the Automation Account

**401 Unauthorized from Graph API**
- Verify the App Registration has the required Graph API permissions
- Ensure admin consent was granted for the permissions

**ADX ingestion fails**
- Verify the App Registration/Managed Identity has Database Ingestor role on the ADX database
- Check the `ADX_CLUSTER_URI` and `ADX_DATABASE` variables are correct

## 📝 License

MIT
