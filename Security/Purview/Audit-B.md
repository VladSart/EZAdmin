# Purview Audit (Unified Audit Log) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

```powershell
# 1. Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>

# 2. Confirm Unified Audit Log ingestion is actually turned on
Get-AdminAuditLogConfig | Format-List UnifiedAuditLogIngestionEnabled

# 3. Run a small, recent, unambiguous test search (last 1 hour, no filters)
Search-UnifiedAuditLog -StartDate (Get-Date).AddHours(-1) -EndDate (Get-Date) -ResultSize 10

# 4. Check whether the target mailbox has audit logging bypassed
Get-MailboxAuditBypassAssociation -Identity "<USER_UPN>" | Select AuditBypassEnabled

# 5. Check the org's Audit (Premium) license status (governs retention + high-value events)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "E5|ATP_ENTERPRISE|EQUIVIO|INFO_PROTECTION" } |
    Select SkuPartNumber, ConsumedUnits
```

| Output | Interpretation | Next Step |
|--------|---------------|-----------|
| `UnifiedAuditLogIngestionEnabled = $false` | Auditing is off tenant-wide — nothing is being logged, this isn't a search problem | [Fix 1 — Enable Audit Log Ingestion](#fix-1--enable-audit-log-ingestion) |
| Step 3 returns 0 rows even though you know activity occurred | Either ingestion delay, wrong record type, or bypassed mailbox | [Fix 2 — Handle Ingestion Delay](#fix-2--handle-ingestion-delay) |
| Search returns exactly 100 rows and stops | You hit the **default, silent 100-record cap** — not "no more data" | [Fix 3 — Retrieve Large Result Sets](#fix-3--retrieve-large-result-sets) |
| `AuditBypassEnabled = True` on a mailbox you're investigating | That mailbox's actions are deliberately excluded from the audit log | [Fix 4 — Remove Mailbox Audit Bypass](#fix-4--remove-mailbox-audit-bypass) |
| Search works but a known event (e.g. `MailItemsAccessed` sensitivity label) is missing a property | That property requires an **Audit (Premium)** license on the actor | [Fix 5 — Diagnose Premium-Only Gaps](#fix-5--diagnose-premium-only-gaps) |
| Records exist but are older than expected retention | Retention expired, or no custom retention policy was ever created | [Fix 6 — Extend Audit Log Retention](#fix-6--extend-audit-log-retention) |

---
## Dependency Cascade

<details><summary>What must be true for an activity to be searchable</summary>

```
Microsoft 365 subscription with Exchange Online
  └── Audit (Standard) — enabled by default
        └── UnifiedAuditLogIngestionEnabled = True (org-wide switch)
              └── Per-workload audit logging (Exchange, SharePoint, Entra ID, Teams, Power Platform, etc.)
                    └── Per-mailbox: NOT excluded via Set-MailboxAuditBypassAssociation
                          └── Activity occurs → ingestion pipeline → indexed (30 min – 24 hrs typical)
                                └── Searchable via:
                                      ├── Purview portal Audit search (New Search, Classic retired Nov 2023)
                                      ├── Audit Search Graph API
                                      ├── Search-UnifiedAuditLog cmdlet (100-result default cap!)
                                      └── Office 365 Management Activity API (SIEM ingestion)
                                            └── Retained for:
                                                  180 days (Standard, default since 17 Oct 2023)
                                                  1 year — AAD/Exchange/OneDrive/SharePoint (Premium default policy)
                                                  Up to 10 years (Premium + per-user 10-yr add-on license)

Audit (Premium) — requires E5 / E5 Compliance / G5 add-on, assigned PER USER (actor), gates:
  ├── High-value "intelligent insight" properties (e.g. MailItemsAccessed → SensitivityLabel)
  ├── Custom audit log retention policies
  └── Higher-bandwidth Management Activity API access
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm ingestion is on and has been on long enough**
```powershell
Get-AdminAuditLogConfig | Format-List UnifiedAuditLogIngestionEnabled
```
- `True` → proceed. `False` → this is a config gap, not a search bug; see Fix 1.
- If it was just turned on, remember: it does **not** retroactively log anything before the enable time.

**Step 2 — Run the smallest possible control search**
```powershell
Search-UnifiedAuditLog -StartDate (Get-Date).AddHours(-1) -EndDate (Get-Date) `
    -UserIds "<USER_UPN>" -ResultSize 10
```
Do this against an account you can personally generate fresh activity on (e.g. sign in, open a file) to rule out ingestion delay as the cause before troubleshooting anything else.

**Step 3 — Check for the default result cap**
```powershell
# Naive call — silently truncates at 100 records, no warning
Search-UnifiedAuditLog -StartDate $start -EndDate $end -ResultSize 5000
```
If your `$results.Count` is exactly 100 and you expected more, you didn't hit "no more data" — you hit the cmdlet's default behavior. Use `-SessionCommand ReturnLargeSet` or `-HighCompleteness` (see Fix 3).

**Step 4 — Check mailbox-level bypass**
```powershell
Get-MailboxAuditBypassAssociation -Identity "<USER_UPN>" | Select Identity, AuditBypassEnabled
```
Bypass is normally set on service accounts to reduce noise — but it's occasionally left enabled on a real user mailbox by mistake, and their activity will never appear in the log while it's set.

**Step 5 — Confirm retention window covers the requested date range**
```powershell
Get-UnifiedAuditLogRetentionPolicy | Select Name, RetentionDuration, Priority, Workload
```
If nothing has been configured, everything falls back to the default: 180 days (Standard) or 1 year for AAD/Exchange/OneDrive/SharePoint (Premium's built-in default policy). Anything you're searching for outside that window is already gone — this is not recoverable after the fact.

---
## Common Fix Paths

<details><summary>Fix 1 — Enable Audit Log Ingestion</summary>

**Symptom:** `UnifiedAuditLogIngestionEnabled = $false`.

```powershell
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true

# Verify
Get-AdminAuditLogConfig | Format-List UnifiedAuditLogIngestionEnabled
```

**Important:** This is enabled by default for all M365/O365 enterprise organizations. If you find it disabled, someone (or some script) turned it off deliberately — investigate why before re-enabling, since it may have been a compliance decision. Once re-enabled, only activity from that point forward is logged; nothing is backfilled.

</details>

<details><summary>Fix 2 — Handle Ingestion Delay</summary>

**Symptom:** Recent, confirmed activity doesn't show up in search yet.

Ingestion latency is normal and variable — typically **30 minutes to 24 hours**, occasionally longer during service-wide load. This is the single most common false alarm in audit log tickets.

```powershell
# Widen the window and re-run after waiting
Start-Sleep -Seconds 1800   # wait 30 min in an automated re-check, or just come back later
Search-UnifiedAuditLog -StartDate (Get-Date).AddHours(-24) -EndDate (Get-Date) -UserIds "<USER_UPN>"
```

If it's still missing after 24 hours, check the [Microsoft 365 Service Health dashboard](https://admin.microsoft.com/Adminportal/Home#/servicehealth) for an active audit ingestion incident before escalating further.

</details>

<details><summary>Fix 3 — Retrieve Large Result Sets</summary>

**Symptom:** Search silently caps at 100 records, or you know a date range holds more than a few thousand events.

```powershell
# Option A — ReturnLargeSet: use a SessionId to page through up to 50,000 records
# (5,000 per page, requires paging loop — see Evidence Pack script in the -A runbook)
$sessionId = [Guid]::NewGuid().ToString() + "_ExtractLogs"
$results = Search-UnifiedAuditLog -StartDate $start -EndDate $end `
    -SessionId $sessionId -SessionCommand ReturnLargeSet -ResultSize 5000

# Option B — HighCompleteness: prioritizes completeness over speed, no SessionId needed
$results = Search-UnifiedAuditLog -StartDate $start -EndDate $end `
    -ResultSize 5000 -HighCompleteness
```

**Hard ceiling:** `Search-UnifiedAuditLog` tops out at **50,000 records per session** even with `ReturnLargeSet`. If a date range returns exactly 50,000, records are almost certainly missing — split the range into smaller chunks and re-run per chunk (see the -A runbook's paging script).

**For anything recurring or large-scale:** don't build this as a scheduled PowerShell job — use the **Office 365 Management Activity API** instead. It's built for continuous, high-volume pulls and doesn't share the cmdlet's per-session ceiling.

</details>

<details><summary>Fix 4 — Remove Mailbox Audit Bypass</summary>

**Symptom:** A specific mailbox's activity never appears, `AuditBypassEnabled = True`.

```powershell
# Check current state
Get-MailboxAuditBypassAssociation -Identity "<USER_UPN>" | Select Identity, AuditBypassEnabled

# Remove the bypass so this mailbox is audited normally again
Set-MailboxAuditBypassAssociation -Identity "<USER_UPN>" -AuditBypassEnabled $false
```

**Before removing:** confirm why it was set. Bypass is commonly applied deliberately to high-volume service accounts (backup/migration tools, compliance bots) to cut audit log noise. Removing it on a genuine service account can flood the log — only remove it if the mailbox is a real user or the noise tradeoff has been discussed with the client.

</details>

<details><summary>Fix 5 — Diagnose Premium-Only Gaps</summary>

**Symptom:** The search works and returns the event, but an expected property (e.g. `SensitivityLabel` on `MailItemsAccessed`, or Teams `AppAccessContext`) is missing or null.

```powershell
# Check whether the acting user has an Audit (Premium)-capable license
Get-MgUserLicenseDetail -UserId "<USER_UPN>" |
    Select SkuPartNumber, ServicePlans
```

Audit (Premium) "intelligent insight" properties are only generated for users who **hold a Premium-capable license at the time the activity occurs** (E5, E5 Compliance add-on, or G5). Standard audit records are still generated and searchable — they simply lack the extra property. This is not a search or config bug; it's a licensing gate applied per-actor, not per-tenant.

</details>

<details><summary>Fix 6 — Extend Audit Log Retention</summary>

**Symptom:** Events older than 180 days (or 1 year for AAD/Exchange/OneDrive/SharePoint) are gone and needed for an investigation.

```powershell
# Requires Audit (Premium)
New-UnifiedAuditLogRetentionPolicy -Name "Legal-LongRetention" `
    -RecordTypes AzureActiveDirectory,ExchangeAdmin,SharePointFileOperation `
    -RetentionDuration TenYears `
    -Priority 1
```

**This is not retroactive.** A new retention policy only protects audit records generated *after* the policy is created — it cannot recover records that already aged out. If a client needs long-term retention for compliance, set the policy up proactively, before the investigation, not during it. Flag this clearly if a client asks you to "go back and find" something older than the applicable retention window; the honest answer is that it may already be gone.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION: Purview Audit / Unified Audit Log Issue
=====================================
Admin UPN:                    ___________________________
Tenant / customer:            ___________________________
Audit (Standard/Premium):     ___________________________
UnifiedAuditLogIngestionEnabled: ___________________________
Affected user/mailbox UPN:    ___________________________
AuditBypassEnabled on mailbox:___________________________
Search method used:           Portal / Search-UnifiedAuditLog / Graph API / Management Activity API
Date range searched:          ___________________________
Result count returned:        ___________________________
Expected vs actual event:     ___________________________
Retention policy in effect:   ___________________________
Error message (exact):        ___________________________
Compliance Center URL:        https://compliance.microsoft.com/auditlogsearch
Support path:                 Microsoft 365 Admin → Support → New service request
                               (select "Security & Compliance" > "Audit log search")
```

---
## 🎓 Learning Pointers

- **The 100-record default is silent, not an error.** `Search-UnifiedAuditLog` without `-SessionCommand ReturnLargeSet` or `-HighCompleteness` returns at most 100 rows and gives no warning that more exist. Assume every "why is my count so low" ticket is this until proven otherwise. [MS Docs — Search-UnifiedAuditLog](https://learn.microsoft.com/en-us/powershell/module/exchange/search-unifiedauditlog)
- **Ingestion delay is normal, not a fault.** 30 minutes to 24 hours is the expected range before an activity becomes searchable. Don't escalate "missing" recent activity until you've waited out a full 24-hour window and confirmed ingestion is actually enabled. [MS Docs — Audit log search](https://learn.microsoft.com/en-us/purview/audit-search)
- **Retention gaps are not fixable after the fact.** The default retention (180 days Standard, 1 year for AAD/Exchange/OneDrive/SharePoint on Premium) only protects records generated while a policy is in effect. If a client wants years of retention, that decision has to be made before the data ages out, not during an incident response. [MS Docs — Manage audit log retention policies](https://learn.microsoft.com/en-us/purview/audit-log-retention-policies)
- **Mailbox audit bypass is a legitimate but easy-to-forget setting.** It exists to quiet high-volume service accounts, but if a client asks "why can't I see what this mailbox did," always check `Get-MailboxAuditBypassAssociation` before assuming a platform bug.
- **Classic Search is gone.** It retired 30 November 2023. If a client's documentation, screenshots, or training material references the old search experience, redirect them to New Search in the Purview portal — the UI and some parameter names changed. [MS Docs — Audit solutions overview](https://learn.microsoft.com/en-us/purview/audit-solutions-overview)
- **For anything recurring, don't fight the cmdlet — switch tools.** The Office 365 Management Activity API is purpose-built for continuous, high-volume audit pulls (SIEM ingestion) and isn't bound by the 50,000-record-per-session ceiling that `Search-UnifiedAuditLog` has. If a client is running a scheduled PowerShell job to pull audit data daily, that's a sign they should be using the Management Activity API instead.
