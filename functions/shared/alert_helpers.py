"""
Alert Engine helpers — config-driven alerting for Intune data.

Queries Log Analytics for alert conditions, deduplicates against
previously-alerted entities, sends email notifications via Graph
sendMail, and records alert state to IntuneAlertState_CL.
"""
import json
import logging
import asyncio
import os
from datetime import datetime, timezone, timedelta
from typing import Dict, List, Set, Any

from azure.monitor.query import LogsQueryClient, LogsQueryStatus
from msgraph_beta.generated.users.item.send_mail.send_mail_post_request_body import SendMailPostRequestBody
from msgraph_beta.generated.models.message import Message
from msgraph_beta.generated.models.item_body import ItemBody
from msgraph_beta.generated.models.body_type import BodyType
from msgraph_beta.generated.models.recipient import Recipient
from msgraph_beta.generated.models.email_address import EmailAddress

from azure.identity import ManagedIdentityCredential

from shared import (
    get_credential,
    get_env,
    get_graph_client,
    add_metadata,
    retry_with_backoff,
    DataIngester,
    ConfigurationError,
)
from shared.email_templates import build_alert_email, build_resolve_email

logger = logging.getLogger(__name__)

DEFAULT_MAX_EMAILS_PER_RUN = 50
EMAIL_SEND_DELAY = 0.5  # seconds between emails to avoid throttling


class AlertEngine:
    """Config-driven alert engine that queries Log Analytics and sends emails."""

    def __init__(self, config_path: str):
        self.config = self._load_config(config_path)
        self.query_client = LogsQueryClient(ManagedIdentityCredential())
        self.graph_client = get_graph_client()
        self.ingester = DataIngester()
        self.workspace_id = get_env('LOG_ANALYTICS_WORKSPACE_ID')
        if not self.workspace_id:
            raise ConfigurationError("LOG_ANALYTICS_WORKSPACE_ID is required for the alert engine")
        self.sender_address = get_env('ALERT_SENDER_ADDRESS')
        if not self.sender_address:
            raise ConfigurationError("ALERT_SENDER_ADDRESS is required for the alert engine")

    def _load_config(self, config_path: str) -> dict:
        """Load and validate alert configuration from JSON file."""
        if not os.path.exists(config_path):
            raise ConfigurationError(f"Alert config not found: {config_path}")

        with open(config_path, 'r') as f:
            config = json.load(f)

        defaults = config.get('defaults', {})
        alerts = config.get('alerts', [])

        if not alerts:
            logger.warning("No alert rules defined in config")
            return config

        for alert in alerts:
            if 'id' not in alert:
                raise ConfigurationError(f"Alert rule missing 'id': {alert}")
            if 'kql_query' not in alert:
                raise ConfigurationError(f"Alert rule '{alert['id']}' missing 'kql_query'")
            if 'entity_id_field' not in alert:
                raise ConfigurationError(f"Alert rule '{alert['id']}' missing 'entity_id_field'")

            # Apply defaults
            alert.setdefault('enabled', defaults.get('enabled', True))
            alert.setdefault('severity', defaults.get('severity', 'medium'))
            alert.setdefault('cooldown_days', defaults.get('cooldown_days', 30))
            alert.setdefault('max_emails_per_run', defaults.get('max_emails_per_run', DEFAULT_MAX_EMAILS_PER_RUN))
            alert.setdefault('parameters', {})
            alert.setdefault('auto_resolve', {'enabled': False})
            alert['auto_resolve'].setdefault('send_resolve_email', False)
            alert.setdefault('email', {})
            alert['email'].setdefault('recipients', defaults.get('recipients', ['{ALERT_RECIPIENTS}']))

        logger.info(f"Loaded {len(alerts)} alert rules from config")
        return config

    def _substitute_parameters(self, template: str, parameters: dict) -> str:
        """Replace {key} placeholders in a string with parameter values."""
        result = template
        for key, value in parameters.items():
            result = result.replace(f'{{{key}}}', str(value))
        return result

    def _query_log_analytics(self, kql: str) -> List[Dict[str, Any]]:
        """Execute a KQL query and return rows as dicts."""
        response = self.query_client.query_workspace(
            workspace_id=self.workspace_id,
            query=kql,
            timespan=timedelta(days=90),
        )

        if response.status == LogsQueryStatus.PARTIAL:
            logger.warning("KQL query returned partial results")
        elif response.status == LogsQueryStatus.FAILURE:
            raise Exception(f"KQL query failed: {response}")

        rows = []
        for table in response.tables:
            columns = [col if isinstance(col, str) else col.name for col in table.columns]
            for row in table.rows:
                rows.append(dict(zip(columns, row)))
        return rows

    def _get_active_alert_ids(self, alert_id: str) -> Set[str]:
        """Get entity IDs with active alerts for a rule."""
        kql = f"""IntuneAlertState_CL
| where AlertId == '{alert_id}' and State == 'active'
| summarize arg_max(TimeGenerated, *) by EntityId
| project EntityId"""
        try:
            return {row['EntityId'] for row in self._query_log_analytics(kql)}
        except Exception as e:
            # On first run, table may not exist yet
            if any(s in str(e).lower() for s in ['not found', 'does not exist', 'bad request']):
                logger.info(f"Alert state table not found (first run?), treating as empty")
                return set()
            raise

    def _get_cooldown_ids(self, alert_id: str, cooldown_days: int) -> Set[str]:
        """Get entity IDs in cooldown (recently resolved)."""
        kql = f"""IntuneAlertState_CL
| where AlertId == '{alert_id}' and State == 'resolved'
| summarize arg_max(TimeGenerated, *) by EntityId
| where datetime_diff('day', now(), todatetime(ResolvedAt)) < {cooldown_days}
| project EntityId"""
        try:
            return {row['EntityId'] for row in self._query_log_analytics(kql)}
        except Exception:
            return set()

    def _resolve_recipients(self, recipient_list: List[str]) -> List[str]:
        """Resolve recipient addresses, substituting {ENV_VAR} references."""
        resolved = []
        for addr in recipient_list:
            if addr.startswith('{') and addr.endswith('}'):
                env_value = get_env(addr[1:-1])
                if env_value:
                    resolved.extend([a.strip() for a in env_value.split(',')])
                else:
                    logger.warning(f"Recipient env var '{addr[1:-1]}' not set, skipping")
            else:
                resolved.append(addr)
        return resolved

    async def _send_email(self, recipients: List[str], subject: str, body_html: str):
        """Send an email via Graph sendMail API."""
        message = Message()
        message.subject = subject
        message.body = ItemBody(content_type=BodyType.Html, content=body_html)
        message.to_recipients = [
            Recipient(email_address=EmailAddress(address=addr))
            for addr in recipients
        ]

        request_body = SendMailPostRequestBody(message=message, save_to_sent_items=False)
        await retry_with_backoff(
            self.graph_client.users.by_user_id(self.sender_address).send_mail.post,
            request_body
        )

    async def run_rule(self, rule: dict) -> Dict[str, int]:
        """Run a single alert rule: detect, deduplicate, alert, resolve."""
        rule_id = rule['id']
        rule_name = rule.get('name', rule_id)
        entity_id_field = rule['entity_id_field']
        max_emails = rule.get('max_emails_per_run', DEFAULT_MAX_EMAILS_PER_RUN)
        summary = {'new_alerts': 0, 'emails_sent': 0, 'resolved': 0, 'capped': 0}

        # 1. Run detection query
        kql = self._substitute_parameters(rule['kql_query'], rule.get('parameters', {}))
        detection_results = self._query_log_analytics(kql)
        detected_ids = {row[entity_id_field] for row in detection_results}
        logger.info(f"[{rule_name}] Detected {len(detected_ids)} entities matching condition")

        if not detected_ids:
            if rule.get('auto_resolve', {}).get('enabled'):
                summary['resolved'] = await self._auto_resolve(rule)
            return summary

        # 2-3. Deduplicate against active alerts and cooldown
        active_ids = self._get_active_alert_ids(rule_id)
        cooldown_ids = self._get_cooldown_ids(rule_id, rule.get('cooldown_days', 30))
        new_ids = detected_ids - active_ids - cooldown_ids
        new_entities = [r for r in detection_results if r[entity_id_field] in new_ids]
        summary['new_alerts'] = len(new_entities)
        logger.info(f"[{rule_name}] {len(new_entities)} new, {len(active_ids)} already active, {len(cooldown_ids)} in cooldown")

        if not new_entities:
            if rule.get('auto_resolve', {}).get('enabled'):
                summary['resolved'] = await self._auto_resolve(rule)
            return summary

        # 4. Send emails (capped at max_emails_per_run)
        recipients = self._resolve_recipients(rule.get('email', {}).get('recipients', []))
        if not recipients:
            logger.error(f"[{rule_name}] No recipients configured, skipping emails")
        else:
            entities_to_email = new_entities[:max_emails]
            capped_count = len(new_entities) - len(entities_to_email)
            if capped_count > 0:
                summary['capped'] = capped_count
                logger.warning(f"[{rule_name}] Capped at {max_emails} emails, {capped_count} remaining will alert next run")

            state_records = []
            for i, entity in enumerate(entities_to_email):
                entity_id = entity[entity_id_field]
                # Get a human-readable name from common fields
                entity_name = next(
                    (str(entity[f]) for f in ['DeviceName', 'UserPrincipalName', 'DisplayName', 'Name']
                     if f in entity and entity[f]),
                    str(entity.get(entity_id_field, 'Unknown'))
                )

                # Build and send email
                subject_template = rule.get('email', {}).get('subject_template', f'[Intune Alert] {rule_name}')
                subject = subject_template
                for key, value in entity.items():
                    subject = subject.replace(f'{{{key}}}', str(value) if value is not None else 'N/A')
                body = build_alert_email(rule, entity)

                try:
                    await self._send_email(recipients, subject, body)
                    summary['emails_sent'] += 1
                except Exception as e:
                    logger.error(f"[{rule_name}] Failed to send email for {entity_id}: {e}")
                    continue  # Don't record state if email failed

                # Record alert state
                now_iso = datetime.now(timezone.utc).isoformat()
                state_records.append({
                    'AlertId': rule_id,
                    'AlertName': rule_name,
                    'EntityId': entity_id,
                    'EntityName': entity_name,
                    'State': 'active',
                    'Severity': rule.get('severity', 'medium'),
                    'AlertedAt': now_iso,
                    'ResolvedAt': None,
                    'Details': json.dumps({k: str(v) if v is not None else None for k, v in entity.items()}),
                })

                # Delay between emails to avoid throttling
                if i < len(entities_to_email) - 1:
                    await asyncio.sleep(EMAIL_SEND_DELAY)

            self._write_alert_state(state_records)
            logger.info(f"[{rule_name}] Sent {summary['emails_sent']} emails, wrote {len(state_records)} state records")

        # 5. Auto-resolve
        if rule.get('auto_resolve', {}).get('enabled'):
            summary['resolved'] = await self._auto_resolve(rule)

        return summary

    def _write_alert_state(self, records: List[dict]):
        """Write alert state records to IntuneAlertState_CL via DCR."""
        if not records:
            return
        records = add_metadata(records, 'IntuneAlertEngine')
        self.ingester.ingest('AlertState', records)

    async def _auto_resolve(self, rule: dict) -> int:
        """Check for resolved alerts and update state. Returns count resolved."""
        auto_resolve = rule.get('auto_resolve', {})
        resolve_query = auto_resolve.get('resolve_query')
        if not resolve_query:
            return 0

        rule_id = rule['id']
        rule_name = rule.get('name', rule_id)
        entity_id_field = rule['entity_id_field']

        active_ids = self._get_active_alert_ids(rule_id)
        if not active_ids:
            return 0

        # Find entities no longer in alert condition
        kql = self._substitute_parameters(resolve_query, rule.get('parameters', {}))
        resolved_ids = {row[entity_id_field] for row in self._query_log_analytics(kql)}
        to_resolve = active_ids & resolved_ids
        if not to_resolve:
            return 0

        logger.info(f"[{rule_name}] Resolving {len(to_resolve)} alerts")

        # Get entity names for resolve emails (if configured)
        active_details = {}
        if auto_resolve.get('send_resolve_email'):
            details_kql = f"""IntuneAlertState_CL
| where AlertId == '{rule_id}' and State == 'active'
| summarize arg_max(TimeGenerated, *) by EntityId
| project EntityId, EntityName, AlertedAt"""
            try:
                active_details = {row['EntityId']: row for row in self._query_log_analytics(details_kql)}
            except Exception:
                pass

        now_iso = datetime.now(timezone.utc).isoformat()
        state_records = []
        recipients = self._resolve_recipients(rule.get('email', {}).get('recipients', []))

        for entity_id in to_resolve:
            detail = active_details.get(entity_id, {})
            entity_name = detail.get('EntityName', entity_id)

            state_records.append({
                'AlertId': rule_id,
                'AlertName': rule_name,
                'EntityId': entity_id,
                'EntityName': entity_name,
                'State': 'resolved',
                'Severity': rule.get('severity', 'medium'),
                'AlertedAt': detail.get('AlertedAt', now_iso),
                'ResolvedAt': now_iso,
                'Details': json.dumps({'resolve_reason': 'condition_cleared'}),
            })

            if auto_resolve.get('send_resolve_email') and recipients:
                try:
                    body = build_resolve_email(rule, entity_id, entity_name)
                    await self._send_email(recipients, f"[Intune Alert] Resolved: {entity_name}", body)
                except Exception as e:
                    logger.error(f"[{rule_name}] Failed to send resolve email for {entity_id}: {e}")

        self._write_alert_state(state_records)
        logger.info(f"[{rule_name}] Resolved {len(state_records)} alerts")
        return len(to_resolve)

    async def run_all_rules(self) -> Dict[str, Any]:
        """Run all enabled alert rules and return summary."""
        alerts = self.config.get('alerts', [])
        enabled = [a for a in alerts if a.get('enabled', True)]

        if not enabled:
            logger.info("No enabled alert rules to run")
            return {'rules_run': 0, 'total_new': 0, 'total_emails': 0, 'total_resolved': 0}

        logger.info(f"Running {len(enabled)} enabled alert rules")
        total_new = 0
        total_emails = 0
        total_resolved = 0
        rule_results = {}

        for rule in enabled:
            try:
                result = await self.run_rule(rule)
                rule_results[rule['id']] = result
                total_new += result['new_alerts']
                total_emails += result['emails_sent']
                total_resolved += result['resolved']
            except Exception as e:
                logger.error(f"[{rule.get('name', rule['id'])}] Rule failed: {e}", exc_info=True)
                rule_results[rule['id']] = {'error': str(e)}

        logger.info(f"Alert Engine complete: {len(enabled)} rules, {total_new} new, {total_emails} emails, {total_resolved} resolved")
        return {
            'rules_run': len(enabled),
            'total_new': total_new,
            'total_emails': total_emails,
            'total_resolved': total_resolved,
            'rules': rule_results,
        }
