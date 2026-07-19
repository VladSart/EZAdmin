# Insider Risk Management — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Microsoft Purview Insider Risk Management (IRM) in Microsoft 365 E5 / Compliance add-on tenants
- Policy creation, indicator configuration, alert triage, and case management
- Adaptive Protection integration with Conditional Access
- HRMS connector integration for offboarding triggers
- Graph API and PowerShell management

**Out of scope:**
- Purview Communication Compliance (separate module)
- Microsoft Sentinel Insider Risk connectors (covered in Sentinel runbooks)
- UEBA from third-party tools

**Assumed baseline:**
- Microsoft 365 E5 or E5 Compliance license assigned to users
- Insider Risk Management Admin or Analyst role assigned in Purview
- Audit log enabled in the tenant
- At least one IRM policy active and monitoring users

---

## How It Works

<details><summary>Full architecture</summary>

### Signal Ingestion Pipeline

```
User Activity (M365 services)
        │
        ├── Exchange Online (email exfil signals)
        ├── SharePoint/OneDrive (file download, share, delete)
        ├── Teams (chat, file transfer)
        ├── Endpoint DLP (device-level file copy/print/USB)
        ├── Microsoft Defender for Endpoint (process events)
        └── HRMS Connector (offboarding, leave events) [optional]
        │
        ▼
Microsoft 365 Audit Log (UAL)
        │
        ▼
Insider Risk Management Engine
        │
        ├── Policy Evaluation (which users are in scope?)
        ├── Indicator Scoring (how risky is this activity?)
        ├── Sequence Detection (does this form a pattern?)
        ├── Machine Learning Baseline (unusual vs normal for this user)
        └── Cumulative Exfiltration Detection
        │
        ▼
Risk Score → Alert Generation
        │
        ├── Low (informational)
        ├── Medium (review recommended)
        └── High (immediate review)
        │
        ▼
Alert Queue → Triage → Case (if escalated) → eDiscovery (if legal hold needed)
```

### Policy Types

| Policy Template | Trigger | Primary Signals |
|----------------|---------|-----------------|
| Data theft by departing user | HR connector offboarding event OR manual trigger | File download volume, USB copy, personal cloud upload |
| Data leaks by priority users | Always-on (no trigger) | Exfiltration patterns above user baseline |
| Data leaks by risky users | Low DLP match count | Post-violation exfiltration |
| Security policy violations | MDE alert | Disabled security tools, malware dropped |
| Offensive language | Communication Compliance finding | N/A (separate module) |
| Patient data misuse | Teams/SPO access to sensitive data | Unusual access patterns |
| General data leaks | Always-on | All exfiltration channels |

### Risk Score Mechanics

- Each indicator has a configurable weight (Low/Medium/High)
- Scores are cumulative within a policy window (30/60/90 days configurable)
- Machine learning establishes a **user baseline** from 90 days of historical activity
- A **sequence boost** multiplies scores when multiple indicators occur in close temporal proximity (e.g., large download + USB copy + personal email send within 24 hours)
- Scores above configured thresholds generate alerts

### Adaptive Protection

When Adaptive Protection is enabled, IRM risk levels (Minor/Moderate/Elevated — a distinct scale from alert severity, see below) feed into three separate enforcement arms: Conditional Access, DLP (Exchange/Teams/Devices only), and Data Lifecycle Management (120-day deleted-content preservation for Elevated users). Each arm ships safe-by-default (CA in Report-only, DLP in simulation mode) and must be explicitly promoted to enforce.

> **This section is intentionally brief.** For the full architecture — insider risk level vs. alert severity, Quick vs. Custom Setup, the DLP/CA/DLM three-way integration, the permissions model, and the disable/orphaned-policy lifecycle — see the dedicated **`AdaptiveProtection-A.md`** / **`AdaptiveProtection-B.md`** pair in this folder. Do not duplicate that depth here.

</details>

---

## Dependency Stack

```
Microsoft 365 Audit Log (UAL)
    │   Must be enabled tenant-wide; 90-day retention minimum
    │
    ├── Purview Audit (Standard) ──── Basic activity signals
    └── Purview Audit (Premium) ──── Detailed mail/file access, longer retention
            │
            ├── Exchange Online ── Email signals (send to personal, fwd rules)
            ├── SharePoint/OneDrive ── File signals (download, share, delete)
            ├── Teams ── Chat and file transfer signals
            ├── MDE Integration ── Endpoint signals (USB, print, process)
            │       └── Requires MDE onboarding + IRM-MDE connector enabled
            ├── HRMS Connector ── HR trigger events (offboarding date, leave)
            │       └── Optional; enables "Departing user" policies
            └── DLP Policies ── Risk-by-risky-user trigger source
                    └── Requires DLP policies generating matches

Insider Risk Management Engine
    │
    ├── Licensing: E5 Compliance or Microsoft 365 E5
    ├── Roles: Insider Risk Management (Admin/Analyst/Investigator/Viewer/Approver)
    ├── Privacy settings: pseudonymization vs plain user display
    └── Adaptive Protection (optional)
            └── Requires Conditional Access P1/P2 + IRM Adaptive Protection setup
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| No alerts generated for any policy | Audit log not enabled or signals not flowing | `Get-AdminAuditLogConfig` — UnifiedAuditLogIngestionEnabled = True |
| Policy shows 0 users in scope | No users match policy scope (groups/users not assigned) | Review policy → Users and groups in scope |
| Departing user policy never fires | HRMS connector not connected or resignation date not populated | Purview → Data connectors → HR connector status |
| Alert count suddenly drops to zero | Policy turned off, indicator weights zeroed, or audit log gap | Check policy status + audit log health |
| MDE signals missing from alerts | IRM–MDE connector not enabled | Security portal → Settings → IRM integration |
| User activity shows in audit but not IRM | User not licensed for E5 Compliance | Verify license assignment |
| Adaptive Protection not applying CA restrictions | Adaptive Protection not configured end-to-end | Purview → Adaptive Protection → Status |
| Case evidence (content) unavailable in case | User mailbox/SPO not covered by hold or eDiscovery scope | Check case → Evidence → Content locations |
| False positive storm after policy change | Indicators set too sensitive or weights too high | Review indicator configuration and tune thresholds |
| Pseudonymization preventing user identification | Privacy setting is on; requires Analyst+ role to de-anonymize | Purview → IRM Settings → Privacy |

---

## Validation Steps

**1. Confirm audit log is enabled and healthy**
```powershell
Connect-ExchangeOnline
$config = Get-AdminAuditLogConfig
$config.UnifiedAuditLogIngestionEnabled  # Must be True

# Check recent audit log entries exist
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -RecordType SharePointFileOperation -ResultSize 5
```
Expected: Returns results. If empty, audit pipeline may be broken or no activity occurred.

**2. Verify IRM license coverage**
```powershell
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All"
$users = Get-MgUser -All -Property DisplayName,Id,AssignedLicenses
$e5sku = "06ebc4ee-1bb5-47dd-8120-11324bc54e06"  # M365 E5 SkuId
$users | Where-Object { $_.AssignedLicenses.SkuId -contains $e5sku } | Measure-Object
```
Expected: Count matches users expected to be in IRM scope.

**3. Check HRMS connector status**
```powershell
# Requires Graph — check via portal or:
Connect-MgGraph -Scopes "InformationProtectionPolicy.Read.All"
# Navigate: Purview portal → Data connectors → HR → Last sync time
```
Expected: Last sync within 24 hours; no errors shown.

**4. Verify MDE–IRM integration**
```powershell
# In Microsoft Defender portal:
# Settings → Endpoints → Advanced features → Insider Risk Management
# Toggle should be On
# Also check: Purview → IRM Settings → Microsoft Defender for Endpoint integration = Enabled
```

**5. Confirm a user is in an active policy**
```powershell
# PowerShell module: SecurityComplianceCenter
Connect-IPPSSession
Get-InsiderRiskPolicy | Select-Object Name, IsEnabled, CreatedDateTime | Format-Table
```
Expected: Relevant policies show IsEnabled = True.

**6. Validate Adaptive Protection end-to-end**
```powershell
# Check if Adaptive Protection is enabled
# Purview portal → Adaptive Protection → Status = Active
# Then verify CA policy exists referencing "Insider Risk level"
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.Users.IncludeGuestsOrExternalUsers -or $_.DisplayName -like "*Insider*" }
```

---

## Troubleshooting Steps (by phase)

### Phase 1: No Signals / No Alerts

**Step 1 — Confirm UAL ingestion**
```powershell
Connect-ExchangeOnline
(Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled
```
If False: Enable with `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true`
Allow 24–72 hours for backfill.

**Step 2 — Confirm policy is enabled and has users in scope**
```powershell
Connect-IPPSSession
Get-InsiderRiskPolicy | Select Name, IsEnabled
```
Review policy scope in the portal: Purview → IRM → Policies → [Policy] → Users and Groups.

**Step 3 — Confirm audit record types are generating**
```powershell
Connect-ExchangeOnline
# Test file download signal
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) `
    -RecordType SharePointFileOperation -Operations FileDownloaded -ResultSize 10
```
If empty despite real activity: check SharePoint auditing is not suppressed by a compliance hold misconfiguration.

**Step 4 — Check indicator selection in policy**
Navigate: Purview → IRM → Settings → Policy indicators.
Ensure relevant indicators are turned **on** at the tenant level first, then confirmed in the policy.
Common miss: Endpoint indicators require MDE integration AND the endpoint indicator toggle ON.

---

### Phase 2: Alerts Generated But Incorrect / Noisy

**Step 5 — Review alert severity distribution**
```powershell
Connect-IPPSSession
Get-InsiderRiskAlert | Group-Object Severity | Format-Table
```
If all alerts are High: indicator weights may be misconfigured. Review and reduce weights for low-signal indicators.

**Step 6 — Check sequence detection thresholds**
Purview → IRM → Settings → Intelligent detections → Sequence detection.
If sequence boost is causing false positives for normal bulk operations (e.g., developers running large file syncs), add exclusion groups or raise the sequence threshold.

**Step 7 — Review anomaly detection settings**
Purview → IRM → Settings → Intelligent detections → Unusual activity detection.
Verify the activity volume threshold matches your org's normal baseline. Initial 30-day calibration period must complete before scores are reliable.

---

### Phase 3: HRMS Connector Failures

**Step 8 — Check connector job status**
Purview portal → Data connectors → HR connector → Job execution history.
Look for: Error or Warning status, timestamp of last successful run.

**Step 9 — Validate CSV format**
HRMS connector expects a specific CSV schema:
```
EmailAddress,ResignationDate,LastWorkingDate,ManagerEmailAddress,WorkflowType,OptionalData
user@domain.com,2026-06-15,2026-06-30,manager@domain.com,HRSignal,
```
Run a test upload via: Purview → Data connectors → HR → Import a file.

**Step 10 — Re-authenticate connector app registration**
If the connector App Registration secret has expired:
1. Azure portal → App Registrations → [HR Connector app] → Certificates & secrets
2. Create new client secret
3. Update secret in Purview → Data connectors → HR connector → Edit

---

### Phase 4: Adaptive Protection Issues

**Step 11 — Verify risk level assignments**
Purview → Adaptive Protection → Current risk levels.
Check that users have a risk level assigned (Minor/Moderate/Elevated).
If no users show risk levels: IRM must have generated alerts for those users first.

**Step 12 — Verify CA policy references IRM risk**
Azure AD / Entra portal → Conditional Access → Policies.
Find the policy targeting Insider Risk. Confirm:
- Condition: Insider Risk = Elevated (or Moderate)
- Grant: Block access OR Require compliant device

**Step 13 — Test Adaptive Protection impact**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All","AuditLog.Read.All"
# Check sign-in logs for a user with an assigned insider risk level
Get-MgAuditLogSignIn -Filter "userPrincipalName eq 'user@domain.com'" -Top 20 |
    Select-Object CreatedDateTime, AppDisplayName, ConditionalAccessStatus
```
> **Caution:** `RiskLevelAggregated` on sign-in logs and `Get-MgRiskyUser` belong to **Entra ID Protection** (`userRiskLevels`/`signInRiskLevels`) — a separate risk engine, not Adaptive Protection's `insiderRiskLevels`. Confirm CA policy state via `AdaptiveProtection-A.md`'s Command Cheat Sheet instead of relying on Identity Protection fields for insider-risk conclusions — see `AdaptiveProtection-B.md` Fix 7 for the full gotcha.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Enable IRM for first time (new policy)</summary>

**Prerequisites:** E5 license, Global Admin or Compliance Admin role.

```powershell
# Step 1: Enable audit log
Connect-ExchangeOnline
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true

# Step 2: Enable IRM indicators at tenant level
# Purview portal → IRM → Settings → Policy indicators → Enable all relevant indicators
# (Cannot be done via PowerShell — portal only)

# Step 3: Create policy via portal
# Purview → IRM → Policies → Create policy → Choose template
# Recommended starting template: "Data leaks by priority users"

# Step 4: Scope to a pilot group first
# Add a group of ~50 users, not all users

# Step 5: Verify after 48 hours
Connect-IPPSSession
Get-InsiderRiskAlert -AlertStatus NeedsReview | Measure-Object
```

**Timeline:** Expect first alerts within 24–72 hours of activity after policy activation.

</details>

<details><summary>Playbook 2 — Tune noisy policy</summary>

```powershell
# 1. Export current alert volume by indicator
Connect-IPPSSession
$alerts = Get-InsiderRiskAlert -AlertStatus NeedsReview
$alerts | Select-Object AlertId, Severity, CreatedDateTime | Export-Csv -Path C:\Temp\IRM-Alerts.csv -NoTypeInformation

# 2. Review in portal: Alerts → Filter by severity High
# Identify which indicators are firing most

# 3. Reduce indicator weight for noisy indicators
# Purview → IRM → Policies → [Policy] → Indicators → Set to Medium or Low weight

# 4. Add exclusion groups for service accounts / admin users
# Purview → IRM → Settings → Policy indicators → Exclusion groups
```

**Rollback:** Weight changes take effect immediately. Increase back to High if too many true positives are missed.

</details>

<details><summary>Playbook 3 — Respond to high-severity insider risk alert</summary>

```powershell
# 1. Review alert in portal
# Purview → IRM → Alerts → [Alert] → View activity (timeline)

# 2. Check user's recent exfiltration activity
Connect-ExchangeOnline
Search-UnifiedAuditLog -UserIds "user@domain.com" `
    -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
    -Operations "FileDownloaded,FileCopiedToUsb,Send,SendAs" `
    -ResultSize 500 | Export-Csv C:\Temp\UserActivity.csv -NoTypeInformation

# 3. If confirmed incident — escalate to case
# Purview → IRM → Alerts → [Alert] → Create case
# Case: Add evidence, add notes, assign investigator

# 4. If legal hold needed
# Purview → IRM → Case → [Case] → eDiscovery → Create hold

# 5. Notify HR/Legal (out-of-band — do not use IRM notifications to warn suspect)
```

**Rollback:** Cases can be closed without action. Holds must be explicitly released.

</details>

<details><summary>Playbook 4 — Configure HRMS connector</summary>

```powershell
# Step 1: Create app registration
# Azure portal → App Registrations → New
# Note: Application ID, Tenant ID
# Create client secret, note value (shown once)

# Step 2: Assign permissions
# API permissions → Add → Microsoft APIs → Office 365 Management APIs
# Application permission: ActivityFeed.Read, ActivityFeed.ReadDlp
# Grant admin consent

# Step 3: Create connector in Purview
# Purview → Data connectors → HR → Add connector
# Enter: App ID, Tenant ID, Client Secret

# Step 4: Prepare CSV and upload
$csv = @"
EmailAddress,ResignationDate,LastWorkingDate,ManagerEmailAddress,WorkflowType
user@domain.com,2026-07-01,2026-07-15,mgr@domain.com,HRSignal
"@
$csv | Out-File C:\Temp\hrms-import.csv -Encoding UTF8
# Upload via Purview → Data connectors → HR → Import file

# Step 5: Automate with Logic App or scheduled task
# Re-upload daily with current HR data for ongoing triggering
```

</details>

---

## Evidence Pack

```powershell
#Requires -Modules ExchangeOnlineManagement, Microsoft.Graph

function Get-IRMEvidencePack {
    param([string]$TenantName = "CUSTOMER")

    Write-Host "=== IRM Evidence Pack — $TenantName ===" -ForegroundColor Cyan
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportPath = "C:\Temp\IRM-Evidence-$TenantName-$timestamp"
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

    # 1. Audit log status
    Connect-ExchangeOnline -ShowProgress $false
    $auditConfig = Get-AdminAuditLogConfig
    [PSCustomObject]@{
        UnifiedAuditLogEnabled = $auditConfig.UnifiedAuditLogIngestionEnabled
        AuditLogAgeLimit       = $auditConfig.AuditLogAgeLimit
    } | Export-Csv "$reportPath\AuditConfig.csv" -NoTypeInformation
    Write-Host "[OK] Audit config exported"

    # 2. Policy list
    Connect-IPPSSession
    Get-InsiderRiskPolicy | Select-Object Name, IsEnabled, CreatedDateTime, ModifiedDateTime |
        Export-Csv "$reportPath\IRM-Policies.csv" -NoTypeInformation
    Write-Host "[OK] Policies exported"

    # 3. Alert summary (last 30 days)
    Get-InsiderRiskAlert -AlertStatus NeedsReview | Select-Object AlertId, Severity, CreatedDateTime, AlertPolicies |
        Export-Csv "$reportPath\IRM-Alerts-Open.csv" -NoTypeInformation
    Write-Host "[OK] Open alerts exported"

    # 4. Recent audit log sample
    $auditSample = Search-UnifiedAuditLog `
        -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) `
        -RecordType SharePointFileOperation -ResultSize 100
    $auditSample | Export-Csv "$reportPath\AuditLog-SPO-7d.csv" -NoTypeInformation
    Write-Host "[OK] Audit sample exported"

    Write-Host "`nEvidence pack saved to: $reportPath" -ForegroundColor Green
}

Get-IRMEvidencePack -TenantName "<CUSTOMER_NAME>"
```

---

## Command Cheat Sheet

```powershell
# --- Policy Management ---
# List all IRM policies
Connect-IPPSSession
Get-InsiderRiskPolicy | Select Name, IsEnabled, CreatedDateTime

# Enable a policy
Set-InsiderRiskPolicy -Identity "Policy Name" -Enabled $true

# Get alert queue
Get-InsiderRiskAlert -AlertStatus NeedsReview

# Filter alerts by severity
Get-InsiderRiskAlert -AlertStatus NeedsReview | Where-Object { $_.Severity -eq "High" }

# --- Audit Log Checks ---
# Check audit log is on
Connect-ExchangeOnline
(Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled

# Search audit log for specific user
Search-UnifiedAuditLog -UserIds "user@domain.com" -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) -ResultSize 100

# Search for file download activity
Search-UnifiedAuditLog -Operations FileDownloaded,FileUploaded -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 100

# --- Graph API (IRM) ---
# Get IRM alerts via Graph
Connect-MgGraph -Scopes "SecurityEvents.Read.All"
Get-MgSecurityAlert -Filter "category eq 'insiderRisk'" -Top 20

# --- Licensing ---
# Find users without E5 Compliance
Connect-MgGraph -Scopes "User.Read.All"
$compSku = "184efa21-98c3-4e5d-95ab-d07053a96e67"  # E5 Compliance SkuId
Get-MgUser -All | Where-Object { $_.AssignedLicenses.SkuId -notcontains $compSku }
```

---

## 🎓 Learning Pointers

- **Audit log is the foundation.** IRM has no signal without the Unified Audit Log. Enable it immediately on new tenants and verify it monthly — it can silently fail if the org moves to a new subscription tier. [UAL management](https://learn.microsoft.com/en-us/purview/audit-log-enable-disable)

- **The 90-day calibration period matters.** IRM's machine learning model needs 90 days of baseline activity per user before anomaly detection is reliable. Alerts in the first 90 days skew high; expect tuning. [IRM analytics](https://learn.microsoft.com/en-us/purview/insider-risk-management-analytics)

- **Adaptive Protection is the highest-value integration** — it converts a detected risk into automatic DLP/CA/DLM enforcement within minutes, before an investigator even sees the alert. Set it up alongside any E5 IRM deployment. For full setup, troubleshooting, and the insider-risk-level-vs-alert-severity distinction, see `AdaptiveProtection-A.md`. [Adaptive Protection docs](https://learn.microsoft.com/en-us/purview/insider-risk-management-adaptive-protection)

- **Pseudonymization is a double-edged sword.** Turned on by default to protect employee privacy during triage, it means analysts see obfuscated names. Only Insider Risk Management (Admin) role can de-anonymize. Communicate this to your SOC team before they escalate confused. [Privacy settings](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings-policy-indicators)

- **HRMS connector unlocks the most powerful policies.** The "Departing user" template generates significantly more actionable alerts than always-on policies because it focuses signal around the highest-risk period. Budget time to connect HR data. [HR connector setup](https://learn.microsoft.com/en-us/purview/import-hr-data)

- **IRM is not a forensics tool.** It surfaces risk signals and timelines — it does not retain content. When a case reaches legal hold territory, integrate with Purview eDiscovery immediately. Content not under hold is at risk of deletion. [eDiscovery integration](https://learn.microsoft.com/en-us/purview/insider-risk-management-cases)
