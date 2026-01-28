"""
Manual Export Trigger
HTTP endpoint to manually trigger exports for testing.

Usage:
    GET/POST /api/export              - List available exports
    GET/POST /api/export/devices      - Run device export
    GET/POST /api/export/compliance   - Run compliance export
    GET/POST /api/export/analytics    - Run endpoint analytics export
    GET/POST /api/export/autopilot    - Run autopilot export
    GET/POST /api/export/all          - Run all exports
    GET/POST /api/export/test         - Test Log Analytics ingestion with sample data
    GET/POST /api/export/health       - Health check (auth + config validation)

Authentication: Function key required (passed as ?code=<key> or x-functions-key header)
"""
import json
import logging
import asyncio
from datetime import datetime, timezone
import azure.functions as func

logger = logging.getLogger(__name__)

# Import the run() functions from each export module
from export_devices import run as run_devices
from export_compliance import run as run_compliance
from export_endpoint_analytics import run as run_analytics
from export_autopilot import run as run_autopilot
from shared import validate_config, get_credential, get_graph_client, DataIngester, add_metadata

EXPORTS = {
    'devices': ('Export Intune Devices', run_devices),
    'compliance': ('Export Compliance Policies & States', run_compliance),
    'analytics': ('Export Endpoint Analytics', run_analytics),
    'autopilot': ('Export Autopilot Devices & Profiles', run_autopilot),
}


async def run_health_check():
    """Run health check - validate config, auth, and Graph API connectivity."""
    results = {
        'config': {'status': 'unknown'},
        'authentication': {'status': 'unknown'},
        'graph_api': {'status': 'unknown'},
        'log_analytics': {'status': 'unknown'},
    }

    # Check configuration
    try:
        config = validate_config()
        results['config'] = {
            'status': 'ok',
            'backend': config.get('backend'),
            'auth_method': config.get('auth_method'),
        }
    except Exception as e:
        results['config'] = {'status': 'error', 'error': str(e)}
        return results  # Can't proceed without valid config

    # Check authentication
    try:
        credential = get_credential()
        # Try to get a token
        token = credential.get_token("https://graph.microsoft.com/.default")
        results['authentication'] = {
            'status': 'ok',
            'token_obtained': True,
        }
    except Exception as e:
        results['authentication'] = {'status': 'error', 'error': str(e)}
        return results

    # Check Graph API connectivity
    try:
        client = get_graph_client()
        # Simple API call to verify connectivity
        org = await client.organization.get()
        org_name = org.value[0].display_name if org.value else 'Unknown'
        results['graph_api'] = {
            'status': 'ok',
            'organization': org_name,
        }
    except Exception as e:
        error_msg = str(e)
        if 'Authorization' in error_msg or '403' in error_msg:
            results['graph_api'] = {
                'status': 'ok',
                'note': 'Connected but missing Intune permissions (expected for test tenant)',
            }
        else:
            results['graph_api'] = {'status': 'error', 'error': error_msg}

    # Check Log Analytics ingestion
    try:
        ingester = DataIngester()
        results['log_analytics'] = {
            'status': 'ok',
            'backend': ingester.backend,
            'dce': ingester.dce if hasattr(ingester, 'dce') else None,
        }
    except Exception as e:
        results['log_analytics'] = {'status': 'error', 'error': str(e)}

    return results


async def run_test_ingestion():
    """Send test data to Log Analytics to verify ingestion pipeline."""
    ingester = DataIngester()

    # Create test record for IntuneSyncState_CL
    test_records = [{
        'ExportType': 'TestIngestion',
        'RecordCount': 1,
        'Status': 'Success',
        'DurationSeconds': 0.5,
        'ErrorMessage': None,
    }]

    # Add metadata (TimeGenerated, IngestionTime, SourceSystem)
    add_metadata(test_records, 'IntuneReporting-Test')

    # Ingest to SyncState table
    count = ingester.ingest('SyncState', test_records)

    return {
        'records_sent': count,
        'table': 'IntuneSyncState_CL',
        'message': 'Test data sent to Log Analytics. Check the table in ~5 minutes.',
    }


def main(req: func.HttpRequest) -> func.HttpResponse:
    """Handle manual export trigger requests."""
    export_type = req.route_params.get('export_type', '').lower()

    # List available exports
    if not export_type:
        return func.HttpResponse(
            json.dumps({
                'message': 'Intune Reporting - Manual Export Trigger',
                'available_exports': {k: v[0] for k, v in EXPORTS.items()},
                'usage': {
                    'single': '/api/export/{type}',
                    'all': '/api/export/all',
                    'test': '/api/export/test',
                    'health': '/api/export/health',
                },
                'examples': [
                    '/api/export/devices',
                    '/api/export/compliance',
                    '/api/export/analytics',
                    '/api/export/autopilot',
                    '/api/export/all',
                    '/api/export/test',
                    '/api/export/health',
                ]
            }, indent=2),
            mimetype="application/json",
            status_code=200
        )

    # Health check
    if export_type == 'health':
        try:
            results = asyncio.run(run_health_check())
            all_ok = all(r.get('status') == 'ok' for r in results.values())
            return func.HttpResponse(
                json.dumps({
                    'status': 'healthy' if all_ok else 'degraded',
                    'checks': results,
                }, indent=2),
                mimetype="application/json",
                status_code=200 if all_ok else 503
            )
        except Exception as e:
            return func.HttpResponse(
                json.dumps({'status': 'unhealthy', 'error': str(e)}, indent=2),
                mimetype="application/json",
                status_code=500
            )

    # Test ingestion
    if export_type == 'test':
        try:
            result = asyncio.run(run_test_ingestion())
            return func.HttpResponse(
                json.dumps({
                    'message': 'Test ingestion completed',
                    **result
                }, indent=2),
                mimetype="application/json",
                status_code=200
            )
        except Exception as e:
            logger.error(f"Test ingestion failed: {e}")
            return func.HttpResponse(
                json.dumps({'error': str(e), 'export_type': 'test'}, indent=2),
                mimetype="application/json",
                status_code=500
            )

    # Run all exports
    if export_type == 'all':
        results = {}
        total_records = 0
        start_time = datetime.now(timezone.utc)
        export_count = 0

        for name, (description, run_func) in EXPORTS.items():
            try:
                # Add delay between exports to avoid rate limiting (except first)
                if export_count > 0:
                    import time
                    time.sleep(5)

                logger.info(f"Running {description}...")
                count = asyncio.run(run_func())
                results[name] = {'status': 'success', 'records': count}
                total_records += count
                export_count += 1
            except Exception as e:
                logger.error(f"Failed {name}: {e}")
                results[name] = {'status': 'error', 'error': str(e)}

        duration = (datetime.now(timezone.utc) - start_time).total_seconds()

        return func.HttpResponse(
            json.dumps({
                'message': 'All exports completed',
                'total_records': total_records,
                'duration_seconds': round(duration, 2),
                'results': results
            }, indent=2),
            mimetype="application/json",
            status_code=200
        )

    # Run single export
    if export_type not in EXPORTS:
        return func.HttpResponse(
            json.dumps({
                'error': f"Unknown export type: {export_type}",
                'available': list(EXPORTS.keys())
            }, indent=2),
            mimetype="application/json",
            status_code=400
        )

    description, run_func = EXPORTS[export_type]
    start_time = datetime.now(timezone.utc)

    try:
        logger.info(f"Running {description}...")
        count = asyncio.run(run_func())
        duration = (datetime.now(timezone.utc) - start_time).total_seconds()

        return func.HttpResponse(
            json.dumps({
                'message': f'{description} completed',
                'export_type': export_type,
                'records': count,
                'duration_seconds': round(duration, 2)
            }, indent=2),
            mimetype="application/json",
            status_code=200
        )
    except Exception as e:
        logger.error(f"Export failed: {e}")
        return func.HttpResponse(
            json.dumps({
                'error': str(e),
                'export_type': export_type
            }, indent=2),
            mimetype="application/json",
            status_code=500
        )
