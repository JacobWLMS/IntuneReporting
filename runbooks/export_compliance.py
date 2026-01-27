#!/usr/bin/env python3
"""
Intune Compliance Export Runbook
Exports compliance policies and per-device compliance states to Log Analytics or Azure Data Explorer

NOTE: Device inventory is handled by export_devices.py - this runbook only exports compliance data.

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
from azure.identity import ClientSecretCredential
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
    'CompliancePolicies': 'Custom-IntuneCompliancePolicies_CL',
    'DeviceComplianceStates': 'Custom-IntuneComplianceStates_CL',
    'SyncState': 'Custom-IntuneSyncState_CL'
}


def get_automation_variable(name: str, default: str = '') -> str:
    """Get variable from Azure Automation or environment"""
    value = os.environ.get(name)
    if value:
        return value
    
    try:
        import automationassets  # type: ignore  # Only available in Azure Automation runtime
        return automationassets.get_automation_variable(name) or default
    except ImportError:
        return default


def get_credential():
    """Get Azure credential from App Registration"""
    client_id = get_automation_variable('AZURE_CLIENT_ID')
    client_secret = get_automation_variable('AZURE_CLIENT_SECRET')
    tenant_id = get_automation_variable('AZURE_TENANT_ID')
    
    if not all([client_id, client_secret, tenant_id]):
        raise ValueError("Missing required credentials: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID")
    
    logger.info("Using client secret authentication")
    return ClientSecretCredential(tenant_id=tenant_id, client_id=client_id, client_secret=client_secret)


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
    raise Exception(f"Max retries ({MAX_RETRIES}) exceeded")


def parse_report_response(response) -> tuple:
    """Parse Graph Reports API response into list of dicts"""
    if not response or not response.values:
        return [], 0
    
    columns = [c.name for c in response.schema] if response.schema else []
    rows = [dict(zip(columns, row)) for row in response.values]
    total = response.total_row_count or len(rows)
    return rows, total


async def get_compliance_policies(graph_client: GraphServiceClient) -> list:
    """Get all compliance policy definitions"""
    logger.info("Fetching compliance policies...")
    policies = []
    
    try:
        result = await retry_with_backoff(
            graph_client.device_management.device_compliance_policies.get
        )
        
        for policy in result.value or []:
            policies.append({
                'PolicyId': policy.id,
                'PolicyName': policy.display_name,
                'Description': policy.description,
                'CreatedDateTime': policy.created_date_time.isoformat() if policy.created_date_time else None,
                'LastModifiedDateTime': policy.last_modified_date_time.isoformat() if policy.last_modified_date_time else None,
                'PolicyType': type(policy).__name__.replace('CompliancePolicy', ''),
            })
            
    except Exception as e:
        logger.error(f"Error fetching compliance policies: {e}")
        raise
    
    logger.info(f"Fetched {len(policies)} compliance policies")
    return policies


async def get_compliance_states(graph_client: GraphServiceClient, policy_id: str, policy_name: str) -> list:
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
        
        try:
            response = await retry_with_backoff(
                graph_client.device_management.reports.get_device_status_by_compliace_policy_report.post,
                body
            )
        except Exception as e:
            logger.error(f"Error fetching compliance states for policy {policy_name}: {e}")
            raise
        
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


# ============================================================================
# Log Analytics Ingestion (Primary)
# ============================================================================

def ingest_to_log_analytics(data: dict):
    """Ingest data to Log Analytics via Data Collection Rule"""
    dce = get_automation_variable('LOG_ANALYTICS_DCE')
    dcr_id = get_automation_variable('LOG_ANALYTICS_DCR_ID')
    
    if not dce or not dcr_id:
        raise ValueError("LOG_ANALYTICS_DCE and LOG_ANALYTICS_DCR_ID are required for Log Analytics backend")
    
    credential = get_credential()
    client = LogsIngestionClient(endpoint=dce, credential=credential)
    
    for table_name, records in data.items():
        if not records:
            logger.info(f"No records to ingest for {table_name}")
            continue
            
        stream_name = LOG_ANALYTICS_STREAMS.get(table_name)
        if not stream_name:
            logger.warning(f"No stream mapping for {table_name}, skipping")
            continue
        
        logger.info(f"Ingesting {len(records)} records to {stream_name}")
        
        # Split into batches of 500 records
        batch_size = 500
        for i in range(0, len(records), batch_size):
            batch = records[i:i + batch_size]
            try:
                client.upload(rule_id=dcr_id, stream_name=stream_name, logs=batch)
                logger.info(f"Ingested batch {i // batch_size + 1} ({len(batch)} records)")
            except Exception as e:
                logger.error(f"Failed to ingest batch to {stream_name}: {e}")
                raise


# ============================================================================
# ADX Ingestion (Secondary)
# ============================================================================

def ingest_to_adx(data: dict):
    """Ingest data to Azure Data Explorer"""
    cluster_uri = get_automation_variable('ADX_CLUSTER_URI')
    database = get_automation_variable('ADX_DATABASE', 'IntuneAnalytics')
    
    if not cluster_uri:
        raise ValueError("ADX_CLUSTER_URI is required for ADX backend")
    
    credential = get_credential()
    
    # Build connection string
    kcsb = KustoConnectionStringBuilder.with_azure_token_credential(cluster_uri, credential)
    ingest_uri = cluster_uri.replace('https://', 'https://ingest-')
    ingest_kcsb = KustoConnectionStringBuilder.with_azure_token_credential(ingest_uri, credential)
    
    ingest_client = QueuedIngestClient(ingest_kcsb)
    
    for table_name, records in data.items():
        if not records:
            logger.info(f"No records to ingest for {table_name}")
            continue
        
        logger.info(f"Ingesting {len(records)} records to ADX table {table_name}")
        
        # Convert to JSON lines
        json_data = '\n'.join(json.dumps(r) for r in records)
        stream = StringIO(json_data)
        
        ingestion_props = IngestionProperties(
            database=database,
            table=table_name,
            data_format=DataFormat.MULTIJSON
        )
        
        try:
            ingest_client.ingest_from_stream(stream, ingestion_properties=ingestion_props)
            logger.info(f"Successfully queued {table_name} for ingestion")
        except Exception as e:
            logger.error(f"Failed to ingest {table_name}: {e}")
            raise


# ============================================================================
# Main Entry Point
# ============================================================================

async def main():
    """Main execution function"""
    start_time = datetime.now(timezone.utc)
    logger.info("=" * 60)
    logger.info("Starting Intune Compliance Export")
    logger.info("=" * 60)
    
    # Get backend setting (Log Analytics is primary)
    backend = get_automation_variable('ANALYTICS_BACKEND', 'LogAnalytics')
    logger.info(f"Analytics backend: {backend}")
    
    # Get Graph client
    graph_client = get_graph_client()
    
    # Fetch compliance policies
    policies = await get_compliance_policies(graph_client)
    policies = add_metadata(policies, 'IntuneComplianceExport')
    
    # Fetch compliance states for each policy
    all_states = []
    for policy in policies:
        logger.info(f"Fetching compliance states for: {policy['PolicyName']}")
        states = await get_compliance_states(graph_client, policy['PolicyId'], policy['PolicyName'])
        all_states.extend(states)
        logger.info(f"  Found {len(states)} device states")
    
    all_states = add_metadata(all_states, 'IntuneComplianceExport')
    
    # Create sync state record
    end_time = datetime.now(timezone.utc)
    duration = (end_time - start_time).total_seconds()
    sync_state = [{
        'SyncType': 'Compliance',
        'PolicyCount': len(policies),
        'StateCount': len(all_states),
        'Status': 'Success',
        'DurationSeconds': duration,
        'SyncTime': end_time.isoformat()
    }]
    sync_state = add_metadata(sync_state, 'IntuneComplianceExport')
    
    data = {
        'CompliancePolicies': policies,
        'DeviceComplianceStates': all_states,
        'SyncState': sync_state
    }
    
    # Ingest to chosen backend
    if backend.upper() == 'LOGANALYTICS':
        ingest_to_log_analytics(data)
    else:
        ingest_to_adx(data)
    
    logger.info("=" * 60)
    logger.info("Compliance export completed successfully")
    logger.info(f"Policies: {len(policies)}, States: {len(all_states)}")
    logger.info(f"Duration: {duration:.1f}s")
    logger.info("=" * 60)


if __name__ == '__main__':
    asyncio.run(main())
