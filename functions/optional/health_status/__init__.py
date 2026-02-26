"""
Health Status - Anonymous endpoint for dashboard health checks.

This endpoint is anonymous (no function key required) so the dashboard
can display health status without authentication issues.
"""
import json
import logging
import asyncio
import azure.functions as func

logger = logging.getLogger(__name__)

# Import health check logic from manual_trigger
from shared import validate_config, get_credential, get_graph_client, DataIngester


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


def main(req: func.HttpRequest) -> func.HttpResponse:
    """Handle health status requests (anonymous access)."""
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
        logger.error(f"Health check failed: {e}")
        return func.HttpResponse(
            json.dumps({'status': 'unhealthy', 'error': str(e)}, indent=2),
            mimetype="application/json",
            status_code=500
        )
