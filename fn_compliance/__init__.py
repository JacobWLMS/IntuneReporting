"""
Compliance Export Function
Runs every 6 hours - exports device compliance states

This is the CORE actionable data:
- Which devices are non-compliant?
- Why are they non-compliant?
- When did they become non-compliant?
"""
import logging
import asyncio
import azure.functions as func
from datetime import datetime, timezone

from shared import (
    Config, get_ingestion_client, get_graph_client, add_metadata,
    parse_report_response, retry_with_backoff
)
from msgraph_beta.generated.device_management.reports.get_device_status_by_compliace_policy_report.get_device_status_by_compliace_policy_report_post_request_body import GetDeviceStatusByCompliacePolicyReportPostRequestBody


STATUS_MAP = {
    1: 'unknown', 2: 'compliant', 3: 'inGracePeriod', 
    4: 'noncompliant', 5: 'error', 6: 'conflict', 7: 'notApplicable'
}


async def get_managed_devices(graph) -> list[dict]:
    """Get all managed devices with compliance-relevant fields"""
    devices = []
    result = await graph.device_management.managed_devices.get()
    
    while result:
        for d in result.value or []:
            devices.append({
                'DeviceId': d.id,
                'DeviceName': d.device_name,
                'UserId': d.user_id,
                'UserPrincipalName': d.user_principal_name,
                'UserDisplayName': d.user_display_name,
                'OperatingSystem': d.operating_system,
                'OSVersion': d.os_version,
                'ComplianceState': str(d.compliance_state) if d.compliance_state else None,
                'ManagementAgent': str(d.management_agent) if d.management_agent else None,
                'EnrolledDateTime': d.enrolled_date_time.isoformat() if d.enrolled_date_time else None,
                'LastSyncDateTime': d.last_sync_date_time.isoformat() if d.last_sync_date_time else None,
                'Model': d.model,
                'Manufacturer': d.manufacturer,
                'SerialNumber': d.serial_number,
                'IsEncrypted': d.is_encrypted,
                'IsSupervised': d.is_supervised,
                'AzureADDeviceId': d.azure_a_d_device_id,
            })
        
        if result.odata_next_link:
            result = await graph.device_management.managed_devices.with_url(result.odata_next_link).get()
        else:
            break
    
    return devices


async def get_compliance_policies(graph) -> list[dict]:
    """Get compliance policy metadata"""
    policies = []
    result = await graph.device_management.device_compliance_policies.get()
    
    for p in result.value or []:
        policies.append({
            'PolicyId': p.id,
            'PolicyName': p.display_name,
            'Description': p.description,
            'CreatedDateTime': p.created_date_time.isoformat() if p.created_date_time else None,
            'LastModifiedDateTime': p.last_modified_date_time.isoformat() if p.last_modified_date_time else None,
            'PolicyType': type(p).__name__.replace('CompliancePolicy', ''),
        })
    
    return policies


async def get_compliance_states(graph, policy_id: str) -> list[dict]:
    """Get per-device compliance states for a specific policy"""
    states = []
    skip = 0
    
    while True:
        body = GetDeviceStatusByCompliacePolicyReportPostRequestBody()
        body.filter = f"(PolicyId eq '{policy_id}')"
        body.select = []
        body.skip = skip
        body.top = 1000
        body.order_by = []
        
        response = await retry_with_backoff(
            graph.device_management.reports.get_device_status_by_compliace_policy_report.post, 
            body
        )
        
        rows, total = parse_report_response(response)
        
        for row in rows:
            states.append({
                'DeviceId': row.get('DeviceId'),
                'DeviceName': row.get('DeviceName'),
                'UserId': row.get('UserId'),
                'UserPrincipalName': row.get('UPN'),
                'PolicyId': row.get('PolicyId'),
                'PolicyName': row.get('PolicyName'),
                'Status': STATUS_MAP.get(row.get('Status'), 'unknown'),
                'StatusRaw': row.get('Status'),
                'SettingCount': row.get('SettingCount'),
                'FailedSettingCount': row.get('FailedSettingCount'),
                'LastContact': row.get('LastContact'),
                'InGracePeriodCount': row.get('InGracePeriodCount'),
            })
        
        skip += len(rows)
        if len(rows) < 1000 or skip >= total:
            break
    
    return states


async def run_export():
    """Main export logic"""
    config = Config.from_env()
    graph = get_graph_client()
    client = get_ingestion_client(config)
    
    results = {}
    
    # 1. Export managed devices
    logging.info("Fetching managed devices...")
    devices = await get_managed_devices(graph)
    devices = add_metadata(devices, 'GraphAPI')
    results['devices'] = client.ingest('ManagedDevices', devices)
    logging.info(f"Ingested {results['devices']} devices")
    
    # 2. Export compliance policies (metadata)
    logging.info("Fetching compliance policies...")
    policies = await get_compliance_policies(graph)
    policies = add_metadata(policies, 'GraphAPI')
    results['policies'] = client.ingest('CompliancePolicies', policies)
    logging.info(f"Ingested {results['policies']} policies")
    
    # 3. Export compliance states per policy (THE ACTIONABLE DATA)
    logging.info("Fetching compliance states per policy...")
    all_states = []
    
    for p in policies:
        logging.info(f"  → {p['PolicyName']}")
        states = await get_compliance_states(graph, p['PolicyId'])
        all_states.extend(states)
    
    all_states = add_metadata(all_states, 'GraphAPI')
    results['states'] = client.ingest('DeviceComplianceStates', all_states)
    logging.info(f"Ingested {results['states']} compliance states")
    
    return results


def main(timer: func.TimerRequest) -> None:
    """Timer trigger entry point"""
    logging.info(f"Compliance export started at {datetime.now(timezone.utc)}")
    
    if timer.past_due:
        logging.warning("Timer is past due, running anyway")
    
    results = asyncio.run(run_export())
    
    logging.info(f"Compliance export complete: {results}")
