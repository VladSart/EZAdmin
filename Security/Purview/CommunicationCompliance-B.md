# Microsoft Purview Communication Compliance — Hotfix Runbook (Mode B: Ops)
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

**There is no PowerShell for creating, editing, or querying Communication Compliance policies.** Every check below either uses an adjacent cmdlet (licensing, audit log, role groups, EXO mailbox) or points you to the Microsoft Purview portal directly.

```powershell
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.com>
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# 1. Is the Unified Audit Log on? CC alerts and reports are built entirely on top of it.
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled

# 2. Is there at least one live admin in the CC role groups? (zero-admin lockout check)
Get-RoleGroupMember -Identity "Communication Compliance Admins"
Get-RoleGroupMember -Identity "Communication Compliance"

# 3. Does the affected reviewer/analyst have an Exchange Online-hosted mailbox?
#    (a reviewer with no EXO mailbox cannot be added to a policy at all)
Get-EXOMailbox -Identity <reviewer@tenant.com> -ErrorAction SilentlyContinue

# 4. Is the affected scoped user actually licensed for Communication Compliance?
Get-MgUserLicenseDetail -UserId <user@tenant.com> |
    Select-Object -ExpandProperty ServicePlans |
    Where-Object { $_.ServicePlanName -match "COMMUNICATION_COMPLIANCE|INFORMATION_PROTECTION_COMPLIANCE" }
```

**Interpretation:**

| Result | Action |
|--------|--------|
| `UnifiedAuditLogIngestionEnabled = False` | Fix 1 — enable audit log (nothing works without it) |
| CC Admins / CC role group has zero members | Fix 2 — zero-admin lockout, restore access via Entra Global Admin |
| Reviewer/analyst has no EXO mailbox | Fix 3 — reviewer requirement not met, can't be added to any policy |
| User has no qualifying licence/service plan | Fix 4 — assign licence |
| Everything above checks out, but a specific policy "isn't matching" | Fix 5 — go to Diagnosis flow, this is a portal-side configuration issue |
| New policy shows nothing after &lt;24h (email) / &lt;48h (Teams/Viva Engage) | Not a bug — still inside normal processing latency, re-check after the window |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant subscription: Purview Suite (E5 Compliance) / O365 E3 + Advanced Compliance / O365 E5
        │
Audit log ENABLED (UnifiedAuditLogIngestionEnabled = True)   ← single data pipe, nothing flows without it
        │
Role groups populated
  ├── Communication Compliance Admins / Communication Compliance  → can configure policies (≥1 required, or lockout)
  ├── Communication Compliance Analysts                            → can review (sees anonymized names if enabled)
  └── Communication Compliance Investigators                       → can review + escalate (always sees real names)
        │
Communication Compliance policy CREATED (portal only — no PowerShell)
  ├── Scoped users/groups (DGs, M365 Groups — NOT dynamic/nested groups)
  ├── Reviewers (individual users only, EXO-hosted mailbox, in Analysts/Investigators group)
  ├── Locations (Exchange / Teams / Viva Engage / Copilot / third-party — at least one)
  ├── Conditions (classifiers, SITs, keyword dictionaries) + review percentage
  └── Policy status = Active (not Draft)
        │
Channel-specific prerequisites
  ├── Teams        → nothing extra; AllowSecurityEndUserReporting controls self-report, not policy matching
  ├── Viva Engage   → tenant must be in Native Mode
  ├── Exchange      → mailbox must be on Exchange Online (on-prem needs a DG workaround, see Learning Pointers)
  └── Copilot / AI  → non-M365 AI apps need pay-as-you-go billing enabled tenant-wide
        │
Message sent by a scoped user in a checked location
        │
Processing latency: ~24h (email) or ~48h (Teams / Viva Engage / third-party)
        │
Alert generated → reviewer/analyst/investigator triages in Microsoft Purview portal
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the licence covers Communication Compliance**
```powershell
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All"
Get-MgUserLicenseDetail -UserId <user@tenant.com> | Select-Object SkuPartNumber
```
Expected: a SKU that includes Purview Suite / E5 Compliance / Advanced Compliance add-on. Bad: no matching SKU — user is silently excluded from every policy regardless of scope settings.

**Step 2 — Confirm audit log ingestion**
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
Expected: `True`. Bad: `False` — Fix 1.

**Step 3 — Confirm role group membership and the zero-admin scenario**
```powershell
Get-RoleGroupMember -Identity "Communication Compliance Admins"
Get-RoleGroupMember -Identity "Communication Compliance"
```
Expected: at least one active user in one of these two groups. Bad: both empty — nobody in the tenant can open the Communication Compliance solution at all (not even Global Admin, by default) — Fix 2.

**Step 4 — Confirm the reviewer/analyst prerequisites for the specific policy**
Open the policy in the Purview portal → check the **Reviewers** field.
Good: every reviewer is an individual user (not a group), has an Exchange Online mailbox, and is a member of *Communication Compliance Analysts* or *Investigators*.
Bad: a reviewer was added as a group (unsupported — silently ignored) or lacks an EXO mailbox (can't be added, or was removed after mailbox migration off EXO).

**Step 5 — Confirm scope**
Open the policy → **Users and groups**.
Good: affected user is in "All users", an explicitly listed user/group, or an adaptive scope that currently matches them.
Bad: user was added via a **dynamic** distribution group, **nested** distribution group, or M365 group with **dynamic membership** — none of these are supported for scoping and the user is silently never evaluated.

**Step 6 — Confirm processing latency hasn't been mistaken for a failure**
Good: message sent more than 24h ago (email) or 48h ago (Teams/Viva Engage/third-party) and still no alert.
Bad: message sent minutes/hours ago — this is still inside normal ingestion latency, not a bug.

**Step 7 — Confirm the channel itself is eligible**
- Teams: chats/channels only — the policy must have Teams selected as a location, and (for on-prem/external mailbox users) a distribution group must exist to bridge Teams-chat detection for those users.
- Viva Engage: tenant must be in **Native Mode** — if not, Viva Engage messages are invisible to every CC policy regardless of configuration.
- Generative AI (non-Microsoft): requires pay-as-you-go billing to be enabled tenant-wide; Microsoft 365 Copilot itself has no such requirement.

---

## Common Fix Paths

<details><summary>Fix 1 — Enable the Unified Audit Log</summary>

**Nothing in Communication Compliance works without this — no alerts, no reports, no message capture.**

```powershell
Connect-ExchangeOnline -UserPrincipalName <admin@tenant.com>
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
Preparation can take a couple of hours after enabling before the first search returns results.

**Rollback:** `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $false` — confirm with the compliance stakeholder first; this also blinds every other Purview solution (DLP, IRM, eDiscovery), not just CC.

</details>

<details><summary>Fix 2 — Recover from a zero-admin lockout</summary>

**By default, Global Administrators do NOT have access to Communication Compliance features.** If both the *Communication Compliance* and *Communication Compliance Admins* role groups are empty, nobody can open the solution to fix this from inside it.

1. Sign in with an Entra ID **Global Administrator** or **Compliance Administrator** role (these have the same effective access as *Communication Compliance Admins* even without explicit role-group membership).
2. Go to **Microsoft Purview portal** → **Settings** → **Roles and groups** → **Role groups**.
3. Add at least one real user to *Communication Compliance Admins* (or *Communication Compliance*, which is a superset).
4. Wait up to **30 minutes** for the role assignment to propagate before assuming it hasn't worked.

**Rollback:** none needed — this is a restorative action. Going forward, always keep at least two people in these role groups to avoid a repeat.

</details>

<details><summary>Fix 3 — Reviewer doesn't meet requirements</summary>

**Reviewers must be individual users (never a group), hosted on Exchange Online, and members of Communication Compliance Analysts or Investigators.**

1. Confirm the mailbox is actually on Exchange Online:
   ```powershell
   Get-EXOMailbox -Identity <reviewer@tenant.com> | Select-Object DisplayName, RecipientTypeDetails
   ```
   If this returns nothing, the mailbox is on-prem, shared/resource (unsupported for review purposes), or doesn't exist.
2. Add the reviewer to the correct role group:
   ```powershell
   Add-RoleGroupMember -Identity "Communication Compliance Analysts" -Member <reviewer@tenant.com>
   ```
3. Re-open the policy in the Purview portal → **Reviewers** → add the individual user (not a group — groups are silently unsupported here even though the portal may let you attempt it for scoped/excluded users).

**Rollback:** `Remove-RoleGroupMember -Identity "Communication Compliance Analysts" -Member <reviewer@tenant.com>` if the assignment was made in error.

</details>

<details><summary>Fix 4 — User not licensed</summary>

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","Organization.Read.All"
$sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "SPE_E5|INFORMATION_PROTECTION_COMPLIANCE" }
$userId = (Get-MgUser -Filter "userPrincipalName eq '<user@tenant.com>'").Id
Set-MgUserLicense -UserId $userId -AddLicenses @(@{SkuId = $sku.SkuId}) -RemoveLicenses @()
```

**Rollback:** `Set-MgUserLicense -UserId $userId -AddLicenses @() -RemoveLicenses @($sku.SkuId)` — removing the licence stops future evaluation but does not delete existing alerts/cases for that user.

</details>

<details><summary>Fix 5 — Policy configured but matching nothing (portal-side)</summary>

No PowerShell path exists for this — work through the portal:

1. **Test the conditions first** (Communication Compliance / Communication Compliance Admins members only): open the policy → **Test your conditions** → paste sample text or upload a `.txt` file → confirm the classifier/SIT actually fires before assuming the live policy is broken.
2. Check **Locations** — a policy scoped to "Exchange" only will never see Teams messages, and vice versa.
3. Check **Review percentage** — the *Regulatory compliance* and *Sensitive information* templates default to **10%**, not 100%. A 10%-reviewed policy will legitimately miss 9 out of 10 matching messages; this is by design, not a bug. Raise it to 100% if the client needs full coverage.
4. Check whether the affected user was added via a distribution group and the group's `MemberJoinRestriction`/membership actually includes them — group membership changes can lag behind what an admin expects if the group is managed outside the CC workflow.
5. Confirm **Filter out messages from email blasting services** isn't unintentionally excluding legitimate bulk-style internal senders (default: on).

**Rollback:** N/A — diagnostic only.

</details>

---

## Escalation Evidence

```
=== COMMUNICATION COMPLIANCE — ESCALATION PACK ===
Date/Time:                 ___________________________
Tenant ID:                 ___________________________
Affected Policy Name:      ___________________________
Affected User/Reviewer:    ___________________________
Alert ID (if any):         ___________________________
Raised by:                 ___________________________

--- DIAGNOSTIC CHECKLIST ---
[ ] Unified Audit Log enabled:                Yes / No
[ ] User licensed for Communication Compliance: Yes / No
[ ] Communication Compliance Admins has ≥1 member: Yes / No
[ ] Reviewer is individual user w/ EXO mailbox: Yes / No
[ ] Reviewer in Analysts/Investigators group:  Yes / No
[ ] User in supported scope type (not dynamic/nested group): Yes / No
[ ] Policy Review Percentage:                 ____%
[ ] Outside normal processing latency (24h email / 48h Teams): Yes / No

--- ISSUE DESCRIPTION ---
Expected behaviour:   ___________________________
Actual behaviour:     ___________________________
First occurrence:     ___________________________
Steps already tried:  ___________________________

--- SCREENSHOTS / EXPORTS ---
[ ] Purview portal screenshot of policy configuration (Locations, Conditions, Review %)
[ ] Test conditions result screenshot
[ ] Role group membership list (Get-RoleGroupMember output)
[ ] User licence assignment (Get-MgUserLicenseDetail output)

--- MICROSOFT SUPPORT LINKS ---
Open ticket at: https://admin.microsoft.com → Support → New service request
Category: Compliance → Communication Compliance
Tenant ID required: (Get-MgOrganization).Id
```

---

## 🎓 Learning Pointers

- **There is no PowerShell module for Communication Compliance policy management, full stop.** Every other Purview solution in this repo (DLP, Insider Risk, retention) has at least partial cmdlet coverage; Communication Compliance policies must be created and edited exclusively through the Microsoft Purview portal. Plan your MSP tooling and change-tracking around portal screenshots and exported audit logs, not scripts. [MS Docs: Manage Communication Compliance policies](https://learn.microsoft.com/en-us/purview/communication-compliance-policies)
- **Global Administrators are locked out of Communication Compliance by default** — this is the opposite of how most M365 admin surfaces behave, and it means a fresh GA account genuinely cannot see the menu option until explicitly added to a role group (or the equivalent Entra/Purview admin roles). This is the #1 cause of "I'm a Global Admin and I don't even see Communication Compliance" tickets.
- **Regulatory compliance and Sensitive information templates review only 10% of matching traffic by default**, unlike every other template's 100%. A client expecting full coverage from an out-of-the-box template will be under-reviewing 9 out of 10 real matches until this is explicitly raised.
- **Reviewers can never be groups — only individual users**, and they must have an Exchange Online mailbox. This is different from scoped/excluded users, which do support Distribution Groups and Microsoft 365 Groups. Mixing these two rules up is a common configuration mistake.
- **Under the hood, Communication Compliance is still "Supervisory Review"** — the legacy feature name survives in the compliance-boundary mailbox pattern (`Mailbox_Name -like 'SupervisoryReview{*'`) used by `New-ComplianceSecurityFilter`. If a client's environment has compliance boundaries configured for eDiscovery, CC admins/reviewers can be silently blocked from the mailboxes they need — see `CommunicationCompliance-A.md` Remediation Playbook 3.
- **Processing latency is real and asymmetric: ~24h for email, ~48h for Teams/Viva Engage/third-party.** Declaring a brand-new policy "broken" inside that window is the single most common false-positive escalation for this feature.
