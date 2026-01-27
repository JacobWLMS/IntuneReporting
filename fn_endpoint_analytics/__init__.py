"""
Endpoint Analytics Export Function
Runs daily at 8 AM - exports device health and performance data

This is ACTIONABLE performance data:
- Which devices have poor startup times?
- Which devices have low health scores?
- Which apps are causing reliability issues?
"""
import logging
import asyncio
import azure.functions as func
from datetime import datetime, timezone

from shared import Config, get_ingestion_client, get_graph_client, add_metadata


async def get_device_scores(graph) -> list[dict]:
    """Get device health scores - the core Endpoint Analytics metric"""
    scores = []
    result = await graph.device_management.user_experience_analytics_device_scores.get()
    
    while result:
        for d in result.value or []:
            scores.append({
                'DeviceId': d.device_name,  # Note: this is actually the Intune device ID
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
            result = await graph.device_management.user_experience_analytics_device_scores.with_url(result.odata_next_link).get()
        else:
            break
    
    return scores


async def get_startup_performance(graph) -> list[dict]:
    """Get device startup performance metrics"""
    records = []
    result = await graph.device_management.user_experience_analytics_device_startup_history.get()
    
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
            result = await graph.device_management.user_experience_analytics_device_startup_history.with_url(result.odata_next_link).get()
        else:
            break
    
    return records


async def get_app_reliability(graph) -> list[dict]:
    """Get app reliability data - which apps are crashing?"""
    records = []
    
    try:
        result = await graph.device_management.user_experience_analytics_app_health_application_performance.get()
        
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
                result = await graph.device_management.user_experience_analytics_app_health_application_performance.with_url(result.odata_next_link).get()
            else:
                break
    except Exception as e:
        logging.warning(f"App reliability not available: {e}")
    
    return records


async def run_export():
    """Main export logic"""
    config = Config.from_env()
    graph = get_graph_client()
    client = get_ingestion_client(config)
    
    results = {}
    
    # 1. Device health scores (PRIMARY METRIC)
    logging.info("Fetching device health scores...")
    scores = await get_device_scores(graph)
    scores = add_metadata(scores, 'EndpointAnalytics')
    results['scores'] = client.ingest('DeviceScores', scores)
    logging.info(f"Ingested {results['scores']} device scores")
    
    # 2. Startup performance history
    logging.info("Fetching startup performance...")
    startup = await get_startup_performance(graph)
    startup = add_metadata(startup, 'EndpointAnalytics')
    results['startup'] = client.ingest('StartupPerformance', startup)
    logging.info(f"Ingested {results['startup']} startup records")
    
    # 3. App reliability (which apps are causing issues)
    logging.info("Fetching app reliability...")
    apps = await get_app_reliability(graph)
    apps = add_metadata(apps, 'EndpointAnalytics')
    results['apps'] = client.ingest('AppReliability', apps)
    logging.info(f"Ingested {results['apps']} app reliability records")
    
    return results


def main(timer: func.TimerRequest) -> None:
    """Timer trigger entry point"""
    logging.info(f"Endpoint Analytics export started at {datetime.now(timezone.utc)}")
    
    if timer.past_due:
        logging.warning("Timer is past due, running anyway")
    
    results = asyncio.run(run_export())
    
    logging.info(f"Endpoint Analytics export complete: {results}")
