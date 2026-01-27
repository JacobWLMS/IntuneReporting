"""
Shared utilities for Intune export functions.
"""
import os
import json
import logging
from datetime import datetime, timezone
from io import StringIO

from azure.identity import DefaultAzureCredential, ClientSecretCredential
from azure.monitor.ingestion import LogsIngestionClient
from msgraph_beta import GraphServiceClient

logger = logging.getLogger(__name__)


def get_env(name: str, default: str = '') -> str:
    """Get environment variable with optional default."""
    return os.environ.get(name, default)


def get_credential():
    """
    Get Azure credential.
    Uses ClientSecretCredential if app registration is configured,
    otherwise falls back to DefaultAzureCredential (managed identity).
    """
    client_id = get_env('AZURE_CLIENT_ID')
    client_secret = get_env('AZURE_CLIENT_SECRET')
    tenant_id = get_env('AZURE_TENANT_ID')

    if all([client_id, client_secret, tenant_id]):
        logger.info("Using client secret authentication")
        return ClientSecretCredential(
            tenant_id=tenant_id,
            client_id=client_id,
            client_secret=client_secret
        )

    logger.info("Using DefaultAzureCredential (managed identity)")
    return DefaultAzureCredential()


def get_graph_client() -> GraphServiceClient:
    """Get authenticated Microsoft Graph client."""
    credential = get_credential()
    scopes = ['https://graph.microsoft.com/.default']
    return GraphServiceClient(credentials=credential, scopes=scopes)


def add_metadata(records: list, source: str) -> list:
    """Add standard ingestion metadata to records."""
    now = datetime.now(timezone.utc).isoformat()
    for record in records:
        record['IngestionTime'] = now
        record['TimeGenerated'] = now
        record['SourceSystem'] = source
    return records


# Log Analytics stream mappings
LOG_ANALYTICS_STREAMS = {
    'ManagedDevices': 'Custom-IntuneDevices_CL',
    'CompliancePolicies': 'Custom-IntuneCompliancePolicies_CL',
    'DeviceComplianceStates': 'Custom-IntuneComplianceStates_CL',
    'DeviceScores': 'Custom-IntuneDeviceScores_CL',
    'StartupPerformance': 'Custom-IntuneStartupPerformance_CL',
    'AppReliability': 'Custom-IntuneAppReliability_CL',
    'AutopilotDevices': 'Custom-IntuneAutopilotDevices_CL',
    'AutopilotProfiles': 'Custom-IntuneAutopilotProfiles_CL',
    'SyncState': 'Custom-IntuneSyncState_CL',
}


class DataIngester:
    """Handles data ingestion to Log Analytics or ADX."""

    def __init__(self):
        self.backend = get_env('ANALYTICS_BACKEND', 'LogAnalytics').upper()
        self.credential = get_credential()

        if self.backend == 'LOGANALYTICS':
            self.dce = get_env('LOG_ANALYTICS_DCE')
            self.dcr_id = get_env('LOG_ANALYTICS_DCR_ID')
            if not self.dce or not self.dcr_id:
                raise ValueError("LOG_ANALYTICS_DCE and LOG_ANALYTICS_DCR_ID required")
            self._client = LogsIngestionClient(endpoint=self.dce, credential=self.credential)
        else:
            # ADX backend
            from azure.kusto.data import KustoConnectionStringBuilder
            from azure.kusto.ingest import QueuedIngestClient
            self.cluster = get_env('ADX_CLUSTER_URI')
            self.database = get_env('ADX_DATABASE', 'IntuneAnalytics')
            if not self.cluster:
                raise ValueError("ADX_CLUSTER_URI required for ADX backend")
            ingest_uri = self.cluster.replace('https://', 'https://ingest-')
            kcsb = KustoConnectionStringBuilder.with_azure_token_credential(ingest_uri, self.credential)
            self._client = QueuedIngestClient(kcsb)

    def ingest(self, table: str, data: list) -> int:
        """Ingest data to configured backend. Returns record count."""
        if not data:
            logger.info(f"No records to ingest for {table}")
            return 0

        logger.info(f"Ingesting {len(data)} records to {table}")

        if self.backend == 'LOGANALYTICS':
            stream_name = LOG_ANALYTICS_STREAMS.get(table, f'Custom-{table}_CL')
            # Batch in chunks of 500
            batch_size = 500
            for i in range(0, len(data), batch_size):
                batch = data[i:i + batch_size]
                self._client.upload(rule_id=self.dcr_id, stream_name=stream_name, logs=batch)
                logger.info(f"  Uploaded batch {i // batch_size + 1} ({len(batch)} records)")
        else:
            from azure.kusto.ingest import IngestionProperties, DataFormat
            props = IngestionProperties(
                database=self.database,
                table=table,
                data_format=DataFormat.MULTIJSON
            )
            jsonl = '\n'.join(json.dumps(row, default=str) for row in data)
            self._client.ingest_from_stream(StringIO(jsonl), props)

        return len(data)
