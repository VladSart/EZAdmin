# Microsoft Priva — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Priva's two solutions, both hosted in the Priva portal (`purview.microsoft.com/priva`):
  - **Privacy Risk Management (PRM)** — policy-driven detection of data overexposure and data transfer risk
  - **Subject Rights Requests (SRR)** — case-based discovery/export/deletion of an individual's personal data for regulatory requests (GDPR, CCPA, etc.)
- RBAC via Microsoft Purview portal role groups, licensing/data-residency prerequisites
- PowerShell management via Security & Compliance PowerShell's legacy-named Privacy Management cmdlets

**Out of scope:**
- Microsoft Purview DLP — a related but architecturally separate engine focused on preventing data *loss/exfiltration* via explicit block/notify rules, not proactive personal-data *risk visibility*. See `DLP-Policy-A.md`.
- Retention labels, record labels, and regulatory records — a separate lifecycle-management workload. See `RetentionLabels-A.md`.
- Insider Risk Management — a separate policy engine focused on behavioral/insider threat indicators, not personal-data exposure. See `Insider-Risk-A.md`.
- General GDPR/CCPA legal process guidance beyond the technical SRR tooling (consult legal/compliance for regulatory interpretation).

**Assumed baseline:**
- Tenant is not provisioned in a Priva-excluded data-residency boundary (see Dependency Stack)
- Priva licensing assigned (Microsoft 365 E5/E5 Compliance bundle, or the standalone Priva add-on SKU(s))
- Connected to Security & Compliance PowerShell (`Connect-IPPSSession`) for any cmdlet-based checks
- Admin has an appropriate Purview portal role assignment (not an Entra ID role)

---

## How It Works

<details><summary>Full architecture</summary>

### Two Solutions, One Portal, Different Engines

Microsoft Priva is a brand covering two functionally independent solutions that happen to share a portal and a permission surface:

- **Privacy Risk Management** evaluates content continuously against policy conditions and surfaces risk via alerts.
- **Subject Rights Requests** is case-based — an admin opens a request for a named data subject, and Priva runs a bounded, one-time (per request) discovery/action workflow against that subject's data.

They do not share diagnosis logic. A stuck SRR case is never a PRM policy problem, and a noisy PRM policy is never an SRR search-scope problem.

### Privacy Risk Management Pipeline

```
Policy template chosen: Data overexposure | Data transfer
        │
        ▼
Data sources selected: Exchange | OneDrive | Teams | SharePoint (all or specific sites)
        │
        ▼
Data to monitor selected (mutually exclusive choice):
  ├── Classification groups (curated groupings of SITs, e.g. "US Personal Data")
  └── Sensitive information types OR trainable classifiers (build a custom group)
        │   Note: trainable classifier matches count as ONE match per item
        │   (a per-item detection), while each SIT instance within an item
        │   counts as its own separate match — this changes how alert
        │   thresholds behave between the two data-to-monitor modes.
        ▼
Users/groups scoped: All, or up to 100 specific users / 10 specific groups
        │
        ▼
Conditions set (policy-type specific — overexposure vs. transfer-boundary logic)
        │
        ▼
Outcomes defined: Teams tips shown to end users at time of risky action (transfer
policies only) — a policy match is generated whether the user heeds the tip or
selects "Ignore and send" (which additionally logs the user's typed justification)
        │
        ▼
Alerts configured: off, every match, threshold-based, or condition-based
(high-volume-of-personal-data OR regulated-data-category — Microsoft's
recommended setting)
        │
        ▼
Policy mode: TEST (default — 30-day lookback, zero alerts/tips generated,
insights-only) or ON
        │
        ▼
[When On] Policy match → Alert generated → admin reviews Alert → admin manually
creates an Issue → Issue reviewed (Content/Notes/Collaborators tabs) →
Remediation action taken (Notify owner | Apply retention label | Apply
sensitivity label | Mark as not a match | Make private) → Issue resolved
```

**Key architectural point:** an Alert is not automatically actionable — it is purely a notification that a match occurred. Nothing downstream happens until a human converts the Alert into an Issue. A tenant with alerting configured but no one triaging Issues will produce a growing, silently-ignored Alerts queue that looks identical from the outside to "policy isn't catching anything."

### Subject Rights Requests Pipeline

```
Request created for a named data subject, request type chosen:
  ├── Access — summary of the subject's personal data
  ├── Export — summary + exported file of matched content items
  ├── Tagged list for follow-up — summary of items tagged during review
  └── Delete — deletes matched content items (IRREVERSIBLE, one-way door)
        │
        ▼
Data subject identity resolution — must resolve to an actual mailbox/user
object; ambiguous or free-text identity input degrades search accuracy
        │
        ▼
Automated discovery kicks off immediately across:
  Exchange Online | SharePoint Online | OneDrive for Business | Microsoft Teams
  (+ optional preview "beyond M365" connectors for third-party/on-prem sources)
        │
        ▼
Dedicated Microsoft Teams channel auto-provisioned for the request — adding
collaborators invites them into this channel to jointly review results
        │
        ▼
Review stage: content owners/reviewers examine matched items, can redact,
tag for follow-up, or mark as not relevant
        │
        ▼
Report generation → (Access/Export) deliverable produced, or
                     (Delete) matched items permanently removed
        │
        ▼
Request closed
```

### RBAC Model

Priva uses Microsoft Purview portal permissions (Settings > Roles and scopes), a completely separate surface from Entra ID directory roles. Role groups relevant to Priva:

| Role group | Can do | Can view content | Applies to |
|------------|--------|-------------------|------------|
| Privacy Management | Everything (all Priva roles combined) | Yes | PRM |
| Privacy Management Administrators | Full CRUD on policies, permissions, settings | No | PRM |
| Privacy Management Analysts | Investigate matches, take remediation actions | No | PRM |
| Privacy Management Investigators | Investigate matches, take remediation actions | Yes | PRM |
| Privacy Management Viewer | Read-only reports/insights | No | PRM |

Microsoft's own guidance is to assign the narrowest role that fits the task and to keep Global Administrator usage to emergency scenarios only — Global Admin is a valid but explicitly discouraged path into Priva.

</details>

---

## Dependency Stack

```
Tenant data-residency region
    │   Norway, Poland, Qatar, Singapore, South Africa, South Korea, Spain,
    │   Sweden, Switzerland, and UAE local-datacenter tenants CANNOT use
    │   Priva at all — this gate sits below licensing and cannot be
    │   worked around with any SKU
    │
Priva licensing
    │   Microsoft 365 E5 / E5 Compliance bundle, OR standalone add-on
    │   ("Microsoft Priva Privacy Risk Management" / "...Subject Rights
    │   Requests") — the two solutions can be licensed independently
    │
Purview portal RBAC role assignment
    │   Settings > Roles and scopes — NOT Entra ID directory roles
    │   Global Administrator can assign; day-to-day use should be scoped
    │   to the narrowest Privacy Management role group that fits
    │
    ├── Privacy Risk Management branch
    │     │
    │   Unified Audit Log (tenant-wide, one-time enable, hours to prepare)
    │     │   Policy insights and alerting depend on this being on
    │     │
    │   Foundational Purview classification (SITs, classification groups,
    │   trainable classifiers) — Priva reuses these, doesn't own them
    │     │
    │   Policy (Data overexposure | Data transfer), starts in Test mode
    │     │
    │   Alert → Issue → Remediation workflow (manual triage step required)
    │
    └── Subject Rights Requests branch
          │
        Data subject identity resolution (must map to a real object)
          │
        Search scope: Exchange | SharePoint | OneDrive | Teams
        (+ preview "beyond M365" connectors)
          │
        Auto-provisioned Teams collaboration channel
          │
        Review/redaction stage → Report/Export/Delete outcome
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Priva portal shows nothing / cmdlets fail entirely | Data-residency exclusion, missing licence, or no RBAC role | Confirm tenant provisioning region; `Get-MgSubscribedSku` for Priva SKU; `Get-RoleGroupMember` |
| Policy exists but never generates alerts | Policy still in Test mode (the default) | `Get-PrivacyManagementPolicy` → `Mode` field |
| Policy is On but insights/matches never populate | Unified Audit Log not enabled, or <24-48h since it was enabled/policy turned on | `Get-AdminAuditLogConfig` |
| Alert volume is very high / alert storm | `Alert each time a match occurs` selected instead of threshold/condition-based alerting | Review policy's Alerts step in the portal |
| Trainable-classifier-based policy alert thresholds behave unexpectedly | Trainable classifiers count as one match per item — the "high volume of personal data" threshold option is unavailable for them | Confirm data-to-monitor type (SIT vs. trainable classifier) |
| Admin sees Alerts but no Issues, remediation never happens | Alerts require a manual "Create issue" step — nothing is automatic | Check Alerts page for un-triaged alerts |
| A user assigned a Privacy Management role can't find Priva anywhere | Looking in Entra ID directory roles instead of Purview portal permissions | `Settings > Roles and scopes` in the Purview/Priva portal |
| SRR request returns zero or partial matches | Data subject identity unresolved, or search scope excluded the workload holding the data | Review request's Search tab; confirm identity resolved to a real object |
| SRR request for a departed employee finds nothing | Mailbox/OneDrive already deleted/purged before request creation | Confirm retention/deletion status of the account predates the request |
| Client expects Priva to reach a third-party or on-prem system | Default SRR search only covers Exchange/SharePoint/OneDrive/Teams | Confirm whether the preview "beyond M365" connector capability is configured |
| Someone ran a Delete SRR request and now wants the data back | Delete is irreversible by design — no rollback exists | N/A — prevention (Fix 6 in the companion hotfix runbook) is the only real control |

---

## Validation Steps

**1. Confirm Priva is reachable at all**
```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>
Get-PrivacyManagementPolicy -ErrorAction Stop
```
Good: returns without error (empty list is fine on a fresh tenant). Bad: cmdlet not recognized or an access-denied-style error — work the Dependency Stack top-down (residency → licence → RBAC) before assuming a policy problem.

**2. Confirm licensing**
```powershell
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "PRIVACY|PRIVA" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}
```
Good: a matching SKU with available units. Bad: no match — cross-check the exact SKU name in the admin center, since Priva SKU naming varies by agreement/region and this filter is best-effort, not authoritative.

**3. Confirm RBAC coverage**
```powershell
"Privacy Management","Privacy Management Administrators","Privacy Management Analysts",`
"Privacy Management Investigators","Privacy Management Viewer" | ForEach-Object {
    [PSCustomObject]@{
        RoleGroup = $_
        Members   = (Get-RoleGroupMember -Identity $_ -ErrorAction SilentlyContinue).Name -join ", "
    }
}
```
Good: at least one member across the role groups relevant to your operating model. Bad: entirely empty — only an emergency Global Admin path exists into Priva.

**4. Confirm audit log state (Privacy Risk Management only)**
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
Good: `True`, and enabled long enough ago (hours, not minutes) for preparation to have completed. Bad: `False` — every PRM policy will show zero insights regardless of how well it's configured.

**5. Confirm policy mode and scope match expectation**
```powershell
Get-PrivacyManagementPolicy | Select-Object Name, Type, Mode, Enabled
```
Good: `Mode: On` for any policy the requester expects to be actively alerting. Bad: `Mode: Test` — this is a design default, not a defect, and must be explicitly turned on from the portal.

**6. (SRR) Confirm identity resolution and data-source scope in the portal**
Open the request's **Search** tab. Good: the data subject shows as a resolved user/mailbox object and all relevant workloads (Exchange/SharePoint/OneDrive/Teams) are checked. Bad: subject shown as unresolved text, or a workload known to hold relevant data is unchecked.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Classify the ticket
1. Determine whether this is a Privacy Risk Management (policy/alert) ticket or a Subject Rights Requests (case) ticket — the two share no diagnosis logic.
2. For PRM: identify the specific policy and whether the complaint is "no alerts at all" vs. "too many alerts" vs. "matches look wrong."
3. For SRR: identify the request type (Access/Export/Tagged list/Delete) and whether the complaint is about missing results, a stuck workflow step, or a pending destructive action.

### Phase 2 — Rule out tenant-wide access blockers
1. Confirm the tenant isn't in a Priva-excluded data-residency region.
2. Confirm licensing.
3. Confirm the requester (or a relevant admin) has an appropriate Purview portal RBAC role — remember this is not an Entra ID role and won't show up in Entra role-assignment views.

### Phase 3 (PRM) — Isolate policy configuration vs. platform prerequisite
1. If `Get-PrivacyManagementPolicy` returns the policy correctly but no insights populate, check the Unified Audit Log state before touching the policy at all.
2. If insights populate but no alerts fire, check `Mode` — Test mode never alerts, regardless of alert settings.
3. If alerts fire but nothing gets remediated, check whether anyone is converting Alerts into Issues — this is a manual, not automatic, step.
4. If alert volume is unexpectedly high, review the alert frequency setting (each-match vs. threshold vs. condition-based) and the breadth of the classification group in use — an overly broad default classification group is the most common cause of alert-storm tickets, mirroring the same "turn off default policies at first" guidance Microsoft gives for Priva onboarding.

### Phase 3 (SRR) — Isolate identity vs. scope vs. data-availability
1. Confirm the data subject identity resolved correctly at request creation — this is the single most common root cause of incomplete results.
2. Confirm data-source scope covers every workload expected to hold relevant content.
3. If the subject is a former employee, confirm their mailbox/OneDrive weren't deleted/purged before the request was created — Priva cannot search data that no longer exists.
4. If data is expected outside the four core M365 workloads, confirm whether the preview "beyond M365" connector capability applies and is configured.

### Phase 4 — Pre-execution review for destructive SRR actions
1. For any Delete-type request, confirm a human reviewed the matched content (via Access/Export/Tagged-list output) before deletion is authorized.
2. Confirm no active legal hold, retention label, or eDiscovery hold applies to the same content — reconcile against `eDiscovery-A.md` / `RetentionLabels-A.md` if uncertain.
3. Only after both checks pass should the Delete request proceed — there is no rollback once it does.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Onboard Privacy Risk Management from scratch</summary>

1. Confirm licensing and that the tenant is not in a Priva-excluded data-residency region.
2. Enable the Unified Audit Log if not already on, and allow several hours for it to finish preparing.
   ```powershell
   Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
   ```
3. Assign RBAC roles using the narrowest role group that fits each person's task.
   ```powershell
   Add-RoleGroupMember -Identity "Privacy Management Administrators" -Member <admin@tenant.com>
   Add-RoleGroupMember -Identity "Privacy Management Analysts" -Member <analyst@tenant.com>
   ```
4. In the Priva portal, create a policy from the **Data overexposure** template first (data transfer policies are more disruptive to pilot since they surface end-user Teams tips immediately). Accept quick-setup defaults or use custom setup to scope data sources/users.
5. Leave the policy in **Test mode** for a minimum of 5 days per Microsoft's own guidance before turning it on — use this window to sanity-check match volume and adjust conditions if the default classification groups prove too broad (a well-documented early pain point for new Priva deployments).
6. Turn the policy on from the portal once satisfied with test-mode behavior, and set alerts to the recommended condition-based mode (high volume or regulated-data-category) rather than alert-on-every-match.

**Rollback:** re-edit the policy and toggle back to Test mode at any time — this preserves the policy definition and history without generating further alerts.

</details>

<details><summary>Playbook 2 — Tune a noisy or over-alerting policy</summary>

1. Confirm which data-to-monitor mode is in use — a broad default **classification group** (which can pull in dozens of SITs spanning regulations irrelevant to the client's industry/geography) is the most common cause of excessive matches.
2. Switch to a custom, narrower group of specific sensitive information types or trainable classifiers relevant to the client's actual regulatory exposure.
   ```powershell
   Get-PrivacyManagementPolicy | Select-Object Name, Type, Mode
   # Detailed rule conditions are portal-managed; Get-PrivacyManagementRule can
   # surface the underlying rule XML for reference, but rule edits should be
   # made through the portal wizard to keep the policy in a supported state
   Get-PrivacyManagementRule -Policy "<PolicyName>" | Select-Object Name, Disabled
   ```
3. Change alert frequency from "every match" to the recommended condition-based option (high volume of personal data, or personal data items covered by specific regulations).
4. Put the policy back into Test mode while validating the narrower scope, then turn it back on once match volume looks reasonable.

**Rollback:** revert the classification group / alert frequency changes via the portal edit wizard; policy history from before the change remains intact.

</details>

<details><summary>Playbook 3 — Run and close a Subject Rights Request end-to-end (Access or Export)</summary>

1. Create the request in the Priva portal, resolving the data subject to a specific user/mailbox object (never leave this as free text).
2. Select data sources deliberately rather than accepting an "all sources" default if the engagement scope is narrower — this both speeds discovery and reduces irrelevant results requiring manual review.
3. Add collaborators as needed; they'll be added to the auto-provisioned Teams channel for the request.
4. Once discovery completes, review matched content in the **Review** stage — redact or tag items for follow-up as needed.
5. Generate the report/export deliverable and close the request.

**Rollback:** N/A for Access/Export — these are non-destructive read operations. The request itself can be deleted from the portal's request list if created in error, before or after closure.

</details>

<details><summary>Playbook 4 — Decommission Priva (offboarding a client or workload)</summary>

1. Confirm with the client this is intentional — turning off Privacy Risk Management policies stops all future detection; it does not retroactively undo any remediation already taken.
2. Turn off (not delete) each active policy from the portal to preserve history and allow easy re-enable.
3. Remove RBAC role assignments no longer needed:
   ```powershell
   "Privacy Management","Privacy Management Administrators","Privacy Management Analysts",`
   "Privacy Management Investigators","Privacy Management Viewer" | ForEach-Object {
       Get-RoleGroupMember -Identity $_ -ErrorAction SilentlyContinue
   }
   # Then, per user to remove:
   Remove-RoleGroupMember -Identity "<role group>" -Member <user@tenant.com>
   ```
4. Do not disable the Unified Audit Log solely for this purpose — it's a shared dependency for DLP, eDiscovery, Insider Risk, and other Purview workloads; confirm nothing else in the tenant still needs it before touching it.
5. Leave any completed Subject Rights Request history in place — closed requests and their reports are compliance records, not operational state to clean up.

**Rollback:** policies can be turned back on at any time if turned off (not deleted); RBAC role assignments can be re-added; the audit log should generally never have been disabled in the first place.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Microsoft Priva diagnostic evidence for escalation or handoff.
    See also: Scripts/Get-PrivaReadinessAudit.ps1 for the full standalone version.
#>
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

$outDir = "$env:TEMP\Priva-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

try {
    Get-PrivacyManagementPolicy -ErrorAction Stop |
        Select-Object Name, Type, Mode, Enabled |
        Export-Csv "$outDir\Policies.csv" -NoTypeInformation
} catch {
    "Get-PrivacyManagementPolicy failed: $($_.Exception.Message)" | Out-File "$outDir\PolicyCheck-ERROR.txt"
}

Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled |
    Export-Csv "$outDir\AuditLogConfig.csv" -NoTypeInformation

"Privacy Management","Privacy Management Administrators","Privacy Management Analysts",`
"Privacy Management Investigators","Privacy Management Viewer" | ForEach-Object {
    $roleGroup = $_
    Get-RoleGroupMember -Identity $roleGroup -ErrorAction SilentlyContinue |
        Select-Object @{N="RoleGroup";E={$roleGroup}}, Name, RecipientType
} | Export-Csv "$outDir\RBAC.csv" -NoTypeInformation

Write-Host "Evidence collected in $outDir" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Connect-IPPSSession` | Connect to Security & Compliance PowerShell (required for all Priva cmdlets) |
| `Get-PrivacyManagementPolicy` | List Privacy Risk Management policies and their Mode/Enabled state (legacy cmdlet name — pre-dates the Priva rebrand) |
| `Get-PrivacyManagementRule -Policy <name>` | Inspect the underlying rule(s) for a policy |
| `Get-AdminAuditLogConfig` | Check Unified Audit Log ingestion state — a hard PRM prerequisite |
| `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true` | Enable the audit log (shared tenant-wide dependency) |
| `Get-RoleGroupMember -Identity "Privacy Management"` | Check RBAC membership for the all-in-one role group |
| `Add-RoleGroupMember` / `Remove-RoleGroupMember` | Grant/revoke a Priva RBAC role |
| `Get-MgSubscribedSku` | Best-effort licence check (filter `SkuPartNumber -match "PRIVACY\|PRIVA"`) |
| `Get-MgOrganization` | Pull Tenant ID for escalation packs |

> There is no PowerShell cmdlet to create/edit a policy's conditions, turn a policy from Test to On, or manage Subject Rights Requests end-to-end — those actions are portal-only (`purview.microsoft.com/priva`). The cmdlets above are read/RBAC/prerequisite management only.

---

## 🎓 Learning Pointers

- **Priva is two products wearing one brand.** Privacy Risk Management (continuous policy-driven detection) and Subject Rights Requests (case-based, per-data-subject) share a portal and a permission model but have zero shared diagnosis logic — always classify the ticket type first. See: [Learn about Microsoft Priva](https://learn.microsoft.com/en-us/privacy/priva/priva-overview)

- **Test mode is the load-bearing default that trips up most new deployments.** Every policy starts in Test mode, generates zero alerts, and requires an explicit portal action to turn on — there's no cmdlet shortcut. Budget the recommended minimum 5-day test window into onboarding timelines rather than promising same-day live alerting. See: [Privacy risk management policies](https://learn.microsoft.com/en-us/privacy/priva/risk-management-policies)

- **An Alert is not a completed action — it's a notification that requires a manual "Create issue" step before any remediation becomes available.** Tenants that enable alerting but never assign anyone to triage the Alerts page will accumulate a growing backlog that looks, from the outside, identical to "the policy isn't working." Build issue-triage into the operational runbook at onboarding time, not as an afterthought. See: [Investigate and remediate alerts in Privacy Risk Management](https://learn.microsoft.com/en-us/privacy/priva/risk-management-alerts)

- **Priva's PowerShell cmdlets are read/prerequisite-only, and their names predate the Priva brand.** `Get-PrivacyManagementPolicy`/`Get-PrivacyManagementRule` are inherited from the product's earlier "Privacy Management"/Advanced Data Governance naming and aren't consistently documented in the current cmdlet reference — treat them as best-effort diagnostic tools, and route actual policy/SRR configuration through the portal. See: [Get started with Priva](https://learn.microsoft.com/en-us/privacy/priva/priva-setup)

- **Data-residency exclusions are a hard, unfixable gate.** Unlike a licensing or RBAC gap, a tenant provisioned in Norway, Poland, Qatar, Singapore, South Africa, South Korea, Spain, Sweden, Switzerland, or UAE local datacenters cannot use Priva at all — confirm this early for any client tenant showing zero Priva functionality despite correct licensing, rather than escalating it as a bug. See: [Get started with Priva](https://learn.microsoft.com/en-us/privacy/priva/priva-setup)

- **A Delete-type Subject Rights Request is the only truly irreversible action in this domain.** No `-WhatIf`, no undo, no PowerShell recovery path — always cross-check active legal holds and retention/regulatory-record status (`RetentionLabels-A.md`) before execution, and require an explicit human review pass of matched content first. See: [Microsoft Priva Subject Rights Requests](https://www.microsoft.com/en-us/security/business/privacy/microsoft-priva-subject-rights-requests)
