"""
Export Intune Managed Devices
Schedule: Every 4 hours
"""
import logging
import asyncio
import azure.functions as func

from shared import get_graph_client, add_metadata, DataIngester, retry_with_backoff

logger = logging.getLogger(__name__)


async def get_managed_devices(graph_client) -> list:
    """Fetch all managed devices with pagination."""
    logger.info("Fetching managed devices...")
    devices = []

    # Initial request with retry
    result = await retry_with_backoff(
        graph_client.device_management.managed_devices.get
    )

    while result:
        for device in result.value or []:
            devices.append({
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
                'EthernetMacAddress': device.ethernet_mac_address,
            })

        # Handle pagination with retry
        if result.odata_next_link:
            result = await retry_with_backoff(
                graph_client.device_management.managed_devices.with_url(result.odata_next_link).get
            )
        else:
            break

    logger.info(f"Fetched {len(devices)} devices")
    return devices


async def run():
    """Main export logic."""
    logger.info("Starting Intune Device Export")

    graph_client = get_graph_client()
    ingester = DataIngester()

    # Fetch and ingest devices
    devices = await get_managed_devices(graph_client)
    devices = add_metadata(devices, 'IntuneDeviceExport')
    count = ingester.ingest('ManagedDevices', devices)

    logger.info(f"Export completed: {count} devices")
    return count


def main(timer: func.TimerRequest) -> None:
    """Azure Function entry point."""
    if timer.past_due:
        logger.warning("Timer is past due")

    asyncio.run(run())
