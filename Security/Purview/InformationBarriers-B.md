# Microsoft Purview Information Barriers — Hotfix Runbook (Mode B: Ops)
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

Run these first — Information Barriers (IB) issues are almost always segment/policy/application-status problems, not client bugs.

```powershell
# Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# 1. Check the most recent policy application status
Get-InformationBarrierPoliciesApplicationStatus

# 2. Check whether the affected user is even subject to an IB policy
Get-InformationBarrierRecipientStatus -Identity <userA@domain.com>

# 3. Compare two users who should (or shouldn't) be blocked from each other
Get-InformationBarrierRecipientStatus -Identity <userA@domain.com> -Identity2 <userB@domain.com>

# 4. Check for Exchange Address Book Policies — these silently block IB application entirely
Get-AddressBookPolicy | Select-Object Name, Guid
```

**Interpretation:**

| Result | Action |
|--------|--------|
| `Get-AddressBookPolicy` returns any results | Fix 1 — Remove conflicting Address Book Policies |
| Recipient status shows no `ExoPolicyId` / no segment | Fix 2 — User not in any segment; assign attribute or policy |
| Application status = `Failed` | Fix 3 — Diagnose via audit log for segment conflict |
| Application status = `Not started` for >45 min | Fix 4 — Re-run application, check for stuck job |
| Application status = `In progress` for multiple days | Fix 5 — Escalate to Microsoft Support |
| User in >1 segment (`IBPolicyConflict` in audit log) | Fix 6 — Fix segment overlap |
| Recently edited a user's Entra attributes, IB not reflecting it | Fix 7 — Wait for FwdSync, then reapply |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft 365 E5 / E5 Compliance (or Advanced Compliance add-on) licence
  └── assigned to every user who must be evaluated by IB
        │
Entra ID user attributes populated correctly
  ├── Department, MemberOf, Company, or ExtensionAttribute1–15
  └── (hybrid) synced from on-prem AD via Entra Connect — stale attrs = stale segments
        │
No Exchange Address Book Policies in the tenant
  └── ABPs and IB are mutually exclusive; ABP presence blocks ALL policy application
        │
Organization Segments defined (New-OrganizationSegment / Purview portal)
  ├── Each segment = a filter query against a supported attribute
  ├── Max 5,000 segments per org
  └── A user may belong to AT MOST 1 segment per policy dimension — overlap = conflict
        │
Information Barrier Policies defined per segment pair
  ├── Mode: Block (deny) or Allow (only these can talk) — cannot mix on same segment
  └── Every segment that needs enforcement must be referenced by an active policy
        │
Start-InformationBarrierPoliciesApplication run
  ├── ~30–35 min to start, ~1 hour per 5,000 user accounts to complete
  └── Processes EVERY user in the org, not just changed ones
        │
Enforcement surfaces in:
  ├── Microsoft Teams — search, chat, calls, screen share, @mentions, meeting invites, shared channels
  ├── SharePoint Online / OneDrive — sharing and access restrictions
  └── (Does NOT affect Exchange mail flow — that requires separate transport rules / ethical walls)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the user is actually in an IB policy**
```powershell
Get-InformationBarrierRecipientStatus -Identity <user@domain.com>
```
Expected: output includes a segment name and `*ExoPolicyId: <GUID>`.
Bad: no segment listed at all → the user has never matched a segment filter. This is "working as designed," not a bug — go to Fix 2.

**Step 2 — Confirm which segments a policy covers**
```powershell
Get-InformationBarrierPolicy -Identity <ExoPolicyId from Step 1>
```
Expected: `AssignedSegment`, `SegmentsAllowed`, `SegmentsBlocked` fields populated as designed.
Example — `AssignedSegment: Sales`, `SegmentsBlocked: {Research}` means Sales↔Research communication is blocked by design. If this matches the reported symptom, IB is working correctly and there is no fix to apply — communicate this to the requester.

**Step 3 — Verify segment membership is attribute-accurate**
```powershell
Get-OrganizationSegment -Identity <segment GUID or name>
```
Check the `UserGroupFilter` value against the user's actual Entra attributes (`Get-MgUser -UserId <user@domain.com> -Property Department,CompanyName,OnPremisesExtensionAttributes`). A stale or wrong attribute is the #1 root cause of "wrong people are/aren't blocked."

**Step 4 — Check the last policy application run**
```powershell
Get-InformationBarrierPoliciesApplicationStatus
# For full history:
Get-InformationBarrierPoliciesApplicationStatus -All $true
```
Expected: `Status: Complete`, `Failed Recipients: 0`.
Bad:
- `Not started` past 45 min → Fix 4
- `Failed` → Fix 3
- `Complete` but `Failed Recipients > 0` → Fix 3 (partial failure, same root cause)

**Step 5 — Pull the failure detail from the audit log (only if Step 4 shows failures)**
```powershell
$appId = (Get-InformationBarrierPoliciesApplicationStatus).Identity
$detailedLogs = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date) `
    -RecordType InformationBarrierPolicyApplication -ResultSize 1000 |
    Where-Object { $_.AuditData -match $appId }
$detailedLogs | ForEach-Object { $_.AuditData | ConvertFrom-Json } | Select-Object UserId, ErrorDetails
```
Expected error text for the most common cause: `Status: IBPolicyConflict. Error: IB segment "X" and IB segment "Y" has conflict and cannot be assigned to the recipient.` → Fix 6.

---
## Common Fix Paths

<details>
<summary>Fix 1 — Remove conflicting Exchange Address Book Policies</summary>

**ABPs and Information Barriers cannot coexist. If any ABP exists in the tenant, IB policy application fails outright — not partially, entirely.**

```powershell
Get-AddressBookPolicy | Select-Object Name, Guid

# Remove each one after confirming with the customer this is safe
Remove-AddressBookPolicy -Identity "<ABP name>"

# Re-run IB application once ABPs are gone
Start-InformationBarrierPoliciesApplication
```

**Rollback:** ABPs can be recreated with `New-AddressBookPolicy`, but doing so will break IB again. Confirm with the client which feature they actually need before removing — this is a design decision, not a quick fix, if the client has an active ABP use case (e.g. multi-tenant hosting scenarios).

</details>

<details>
<summary>Fix 2 — User not in any segment</summary>

**No segment membership means no IB evaluation at all — the user is fully unrestricted by IB (may still be restricted by other mechanisms).**

```powershell
# Confirm which attribute the target segment filters on
Get-OrganizationSegment | Select-Object Name, UserGroupFilter

# Fix the user's attribute in Entra ID to match (example: Department)
Update-MgUser -UserId <user@domain.com> -Department "Research"

# Wait ~30 min for FwdSync, or force reapplication immediately
Start-InformationBarrierPoliciesApplication
```

If no segment exists yet for the population you need to restrict, create one:
```powershell
New-OrganizationSegment -Name "Research" -UserGroupFilter "Department -eq 'Research'"
New-InformationBarrierPolicy -Name "Sales-Research-Block" -AssignedSegment "Sales" -SegmentsBlocked "Research" -State Active
Start-InformationBarrierPoliciesApplication
```

**Rollback:** `Remove-InformationBarrierPolicy -Identity <name>` then reapply — this removes the restriction for everyone in scope, not just one user.

</details>

<details>
<summary>Fix 3 — Diagnose and fix a failed application</summary>

**A "Failed" status with no further detail is never actionable on its own — always pull the audit log first (Diagnosis Step 5) before touching segments.**

```powershell
# After identifying the specific error from Step 5, most common fix (segment overlap):
Set-OrganizationSegment -Identity "<segment name>" -UserGroupFilter "Department -eq 'Sales' -and CompanyName -ne 'Contoso Research'"

# Reapply
Start-InformationBarrierPoliciesApplication
```

**Rollback:** Revert `UserGroupFilter` to its prior value via the same cmdlet, then reapply.

</details>

<details>
<summary>Fix 4 — Application stuck at "Not started" or hung "In progress"</summary>

**Past 45 minutes with no start, or multiple days still "In progress," the job is stuck, not slow.**

```powershell
# Get the Identity of the stuck run
$stuck = Get-InformationBarrierPoliciesApplicationStatus
$stuck.Identity

# Stop it
Stop-InformationBarrierPoliciesApplication -Identity $stuck.Identity

# Re-run
Start-InformationBarrierPoliciesApplication
```

> Do not run `Start-InformationBarrierPoliciesApplication` a second time while one is already in progress — it will queue behind the stuck job rather than replacing it. Always stop first.

**Rollback:** N/A — this only clears a stuck job, it does not change policy state.

</details>

<details>
<summary>Fix 5 — Escalate a genuinely hung application</summary>

If `Stop-InformationBarrierPoliciesApplication` + reapply still doesn't complete within the expected window (~1 hour per 5,000 users), this is a service-side issue — gather the Escalation Evidence pack below and open a Microsoft Support ticket. Do not keep retrying; repeated Start/Stop cycles on a large tenant can extend the eventual completion time.

</details>

<details>
<summary>Fix 6 — User assigned to more than one segment (segment overlap)</summary>

**This is the single most common cause of both application failures and unpredictable per-user behaviour.**

```powershell
# Find every segment a user's attributes could match
Get-OrganizationSegment | ForEach-Object {
    $_ | Select-Object Name, UserGroupFilter
}

# Narrow the overlapping segment's filter so it no longer double-matches
Set-OrganizationSegment -Identity "<segment name>" -UserGroupFilter "<narrower filter>"

# Reapply
Start-InformationBarrierPoliciesApplication
```

A user can belong to only one segment per IB evaluation — if two segment filters both match the same user (e.g. `Department -eq 'Sales'` and `MemberOf -eq 'Sales-EMEA'` both catch the same person), fix the filter to be mutually exclusive rather than trying to work around it downstream.

**Rollback:** Revert filter change, reapply.

</details>

<details>
<summary>Fix 7 — Entra attribute change not reflected in IB (FwdSync delay)</summary>

**Attribute edits in Entra ID take up to ~30 minutes to propagate to Exchange Online (FwdSync) before IB will see the new value — this is normal, not a bug.**

```powershell
# Confirm the current attribute value has landed in EXO
Get-EXORecipient -Identity <user@domain.com> -Properties CustomAttribute1,Department | Format-List

# If it's landed and IB still hasn't picked it up, force reapplication
Start-InformationBarrierPoliciesApplication
```

If more than 60 minutes have passed and the attribute still hasn't synced to EXO, check Entra Connect sync health (if hybrid) rather than IB — this is an identity sync issue, not an IB issue.

</details>

---
## Escalation Evidence

```
=== INFORMATION BARRIERS — ESCALATION PACK ===
Date/Time:              ___________________________
Tenant ID:               ___________________________ (Get-MgOrganization | Select-Object Id)
Affected User(s) UPN:    ___________________________
Expected Segment(s):     ___________________________
Policy Name / GUID:      ___________________________
Application Identity:    ___________________________ (from Get-InformationBarrierPoliciesApplicationStatus)

--- DIAGNOSTIC CHECKLIST ---
[ ] Get-AddressBookPolicy returns any results:      Yes / No
[ ] Get-InformationBarrierRecipientStatus segment:   ___________
[ ] Get-InformationBarrierPolicy Assigned/Allowed/Blocked segments: ___________
[ ] Get-OrganizationSegment UserGroupFilter matches actual user attrs: Yes / No
[ ] Last application status:                         Complete / Failed / Not started / In progress
[ ] Failed Recipients count:                         ___________
[ ] Audit log ErrorDetails (if failed):              ___________________________
[ ] Duration since Start-InformationBarrierPoliciesApplication was run: ___________

--- ISSUE DESCRIPTION ---
Expected behaviour:   ___________________________
Actual behaviour:     ___________________________
First occurrence:     ___________________________
Steps already tried:  ___________________________

--- EXPORTS TO ATTACH ---
[ ] Get-InformationBarrierRecipientStatus output for all affected users
[ ] Get-InformationBarrierPoliciesApplicationStatus -All $true output
[ ] Search-UnifiedAuditLog export (RecordType InformationBarrierPolicyApplication)
[ ] Get-OrganizationSegment output for every segment in the affected policy

--- MICROSOFT SUPPORT LINKS ---
Open ticket at: https://admin.microsoft.com → Support → New service request
Category: Compliance → Information Barriers
Tenant ID required (Get-MgOrganization | Select-Object Id)
```

---
## 🎓 Learning Pointers

- **A "working" Information Barrier looks identical to a "broken" one from the user's chair** — both present as "I can't find/message this person." Always confirm the policy's intended AssignedSegment/SegmentsBlocked relationship (Diagnosis Step 2) before treating this as an incident; a large share of IB tickets are the policy doing exactly what it was designed to do. See: [Resolve communication issues in Information Barriers](https://learn.microsoft.com/en-us/microsoft-365/troubleshoot/information-barriers/information-barriers-troubleshooting)

- **Address Book Policies and Information Barriers are mutually exclusive at the tenant level, not the user level.** One leftover ABP from a prior Exchange project — even one nobody remembers creating — silently fails every IB policy application. Check for ABPs first, before touching segments, on any "IB isn't applying at all" ticket. See: [Address book policies](https://learn.microsoft.com/en-us/exchange/address-books/address-book-policies/address-book-policies)

- **Segment overlap is the #1 real-world root cause of application failures.** Users can only belong to one segment per policy dimension; two segment filters that both match the same attribute combination will produce an `IBPolicyConflict` for every user caught in the overlap. Design segment filters to be mutually exclusive from day one. See: [Information Barriers attributes](https://learn.microsoft.com/en-us/purview/information-barriers-attributes)

- **Policy application is a full-tenant batch job, not an incremental sync.** Every `Start-InformationBarrierPoliciesApplication` run re-evaluates every user in the org (~1 hour per 5,000 accounts) — there's no "just apply to this one user" fast path. Set expectations accordingly before promising a quick turnaround on a single-user fix. See: [Get started with Information Barriers](https://learn.microsoft.com/en-us/purview/information-barriers-policies)

- **IB governs Teams and SharePoint/OneDrive — it does not touch Exchange mail flow.** If a client's actual requirement is "these two departments must never email each other," IB alone won't do it; that needs a separate Exchange transport rule (an "ethical wall"). Scope this correctly during requirements gathering, not after go-live. See: [Information Barriers in Microsoft Teams](https://learn.microsoft.com/en-us/purview/information-barriers-teams)

- **Entra attribute edits aren't instant in IB's eyes.** Allow ~30 minutes for FwdSync propagation to Exchange Online before assuming a segment reassignment failed — reapplying immediately after an attribute edit is a common source of wasted troubleshooting cycles. See: [Manage Information Barriers policies](https://learn.microsoft.com/en-us/purview/information-barriers-edit-segments-policies)
