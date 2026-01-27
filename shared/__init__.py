"""
Shared utilities for Intune Analytics Function App
"""
import os
import json
import logging
import asyncio
from datetime import datetime, timezone
from dataclasses import dataclass
from typing import Optional
from abc import ABC, abstractmethod
from io import StringIO

from azure.identity import DefaultAzureCredential, ClientSecretCredential
from azure.kusto.data import KustoConnectionStringBuilder
from azure.kusto.ingest import QueuedIngestClient, IngestionProperties, DataFormat
from azure.monitor.ingestion import LogsIngestionClient
from msgraph_beta import GraphServiceClient

# Retry configuration for Graph API rate limiting
MAX_RETRIES = 5
BASE_DELAY = 30

@dataclass
class Config:
    """Configuration from environment variables"""
    # Backend choice: 'ADX' or 'LogAnalytics'
    analytics_backend: str = os.environ.get('ANALYTICS_BACKEND', 'ADX')
    
    # ADX settings
    adx_cluster: str = os.environ.get('ADX_CLUSTER_URI', '')
    adx_database: str = os.environ.get('ADX_DATABASE', 'IntuneAnalytics')
    
    # Log Analytics settings
    log_analytics_dce: str = os.environ.get('LOG_ANALYTICS_DCE', '')  # Data Collection Endpoint
    log_analytics_dcr_id: str = os.environ.get('LOG_ANALYTICS_DCR_ID', '')  # Data Collection Rule ID
    log_analytics_workspace_id: str = os.environ.get('LOG_ANALYTICS_WORKSPACE_ID', '')
    
    @classmethod
    def from_env(cls) -> 'Config':
        return cls()


# Table name to Log Analytics stream mapping
LOG_ANALYTICS_STREAMS = {
    'ManagedDevices': 'Custom-IntuneDevices_CL',
    'CompliancePolicies': 'Custom-IntuneCompliancePolicies_CL', 
    'DeviceComplianceStates': 'Custom-IntuneComplianceStates_CL',
    'DeviceScores': 'Custom-IntuneDeviceScores_CL',
    'StartupPerformance': 'Custom-IntuneStartupPerformance_CL',
    'AppReliability': 'Custom-IntuneAppReliability_CL',
    'SyncState': 'Custom-IntuneSyncState_CL'
}


class IngestionClient(ABC):
    """Abstract base class for data ingestion"""
    
    @abstractmethod
    def ingest(self, table: str, data: list[dict]) -> int:
        """Ingest data to the specified table"""
        pass


class ADXClient(IngestionClient):
    """Azure Data Explorer client for ingestion"""
    
    def __init__(self, config: Config):
        self.config = config
        self._ingest_client: Optional[QueuedIngestClient] = None
    
    def _get_ingest_client(self) -> QueuedIngestClient:
        if not self._ingest_client:
            credential = get_credential()
            ingest_uri = self.config.adx_cluster.replace('https://', 'https://ingest-')
            kcsb = KustoConnectionStringBuilder.with_azure_token_credential(ingest_uri, credential)
            self._ingest_client = QueuedIngestClient(kcsb)
        return self._ingest_client
    
    def ingest(self, table: str, data: list[dict]) -> int:
        """Ingest data to ADX table"""
        if not data:
            return 0
        
        client = self._get_ingest_client()
        props = IngestionProperties(database=self.config.adx_database, table=table, data_format=DataFormat.JSON)
        
        # Convert to JSONL for ingestion
        jsonl = '\n'.join(json.dumps(row, default=str) for row in data)
        client.ingest_from_stream(StringIO(jsonl), props)
        return len(data)


class LogAnalyticsClient(IngestionClient):
    """Log Analytics client for ingestion via Data Collection Rules"""
    
    def __init__(self, config: Config):
        self.config = config
        self._client: Optional[LogsIngestionClient] = None
    
    def _get_client(self) -> LogsIngestionClient:
        if not self._client:
            credential = get_credential()
            self._client = LogsIngestionClient(endpoint=self.config.log_analytics_dce, credential=credential)
        return self._client
    
    def ingest(self, table: str, data: list[dict]) -> int:
        """Ingest data to Log Analytics custom table"""
        if not data:
            return 0
        
        # Map table name to stream name
        stream_name = LOG_ANALYTICS_STREAMS.get(table, f'Custom-{table}_CL')
        
        client = self._get_client()
        
        # Log Analytics expects TimeGenerated field (ISO 8601 format)
        for record in data:
            if 'IngestionTime' in record and 'TimeGenerated' not in record:
                record['TimeGenerated'] = record['IngestionTime']
        
        client.upload(
            rule_id=self.config.log_analytics_dcr_id,
            stream_name=stream_name,
            logs=data
        )
        return len(data)


def get_ingestion_client(config: Config) -> IngestionClient:
    """Factory function to get the appropriate ingestion client based on config"""
    if config.analytics_backend.upper() == 'LOGANALYTICS':
        logging.info("Using Log Analytics backend")
        return LogAnalyticsClient(config)
    else:
        logging.info("Using Azure Data Explorer backend")
        return ADXClient(config)


def get_credential():
    """Get Azure credential - supports client secret or managed identity"""
    # If client secret is configured, use it (for app registration auth)
    client_id = os.environ.get('AZURE_CLIENT_ID')
    client_secret = os.environ.get('AZURE_CLIENT_SECRET')
    tenant_id = os.environ.get('AZURE_TENANT_ID') or os.environ.get('TENANT_ID')

    if client_id and client_secret and tenant_id:
        logging.info("Using client secret authentication")
        return ClientSecretCredential(tenant_id=tenant_id, client_id=client_id, client_secret=client_secret)

    # Otherwise use DefaultAzureCredential (managed identity in Azure, Azure CLI locally)
    logging.info("Using DefaultAzureCredential")
    return DefaultAzureCredential()


def get_graph_client() -> GraphServiceClient:
    """Get authenticated Graph client"""
    credential = get_credential()
    scopes = ['https://graph.microsoft.com/.default']
    return GraphServiceClient(credentials=credential, scopes=scopes)


def add_metadata(records: list[dict], source: str) -> list[dict]:
    """Add ingestion metadata to records"""
    now = datetime.now(timezone.utc).isoformat()
    for r in records:
        r['IngestionTime'] = now
        r['SourceSystem'] = source
    return records


def parse_report_response(response) -> tuple[list[dict], int]:
    """Parse Graph Reports API response into list of dicts"""
    if not response or not response.values:
        return [], 0
    
    columns = [c.name for c in response.schema] if response.schema else []
    rows = [dict(zip(columns, row)) for row in response.values]
    total = response.total_row_count or len(rows)
    return rows, total


async def retry_with_backoff(func, *args, **kwargs):
    """Execute async function with exponential backoff for rate limiting"""
    for attempt in range(MAX_RETRIES):
        try:
            return await func(*args, **kwargs)
        except Exception as e:
            error_str = str(e)
            if '429' in error_str or 'throttl' in error_str.lower():
                delay = BASE_DELAY * (2 ** attempt)
                logging.warning(f"Rate limited, waiting {delay}s (attempt {attempt + 1}/{MAX_RETRIES})")
                await asyncio.sleep(delay)
            else:
                raise
    raise Exception(f"Max retries exceeded after {MAX_RETRIES} attempts")
