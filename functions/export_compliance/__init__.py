"""
Export Intune Compliance Policies and Device States
Schedule: Every 6 hours
"""
import logging
import asyncio
import json
import azure.functions as func

from shared import get_graph_client, add_metadata, DataIngester, retry_with_backoff
from msgraph_beta.generated.device_management.reports.get_device_status_by_compliace_policy_report.get_device_status_by_compliace_policy_report_post_request_body import GetDeviceStatusByCompliacePolicyReportPostRequestBody

logger = logging.getLogger(__name__)

STATUS_MAP = {
    1: 'unknown', 2: 'compliant', 3: 'inGracePeriod',
    4: 'noncompliant', 5: 'error', 6: 'conflict', 7: 'notApplicable'
}


async def get_compliance_policies(graph_client) -> list:
    """Get all compliance policy definitions."""
    logger.info("Fetching compliance policies...")
    policies = []
    result = await retry_with_backoff(
        graph_client.device_management.device_compliance_policies.get
    )

    for policy in result.value or []:
        policies.append({
            'PolicyId': policy.id,
            'PolicyName': policy.display_name,
            'Description': policy.description,
            'CreatedDateTime': policy.created_date_time.isoformat() if policy.created_date_time else None,
            'LastModifiedDateTime': policy.last_modified_date_time.isoformat() if policy.last_modified_date_time else None,
            'PolicyType': type(policy).__name__.replace('CompliancePolicy', ''),
        })

    logger.info(f"Fetched {len(policies)} compliance policies")
    return policies


def parse_report_response(response) -> tuple:
    """Parse Graph Reports API response (handles both object and bytes responses)."""
    if not response:
        return [], 0
    
    # Handle bytes response (newer SDK versions return raw JSON)
    if isinstance(response, bytes):
        try:
            data = json.loads(response.decode('utf-8'))
            # Schema can be list of strings or list of dicts with 'name' key
            schema = data.get('Schema', [])
            columns = []
            for col in schema:
                if isinstance(col, dict):
                    columns.append(col.get('name', col.get('Name', str(col))))
                else:
                    columns.append(str(col))
            
            rows = [dict(zip(columns, row)) for row in data.get('Values', [])]
            total = data.get('TotalRowCount', len(rows))
            logger.info(f"Parsed report: {len(rows)} rows, columns: {columns[:5]}...")
            return rows, total
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            logger.error(f"Failed to parse bytes response: {e}")
            return [], 0
    
    # Handle object response (older SDK versions)
    if not hasattr(response, 'values') or not response.values:
        return [], 0
    columns = [c.name for c in response.schema] if response.schema else []
    rows = [dict(zip(columns, row)) for row in response.values]
    total = response.total_row_count or len(rows)
    return rows, total


async def get_compliance_states(graph_client, policy_id: str, policy_name: str) -> list:
    """Get per-device compliance states for a policy."""
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
            graph_client.device_management.reports.get_device_status_by_compliace_policy_report.post,
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
            })

        skip += len(rows)
        if skip >= total or len(rows) == 0:
            break

    return states


async def run():
    """Main export logic."""
    logger.info("Starting Intune Compliance Export")

    graph_client = get_graph_client()
    ingester = DataIngester()

    # Fetch policies
    policies = await get_compliance_policies(graph_client)
    policies = add_metadata(policies, 'IntuneComplianceExport')
    ingester.ingest('CompliancePolicies', policies)

    # Fetch compliance states for each policy
    all_states = []
    for policy in policies:
        logger.info(f"Fetching states for: {policy['PolicyName']}")
        states = await get_compliance_states(graph_client, policy['PolicyId'], policy['PolicyName'])
        all_states.extend(states)

    all_states = add_metadata(all_states, 'IntuneComplianceExport')
    count = ingester.ingest('DeviceComplianceStates', all_states)

    logger.info(f"Export completed: {len(policies)} policies, {count} states")
    return count


def main(timer: func.TimerRequest) -> None:
    """Azure Function entry point."""
    if timer.past_due:
        logger.warning("Timer is past due")

    asyncio.run(run())
