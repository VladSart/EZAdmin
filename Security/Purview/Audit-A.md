# Purview Audit (Unified Audit Log) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**Covers:**
- Microsoft Purview Audit (Standard) and Audit (Premium) — the unified audit log underlying nearly every other Purview solution in this repo
- The four retrieval methods: Purview portal Audit search (New Search), the Audit Search Graph API, the `Search-UnifiedAuditLog` cmdlet, and the Office 365 Management Activity API
- Retention behavior (180-day Standard default, 1-year Premium default for AAD/Exchange/OneDrive/SharePoint, up to 10-year add-on) and custom audit log retention policies
- Mailbox-level audit configuration, including `Set-MailboxAuditBypassAssociation`
- Licensing gates between Standard and Premium, including per-actor "intelligent insight" properties

**Does not cover:**
- eDiscovery search and hold mechanics (a downstream consumer of the audit log for its own action trail — see `eDiscovery-A.md`)
- Insider Risk Management and Communication Compliance signal ingestion (both *depend on* the audit log as a prerequisite, but their policy engines are covered in their own runbooks — see `Insider-Risk-A.md`, `CommunicationCompliance-A.md`)
- Microsoft Entra ID sign-in and audit logs surfaced natively in the Entra portal (a separate, Entra-specific log with its own retention — see `EntraID/_AGENT.md` for Entra-side diagnostics; this runbook covers the unified, cross-workload Purview audit log)

**Assumed:** You have Compliance Administrator, Audit Logs, or View-Only Audit Logs role and can connect to Security & Compliance PowerShell:
```powershell
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>
```

---
## How It Works

<details><summary>Full architecture — how an activity becomes a searchable audit record</summary>

### Audit (Standard) vs. Audit (Premium)

Audit (Premium) is a strict superset of Audit (Standard) — every Standard capability is included, Premium adds four things on top:

| Capability | Standard | Premium |
|---|---|---|
| Enabled by default | Yes | Yes |
| Thousands of searchable event types | Yes | Yes |
| Portal search, Graph API, `Search-UnifiedAuditLog`, export to CSV | Yes | Yes |
| 180-day retention | Yes | Yes |
| Up to 1-year retention (AAD/Exchange/OneDrive/SharePoint) | No | Yes (default policy) |
| Up to 10-year retention | No | Yes (requires separate per-user add-on license) |
| Custom audit log retention policies | No | Yes |
| Intelligent insights (high-value activity properties) | No | Yes |
| Higher-bandwidth Management Activity API access | No | Yes (~2x baseline, scales with seat count) |

Both tiers are **enabled by default** — there is no "turn on Audit Standard" step for a normal tenant. What changes with Premium is retention depth, policy flexibility, and the richness of certain event properties, not whether logging happens at all.

---

### The Ingestion Pipeline

```
User/admin/service performs an action in a Microsoft 365 workload
  (Exchange, SharePoint, OneDrive, Teams, Entra ID, Power Platform, Purview
   solutions themselves, Dynamics 365, Defender, and dozens more)
        │
        ▼
Workload emits an audit event → central auditing pipeline
        │
        ▼
Pipeline validates against org-level gates:
  - UnifiedAuditLogIngestionEnabled (tenant-wide switch, on by default)
  - Per-mailbox AuditBypassEnabled (mailbox-level opt-out, off by default)
        │
        ▼
Event is indexed and becomes searchable
  (typical latency: 30 min – 24 hrs; NOT instantaneous, NOT a fixed SLA)
        │
        ▼
Retained per the effective retention policy:
  - No custom policy → default: 180 days (Standard) or
    1 year for AAD/Exchange/OneDrive/SharePoint workloads (Premium default policy)
  - Custom policy (Premium only) → up to 10 years with per-user add-on
        │
        ▼
Retrievable via 4 independent paths (see below) — each hits the SAME
underlying store, but has different limits, latency, and intended use case
```

**Why "180 days" isn't universally true:** the retention period is a property of the record's Workload and any applicable retention policy — not a single tenant-wide number. Exchange/SharePoint/OneDrive/Entra ID records on a Premium tenant get 1 year by default even with zero custom policies configured, because Premium ships with a **default audit log retention policy** covering those four workloads specifically. Everything else on a Premium tenant, and everything on a Standard tenant, falls back to 180 days unless a custom policy says otherwise.

---

### The Four Retrieval Methods — and when to use each

| Method | Best for | Hard limits |
|---|---|---|
| **Purview portal Audit search** (New Search — Classic retired 30 Nov 2023) | Quick lookups, short time ranges, ad-hoc investigation by a human | UI pagination; impractical for tens of thousands of results |
| **Audit Search Graph API** | Programmatic access, app integrations, modern automation | Standard Graph throttling; requires `AuditLogsQuery.Read.All` or similar |
| **`Search-UnifiedAuditLog` cmdlet** | Manual/scripted pulls for a specific investigation, moderate volume | **100 records by default** (silent); **5,000 per page** with `-ResultSize`; **50,000 hard ceiling per session** even with `-SessionCommand ReturnLargeSet` |
| **Office 365 Management Activity API** | Continuous, high-volume ingestion (SIEM, long-term archival, compliance pipelines) | Throttled by requests/minute, not record count — baseline 2,000 req/min, ~2x for Premium/high-seat orgs; this is the only method built for sustained, large-scale pulls |

The single most common operational mistake in this repo's experience: building a recurring PowerShell job around `Search-UnifiedAuditLog` for what is actually a continuous SIEM-style ingestion need. That cmdlet is explicitly documented as the tool for **manual, investigation-scoped** retrieval — not a replacement for the Management Activity API.

---

### `Search-UnifiedAuditLog` Paging Mechanics

Without any session parameters, the cmdlet returns **up to 100 records** and gives no indication that truncation occurred — this is the top root cause of "why is my result count suspiciously round/low" tickets.

Two ways to get more, and they behave differently:

**`-SessionCommand ReturnLargeSet`** — requires a `-SessionId` (any unique string you generate) shared across repeated calls. Each call returns up to 5,000 records (`ResultSize`); keep calling with the same `SessionId` until a call returns 0 records or `ResultIndex` reaches `ResultCount` for that session. Optimized for throughput over strict chronological ordering.

**`-HighCompleteness`** — no `SessionId` required; instructs the backend to prioritize exhaustiveness over search latency. Simpler to use for one-off large pulls, but slower per call.

**Both are capped at 50,000 records per session/date-range combination.** If a query returns exactly 50,000, treat that as a signal records are being cut off, not that 50,000 happens to be the true count — split the date range into smaller windows and re-run each one.

</details>

---
## Dependency Stack

```
Microsoft 365 / Office 365 subscription with Exchange Online
  └── Audit (Standard) — on by default, no enablement step normally required
        └── UnifiedAuditLogIngestionEnabled = True (tenant-wide toggle)
              ├── Per-workload audit event generation
              │     (Exchange, SharePoint, OneDrive, Teams, Entra ID, Power Platform,
              │      Defender, Purview solutions, Dynamics 365, dozens more — see
              │      "Audit log record type" reference for the full RecordType enum)
              │
              ├── Per-mailbox gate: Set-MailboxAuditBypassAssociation
              │     (off by default; commonly enabled deliberately for service accounts)
              │
              └── Ingestion pipeline (async, 30 min – 24 hr typical latency)
                    │
                    ▼
              Retention (the effective policy for a given record):
                    ├── No custom policy, Standard tenant → 180 days, all workloads
                    ├── No custom policy, Premium tenant  → 1 year for AAD/Exchange/
                    │                                        OneDrive/SharePoint
                    │                                       (default policy, Premium-only)
                    │                                        180 days everything else
                    └── Custom UnifiedAuditLogRetentionPolicy (Premium only)
                          ├── Scoped by: Workload, RecordType, or specific user
                          ├── Priority (lower number wins on overlap)
                          └── Up to 10 years — requires separate per-user
                                10-Year Audit Log Retention add-on license
                                (system/service-principal events fixed at 1 year,
                                 not configurable, custom policies don't apply)
                    │
                    ▼
              Retrieval (4 independent paths, same underlying data):
                    ├── Purview portal Audit search (New Search)
                    ├── Audit Search Graph API
                    ├── Search-UnifiedAuditLog (Exchange Online PowerShell)
                    │     └── 100-record default cap → ReturnLargeSet or HighCompleteness
                    │           → 5,000/page, 50,000/session hard ceiling
                    └── Office 365 Management Activity API
                          └── Throttled by requests/minute (2,000 baseline,
                              ~2x for Premium/high-seat tenants), not record count

Audit (Premium) — per-user license (E5 / E5 Compliance add-on / G5), gates:
  ├── Intelligent insight properties (generated only if the ACTING user is licensed)
  │     e.g. Exchange MailItemsAccessed → SensitivityLabel
  │          Teams ChatCreated/MessageSent/etc. → AppAccessContext, ParticipantInfo
  ├── Custom audit log retention policies (creation requires Premium tenant-wide)
  └── Higher Management Activity API bandwidth
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Search returns exactly 100 records | Default cmdlet cap, no session parameters used | Re-run with `-SessionCommand ReturnLargeSet` or `-HighCompleteness` |
| Search returns exactly 50,000 records | Session-level hard ceiling hit, records likely truncated | Split date range into smaller windows |
| Confirmed activity not appearing at all | Ingestion delay (< 24 hrs is normal) | Wait and re-check; confirm `UnifiedAuditLogIngestionEnabled = True` |
| One specific mailbox never shows activity | `AuditBypassEnabled = True` on that mailbox | `Get-MailboxAuditBypassAssociation -Identity <UPN>` |
| Event present but missing an expected property (e.g. `SensitivityLabel`) | Acting user lacks an Audit (Premium)-capable license | `Get-MgUserLicenseDetail -UserId <UPN>` |
| Records older than 180 days (or 1 yr) are gone | Retention expired; no custom policy existed at the time | `Get-UnifiedAuditLogRetentionPolicy`; check `Priority`/`Workload`/`RetentionDuration` |
| New retention policy created but old data still missing | Policies are **not retroactive** — they only protect records generated after creation | Confirm policy `WhenCreated` date vs. the missing record's timestamp |
| `UnifiedAuditLogIngestionEnabled = $false` tenant-wide | Someone deliberately disabled auditing, or a misconfiguration | `Get-AdminAuditLogConfig`; investigate before re-enabling |
| SIEM integration missing events / falling behind | Management Activity API throttling, or polling interval misconfigured | Check API throttling response headers; confirm Premium licensing for higher bandwidth |
| Search-UnifiedAuditLog script hangs or times out | Very large date range with small `ResultSize`/interval, or a known service-side cmdlet degradation | Reduce interval size; add retry logic; check M365 Service Health for audit search incidents |
| Graph API query returns fewer results than the portal for the same range | Different pagination/consistency model between the two front-ends | Cross-check with `Search-UnifiedAuditLog -HighCompleteness` as a tiebreaker |
| Classic Search documentation/screenshots don't match current UI | Classic Search retired 30 Nov 2023 | Redirect to New Search; verify any saved search / scheduled export was migrated |

---
## Validation Steps

**Step 1 — Confirm ingestion is enabled and has been for the relevant period**
```powershell
Get-AdminAuditLogConfig | Format-List UnifiedAuditLogIngestionEnabled
```
Expected: `True`. If disabled, nothing generated during the disabled window can ever be recovered.

**Step 2 — Confirm licensing tier (Standard vs. Premium) at the tenant level**
```powershell
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "EXCHANGE_ANALYTICS|INFORMATION_BARRIERS|M365_ADVANCED_AUDITING" } |
    Select SkuPartNumber, ConsumedUnits
```
There's no single authoritative "Premium enabled" flag exposed this way — treat this as directional and confirm in the Purview portal (Audit → Audit search) which will explicitly indicate Premium features if licensed.

**Step 3 — Confirm the acting user's individual Premium license (for intelligent insights)**
```powershell
Get-MgUserLicenseDetail -UserId "<USER_UPN>" | Select SkuPartNumber
```
Intelligent insight properties are generated **per actor**, not per tenant — a Premium tenant with an unlicensed user will still produce Standard-only records for that user's activity.

**Step 4 — Confirm mailbox-level audit bypass status for the account in question**
```powershell
Get-MailboxAuditBypassAssociation -Identity "<USER_UPN>" | Select Identity, AuditBypassEnabled
```
Expected: `False` for any account whose activity you expect to see logged.

**Step 5 — Confirm effective retention for the workload/date range being investigated**
```powershell
Get-UnifiedAuditLogRetentionPolicy | Select Name, Priority, RetentionDuration, Workload, RecordTypes
```
If no custom policy exists, default retention applies: 180 days (Standard), or 1 year for AAD/Exchange/OneDrive/SharePoint on Premium.

**Step 6 — Run a controlled search and verify paging behavior**
```powershell
$sessionId = [Guid]::NewGuid().ToString() + "_Validate"
$results = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) `
    -SessionId $sessionId -SessionCommand ReturnLargeSet -ResultSize 5000
Write-Host "Returned: $($results.Count) | Reported total: $($results[0].ResultCount)"
```
Expected: `$results.Count` should climb toward `ResultCount` across repeated calls with the same `SessionId`, not stop suspiciously at 100.

**Step 7 — Cross-check Graph API vs. cmdlet for consistency (optional, if discrepancy suspected)**
```powershell
# Requires an app registration with AuditLogsQuery.Read.All or equivalent
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/security/auditLog/queries" `
    -Body (@{
        displayName    = "Validation_$(Get-Date -Format yyyyMMddHHmm)"
        filterStartDateTime = (Get-Date).AddDays(-1).ToString("o")
        filterEndDateTime   = (Get-Date).ToString("o")
    } | ConvertTo-Json)
```
Use this only when the portal and cmdlet disagree on result counts for the same window — it's a tiebreaker, not a routine step.

---
## Troubleshooting Steps by Phase

### Phase 1 — Ingestion & Configuration

**Problem: Nothing is being logged at all**
```powershell
Get-AdminAuditLogConfig | Format-List UnifiedAuditLogIngestionEnabled

# If disabled, re-enable (investigate why it was off first)
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
```
Re-enabling does not backfill the gap — treat the disabled window as a permanent evidence gap for any investigation spanning that period.

**Problem: A specific service/automation account's activity is missing**
```powershell
Get-MailboxAuditBypassAssociation -Identity "<SERVICE_ACCOUNT_UPN>"
```
If `True`, this is very likely intentional (reduces noise from backup tools, migration scripts, compliance bots). Confirm intent with whoever owns the automation before changing it — flipping it off can flood the audit log for a high-volume account.

---

### Phase 2 — Retrieval Method Mismatches

**Problem: Result count looks suspiciously low or suspiciously exact (100 / 5,000 / 50,000)**

These are not coincidences — they're the cmdlet's default cap, page size, and session ceiling respectively.
```powershell
# 100 → add session parameters
# 5,000 (single page) → increase ResultSize up to 5000 max, or continue paging with same SessionId
# 50,000 → split the date range; you've hit the absolute per-session ceiling
```

**Problem: A recurring/scheduled job pulling audit data is unreliable or slow**

This is a tooling mismatch, not a bug to work around. `Search-UnifiedAuditLog` is documented as suited to manual, investigation-scoped pulls. For continuous ingestion:
```powershell
# Migrate to the Office 365 Management Activity API subscription model instead
# (requires an Azure AD app registration with ActivityFeed.Read permission)
$body = @{ contentType = "Audit.General" } | ConvertTo-Json
Invoke-RestMethod -Method POST `
    -Uri "https://manage.office.com/api/v1.0/<TENANT_ID>/activity/feed/subscriptions/start" `
    -Headers @{ Authorization = "Bearer $token" } -Body $body -ContentType "application/json"
```

---

### Phase 3 — Licensing & Premium Feature Gaps

**Problem: Expected "intelligent insight" property is null/missing**
```powershell
Get-MgUserLicenseDetail -UserId "<ACTOR_UPN>"
```
Confirm the *acting* user (not the admin running the search) holds an Audit (Premium)-capable license. This is one of the more counterintuitive gates in the whole Purview suite — the tenant can be fully Premium-licensed and the property will still be absent if the specific user who performed the action isn't individually licensed.

**Problem: Custom retention policy creation fails**
```powershell
New-UnifiedAuditLogRetentionPolicy -Name "Test" -RecordTypes ExchangeItem -RetentionDuration OneYear
```
If this errors on a tenant you believe is Premium-licensed, re-verify licensing in the Purview portal directly (Solutions → Audit → Retention policies) — the portal will explicitly state if the feature is gated.

---

### Phase 4 — Retention & Long-Term Investigations

**Problem: Client wants records older than the applicable retention window**

There is no recovery path. Retention is enforced at the point the record ages out of the store; a retention policy created today cannot resurrect data that already expired under a shorter or absent policy.
```powershell
# Confirm what WAS in effect historically (best available reconstruction)
Get-UnifiedAuditLogRetentionPolicy | Select Name, WhenCreated, RetentionDuration, Workload
```
Set expectations with the client accordingly, then proactively create appropriate policies so this doesn't recur:
```powershell
New-UnifiedAuditLogRetentionPolicy -Name "LongTerm-CoreWorkloads" `
    -RecordTypes AzureActiveDirectory,ExchangeAdmin,ExchangeItem,SharePointFileOperation `
    -RetentionDuration TenYears `
    -Priority 1
```
Remember the 10-year tier additionally requires the per-user 10-Year Audit Log Retention add-on license — the policy alone (Premium) only reaches 1 year without it.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full audit log pull for an investigation (paged, large date range)</summary>

```powershell
<#
.SYNOPSIS  Paged Search-UnifiedAuditLog extraction for a bounded investigation.
.NOTES     Not a replacement for the Management Activity API on recurring jobs — see Phase 2.
#>
param(
    [Parameter(Mandatory)][DateTime]$StartDate,
    [Parameter(Mandatory)][DateTime]$EndDate,
    [string]$RecordType = $null,          # $null searches all record types
    [string]$UserIds = $null,
    [int]$IntervalMinutes = 60,
    [string]$OutputFile = ".\AuditRecords_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
)

$currentStart = $StartDate
while ($currentStart -lt $EndDate) {
    $currentEnd = $currentStart.AddMinutes($IntervalMinutes)
    if ($currentEnd -gt $EndDate) { $currentEnd = $EndDate }

    $sessionId = [Guid]::NewGuid().ToString() + "_Pull" + (Get-Date -Format yyyyMMddHHmmssfff)
    $intervalTotal = 0

    do {
        $params = @{
            StartDate      = $currentStart
            EndDate        = $currentEnd
            SessionId      = $sessionId
            SessionCommand = "ReturnLargeSet"
            ResultSize     = 5000
        }
        if ($RecordType) { $params.RecordType = $RecordType }
        if ($UserIds)    { $params.UserIds    = $UserIds }

        $results = Search-UnifiedAuditLog @params

        if ($results.Count -gt 0) {
            $results | Export-Csv -Path $OutputFile -Append -NoTypeInformation
            $intervalTotal += $results.Count

            if ($intervalTotal -ge 50000) {
                Write-Warning "Hit the 50,000 session ceiling for $currentStart - $currentEnd. Narrow this interval and re-run."
                break
            }
        }
    } while ($results.Count -gt 0)

    Write-Host "$currentStart to $currentEnd : $intervalTotal records"
    $currentStart = $currentEnd
}

Write-Host "Done. Output: $OutputFile"
```

**Rollback:** Read-only extraction — nothing to roll back. Delete the output CSV if it contains sensitive data that shouldn't persist beyond the investigation.

</details>

<details><summary>Playbook 2 — Set up a defensible long-term retention baseline (Premium)</summary>

```powershell
# 1. Confirm current effective policies before changing anything
Get-UnifiedAuditLogRetentionPolicy | Select Name, Priority, Workload, RetentionDuration

# 2. Create a policy covering the highest-value workloads for compliance/legal needs
New-UnifiedAuditLogRetentionPolicy -Name "Compliance-CoreWorkloads-1Yr" `
    -RecordTypes AzureActiveDirectory,ExchangeItem,ExchangeAdmin,SharePointFileOperation `
    -RetentionDuration OneYear `
    -Priority 5

# 3. If specific users need 10-year retention, assign the add-on license first (portal or Graph),
#    then scope a dedicated policy to just those users
New-UnifiedAuditLogRetentionPolicy -Name "Legal-Custodians-10Yr" `
    -RecordTypes ExchangeItem,SharePointFileOperation `
    -RetentionDuration TenYears `
    -Priority 1 `
    -UserIds "<CUSTODIAN1_UPN>","<CUSTODIAN2_UPN>"

# 4. Verify
Get-UnifiedAuditLogRetentionPolicy | Format-Table Name, Priority, RetentionDuration, Workload
```

**Rollback:**
```powershell
Remove-UnifiedAuditLogRetentionPolicy -Identity "Compliance-CoreWorkloads-1Yr" -Confirm:$false
```
Removing a policy does not delete already-retained data immediately, but records will begin aging out per whatever policy (or default) applies next — do not remove a longer-retention policy while an active legal hold or investigation depends on it.

</details>

<details><summary>Playbook 3 — Fleet-wide mailbox audit bypass sweep</summary>

```powershell
# Find every mailbox with bypass enabled — confirm each is an intentional service account
$allMailboxes = Get-Mailbox -ResultSize Unlimited
$bypassed = foreach ($mbx in $allMailboxes) {
    $bypass = Get-MailboxAuditBypassAssociation -Identity $mbx.PrimarySmtpAddress -ErrorAction SilentlyContinue
    if ($bypass.AuditBypassEnabled) {
        [PSCustomObject]@{
            Mailbox         = $mbx.PrimarySmtpAddress
            RecipientType   = $mbx.RecipientTypeDetails
            AuditBypass     = $true
        }
    }
}
$bypassed | Format-Table -AutoSize
$bypassed | Export-Csv "AuditBypass_Sweep_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
```

**Follow-up:** Any `UserMailbox` (not `SharedMailbox`/`EquipmentMailbox`/known service accounts) in this list is worth flagging to the client — bypass on a real user mailbox is the classic "why can't I see this person's activity" root cause.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Purview Audit configuration and health evidence for escalation.
.NOTES     Run as Compliance Admin; outputs to .\Audit_Evidence\
#>

Connect-IPPSSession -UserPrincipalName "<ADMIN_UPN>"

$outDir = ".\Audit_Evidence_$(Get-Date -Format yyyyMMdd_HHmm)"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# 1. Ingestion status
Get-AdminAuditLogConfig | Select UnifiedAuditLogIngestionEnabled |
    Export-Csv "$outDir\IngestionConfig.csv" -NoTypeInformation

# 2. Retention policies in effect
Get-UnifiedAuditLogRetentionPolicy |
    Select Name, Priority, Workload, RecordTypes, RetentionDuration, WhenCreated |
    Export-Csv "$outDir\RetentionPolicies.csv" -NoTypeInformation

# 3. Mailbox audit bypass sweep (see Playbook 3 for the full version; abbreviated here)
Get-Mailbox -ResultSize Unlimited |
    ForEach-Object { Get-MailboxAuditBypassAssociation -Identity $_.PrimarySmtpAddress -ErrorAction SilentlyContinue } |
    Where-Object { $_.AuditBypassEnabled } |
    Select Identity, AuditBypassEnabled |
    Export-Csv "$outDir\MailboxAuditBypass.csv" -NoTypeInformation

# 4. Control search — last 24 hours, small sample
Search-UnifiedAuditLog -StartDate (Get-Date).AddHours(-24) -EndDate (Get-Date) -ResultSize 50 |
    Select CreationDate, UserIds, Operations, RecordType |
    Export-Csv "$outDir\ControlSearch_Last24h.csv" -NoTypeInformation

Write-Host "Evidence collected to $outDir" -ForegroundColor Green
Compress-Archive -Path $outDir -DestinationPath "$outDir.zip"
Write-Host "ZIP: $outDir.zip"
```

---
## Command Cheat Sheet

```powershell
# --- SESSION ---
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>

# --- INGESTION STATUS ---
Get-AdminAuditLogConfig | Format-List UnifiedAuditLogIngestionEnabled
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true

# --- MAILBOX BYPASS ---
Get-MailboxAuditBypassAssociation -Identity <UPN>
Set-MailboxAuditBypassAssociation -Identity <UPN> -AuditBypassEnabled $false

# --- SEARCH (small) ---
Search-UnifiedAuditLog -StartDate <DATE> -EndDate <DATE> -UserIds <UPN> -ResultSize 100

# --- SEARCH (large, paged) ---
$sid = [Guid]::NewGuid().ToString() + "_Pull"
Search-UnifiedAuditLog -StartDate <DATE> -EndDate <DATE> -SessionId $sid -SessionCommand ReturnLargeSet -ResultSize 5000

# --- SEARCH (high completeness, no paging) ---
Search-UnifiedAuditLog -StartDate <DATE> -EndDate <DATE> -ResultSize 5000 -HighCompleteness

# --- RETENTION POLICIES (Premium) ---
Get-UnifiedAuditLogRetentionPolicy
New-UnifiedAuditLogRetentionPolicy -Name "<NAME>" -RecordTypes <TYPE1>,<TYPE2> -RetentionDuration OneYear
Remove-UnifiedAuditLogRetentionPolicy -Identity "<NAME>" -Confirm:$false

# --- LICENSING ---
Get-MgUserLicenseDetail -UserId <UPN>
Get-MgSubscribedSku | Select SkuPartNumber, ConsumedUnits

# --- SERVICE HEALTH (ingestion incidents) ---
# Portal only: https://admin.microsoft.com/Adminportal/Home#/servicehealth
```

---
## 🎓 Learning Pointers

- **The 100/5,000/50,000 tiers are the single highest-yield thing to memorize about this topic.** Default (100), per-page with paging (5,000), hard session ceiling even with paging (50,000). Nearly every "why don't I see all the records" ticket resolves to one of these three numbers. [MS Docs — Use a PowerShell script to search the audit log](https://learn.microsoft.com/en-us/purview/audit-log-search-script)
- **Retention policy creation is not retroactive — say this explicitly to clients.** A common and reasonable-sounding client request is "can you set retention to 10 years and pull last year's data" — the honest answer is no, a new policy only protects records generated after it's created. This needs to be proactive, not reactive. [MS Docs — Manage audit log retention policies](https://learn.microsoft.com/en-us/purview/audit-log-retention-policies)
- **Audit (Premium) licensing gates apply to the actor, not the tenant or the admin running the search.** A fully Premium-licensed tenant will still produce Standard-only records (missing intelligent-insight properties) for any user who individually lacks the license. This is the most counterintuitive gate in the whole audit stack and worth explaining clearly the first time a client hits it. [MS Docs — Audit solutions overview](https://learn.microsoft.com/en-us/purview/audit-solutions-overview)
- **Don't build recurring jobs on `Search-UnifiedAuditLog`.** It's explicitly positioned by Microsoft as the tool for manual, investigation-scoped retrieval. Continuous/high-volume needs (SIEM feeds, compliance archival) belong on the Office 365 Management Activity API, which is throttled by request rate rather than a hard record ceiling. [MS Docs — Office 365 Management Activity API reference](https://learn.microsoft.com/en-us/office/office-365-management-api/office-365-management-activity-api-reference)
- **Classic Search's retirement (30 Nov 2023) is old enough now that most tickets won't reference it directly — but client-side documentation, saved bookmarks, and training material sometimes still do.** If a client describes a search UI or workflow that doesn't match current New Search, that's the likely explanation, not a bug. [MS Docs — Search the audit log](https://learn.microsoft.com/en-us/purview/audit-search)
- **The Unified Audit Log is a load-bearing dependency for other Purview solutions in this repo, not just its own topic.** Priva, Insider Risk Management, and Communication Compliance all have hard prerequisites on `UnifiedAuditLogIngestionEnabled` — see the `NO_AUDIT_LOG` flag in `Get-PrivaReadinessAudit.ps1` for a concrete example. When troubleshooting any of those, always confirm this layer first.
