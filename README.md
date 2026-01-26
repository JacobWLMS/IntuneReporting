# Intune Analytics Platform

Export Microsoft Intune data to Azure for compliance monitoring, endpoint analytics, and custom alerting.

## 🚀 One-Click Deploy

Choose your analytics backend:

| Option | Deploy | Cost | Best For |
|--------|--------|------|----------|
| **Azure Data Explorer** | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FJacobWLMS%2FIntuneReporting%2Fmain%2Fdeployment%2Fdeploy-adx.json) | Free tier | Powerful KQL, materialized views, time-series |
| **Log Analytics** | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FJacobWLMS%2FIntuneReporting%2Fmain%2Fdeployment%2Fdeploy-loganalytics.json) | Pay-per-GB | Simpler setup, Azure Monitor integration |

### Which should I choose?

| Feature | ADX | Log Analytics |
|---------|-----|---------------|
| **Cost** | Free dev tier (1 cluster per subscription) | ~$2.76/GB ingested |
| **Query Language** | KQL (full power) | KQL (subset) |
| **Materialized Views** | ✅ Yes | ❌ No |
| **Custom Functions** | ✅ Yes | ✅ Yes |
| **Azure Monitor Alerts** | Via export | ✅ Native |
| **Sentinel Integration** | Via export | ✅ Native |
| **Setup Complexity** | Medium | Simple |

**Recommendation**: Start with **ADX** for the free tier and powerful analytics. Use **Log Analytics** if you already have a workspace or need Sentinel/Azure Monitor integration.

> 📖 **Full setup instructions**: [SETUP.md](SETUP.md)

## 🎯 Why This Exists

Microsoft Intune portal is great for day-to-day management, but limited for:
- **Custom alerting** - Get notified when devices become non-compliant
- **Historical trends** - Track compliance rates over time
- **Cross-data analysis** - Correlate compliance with endpoint health
- **Flexible reporting** - Build exactly the reports you need

This platform exports **actionable data** to Azure Data Explorer where you can query, visualize, and alert on it.

## 📊 What Data Is Collected

Only data that drives action:

| Data | Why It's Useful | Update Frequency |
|------|-----------------|------------------|
| **Devices + Compliance States** | "Which devices are non-compliant and why?" | Every 6 hours |
| **Device Health Scores** | "Which devices have poor performance?" | Daily |
| **Startup Performance** | "Which devices are slow to boot?" | Daily |
| **App Reliability** | "Which apps are crashing?" | Daily |

**What we DON'T collect**: App catalogs, detected apps inventory, policy definitions (static data with no actionable insight).

## 🏗️ Architecture

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│   Microsoft      │     │  Azure Function  │     │   Azure Data     │
│   Graph API      │────▶│  (Timer Trigger) │────▶│   Explorer       │
│   (Intune Data)  │     │  Consumption Plan│     │   (Free Tier)    │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                                           │
                                                           ▼
                                                  ┌──────────────────┐
                                                  │   KQL Queries    │
                                                  │   + Dashboards   │
                                                  │   + Alerts       │
                                                  └──────────────────┘
```

**Cost**: ~$0/month (Function App consumption plan + ADX Dev/Free tier)

## 🚀 Quick Start

### 1. Deploy (One-Click)

**Option 1: Azure Portal (Recommended)**

1. Click the **Deploy to Azure** button above
2. Fill in parameters (base name, resource group, region)
3. Click **Review + create** → **Create**
4. ⏳ Wait 15-25 minutes

**Option 2: Azure CLI**

```bash
az group create --name rg-intune-analytics --location uksouth

az deployment group create \
  --resource-group rg-intune-analytics \
  --template-file deployment/deploy-function-app.json \
  --parameters baseName=intune-analytics
```

> ✅ **Automatically deployed**: Storage, Function App, ADX cluster, database schema, and function code from GitHub

### 2. Grant Graph API Permissions (Only Manual Step)

The Function App's managed identity needs these **Application** permissions:

| Permission | Why |
|------------|-----|
| `DeviceManagementManagedDevices.Read.All` | Read devices and compliance |
| `DeviceManagementConfiguration.Read.All` | Read endpoint analytics |

**To grant:**
1. Azure Portal → **Entra ID** → **App registrations**
2. Search for your Function App name
3. **API Permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions**
4. Add the permissions above → **Grant admin consent**

### 3. Verify It Works

Check the Function App logs in Application Insights, or wait for the first scheduled run.

## 📈 Dashboards

Import these ADX dashboard definitions:

| Dashboard | Purpose |
|-----------|---------|
| [ComplianceOverview.json](dashboards/ComplianceOverview.json) | Compliance rates, non-compliant devices |
| [DeviceHealth.json](dashboards/DeviceHealth.json) | Device inventory, stale devices, encryption |
| [EndpointAnalyticsDeep.json](dashboards/EndpointAnalyticsDeep.json) | Startup times, app reliability, health scores |

## 🔔 Alerting

The schema includes alert functions. Query them from Logic Apps, Power Automate, or ADX alerts:

```kql
// New non-compliant devices in last 6 hours
AlertNewNonCompliant()

// Devices with health score drop >20 points
AlertHealthScoreDrop(20.0)
```

## 🔧 Handling Duplicates

ADX doesn't have UPSERT, but we solve this with:

1. **Raw tables** - 7-day retention, receives all ingested data
2. **Materialized views** - `arg_max(IngestionTime, *)` always returns latest record

**Always query the `_Current` views**, not raw tables:

```kql
// ✅ Do this - gets latest state per device
ManagedDevices_Current | where ComplianceState == "noncompliant"

// ❌ Not this - returns duplicates
ManagedDevices | where ComplianceState == "noncompliant"
```

## 📁 Project Structure

```
├── fn_compliance/               # Compliance export function (every 6h)
├── fn_endpoint_analytics/       # Endpoint Analytics function (daily 8 AM)
├── shared/                      # Common utilities (ADX client, Graph auth)
├── host.json                    # Function App configuration
├── requirements.txt             # Python dependencies
├── database/
│   └── Schema-Focused.kql       # ADX schema + views + functions
├── dashboards/                  # ADX dashboard definitions
│   ├── ComplianceOverview.json
│   ├── DeviceHealth.json
│   └── ...
├── deployment/
│   └── deploy-function-app.json # ARM template (one-click deploy)
├── SETUP.md                     # Detailed setup guide
└── README.md
```

## 🔐 Security

- **Managed Identity** - No secrets stored, uses Azure AD auth
- **Least Privilege** - Only read permissions, no write access to Intune
- **ADX Ingestor Role** - Function can only ingest, not query or admin

## 📝 License

MIT
