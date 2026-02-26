"""
Shared utilities for Intune export functions.

This module provides:
- Authentication (Azure AD / Managed Identity)
- Microsoft Graph client
- Data ingestion (Log Analytics via DCR)
- Retry logic with exponential backoff
- Configuration validation
"""
import os
import logging
import asyncio
from datetime import datetime, timezone
from typing import Dict, Any

from azure.identity import DefaultAzureCredential, ClientSecretCredential, ManagedIdentityCredential
from azure.monitor.ingestion import LogsIngestionClient
from msgraph_beta import GraphServiceClient

logger = logging.getLogger(__name__)

# Retry configuration
MAX_RETRIES = 5
BASE_DELAY = 30  # seconds


class ConfigurationError(Exception):
    """Raised when required configuration is missing or invalid."""
    pass


def validate_config() -> Dict[str, Any]:
    """
    Validate configuration and return a summary.
    Call this on startup to fail fast if misconfigured.

    Returns:
        Dict with configuration summary

    Raises:
        ConfigurationError if required config is missing
    """
    errors = []
    warnings = []
    config = {}

    # Check authentication
    tenant_id = os.environ.get('AZURE_TENANT_ID')
    client_id = os.environ.get('AZURE_CLIENT_ID')
    client_secret = os.environ.get('AZURE_CLIENT_SECRET')
    use_managed_identity = os.environ.get('USE_MANAGED_IDENTITY', '').lower() in ('true', '1', 'yes')

    if all([tenant_id, client_id, client_secret]) and not use_managed_identity:
        config['auth_method'] = 'client_secret'
        config['tenant_id'] = tenant_id
        config['client_id'] = client_id
    elif use_managed_identity or not any([client_id, client_secret]):
        config['auth_method'] = 'managed_identity'
        if tenant_id:
            config['tenant_id'] = tenant_id
        warnings.append("Using managed identity - ensure Function App has required permissions")
    else:
        missing = []
        if not tenant_id: missing.append('AZURE_TENANT_ID')
        if not client_id: missing.append('AZURE_CLIENT_ID')
        if not client_secret: missing.append('AZURE_CLIENT_SECRET')
        errors.append(f"Partial auth config - missing: {', '.join(missing)}")

    # Check Log Analytics configuration
    dce = os.environ.get('LOG_ANALYTICS_DCE')
    dcr_id = os.environ.get('LOG_ANALYTICS_DCR_ID')

    if not dce:
        errors.append("LOG_ANALYTICS_DCE is required")
    elif not dce.startswith('https://'):
        errors.append(f"LOG_ANALYTICS_DCE should be a URL, got: {dce[:50]}...")
    else:
        config['dce'] = dce

    if not dcr_id:
        errors.append("LOG_ANALYTICS_DCR_ID is required")
    elif not dcr_id.startswith('dcr-'):
        warnings.append(f"LOG_ANALYTICS_DCR_ID usually starts with 'dcr-', got: {dcr_id[:20]}...")
    config['dcr_id'] = dcr_id

    # Log results
    if errors:
        for err in errors:
            logger.error(f"Config error: {err}")
        raise ConfigurationError(f"Configuration invalid: {'; '.join(errors)}")

    for warn in warnings:
        logger.warning(f"Config warning: {warn}")

    logger.info(f"Configuration valid: auth={config['auth_method']}, dce={config.get('dce', 'not set')}")
    return config


async def retry_with_backoff(func, *args, **kwargs):
    """
    Execute async function with exponential backoff for rate limiting.
    Handles Graph API 429 (Too Many Requests) responses.
    """
    last_exception = None

    for attempt in range(MAX_RETRIES):
        try:
            return await func(*args, **kwargs)
        except Exception as e:
            last_exception = e
            error_str = str(e).lower()

            # Check for rate limiting (429) or throttling
            if '429' in str(e) or 'throttl' in error_str or 'too many requests' in error_str:
                delay = BASE_DELAY * (2 ** attempt)
                logger.warning(
                    f"Rate limited, waiting {delay}s (attempt {attempt + 1}/{MAX_RETRIES})"
                )
                await asyncio.sleep(delay)
            # Check for transient errors worth retrying
            elif any(err in error_str for err in ['timeout', 'connection', '503', '504']):
                delay = BASE_DELAY * (2 ** attempt)
                logger.warning(
                    f"Transient error, retrying in {delay}s (attempt {attempt + 1}/{MAX_RETRIES}): {e}"
                )
                await asyncio.sleep(delay)
            else:
                # Non-retryable error, raise immediately
                raise

    # All retries exhausted
    raise Exception(f"Max retries ({MAX_RETRIES}) exceeded. Last error: {last_exception}")


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


# Log Analytics stream mappings (table name → DCR stream name)
LOG_ANALYTICS_STREAMS = {
    'ManagedDevices': 'Custom-IntuneDevices_CL',
    'Users': 'Custom-IntuneUsers_CL',
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
    """Handles data ingestion to Log Analytics via DCR."""

    def __init__(self):
        # Always use Managed Identity for DCR ingestion (even if App Reg is configured for Graph)
        use_mi = get_env('USE_MANAGED_IDENTITY', '').lower() in ('true', '1', 'yes')
        if use_mi:
            logger.info("DataIngester: Using Managed Identity for DCR")
            self.credential = ManagedIdentityCredential()
        else:
            self.credential = get_credential()

        self.dce = get_env('LOG_ANALYTICS_DCE')
        self.dcr_id = get_env('LOG_ANALYTICS_DCR_ID')
        if not self.dce or not self.dcr_id:
            raise ValueError("LOG_ANALYTICS_DCE and LOG_ANALYTICS_DCR_ID required")
        self._client = LogsIngestionClient(endpoint=self.dce, credential=self.credential)

    def ingest(self, table: str, data: list) -> int:
        """Ingest data to Log Analytics. Returns record count."""
        if not data:
            logger.info(f"No records to ingest for {table}")
            return 0

        logger.info(f"Ingesting {len(data)} records to {table}")

        stream_name = LOG_ANALYTICS_STREAMS.get(table, f'Custom-{table}_CL')
        batch_size = 500
        for i in range(0, len(data), batch_size):
            batch = data[i:i + batch_size]
            batch_num = i // batch_size + 1
            try:
                self._client.upload(rule_id=self.dcr_id, stream_name=stream_name, logs=batch)
                logger.info(f"  Uploaded batch {batch_num} ({len(batch)} records)")
            except Exception as e:
                logger.error(f"  Ingestion failed for batch {batch_num} of {table} ({len(batch)} records): {e}")
                raise

        return len(data)
