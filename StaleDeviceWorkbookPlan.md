Stale Device Investigation Workbook — Reclaim Workflow
Context
Service desk analysts receive stale device alerts and must reclaim the device — physically locate it, contact whoever had it, decide whether to retire or recover it. The workbook supports this workflow end-to-end: see my queue → pick a device → who had it & where are they → is it a security risk → what do I do with it.

Design principles:

Device-first, always — analyst starts from a device alert, never from a user
Global device selector — pick a device once, then click through tabs for progressively deeper detail
All selection via Type 2 dropdowns — no broken grid row clicks
Works without IntuneUsers_CL — all user joins use kind=leftouter
"No Data" for empty fields — never blank, never null — always show "No Data" so analyst knows the field exists but has no value
Best-known user — resolve the most likely active user from multiple sources (same logic as StaleDeviceIncidents.kql): prefer last logon user over primary assigned user, coalesce across sources
Most useful info first — within each tab, the most actionable information appears at the top; supplementary/reference info lower
Explanatory notes — every visual has a brief markdown note explaining what the data shows, where it comes from, and how reliable it is
Tab Structure
Tab	Purpose	What the analyst is asking
1. Queue	Overview + device list to pick from	"Which stale devices need my attention?"
2. Device Details	Hardware, enrollment, compliance, health	"What is this device and what state is it in?"
3. Locate & Contact	Best-known user, location, department contacts, physical IDs	"Who had it, where are they, and how do I find it?"
4. Action	Risk assessment, recommendation, batch export lists	"What should I do with it — retire, investigate, or wait?"
5. Trends	Historical charts for management reporting	"Is the stale device situation getting better or worse?"
Parameter Flow

Global (visible on all tabs):
  Tab (type 1, hidden)
  StaleDays (type 1, default "30")
  SeverityFilter (type 2, multi-select: Critical/High/Medium/Low)
  DeviceSearch (type 1, text: "Search by name, serial, or user")
  SelectedDevice (type 2, single-select, query-driven from filters above)

Tab 1 shows a grid of all stale devices (read-only overview)
Tabs 2-4 show detail panels, all with conditionalVisibility: SelectedDevice != ""
Tab 5 shows fleet-wide trends — no device selection needed (for managers)
Best-Known User Resolution
Reuse the logic from deployment/kql/StaleDeviceIncidents.kql (lines 67-75). Multiple user sources exist for any device:

Primary User — UserPrincipalName from IntuneManagedDevices_CL (the assigned/enrolled user)
Last Logon User — LastLoggedOnUserId from IntuneManagedDevices_CL, resolved to a UPN via IntuneUsers_CL
Entra Sign-In — LastSignInDateTime from IntuneUsers_CL for the resolved user
The "Best Known User" is resolved as:


BestKnownUser = coalesce(LastLogonUserUPN, UserPrincipalName, "No Data")
BestKnownUserName = coalesce(LastLogonUserName, UserDisplayName, "No Data")
BestKnownDept = coalesce(LastLogonDepartment, Department, "No Data")
BestKnownMail = coalesce(LastLogonMail, Mail, EmailAddress, "No Data")
BestKnownAccountEnabled = coalesce(LastLogonAccountEnabled, AccountEnabled)
The "Locate & Contact" tab shows the best-known user prominently at the top, THEN shows the raw Primary User and Last Logon User separately below for transparency.

Tab 1: Queue
Goal: "Show me everything that needs attention, let me pick one"

Information priority (top to bottom):

Stat tiles (4 × 25%): Total Stale, Critical (6+mo), Orphaned (user disabled), Unencrypted

Note: "Counts are based on Windows devices that haven't synced with Intune for more than {StaleDays} days. Orphaned means the associated user account is disabled in Entra ID."
Stale device grid (full width, sortable, exportable):

Severity (icon), DeviceName, SerialNumber, Model, BestKnownUser, BestKnownDept, BestKnownOffice, LastSyncDaysAgo, ComplianceState, Encrypted, RecommendedAction
Color-coded: severity icons, heatmap on days stale, compliance/encryption icons
Note: "All stale Windows devices sorted by severity. The 'Best Known User' is resolved from the last logon user (preferred) or the primary assigned user. Use the global filters above to narrow the list."
Severity pie chart (40%) + Top departments table (60%)

Note on pie: "Distribution of stale devices by how long they've been offline."
Note on departments: "Departments with the most stale devices. Department data comes from Entra ID user profiles — requires User.Read.All permission."
Tab 2: Device Details
Goal: "Tell me everything about this device"

All panels have conditionalVisibility: SelectedDevice != ""

Information priority (top to bottom):

Status bar — 5 stat tiles (20% each): Days Stale, Severity, Compliance, Encrypted, User Account Status

All color-coded with thresholds (green/yellow/orange/red)
Note: "At-a-glance status of the selected device. Red indicates critical issues requiring immediate attention."
Device Identity table (55%): DeviceName, SerialNumber, Manufacturer, Model, FormFactor, OS, OSVersion, Storage, RAM

All empty fields show "No Data"
Note: "Hardware and OS details from Intune device inventory. Updated every 4 hours when the device syncs."
Staleness Signals bar chart (45%): horizontal bars for each signal

Intune Sync, Device Logon, User Sign-In (interactive), User Sign-In (non-interactive)
Note: "Shows how long ago each activity signal was last seen. Intune Sync and Device Logon come from the device record. User Sign-In comes from Entra ID — requires AuditLog.Read.All permission. Signals not available show as empty."
Compliance Policies table (full width): per-policy status, failed settings, last contact

Sorted: non-compliant first, then error, then compliant
Note: "Compliance policy evaluation results for this device. Updated every 6 hours. If no policies appear, the device may not have been evaluated recently."
Enrollment & Management table (50%): OwnerType, JoinType, DeviceEnrollmentType, ManagementState, AutopilotEnrolled, EnrolledDateTime, enrollment age, cert expiry, RetireAfterDateTime, Notes

Note: "Enrollment and management configuration. 'Retire After' shows if an admin has scheduled this device for retirement."
Endpoint Analytics table (50%): HealthStatus, OverallScore, StartupScore, AppReliabilityScore, WorkFromAnywhereScore

Heatmap 0-100 (red to green)
Note: "Endpoint Analytics scores from Microsoft's device health service. Updated daily. Note: the scores table uses device name (not ID) for matching, so renamed devices may not match. Scores may be stale since the device hasn't been checking in."
Tab 3: Locate & Contact
Goal: "Who had this device, where are they, and who else can help me find it?"

All panels have conditionalVisibility: SelectedDevice != ""

Information priority (top to bottom — most actionable first):

Best Known User table (full width): Single-row card showing the resolved best user

DisplayName, UPN, Email, JobTitle, Department, OfficeLocation, City, Country, AccountEnabled (icon), LastSignInDaysAgo
All empty fields show "No Data"
Note: "The most likely current user of this device. Resolved by preferring the last logged-on user over the primary assigned user (last logon is more recent and reliable). If the user account is disabled, the device is likely orphaned."
Location & Physical IDs table (full width): For physically tracking the device

OfficeLocation, City, State, Country, FormFactor, OwnerType, SerialNumber, WiFi MAC (formatted), Ethernet MAC, IMEI
All empty fields show "No Data"
Note: "Location comes from the best-known user's Entra ID profile — it reflects where the user is assigned, not necessarily where the device is physically located. Physical identifiers (serial, MAC, IMEI) can be used with asset tracking systems or network tools to locate the device. Requires User.Read.All permission for location fields."
All User Sources table (full width): Shows Primary User AND Last Logon User as separate rows

Source (Primary/Last Logon), DisplayName, UPN, Email, Department, Office, AccountEnabled, LastSignIn
Note: "All known user associations for this device. 'Primary' is the user assigned during enrollment. 'Last Logon' is the most recent Windows logon recorded by Intune. These may be the same person. If they differ, the Last Logon user is usually more relevant for reclaim."
Department Contacts table (full width): Active users in same department, signed in within 14 days

DisplayName, UPN, Email, JobTitle, OfficeLocation
Excludes the device's own user, limited to 10
Note: "Active users in the same department who have signed in recently. Contact them if the primary user is unreachable or has left the organisation. Only shows results when department data is available in Entra ID."
Tab 4: Action
Goal: "What should I do with this device, and let me process the batch"

Information priority (top to bottom):

Per-device section (conditionalVisibility: SelectedDevice != "")
Risk Assessment table (full width): Single row

Severity, RecommendedAction, UserAccount status, Encrypted, ComplianceState, ActiveMalware count, RiskFactors
RiskFactors = pipe-delimited list of: "User account disabled", "Device NOT encrypted", "6+ months without sync", "Non-compliant", "Active malware detected"
Note: "Automated risk assessment based on staleness duration, user account status, encryption, compliance, and malware signals. Recommended action follows these rules: RETIRE if user disabled + 90d stale, no user + 90d stale, or 6+ months offline. INVESTIGATE if 90d+ stale or user recently disabled. MONITOR if recently gone stale with active user."
Other Devices from Same User table: All devices (stale + active) for the best-known user

Status (STALE/Active), DeviceName, Model, LastSyncDaysAgo, ComplianceState
Note: "All devices associated with the same user. Helps identify if the user has a replacement device (suggesting this one can be retired) or if multiple devices are stale (suggesting the user may have left)."
Batch section (always visible)
3 stat tiles: Ready to Retire, Needs Investigation, Monitor

Note: "Summary of all stale devices grouped by recommended action."
Retire list (exportable): Reason, DeviceName, Serial, BestKnownUser, DaysStale, Model, Encrypted

Note: "Devices safe to retire: user account disabled + 90 days stale, no known user + 90 days stale, or 6+ months with no contact. Export to Excel and process retirements in bulk via Intune."
Investigate list (exportable): Reason, DeviceName, Serial, BestKnownUser, ContactEmail, Department, DaysStale

Note: "Devices that need manual follow-up before a retire decision. Contact the user or department colleagues to determine device status."
Monitor list (exportable): DeviceName, BestKnownUser, Department, DaysStale, Model

Note: "Recently stale devices that may come back online. Re-check in the next review cycle."
Tab 5: Trends
Goal: "Is the stale device problem getting better or worse?" — for managers and team leads

No conditionalVisibility on SelectedDevice — this tab shows fleet-wide data regardless of device selection.

Information priority (top to bottom):

Stale device count over time (full width, timechart):

Daily count of stale devices over the last 30 days
Shows whether the total count is trending up (growing backlog) or down (team is clearing it)
Note: "Daily count of Windows devices exceeding the stale threshold. Based on historical snapshots in Log Analytics. A rising trend means devices are going stale faster than they're being reclaimed."
Severity breakdown over time (full width, timechart with 4 series):

Daily count broken out by Critical/High/Medium/Low severity
Shows whether the most serious cases are being addressed
Note: "Stale devices broken down by severity over time. Ideally Critical and High counts should decrease as devices are retired or recovered."
New vs Resolved (full width, timechart):

"New stale" = devices that crossed the stale threshold this week
"Resolved" = devices that were stale last week but are no longer (either synced back or removed from Intune)
Note: "Devices entering vs leaving stale status each week. 'New' means the device crossed the stale threshold. 'Resolved' means a previously stale device synced again or was retired. When 'Resolved' exceeds 'New', the backlog is shrinking."
Stale by Department bar chart (50%) + Stale by Model bar chart (50%):

Top 10 each, for spotting systemic patterns
Note on departments: "Departments with the most stale devices. May indicate teams with poor device return processes or high staff turnover."
Note on models: "Device models most represented in the stale queue. Older models may be candidates for bulk retirement."
Key KQL Patterns
Global device selector query: Same as before but with "No Data" fallbacks:


| project label = strcat(DeviceName, " | ", coalesce(UserPrincipalName,"no user"), " | ", coalesce(SerialNumber,"no serial"), " | ", tostring(LastSyncDaysAgo), "d"), value = DeviceId
Best-known user resolution (reuse from StaleDeviceIncidents.kql lines 67-75):


| extend BestKnownUser = coalesce(LastLogonUserUPN, UserPrincipalName, "No Data")
| extend BestKnownUserName = coalesce(LastLogonUserName, UserDisplayName, "No Data")
| extend BestKnownDept = coalesce(LastLogonDepartment, Department, "No Data")
| extend BestKnownMail = coalesce(LastLogonMail, Mail, EmailAddress, "No Data")
"No Data" pattern for all displayed fields:


| project Field = coalesce(Field, "No Data")
Wi-Fi MAC formatting: strcat(substring(WiFiMacAddress,0,2),":",...) when strlen == 12, else "No Data"

Endpoint Analytics join: DeviceId in IntuneDeviceScores_CL = DeviceName, not GUID — resolve first

Critical Files
File	Action
deployment/workbooks/stale-device-investigation.workbook	Create
deployment/kql/StaleDeviceIncidents.kql	Reference — best-known user resolution logic (lines 67-75), severity/action classification (lines 82-93)
deployment/workbooks/device-inventory.workbook	Reference — working Type 2 dropdown patterns
deployment/workbooks/compliance-overview.workbook	Reference — Value/Label projection pattern
Implementation
Build complete workbook JSON via Python script — header, global params, tabs, 4 groups
Each tab is a type 12 group with conditionalVisibility on Tab parameter
Global params (including device selector) in a type 9 block before tabs
Every visual followed by a type 1 markdown note explaining the data
All coalesce(field, "No Data") for every displayed field
Write with json.dumps(indent=2) for valid, readable JSON
Verification
python -c "import json; json.load(open(...))" — valid JSON
Test device selector KQL against workspace c142a15c-eb91-49a9-a516-d3fbd4dc798f
Verify conditionalVisibility: no device → "Select a device" prompt; device selected → panels appear
Confirm leftouter joins return "No Data" (not blank/null) with empty IntuneUsers_CL
Paste into Azure Monitor Workbooks Advanced Editor and verify 4 tabs render correctly