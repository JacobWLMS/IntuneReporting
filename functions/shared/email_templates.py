"""HTML email templates for the alert engine."""

SEVERITY_COLORS = {
    'critical': '#dc3545',
    'high': '#fd7e14',
    'medium': '#ffc107',
    'low': '#28a745',
}


def build_alert_email(rule: dict, entity: dict) -> str:
    """Build HTML email body with entity details in a table."""
    severity = rule.get('severity', 'medium')
    color = SEVERITY_COLORS.get(severity, '#6c757d')

    fields_html = ""
    for field in rule.get('email', {}).get('body_fields', []):
        value = entity.get(field) or 'N/A'
        fields_html += (
            f"<tr>"
            f"<td style='padding:8px;border:1px solid #ddd;font-weight:bold;background:#f8f9fa'>{field}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{value}</td>"
            f"</tr>\n"
        )

    return f"""<div style="font-family:Segoe UI,Arial,sans-serif;max-width:600px">
    <div style="background:{color};color:white;padding:12px 16px;border-radius:4px 4px 0 0">
        <h2 style="margin:0;font-size:18px">{rule.get('name', 'Intune Alert')}</h2>
        <p style="margin:4px 0 0;font-size:13px;opacity:0.9">Severity: {severity.upper()}</p>
    </div>
    <div style="padding:16px;border:1px solid #ddd;border-top:none;border-radius:0 0 4px 4px">
        <p style="margin:0 0 12px">{rule.get('description', '')}</p>
        <table style="width:100%;border-collapse:collapse;margin-bottom:16px">
            {fields_html}
        </table>
        <p style="color:#6c757d;font-size:12px;margin:0">Sent by Intune Reporting Alert Engine.</p>
    </div>
</div>"""


def build_resolve_email(rule: dict, entity_id: str, entity_name: str) -> str:
    """Build HTML email body for a resolved alert."""
    return f"""<div style="font-family:Segoe UI,Arial,sans-serif;max-width:600px">
    <div style="background:#28a745;color:white;padding:12px 16px;border-radius:4px 4px 0 0">
        <h2 style="margin:0;font-size:18px">Resolved: {rule.get('name', 'Intune Alert')}</h2>
    </div>
    <div style="padding:16px;border:1px solid #ddd;border-top:none;border-radius:0 0 4px 4px">
        <p>The following entity is no longer in an alert condition:</p>
        <table style="width:100%;border-collapse:collapse;margin-bottom:16px">
            <tr><td style="padding:8px;border:1px solid #ddd;font-weight:bold;background:#f8f9fa">Entity ID</td><td style="padding:8px;border:1px solid #ddd">{entity_id}</td></tr>
            <tr><td style="padding:8px;border:1px solid #ddd;font-weight:bold;background:#f8f9fa">Entity Name</td><td style="padding:8px;border:1px solid #ddd">{entity_name}</td></tr>
        </table>
        <p style="color:#6c757d;font-size:12px;margin:0">Sent by Intune Reporting Alert Engine.</p>
    </div>
</div>"""
