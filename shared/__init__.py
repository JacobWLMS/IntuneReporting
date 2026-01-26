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

from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.kusto.data import KustoClient, KustoConnectionStringBuilder
from azure.kusto.ingest import QueuedIngestClient, IngestionProperties, DataFormat
from msgraph_beta import GraphServiceClient

# Retry configuration for Graph API rate limiting
MAX_RETRIES = 5
BASE_DELAY = 30

@dataclass
class Config:
    """Configuration from environment variables"""
    adx_cluster: str = os.environ.get('ADX_CLUSTER_URI', '')
    adx_database: str = os.environ.get('ADX_DATABASE', 'IntuneAnalytics')
    tenant_id: str = os.environ.get('TENANT_ID', '')
    dry_run: bool = False
    output_path: str = ''

    @classmethod
    def from_env(cls) -> 'Config':
        return cls()


class ADXClient:
    """Azure Data Explorer client for ingestion"""
    
    def __init__(self, config: Config):
        self.config = config
        self._ingest_client: Optional[QueuedIngestClient] = None
    
    def _get_ingest_client(self) -> QueuedIngestClient:
        if not self._ingest_client:
            # Use managed identity in Azure, DefaultAzureCredential locally
            credential = ManagedIdentityCredential() if os.environ.get('WEBSITE_INSTANCE_ID') else DefaultAzureCredential()
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
        
        from io import StringIO
        client.ingest_from_stream(StringIO(jsonl), props)
        return len(data)


def get_graph_client() -> GraphServiceClient:
    """Get authenticated Graph client using managed identity"""
    credential = ManagedIdentityCredential() if os.environ.get('WEBSITE_INSTANCE_ID') else DefaultAzureCredential()
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
