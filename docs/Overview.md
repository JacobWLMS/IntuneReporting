# Intune Reporting & Alerting

I wanted to share an overview of the Intune Reporting & Alerting solution now running in the background. This is an automated system that collects device and user data from Intune and Entra ID on a schedule, stores it in Azure Log Analytics, and then provides dashboards and email alerts on top of that data. It requires no manual intervention and the current running cost is approximately **£4.40 per month**.

## How it works

The system connects to Microsoft Graph API on a recurring schedule (some datasets every few hours, others daily). The data is stored in Azure Log Analytics, giving us a central, queryable history of our device estate over time rather than a point-in-time snapshot. Dashboards and alert rules are built on top of this data.

## Stale devices

This was primarily built to identify stale Windows devices — devices that have stopped checking in to Intune. A stale device is no longer receiving security policies, compliance updates, or software deployments, and until now we have not had a reliable way to catch them early.

Each morning, the system checks for Windows devices that have not synced in over 30 days and sends an email alert for each one. Each alert includes the device name, serial number, last known user, their department and office, and how long the device has been stale. Devices are categorised by severity based on staleness duration (Low: 1–2 months through to Critical: 6+ months). If a device starts syncing again, it is automatically marked as resolved so we are not chasing issues that have already self-corrected.

There is also a dedicated Stale Device Investigation dashboard for the service desk, which lists stale devices in a queue filtered by severity, with a per-device detail view to support triage and investigation.

## Dashboards

| Dashboard | What it shows |
| --- | --- |
| **Stale Device Investigation** | Queue of stale devices with severity filtering and a per-device detail view for the service desk. |
| **Device Inventory** | All managed devices — hardware, OS, models, encryption status, enrolment details. |
| **Compliance Overview** | Which devices are compliant with which policies, and which are not. |
| **Device Health** | Endpoint Analytics scores — startup performance, app reliability, overall device health. |
| **Autopilot Deployment** | Windows Autopilot enrolment and deployment status by group tag and profile. |

## Data currently collected

| Dataset | What it covers | Update frequency |
| --- | --- | --- |
| **Managed Devices** | Device identity, hardware, OS, security status, enrolment dates, last sync, assigned users | Every 4 hours |
| **Compliance** | Per-device compliance status against each policy | Every 6 hours |
| **Autopilot** | Serial numbers, enrolment state, group tags, profile assignments | Daily |
| **Endpoint Analytics** | Device health scores, startup times, app crash rates | Daily |
| **Users** | Entra ID user profiles — name, department, job title, office, account status, last sign-in | Daily |

## Going forward

Because the data is pulled via Microsoft Graph API, which covers most of Intune, Entra ID, and Microsoft 365, we can extend reporting to additional areas where data is available — for example application installations, Windows Update compliance, or licence usage. New alert rules can also be added through configuration without code changes. If there is something you would like visibility on that is not covered here, raise it with the team and we can look at what is possible.
