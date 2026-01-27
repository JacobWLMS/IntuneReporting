"""
Export Intune Endpoint Analytics Data
Schedule: Daily at 8 AM UTC
"""
import logging
import asyncio
import azure.functions as func

from shared import get_graph_client, add_metadata, DataIngester, retry_with_backoff

logger = logging.getLogger(__name__)


async def get_device_scores(graph_client) -> list:
    """Get device health scores."""
    logger.info("Fetching device health scores...")
    scores = []

    result = await retry_with_backoff(
        graph_client.device_management.user_experience_analytics_device_scores.get
    )

    while result:
        for d in result.value or []:
            scores.append({
                'DeviceId': d.device_name,
                'DeviceName': d.device_name,
                'Model': d.model,
                'Manufacturer': d.manufacturer,
                'HealthStatus': str(d.health_status) if d.health_status else None,
                'EndpointAnalyticsScore': d.endpoint_analytics_score,
                'StartupPerformanceScore': d.startup_performance_score,
                'AppReliabilityScore': d.app_reliability_score,
                'WorkFromAnywhereScore': d.work_from_anywhere_score,
                'MeanResourceSpikeTimeScore': d.mean_resource_spike_time_score,
                'BatteryHealthScore': getattr(d, 'battery_health_score', None),
            })

        if result.odata_next_link:
            result = await retry_with_backoff(
                graph_client.device_management.user_experience_analytics_device_scores.with_url(result.odata_next_link).get
            )
        else:
            break

    logger.info(f"Fetched {len(scores)} device scores")
    return scores


async def get_startup_performance(graph_client) -> list:
    """Get device startup performance metrics."""
    logger.info("Fetching startup performance data...")
    records = []

    result = await retry_with_backoff(
        graph_client.device_management.user_experience_analytics_device_startup_history.get
    )

    while result:
        for s in result.value or []:
            records.append({
                'DeviceId': s.device_id,
                'StartTime': s.start_time.isoformat() if s.start_time else None,
                'CoreBootTimeInMs': s.core_boot_time_in_ms,
                'GroupPolicyBootTimeInMs': s.group_policy_boot_time_in_ms,
                'GroupPolicyLoginTimeInMs': s.group_policy_login_time_in_ms,
                'CoreLoginTimeInMs': s.core_login_time_in_ms,
                'TotalBootTimeInMs': s.total_boot_time_in_ms,
                'TotalLoginTimeInMs': s.total_login_time_in_ms,
                'IsFirstLogin': s.is_first_login,
                'IsFeatureUpdate': s.is_feature_update,
                'OperatingSystemVersion': s.operating_system_version,
                'RestartCategory': str(s.restart_category) if s.restart_category else None,
                'RestartFaultBucket': s.restart_fault_bucket,
            })

        if result.odata_next_link:
            result = await retry_with_backoff(
                graph_client.device_management.user_experience_analytics_device_startup_history.with_url(result.odata_next_link).get
            )
        else:
            break

    logger.info(f"Fetched {len(records)} startup performance records")
    return records


async def get_app_reliability(graph_client) -> list:
    """Get app reliability data."""
    logger.info("Fetching app reliability data...")
    records = []

    try:
        result = await retry_with_backoff(
            graph_client.device_management.user_experience_analytics_app_health_application_performance.get
        )

        while result:
            for a in result.value or []:
                records.append({
                    'AppName': a.app_name,
                    'AppDisplayName': a.app_display_name,
                    'AppPublisher': a.app_publisher,
                    'ActiveDeviceCount': a.active_device_count,
                    'AppCrashCount': a.app_crash_count,
                    'AppHangCount': a.app_hang_count,
                    'MeanTimeToFailureInMinutes': a.mean_time_to_failure_in_minutes,
                    'AppHealthScore': getattr(a, 'app_health_score', None),
                    'AppHealthStatus': getattr(a, 'app_health_status', None),
                })

            if result.odata_next_link:
                result = await retry_with_backoff(
                    graph_client.device_management.user_experience_analytics_app_health_application_performance.with_url(result.odata_next_link).get
                )
            else:
                break
    except Exception as e:
        logger.warning(f"Could not fetch app reliability data: {e}")

    logger.info(f"Fetched {len(records)} app reliability records")
    return records


async def run():
    """Main export logic."""
    logger.info("Starting Endpoint Analytics Export")

    graph_client = get_graph_client()
    ingester = DataIngester()
    total = 0

    # Device scores
    scores = await get_device_scores(graph_client)
    scores = add_metadata(scores, 'EndpointAnalytics')
    total += ingester.ingest('DeviceScores', scores)

    # Startup performance
    startup = await get_startup_performance(graph_client)
    startup = add_metadata(startup, 'EndpointAnalytics')
    total += ingester.ingest('StartupPerformance', startup)

    # App reliability
    apps = await get_app_reliability(graph_client)
    apps = add_metadata(apps, 'EndpointAnalytics')
    total += ingester.ingest('AppReliability', apps)

    logger.info(f"Export completed: {total} total records")
    return total


def main(timer: func.TimerRequest) -> None:
    """Azure Function entry point."""
    if timer.past_due:
        logger.warning("Timer is past due")

    asyncio.run(run())
