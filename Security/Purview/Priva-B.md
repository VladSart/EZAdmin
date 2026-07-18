# Microsoft Priva — Hotfix Runbook (Mode B: Ops)
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

Priva tickets split into two structurally different types — **figure out which one first**, since the diagnosis paths don't overlap: (1) *Privacy Risk Management* — a policy/alert isn't behaving as expected, or (2) *Subject Rights Requests (SRR)* — a data-subject case is stuck, missing data, or about to run a destructive action.

```powershell
# Connect to Security & Compliance PowerShell (required for all Priva cmdlets)
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# 1. Confirm the tenant can even see Priva (licensing + role gate) — legacy cmdlet name, wrap in try
try {
    Get-PrivacyManagementPolicy -ErrorAction Stop | Select-Object Name, Type, Mode, Enabled
} catch {
    Write-Warning "Get-PrivacyManagementPolicy failed: $($_.Exception.Message)"
}

# 2. Confirm the Unified Audit Log is on — required for Privacy Risk Management insights
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled

# 3. Confirm someone actually has an RBAC role assigned (Purview permissions, not Entra ID)
Get-RoleGroupMember -Identity "Privacy Management" -ErrorAction SilentlyContinue

# 4. If this is a Subject Rights Request ticket, confirm the tenant has SRR role members too
Get-RoleGroupMember -Identity "Privacy Management Investigators" -ErrorAction SilentlyContinue
```

**Interpretation:**

| Result | Action |
|--------|--------|
| `Get-PrivacyManagementPolicy` throws / cmdlet not found | Fix 1 — licensing, RBAC, or data-residency gate; Priva may not be provisioned at all |
| `UnifiedAuditLogIngestionEnabled: False` | Fix 2 — enable the audit log; Privacy Risk Management insights depend on it |
| No members in any Privacy Management role group | Fix 3 — nobody but an emergency Global Admin can open the Priva portal |
| Policy exists but shows `Mode: Test` and the requester expected alerts | Fix 4 — policy is in test mode by design; test mode never generates alerts |
| SRR request shows 0 or partial matches for the data subject | Fix 5 — identity resolution or data-source scope problem |
| Ticket asks to run/confirm a **Delete** SRR request | Fix 6 — this is irreversible; do not execute without the confirmation checklist |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant NOT provisioned in a Priva-excluded data-residency boundary
  (Norway, Poland, Qatar, Singapore, South Africa, South Korea, Spain,
   Sweden, Switzerland, UAE local datacenters => Priva unavailable, ANY licence)
    │
    ▼
Priva licensing assigned
  (Microsoft 365 E5 / E5 Compliance bundle, OR standalone "Microsoft Priva
   Privacy Risk Management" / "Microsoft Priva Subject Rights Requests" add-on)
    │
    ▼
RBAC role assigned in Microsoft Purview portal permissions (Settings > Roles
and scopes) — these are Purview roles, NOT Entra ID directory roles and will
never appear when searching Entra ID role assignments
    │
    ├── Privacy Risk Management branch
    │     │
    │     ▼
    │   Unified Audit Log enabled tenant-wide (one-time; several hours to
    │   finish "preparing" after first enabled)
    │     │
    │     ▼
    │   Policy created from a template (Data overexposure | Data transfer)
    │     │
    │     ▼
    │   Policy starts in TEST MODE by default — 30-day lookback,
    │   NO alerts, NO Teams tips generated while testing
    │     │
    │     ▼
    │   Policy turned On → Alert generated on match → admin must manually
    │   create an Issue from the Alert → Remediation action taken → Resolve
    │
    └── Subject Rights Requests branch
          │
          ▼
        Request created (Access | Export | Tagged list for follow-up | Delete)
          │
          ▼
        Automated search across Exchange Online, SharePoint Online,
        OneDrive for Business, Microsoft Teams (+ Purview-registered /
        "beyond M365" connectors, preview) — keyed on the data subject's
        identity (email/UPN); wrong or ambiguous identity = incomplete results
          │
          ▼
        Dedicated Teams channel auto-created for request collaborators
          │
          ▼
        Review, redact, generate report → close request
        (Delete request type is a ONE-WAY DOOR once executed)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Classify the ticket type**
Privacy Risk Management (policy/alert behavior) and Subject Rights Requests (case-based, per data subject) share a portal but nothing else architecturally. Confirm which one before going further — most wasted troubleshooting time on Priva tickets comes from applying PRM diagnosis logic to an SRR case or vice versa.

**Step 2 — Confirm the tenant can reach Priva at all**
```powershell
Get-PrivacyManagementPolicy -ErrorAction Stop
```
Expected: returns (possibly empty) policy list without error.
Bad: cmdlet not recognized or throws an access-denied style error → go to Fix 1 before anything else. Also manually confirm the tenant's provisioning region isn't on the excluded data-residency list — this blocks Priva even with a valid licence, and no error message in the portal will clearly explain it.

**Step 3 — Confirm RBAC**
```powershell
Get-RoleGroupMember -Identity "Privacy Management"
Get-RoleGroupMember -Identity "Privacy Management Administrators"
Get-RoleGroupMember -Identity "Privacy Management Analysts"
Get-RoleGroupMember -Identity "Privacy Management Investigators"
Get-RoleGroupMember -Identity "Privacy Management Viewer"
```
Expected: the requester (or someone) is a member of a role group appropriate to what they're trying to do. Bad: empty across all five → Fix 3.

**Step 4 — (Privacy Risk Management only) Confirm audit log and policy mode**
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
Get-PrivacyManagementPolicy | Select-Object Name, Type, Mode, Enabled
```
Expected: `UnifiedAuditLogIngestionEnabled: True`, and the policy in question shows `Mode: On` if the requester expects live alerts.
Bad: audit log `False` → Fix 2. Policy `Mode: Test` while the requester expected alerts → Fix 4 (this is working as designed, not a bug).

**Step 5 — (SRR only) Confirm identity resolution and data-source scope**
In the Priva portal, open the request > **Search** tab and confirm the data subject was resolved to a specific mailbox/user object, not left as free-text. Confirm which data sources were included (Exchange/SharePoint/OneDrive/Teams, plus any "beyond M365" connectors). A request scoped to only one workload when the data actually lives in another is the most common "found nothing" complaint.

**Step 6 — (SRR Delete only) Stop before executing**
Confirm this is genuinely required and the correct data subject/content set before running a Delete request — go to Fix 6.

---
## Common Fix Paths

<details>
<summary>Fix 1 — Priva isn't visible / cmdlets fail / portal shows nothing</summary>

**Three independent gates can each produce this symptom: data residency, licensing, and RBAC. Check in this order — residency first, since no licence or role fix will work around it.**

```powershell
# Residency: there is no cmdlet for this — confirm with the client which region their
# tenant was originally provisioned in. If it's one of the excluded local-datacenter
# regions (Norway, Poland, Qatar, Singapore, South Africa, South Korea, Spain, Sweden,
# Switzerland, UAE), Priva is categorically unavailable — this cannot be fixed, only
# communicated as a product limitation.

# Licensing: best-effort SKU check (Priva SKU naming varies by agreement type —
# cross-check against the admin center if this returns nothing definitive)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "PRIVACY|PRIVA" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}

# RBAC: assign a role (Global Admin only)
Add-RoleGroupMember -Identity "Privacy Management" -Member <user@tenant.com>
```

**Rollback:** `Remove-RoleGroupMember -Identity "Privacy Management" -Member <user@tenant.com>` to revert an RBAC grant. Licensing and residency are not reversible from this side.

</details>

<details>
<summary>Fix 2 — Unified Audit Log not enabled (Privacy Risk Management insights missing)</summary>

**Privacy Risk Management policy insights depend entirely on the Microsoft 365 unified audit log. If it was only just turned on, expect a multi-hour "preparing" delay before any policy insight populates — this is not a Priva-specific delay.**

```powershell
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true

# Re-check after a few hours
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```

**Rollback:** `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $false` — not recommended, since this also disables audit logging for every other Purview workload that depends on it (DLP, eDiscovery, Insider Risk, etc.).

</details>

<details>
<summary>Fix 3 — No one has an RBAC role, or the wrong role for the task</summary>

**Priva roles live in Microsoft Purview portal permissions (Settings > Roles and scopes), not Entra ID — searching Entra ID directory roles for "Privacy" will find nothing.**

```powershell
# Grant the narrowest role that fits the task — avoid defaulting to
# "Privacy Management" (all-in-one) or Global Administrator
Add-RoleGroupMember -Identity "Privacy Management Analysts" -Member <analyst@tenant.com>
Add-RoleGroupMember -Identity "Privacy Management Investigators" -Member <investigator@tenant.com>
Add-RoleGroupMember -Identity "Privacy Management Viewer" -Member <viewer@tenant.com>
```
- **Analysts** can investigate matches and take remediation actions but cannot view file content.
- **Investigators** can do everything Analysts can, plus view actual file content — reserve for staff who need content-level access.
- **Viewer** is read-only reporting/insights, no remediation.

**Rollback:** `Remove-RoleGroupMember -Identity "<role group>" -Member <user@tenant.com>`.

</details>

<details>
<summary>Fix 4 — Policy is in Test mode and the requester expected alerts</summary>

**Test mode is the default for every new policy and never generates alerts or Teams tips, by design — this is the single most common Priva "it's not working" ticket.**

```powershell
Get-PrivacyManagementPolicy | Select-Object Name, Mode, Enabled
```
If `Mode: Test` is unexpected, turn the policy on from the Priva portal (**Policies > [policy name] > Turn on policy**) — there is no PowerShell cmdlet to flip a policy from Test to On; this action is portal-only.

Before turning on, confirm the policy has been in test mode long enough to sanity-check its match volume (Microsoft recommends a minimum of 5 days) — turning on a policy that's still surfacing an unexpectedly high match count will immediately generate an alert storm.

**Rollback:** re-edit the policy in the portal and toggle back to test mode at any time; this does not delete the policy or its history.

</details>

<details>
<summary>Fix 5 — Subject Rights Request finds zero or partial results</summary>

**The two most common root causes are identity resolution and data-source scope — check both before assuming a data problem.**

1. Open the request in the Priva portal and confirm the data subject was resolved to an actual user/mailbox object during request creation, not left as unmatched free text.
2. Confirm the **Search** step included every workload the data is expected to live in (Exchange, SharePoint, OneDrive, Teams). A request scoped only to Exchange will never find a SharePoint-only file.
3. If the data subject is a former employee, confirm their mailbox/OneDrive weren't already deleted or purged past the retention window before the request was created — Priva can only search data that still exists.
4. For data outside the four core M365 workloads, confirm whether the (preview) "beyond M365" connector capability is configured and in scope — Priva's default search does not reach third-party/on-prem systems without it.

**Rollback:** N/A — this is a search-scope fix, not a destructive action. Re-run the search after correcting scope.

</details>

<details>
<summary>Fix 6 — About to run (or confirm) a Delete-type Subject Rights Request</summary>

**A Delete request permanently removes the identified content. There is no undo once it executes — treat this exactly like the Regulatory Record irreversibility warning in `RetentionLabels-A.md`: confirm before acting, not after.**

Before executing:
1. Confirm the exact data subject identity and every content item in scope by reviewing the **Tagged list for follow-up** or review-stage output first — do not go straight from Access/Export results to Delete without a human review pass.
2. Confirm the requester has legal/compliance sign-off for deletion (Priva RBAC does not gate this — a Privacy Management Administrator can execute a Delete request with no secondary approval built into the product).
3. Confirm no active legal hold, retention label, or eDiscovery hold applies to the same content — a hold will block or partially block deletion; reconcile with `Security/Purview/eDiscovery-A.md` and `RetentionLabels-A.md` first if any hold might apply.
4. Only then execute the Delete request from the portal.

**Rollback:** none. This is the one Priva action in this runbook with no rollback path — get explicit sign-off before proceeding.

</details>

---
## Escalation Evidence

```
=== MICROSOFT PRIVA — ESCALATION PACK ===
Date/Time:                  ___________________________
Tenant ID:                  ___________________________ (Get-MgOrganization | Select-Object Id)
Ticket type:                 Privacy Risk Management  /  Subject Rights Request
Affected policy or request:  ___________________________
Requester UPN:               ___________________________

--- DIAGNOSTIC CHECKLIST ---
[ ] Get-PrivacyManagementPolicy succeeds without error:        Yes / No
[ ] UnifiedAuditLogIngestionEnabled:                            True / False
[ ] Requester (or relevant admin) has a Privacy Management role: Yes / No — which group: ___________
[ ] Tenant data-residency region confirmed NOT on the exclusion list: Yes / No / Unknown
[ ] (PRM) Policy Mode:                                          Test / On
[ ] (PRM) Data sources / data-to-monitor scope matches expectation: Yes / No
[ ] (SRR) Data subject identity resolved to a real object:      Yes / No
[ ] (SRR) Data sources searched:                                ___________________________
[ ] (SRR) Active hold/retention label on in-scope content:      Yes / No

--- ISSUE DESCRIPTION ---
Expected behaviour:   ___________________________
Actual behaviour:     ___________________________
First occurrence:     ___________________________
Steps already tried:  ___________________________

--- EXPORTS TO ATTACH ---
[ ] Get-PrivacyManagementPolicy output
[ ] Get-RoleGroupMember output for all five Privacy Management role groups
[ ] Get-AdminAuditLogConfig output
[ ] Screenshot of the SRR request's Search/Content tabs (portal-only, no cmdlet equivalent)

--- MICROSOFT SUPPORT LINKS ---
Open ticket at: https://admin.microsoft.com → Support → New service request
Category: Compliance → Priva
Tenant ID required (Get-MgOrganization | Select-Object Id)
```

---
## 🎓 Learning Pointers

- **Test mode is silent by design, not broken.** Every new Privacy Risk Management policy starts in Test mode with a 30-day lookback and generates zero alerts or Teams tips until an admin explicitly turns it on. This is the single most common "Priva isn't doing anything" ticket. See: [Privacy risk management policies](https://learn.microsoft.com/en-us/privacy/priva/risk-management-policies)

- **Priva RBAC lives in the Purview portal, not Entra ID.** Searching Entra ID directory roles for a "Privacy" role will always come up empty — roles are assigned under Purview portal Settings > Roles and scopes, and use their own role-group model (Privacy Management, Administrators, Analysts, Investigators, Viewer). See: [Get started with Priva](https://learn.microsoft.com/en-us/privacy/priva/priva-setup)

- **Data-residency boundary tenants can't use Priva at all, regardless of licence.** Tenants originally provisioned in Norway, Poland, Qatar, Singapore, South Africa, South Korea, Spain, Sweden, Switzerland, or UAE local datacenters are excluded outright — this produces a confusing "nothing works" experience with no clear in-portal explanation, so it's worth confirming early on any "Priva is broken" ticket for a client in one of those regions. See: [Get started with Priva](https://learn.microsoft.com/en-us/privacy/priva/priva-setup)

- **Alerts don't self-remediate — an admin must manually create an Issue from an Alert before any remediation action (notify owner, apply a label, make private) becomes available.** A policy generating alerts that nobody is triaging into Issues will look identical to a policy that isn't working. See: [Investigate and remediate alerts in Privacy Risk Management](https://learn.microsoft.com/en-us/privacy/priva/risk-management-alerts)

- **Subject Rights Requests only search what's still there.** If a former employee's mailbox or OneDrive was already deleted/purged before the request was created, Priva cannot retroactively find that data — confirm data retention status before promising a complete result set to legal/compliance. See: [Learn about Microsoft Priva](https://learn.microsoft.com/en-us/privacy/priva/priva-overview)

- **A Delete-type Subject Rights Request has no rollback.** Unlike every other fix in this runbook, there is no `-WhatIf`, no undo, and no PowerShell escape hatch — treat it with the same one-way-door discipline as declaring a Regulatory Record in `RetentionLabels-A.md`, and always check for an active hold first. See: [Microsoft Priva Subject Rights Requests](https://www.microsoft.com/en-us/security/business/privacy/microsoft-priva-subject-rights-requests)
