#!/usr/bin/env python3
"""
Intune Compliance Export Runbook
Exports device compliance data from Microsoft Graph to Azure Data Explorer or Log Analytics

Schedule: Every 6 hours
"""
import os
import sys
import json
import logging
import asyncio
from datetime import datetime, timezone
from io import StringIO

# Azure SDK imports
from azure.identity import ClientSecretCredential, DefaultAzureCredential
from azure.kusto.data import KustoConnectionStringBuilder
from azure.kusto.ingest import QueuedIngestClient, IngestionProperties, DataFormat
from azure.monitor.ingestion import LogsIngestionClient
from msgraph_beta import GraphServiceClient
from msgraph_beta.generated.device_management.reports.get_device_status_by_compliace_policy_report.get_device_status_by_compliace_policy_report_post_request_body import GetDeviceStatusByCompliacePolicyReportPostRequestBody

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Retry configuration
MAX_RETRIES = 5
BASE_DELAY = 30

STATUS_MAP = {
    1: 'unknown', 2: 'compliant', 3: 'inGracePeriod',
    4: 'noncompliant', 5: 'error', 6: 'conflict', 7: 'notApplicable'
}

# Log Analytics stream mapping
LOG_ANALYTICS_STREAMS = {
    'ManagedDevices': 'Custom-IntuneDevices_CL',
    'CompliancePolicies': 'Custom-IntuneCompliancePolicies_CL',
    'DeviceComplianceStates': 'Custom-IntuneComplianceStates_CL',
    'SyncState': 'Custom-IntuneSyncState_CL'
}


def get_automation_variable(name: str, default: str = '') -> str:
    """Get variable from Azure Automation or environment"""
    # Try environment variable first (for local testing)
    value = os.environ.get(name)
    if value:
        return value
    
    # Try Azure Automation variables
    try:
        import automationassets
        return automationassets.get_automation_variable(name) or default
    except ImportError:
        return default


def get_credential():
    """Get Azure credential from Automation variables or environment"""
    client_id = get_automation_variable('AZURE_CLIENT_ID')
    client_secret = get_automation_variable('AZURE_CLIENT_SECRET')
    tenant_id = get_automation_variable('AZURE_TENANT_ID')
    
    if client_id and client_secret and tenant_id:
        logger.info("Using client secret authentication")
        return ClientSecretCredential(tenant_id=tenant_id, client_id=client_id, client_secret=client_secret)
    
    logger.info("Using DefaultAzureCredential (managed identity)")
    return DefaultAzureCredential()


def get_graph_client() -> GraphServiceClient:
    """Get authenticated Graph client"""
    credential = get_credential()
    scopes = ['https://graph.microsoft.com/.default']
    return GraphServiceClient(credentials=credential, scopes=scopes)


def add_metadata(records: list, source: str) -> list:
    """Add ingestion metadata to records"""
    now = datetime.now(timezone.utc).isoformat()
    for r in records:
        r['IngestionTime'] = now
        r['TimeGenerated'] = now
        r['SourceSystem'] = source
    return records


async def retry_with_backoff(func, *args, **kwargs):
    """Execute async function with exponential backoff for rate limiting"""
    for attempt in range(MAX_RETRIES):
        try:
            return await func(*args, **kwargs)
        except Exception as e:
            error_str = str(e)
            if '429' in error_str or 'throttl' in error_str.lower():
                delay = BASE_DELAY * (2 ** attempt)
                logger.warning(f"Rate limited, waiting {delay}s (attempt {attempt + 1}/{MAX_RETRIES})")
                await asyncio.sleep(delay)
            else:
                raise
    raise Exception(f"Max retries exceeded after {MAX_RETRIES} attempts")


def parse_report_response(response) -> tuple:
    """Parse Graph Reports API response into list of dicts"""
    if not response or not response.values:
        return [], 0
    
    columns = [c.name for c in response.schema] if response.schema else []
    rows = [dict(zip(columns, row)) for row in response.values]
    total = response.total_row_count or len(rows)
    return rows, total


class DataIngester:
    """Handles data ingestion to ADX or Log Analytics"""
    
    def __init__(self):
        self.backend = get_automation_variable('ANALYTICS_BACKEND', 'ADX').upper()
        self.credential = get_credential()
        
        if self.backend == 'LOGANALYTICS':
            self.dce = get_automation_variable('LOG_ANALYTICS_DCE')
            self.dcr_id = get_automation_variable('LOG_ANALYTICS_DCR_ID')
            self._client = LogsIngestionClient(endpoint=self.dce, credential=self.credential)
        else:
            self.cluster = get_automation_variable('ADX_CLUSTER_URI')
            self.database = get_automation_variable('ADX_DATABASE', 'IntuneAnalytics')
            ingest_uri = self.cluster.replace('https://', 'https://ingest-')
            kcsb = KustoConnectionStringBuilder.with_azure_token_credential(ingest_uri, self.credential)
            self._client = QueuedIngestClient(kcsb)
    
    def ingest(self, table: str, data: list) -> int:
        """Ingest data to the configured backend"""
        if not data:
            return 0
        
        if self.backend == 'LOGANALYTICS':
            stream_name = LOG_ANALYTICS_STREAMS.get(table, f'Custom-{table}_CL')
            self._client.upload(rule_id=self.dcr_id, stream_name=stream_name, logs=data)
        else:
            props = IngestionProperties(database=self.database, table=table, data_format=DataFormat.JSON)
            jsonl = '\n'.join(json.dumps(row, default=str) for row in data)
            self._client.ingest_from_stream(StringIO(jsonl), props)
        
        return len(data)


async def get_managed_devices(graph) -> list:
    """Get all managed devices with compliance-relevant fields"""
    devices = []
    result = await graph.device_management.managed_devices.get()
    
    while result:
        for d in result.value or []:
            devices.append({
                'DeviceId': d.id,
                'DeviceName': d.device_name,
                'UserId': d.user_id,
                'UserPrincipalName': d.user_principal_name,
                'UserDisplayName': d.user_display_name,
                'OperatingSystem': d.operating_system,
                'OSVersion': d.os_version,
                'ComplianceState': str(d.compliance_state) if d.compliance_state else None,
                'ManagementAgent': str(d.management_agent) if d.management_agent else None,
                'EnrolledDateTime': d.enrolled_date_time.isoformat() if d.enrolled_date_time else None,
                'LastSyncDateTime': d.last_sync_date_time.isoformat() if d.last_sync_date_time else None,
                'Model': d.model,
                'Manufacturer': d.manufacturer,
                'SerialNumber': d.serial_number,
                'IsEncrypted': d.is_encrypted,
                'IsSupervised': d.is_supervised,
                'AzureADDeviceId': d.azure_a_d_device_id,
            })
        
        if result.odata_next_link:
            result = await graph.device_management.managed_devices.with_url(result.odata_next_link).get()
        else:
            break
    
    return devices


async def get_compliance_policies(graph) -> list:
    """Get compliance policy metadata"""
    policies = []
    result = await graph.device_management.device_compliance_policies.get()
    
    for p in result.value or []:
        policies.append({
            'PolicyId': p.id,
            'PolicyName': p.display_name,
            'Description': p.description,
            'CreatedDateTime': p.created_date_time.isoformat() if p.created_date_time else None,
            'LastModifiedDateTime': p.last_modified_date_time.isoformat() if p.last_modified_date_time else None,
            'PolicyType': type(p).__name__.replace('CompliancePolicy', ''),
        })
    
    return policies


async def get_compliance_states(graph, policy_id: str) -> list:
    """Get per-device compliance states for a specific policy"""
    states = []
    skip = 0
    
    while True:
        body = GetDeviceStatusByCompliacePolicyReportPostRequestBody()
        body.filter = f"(PolicyId eq '{policy_id}')"
        body.select = []
        body.skip = skip
        body.top = 1000
        body.order_by = []
        
        response = await retry_with_backoff(
            graph.device_management.reports.get_device_status_by_compliace_policy_report.post,
            body
        )
        
        rows, total = parse_report_response(response)
        
        for row in rows:
            states.append({
                'DeviceId': row.get('DeviceId'),
                'DeviceName': row.get('DeviceName'),
                'UserId': row.get('UserId'),
                'UserPrincipalName': row.get('UPN'),
                'PolicyId': row.get('PolicyId'),
                'PolicyName': row.get('PolicyName'),
                'Status': STATUS_MAP.get(row.get('Status'), 'unknown'),
                'StatusRaw': row.get('Status'),
                'SettingCount': row.get('SettingCount'),
                'FailedSettingCount': row.get('FailedSettingCount'),
                'LastContact': row.get('LastContact'),
                'InGracePeriodCount': row.get('InGracePeriodCount'),
            })
        
        skip += len(rows)
        if skip >= total or len(rows) == 0:
            break
    
    return states


async def main():
    """Main execution function"""
    start_time = datetime.now(timezone.utc)
    logger.info("=== Intune Compliance Export Started ===")
    
    try:
        graph = get_graph_client()
        ingester = DataIngester()
        
        # Export managed devices
        logger.info("Fetching managed devices...")
        devices = await get_managed_devices(graph)
        devices = add_metadata(devices, 'IntuneCompliance')
        count = ingester.ingest('ManagedDevices', devices)
        logger.info(f"Exported {count} managed devices")
        
        # Export compliance policies
        logger.info("Fetching compliance policies...")
        policies = await get_compliance_policies(graph)
        policies = add_metadata(policies, 'IntuneCompliance')
        count = ingester.ingest('CompliancePolicies', policies)
        logger.info(f"Exported {count} compliance policies")
        
        # Export compliance states for each policy
        all_states = []
        for policy in policies:
            logger.info(f"Fetching compliance states for policy: {policy['PolicyName']}")
            states = await get_compliance_states(graph, policy['PolicyId'])
            all_states.extend(states)
        
        all_states = add_metadata(all_states, 'IntuneCompliance')
        count = ingester.ingest('DeviceComplianceStates', all_states)
        logger.info(f"Exported {count} compliance states")
        
        # Log sync state
        end_time = datetime.now(timezone.utc)
        duration = (end_time - start_time).total_seconds()
        sync_record = [{
            'ExportType': 'Compliance',
            'RecordCount': len(devices) + len(policies) + len(all_states),
            'StartTime': start_time.isoformat(),
            'EndTime': end_time.isoformat(),
            'DurationSeconds': duration,
            'Status': 'Success',
            'ErrorMessage': None
        }]
        sync_record = add_metadata(sync_record, 'IntuneCompliance')
        ingester.ingest('SyncState', sync_record)
        
        logger.info(f"=== Export completed in {duration:.1f}s ===")
        
    except Exception as e:
        logger.error(f"Export failed: {e}")
        raise


if __name__ == '__main__':
    asyncio.run(main())
