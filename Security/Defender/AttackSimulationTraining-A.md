# Attack Simulation Training — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Attack Simulation Training in Microsoft Defender for Office 365 Plan 2 (standalone or via Microsoft 365 E5)
- Simulations, simulation automations, training campaigns, payloads, landing/login pages, end-user notifications
- Delivery, target resolution, interaction capture (click/report/compromise), and training assignment logic
- Reporting/insights pipeline and its dependency on unified audit logging
- Microsoft Graph API access (the only programmatic surface — there is no dedicated PowerShell module)

**Does not cover:**
- Building or wordsmithing individual phishing payload content (see Microsoft's payload authoring docs)
- Microsoft Defender for Office 365 anti-phishing/Safe Links/Safe Attachments *policy* configuration for real mail flow — this runbook only covers where those policies intersect with simulation traffic (see `Security/Defender/ASR-Rules-A.md` and mail-flow runbooks under `M365/Exchange/` for the policies themselves)
- Communication Compliance or Insider Risk simulation-adjacent features (different Purview workload — see `Security/Purview/Insider-Risk-A.md`)

**Assumptions:**
- Tenant has at least one Microsoft 365 E5 or Defender for Office 365 Plan 2 (standalone add-on) license
- Admin has one of: Global Administrator, Security Administrator, or Attack Simulation Administrator (classic Entra role, not Defender XDR Unified RBAC — unsupported for this workload)
- Unified audit logging is the intended state (default: on)

---
## How It Works

<details><summary>Full architecture — simulation lifecycle end-to-end</summary>

**Attack Simulation Training is a hosted campaign engine, not a mail-flow policy.** It generates real (but harmless) phishing-style messages, delivers them through the normal Exchange Online transport pipeline, tracks every user interaction against a per-user, per-URL binding, and layers targeted training on top based on outcome. Content is delivered in partnership with Terranova Security.

**The five building blocks of a simulation:**
1. **Payload** — the phishing message content and the social engineering technique it uses. Techniques (curated from the MITRE ATT&CK framework, except How-to Guide):
   - **Credential Harvest** — link to a fake credentials page. Most common technique.
   - **Malware Attachment** — attachment that "runs" arbitrary code on open (simulated, harmless).
   - **Link in Attachment** — hybrid: link *inside* an attachment leads to a credential harvest page.
   - **Link to Malware** — link to a file on a well-known sharing platform (e.g., SharePoint) that "executes" on open.
   - **Drive-by-url** — link to a page that simulates background code execution (a "watering hole" pattern).
   - **OAuth Consent Grant** — simulates a malicious Azure AD app requesting data access via a consent prompt.
   - **How-to Guide** — not a test at all; a lightweight in-inbox teaching artifact (e.g., "how to report phishing").
2. **Login page** — used only by Credential Harvest / Link in Attachment payloads; the page that "captures" credentials. Nothing entered here is ever stored — only the fact that a submission occurred (the "compromise" event) is recorded.
3. **Landing page** — where users land after interacting with the payload, regardless of technique; used to deliver in-the-moment teaching.
4. **End-user notifications** — reminders (assignment, due-date, overdue) sent independently of the simulation payload itself.
5. **Target list** — Entra groups (Microsoft 365 static/dynamic, distribution static-only, mail-enabled security static-only), a CSV (max 40,000 recipients per import), "all users" (tenants under 40,000 users only), or individually selected users. Recipient upper bound is 400,000, but Microsoft recommends capping any single simulation at 200,000 for performance. **Shared mailboxes cannot be targeted.**

**Simulation vs. simulation automation vs. training campaign:**
- A **simulation** is a single social-engineering-technique campaign with one payload.
- A **simulation automation** chains multiple techniques/payloads and supports recurring/randomized scheduling — a simulation does not.
- A **training campaign** skips the phishing test entirely and directly assigns training modules — useful for recurring "monthly security awareness" pushes that aren't trying to catch anyone.

**Target resolution (the step most tickets misunderstand):** groups are expanded and the final recipient list is generated **at save time**, not at launch time. During expansion, the service silently drops: invalid/malformed email addresses, guest accounts, and users no longer active in Entra ID. None of this produces an admin-facing error — it's treated as expected filtering, which is why "not everyone got it" tickets are almost always a target-list hygiene problem, not a delivery bug.

**Delivery and region-aware timing:** messages route through the normal Exchange Online transport pipeline (on-premises mailboxes are supported, with reduced reporting — see below). Region-aware delivery uses each recipient mailbox's time zone attribute to send at a locally-equivalent time, which can stagger the apparent send date by up to a day for users in different time zones from the campaign creator — this is by design, not a partial-failure.

**Interaction capture:** every link in a simulation payload is bound to the individual recipient, so Safe Links click-tracking works for simulation URLs even in tenants where the "Track user clicks" Safe Links setting is otherwise off — Attack Simulation Training forces this for its own URLs specifically. Because simulation URLs are **not wrapped** by Safe Links (they're the raw simulation domain), not every click on them is guaranteed to traverse the Safe Links click-logging path the same way a normal wrapped URL would — this is why `UrlClickEvents` (Advanced Hunting) can under-represent simulation activity; the authoritative source is always the built-in simulation report, never a derived hunting table.

**Training assignment logic:** two modes exist per simulation/automation/training campaign — **"Assign training for me (Recommended)"**, a heuristic that assigns modules based on the user's simulation/training history, or **"Select training courses and modules myself"**, fully admin-controlled. A **training threshold** (default 90 days) prevents the same training from being reassigned to a user inside that window, regardless of which mode is used — this is the most common cause of "why didn't this user get retrained" tickets after a repeat click.

**Reporting mailbox interplay:** if the org routes user-reported phishing through a custom reporting mailbox (Outlook button → custom mailbox, not the built-in Microsoft Report button), that mailbox must be configured as a SecOps mailbox in the Advanced Delivery policy. If it isn't, Safe Links/Safe Attachments can detonate the forwarded simulation message as part of normal scanning, and that detonation itself gets recorded as a user interaction — incorrectly assigning training to a user who did exactly the right thing.

**Reporting pipeline dependency on audit logging:** Attack Simulation Training reads its own reporting data from the unified audit log pipeline. This is architecturally different from most Microsoft 365 features where audit logging is a parallel compliance stream — here, turning audit logging off doesn't just blind your *compliance* reports, it blinds the *product's own* reporting and additionally **blocks training assignment outright**, because the assignment engine can't read the interaction data it needs to decide what to assign.

**Reporting freshness:** simulations move through a `scheduled` → `inProgress` → `completed` lifecycle. `scheduled` reports are mostly empty (target resolution/expansion is happening). After the transition to `inProgress`, allow up to 30 minutes before data starts appearing, then updates land every 10 minutes for the first hour, every 15 minutes until 2 days, every 30 minutes until 7 days, and every 60 minutes after that.

**Repeat offender computation:** a user is a "repeat offender" after being compromised (credentials submitted) in a configurable number of consecutive simulations (default 2). Cancelling an in-progress simulation does **not** retroactively un-count users who had already been compromised before the cancellation.

**Data retention:** simulation metadata, automations, payload automations, and user activity retain for 18 months unless an admin deletes them first; tenant payloads/notifications/login/landing pages follow the same 18-month window unless archived+deleted; global (Microsoft-provided) content persists until Microsoft removes it; MDO-recommended payloads retain for 6 months. If the entire tenant is deleted, simulation data is purged after 90 days.

</details>

---
## Dependency Stack

```
Microsoft 365 E5 / Defender for Office 365 Plan 2 license (or E3 trial subset — Credential
Harvest + ISA/Mass Market Phishing training only, no other capabilities)
  └── Entra role assignment (classic role, NOT Defender XDR Unified RBAC — unsupported here)
        │     Global Administrator / Security Administrator / Attack Simulation Administrator
        │     → full create/manage. Attack Payload Author → payloads only, no sims/reports.
        │     → Security Operator + Security Reader → read-only view, no write APIs.
        └── Unified audit logging enabled tenant-wide
              (off = empty reports AND blocked training assignment, not a partial degradation)
              └── Target list defined: Entra group / CSV (≤40,000) / individual / all-users (<40,000 tenant)
                    └── Target resolution + expansion at SAVE time
                          (guests, invalid addresses, inactive Entra users silently dropped here)
                          └── Region-aware delivery scheduling (± up to 1 day vs. creator's time zone)
                                └── Transport pipeline delivery (Exchange Online or on-prem via hybrid)
                                      │  on-prem mailboxes: delivery works, but no read/report/
                                      │  forward/delete telemetry — reduced reporting only
                                      └── Payload rendering + per-user URL/QR binding
                                            └── Interaction capture: click / open / credential
                                                submit / report / reply / forward / delete /
                                                out-of-office / attachment-opened
                                                  │  Safe Links click-tracking forced on for sim
                                                  │  URLs even if tenant-wide tracking is off
                                                  └── Reporting-mailbox path (if user reports)
                                                        must be SecOps-exempted in Advanced
                                                        Delivery policy, or detonation = false
                                                        training assignment
                                                        └── Training assignment engine
                                                              "Assign for me" heuristic OR
                                                              admin-selected modules, gated by
                                                              90-day training threshold
                                                              └── Reporting & Insights
                                                                    (lifecycle-lag as above;
                                                                     18-month retention)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| All reports/dashboards empty across every simulation | Unified audit logging disabled tenant-wide | `Get-AdminAuditLogConfig` |
| Empty activity details for specific users only | Those users lack an E5/MDO P2 license | `Get-MgUserLicenseDetail` |
| Not all target group members received the simulation | Guests/invalid/inactive Entra accounts dropped during target resolution (by design) | `Get-DistributionGroupMember`, Users tab filtered "Failed to deliver" |
| User insists they didn't click, or click logged seconds after delivery | Non-Microsoft security tool (EDR/AV/Outlook add-in/SOAR) pre-fetched or scanned the link | Compare `EmailLinkClicked_IP`/`Timestamp` against known-good IP ranges |
| Training assigned even though user correctly reported the message | Custom reporting mailbox not exempted from Safe Links/Safe Attachments detonation | Advanced Delivery policy SecOps mailbox config |
| Reported-phish submissions never show up in simulation reports | Transport rule blocking mail to junk@/abuse@/phish@/not_junk@ addresses | `Get-TransportRule` scan |
| Same user isn't retrained after a repeat click | 90-day training threshold suppressing reassignment | Training threshold setting in campaign settings |
| QR payload shows "ping successful" instead of the landing page | `<div id="QRcode">` tag missing/altered in the payload's Code view | Inspect payload HTML in the Code tab before use |
| Simulation shows 0% delivered a long time after launch | Still in `scheduled` status (target expansion in progress) or every recipient failed validation | `status`/`launchDateTime` via Graph, Users tab "Failed to deliver" |
| Users in a specific country report no simulation email at all | Country/region not in the supported APC/EUR/NAM list | Cross-check supported country list in Learning Pointers |
| Chrome shows "Deceptive site ahead" on the phishing link | Google Safe Browsing flagged the simulation domain (Edge unaffected) | Test URL in both browsers before launch; allowlist per Google's guidance if needed |
| Admin with "a role" can't create/edit a simulation | Assigned Attack Payload Author or Security Operator/Reader (both intentionally limited) or attempted via Unified RBAC (unsupported) | `Get-MgUserMemberOf` — confirm exact classic Entra role |
| Simulation content changes didn't apply to an already-running campaign | Simulation was `inProgress`/`completed` when edited — content is only re-evaluated for `scheduled` campaigns | Check simulation `status` before assuming a content bug |

---
## Validation Steps

**Step 1 — Confirm licensing on affected users**
```powershell
Get-MgUserLicenseDetail -UserId "<UPN>" | Select-Object SkuPartNumber
```
Expected: an E5-class SKU (`SPE_E5`, `ENTERPRISEPREMIUM`) or a standalone Defender for Office 365 Plan 2 SKU. Bad: no matching SKU → empty activity details for that user regardless of everything else being healthy.

**Step 2 — Confirm the admin's actual Entra role**
```powershell
Get-MgUserMemberOf -UserId "<AdminUPN>" | Select-Object -ExpandProperty AdditionalProperties | Select-Object displayName
```
Expected: `Global Administrator`, `Security Administrator`, or `Attack Simulation Administrator`. Bad: only `Attack Payload Author` or `Security Reader`/`Security Operator` — both are real roles with real, permanent limitations, not a misconfiguration.

**Step 3 — Confirm unified audit logging**
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
Expected: `True`. Bad: `False` — this single setting blanks all reporting AND blocks training assignment tenant-wide; it is the single highest-value check in this entire runbook.

**Step 4 — Pull recent simulations and their lifecycle state via Graph**
```powershell
Connect-MgGraph -Scopes "AttackSimulation.Read.All" -NoWelcome
$sims = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/security/attackSimulation/simulations?`$top=25&`$orderby=createdDateTime desc"
$sims.value | Select-Object displayName, status, attackType, attackTechnique, launchDateTime, completionDateTime, isAutomated
```
Expected: `status` progresses `scheduled` → `inProgress` → `completed` on the timeline you expect. Bad: a campaign stuck in `scheduled` long after its `launchDateTime`, or `completed` with `completionDateTime` far earlier than expected (possible mass validation failure).

**Step 5 — Validate target group hygiene**
```powershell
Get-DistributionGroupMember -Identity "<TargetGroupName>" | Select-Object Name, RecipientType, PrimarySmtpAddress
```
Expected: all members are licensed, active, non-guest mailboxes. Bad: guest accounts, disabled mailboxes, or malformed addresses present — these are silently excluded from delivery, and the group itself is the fix point, not the simulation.

**Step 6 — Check for mail-flow interference with reported-phish submissions**
```powershell
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
    Select-Object Name, SentTo, BlockedSenders, RejectMessageReasonText
```
Expected: no enabled rule matches `junk@office365.microsoft.com`, `abuse@messaging.microsoft.com`, `phish@office365.microsoft.com`, or `not_junk@office365.microsoft.com`. Bad: a broad reject/redirect/quarantine rule catching mail to those addresses — user-reported submissions never register.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Pre-launch (licensing, roles, audit logging, network allowlisting)
1. Confirm tenant licensing (`Get-MgUserLicenseDetail`) covers the users you expect to appear in reports — not just "the tenant has E5 somewhere."
2. Confirm the admin's classic Entra role — remember Unified RBAC does not apply here.
3. Confirm `UnifiedAuditLogIngestionEnabled = True` before troubleshooting anything else; this single flag explains the largest class of "nothing is working" tickets.
4. If proxies/firewalls/WAFs/non-Microsoft filter drivers are in play, confirm `security.microsoft.com/attacksimulator`, `/attacksimulationreport`, `/trainingassignments`, and `http://asttrainingfdendpoint-a6fva0cjbsbbereq.b02.azurefd.net/` bypass scanning, plus the simulation payload domains themselves.
5. If the org is in Chrome-heavy environment, test the intended phishing URL in Chrome ahead of a real campaign — Google Safe Browsing sometimes flags simulation domains with "Deceptive site ahead" (Edge is unaffected); allowlist per Google's guidance if hit.

### Phase 2 — Launch / target resolution / delivery
1. Confirm the target list resolved cleanly — pull group membership and look for guests/invalid/inactive accounts before escalating a partial-delivery ticket.
2. Remember target expansion happens at **save time**, not launch time — editing a group after saving the simulation does not change who gets targeted.
3. For on-premises mailboxes, set expectations correctly up front: delivery works, but read/report/forward/delete telemetry will never populate — this is a permanent limitation, not a bug to chase.
4. If using region-aware delivery, expect apparent "no send" for users in far time zones on day one — this resolves as more users enter their local delivery window.

### Phase 3 — Interaction / reporting accuracy
1. If clicks look suspicious (instant, or user denies clicking), pull `EmailLinkClicked_IP`/`EmailLinkClicked_TimeStamp` from the exported user report before assuming a real click occurred.
2. Cross-reference any flagged IP against Microsoft's ranges, the org's own egress IPs, and the user's known IP — a mismatch plus near-zero delay is the signature of an intercepting security tool, not a false report from the user.
3. For QR-code payloads showing "ping successful" instead of a landing page, inspect the payload's Code tab for an intact `<div id="QRcode"...>` marker before using it live.
4. Remember content changes (payload/module/login/landing page) only apply to simulations still in `scheduled` state — an `inProgress`/`completed` simulation already locked in its content at launch.

### Phase 4 — Training assignment
1. If training seems to be assigned incorrectly (or not at all) after a report action, check the reporting mailbox's Advanced Delivery / SecOps exemption status first — this is the single most common root cause.
2. If training isn't reassigned after a repeat click, check the training threshold (default 90 days) before assuming the assignment engine is broken.
3. If using "Assign training for me," remember it's a heuristic based on history — switch to "Select training courses and modules myself" if you need deterministic, auditable assignment for a compliance-driven campaign.

### Phase 5 — Post-simulation / data lifecycle
1. Confirm repeat-offender counts reflect intended business logic — a user compromised before an admin cancels the simulation is still counted, cancellation does not retroactively clear it.
2. For data retention questions in a compliance or investigation context, refer to the 18-month default window per artifact type (see How It Works) rather than assuming immediate purge on tenant offboarding.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Enable and verify unified audit logging tenant-wide</summary>

```powershell
# Requires Exchange Online PowerShell (Connect-ExchangeOnline)
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled

# If False:
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true

# Re-verify
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
Allow up to several hours for historical reporting gaps during the "off" window to remain permanently blank — this setting doesn't retroactively backfill missed data, it only restores the pipeline going forward.

**Rollback:** `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $false` — only do this for a documented compliance reason; understand it will re-blank Attack Simulation Training reporting and block future training assignment tenant-wide, not just this product's audit trail.
</details>

<details><summary>Playbook 2 — Configure the reporting mailbox as a SecOps mailbox (Advanced Delivery policy)</summary>

1. Confirm the reporting mailbox in use: **security.microsoft.com/securitysettings/userSubmission**
2. Go to **Microsoft Defender portal → Email & collaboration → Policies & rules → Threat policies → Advanced delivery → SecOps mailbox**
3. Add the reporting mailbox so messages route to it unfiltered by Safe Links/Safe Attachments.
4. Verify against the [documented reporting-mailbox prerequisites](https://learn.microsoft.com/en-us/defender-office-365/submissions-user-reported-messages-custom-mailbox#configuration-requirements-for-the-reporting-mailbox) — the mailbox needs specific configuration beyond just the SecOps flag (e.g., not being a shared mailbox with conflicting forwarding rules).
5. Re-run a test simulation with **Send a test** and confirm the reported-message path no longer generates a false training assignment.

**Rollback:** remove the mailbox from the SecOps list in Advanced Delivery — reverts to normal scanning for that mailbox.
</details>

<details><summary>Playbook 3 — Clean and re-scope a target group for hygiene</summary>

```powershell
# Requires Exchange Online PowerShell
$members = Get-DistributionGroupMember -Identity "<TargetGroupName>"
$members | Select-Object Name, RecipientType, PrimarySmtpAddress

# Identify likely-excluded members (guests, non-UserMailbox types)
$members | Where-Object { $_.RecipientType -ne "UserMailbox" }
```
For a self-correcting target list going forward, replace a static distribution/security group with a **dynamic Microsoft 365 Group** scoped to active, non-guest members only (e.g., `(user.userType -eq "Member") -and (user.accountEnabled -eq true)`), configured in the Entra admin center's dynamic membership rule builder.

**Rollback:** none required — target list changes only affect future simulations/automations, not completed campaigns.
</details>

<details><summary>Playbook 4 — Bulk allowlist for network/security tool false positives</summary>

Use when multiple users across the org are affected by false clicks/compromises or blocked simulation URLs.

1. Confirm the interference pattern first (Phase 3, Step 1-2 above) — don't allowlist speculatively.
2. Add the following to the relevant tool's URL/domain exclusion list (proxy, WAF, EDR, email security gateway, SOAR playbook):
   - `security.microsoft.com/attacksimulator`, `/attacksimulationreport`, `/trainingassignments`
   - `http://asttrainingfdendpoint-a6fva0cjbsbbereq.b02.azurefd.net/`
   - The specific simulation payload domain(s) in use for the current campaign — Microsoft publishes and periodically updates this list in the [Get started](https://learn.microsoft.com/en-us/defender-office-365/attack-simulation-training-get-started#simulations) documentation; treat it as a living list to re-check per campaign rather than hard-coding permanently into every tool.
3. For Google Chrome specifically, if Safe Browsing blocks a URL, follow [Google's allowlist guidance](https://support.google.com/chrome/a/answer/7532419) — this is a Google-side reputation flag, not something Microsoft or the tenant admin controls directly.
4. Re-run **Send a test** from the Payloads page to confirm the exclusion resolved the false positive before relaunching the real campaign.

**Rollback:** remove the exclusions if the security tool's normal scanning behavior needs to be restored (e.g., after a one-off campaign).
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Attack Simulation Training diagnostic evidence for escalation
.NOTES     Run with Microsoft Graph PowerShell SDK + Exchange Online PowerShell connected.
           Read-only — no simulation, policy, or mailbox changes are made.
#>

$reportPath = "C:\Temp\AttackSim-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# Recent simulations
try {
    $sims = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/security/attackSimulation/simulations?`$top=25&`$orderby=createdDateTime desc"
    $sims.value | ConvertTo-Json -Depth 5 | Out-File "$reportPath\01-RecentSimulations.json"
} catch {
    "Graph call failed: $($_.Exception.Message)" | Out-File "$reportPath\01-RecentSimulations.txt"
}

# Audit logging state
try {
    Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled |
        ConvertTo-Json | Out-File "$reportPath\02-AuditLogConfig.json"
} catch {
    "Get-AdminAuditLogConfig failed (Exchange Online PowerShell not connected?): $($_.Exception.Message)" |
        Out-File "$reportPath\02-AuditLogConfig.txt"
}

# Transport rule scan for reported-phish submission addresses
try {
    $watchAddresses = @("junk@office365.microsoft.com","abuse@messaging.microsoft.com","phish@office365.microsoft.com","not_junk@office365.microsoft.com")
    Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
        Select-Object Name, SentTo, BlockedSenders, RejectMessageReasonText |
        ConvertTo-Json | Out-File "$reportPath\03-TransportRules.json"
    $watchAddresses | Out-File "$reportPath\03-WatchAddresses-Reference.txt"
} catch {
    "Get-TransportRule failed (Exchange Online PowerShell not connected?): $($_.Exception.Message)" |
        Out-File "$reportPath\03-TransportRules.txt"
}

# Package everything
$zipPath = "C:\Temp\AttackSim-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').zip"
Compress-Archive -Path $reportPath -DestinationPath $zipPath -Force

Write-Host "Evidence collected: $zipPath" -ForegroundColor Green
Write-Host "Attach to escalation ticket. Manually export the simulation's Users tab (with EmailLinkClicked_IP/Timestamp columns) if a false-click investigation is in scope." -ForegroundColor Cyan
```

---
## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Connect with read scope | `Connect-MgGraph -Scopes "AttackSimulation.Read.All"` |
| List recent simulations | `Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/attackSimulation/simulations?$top=25&$orderby=createdDateTime desc"` |
| Filter simulations by status | `...simulations?$filter=status eq 'inProgress'` |
| Check audit logging | `Get-AdminAuditLogConfig \| Select UnifiedAuditLogIngestionEnabled` |
| Enable audit logging | `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true` |
| Check user license | `Get-MgUserLicenseDetail -UserId <UPN> \| Select SkuPartNumber` |
| Check admin's Entra role | `Get-MgUserMemberOf -UserId <AdminUPN>` |
| Validate group membership | `Get-DistributionGroupMember -Identity <GroupName>` |
| Scan transport rules | `Get-TransportRule \| Where State -eq Enabled` |
| Portal — simulations home | `https://security.microsoft.com/attacksimulator` |
| Portal — training assignments | `https://security.microsoft.com/trainingassignments` |
| Portal — user-reported settings | `https://security.microsoft.com/securitysettings/userSubmission` |
| Portal — Advanced Delivery (SecOps) | Defender portal → Email & collaboration → Policies & rules → Threat policies → Advanced delivery |
| Send a test simulation | Simulation wizard → Review Simulation → **Send a test** |
| Repeat-offender / training threshold settings | Defender portal → Attack simulation training → Settings |

---
## 🎓 Learning Pointers

- **There is no PowerShell module for this workload** — every programmatic touchpoint is Microsoft Graph (`AttackSimulation.Read.All` / `AttackSimulation.ReadWrite.All`, delegated or application). Don't burn time hunting for an Exchange Online cmdlet equivalent. [MS Docs: FAQ — API access](https://learn.microsoft.com/en-us/defender-office-365/attack-simulation-training-faq#q-can-i-create-view-and-manage-simulations-using-an-api)
- **Audit logging is a hard dependency, not a nice-to-have** — it's the actual data source for both reporting and the training-assignment engine in this specific product, unlike most other Microsoft 365 workloads where it's a parallel compliance stream. [MS Docs: Turn auditing on or off](https://learn.microsoft.com/en-us/purview/audit-log-enable-disable)
- **Target resolution happens at save time, and exclusions are silent** — guests, invalid addresses, and inactive Entra accounts are dropped with no admin-facing warning. Build group hygiene checks into your pre-launch checklist rather than debugging "missing" recipients after the fact.
- **Attack Payload Author and Security Operator/Reader are real, permanent role limitations** — not misconfigurations to fix. Match the role to the actual task (payload creation vs. full campaign management vs. read-only reporting).
- **Region availability is not universal** — Attack Simulation Training only operates in APC, EUR, and NAM regions, with a specific country list, and some recently-added countries (Norway, South Africa, UAE, Germany at time of writing) lack reported-email telemetry even though the rest of the product works. Check this before troubleshooting a "silent" tenant in an unsupported geography. [MS Docs: Get started — availability](https://learn.microsoft.com/en-us/defender-office-365/attack-simulation-training-get-started#what-do-you-need-to-know-before-you-begin)
- **Reporting freshness follows a documented lag schedule, not real-time** — up to 30 minutes after transition to `In progress`, then tiered update intervals. Escalating a "no data" ticket inside that window wastes an engineering cycle on expected behavior. [MS Docs: FAQ — reporting issues](https://learn.microsoft.com/en-us/defender-office-365/attack-simulation-training-faq#reporting-issues)
