"""
Export Intune Managed Devices
Schedule: Every 4 hours
"""
import json
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
            # Resolve most-recent logged-on user from the array
            users_logged_on = device.users_logged_on or []
            last_logon_user_id = None
            last_logon_dt = None
            if users_logged_on:
                sorted_users = sorted(
                    [u for u in users_logged_on if u.last_log_on_date_time],
                    key=lambda u: u.last_log_on_date_time,
                    reverse=True,
                )
                if sorted_users:
                    last_logon_user_id = sorted_users[0].user_id
                    last_logon_dt = sorted_users[0].last_log_on_date_time.isoformat()

            devices.append({
                # --- Identity ---
                'DeviceId': device.id,
                'DeviceName': device.device_name,
                'ManagedDeviceName': device.managed_device_name,
                'AzureADDeviceId': device.azure_a_d_device_id,
                'SerialNumber': device.serial_number,
                'IMEI': device.imei,

                # --- Primary user ---
                'UserPrincipalName': device.user_principal_name,
                'UserDisplayName': device.user_display_name,
                'EmailAddress': device.email_address,

                # --- Last logged-on user (key for stale detection) ---
                'LastLoggedOnUserId': last_logon_user_id,
                'LastLoggedOnDateTime': last_logon_dt,
                'UsersLoggedOnCount': len(users_logged_on),
                'UsersLoggedOnJson': json.dumps([
                    {
                        'userId': u.user_id,
                        'lastLogOnDateTime': u.last_log_on_date_time.isoformat() if u.last_log_on_date_time else None,
                    }
                    for u in users_logged_on
                ]) if users_logged_on else None,

                # --- OS & hardware ---
                'OperatingSystem': device.operating_system,
                'OSVersion': device.os_version,
                'Manufacturer': device.manufacturer,
                'Model': device.model,
                'ChassisType': device.chassis_type.value if device.chassis_type else None,
                'ProcessorArchitecture': device.processor_architecture.value if device.processor_architecture else None,
                'SkuFamily': device.sku_family,
                'TotalStorageGB': round(device.total_storage_space_in_bytes / (1024**3), 2) if device.total_storage_space_in_bytes else None,
                'FreeStorageGB': round(device.free_storage_space_in_bytes / (1024**3), 2) if device.free_storage_space_in_bytes else None,
                'PhysicalMemoryGB': round(device.physical_memory_in_bytes / (1024**3), 2) if device.physical_memory_in_bytes else None,
                'WiFiMacAddress': device.wi_fi_mac_address,
                'EthernetMacAddress': device.ethernet_mac_address,

                # --- Enrollment & management ---
                'EnrolledDateTime': device.enrolled_date_time.isoformat() if device.enrolled_date_time else None,
                'LastSyncDateTime': device.last_sync_date_time.isoformat() if device.last_sync_date_time else None,
                'ManagementState': device.management_state.value if device.management_state else None,
                'ManagementAgent': device.management_agent.value if device.management_agent else None,
                'ManagementFeatures': device.management_features.value if device.management_features else None,
                'ManagementCertificateExpirationDate': device.management_certificate_expiration_date.isoformat() if device.management_certificate_expiration_date else None,
                'RetireAfterDateTime': device.retire_after_date_time.isoformat() if device.retire_after_date_time else None,
                'OwnerType': device.owner_type.value if device.owner_type else None,
                'DeviceEnrollmentType': device.device_enrollment_type.value if device.device_enrollment_type else None,
                'EnrollmentProfileName': device.enrollment_profile_name,
                'AutopilotEnrolled': str(device.autopilot_enrolled).lower() if device.autopilot_enrolled is not None else None,
                'JoinType': device.join_type.value if device.join_type else None,

                # --- Registration & compliance ---
                'AzureADRegistered': str(device.azure_a_d_registered).lower() if device.azure_a_d_registered is not None else None,
                'DeviceRegistrationState': device.device_registration_state.value if device.device_registration_state else None,
                'ComplianceState': device.compliance_state.value if device.compliance_state else None,
                'DeviceCategory': device.device_category_display_name,

                # --- Security ---
                'IsEncrypted': str(device.is_encrypted).lower() if device.is_encrypted is not None else None,
                'IsSupervised': str(device.is_supervised).lower() if device.is_supervised is not None else None,
                'JailBroken': device.jail_broken,
                'LostModeState': device.lost_mode_state.value if device.lost_mode_state else None,
                'PartnerReportedThreatState': device.partner_reported_threat_state.value if device.partner_reported_threat_state else None,
                'WindowsActiveMalwareCount': device.windows_active_malware_count,
                'WindowsRemediatedMalwareCount': device.windows_remediated_malware_count,

                # --- Notes ---
                'Notes': device.notes,
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
