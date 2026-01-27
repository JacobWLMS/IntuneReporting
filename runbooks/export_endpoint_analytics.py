#!/usr/bin/env python3
"""
Intune Endpoint Analytics Export Runbook
Exports device health and performance data from Microsoft Graph to Azure Data Explorer or Log Analytics

Schedule: Daily at 8 AM
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

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Log Analytics stream mapping
LOG_ANALYTICS_STREAMS = {
    'DeviceScores': 'Custom-IntuneDeviceScores_CL',
    'StartupPerformance': 'Custom-IntuneStartupPerformance_CL',
    'AppReliability': 'Custom-IntuneAppReliability_CL',
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


async def get_device_scores(graph) -> list:
    """Get device health scores - the core Endpoint Analytics metric"""
    scores = []
    result = await graph.device_management.user_experience_analytics_device_scores.get()
    
    while result:
        for d in result.value or []:
            scores.append({
                'DeviceId': d.device_name,
                'DeviceName': d.device_name,
                'Model': d.model,
                'Manufacturer': d.manufacturer,
                'HealthStatus': str(d.health_status) if d.health_status else None,
                'EndpointAnalyticsScore': d.endpoint_analytics_score,
                'StartupPerformanceScore': d.startup_performance_score,
                'AppReliabilityScore': d.app_reliability_score,
                'WorkFromAnywhereScore': d.work_from_anywhere_score,
                'MeanResourceSpikeTimeScore': d.mean_resource_spike_time_score,
                'BatteryHealthScore': getattr(d, 'battery_health_score', None),
            })
        
        if result.odata_next_link:
            result = await graph.device_management.user_experience_analytics_device_scores.with_url(result.odata_next_link).get()
        else:
            break
    
    return scores


async def get_startup_performance(graph) -> list:
    """Get device startup performance metrics"""
    records = []
    result = await graph.device_management.user_experience_analytics_device_startup_history.get()
    
    while result:
        for s in result.value or []:
            records.append({
                'DeviceId': s.device_id,
                'StartTime': s.start_time.isoformat() if s.start_time else None,
                'CoreBootTimeInMs': s.core_boot_time_in_ms,
                'GroupPolicyBootTimeInMs': s.group_policy_boot_time_in_ms,
                'GroupPolicyLoginTimeInMs': s.group_policy_login_time_in_ms,
                'CoreLoginTimeInMs': s.core_login_time_in_ms,
                'TotalBootTimeInMs': s.total_boot_time_in_ms,
                'TotalLoginTimeInMs': s.total_login_time_in_ms,
                'IsFirstLogin': s.is_first_login,
                'IsFeatureUpdate': s.is_feature_update,
                'OperatingSystemVersion': s.operating_system_version,
                'RestartCategory': str(s.restart_category) if s.restart_category else None,
                'RestartFaultBucket': s.restart_fault_bucket,
            })
        
        if result.odata_next_link:
            result = await graph.device_management.user_experience_analytics_device_startup_history.with_url(result.odata_next_link).get()
        else:
            break
    
    return records


async def get_app_reliability(graph) -> list:
    """Get app reliability data - which apps are crashing?"""
    records = []
    
    try:
        result = await graph.device_management.user_experience_analytics_app_health_application_performance.get()
        
        while result:
            for a in result.value or []:
                records.append({
                    'AppName': a.app_name,
                    'AppDisplayName': a.app_display_name,
                    'AppPublisher': a.app_publisher,
                    'ActiveDeviceCount': a.active_device_count,
                    'AppCrashCount': a.app_crash_count,
                    'AppHangCount': a.app_hang_count,
                    'MeanTimeToFailureInMinutes': a.mean_time_to_failure_in_minutes,
                    'AppHealthScore': getattr(a, 'app_health_score', None),
                    'AppHealthStatus': getattr(a, 'app_health_status', None),
                })
            
            if result.odata_next_link:
                result = await graph.device_management.user_experience_analytics_app_health_application_performance.with_url(result.odata_next_link).get()
            else:
                break
    except Exception as e:
        logger.warning(f"Could not fetch app reliability data: {e}")
    
    return records


async def main():
    """Main execution function"""
    start_time = datetime.now(timezone.utc)
    logger.info("=== Intune Endpoint Analytics Export Started ===")
    
    try:
        graph = get_graph_client()
        ingester = DataIngester()
        total_records = 0
        
        # Export device scores
        logger.info("Fetching device health scores...")
        scores = await get_device_scores(graph)
        scores = add_metadata(scores, 'EndpointAnalytics')
        count = ingester.ingest('DeviceScores', scores)
        total_records += count
        logger.info(f"Exported {count} device scores")
        
        # Export startup performance
        logger.info("Fetching startup performance data...")
        startup = await get_startup_performance(graph)
        startup = add_metadata(startup, 'EndpointAnalytics')
        count = ingester.ingest('StartupPerformance', startup)
        total_records += count
        logger.info(f"Exported {count} startup performance records")
        
        # Export app reliability
        logger.info("Fetching app reliability data...")
        apps = await get_app_reliability(graph)
        apps = add_metadata(apps, 'EndpointAnalytics')
        count = ingester.ingest('AppReliability', apps)
        total_records += count
        logger.info(f"Exported {count} app reliability records")
        
        # Log sync state
        end_time = datetime.now(timezone.utc)
        duration = (end_time - start_time).total_seconds()
        sync_record = [{
            'ExportType': 'EndpointAnalytics',
            'RecordCount': total_records,
            'StartTime': start_time.isoformat(),
            'EndTime': end_time.isoformat(),
            'DurationSeconds': duration,
            'Status': 'Success',
            'ErrorMessage': None
        }]
        sync_record = add_metadata(sync_record, 'EndpointAnalytics')
        ingester.ingest('SyncState', sync_record)
        
        logger.info(f"=== Export completed in {duration:.1f}s ===")
        
    except Exception as e:
        logger.error(f"Export failed: {e}")
        raise


if __name__ == '__main__':
    asyncio.run(main())
