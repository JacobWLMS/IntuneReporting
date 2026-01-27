#!/usr/bin/env python3
"""
Intune Devices Export Runbook
Exports managed device inventory from Microsoft Graph to Log Analytics or Azure Data Explorer

This is the core runbook - ManagedDevices is the primary key table that other data references.

Schedule: Every 4 hours
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

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Retry configuration
MAX_RETRIES = 5
BASE_DELAY = 30

# Log Analytics stream mapping
LOG_ANALYTICS_STREAMS = {
    'ManagedDevices': 'Custom-IntuneDevices_CL',
    'SyncState': 'Custom-IntuneSyncState_CL'
}


def get_automation_variable(name: str, default: str = '') -> str:
    """Get variable from Azure Automation or environment"""
    value = os.environ.get(name)
    if value:
        return value
    
    try:
        import automationassets
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


async def get_managed_devices(graph_client: GraphServiceClient) -> list:
    """Fetch all managed devices with pagination"""
    logger.info("Fetching managed devices...")
    devices = []
    
    # Select key fields for device inventory
    select_fields = [
        'id', 'deviceName', 'userPrincipalName', 'userDisplayName',
        'operatingSystem', 'osVersion', 'complianceState', 'managementState',
        'enrolledDateTime', 'lastSyncDateTime', 'manufacturer', 'model',
        'serialNumber', 'imei', 'managementAgent', 'ownerType',
        'deviceEnrollmentType', 'activationLockBypassCode', 'emailAddress',
        'azureADRegistered', 'azureADDeviceId', 'deviceRegistrationState',
        'isEncrypted', 'isSupervised', 'jailBroken', 'autopilotEnrolled',
        'deviceCategoryDisplayName', 'hardwareInformation',
        'totalStorageSpaceInBytes', 'freeStorageSpaceInBytes',
        'physicalMemoryInBytes', 'subscriberCarrier', 'wiFiMacAddress',
        'ethernetMacAddress'
    ]
    
    try:
        result = await retry_with_backoff(
            graph_client.device_management.managed_devices.get,
            request_configuration=lambda config: setattr(
                config.query_parameters, 'select', select_fields
            ) if hasattr(config, 'query_parameters') else None
        )
        
        while result:
            if result.value:
                for device in result.value:
                    device_dict = {
                        'DeviceId': device.id,
                        'DeviceName': device.device_name,
                        'UserPrincipalName': device.user_principal_name,
                        'UserDisplayName': device.user_display_name,
                        'OperatingSystem': device.operating_system,
                        'OSVersion': device.os_version,
                        'ComplianceState': device.compliance_state.value if device.compliance_state else None,
                        'ManagementState': device.management_state.value if device.management_state else None,
                        'EnrolledDateTime': device.enrolled_date_time.isoformat() if device.enrolled_date_time else None,
                        'LastSyncDateTime': device.last_sync_date_time.isoformat() if device.last_sync_date_time else None,
                        'Manufacturer': device.manufacturer,
                        'Model': device.model,
                        'SerialNumber': device.serial_number,
                        'IMEI': device.imei,
                        'ManagementAgent': device.management_agent.value if device.management_agent else None,
                        'OwnerType': device.owner_type.value if device.owner_type else None,
                        'DeviceEnrollmentType': device.device_enrollment_type.value if device.device_enrollment_type else None,
                        'EmailAddress': device.email_address,
                        'AzureADRegistered': device.azure_a_d_registered,
                        'AzureADDeviceId': device.azure_a_d_device_id,
                        'DeviceRegistrationState': device.device_registration_state.value if device.device_registration_state else None,
                        'IsEncrypted': device.is_encrypted,
                        'IsSupervised': device.is_supervised,
                        'JailBroken': device.jail_broken,
                        'AutopilotEnrolled': device.autopilot_enrolled,
                        'DeviceCategory': device.device_category_display_name,
                        'TotalStorageGB': round(device.total_storage_space_in_bytes / (1024**3), 2) if device.total_storage_space_in_bytes else None,
                        'FreeStorageGB': round(device.free_storage_space_in_bytes / (1024**3), 2) if device.free_storage_space_in_bytes else None,
                        'PhysicalMemoryGB': round(device.physical_memory_in_bytes / (1024**3), 2) if device.physical_memory_in_bytes else None,
                        'WiFiMacAddress': device.wi_fi_mac_address,
                        'EthernetMacAddress': device.ethernet_mac_address
                    }
                    devices.append(device_dict)
            
            # Handle pagination
            if result.odata_next_link:
                result = await retry_with_backoff(
                    graph_client.device_management.managed_devices.with_url(result.odata_next_link).get
                )
            else:
                break
                
    except Exception as e:
        logger.error(f"Error fetching managed devices: {e}")
        raise
    
    logger.info(f"Fetched {len(devices)} managed devices")
    return devices


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
    logger.info("=" * 60)
    logger.info("Starting Intune Device Export")
    logger.info("=" * 60)
    
    # Get backend setting (Log Analytics is primary)
    backend = get_automation_variable('ANALYTICS_BACKEND', 'LogAnalytics')
    logger.info(f"Analytics backend: {backend}")
    
    # Get Graph client
    graph_client = get_graph_client()
    
    # Fetch device data
    devices = await get_managed_devices(graph_client)
    
    # Add metadata
    devices = add_metadata(devices, 'IntuneDeviceExport')
    
    # Create sync state record
    sync_state = [{
        'SyncType': 'Devices',
        'RecordCount': len(devices),
        'Status': 'Success',
        'SyncTime': datetime.now(timezone.utc).isoformat()
    }]
    sync_state = add_metadata(sync_state, 'IntuneDeviceExport')
    
    data = {
        'ManagedDevices': devices,
        'SyncState': sync_state
    }
    
    # Ingest to chosen backend
    if backend.upper() == 'LOGANALYTICS':
        ingest_to_log_analytics(data)
    else:
        ingest_to_adx(data)
    
    logger.info("=" * 60)
    logger.info("Device export completed successfully")
    logger.info(f"Total devices exported: {len(devices)}")
    logger.info("=" * 60)


if __name__ == '__main__':
    asyncio.run(main())
