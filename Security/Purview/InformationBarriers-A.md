# Information Barriers — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Purview Information Barriers (IB) — segment design, policy design, application, and troubleshooting
- Enforcement surfaces: Microsoft Teams (chat, calls, meetings, screen share, @mentions, shared channels, people search), SharePoint Online, OneDrive for Business
- PowerShell management via Security & Compliance PowerShell (Exchange Online module's IB cmdlets)
- Common failure modes: segment overlap, Address Book Policy conflicts, stale attribute sync, stuck policy application

**Out of scope:**
- Exchange mail flow "ethical wall" rules (a separate, transport-rule-based mechanism — IB does not govern email)
- Restricted SharePoint site permissions unrelated to IB (see `M365/SharePoint-OneDrive/Permissions-A.md`)
- Conditional Access-based access restrictions (see `Security/ConditionalAccess/`)

**Assumed baseline:**
- Microsoft 365 E5, E5 Compliance, or the standalone Information Barriers/Advanced Compliance add-on licensed for every user who must be evaluated
- Tenant admin has Compliance Administrator or Information Barriers admin role assignment in the Microsoft Purview compliance portal
- Connected to Security & Compliance PowerShell (`Connect-IPPSSession`)
- No pre-existing Exchange Address Book Policies in the tenant (mutually exclusive with IB)

---

## How It Works

<details><summary>Full architecture</summary>

### Conceptual Model

Information Barriers restrict which users can find, communicate, and collaborate with which other users. It is built on two objects:

- **Organization Segments** — a named group of users defined by a filter against a supported Entra ID attribute (not a security group; not a dynamic group — a purpose-built IB construct).
- **Information Barrier Policies** — a rule that says "users in segment X are Blocked from / Allowed only to communicate with users in segment Y (or Z)."

### Evaluation Pipeline

```
Entra ID user attribute (Department, MemberOf, Company, ExtensionAttribute1-15, etc.)
        │
        ▼
Organization Segment (UserGroupFilter matches the attribute)
        │  A user may match at most ONE segment per policy dimension.
        │  Matching >1 segment = IBPolicyConflict at application time.
        ▼
Information Barrier Policy (AssignedSegment + SegmentsAllowed / SegmentsBlocked)
        │  Mode: Block (deny listed segments) or Allow (permit ONLY listed segments)
        ▼
Start-InformationBarrierPoliciesApplication
        │  Full-tenant batch job — evaluates EVERY user, not just changed ones
        │  ~30-35 min to start, ~1 hour per 5,000 accounts to complete
        ▼
Policy state propagated to:
  ├── Exchange Online (recipient-level policy assignment, queryable via
  │     Get-InformationBarrierRecipientStatus / Get-ExoInformationBarrierRelationship)
  ├── Microsoft Teams client/service
  │     — People search results filtered
  │     — 1:1 and group chat initiation blocked
  │     — Calls, screen share, @mentions blocked
  │     — Meeting invites to barred users blocked/removed
  │     — Shared channel membership restricted
  └── SharePoint Online / OneDrive
        — Sharing invitations to barred users blocked
        — Site/library access restricted where IB-aware sharing checks apply
```

### Why Segments Are Not Groups

A common design mistake is treating a Segment like a security or M365 group. It isn't — a Segment is a live filter query re-evaluated against Entra ID attributes every time policies are applied. There is no membership list to manually curate; the filter *is* the membership definition. This means:

- Changing a user's `Department` attribute moves them between segments automatically on next application — no manual re-adding required.
- Two segments with overlapping filter logic will always produce the same conflict for any user matching both, until the filters themselves are corrected.
- Segment membership cannot be queried like a group membership list — you query it indirectly via `Get-InformationBarrierRecipientStatus` per user, or infer it by reading each segment's `UserGroupFilter`.

### Allow vs. Block Policies

- **Block policy**: the assigned segment can talk to everyone EXCEPT the listed blocked segment(s). Used when most of the org should mix freely except two specific groups (e.g., Research vs. Sales in a conflict-of-interest scenario).
- **Allow policy**: the assigned segment can ONLY talk to the listed allowed segment(s) — everyone else is implicitly blocked. Used for highly regulated, closed-loop scenarios (e.g., a deal team that must only communicate within itself and with outside counsel).

Mixing Allow and Block policies on the same segment in the same direction is not supported and is the second most common design-time cause of unexpected enforcement.

### FwdSync and Propagation Delay

Entra ID attribute changes do not reach Exchange Online (the system of record IB actually evaluates against) instantly. The ForwardSync (FwdSync) process typically takes **up to 30 minutes**. Engineers who edit a user's `Department` and immediately run `Start-InformationBarrierPoliciesApplication` will often see the reapplication complete against the *old* attribute value, producing a confusing "I already fixed this, why is it still blocked" ticket.

</details>

---

## Dependency Stack

```
Microsoft 365 E5 / E5 Compliance / Advanced Compliance add-on licence
    │   Required per-user for evaluation; unlicensed users are invisible to IB
    │
Entra ID attribute accuracy
    │   Department, MemberOf, Company, ExtensionAttribute1-15
    │   (hybrid) sourced from on-prem AD via Entra Connect — check sync health first
    │       if attributes look wrong, this is an identity problem, not an IB problem
    │
No Exchange Address Book Policies present in tenant
    │   ABP and IB are architecturally mutually exclusive — ANY ABP blocks ALL IB
    │   policy application, tenant-wide, not just for ABP-scoped users
    │
Organization Segments (up to 5,000 per org)
    │   Each = UserGroupFilter query against one attribute
    │   A user may match at most 1 segment per policy dimension
    │
Information Barrier Policies (Block or Allow mode)
    │   Every segment requiring enforcement must be referenced by an active policy
    │
Start-InformationBarrierPoliciesApplication (full-tenant batch job)
    │   ~30-35 min to start, ~1 hr / 5,000 accounts to complete
    │   Get-InformationBarrierPoliciesApplicationStatus tracks progress/failures
    │
Enforcement surface (client + service side)
    ├── Microsoft Teams — search, chat, calls, meetings, @mentions, shared channels
    └── SharePoint Online / OneDrive — sharing restrictions
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| User can't find/message someone in Teams | IB policy working as designed | `Get-InformationBarrierPolicy` — check AssignedSegment/SegmentsBlocked |
| Two users who should be blocked can still chat | User(s) not in any segment, or segment has no policy | `Get-InformationBarrierRecipientStatus -Identity X -Identity2 Y` |
| Policy application fails outright, every time | Exchange Address Book Policy present | `Get-AddressBookPolicy` |
| Some users in a segment are enforced, others aren't | Partial application failure — segment conflict for specific users | `Get-InformationBarrierPoliciesApplicationStatus` → Failed Recipients, then audit log |
| Application status stuck "Not started" >45 min | Job failed to start — check audit log for definition errors | `Search-UnifiedAuditLog -RecordType InformationBarrierPolicyApplication` |
| Application "In progress" for multiple days | Genuinely hung service-side job | Escalate to Microsoft Support with Evidence Pack |
| Attribute was just fixed but IB still shows old behaviour | FwdSync propagation delay (~30 min) or application not yet rerun | `Get-EXORecipient -Properties Department` to confirm EXO has the new value |
| Client wants to block email between two departments and thinks IB does it | Scope mismatch — IB doesn't cover Exchange mail flow | Redirect to Exchange transport rule / ethical wall design |
| IB was working, then stopped after an Entra Connect change | Attribute drift from a sync rule change upstream | Check Entra Connect sync rules, not IB config |

---

## Validation Steps

**1. Confirm licensing coverage**
```powershell
Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -match "E5|COMPLIANCE|INFORMATION_PROTECTION"} |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Available";E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}}
```
Good: SKU present with available/consumed units matching users in scope. Bad: no matching SKU — IB will silently not evaluate unlicensed users.

**2. Confirm no Address Book Policies exist**
```powershell
Get-AddressBookPolicy
```
Good: empty result. Bad: any result — this blocks ALL IB application tenant-wide until removed.

**3. Confirm segment filters resolve to the expected population**
```powershell
Get-OrganizationSegment | Select-Object Name, UserGroupFilter
```
Cross-check each `UserGroupFilter` against real user attributes with a sample query:
```powershell
Get-MgUser -Filter "department eq 'Research'" -Property DisplayName,Department | Select-Object DisplayName,Department
```
Good: the population returned matches business expectation. Bad: unexpected users included/excluded — the filter attribute is stale or the wrong attribute was chosen.

**4. Confirm every enforced segment has an active policy**
```powershell
Get-InformationBarrierPolicy | Select-Object Name, AssignedSegment, SegmentsAllowed, SegmentsBlocked, State
```
Good: `State: Active` for every policy that should be enforcing. Bad: `Inactive` or missing entirely for a segment that needs restriction.

**5. Confirm the last application run completed cleanly**
```powershell
Get-InformationBarrierPoliciesApplicationStatus -All $true | Select-Object -First 5 Identity, Status, TotalRecipients, FailedRecipients
```
Good: `Status: Complete`, `FailedRecipients: 0`. Bad: any `Failed` count or non-Complete status.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm the report is real vs. expected behaviour
1. Identify the two (or more) users involved.
2. Run `Get-InformationBarrierRecipientStatus -Identity <A> -Identity2 <B>`.
3. Cross-reference against `Get-InformationBarrierPolicy` for the relevant segments.
4. If the policy's AssignedSegment/SegmentsBlocked exactly matches the reported symptom — this is working as designed. Stop here and communicate that to the requester rather than treating it as a defect.

### Phase 2 — Rule out tenant-wide blockers
1. Check for Address Book Policies (`Get-AddressBookPolicy`). If any exist, this must be resolved before any other IB troubleshooting is meaningful — it blocks everything.
2. Check licensing coverage for the affected users.
3. Check the last application run status.

### Phase 3 — Isolate to segment definition vs. policy definition vs. application failure
1. If the user has no segment at all → segment filter problem (attribute mismatch) or the user hasn't been captured by any filter — segment definition issue.
2. If the user has a segment but no policy references it → policy definition issue.
3. If both segment and policy look correct but enforcement isn't happening → check whether the application actually ran successfully since the segment/policy was created or last changed.

### Phase 4 — Root-cause a failed or partial application
1. Pull the application `Identity` from `Get-InformationBarrierPoliciesApplicationStatus`.
2. Search the audit log (`RecordType InformationBarrierPolicyApplication`) for that Identity.
3. Read `ErrorDetails` per failed `UserId`. The overwhelming majority resolve to `IBPolicyConflict` (segment overlap).
4. Fix the overlapping segment filter(s), reapply, re-verify Failed Recipients drops to 0.

### Phase 5 — Confirm attribute-level fixes have actually propagated
1. If the fix involved changing a user's Entra attribute, confirm it landed in Exchange Online via `Get-EXORecipient` before assuming reapplication failed.
2. Allow the full FwdSync window (~30 min) before escalating a "the fix didn't take" report.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Stand up a new Information Barrier scenario from scratch</summary>

1. Confirm licensing covers all users in scope for both segments.
2. Choose the segmentation attribute — `Department` for org-chart-based restrictions, `ExtensionAttribute1-15` for ad hoc/custom groupings not tied to HR data, `MemberOf` when segment membership should track an existing group.
3. Design segment filters to be **mutually exclusive** — verify no user can match two segments simultaneously before creating policies.
   ```powershell
   New-OrganizationSegment -Name "Segment-Research" -UserGroupFilter "Department -eq 'Research'"
   New-OrganizationSegment -Name "Segment-Sales" -UserGroupFilter "Department -eq 'Sales'"
   ```
4. Create the policy in the appropriate mode.
   ```powershell
   New-InformationBarrierPolicy -Name "Research-Sales-Block" `
       -AssignedSegment "Segment-Research" -SegmentsBlocked "Segment-Sales" -State Active
   New-InformationBarrierPolicy -Name "Sales-Research-Block" `
       -AssignedSegment "Segment-Sales" -SegmentsBlocked "Segment-Research" -State Active
   ```
   > Both directions must be defined explicitly — a policy on Segment A blocking Segment B does not automatically create the reverse restriction.
5. Apply.
   ```powershell
   Start-InformationBarrierPoliciesApplication
   ```
6. Validate with `Get-InformationBarrierPoliciesApplicationStatus` until `Complete`, then spot-check with `Get-InformationBarrierRecipientStatus` for a sample user from each segment.

**Rollback:** `Set-InformationBarrierPolicy -Identity <name> -State Inactive` then reapply — deactivates without deleting, preserving the definition for later re-enable.

</details>

<details><summary>Playbook 2 — Resolve a segment-overlap application failure</summary>

1. Pull failed `UserId`s from the audit log per Diagnosis Step 5 in the companion hotfix runbook.
2. For each failed user, list every segment whose filter could match them:
   ```powershell
   $user = Get-MgUser -UserId <upn> -Property Department,CompanyName,OnPremisesExtensionAttributes
   Get-OrganizationSegment | Where-Object {
       # manually cross-reference $_.UserGroupFilter logic against $user's attribute values
       $true
   } | Select-Object Name, UserGroupFilter
   ```
3. Narrow the overlapping filter(s) so only one segment matches per user — prefer tightening the filter over moving the user's attribute, since the latter can have downstream effects outside IB (reporting, dynamic groups, etc.).
4. `Set-OrganizationSegment -Identity <name> -UserGroupFilter <corrected filter>`
5. Reapply and confirm `FailedRecipients: 0` on the next application status check.

**Rollback:** revert the `UserGroupFilter` value, reapply.

</details>

<details><summary>Playbook 3 — Remove Information Barriers entirely (decommission)</summary>

1. Confirm with the client this is intentional — IB removal immediately un-restricts all previously blocked communication once the next application completes.
2. Deactivate or remove policies:
   ```powershell
   Get-InformationBarrierPolicy | ForEach-Object { Set-InformationBarrierPolicy -Identity $_.Name -State Inactive }
   ```
3. Apply the deactivation:
   ```powershell
   Start-InformationBarrierPoliciesApplication
   ```
4. Optionally remove segments once no policy references them:
   ```powershell
   Remove-OrganizationSegment -Identity "<segment name>"
   ```

**Rollback:** policies can be reactivated (`-State Active`) and reapplied at any time as long as they were deactivated rather than deleted; deleted segments must be recreated from scratch.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Information Barriers diagnostic evidence for escalation or handoff.
#>
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

$outDir = "$env:TEMP\IB-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Get-AddressBookPolicy | Export-Csv "$outDir\AddressBookPolicies.csv" -NoTypeInformation
Get-OrganizationSegment | Select-Object Name, Guid, UserGroupFilter |
    Export-Csv "$outDir\Segments.csv" -NoTypeInformation
Get-InformationBarrierPolicy | Select-Object Name, Guid, AssignedSegment, SegmentsAllowed, SegmentsBlocked, State |
    Export-Csv "$outDir\Policies.csv" -NoTypeInformation
Get-InformationBarrierPoliciesApplicationStatus -All $true |
    Export-Csv "$outDir\ApplicationHistory.csv" -NoTypeInformation

Write-Host "Evidence collected in $outDir" -ForegroundColor Green
#>
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Connect-IPPSSession` | Connect to Security & Compliance PowerShell (required for all IB cmdlets) |
| `Get-InformationBarrierRecipientStatus -Identity <u>` | Show segment/policy assignment for one user |
| `Get-InformationBarrierRecipientStatus -Identity <u1> -Identity2 <u2>` | Compare two users' IB relationship |
| `Get-InformationBarrierPolicy` | List all IB policies and their segment assignments |
| `New-InformationBarrierPolicy` | Create a new Block or Allow policy |
| `Set-InformationBarrierPolicy -State Inactive` | Deactivate a policy without deleting it |
| `Get-OrganizationSegment` | List all segments and their filters |
| `New-OrganizationSegment` | Define a new segment |
| `Set-OrganizationSegment -UserGroupFilter` | Fix a segment's membership filter (most common overlap fix) |
| `Start-InformationBarrierPoliciesApplication` | Apply all active policies tenant-wide |
| `Stop-InformationBarrierPoliciesApplication -Identity <guid>` | Cancel a stuck application run |
| `Get-InformationBarrierPoliciesApplicationStatus [-All $true]` | Check status/history of applications |
| `Get-AddressBookPolicy` | Check for the #1 tenant-wide IB blocker |
| `Get-ExoInformationBarrierRelationship` | Alternate cmdlet for per-user attribute/segment detail |
| `Search-UnifiedAuditLog -RecordType InformationBarrierPolicyApplication` | Pull failure detail for a specific application run |

---

## 🎓 Learning Pointers

- **Segments are live filter queries, not static group membership.** Every application run re-evaluates every user's attributes against every segment filter. This means IB self-heals when attributes are corrected, but also means a single mistyped filter silently mis-segments an entire population until caught. See: [Information Barriers attributes](https://learn.microsoft.com/en-us/purview/information-barriers-attributes)

- **Address Book Policies and IB cannot coexist, tenant-wide.** This is an all-or-nothing architectural constraint, not a per-user setting — one legacy ABP from an unrelated Exchange project can silently fail 100% of IB policy applications. Always check for ABPs first on any "IB isn't applying" ticket. See: [Address book policies](https://learn.microsoft.com/en-us/exchange/address-books/address-book-policies/address-book-policies)

- **Policy application is O(all users), always.** There is no incremental/delta application mode — every run walks the entire tenant (~1 hour per 5,000 accounts). Design segment and policy changes to be batched rather than applied one at a time when doing a larger rollout, to avoid unnecessary multi-hour waits between iterations. See: [Get started with Information Barriers](https://learn.microsoft.com/en-us/purview/information-barriers-policies)

- **IB's enforcement surface is Teams + SharePoint/OneDrive — not Exchange mail.** This is the single most common scoping misunderstanding when a client asks for IB expecting it to also stop email between two groups. That requires a separate Exchange transport rule ("ethical wall"). Clarify scope during requirements gathering, not after go-live. See: [Information Barriers in Microsoft Teams](https://learn.microsoft.com/en-us/purview/information-barriers-teams)

- **FwdSync introduces a real propagation delay (~30 min) between Entra ID and Exchange Online.** Reapplying immediately after an attribute fix will often reapply against the stale value. Build this delay into change windows for any IB remediation involving attribute edits. See: [Manage Information Barriers policies](https://learn.microsoft.com/en-us/purview/information-barriers-edit-segments-policies)

- **A segment cap of 5,000 and a per-user max of matching exactly one segment per dimension** means large, complex organizational structures (matrix orgs, multi-brand holding companies) need careful up-front filter design — retrofitting segmentation after policies are live is significantly more disruptive than designing it correctly during initial rollout. See: [Get started with Information Barriers](https://learn.microsoft.com/en-us/purview/information-barriers-policies)
