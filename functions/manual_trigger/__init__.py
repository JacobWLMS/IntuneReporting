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

EXPORTS = {
    'devices': ('Export Intune Devices', run_devices),
    'compliance': ('Export Compliance Policies & States', run_compliance),
    'analytics': ('Export Endpoint Analytics', run_analytics),
    'autopilot': ('Export Autopilot Devices & Profiles', run_autopilot),
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
                },
                'examples': [
                    '/api/export/devices',
                    '/api/export/compliance',
                    '/api/export/analytics',
                    '/api/export/autopilot',
                    '/api/export/all',
                ]
            }, indent=2),
            mimetype="application/json",
            status_code=200
        )

    # Run all exports
    if export_type == 'all':
        results = {}
        total_records = 0
        start_time = datetime.now(timezone.utc)

        for name, (description, run_func) in EXPORTS.items():
            try:
                logger.info(f"Running {description}...")
                count = asyncio.run(run_func())
                results[name] = {'status': 'success', 'records': count}
                total_records += count
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
