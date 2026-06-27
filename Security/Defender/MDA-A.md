# Microsoft Defender for Cloud Apps (MDA) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers **Microsoft Defender for Cloud Apps (MDA)**, formerly Microsoft Cloud App Security (MCAS). Key areas:

- Cloud Discovery (Shadow IT detection via log upload or endpoint integration)
- App Connectors (sanctioned SaaS apps via API)
- Session Controls via Conditional Access App Control (CAAC)
- Policies: Activity, Access, Session, File, Anomaly detection
- Integration with Microsoft Sentinel, MDE, and Purview

**Assumptions:**
- Microsoft 365 E5 or EMS E5 licensing (MDA is included)
- Entra ID (Azure AD) Conditional Access configured for session control redirect
- MDE integration enabled for Cloud Discovery (preferred over log collectors for endpoints)

---

## How It Works

<details><summary>Full architecture — MDA data flows and enforcement</summary>

### Three Core Data Planes

```
┌─────────────────────────────────────────────────────────────────┐
│                   Microsoft Defender for Cloud Apps             │
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │  Cloud Discovery │  │  App Connectors  │  │  App Control │  │
│  │  (Shadow IT)     │  │  (API-based)     │  │  (Sessions)  │  │
│  └──────┬───────────┘  └──────┬───────────┘  └──────┬───────┘  │
│         │                    │                      │          │
└─────────┼────────────────────┼──────────────────────┼──────────┘
          │                    │                      │
          ▼                    ▼                      ▼
  MDE endpoint logs    OAuth API tokens        Reverse proxy
  Firewall/proxy logs  (Microsoft 365,         (mca.ms redirect)
  Log Collectors       Salesforce, Box, etc.)
```

### 1. Cloud Discovery Pipeline

```
Endpoint (MDE integrated)
    │
    ├── Network traffic metadata → MDE Sense → MDA Cloud Discovery
    │         (app name, bytes, users, risk score)
    │
    └── OR: Log Collector (on-prem VM/Docker)
            │
            ├── Receives syslog/FTP from firewall/proxy
            ├── Parses vendor-specific format (Cisco, Palo Alto, Zscaler, etc.)
            └── Uploads anonymized metadata to MDA

MDA Cloud Discovery Processing:
    │
    ├── Cross-references against Cloud App Catalog (26,000+ apps)
    ├── Applies risk scoring (GDPR, SOC2, ISO27001 compliance markers)
    ├── Tags apps: Sanctioned / Unsanctioned / Monitored
    └── Generates Shadow IT report
```

### 2. App Connector Pipeline (Sanctioned Apps)

```
MDA → OAuth 2.0 connection to app API
    │
    ├── Pulls activity logs (sign-ins, file access, sharing, admin changes)
    ├── Pulls user list and permissions
    ├── Enforces Governance Actions (suspend user, revoke sharing, quarantine file)
    └── Feeds Activity log in MDA portal
```

**Supported connectors (native):** Microsoft 365, Entra ID, Azure, Salesforce, ServiceNow, Box, Dropbox, GitHub, Google Workspace, Okta, Slack, Workday, Zendesk

### 3. Conditional Access App Control (Session Control)

```
User → Browser → SaaS App login page
                    │
                    ▼
            Entra ID Conditional Access
                    │ (Grant: Use Conditional Access App Control)
                    ▼
            MDA Reverse Proxy (*.mca.ms / *.mcas.ms)
                    │
                    ├── Inspects HTTP session in real-time
                    ├── Enforces Session Policies:
                    │       - Block download/upload
                    │       - Require step-up auth
                    │       - Watermark documents
                    │       - DLP scan on upload
                    └── Passes allowed traffic to SaaS app
```

### Policy Evaluation Engine

```
Incoming event (API or session)
        │
        ▼
MDA Policy Engine
        ├── Activity Policy → alert on specific actions (admin changes, mass download)
        ├── Access Policy → block/allow at access time (before session starts)
        ├── Session Policy → inspect/control mid-session (download, upload, paste)
        ├── File Policy → scan content, apply labels, quarantine
        └── Anomaly Detection → ML-based (impossible travel, impossible activity)
                │
                ▼
        Alert → SIEM (Sentinel) / Email / Teams / Power Automate
        Governance Action → Auto-remediation
```

</details>

---

## Dependency Stack

```
Microsoft 365 / Entra ID tenant
        │
Microsoft Defender for Cloud Apps portal (security.microsoft.com)
        │
        ├── Cloud Discovery
        │       ├── MDE Integration (preferred — agentless for enrolled endpoints)
        │       └── Log Collector (Docker/VM — for non-MDE traffic)
        │
        ├── App Connectors
        │       └── OAuth tokens to each connected SaaS app
        │
        └── App Control (CAAC)
                ├── Entra ID Conditional Access (required — redirect to proxy)
                ├── MDA Reverse Proxy (*.mca.ms)
                └── Browser compatibility (Chrome, Edge, Safari — not embedded browsers)
```

**Critical external dependencies:**
- `*.mca.ms` and `*.mcas.ms` must be reachable from client browsers (Session Control)
- `portal.cloudappsecurity.com` (legacy) and `security.microsoft.com` (unified)
- MDE endpoints must have network connectivity for Cloud Discovery telemetry upload

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Shadow IT report shows no data | MDE Cloud Discovery not enabled, or log collector offline | MDA Settings → Cloud Discovery → Data Sources |
| Apps not appearing in catalog | New app not yet indexed (26K catalog has coverage gaps) | Manual risk assessment required |
| Session policy not triggering | CA policy not redirecting to MDA proxy, or browser unsupported | Check CA sign-in logs for `mca.ms` redirect |
| Users bypass session control | Native app or thick client used instead of browser | Session control only works for browser sessions |
| App connector shows error | OAuth token expired or revoked | Reconnect app connector in MDA portal |
| Anomaly alert — impossible travel | VPN/proxy making user appear in multiple geo-locations | Validate with user; add IP range tag (Corporate, VPN) |
| File policy not finding DLP matches | Sensitivity labels not scanned, or connector lacks file permissions | Check connector permissions; enable content inspection |
| Governance actions not executing | Insufficient API permissions on connected app | Review connector permissions in MDA |
| MDA alerts not appearing in Sentinel | Sentinel MDA connector not enabled, or data connector misconfigured | Check Sentinel → Data Connectors → Microsoft Defender for Cloud Apps |
| "Unsanctioned" tag not blocking | Block script not deployed, or Cloud Discovery blocking not enabled | MDA → Cloud Discovery → App → Tag → Generate Block Script |

---

## Validation Steps

**1. Confirm MDA licensing**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -like "*MCAS*" -or $_.ServicePlans.ServicePlanName -like "*CloudAppSecurity*" } |
    Select-Object SkuPartNumber, @{N="Status";E={($_.ServicePlans | Where ServicePlanName -like "*MCAS*").ProvisioningStatus}}
```

**2. Confirm MDE Cloud Discovery integration**
```powershell
# Check in MDA Portal: Settings → Cloud Discovery → Microsoft Defender for Endpoint
# Validate via MDE — devices must be onboarded to MDE first
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -Select displayName,complianceState | 
    Measure-Object | Select-Object Count
```

**3. Test session control redirect**
```
# From a browser, navigate to a session-controlled app (e.g., SharePoint)
# Check URL — should show *.mca.ms or *.mcas.ms in the address bar
# Check sign-in logs in Entra ID:
# Entra ID → Sign-in logs → filter for app → look for "Conditional Access: Success" + "Session: Applied"
```

**4. Verify app connector status**
```powershell
# Via MDA REST API (requires Bearer token)
$MDABase = "https://<tenant>.portal.cloudappsecurity.com/api/v1"
# Navigate in portal: Settings → Connected apps → App connectors → check status
```

**5. Check Cloud Discovery data sources**
```
MDA Portal → Settings → Cloud Discovery → Data Sources
Verify: Last log upload time, Parser status, Record count
```

**6. Validate CA policy for session control**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgIdentityConditionalAccessPolicy | Where-Object {
    $_.SessionControls.CloudAppSecurity -ne $null
} | Select-Object DisplayName, State
```

**7. Check IP range tags (reduces false-positive anomaly alerts)**
```
MDA Portal → Settings → IP address ranges
Verify: Corporate, VPN, and cloud provider ranges are tagged
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Cloud Discovery not showing data

1. Verify MDE integration is enabled: **MDA Portal → Settings → Cloud Discovery → Microsoft Defender for Endpoint → On**
2. Confirm devices are MDE-onboarded and sending telemetry (`MDE-B.md` or `MDE-Onboarding-A.md`)
3. If using log collectors: check collector health:
   ```bash
   # On Docker-based log collector
   docker ps | grep logcollector
   docker logs <container-id> | tail -50
   ```
4. Validate log format parser matches your firewall vendor (common mismatch: Palo Alto traffic vs threat logs)
5. Allow 2-4 hours for initial data to appear after enabling MDE integration

### Phase 2: Session Control not working

1. Verify the CA policy targeting the app is set to **Session: Use Conditional Access App Control → Monitor only / Block downloads**
2. Check sign-in logs for the CA policy name and result:
   ```
   Entra ID → Sign-in Logs → filter App = <app name> → look for Session Controls Applied
   ```
3. Confirm the user is accessing via a browser (not Outlook desktop, mobile app, etc.)
4. Test with **InPrivate/Incognito** to rule out cached tokens
5. Verify the app's login domain is registered in MDA:
   ```
   MDA Portal → Cloud App Catalog → find app → check "App control" column
   ```
6. For custom/non-catalog apps: manually onboard the app in MDA App Control

### Phase 3: App connector errors

1. Re-authenticate the connector:
   ```
   MDA Portal → Settings → Connected apps → <App> → Edit → Re-authorize
   ```
2. Check if API permissions were revoked in the target SaaS app's admin console
3. For Microsoft 365 connector: verify the account used for connection has Global Admin or appropriate delegated permissions
4. Check connector activity log for specific API errors:
   ```
   MDA Portal → Activity Log → filter Source = <App> → look for error events
   ```
5. Some connectors (Salesforce, ServiceNow) require **specific API edition** — verify the app subscription includes API access

### Phase 4: Too many anomaly alerts / false positives

1. Tag corporate IP ranges to reduce impossible-travel false positives:
   ```
   MDA Portal → Settings → IP address ranges → Add range → Tag as Corporate
   ```
2. Tag VPN exit nodes similarly
3. For service accounts generating noise: create **Activity Policy exclusions** by user or IP
4. Tune anomaly detection sensitivity:
   ```
   MDA Portal → Policies → Threat detection → Anomaly detection → Sensitivity slider
   ```
5. Suppress known-good patterns with Policy exceptions (e.g., admin accounts with global travel)

### Phase 5: File policies not triggering DLP

1. Verify content inspection is enabled on the connector (requires additional API permissions)
2. Check file policy scope — ensure it's not limited to a folder that doesn't match
3. Allow 24-48 hours for initial file scan after enabling the connector
4. Verify Purview sensitivity labels are published and applied — MDA relies on label metadata for label-based file policies
5. Check MDA portal for file scan errors:
   ```
   MDA Portal → Files → look for "Inspection failed" status
   ```

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Enable MDE Cloud Discovery integration</summary>

**Scenario:** Cloud Discovery showing no data; MDE is deployed but integration not enabled.

**Steps:**
1. In Microsoft Defender portal (`security.microsoft.com`): **Settings → Cloud Apps → Cloud Discovery → Microsoft Defender for Endpoint → Toggle On**
2. Allow 2-4 hours for data population
3. Verify in **Cloud Discovery → Dashboard** — expect apps to appear within 4 hours for active endpoints

**Rollback:** Toggle the same setting Off — data stops uploading; existing discovery data retained.

</details>

<details>
<summary>Playbook 2 — Deploy session control for an app via Conditional Access</summary>

**Scenario:** Need to enforce download blocking on a SaaS app for unmanaged/BYOD devices.

**Steps:**
1. In Entra ID → **Conditional Access → New Policy**
2. Target: Users (e.g., all users or specific group) + Cloud App (e.g., SharePoint/Exchange)
3. Conditions: Device state = Not hybrid joined OR not compliant (BYOD filter)
4. Grant: **Session → Use Conditional Access App Control → Monitor only** (start here)
5. Enable policy in **Report-only** first → review sign-in logs
6. Switch to **Enabled** after validation
7. After testing, change session policy in MDA to **Block downloads**

**Rollback:** Set CA policy back to Report-only or disabled.

</details>

<details>
<summary>Playbook 3 — Unsanctioned app block script deployment</summary>

**Scenario:** Shadow IT report shows a high-risk unsanctioned app being used; want to block at the proxy/firewall level.

**Steps:**
1. MDA Portal → **Cloud Discovery → Cloud App Catalog** → find the app
2. Tag the app as **Unsanctioned**
3. Navigate to app → **Generate block script**
4. Select your firewall vendor (Cisco, Palo Alto, Zscaler, etc.)
5. Download the block script
6. Deploy to your firewall/proxy management system
7. After deployment, verify in Cloud Discovery → traffic to the app decreases

```powershell
# PowerShell — list all unsanctioned apps via MDA API (requires API token)
$Headers = @{ Authorization = "Token <your-mda-api-token>" }
$Response = Invoke-RestMethod -Uri "https://<tenant>.portal.cloudappsecurity.com/api/v1/discovery/discovered_apps/?filter[sanction_state]=0" -Headers $Headers
$Response.data | Select-Object name, risk_score, total_users, total_traffic | Sort-Object total_traffic -Descending
```

**Rollback:** Remove block script entries from firewall/proxy; retag app as Monitored.

</details>

<details>
<summary>Playbook 4 — Reconnect a failed app connector</summary>

**Scenario:** App connector (e.g., Salesforce) shows error or stale last-sync time.

```powershell
# Step 1: Identify connector state via MDA API
$Headers = @{ Authorization = "Token <your-mda-api-token>" }
$Apps = Invoke-RestMethod -Uri "https://<tenant>.portal.cloudappsecurity.com/api/v1/cas_apps/" -Headers $Headers
$Apps.data | Select-Object name, status, last_log_time

# Step 2: Re-authorize in portal (no PowerShell equivalent — must be done in MDA portal)
# MDA Portal → Settings → Connected apps → App Connectors → <App> → Edit → Re-authorize

# Step 3: Verify reconnection
Start-Sleep -Seconds 300  # Wait 5 minutes
$Apps = Invoke-RestMethod -Uri "https://<tenant>.portal.cloudappsecurity.com/api/v1/cas_apps/" -Headers $Headers
$Apps.data | Where-Object name -like "<app-name>" | Select-Object name, status, last_log_time
```

**Rollback:** If re-authorization causes issues, disconnect the connector temporarily: **MDA Portal → Settings → Connected apps → <App> → Disconnect**.

</details>

---

## Evidence Pack

```powershell
# MDA Evidence Collection Script
# Run from admin workstation with Graph permissions
# Requires: Microsoft.Graph module, MDA API token

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MDAToken,
    [string]$Tenant,
    [string]$OutputPath = "C:\Temp\MDA-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

function Write-Status { param([string]$Msg,[string]$Status="INFO") Write-Host "[$Status] $Msg" -ForegroundColor $(switch($Status){"OK"{"Green"}"WARN"{"Yellow"}"ERROR"{"Red"}default{"Cyan"}}) }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$Headers = @{ Authorization = "Token $MDAToken" }
$BaseUrl = "https://$Tenant.portal.cloudappsecurity.com/api/v1"

# Licensing
Write-Status "Collecting licensing info..."
Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome 2>$null
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -like "*MCAS*" -or $_.ServicePlans.ServicePlanName -like "*CloudAppSecurity*" } |
    Export-Csv "$OutputPath\licensing.csv" -NoTypeInformation

# CA policies for session control
Write-Status "Collecting CA session control policies..."
Connect-MgGraph -Scopes "Policy.Read.All" -NoWelcome 2>$null
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.SessionControls.CloudAppSecurity -ne $null } |
    Select-Object DisplayName, State, @{N="SessionControl";E={$_.SessionControls.CloudAppSecurity}} |
    Export-Csv "$OutputPath\ca_session_policies.csv" -NoTypeInformation

# Connected apps
Write-Status "Collecting connected app status..."
try {
    $Apps = Invoke-RestMethod -Uri "$BaseUrl/cas_apps/" -Headers $Headers
    $Apps.data | Select-Object name, status, last_log_time, sanction_state |
        Export-Csv "$OutputPath\connected_apps.csv" -NoTypeInformation
} catch { Write-Status "Could not query MDA API: $_" "WARN" }

# Cloud Discovery sources
Write-Status "Collecting discovery data source info..."
try {
    $Sources = Invoke-RestMethod -Uri "$BaseUrl/discovery/data_sources/" -Headers $Headers
    $Sources.data | Select-Object name, status, last_updated_at, records_count |
        Export-Csv "$OutputPath\discovery_sources.csv" -NoTypeInformation
} catch { Write-Status "Could not query discovery sources: $_" "WARN" }

Write-Status "Evidence collected to: $OutputPath" "OK"
Write-Status "Files: $(Get-ChildItem $OutputPath | Measure-Object | Select-Object -ExpandProperty Count)" "OK"
```

---

## Command Cheat Sheet

| Task | Method |
|------|--------|
| Open MDA portal | `security.microsoft.com` → Cloud Apps |
| Check licensing | `Get-MgSubscribedSku \| Where ServicePlans.ServicePlanName -like "*MCAS*"` |
| List CA session policies | `Get-MgIdentityConditionalAccessPolicy \| Where SessionControls.CloudAppSecurity -ne $null` |
| View discovery data sources | MDA Portal → Settings → Cloud Discovery → Data Sources |
| View connected apps | MDA Portal → Settings → Connected Apps → App Connectors |
| Tag IP range | MDA Portal → Settings → IP Address Ranges → Add |
| Generate block script | MDA Portal → Cloud App Catalog → Tag Unsanctioned → Generate Block Script |
| View activity log | MDA Portal → Activity Log (filter by App, User, Time) |
| View alerts | `security.microsoft.com` → Cloud Apps → Alerts |
| View files | MDA Portal → Files (requires connected app with file permissions) |
| MDA API base URL | `https://<tenant>.portal.cloudappsecurity.com/api/v1` |
| Get API token | MDA Portal → Settings → Security extensions → API tokens |

---

## 🎓 Learning Pointers

- **MDA = CASB + UEBA + SaaS Security:** Microsoft Defender for Cloud Apps is a Cloud Access Security Broker (CASB) with User and Entity Behavior Analytics (UEBA). It's not a traditional endpoint security tool — it secures the *data path* between users and cloud apps. Understanding this distinction helps with scoping what it can and cannot protect. Reference: [MDA Architecture](https://learn.microsoft.com/en-us/defender-cloud-apps/what-is-defender-for-cloud-apps)

- **Session Control only covers browsers:** The reverse-proxy architecture of Conditional Access App Control only intercepts browser-based sessions. Native mobile apps, thick clients (e.g., Outlook desktop), and API connections bypass session control entirely. For comprehensive coverage, combine MDA session control with Intune app protection policies (MAM) for mobile and MDE for endpoint-level controls.

- **IP tagging dramatically reduces alert noise:** Anomaly detection fires on impossible travel and other geo-anomalies. Without tagging your corporate office IPs, VPN exit nodes, and cloud provider ranges, every VPN user generates false-positive impossible travel alerts. Tag these ranges on day one. MDA Portal → Settings → IP Address Ranges. See: [MDA IP Ranges](https://learn.microsoft.com/en-us/defender-cloud-apps/ip-tags)

- **MDE integration is the preferred Cloud Discovery source:** Unlike log collectors (which require a VM/Docker container and firewall syslog forwarding), MDE integration is agent-based and zero-infrastructure. If your endpoints are MDE-onboarded, enable the integration and you get Shadow IT visibility for all Windows 10/11 endpoints immediately. Reference: [MDE Cloud Discovery Integration](https://learn.microsoft.com/en-us/defender-cloud-apps/mde-integration)

- **Governance actions are irreversible in some apps:** MDA can auto-execute governance actions like suspending a user in Salesforce or revoking OAuth tokens. In production, always start with policies in **Alert only** mode before enabling auto-governance — a misconfigured file policy in alert-only mode is recoverable; one that auto-quarantines files is not. Document and test every governance action in a non-production tenant first.

- **MDA logs integrate with Microsoft Sentinel:** Enable the MDA data connector in Sentinel to feed alerts and activity logs into your SIEM. This enables correlation with MDE endpoint alerts, Entra sign-in anomalies, and Purview DLP events — providing a unified insider threat detection capability. Reference: [Sentinel MDA Connector](https://learn.microsoft.com/en-us/azure/sentinel/connect-cloud-app-security)
