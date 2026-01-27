# Intune Analytics Platform

Export Microsoft Intune data to Azure for compliance monitoring, endpoint analytics, and custom alerting using **Azure Automation Account** with Python 3.10 runbooks.

## 🚀 One-Click Deploy

Choose your analytics backend:

| Backend | Deploy | Cost | Best For |
|---------|--------|------|----------|
| **Azure Data Explorer** | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FJacobWLMS%2FIntuneReporting%2Fmain%2Fdeployment%2Fautomation-account%2Fazuredeploy.json) | Free tier | Powerful KQL, materialized views, time-series |
| **Log Analytics** | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FJacobWLMS%2FIntuneReporting%2Fmain%2Fdeployment%2Fautomation-account%2Fazuredeploy.json) | Pay-per-GB | Simpler setup, Azure Monitor integration |

> 💡 Both buttons deploy the same Automation Account - just select your preferred backend during deployment.

### Which Backend Should I Choose?

| Feature | Azure Data Explorer | Log Analytics |
|---------|---------------------|---------------|
| **Cost** | Free dev tier (1 cluster/subscription) | ~$2.76/GB ingested |
| **Query Language** | KQL (full power) | KQL (subset) |
| **Materialized Views** | ✅ Yes | ❌ No |
| **Custom Functions** | ✅ Yes | ✅ Yes |
| **Azure Monitor Alerts** | Via export | ✅ Native |
| **Sentinel Integration** | Via export | ✅ Native |

**Recommendation**: Start with **ADX** for the free tier and powerful analytics.

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
| **Export-EndpointAnalytics** | Health scores, startup performance, app reliability | Daily 8 AM UTC |
| **Export-Autopilot** | Autopilot devices and deployment profiles | Daily 6 AM UTC |

## 🏗️ Architecture

```
┌──────────────────┐     ┌────────────────────┐     ┌──────────────────┐
│   Microsoft      │     │  Azure Automation  │     │   Azure Data     │
│   Graph API      │────▶│  Python 3.10       │────▶│   Explorer       │
│   (Intune Data)  │     │  Runbooks          │     │   (Free Tier)    │
└──────────────────┘     └────────────────────┘     └──────────────────┘
                                  │                          │
                                  │                          ▼
                                  │                 ┌──────────────────┐
                                  │                 │   KQL Queries    │
                                  └────────────────▶│   + Dashboards   │
                                  (or Log Analytics)│   + Alerts       │
                                                    └──────────────────┘
```

**Cost**: ~$0/month (Automation Account basic tier + ADX Dev/Free tier)

## 🚀 Quick Start

### 1. Deploy (One-Click)

1. Click the **Deploy to Azure** button above
2. Fill in parameters:
   - **baseName**: Short prefix for resources (max 11 chars)
   - **analyticsBackend**: Choose `ADX` or `LogAnalytics`
   - **graphClientId/Secret**: Your App Registration credentials (for testing)
   - **adxClusterUri** or **logAnalytics*** settings: Your backend details
3. Click **Review + create** → **Create**
4. ⏳ Wait 5-10 minutes

### 2. Grant Graph API Permissions

The runbooks need Microsoft Graph permissions to read Intune data.

**Option A: Use App Registration (Recommended for Testing)**

If you provided `graphClientId` and `graphClientSecret` during deployment, your App Registration needs these API permissions:

| Permission | Type | Purpose |
|------------|------|---------|
| `DeviceManagementManagedDevices.Read.All` | Application | Read devices and compliance |
| `DeviceManagementConfiguration.Read.All` | Application | Read endpoint analytics |
| `DeviceManagementServiceConfig.Read.All` | Application | Read Autopilot data |

Grant these in **Azure Portal → Entra ID → App Registrations → Your App → API Permissions → Add Permission → Microsoft Graph → Application Permissions**.

**Option B: Use Managed Identity**

Leave `graphClientId` and `graphClientSecret` empty during deployment, then grant the Automation Account's managed identity Graph permissions:

```powershell
# Get the managed identity object ID from deployment outputs
.\scripts\Grant-GraphPermissions.ps1 -ManagedIdentityObjectId "<paste-object-id>"
```

### 3. Grant Backend Permissions

**For ADX Backend:**
- Grant the App Registration or Managed Identity **Database Ingestor** role on your ADX database

**For Log Analytics Backend:**
- Grant the App Registration or Managed Identity **Monitoring Metrics Publisher** role on your DCR

### 4. Test the Runbooks

1. Azure Portal → **Automation Account** → **Runbooks**
2. Select `Export-IntuneCompliance` → **Start**
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
│   └── Grant-GraphPermissions.ps1
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
