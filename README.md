# Intune Analytics Platform (Automation Account)

Export Microsoft Intune data to Azure Data Explorer or Log Analytics for compliance monitoring, endpoint analytics, and custom alerting.

## Architecture

```
┌─────────────────────┐     ┌──────────────────────┐     ┌─────────────────────┐
│   Microsoft Graph   │────▶│  Azure Automation    │────▶│  ADX / Log Analytics│
│   (Intune Data)     │     │  (PowerShell 7.2)    │     │  (Analytics)        │
└─────────────────────┘     └──────────────────────┘     └─────────────────────┘
```

**Why Automation Account?**
- No storage account required
- Simpler deployment (3 resources)
- Built-in scheduling
- 500 free minutes/month
- Managed identity authentication

## What Data is Exported

| Runbook | Schedule | Data |
|---------|----------|------|
| `Export-IntuneCompliance` | Every 6 hours | Devices, Compliance Policies, Compliance States |
| `Export-EndpointAnalytics` | Daily 8 AM UTC | Health Scores, Startup Performance, App Reliability |

## Quick Start

### 1. Deploy Infrastructure

```bash
az group create --name rg-intune-analytics --location uksouth

az deployment group create \
  --resource-group rg-intune-analytics \
  --template-file deployment/main.bicep \
  --parameters baseName=intune analyticsBackend=ADX adxClusterUri=https://yourcluster.region.kusto.windows.net
```

### 2. Upload Runbook Code

1. Go to **Automation Account** > **Runbooks**
2. Open `Export-IntuneCompliance` > **Edit**
3. Paste code from `runbooks/Export-IntuneCompliance.ps1`
4. Click **Publish**
5. Repeat for `Export-EndpointAnalytics`

### 3. Grant Graph API Permissions

```powershell
# Get the managed identity principal ID from deployment output
./scripts/Grant-GraphPermissions.ps1 -ServicePrincipalObjectId "<principalId>"
```

Required permissions:
- `DeviceManagementManagedDevices.Read.All`
- `DeviceManagementConfiguration.Read.All`

### 4. Grant Backend Access

**For ADX:** Grant "Ingestor" role on the database to the managed identity

**For Log Analytics:** Grant "Monitoring Metrics Publisher" on the DCR

### 5. Test

1. Go to **Automation Account** > **Runbooks**
2. Select a runbook > **Start**
3. Check the job output

## Project Structure

```
├── deployment/
│   ├── main.bicep              # Automation Account + modules + schedules
│   └── main.bicepparam         # Example parameters
├── runbooks/
│   ├── Export-IntuneCompliance.ps1     # Devices, policies, compliance states
│   └── Export-EndpointAnalytics.ps1    # Health scores, startup, apps
├── scripts/
│   └── Grant-GraphPermissions.ps1      # Grant Graph API permissions
├── database/
│   └── Schema-Focused.kql              # ADX table/view definitions
└── dashboards/
    └── *.json                          # ADX dashboard definitions
```

## Graph API Queries

### Export-IntuneCompliance (every 6 hours)

| Query | Endpoint | Fields |
|-------|----------|--------|
| Managed Devices | `GET /deviceManagement/managedDevices` | DeviceId, DeviceName, UserId, UserPrincipalName, OS, ComplianceState, LastSyncDateTime, Model, Manufacturer |
| Compliance Policies | `GET /deviceManagement/deviceCompliancePolicies` | PolicyId, PolicyName, Description, CreatedDateTime |
| Compliance States | `POST /deviceManagement/reports/getDeviceStatusByCompliacePolicyReport` | DeviceId, PolicyId, Status, FailedSettingCount, LastContact |

### Export-EndpointAnalytics (daily)

| Query | Endpoint | Fields |
|-------|----------|--------|
| Device Scores | `GET /deviceManagement/userExperienceAnalyticsDeviceScores` | DeviceId, HealthStatus, EndpointAnalyticsScore, StartupPerformanceScore, AppReliabilityScore |
| Startup History | `GET /deviceManagement/userExperienceAnalyticsDeviceStartupHistory` | DeviceId, StartTime, CoreBootTimeInMs, TotalBootTimeInMs, RestartCategory |
| App Reliability | `GET /deviceManagement/userExperienceAnalyticsAppHealthApplicationPerformance` | AppName, AppCrashCount, AppHangCount, MeanTimeToFailure |

## Configuration Variables

Set automatically during deployment:

| Variable | Description |
|----------|-------------|
| `AnalyticsBackend` | `ADX` or `LogAnalytics` |
| `AdxClusterUri` | ADX cluster URL |
| `AdxDatabase` | ADX database name |
| `LogAnalyticsWorkspaceId` | Log Analytics workspace ID |
| `LogAnalyticsDce` | Data Collection Endpoint URL |
| `LogAnalyticsDcrId` | Data Collection Rule ID |

## Cost

| Resource | Monthly Cost |
|----------|--------------|
| Automation Account | ~$0 (500 free mins) |
| ADX (Dev/Free tier) | $0 |
| Log Analytics | ~$2.76/GB |

**Total: < $5/month**

## License

MIT
