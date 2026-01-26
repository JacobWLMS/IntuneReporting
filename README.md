# Intune Analytics Platform

Export Microsoft Intune data to Azure Data Explorer for compliance monitoring, endpoint analytics, and custom alerting.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FYOUR-ORG%2Fintune-analytics%2Fmain%2Fdeployment%2Fdeploy-function-app.json)

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

### 1. Deploy Infrastructure

Click the "Deploy to Azure" button above, or run:

```bash
az deployment group create \
  --resource-group YOUR-RG \
  --template-file deployment/deploy-function-app.json \
  --parameters baseName=intune-analytics
```

### 2. Grant Graph API Permissions

The Function App's managed identity needs these **Application** permissions:

| Permission | Why |
|------------|-----|
| `DeviceManagementManagedDevices.Read.All` | Read devices and compliance |
| `DeviceManagementConfiguration.Read.All` | Read endpoint analytics |

**To grant:**
1. Azure Portal → Entra ID → Enterprise Applications
2. Find your Function App (by principal ID from deployment output)
3. API Permissions → Add permissions → Microsoft Graph → Application
4. Add the permissions above → Grant admin consent

### 3. Create ADX Schema

Open your ADX cluster in the [ADX Web UI](https://dataexplorer.azure.com/) and run:

```
database/Schema-Focused.kql
```

This creates:
- Tables with 7-day retention (raw data)
- Materialized views (current state - no duplicates!)
- Functions for common queries and alerts

### 4. Deploy Function Code

```bash
cd function-app
func azure functionapp publish YOUR-FUNCTION-APP-NAME --python
```

### 5. Verify It Works

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
├── function-app/                 # Azure Function App
│   ├── fn_compliance/           # Compliance export (every 6h)
│   ├── fn_endpoint_analytics/   # Endpoint Analytics (daily)
│   ├── shared/                  # Common utilities
│   ├── host.json
│   └── requirements.txt
├── database/
│   └── Schema-Focused.kql       # ADX schema + views + functions
├── dashboards/
│   ├── ComplianceOverview.json
│   ├── DeviceHealth.json
│   └── EndpointAnalyticsDeep.json
├── deployment/
│   └── deploy-function-app.json # ARM template
├── SETUP.md                     # Detailed setup guide
└── README.md
```

## 🔐 Security

- **Managed Identity** - No secrets stored, uses Azure AD auth
- **Least Privilege** - Only read permissions, no write access to Intune
- **ADX Ingestor Role** - Function can only ingest, not query or admin

## 📝 License

MIT
