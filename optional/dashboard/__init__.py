"""
Dashboard - Simple HTML dashboard for Intune Reporting status and manual triggers.

Provides:
- Health status overview
- Export trigger buttons
- Activity log showing recent operations
"""
import azure.functions as func


DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Intune Reporting Dashboard</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f5f5; padding: 20px; }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { color: #333; margin-bottom: 20px; }
        .card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .card h2 { color: #444; margin-bottom: 15px; font-size: 1.2em; }
        .status-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; }
        .status-item { padding: 15px; border-radius: 6px; background: #f8f9fa; }
        .status-item .label { font-size: 0.85em; color: #666; margin-bottom: 5px; }
        .status-item .value { font-size: 1.1em; font-weight: 600; }
        .status-ok { color: #28a745; }
        .status-error { color: #dc3545; }
        .status-unknown { color: #6c757d; }
        .btn-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; }
        .btn { padding: 12px 20px; border: none; border-radius: 6px; cursor: pointer; font-size: 0.95em; transition: all 0.2s; }
        .btn-primary { background: #0078d4; color: white; }
        .btn-primary:hover { background: #106ebe; }
        .btn-secondary { background: #6c757d; color: white; }
        .btn-secondary:hover { background: #5a6268; }
        .btn:disabled { opacity: 0.6; cursor: not-allowed; }
        .activity-log { max-height: 300px; overflow-y: auto; font-family: 'Consolas', monospace; font-size: 0.85em; background: #1e1e1e; color: #d4d4d4; padding: 15px; border-radius: 6px; }
        .log-entry { margin-bottom: 8px; padding-bottom: 8px; border-bottom: 1px solid #333; }
        .log-entry:last-child { border-bottom: none; margin-bottom: 0; padding-bottom: 0; }
        .log-time { color: #6a9955; }
        .log-success { color: #4ec9b0; }
        .log-error { color: #f14c4c; }
        .log-info { color: #9cdcfe; }
        .spinner { display: inline-block; width: 16px; height: 16px; border: 2px solid #f3f3f3; border-top: 2px solid #0078d4; border-radius: 50%; animation: spin 1s linear infinite; margin-right: 8px; vertical-align: middle; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div class="container">
        <h1>Intune Reporting Dashboard</h1>

        <div class="card">
            <h2>Health Status</h2>
            <div class="status-grid" id="health-status">
                <div class="status-item">
                    <div class="label">Configuration</div>
                    <div class="value status-unknown" id="status-config">Checking...</div>
                </div>
                <div class="status-item">
                    <div class="label">Authentication</div>
                    <div class="value status-unknown" id="status-auth">Checking...</div>
                </div>
                <div class="status-item">
                    <div class="label">Graph API</div>
                    <div class="value status-unknown" id="status-graph">Checking...</div>
                </div>
                <div class="status-item">
                    <div class="label">Log Analytics</div>
                    <div class="value status-unknown" id="status-la">Checking...</div>
                </div>
            </div>
        </div>

        <div class="card">
            <h2>Manual Export Triggers</h2>
            <div style="margin-bottom: 15px;">
                <label for="function-key" style="display: block; margin-bottom: 5px; font-size: 0.9em; color: #666;">
                    Function Key (required for exports):
                    <span id="key-help-toggle" style="cursor: pointer; color: #0078d4; margin-left: 5px;" onclick="toggleKeyHelp()">[How to get key]</span>
                </label>
                <input type="password" id="function-key" placeholder="Enter function key..." style="width: 100%; max-width: 500px; padding: 10px; border: 1px solid #ddd; border-radius: 4px; font-family: monospace;">
                <div id="key-help" style="display: none; margin-top: 10px; padding: 12px; background: #f0f7ff; border-left: 3px solid #0078d4; border-radius: 4px; font-size: 0.85em;">
                    <strong>How to get your Function Key:</strong>
                    <ol style="margin: 8px 0 0 20px; padding: 0;">
                        <li>Go to <a href="https://portal.azure.com" target="_blank" style="color: #0078d4;">Azure Portal</a></li>
                        <li>Navigate to your <strong>Function App</strong></li>
                        <li>In the left menu, click <strong>App keys</strong></li>
                        <li>Copy the <strong>default</strong> key (or _master for full access)</li>
                        <li>Paste it in the field above</li>
                    </ol>
                    <div style="margin-top: 8px; color: #666;">The key is stored only in your browser session and never sent to any third party.</div>
                </div>
            </div>
            <div class="btn-grid">
                <button class="btn btn-primary" onclick="runExport('devices')">Export Devices</button>
                <button class="btn btn-primary" onclick="runExport('compliance')">Export Compliance</button>
                <button class="btn btn-primary" onclick="runExport('analytics')">Export Analytics</button>
                <button class="btn btn-primary" onclick="runExport('autopilot')">Export Autopilot</button>
                <button class="btn btn-secondary" onclick="runExport('all')">Run All Exports</button>
                <button class="btn btn-secondary" onclick="runExport('test')">Test Ingestion</button>
            </div>
        </div>

        <div class="card">
            <h2>Activity Log</h2>
            <div class="activity-log" id="activity-log">
                <div class="log-entry"><span class="log-info">Dashboard loaded. Checking health status...</span></div>
            </div>
        </div>
    </div>

    <script>
        const logEl = document.getElementById('activity-log');

        function toggleKeyHelp() {
            const helpEl = document.getElementById('key-help');
            const toggleEl = document.getElementById('key-help-toggle');
            if (helpEl.style.display === 'none') {
                helpEl.style.display = 'block';
                toggleEl.textContent = '[Hide]';
            } else {
                helpEl.style.display = 'none';
                toggleEl.textContent = '[How to get key]';
            }
        }

        function log(message, type = 'info') {
            const time = new Date().toLocaleTimeString();
            const entry = document.createElement('div');
            entry.className = 'log-entry';
            entry.innerHTML = '<span class="log-time">[' + time + ']</span> <span class="log-' + type + '">' + escapeHtml(message) + '</span>';
            logEl.insertBefore(entry, logEl.firstChild);
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        function setStatus(id, status, text) {
            const el = document.getElementById(id);
            el.textContent = text || status;
            el.className = 'value status-' + (status === 'ok' ? 'ok' : status === 'error' ? 'error' : 'unknown');
        }

        async function checkHealth() {
            try {
                const response = await fetch('/api/health');
                const text = await response.text();

                // Try to parse JSON, handle empty or invalid responses
                let data;
                try {
                    if (!text || text.trim() === '') {
                        throw new Error('Empty response');
                    }
                    data = JSON.parse(text);
                } catch (parseError) {
                    log('Health check returned invalid JSON: ' + (text ? text.substring(0, 100) : 'empty'), 'error');
                    setStatus('status-config', 'error', 'Parse Error');
                    setStatus('status-auth', 'error', 'Parse Error');
                    setStatus('status-graph', 'error', 'Parse Error');
                    setStatus('status-la', 'error', 'Parse Error');
                    return;
                }

                if (data.checks) {
                    const checks = data.checks;
                    setStatus('status-config', checks.config?.status || 'unknown', checks.config?.status === 'ok' ? 'OK' : checks.config?.error || 'Unknown');
                    setStatus('status-auth', checks.authentication?.status || 'unknown', checks.authentication?.status === 'ok' ? 'OK' : checks.authentication?.error || 'Unknown');
                    setStatus('status-graph', checks.graph_api?.status || 'unknown', checks.graph_api?.status === 'ok' ? 'OK' : checks.graph_api?.note || checks.graph_api?.error || 'Unknown');
                    setStatus('status-la', checks.log_analytics?.status || 'unknown', checks.log_analytics?.status === 'ok' ? 'OK' : checks.log_analytics?.error || 'Unknown');
                    log('Health check completed: ' + data.status, data.status === 'healthy' ? 'success' : 'error');
                } else if (data.error) {
                    log('Health check failed: ' + data.error, 'error');
                    setStatus('status-config', 'error', 'Error');
                    setStatus('status-auth', 'error', 'Error');
                    setStatus('status-graph', 'error', 'Error');
                    setStatus('status-la', 'error', 'Error');
                }
            } catch (err) {
                log('Health check request failed: ' + err.message, 'error');
                setStatus('status-config', 'error', 'Request Failed');
                setStatus('status-auth', 'error', 'Request Failed');
                setStatus('status-graph', 'error', 'Request Failed');
                setStatus('status-la', 'error', 'Request Failed');
            }
        }

        async function runExport(type) {
            const btn = event.target;
            const originalText = btn.textContent;
            btn.disabled = true;
            btn.innerHTML = '<span class="spinner"></span>Running...';

            log('Starting export: ' + type, 'info');

            try {
                // Get function key from input
                const functionKey = document.getElementById('function-key').value.trim();
                let url = '/api/export/' + type;
                if (functionKey) {
                    url += '?code=' + encodeURIComponent(functionKey);
                }

                const response = await fetch(url);

                // Check for 401 BEFORE trying to parse JSON (401 returns empty body)
                if (response.status === 401) {
                    log('Export requires function key. Enter your key above or get it from Azure Portal.', 'error');
                    return;
                }

                const text = await response.text();

                // Try to parse JSON, handle empty or invalid responses
                let data;
                try {
                    if (!text || text.trim() === '') {
                        throw new Error('Empty response');
                    }
                    data = JSON.parse(text);
                } catch (parseError) {
                    log('Export returned invalid response (HTTP ' + response.status + '): ' + (text ? text.substring(0, 100) : 'empty'), 'error');
                    return;
                }

                if (response.ok) {
                    if (data.records !== undefined) {
                        log('Export ' + type + ' completed: ' + data.records + ' records in ' + (data.duration_seconds || 0) + 's', 'success');
                    } else if (data.total_records !== undefined) {
                        log('All exports completed: ' + data.total_records + ' total records in ' + (data.duration_seconds || 0) + 's', 'success');
                    } else if (data.records_sent !== undefined) {
                        log('Test ingestion completed: ' + data.records_sent + ' records sent', 'success');
                    } else {
                        log('Export completed: ' + JSON.stringify(data), 'success');
                    }
                } else {
                    log('Export failed: ' + (data.error || 'HTTP ' + response.status), 'error');
                }
            } catch (err) {
                log('Export request failed: ' + err.message, 'error');
            } finally {
                btn.disabled = false;
                btn.textContent = originalText;
            }
        }

        // Check health on load
        checkHealth();

        // Refresh health every 60 seconds
        setInterval(checkHealth, 60000);
    </script>
</body>
</html>
"""


def main(req: func.HttpRequest) -> func.HttpResponse:
    """Serve the dashboard HTML."""
    return func.HttpResponse(
        DASHBOARD_HTML,
        mimetype="text/html",
        status_code=200
    )
