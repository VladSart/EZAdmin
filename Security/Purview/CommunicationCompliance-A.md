# Microsoft Purview Communication Compliance — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Microsoft Purview Communication Compliance policy architecture, role model, scoping rules, and workflow (Configure → Investigate → Remediate → Maintain)
- Supported communication channels: Exchange Online, Microsoft Teams, Viva Engage (Native Mode), Microsoft 365 Copilot/Copilot Chat, third-party archive-connector sources
- Integration points with Insider Risk Management and eDiscovery (Premium)

**Out of scope:**
- Insider Risk Management policy engine internals (see `Insider-Risk-A.md`)
- eDiscovery (Premium) case/hold mechanics beyond the escalation handoff (see `eDiscovery-A.md`)
- Data Loss Prevention — a related but architecturally separate Purview solution (see `DLP-Policy-A.md`)
- Trainable classifier training/tuning internals (see Microsoft Learn's trainable classifier docs, linked below)

**Assumes:**
- Tenant has a qualifying subscription: Microsoft Purview Suite (formerly Microsoft 365 E5 Compliance), Office 365 E3 + Advanced Compliance add-on, or Office 365 E5
- Reader has Global Administrator, Compliance Administrator, or Communication Compliance Admins-equivalent access to the Microsoft Purview portal
- Exchange Online PowerShell (`ExchangeOnlineManagement`) and Microsoft Graph PowerShell SDK are available for the adjacent checks this runbook relies on

---

## How It Works

<details><summary>Full architecture — policies, channels, and the review pipeline</summary>

### What Communication Compliance actually is

Communication Compliance is an **insider risk solution**, not a DLP or content-blocking tool. It never prevents a message from being sent — it copies matching messages into a review queue for human investigators, who then take action (notify, tag, escalate, or remove from Teams). This distinction matters operationally: a client who expects real-time blocking of policy-violating content wants DLP, not Communication Compliance.

Historically this feature was named **Supervisory Review** — the name survives in backend artifacts (system mailbox naming pattern `SupervisoryReview{*}`, some cmdlet parameter names) even though the product-facing name has been Communication Compliance for years. This matters when reading older internal documentation, forum posts, or compliance-boundary configuration that predates the rename.

### The four-stage workflow

```
CONFIGURE                 INVESTIGATE               REMEDIATE                MAINTAIN
─────────                 ───────────               ─────────                ────────
Assign role groups   →    Alerts generated     →    Resolve             →    Review dashboards
Create policy             automatically per         Tag (Compliant/          & exported logs
(template or custom)       policy match               Non-compliant/
                                                       Questionable)          Update policies as
Choose channels       →    Document review      →    Notify user             requirements change
                           (conversation/text/                                
Choose conditions +        detail views)         →   Escalate to             Check policy health
review %                                             another reviewer        (preview) warnings
                           Reviewing user
                           activity history      →   Report as
                                                      misclassified

                                                 →   Remove message
                                                      in Teams

                                                 →   Escalate for
                                                      investigation
                                                      (→ eDiscovery Premium)
```

### Policy templates and what they actually configure

Every template pre-selects locations, direction, review percentage, and conditions — but all templates draw from the *same* underlying detection signal types (classifiers, SITs, keyword dictionaries). The template just saves you from assembling those signals by hand.

| Template | Locations | Direction | Review % | Conditions |
|---|---|---|---|---|
| Detect conflict of interest | Exchange, Teams, Viva Engage | Internal | 100% | None (relies on two-group/two-user scoping) |
| Detect Copilot interactions | M365 Copilot / Copilot Chat | Inbound, Outbound, Internal | 100% | Prompt Shields, Protected material classifiers |
| Detect inappropriate content | Teams, Viva Engage | Inbound, Outbound, Internal | 100% | Hate, Violence, Sexual, Self-harm classifiers |
| Detect inappropriate images | Exchange, Teams | Inbound, Outbound, Internal | 100% | Adult, Racy image classifiers |
| Detect inappropriate text | Exchange, Teams, Viva Engage | Inbound, Outbound, Internal | 100% | Threat, Discrimination, Targeted harassment classifiers |
| Detect financial regulatory compliance | Exchange, Teams, Viva Engage | Inbound, Outbound | **10%** | Customer complaints, Gifts & entertainment, Money laundering, Regulatory collusion, Stock manipulation, Unauthorized disclosure |
| Detect sensitive info types | Exchange, Teams, Viva Engage | Inbound, Outbound, Internal | **10%** | SITs, custom dictionaries, attachments >1MB |
| Custom policy | Any combination, including third-party/AI | Any | Configurable | Any combination |

**The two 10%-review templates are the single most common source of "the policy isn't catching things" tickets** — a client who assumes every template reviews 100% of traffic will be surprised the *Regulatory compliance* and *Sensitive information* templates only sample one message in ten unless explicitly raised.

### The scoping model: scoped users, excluded users, reviewers — three different rule sets

Communication Compliance treats these three roles very differently, and conflating them is the most common configuration error:

- **Scoped users** (whose communications get reviewed): supports Distribution Groups and Microsoft 365 Groups (Microsoft's own documentation is inconsistent on whether mail-enabled security groups are also supported — the `communication-compliance-plan` article says no, the `communication-compliance-configure` article says yes; treat this as tenant/version-dependent and verify empirically rather than trusting either page blindly). Does **not** support dynamic distribution groups, nested distribution groups, or M365 Groups with dynamic membership — communications from members added via these unsupported types are silently never evaluated, with no error or warning anywhere in the portal.
- **Excluded users**: same supported/unsupported group types as scoped users.
- **Reviewers**: must be **individual users only** — no group type is supported at all. Reviewers must have an Exchange Online-hosted mailbox (this is how they receive the assignment notification email and how remediation actions are attributed) and must additionally be a member of the *Communication Compliance Analysts* or *Communication Compliance Investigators* role group, or their addition to the policy has no effect.

A policy typically supports around 20 groups/distribution lists total, though the exact ceiling shrinks as more conditions are added to the same policy (Microsoft doesn't publish a fixed hard number — it's a function of total policy complexity).

### Adaptive scopes vs. static groups

Rather than maintaining Distribution Groups by hand, a policy can use an **adaptive scope** — a saved query (e.g., "all users in department X") that re-evaluates membership dynamically. This avoids the administrative overhead of manually maintaining DGs as staff join/leave/move departments, and is Microsoft's recommended approach for anything beyond a small static group. Adaptive scopes are **not** compatible with **admin unit** scoping on the same policy — you must choose one or the other.

### Reviewer role groups and the anonymization split

There are five Communication Compliance-specific role groups plus four broader Entra/Purview roles/groups that carry equivalent access:

| Role group | Can configure policies | Can review/investigate | Can take advanced remediation (escalate, remove Teams msg, run Power Automate) | Sees real usernames |
|---|---|---|---|---|
| Communication Compliance | Yes | Yes | Yes | Depends on anonymization setting |
| Communication Compliance Admins | Yes | No | No | N/A (no review access) |
| Communication Compliance Analysts | No | Yes | No | **No** if anonymization is on — sees pseudonyms |
| Communication Compliance Investigators | No | Yes | Yes | **Always**, regardless of anonymization setting |
| Communication Compliance Viewers | No | Reports only | No | N/A (reports only) |

Equivalent to *Communication Compliance Admins*: Entra ID *Global Administrator*, Entra ID *Compliance Administrator*, Purview portal *Organization Management*, Purview portal *Compliance Administrator*.

**By default, Global Administrators do not have Communication Compliance access** — this is a deliberate separation-of-duties design (IT admins configure the plumbing; a different team investigates human communications) and catches nearly every engineer the first time they look for the menu option as a GA.

The anonymization setting (**Show anonymized versions of usernames**) is a tenant-wide toggle, not per-policy. When on, *Analysts* see a pseudonym like `AnonIS8-988` for every current and past match across every policy; *Investigators* always see real names regardless of this setting. Toggling this setting is retroactive — it re-anonymizes/de-anonymizes historical matches, not just future ones.

### Admin units for geographic/departmental scoping

Admin units restrict a role-group member to only the users/data within their assigned unit, turning them into a *restricted administrator*. Members without an admin unit assignment are *unrestricted administrators* with full tenant visibility. Restricted admins lose the ability to create a policy **from a template** — they can only create **custom** policies, since templates default to broader scoping assumptions that could exceed their unit's boundary.

### Channel-specific quirks

- **Exchange Online** is an *optional* channel as of recent releases — it used to be mandatory in every policy, and older internal runbooks/tickets referencing "Exchange must be selected" may be stale.
- **Teams**: individual users, distribution groups, or specific Teams channels must be explicitly selected for scoping — there's no "all Teams traffic" shortcut independent of user/group scoping. Users can self-report inappropriate Teams messages via **Report inappropriate content**, controlled per-policy (Teams Admin Center) by the `AllowSecurityEndUserReporting` property on the messaging policy — this is a completely separate mechanism from policy-driven detection and feeds a dedicated system policy (see below).
- **Viva Engage** requires **Native Mode** (all users in Entra ID, all groups as M365 Groups, all files in SharePoint) — a tenant still in legacy/hybrid Viva Engage mode is invisible to Communication Compliance regardless of policy configuration, with no error surfaced anywhere.
- **Generative AI**: Microsoft 365 Copilot/Copilot Chat interactions are covered under standard licensing with no extra billing. Non-Microsoft-365 AI applications (Copilot Studio bots, Entra/Purview Data Map-connected AI apps, Security Copilot, Fabric Copilot) require **pay-as-you-go billing** to be enabled tenant-wide before their interactions can be analyzed.
- **Third-party sources** (e.g., Bloomberg Instant Messaging) require a configured archive connector before CC can see anything from them at all.

### The User-reported messages system policy

This is a special, mostly-locked policy auto-created the moment a qualifying license is present in the tenant (can take up to **30 days** after license purchase to appear). Its only editable property is the **Reviewers** list — everything else (scope, conditions, locations) is fixed. Initial reviewers default to all *Communication Compliance Admins* members (or, if that group is empty, all *Global Administrators* — reinforcing why that role group should never be left empty). Admins should replace these defaults with actual HR/Compliance/Risk stakeholders immediately after first policy creation.

### Insider Risk Management integration

Communication Compliance can feed signals directly into Insider Risk Management. When configured via an IRM policy template (*Data leaks by risky users*, *Security policy violations by risky users*), CC auto-creates a dedicated policy named `Insider risk trigger - (date created)` using the *Detect inappropriate text* template's Threat/Harassment/Discrimination classifiers, scoped to all users. Any user who sends **5 or more** risky-classified messages within **24 hours** is automatically brought into scope for the linked IRM policy — with up to **48 hours** of latency between the triggering messages and the user appearing in-scope. IRM Investigators are not automatically able to see the full CC alert detail; they must be manually added to the *Communication Compliance Investigators* role group for that visibility.

### Escalation to eDiscovery (Premium)

The most serious CC alerts can be escalated directly into an eDiscovery (Premium) case, handing off data/case management to that workflow for legal hold, collection, review, and export. This is a one-way handoff for that specific alert's data — it doesn't disable the originating CC policy.

</details>

---

## Dependency Stack

```
Layer 6:  Alert & Review workflow (Purview portal only — Investigate/Remediate)
Layer 5:  Communication Compliance policy (portal-only CRUD, no PowerShell)
Layer 4:  Role groups (Admins/Analysts/Investigators/Viewers) — governs who sees what
Layer 3:  Channel eligibility (Exchange optional; Teams selection; Viva Engage Native Mode; AI billing)
Layer 2:  Scoping (users/groups — supported types only; reviewers always individual + EXO mailbox)
Layer 1:  Unified Audit Log ingestion — the single data pipe for detection and reporting
Layer 0:  Qualifying licence (Purview Suite / E5 Compliance / Advanced Compliance add-on)
```

A gap at Layer 0 or Layer 1 silently breaks everything above it with no error message anywhere in the portal — always validate bottom-up.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Global Admin can't see Communication Compliance menu at all | GA has no default CC access — separation-of-duties by design | Add GA (or any user) to *Communication Compliance Admins* role group |
| Policy exists, is Active, but zero alerts ever | Audit log disabled, or user not actually licensed | `Get-AdminAuditLogConfig`, `Get-MgUserLicenseDetail` |
| Policy catches "some but not most" matching messages | Using *Regulatory compliance* or *Sensitive information* template — both default to 10% review | Check **Review percentage** in policy settings |
| A specific user's messages never generate alerts despite being "in the policy" | Added via a dynamic/nested group or M365 Group with dynamic membership — unsupported, silently ignored | Confirm the actual group type used for scoping |
| Reviewer added to policy but never sees anything to review | Reviewer added as a group (unsupported) or lacks EXO mailbox, or isn't in Analysts/Investigators role group | `Get-EXOMailbox`, `Get-RoleGroupMember` |
| Teams messages never appear in any policy | Teams not selected as a location on the policy, or user only has an on-prem/external mailbox with no bridging DG | Review policy **Locations**; confirm bridging DG for on-prem/external users |
| Viva Engage messages never appear in any policy | Tenant not in Native Mode | Check Viva Engage admin center mode setting |
| Non-Microsoft AI app interactions never detected | Pay-as-you-go billing not enabled tenant-wide | Check **Usage center** in Purview portal |
| New policy "not working" hours after creation | Still inside normal processing latency (24h email / 48h Teams-Viva Engage-third-party) | Re-check after the latency window elapses |
| Nobody can manage CC policies after an admin left the org | Zero-admin lockout — both CC role groups empty | Restore access via Entra GA/Compliance Admin, add a new CC Admin |
| CC admins/reviewers can't open certain mailboxes during investigation | An eDiscovery compliance boundary excludes the `SupervisoryReview{*}` system mailboxes | `Get-ComplianceSecurityFilter`; add a filter permitting CC roles |
| Alerts stopped after a GCC ↔ Commercial cloud migration | Cases/alerts don't migrate between clouds — must be closed pre-migration | Confirm migration runbook closed all CC cases beforehand |

---

## Validation Steps

**1. Confirm the tenant subscription actually includes Communication Compliance**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
```
Expected: a SKU consistent with Purview Suite / M365 E5 Compliance / E5 / Advanced Compliance add-on present with consumed units > 0. Bad: no matching SKU anywhere in the tenant.

**2. Confirm audit log ingestion**
```powershell
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.com>
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
Expected: `True`. Bad: `False`.

**3. Confirm role group population (zero-admin check)**
```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>
"Communication Compliance","Communication Compliance Admins","Communication Compliance Analysts","Communication Compliance Investigators","Communication Compliance Viewers" |
    ForEach-Object { [PSCustomObject]@{ RoleGroup = $_; Members = (Get-RoleGroupMember -Identity $_ -ErrorAction SilentlyContinue).Name -join ", " } }
```
Expected: *Communication Compliance* or *Communication Compliance Admins* has at least one member. Bad: both empty.

**4. Confirm a specific reviewer meets all three requirements**
```powershell
Get-EXOMailbox -Identity <reviewer@tenant.com> | Select-Object DisplayName, RecipientTypeDetails
Get-RoleGroupMember -Identity "Communication Compliance Analysts" | Where-Object Name -eq "<reviewer display name>"
Get-RoleGroupMember -Identity "Communication Compliance Investigators" | Where-Object Name -eq "<reviewer display name>"
```
Expected: mailbox returns with `RecipientTypeDetails = UserMailbox`, and the reviewer appears in at least one of the two review role groups. Bad: any of the three checks comes back empty.

**5. Confirm a user's licence includes the right service plan**
```powershell
Get-MgUserLicenseDetail -UserId <user@tenant.com> | Select-Object -ExpandProperty ServicePlans |
    Where-Object { $_.ServicePlanName -match "COMMUNICATION_COMPLIANCE|INFORMATION_PROTECTION_COMPLIANCE" }
```
Expected: at least one matching, `ProvisioningStatus = Success` service plan. Bad: none found, or `ProvisioningStatus = Disabled`.

**6. Confirm Viva Engage Native Mode (if that channel is in scope)**
No PowerShell path — check Viva Engage admin center → **Native Mode** status page. Bad: any status other than fully native.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Foundation (Layers 0-1).** Confirm licensing and audit log ingestion before touching anything policy-specific — these two gaps produce *identical* symptoms (silent, total non-detection) to a dozen different policy misconfigurations, and ruling them out first prevents chasing the wrong root cause for hours.

**Phase 2 — Access (Layer 4).** Confirm the person reporting the issue (or trying to fix it) actually has the role-group membership their task requires. A GA "not seeing the menu" and an Analyst "not seeing real names" are both working as designed, not bugs.

**Phase 3 — Channel eligibility (Layer 3).** Before assuming a policy configuration problem, confirm the channel itself is even eligible: Viva Engage Native Mode, Teams location selection, AI billing for non-Microsoft apps. These are binary gates with no partial state.

**Phase 4 — Scoping (Layer 2).** Walk the actual group type used for scoped users, excluded users, and reviewers against the supported-type table. This phase resolves the majority of "policy is Active but this specific person is never flagged" tickets.

**Phase 5 — Policy content (Layer 5).** Only after Phases 1-4 pass clean, dig into the policy's own conditions, review percentage, and direction settings using the portal's **Test your conditions** feature to isolate whether the classifier/SIT itself is the gap.

**Phase 6 — Timing.** Before escalating anything as broken, confirm the elapsed time since the test message exceeds the documented processing latency for that channel.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full zero-admin lockout recovery</summary>

Use when: nobody in the tenant can access Communication Compliance and both relevant role groups are empty.

1. Sign in as Entra ID Global Administrator or Compliance Administrator (these carry equivalent access even without explicit CC role-group membership).
2. Microsoft Purview portal → **Settings** → **Roles and groups** → **Role groups** → *Communication Compliance Admins* → **Edit** → add at least two real, active users (never just one — this is exactly how the lockout happened the first time).
3. Wait up to 30 minutes for propagation, then verify with `Get-RoleGroupMember -Identity "Communication Compliance Admins"`.
4. Document the incident and add a standing recurring check (see Evidence Pack script below) to your MSP's monitoring so this doesn't recur silently.

**Rollback:** none — this is purely additive and restorative.

</details>

<details><summary>Playbook 2 — Raise review percentage on an under-reviewing template-based policy</summary>

Use when: a *Regulatory compliance* or *Sensitive information* policy is confirmed healthy end-to-end but the client expects full coverage.

1. Purview portal → **Communication Compliance** → **Policies** → select the policy → **Edit**.
2. On the conditions/percentage step, move **Review percentage** to 100%.
3. Communicate the increased reviewer workload implication to the client before making this change — 100% review of a high-volume mailbox population can produce a large alert volume increase overnight.

**Rollback:** move the slider back to the original percentage.

</details>

<details><summary>Playbook 3 — Restore CC admin/reviewer access to compliance-boundary-restricted mailboxes</summary>

Use when: CC admins or reviewers report they can't access certain content during investigation, and the tenant has eDiscovery compliance boundaries configured.

```powershell
Import-Module ExchangeOnlineManagement
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# Confirm whether a compliance security filter already exists for CC roles
Get-ComplianceSecurityFilter | Where-Object { $_.FilterName -like "*CC*" -or $_.Filters -like "*SupervisoryReview*" }

# If none exists, create one permitting CC admins/reviewers to reach the CC system mailboxes
New-ComplianceSecurityFilter -FilterName "CC_mailbox" `
    -Users <CCAdmin1@tenant.com>,<CCReviewer1@tenant.com> `
    -Filters "Mailbox_Name -like 'SupervisoryReview{*'" `
    -Action All
```

This only needs to be run once per tenant, even as new Communication Compliance policies are added later — the filter matches the underlying `SupervisoryReview{*}` mailbox naming pattern shared by all CC policies, a holdover from the feature's pre-rename name.

**Rollback:** `Remove-ComplianceSecurityFilter -Identity "CC_mailbox"` — only do this if compliance boundaries are being restructured entirely, since removing it re-blocks CC roles from those mailboxes.

</details>

<details><summary>Playbook 4 — Scale scoping to thousands of users via a managed distribution group</summary>

Use when: a large enterprise client needs a global Communication Compliance policy that auto-updates as staff join, without manually maintaining group membership.

```powershell
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.com>

# 1. Create a dedicated, locked-down distribution group (never reuse for other purposes)
New-DistributionGroup -Name "CC-Global-Scope" -Alias "CC-Global-Scope" `
    -MemberDepartRestriction "Closed" -MemberJoinRestriction "Closed" -ModerationEnabled $true

# 2. Pick an unused custom attribute to track membership state, then run this on a schedule
$Mbx = Get-Mailbox -RecipientTypeDetails UserMailbox -ResultSize Unlimited -Filter { CustomAttribute9 -eq $null }
foreach ($M in $Mbx) {
    Add-DistributionGroupMember -Identity "CC-Global-Scope" -Member $M.DistinguishedName -ErrorAction SilentlyContinue
    Set-Mailbox -Identity $M.Alias -CustomAttribute9 "CCAdded"
}
```

Add this distribution group as the scoped-users field in the target policy in the Purview portal (still no PowerShell path for that step). Consider an **adaptive scope** instead if the client's targeting logic is expressible as a query (department, location, etc.) rather than "everyone not yet flagged" — it removes the need for a scheduled script entirely.

**Rollback:** remove the group from the policy's scope in the portal; the distribution group itself can be safely deleted once the policy no longer references it (`Remove-DistributionGroup -Identity "CC-Global-Scope"`).

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects a Communication Compliance readiness/evidence bundle for escalation or a recurring health check.
.DESCRIPTION
    No PowerShell exists to query CC policies directly — this collects every adjacent signal that IS
    scriptable: audit log state, role group membership (incl. zero-admin risk), Teams end-user reporting
    policy state, and licence/service-plan presence for a supplied list of users.
#>
param(
    [string[]]$UsersToCheck = @(),
    [string]$OutputPath = "C:\Evidence\CommunicationCompliance-$(Get-Date -Format yyyyMMdd-HHmm)"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled |
    Export-Csv "$OutputPath\audit-log-state.csv" -NoTypeInformation

"Communication Compliance","Communication Compliance Admins","Communication Compliance Analysts","Communication Compliance Investigators","Communication Compliance Viewers" |
    ForEach-Object {
        [PSCustomObject]@{
            RoleGroup = $_
            Members   = (Get-RoleGroupMember -Identity $_ -ErrorAction SilentlyContinue).Name -join "; "
        }
    } | Export-Csv "$OutputPath\role-group-membership.csv" -NoTypeInformation

Get-CsTeamsMessagingPolicy | Select-Object Identity, AllowSecurityEndUserReporting |
    Export-Csv "$OutputPath\teams-end-user-reporting-policies.csv" -NoTypeInformation

if ($UsersToCheck.Count -gt 0) {
    $licenceReport = foreach ($u in $UsersToCheck) {
        $plans = (Get-MgUserLicenseDetail -UserId $u -ErrorAction SilentlyContinue).ServicePlans |
            Where-Object { $_.ServicePlanName -match "COMMUNICATION_COMPLIANCE|INFORMATION_PROTECTION_COMPLIANCE" }
        [PSCustomObject]@{
            User               = $u
            HasQualifyingPlan  = [bool]$plans
            ServicePlanNames   = ($plans.ServicePlanName -join "; ")
        }
    }
    $licenceReport | Export-Csv "$OutputPath\user-licence-check.csv" -NoTypeInformation
}

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check audit log ingestion | `Get-AdminAuditLogConfig \| Select UnifiedAuditLogIngestionEnabled` |
| Enable audit log | `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true` |
| List a CC role group's members | `Get-RoleGroupMember -Identity "Communication Compliance Admins"` |
| Add a user to a CC role group | `Add-RoleGroupMember -Identity "Communication Compliance Analysts" -Member <user>` |
| Confirm a reviewer's mailbox is on EXO | `Get-EXOMailbox -Identity <user> \| Select RecipientTypeDetails` |
| Check a user's CC-qualifying licence | `Get-MgUserLicenseDetail -UserId <user>` |
| Check/create a compliance-boundary filter for CC mailboxes | `Get-ComplianceSecurityFilter` / `New-ComplianceSecurityFilter -Filters "Mailbox_Name -like 'SupervisoryReview{*'"` |
| Check Teams end-user reporting policy | `Get-CsTeamsMessagingPolicy \| Select Identity, AllowSecurityEndUserReporting` |
| Create a managed scoping distribution group | `New-DistributionGroup -MemberDepartRestriction Closed -MemberJoinRestriction Closed -ModerationEnabled $true` |
| Get tenant ID for a support ticket | `(Get-MgOrganization).Id` |
| List subscribed SKUs (licence check) | `Get-MgSubscribedSku \| Select SkuPartNumber,ConsumedUnits` |

---

## 🎓 Learning Pointers

- **This is the only Purview solution in this repo with zero PowerShell coverage for its core object (the policy itself).** Attack Simulation Training at least has a Graph API; Communication Compliance has neither a cmdlet nor a documented Graph endpoint for policy CRUD as of mid-2026 — plan client-facing change management and audit trails around Purview portal screenshots and the exported modification-history CSV, not scripts. [MS Docs: Manage Communication Compliance policies](https://learn.microsoft.com/en-us/purview/communication-compliance-policies)
- **Global Admins are excluded from Communication Compliance by design** — a deliberate separation-of-duties control so that the people who configure infrastructure aren't automatically the people who read employees' flagged messages. Explain this explicitly to any client who assumes GA is a superset of all admin capability. [MS Docs: Assign permissions in Communication Compliance](https://learn.microsoft.com/en-us/purview/communication-compliance-permissions)
- **Two of the seven policy templates review only 10% of matching traffic by default** (*Regulatory compliance*, *Sensitive information*) — every other template reviews 100%. This asymmetry is the single most common source of "the policy is missing things" tickets on FINRA/SEC-regulated clients specifically, since those clients disproportionately use the 10%-default templates. [MS Docs: Communication Compliance policies — Policy templates](https://learn.microsoft.com/en-us/purview/communication-compliance-policies#policy-templates)
- **Reviewers and scoped/excluded users follow completely different group-support rules** — reviewers must always be individual users with EXO mailboxes; scoped/excluded users can be Distribution Groups or M365 Groups (never dynamic or nested). Conflating these two rule sets during policy setup produces silent, unexplained scoping gaps with no error anywhere in the portal.
- **Viva Engage Native Mode and non-Microsoft AI billing are binary, silent gates** — a policy can be perfectly configured and still see zero matches from these channels if the underlying tenant-wide prerequisite isn't met, with nothing in the policy UI indicating why. Always validate the channel prerequisite before debugging the policy itself. [MS Docs: Detect channel signals with Communication Compliance](https://learn.microsoft.com/en-us/purview/communication-compliance-channels)
- **The legacy "Supervisory Review" name is not just historical trivia — it's operationally load-bearing.** The `New-ComplianceSecurityFilter` workaround for compliance-boundary-restricted mailboxes only works because you know to search for the `SupervisoryReview{*}` naming pattern; searching for "Communication Compliance" in mailbox names will find nothing. Companion hotfix runbook: `CommunicationCompliance-B.md`.
