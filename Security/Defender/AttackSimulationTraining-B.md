# Attack Simulation Training — Hotfix Runbook (Mode B: Ops)
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

> There are no Exchange Online PowerShell cmdlets for Attack Simulation Training — it's Microsoft Graph API only (`AttackSimulation.Read.All` / `AttackSimulation.ReadWrite.All`). Run these from an elevated PowerShell session with the Microsoft Graph PowerShell SDK installed.

```powershell
# 1 — Connect and pull the 5 most recent simulations
Connect-MgGraph -Scopes "AttackSimulation.Read.All","User.Read.All" -NoWelcome
$sims = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/security/attackSimulation/simulations?`$top=5&`$orderby=createdDateTime desc"
$sims.value | Select-Object displayName, status, attackTechnique, launchDateTime, completionDateTime

# 2 — Is unified audit logging on? (required — its absence silently blocks ALL reporting + training assignment)
# Requires Exchange Online PowerShell (Connect-ExchangeOnline)
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled

# 3 — Does the affected/reporting user have an E5 / Defender for Office 365 Plan 2 license?
Get-MgUserLicenseDetail -UserId "<UPN>" | Select-Object SkuPartNumber

# 4 — What Entra role does the admin actually hold? (Attack Payload Author and Security Operator/Reader
#     are read-only or payload-only — a common "why can't I create a simulation" cause)
Get-MgUserMemberOf -UserId "<AdminUPN>" | Select-Object -ExpandProperty AdditionalProperties |
    Select-Object displayName

# 5 — Validate a target group's membership (guests and inactive Entra users are silently
#     dropped during target resolution — the #1 cause of "not everyone got the simulation")
# Requires Exchange Online PowerShell
Get-DistributionGroupMember -Identity "<TargetGroupName>" | Select-Object Name, RecipientType, PrimarySmtpAddress
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `UnifiedAuditLogIngestionEnabled = False` | Reports empty tenant-wide, training assignment blocked | Fix 1 |
| User has no E5/MDO P2 SKU in license list | Empty activity details for that user only | Fix 1 |
| Target group contains guests / `RecipientType` shows disabled mailboxes | Users silently excluded from simulation delivery | Fix 2 |
| Simulation `status` stuck at `scheduled` well past `launchDateTime` | Target resolution still in progress, or all recipients invalid | Fix 3 |
| Admin role is `Attack Payload Author` or `Security Reader` | Role can't create/edit simulations — needs `Attack Simulation Administrator` or `Security Administrator` | Fix 6 |
| Everything above looks healthy but users report false clicks/training | Interaction-layer issue (interception or reporting-mailbox scanning) | Fix 4 / Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true for a simulation to deliver, get accurately reported, and assign training</summary>

```
[License: Microsoft 365 E5 or Defender for Office 365 Plan 2 add-on]
    └── [Entra role: Global Admin / Security Admin / Attack Simulation Administrator]
            (Attack Payload Author and Security Operator/Reader are intentionally limited — see Fix 6)
            └── [Unified audit logging enabled tenant-wide]
                    (if OFF: all reporting is empty AND training assignment is blocked — not just degraded)
                    └── [Target resolution: Entra group / CSV / individual users]
                            (guests, invalid addresses, and inactive Entra users are silently dropped here)
                            └── [Delivery via transport pipeline]
                                    (on-prem mailboxes: delivery works, but read/report/forward/delete
                                     telemetry is NOT captured — reduced reporting only)
                                    └── [User interaction capture: click / report / compromise / training]
                                            (Safe Links tracks clicks even if "Track user clicks" is off in
                                             Safe Links policy, specifically for simulation URLs)
                                            └── [Reporting-mailbox path, if user reports the message]
                                                    (custom reporting mailbox MUST be exempted from Safe
                                                     Links/Safe Attachments detonation, or the detonation
                                                     itself triggers an incorrect training assignment)
                                                    └── [Training assignment: "Assign for me" heuristic
                                                         OR admin-selected modules — gated by the 90-day
                                                         training threshold]
                                                            └── [Reporting & Insights]
                                                                    (delayed by simulation lifecycle state —
                                                                     see Diagnosis Step 4)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm licensing and role**
```powershell
Get-MgUserLicenseDetail -UserId "<UPN>" | Select-Object SkuPartNumber
Get-MgUserMemberOf -UserId "<AdminUPN>" | Select-Object -ExpandProperty AdditionalProperties | Select-Object displayName
```
Expected: at least one `ENTERPRISEPREMIUM` (E5), `SPE_E5`, or a Defender for Office 365 Plan 2 SKU on active users you expect to see in reports. Admin needs Global Administrator, Security Administrator, or Attack Simulation Administrator to create/edit campaigns.

**Step 2 — Confirm unified audit logging**
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
Good: `True`. Bad: `False` — every report is empty and training assignments silently stop, not just reporting.

**Step 3 — Validate simulation target list**
```powershell
Get-DistributionGroupMember -Identity "<TargetGroupName>" | Select-Object Name, RecipientType, PrimarySmtpAddress
```
Look for guest accounts (`RecipientType` mail-user/guest) or disabled/removed users — these are excluded during target validation with no error surfaced to the admin. Cross-check against the simulation's **Users** tab filtered by **Simulation message delivery: Failed to deliver**.

**Step 4 — Understand reporting lag before assuming a real problem**
Simulation lifecycle: `scheduled` → `inProgress` → `completed`. Reports are near-empty during `scheduled` (target resolution/group expansion in progress). After transition to `inProgress`, allow up to 30 minutes for the first data, then updates arrive every 10 min (first hour), 15 min (up to 2 days), 30 min (up to 7 days), 60 min after.
```powershell
$sims.value | Select-Object displayName, status, launchDateTime, completionDateTime
```

**Step 5 — Check for a false-positive click/compromise**
If a user insists they didn't click, or clicks appear seconds after delivery for many users, pull `EmailLinkClicked_IP` / `EmailLinkClicked_TimeStamp` from the simulation's detailed user report (export from the Users tab). An IP that isn't Microsoft's, the company's, or the user's — especially with a near-zero delay — indicates a non-Microsoft security tool (EDR, email gateway, Outlook add-in, SOAR auto-triage) pre-fetched or scanned the link.

**Step 6 — Confirm reported-phish submissions aren't being blocked**
```powershell
# Requires Exchange Online PowerShell
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
    Select-Object Name, SentTo, BlockedSenders, RejectMessageReasonText
```
Manually review any enabled rule broad enough to affect mail to `junk@office365.microsoft.com`, `abuse@messaging.microsoft.com`, `phish@office365.microsoft.com`, or `not_junk@office365.microsoft.com` — these are the addresses user-reported messages route through.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Reports/training show no data at all, or only for some users</summary>

Tenant-wide empty reports:
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
# If False:
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
```
Per-user empty activity details:
```powershell
Get-MgUserLicenseDetail -UserId "<UPN>" | Select-Object SkuPartNumber
```
Assign an E5 / Defender for Office 365 Plan 2 license to the affected active user. Both conditions must be true — audit logging on AND an E5-class license — or the reporting pipeline has no data to populate.

**Rollback:** turning audit logging back off will re-blank all Attack Simulation Training reporting and block future training assignment — only do this if you have an explicit, documented reason (e.g., compliance requirement), not as a troubleshooting step.
</details>

<details>
<summary>Fix 2 — Not everyone in the target group received the simulation</summary>

Confirm exclusions:
```powershell
Get-DistributionGroupMember -Identity "<TargetGroupName>" | Select-Object Name, RecipientType, PrimarySmtpAddress
```
Guests, invalid recipient addresses, and users no longer active in Entra ID are dropped silently during target validation — this is by design, not a bug. Clean the source group (remove guests/stale accounts) or switch to a dynamic Microsoft 365 Group scoped to `userType eq 'Member'` and `accountEnabled eq true` so future campaigns self-correct.

**Rollback:** none needed — this is a group-hygiene fix, not a config change to the simulation itself.
</details>

<details>
<summary>Fix 3 — Simulation stuck in "Scheduled" or shows near-zero delivery</summary>

```powershell
$sims.value | Where-Object { $_.status -eq "scheduled" } | Select-Object displayName, launchDateTime
```
If `launchDateTime` is well in the past and status hasn't moved to `inProgress`, target group expansion may still be resolving a very large group, or every resolved recipient failed validation (all guests / all invalid). Check the **Users** tab filtered by **Failed to deliver**. If the sender domain is owned by you, undelivered-simulation NDRs land in your own mailbox with a standard SMTP bounce code — treat like any other NDR triage.

**Rollback:** cancelling a stuck simulation does not undo compromises already recorded for users who entered credentials before cancellation — they still count as compromised/repeat-offenders.
</details>

<details>
<summary>Fix 4 — Users are assigned training even though they correctly reported the simulated phish</summary>

This happens when a custom reporting mailbox isn't exempted from Safe Links/Safe Attachments detonation — the detonation itself is treated as a "clicked/compromised" interaction.
1. Confirm the reporting mailbox in use: **security.microsoft.com/securitysettings/userSubmission**
2. Configure it as a SecOps mailbox in the [Advanced Delivery policy](https://learn.microsoft.com/en-us/defender-office-365/advanced-delivery-policy-configure#use-the-microsoft-defender-portal-to-configure-secops-mailboxes-in-the-advanced-delivery-policy) so messages route to it unfiltered.
3. Re-verify the reporting mailbox meets the [documented prerequisites](https://learn.microsoft.com/en-us/defender-office-365/submissions-user-reported-messages-custom-mailbox#configuration-requirements-for-the-reporting-mailbox) (skips Safe Links rewriting and Safe Attachments detonation for that mailbox).

**Rollback:** none — this only removes an incorrect scanning path, it doesn't change any user-facing behavior.
</details>

<details>
<summary>Fix 5 — False-positive clicks/compromises reported instantly, or users insist they never clicked</summary>

Pull `EmailLinkClicked_IP` and `EmailLinkClicked_TimeStamp` from the simulation's exported user report. If the IP doesn't belong to Microsoft, your org, or the user, and the click landed within seconds of delivery, a non-Microsoft tool intercepted the link — commonly an Outlook add-in, third-party email security gateway, endpoint AV/EDR pre-fetch, or a SOAR playbook that auto-opens reported/suspicious links.

Add exclusions in that tool for:
- All Attack Simulation Training payload domains (see `AttackSimulationTraining-A.md` Dependency Stack for the current list — it's long and Microsoft-maintained, don't hand-copy it into every tool by memory).
- `https://security.microsoft.com/attacksimulator`, `/attacksimulationreport`, `/trainingassignments`
- `http://asttrainingfdendpoint-a6fva0cjbsbbereq.b02.azurefd.net/`

**Rollback:** none — exclusions only stop a security tool from mis-scanning harmless simulation traffic.
</details>

<details>
<summary>Fix 6 — Admin can't create or edit a simulation despite "having a role"</summary>

```powershell
Get-MgUserMemberOf -UserId "<AdminUPN>" | Select-Object -ExpandProperty AdditionalProperties | Select-Object displayName
```
`Attack Payload Author` can create payloads only — not simulations, training campaigns, or automations, and can't view tenant-wide reports. `Security Operator` / `Security Reader` are read-only. Neither can be fixed by re-checking Defender XDR Unified RBAC — **Attack Simulation Training does not support Unified RBAC**, only classic Entra role assignment.

Assign `Attack Simulation Administrator` (preferred, least-privilege) or `Security Administrator` via **Entra admin center → Roles & administrators**, not via Defender portal role groups.

**Rollback:** remove the role assignment via the same blade if access should be temporary.
</details>

---

## Escalation Evidence

```
=== ATTACK SIMULATION TRAINING ESCALATION ===
Date/Time         :
Engineer          :
Ticket            :
Tenant ID         :

Simulation Name/ID:
Simulation Status : (scheduled / inProgress / completed / other)
Launch Date       :
Affected User(s)  : (UPN)

License Check     : (Get-MgUserLicenseDetail output — SkuPartNumber)
Audit Logging     : (Get-AdminAuditLogConfig -> UnifiedAuditLogIngestionEnabled)
Admin Role Held   : (Get-MgUserMemberOf output for the admin trying to act)

Target Group Used :
Group Hygiene Check: (guests/invalid/inactive found? Y/N — paste Get-DistributionGroupMember output)

Reporting Mailbox : (address, SecOps-exempted? Y/N)
Transport Rule Scan: (any rule matching junk@/abuse@/phish@/not_junk@ addresses?)

False-Click Evidence: (EmailLinkClicked_IP / Timestamp if applicable)

Steps Attempted:
1.
2.
3.

Expected behaviour :
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **There is no PowerShell module for Attack Simulation Training itself** — everything scriptable goes through Microsoft Graph (`AttackSimulation.Read.All` / `AttackSimulation.ReadWrite.All`). Don't waste time searching for an Exchange Online cmdlet that doesn't exist. [MS Docs: Get started](https://learn.microsoft.com/en-us/defender-office-365/attack-simulation-training-get-started)
- **Audit logging isn't optional here** — unlike most Microsoft 365 workloads where it's "nice to have for compliance," Attack Simulation Training uses it as its actual reporting data source. Off means both empty reports and no training assignments, tenant-wide. [MS Docs: FAQ — reporting issues](https://learn.microsoft.com/en-us/defender-office-365/attack-simulation-training-faq)
- **Guests and inactive users are excluded silently, not with an error** — always validate target group membership before escalating a "some users didn't get it" ticket.
- **Attack Payload Author and Security Operator/Reader are deliberately limited roles**, not a licensing bug — check the exact role before assuming a broken permission.
- **A custom reporting mailbox is a common source of false training assignments** — if the org uses one, it must be exempted from Safe Links/Safe Attachments detonation via the Advanced Delivery policy.
- **Reporting lag is normal, not a fault** — up to 30 minutes after a simulation moves to `In progress`, with staggered update intervals after that. Don't escalate a "no data yet" ticket inside that window.
