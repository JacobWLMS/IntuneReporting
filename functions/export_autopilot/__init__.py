"""
Export Intune Autopilot Devices and Profiles
Schedule: Daily at 6 AM UTC
"""
import json
import logging
import asyncio
import azure.functions as func

from shared import get_graph_client, add_metadata, DataIngester

logger = logging.getLogger(__name__)

ENROLLMENT_STATE_MAP = {
    0: 'unknown', 1: 'enrolled', 2: 'pendingReset',
    3: 'failed', 4: 'notContacted', 5: 'blocked'
}

ASSIGNMENT_STATUS_MAP = {
    0: 'unknown', 1: 'assignedInSync', 2: 'assignedOutOfSync',
    3: 'assignedUnknownSyncState', 4: 'notAssigned', 5: 'pending', 6: 'failed'
}


async def get_autopilot_devices(graph_client) -> list:
    """Get Windows Autopilot device identities."""
    devices = []
    result = await graph_client.device_management.windows_autopilot_device_identities.get()

    while result:
        for d in result.value or []:
            enrollment_state = ENROLLMENT_STATE_MAP.get(
                d.enrollment_state.value if d.enrollment_state else 0, 'unknown'
            )
            assignment_status = ASSIGNMENT_STATUS_MAP.get(
                d.deployment_profile_assignment_status.value if d.deployment_profile_assignment_status else 0, 'unknown'
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
                'DeploymentProfileAssignmentStatus': assignment_status,
                'DeploymentProfileAssignedDateTime': d.deployment_profile_assigned_date_time.isoformat() if d.deployment_profile_assigned_date_time else None,
                'LastContactedDateTime': d.last_contacted_date_time.isoformat() if d.last_contacted_date_time else None,
                'AddressableUserName': d.addressable_user_name,
                'UserPrincipalName': d.user_principal_name,
                'ResourceName': d.resource_name,
                'AzureActiveDirectoryDeviceId': d.azure_active_directory_device_id,
                'ManagedDeviceId': d.managed_device_id,
                'DisplayName': d.display_name,
            })

        if result.odata_next_link:
            result = await graph_client.device_management.windows_autopilot_device_identities.with_url(result.odata_next_link).get()
        else:
            break

    return devices


async def get_autopilot_profiles(graph_client) -> list:
    """Get Autopilot deployment profiles."""
    profiles = []
    result = await graph_client.device_management.windows_autopilot_deployment_profiles.get()

    for p in result.value or []:
        oobe = None
        if p.out_of_box_experience_settings:
            oobe = json.dumps({
                'hidePrivacySettings': p.out_of_box_experience_settings.hide_privacy_settings,
                'hideEULA': p.out_of_box_experience_settings.hide_e_u_l_a,
                'userType': str(p.out_of_box_experience_settings.user_type) if p.out_of_box_experience_settings.user_type else None,
                'deviceUsageType': str(p.out_of_box_experience_settings.device_usage_type) if p.out_of_box_experience_settings.device_usage_type else None,
                'skipKeyboardSelectionPage': p.out_of_box_experience_settings.skip_keyboard_selection_page,
                'hideEscapeLink': p.out_of_box_experience_settings.hide_escape_link,
            })

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
            'ExtractHardwareHash': getattr(p, 'extract_hardware_hash', None),
            'OutOfBoxExperienceSettings': oobe,
            'ProfileType': type(p).__name__.replace('WindowsAutopilotDeploymentProfile', ''),
        })

    return profiles


async def run():
    """Main export logic."""
    logger.info("Starting Autopilot Export")

    graph_client = get_graph_client()
    ingester = DataIngester()
    total = 0

    # Autopilot devices
    devices = await get_autopilot_devices(graph_client)
    devices = add_metadata(devices, 'IntuneAutopilot')
    total += ingester.ingest('AutopilotDevices', devices)

    # Autopilot profiles
    profiles = await get_autopilot_profiles(graph_client)
    profiles = add_metadata(profiles, 'IntuneAutopilot')
    total += ingester.ingest('AutopilotProfiles', profiles)

    logger.info(f"Export completed: {total} total records")
    return total


def main(timer: func.TimerRequest) -> None:
    """Azure Function entry point."""
    if timer.past_due:
        logger.warning("Timer is past due")

    asyncio.run(run())
