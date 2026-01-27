#!/usr/bin/env python3
"""
Intune Autopilot Export Runbook
Exports Windows Autopilot device and deployment profile data from Microsoft Graph

Schedule: Daily at 6 AM UTC
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
    'AutopilotDevices': 'Custom-IntuneAutopilotDevices_CL',
    'AutopilotProfiles': 'Custom-IntuneAutopilotProfiles_CL',
    'SyncState': 'Custom-IntuneSyncState_CL'
}

# Enrollment state mapping
ENROLLMENT_STATE_MAP = {
    0: 'unknown',
    1: 'enrolled', 
    2: 'pendingReset',
    3: 'failed',
    4: 'notContacted',
    5: 'blocked'
}

# Deployment profile assignment status mapping
ASSIGNMENT_STATUS_MAP = {
    0: 'unknown',
    1: 'assignedInSync',
    2: 'assignedOutOfSync',
    3: 'assignedUnknownSyncState',
    4: 'notAssigned',
    5: 'pending',
    6: 'failed'
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


async def get_autopilot_devices(graph) -> list:
    """Get all Windows Autopilot device identities"""
    devices = []
    result = await graph.device_management.windows_autopilot_device_identities.get()
    
    while result:
        for d in result.value or []:
            # Map enum values to readable strings
            enrollment_state = ENROLLMENT_STATE_MAP.get(
                d.enrollment_state.value if d.enrollment_state else 0, 
                'unknown'
            )
            assignment_status = ASSIGNMENT_STATUS_MAP.get(
                d.deployment_profile_assignment_status.value if d.deployment_profile_assignment_status else 0,
                'unknown'
            )
            
            devices.append({
                'AutopilotDeviceId': d.id,
                'SerialNumber': d.serial_number,
                'ProductKey': d.product_key,
                'Manufacturer': d.manufacturer,
                'Model': d.model,
                'GroupTag': d.group_tag,
                'PurchaseOrderIdentifier': d.purchase_order_identifier,
                'EnrollmentState': enrollment_state,
                'EnrollmentStateRaw': d.enrollment_state.value if d.enrollment_state else None,
                'DeploymentProfileAssignmentStatus': assignment_status,
                'DeploymentProfileAssignmentStatusRaw': d.deployment_profile_assignment_status.value if d.deployment_profile_assignment_status else None,
                'DeploymentProfileAssignedDateTime': d.deployment_profile_assigned_date_time.isoformat() if d.deployment_profile_assigned_date_time else None,
                'LastContactedDateTime': d.last_contacted_date_time.isoformat() if d.last_contacted_date_time else None,
                'AddressableUserName': d.addressable_user_name,
                'UserPrincipalName': d.user_principal_name,
                'ResourceName': d.resource_name,
                'SkuNumber': d.sku_number,
                'SystemFamily': d.system_family,
                'AzureActiveDirectoryDeviceId': d.azure_active_directory_device_id,
                'AzureAdDeviceId': d.azure_ad_device_id,
                'ManagedDeviceId': d.managed_device_id,
                'DisplayName': d.display_name,
                'DeviceAccountUpn': getattr(d, 'device_account_upn', None),
                'DeviceAccountPassword': None,  # Never export passwords
                'DeviceFriendlyName': getattr(d, 'device_friendly_name', None),
                'RemediationState': str(d.remediation_state) if hasattr(d, 'remediation_state') and d.remediation_state else None,
                'RemediationStateLastModifiedDateTime': d.remediation_state_last_modified_date_time.isoformat() if hasattr(d, 'remediation_state_last_modified_date_time') and d.remediation_state_last_modified_date_time else None,
            })
        
        if result.odata_next_link:
            result = await graph.device_management.windows_autopilot_device_identities.with_url(result.odata_next_link).get()
        else:
            break
    
    return devices


async def get_autopilot_profiles(graph) -> list:
    """Get Windows Autopilot deployment profiles"""
    profiles = []
    result = await graph.device_management.windows_autopilot_deployment_profiles.get()
    
    for p in result.value or []:
        profiles.append({
            'ProfileId': p.id,
            'DisplayName': p.display_name,
            'Description': p.description,
            'CreatedDateTime': p.created_date_time.isoformat() if p.created_date_time else None,
            'LastModifiedDateTime': p.last_modified_date_time.isoformat() if p.last_modified_date_time else None,
            'Language': p.language,
            'DeviceNameTemplate': p.device_name_template,
            'DeviceType': str(p.device_type) if p.device_type else None,
            'EnableWhiteGlove': getattr(p, 'enable_white_glove', None),
            'ExtractHardwareHash': p.extract_hardware_hash if hasattr(p, 'extract_hardware_hash') else None,
            'OutOfBoxExperienceSettings': json.dumps({
                'hidePrivacySettings': p.out_of_box_experience_settings.hide_privacy_settings if p.out_of_box_experience_settings else None,
                'hideEULA': p.out_of_box_experience_settings.hide_e_u_l_a if p.out_of_box_experience_settings else None,
                'userType': str(p.out_of_box_experience_settings.user_type) if p.out_of_box_experience_settings and p.out_of_box_experience_settings.user_type else None,
                'deviceUsageType': str(p.out_of_box_experience_settings.device_usage_type) if p.out_of_box_experience_settings and p.out_of_box_experience_settings.device_usage_type else None,
                'skipKeyboardSelectionPage': p.out_of_box_experience_settings.skip_keyboard_selection_page if p.out_of_box_experience_settings else None,
                'hideEscapeLink': p.out_of_box_experience_settings.hide_escape_link if p.out_of_box_experience_settings else None,
            }) if p.out_of_box_experience_settings else None,
            'ProfileType': type(p).__name__.replace('WindowsAutopilotDeploymentProfile', ''),
        })
    
    return profiles


async def main():
    """Main execution function"""
    start_time = datetime.now(timezone.utc)
    logger.info("=== Intune Autopilot Export Started ===")
    
    try:
        graph = get_graph_client()
        ingester = DataIngester()
        total_records = 0
        
        # Export Autopilot devices
        logger.info("Fetching Autopilot device identities...")
        devices = await get_autopilot_devices(graph)
        devices = add_metadata(devices, 'IntuneAutopilot')
        count = ingester.ingest('AutopilotDevices', devices)
        total_records += count
        logger.info(f"Exported {count} Autopilot devices")
        
        # Export Autopilot deployment profiles
        logger.info("Fetching Autopilot deployment profiles...")
        profiles = await get_autopilot_profiles(graph)
        profiles = add_metadata(profiles, 'IntuneAutopilot')
        count = ingester.ingest('AutopilotProfiles', profiles)
        total_records += count
        logger.info(f"Exported {count} Autopilot profiles")
        
        # Log sync state
        end_time = datetime.now(timezone.utc)
        duration = (end_time - start_time).total_seconds()
        sync_record = [{
            'ExportType': 'Autopilot',
            'RecordCount': total_records,
            'StartTime': start_time.isoformat(),
            'EndTime': end_time.isoformat(),
            'DurationSeconds': duration,
            'Status': 'Success',
            'ErrorMessage': None
        }]
        sync_record = add_metadata(sync_record, 'IntuneAutopilot')
        ingester.ingest('SyncState', sync_record)
        
        logger.info(f"=== Export completed in {duration:.1f}s ===")
        
    except Exception as e:
        logger.error(f"Export failed: {e}")
        raise


if __name__ == '__main__':
    asyncio.run(main())
