# Intune Reporting - Test Cases

This document outlines the test cases for validating the Intune Reporting deployment.

## Prerequisites

Before testing:
1. Run deployment script (`deploy.ps1` or `deploy.sh`)
2. Grant Microsoft Graph API permissions in Azure Portal
3. Have function key available for authenticated endpoints

## Test Categories

### 1. Infrastructure Tests

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| INF-01 | Resource Group exists | `az group show --name rg-{name}` | Returns resource group details |
| INF-02 | Storage Account exists | `az storage account show -g rg-{name} -n {name}stor` | Returns storage account details |
| INF-03 | Log Analytics Workspace exists | `az monitor log-analytics workspace show -g rg-{name} -n {name}-law` | Returns workspace with 30-day retention |
| INF-04 | Custom tables created | Query: `IntuneDevices_CL \| take 1` | Query executes (may return 0 rows) |
| INF-05 | DCE exists | `az monitor data-collection endpoint show -g rg-{name} -n {name}-dce` | Returns DCE with ingestion endpoint |
| INF-06 | DCR exists with 9 streams | `az monitor data-collection rule show -g rg-{name} -n {name}-dcr` | Returns DCR with 9 stream declarations |
| INF-07 | Function App exists | `az functionapp show -g rg-{name} -n {name}-func` | Returns function app details |
| INF-08 | Function App uses Flex Consumption | Check `sku` in function app details | SKU contains "FC" or "FlexConsumption" |
| INF-09 | App Registration exists | `az ad app list --display-name {name}-app` | Returns app registration |
| INF-10 | DCR role assignment exists | Check role assignments on DCR | "Monitoring Metrics Publisher" granted to app |

### 2. Function Deployment Tests

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| FN-01 | Functions deployed | `az functionapp function list -g rg-{name} -n {name}-func` | Lists 5 functions |
| FN-02 | export_devices function exists | Check function list | Function with timerTrigger |
| FN-03 | export_compliance function exists | Check function list | Function with timerTrigger |
| FN-04 | export_endpoint_analytics function exists | Check function list | Function with timerTrigger |
| FN-05 | export_autopilot function exists | Check function list | Function with timerTrigger |
| FN-06 | manual_trigger function exists | Check function list | Function with httpTrigger |

### 3. Configuration Tests

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| CFG-01 | AZURE_TENANT_ID set | `az functionapp config appsettings list -g rg-{name} -n {name}-func` | Contains AZURE_TENANT_ID |
| CFG-02 | AZURE_CLIENT_ID set | Check app settings | Contains AZURE_CLIENT_ID matching app registration |
| CFG-03 | AZURE_CLIENT_SECRET set | Check app settings | Contains AZURE_CLIENT_SECRET (hidden value) |
| CFG-04 | LOG_ANALYTICS_DCE set | Check app settings | Contains DCE endpoint URL |
| CFG-05 | LOG_ANALYTICS_DCR_ID set | Check app settings | Contains DCR immutable ID |
| CFG-06 | ANALYTICS_BACKEND set | Check app settings | Value is "LogAnalytics" |

### 4. Functional Tests

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| API-01 | Manual trigger responds | `GET /api/export?code={key}` | 200 OK with JSON listing exports |
| API-02 | Health check passes | `GET /api/export/health?code={key}` | 200 OK with status "healthy" |
| API-03 | Config check passes | Health response | `checks.config.status` = "ok" |
| API-04 | Auth check passes | Health response | `checks.authentication.status` = "ok" |
| API-05 | Graph API accessible | Health response | `checks.graph_api.status` = "ok" |
| API-06 | Log Analytics accessible | Health response | `checks.log_analytics.status` = "ok" |
| API-07 | Test ingestion works | `GET /api/export/test?code={key}` | 200 OK with records_sent > 0 |
| API-08 | Test data appears in LAW | Query IntuneSyncState_CL after test | Test record visible (allow 2-5 min latency) |

### 5. Workbook Tests

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| WB-01 | Device Inventory workbook exists | Azure Portal > Workbooks | Workbook visible and opens |
| WB-02 | Compliance Overview workbook exists | Azure Portal > Workbooks | Workbook visible and opens |
| WB-03 | Device Health workbook exists | Azure Portal > Workbooks | Workbook visible and opens |
| WB-04 | Autopilot Deployment workbook exists | Azure Portal > Workbooks | Workbook visible and opens |
| WB-05 | Workbook sourceId linked | Check workbook properties | sourceId points to LAW resource |

### 6. Security Tests

| ID | Test Case | Steps | Expected Result |
|----|-----------|-------|-----------------|
| SEC-01 | Unauthenticated access blocked | `GET /api/export` (no code) | 401 Unauthorized |
| SEC-02 | Invalid key rejected | `GET /api/export?code=invalid` | 401 Unauthorized |
| SEC-03 | Valid key accepted | `GET /api/export?code={valid_key}` | 200 OK |
| SEC-04 | Function runs as managed identity | Check function execution | Uses app registration credentials |

## Test Execution Commands

### Get Function Key
```bash
az functionapp function keys list \
  --resource-group rg-{name} \
  --name {name}-func \
  --function-name manual_trigger \
  --query default -o tsv
```

### Test Health Endpoint
```bash
curl -s "https://{name}-func.azurewebsites.net/api/export/health?code={key}" | jq
```

### Test Manual Export List
```bash
curl -s "https://{name}-func.azurewebsites.net/api/export?code={key}" | jq
```

### Test Data Ingestion
```bash
curl -s "https://{name}-func.azurewebsites.net/api/export/test?code={key}" | jq
```

### Query Log Analytics for Test Data
```kql
IntuneSyncState_CL
| where SourceSystem == "IntuneReporting-Test"
| order by TimeGenerated desc
| take 5
```

## Expected Health Check Response

```json
{
  "status": "healthy",
  "checks": {
    "config": {
      "status": "ok",
      "backend": "LOGANALYTICS",
      "auth_method": "client_secret"
    },
    "authentication": {
      "status": "ok",
      "token_obtained": true
    },
    "graph_api": {
      "status": "ok",
      "note": "Connected but missing Intune permissions (expected for test tenant)"
    },
    "log_analytics": {
      "status": "ok",
      "backend": "LOGANALYTICS",
      "dce": "https://{name}-dce-xxx.{region}.ingest.monitor.azure.com"
    }
  }
}
```

Note: `graph_api` may show "missing Intune permissions" if Graph API permissions haven't been granted yet. This is expected and the status should still be "ok".

## Troubleshooting

### Health Check Shows "degraded"
1. Check which check is failing in the response
2. For auth errors: Verify client secret is correct and not expired
3. For Graph API errors: Grant required permissions in Azure Portal
4. For Log Analytics errors: Verify DCE endpoint and DCR ID are correct

### Test Ingestion Fails
1. Verify DCR has "Monitoring Metrics Publisher" role assigned to app
2. Check function logs in Azure Portal for detailed errors
3. Verify DCE endpoint is accessible (not blocked by firewall)

### Functions Not Visible
1. Deployment may still be in progress (check deployment status)
2. Try restarting the function app
3. Redeploy with `func azure functionapp publish {name}-func --python`
