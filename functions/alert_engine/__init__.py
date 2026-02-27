"""
Alert Engine - Config-driven alerting for Intune data.
Schedule: Daily at 09:00 UTC (after all export functions have completed)

Reads alert rules from alerts.json, queries Log Analytics for matching
entities, deduplicates against previously alerted entities, sends email
notifications via Graph API, and records alert state to IntuneAlertState_CL.
"""
import logging
import asyncio
import os
import azure.functions as func

from shared.alert_helpers import AlertEngine

logger = logging.getLogger(__name__)


async def run():
    """Main alert engine logic. Returns total emails sent (int) for consistency with other exports."""
    logger.info("Starting Alert Engine")

    config_path = os.path.join(os.path.dirname(__file__), 'alerts.json')
    engine = AlertEngine(config_path)
    summary = await engine.run_all_rules()

    logger.info(f"Alert Engine completed: {summary}")
    return summary.get('total_emails', 0)


def main(timer: func.TimerRequest) -> None:
    """Azure Function entry point."""
    if timer.past_due:
        logger.warning("Alert Engine timer is past due")

    asyncio.run(run())
