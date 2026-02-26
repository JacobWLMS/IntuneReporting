# Intune Alert Rules

Sample Azure Monitor alert rules for Intune data. These alerts monitor your Intune environment and can notify you of issues.

## Available Alerts

### 1. Non-Compliant Devices Alert (`noncompliant-devices.json`)
- **Purpose**: Alerts when the number of non-compliant devices exceeds a threshold
- **Default threshold**: 10 devices
- **Frequency**: Hourly evaluation
- **Severity**: Warning (2)

### 2. Stale Devices Alert (`stale-devices.json`)
- **Purpose**: Alerts when devices haven't synced with Intune for an extended period
- **Default thresholds**:
  - Stale after 14 days without sync
  - Alert when more than 5 stale devices
- **Frequency**: Daily evaluation
- **Severity**: Informational (3)

## Deployment

### Prerequisites
- Deployed Intune Reporting infrastructure (run `deploy.ps1` or `deploy.sh` first)
- Log Analytics Workspace resource ID
- (Optional) Action Group for notifications

### Deploy via Azure CLI

```bash
# Get your workspace resource ID
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group rg-your-intune \
  --workspace-name your-intune-law \
  --query id -o tsv)

# Deploy non-compliant devices alert
az deployment group create \
  --resource-group rg-your-intune \
  --template-file noncompliant-devices.json \
  --parameters workspaceResourceId="$WORKSPACE_ID" threshold=10

# Deploy stale devices alert
az deployment group create \
  --resource-group rg-your-intune \
  --template-file stale-devices.json \
  --parameters workspaceResourceId="$WORKSPACE_ID" staleDaysThreshold=14 deviceCountThreshold=5
```

### Deploy via PowerShell

```powershell
# Get workspace resource ID
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName "rg-your-intune" -Name "your-intune-law"
$workspaceId = $workspace.ResourceId

# Deploy non-compliant devices alert
New-AzResourceGroupDeployment `
  -ResourceGroupName "rg-your-intune" `
  -TemplateFile "noncompliant-devices.json" `
  -workspaceResourceId $workspaceId `
  -threshold 10

# Deploy stale devices alert
New-AzResourceGroupDeployment `
  -ResourceGroupName "rg-your-intune" `
  -TemplateFile "stale-devices.json" `
  -workspaceResourceId $workspaceId `
  -staleDaysThreshold 14 `
  -deviceCountThreshold 5
```

## Adding Notifications

To receive email/SMS/webhook notifications, create an Action Group first:

```bash
# Create action group with email notification
az monitor action-group create \
  --resource-group rg-your-intune \
  --name "intune-alerts-ag" \
  --short-name "IntuneAG" \
  --action email admin admin@example.com

# Get action group ID
ACTION_GROUP_ID=$(az monitor action-group show \
  --resource-group rg-your-intune \
  --name "intune-alerts-ag" \
  --query id -o tsv)

# Deploy alert with notifications
az deployment group create \
  --resource-group rg-your-intune \
  --template-file noncompliant-devices.json \
  --parameters workspaceResourceId="$WORKSPACE_ID" actionGroupId="$ACTION_GROUP_ID"
```

## Customizing Alerts

You can modify the alert parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `threshold` | Non-compliant device count threshold | 10 |
| `staleDaysThreshold` | Days without sync to be considered stale | 14 |
| `deviceCountThreshold` | Stale device count threshold | 5 |

## Viewing Alerts

After deployment, view alerts in:
1. Azure Portal > Monitor > Alerts
2. Azure Portal > Your Resource Group > Alerts

## Creating Custom Alerts

Use these templates as a starting point. Key components:
- `scopes`: Point to your Log Analytics workspace
- `query`: KQL query against Intune tables
- `threshold`: Numeric threshold for triggering
- `evaluationFrequency`: How often to run (PT1H = 1 hour, P1D = 1 day)
