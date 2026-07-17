# Defender for Office 365 — Safe Links & Safe Attachments — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** This is not spam/malware filtering (see `M365/Exchange/EOP-AntiSpam-B.md`) and not phishing *simulation* (see `AttackSimulationTraining-B.md`). This covers the two real-time protection features of Defender for Office 365: **Safe Links** (URL rewriting + time-of-click verification) and **Safe Attachments** (attachment detonation).

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these immediately to establish context (Exchange Online PowerShell):

```powershell
# 1. Confirm licensing (MDO Plan 1 or Plan 2 required — not just base EOP)
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "ATP_ENTERPRISE|THREAT_INTELLIGENCE|SAFEDOCS" } |
    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}

# 2. List all Safe Links policies + rules, in priority order
Connect-ExchangeOnline
Get-SafeLinksRule | Sort-Object Priority | Select-Object Name, State, Priority, SafeLinksPolicy
Get-SafeAttachmentRule | Sort-Object Priority | Select-Object Name, State, Priority, SafeAttachmentPolicy

# 3. Check which preset security policies are enabled (these ALWAYS win over custom policies)
Get-EOPProtectionPolicyRule | Select-Object Name, State, Priority

# 4. For a specific user — which policy actually applies to them?
Get-SafeLinksRule | Where-Object { $_.State -eq "Enabled" } |
    ForEach-Object { $_ | Select-Object Name, Priority, SentTo, RecipientDomainIs, SentToMemberOf }

# 5. Pull recent Safe Attachments/Safe Links detections for a message (Threat Explorer via Graph is portal-only —
#    fastest CLI proxy is message trace + quarantine)
Get-MessageTrace -RecipientAddress "<user@contoso.com>" -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date) |
    Select-Object Received, SenderAddress, Subject, Status
```

**Interpretation table:**

| Result | What it means | Action |
|---|---|---|
| No ATP/MDO SKU found | User has no Safe Links/Safe Attachments coverage | Check licensing — Fix 1 |
| `Get-SafeLinksRule` / `Get-SafeAttachmentRule` return nothing | No custom policies exist — user relies on **Built-in protection** only | Not necessarily broken — verify Built-in protection is what they expect (Fix 5) |
| User is in Standard/Strict preset **and** has a custom policy | Custom policy and its exclusions are **ignored** — preset always wins | Fix 5 |
| Link isn't wrapped (`safelinks.protection.outlook.com` missing) | Expected for Teams/Office apps (never wrapped) or a third-party gateway pre-processed the link | Fix 2 |
| Attachment delivered instantly, no ~15 min delay | Safe Attachments likely not scanning this recipient/policy | Fix 3 |
| `403` / `CmdletAccessDeniedException` on policy change | RBAC backend config stale, not a real permission gap | Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Defender for Office 365 (Plan 1 or Plan 2) licensing
    │
    ├── Exchange Online Protection (EOP) — base spam/malware layer runs FIRST
    │       └── Message must clear EOP before Safe Links/Safe Attachments even see it
    │
    ├── Policy coverage for the recipient (mutually exclusive — highest priority wins, then STOPS)
    │       ├── 1. Strict preset security policy (if enabled, if user is a target)
    │       ├── 2. Standard preset security policy (if enabled, if user is a target)
    │       ├── 3. Custom policies, in ascending Priority order (0 = highest)
    │       └── 4. Built-in protection (always applied last, priority fixed at "Lowest")
    │
    ├── Safe Links specific
    │       ├── Email: URL rewritten (safelinks.protection.outlook.com) + scanned at delivery + re-checked at click
    │       ├── Teams: URL NEVER rewritten — time-of-click check only, up to 24h to activate after policy change
    │       ├── Office apps: requires modern auth + work/school sign-in + supported app version — link check only, no wrap
    │       └── SharePoint/OneDrive: URLs NOT wrapped (perf optimization) but still processed
    │
    └── Safe Attachments specific
            ├── Mail path: Action = Off / Monitor / Block / Dynamic Delivery, applied per policy
            ├── SPO/OneDrive/Teams path: SEPARATE global toggle (EnableATPForSPOTeamsODB) — not part of mail policies at all
            └── Quarantine policy governs whether/how affected users are notified (default AdminOnlyAccessPolicy = silent)
```

**Common gaps:**
- A custom Safe Links/Safe Attachments policy exists and looks correctly scoped, but the user is *also* in the Standard or Strict preset policy — the preset wins and the custom policy (and its exceptions) are silently ignored.
- Safe Attachments for SharePoint/OneDrive/Teams is a **completely separate switch** from the mail Safe Attachments policies — having mail-side Safe Attachments "Block" doesn't protect files uploaded directly to SharePoint.
- A third-party secure email gateway sits in front of Exchange Online and rewraps/rewrites URLs before Microsoft sees them — Safe Links can't re-wrap an already-wrapped link, so protection silently doesn't apply.

</details>

---

## Diagnosis & Validation Flow

**1. Identify which surface is affected**

```
Link in an email isn't protected/wrapped?               → Fix 2
Attachment delivered without the expected ~15 min delay? → Fix 3
Link in Teams/Office app isn't being checked?             → Fix 4
User says they're "supposed to be protected" but aren't?  → Fix 5 (preset precedence)
Policy change won't save (403 / CmdletAccessDeniedException)? → Fix 6
File uploaded to SharePoint/OneDrive/Teams wasn't scanned? → Fix 1 (separate toggle)
```

**2. Confirm which policy actually covers the user (precedence matters more than existence)**

```powershell
# Preset policies always take precedence over anything custom — check these first
Get-EOPProtectionPolicyRule | Where-Object State -eq Enabled | Select-Object Name, Priority

# Then check custom rule scoping/priority
Get-SafeLinksRule | Sort-Object Priority | Format-Table Name, State, Priority, SentTo, SentToMemberOf, RecipientDomainIs -AutoSize
```

*Expected:* Exactly one rule applies to the affected user — the lowest `Priority` number among all rules that match them (Strict > Standard > custom-by-priority > Built-in).

**3. Confirm the SharePoint/OneDrive/Teams toggle if the issue is a file upload, not email**

```powershell
Get-AtpPolicyForO365 | Format-List EnableATPForSPOTeamsODB
```

**4. Check for a front-of-mail-flow gateway rewriting URLs before EOP sees them**

```
Exchange admin center → Mail flow → Connectors → look for an inbound connector from a
third-party secure email gateway (Mimecast, Proofpoint, Barracuda, etc.) configured BEFORE Microsoft 365.
If present: URL rewriting by that gateway happens first — Safe Links can't detect/rewrap an
already-rewritten URL, so protection is effectively bypassed for that path.
```

**5. Verify scan completion time is reasonable**

Safe Attachments detonation typically completes in ~15 minutes; longer delays point to a backlog or a policy set to **Monitor** with async detonation, not a failure.

---

## Common Fix Paths

<details><summary>Fix 1 — SharePoint/OneDrive/Teams file wasn't scanned by Safe Attachments</summary>

**Cause:** Mail-side Safe Attachments policies do **not** cover files uploaded directly to SharePoint, OneDrive, or Teams. That protection is a separate, tenant-wide toggle.

```powershell
# Check current state
Get-AtpPolicyForO365 | Format-List EnableATPForSPOTeamsODB

# Turn it on
Set-AtpPolicyForO365 -EnableATPForSPOTeamsODB $true

# (Recommended) Also block downloads of files already flagged malicious
# Requires SharePoint Online PowerShell (Connect-SPOService)
Set-SPOTenant -DisallowInfectedFileDownload $true
Get-SPOTenant | Format-List DisallowInfectedFileDownload
```

**Note:** By default, users can still delete and download malicious files in SPO/OneDrive even with detection on — `DisallowInfectedFileDownload` blocks the download (not delete) path. The **Share** button under "Manage access" remains available regardless.

**Rollback:** `Set-AtpPolicyForO365 -EnableATPForSPOTeamsODB $false` / `Set-SPOTenant -DisallowInfectedFileDownload $false`.

</details>

<details><summary>Fix 2 — Email link isn't wrapped / Safe Links didn't process it</summary>

**Cause A — Expected behavior, not a bug:**
- Links to SharePoint/OneDrive are intentionally **not wrapped** (still processed, just not rewritten) — this is a performance optimization, not a gap.
- RTF/TNEF-formatted messages, S/MIME-signed messages, and mail-enabled public folders are **not protected** by Safe Links at all — this is a hard product limitation.
- The policy has **"Do not rewrite the following URLs, do checks via API only"** turned on — links won't wrap but are still checked via API at click time in supported Outlook clients only (not in other mail apps).

**Cause B — Third-party gateway pre-processing:**
```
Check Exchange admin center → Mail flow → Connectors for an inbound connector positioned
before Microsoft 365 filtering (Mimecast/Proofpoint/Barracuda/etc.). If that gateway already
rewrote the URL, Safe Links sees an already-wrapped foreign link and can't re-process it.
```
**Fix:** Configure the third-party gateway to NOT rewrite URLs, and let Safe Links be the sole URL-rewriting layer — or accept dual protection is not stacking and document this as a known gap for affected mail paths.

**Cause C — Automatic forwarding:**
Auto-forwarded mail (inbox rule or SMTP forwarding) does **not** get its URLs rewritten for the final recipient unless that recipient is *also* covered by an active Safe Links policy, or the URL was already wrapped in a prior communication. Manually forwarded/replied messages ARE rewrapped regardless.

**Validate:**
```powershell
# View message source — look for https://<region>.safelinks.protection.outlook.com prefix on links
# (No direct PowerShell cmdlet reads rendered HTML body content — use OWA "View message source" or Outlook)
```

</details>

<details><summary>Fix 3 — Safe Attachments not delaying/scanning mail attachments</summary>

**Check the policy's Action setting:**
```powershell
Get-SafeAttachmentPolicy | Select-Object Name, Enable, Action, Redirect, RedirectAddress
```

| Action value | Behavior |
|---|---|
| `Off` | No scanning at all for messages covered by this policy |
| `Monitor` | Message delivered immediately; detonation happens async in background, alert only |
| `Block` | Message held (~15 min typical) until detonation completes; malicious attachments quarantined |
| `Dynamic Delivery` | Message body delivered immediately, attachment placeholder shown until scan completes |

**If Action = Off or Monitor and blocking behavior was expected:**
```powershell
Set-SafeAttachmentPolicy -Identity "<PolicyName>" -Action Block
```

**If no policy exists at all for the affected recipient:** they rely on **Built-in protection**, which does provide Safe Attachments coverage by default — confirm the user isn't excluded from Built-in protection (Defender portal → Preset security policies → Built-in protection → Manage protection settings → Exclude these users).

**Rollback:** `Set-SafeAttachmentPolicy -Identity "<PolicyName>" -Action Monitor` (non-blocking).

</details>

<details><summary>Fix 4 — Teams/Office app links not being checked</summary>

**Teams:**
```powershell
Get-SafeLinksPolicy | Select-Object Name, EnableSafeLinksForTeams
```
- Confirm `EnableSafeLinksForTeams` is `$true` on the policy covering the user.
- Changes to this setting take **up to 24 hours** to take effect — this is the single most common false-alarm escalation for this feature. Don't troubleshoot further until 24h have passed.
- Confirm the *sender's* policy (not just the recipient's) has Teams protection on — if the sender isn't covered, the recipient can click through unprotected.

**Office apps (Word/Excel/PowerPoint/Visio/OneNote):**
```powershell
Get-SafeLinksPolicy | Select-Object Name, EnableSafeLinksForOffice
```
- Requires the user be signed in with a **work or school account** using **modern authentication** — legacy auth or local/consumer sign-in bypasses this entirely.
- Only current Microsoft 365 Apps builds are supported — fully offline/perpetual-license Office (Office 2019/2021 without Microsoft 365 Apps) does not support Safe Links for Office apps.

**Rollback:** N/A — these are additive protections; disabling them only removes coverage, no data risk.

</details>

<details><summary>Fix 5 — User "should be protected" but a custom policy/exclusion isn't applying</summary>

**Cause:** Standard or Strict preset security policies **always** take precedence over custom Safe Links/Safe Attachments policies and over Built-in protection exclusions — silently. This is the #1 source of "I excluded this user but they're still being scanned" or the inverse, "I added this user to a custom policy but nothing changed" tickets.

```powershell
# Check if the user is a target of Standard or Strict presets
Get-EOPProtectionPolicyRule | Where-Object State -eq Enabled |
    Select-Object Name, SentTo, SentToMemberOf, RecipientDomainIs, ExceptIfSentTo, ExceptIfSentToMemberOf
```

**If the user is in a preset AND you need different behavior:**
1. Add the user to the preset's **exception list** (Defender portal → Preset security policies → Standard/Strict → Manage protection settings → Exclude these users/groups) — you cannot do this from a custom policy.
2. Only after exclusion from the preset will a custom policy or Built-in protection apply to them.

**Rollback:** Remove the exclusion to restore preset coverage.

</details>

<details><summary>Fix 6 — Policy change fails with 403 / CmdletAccessDeniedException</summary>

**Cause:** Despite having the correct role (Security Administrator / Organization Management), a stale Exchange Online RBAC backend configuration can block policy writes. This is a known, documented Microsoft-side issue, not a real permission gap.

**Steps:**
1. Re-confirm role assignment:
```powershell
Get-MgUserMemberOf -UserId "<UPN>" | Select-Object -ExpandProperty AdditionalProperties | Select-Object displayName
```
2. If the role is correctly assigned and the error persists, open a Microsoft Support ticket and reference **"RBAC configuration refresh"** by name — this is the documented resolution path and avoids a lengthy first-line triage loop.

**Rollback:** N/A — no destructive action taken.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Defender for Office 365 Safe Links / Safe Attachments
===========================================================================
Date/Time of issue:            ___________________________
Affected user UPN:              ___________________________
Affected surface:
  [ ] Email link (Safe Links)
  [ ] Email attachment (Safe Attachments)
  [ ] Teams link
  [ ] Office app link
  [ ] SharePoint/OneDrive/Teams file upload

Tenant ID:                      ___________________________
MDO licensing confirmed:        [ ] Plan 1  [ ] Plan 2  [ ] Not licensed

Policy coverage:
  Preset policy covering user:  [ ] Strict [ ] Standard [ ] None
  Custom policy name (if any):  ___________________________
  Custom policy priority:       ___________________________
  Built-in protection excluded: [ ] Yes  [ ] No

Message/file details:
  Message ID / Internet header: ___________________________
  Sender:                       ___________________________
  URL or filename in question:  ___________________________
  Third-party gateway in path:  [ ] Yes — name: _______  [ ] No

Safe Attachments Action (if relevant): [ ] Off [ ] Monitor [ ] Block [ ] Dynamic Delivery
SPO/OneDrive/Teams toggle state (EnableATPForSPOTeamsODB): ___________

Attached evidence:
  [ ] Get-SafeLinksRule / Get-SafeAttachmentRule export
  [ ] Message trace export
  [ ] Message source showing (or not showing) safelinks.protection.outlook.com wrap

Support contact: https://admin.microsoft.com → Support → New service request
Product: Microsoft Defender for Office 365
```

---

## 🎓 Learning Pointers

- **Policy precedence is a strict stop-at-first-match chain, not a merge:** Strict preset → Standard preset → custom policies by priority number → Built-in protection (fixed lowest). The moment a policy matches a recipient, evaluation stops — nothing "adds up." A custom exclusion in a lower-priority policy never overrides a higher one. [MS Docs: Order of precedence for preset security policies](https://learn.microsoft.com/en-us/defender-office-365/preset-security-policies#order-of-precedence-for-preset-security-policies-and-other-threat-policies)

- **Safe Attachments for SharePoint/OneDrive/Teams is architecturally separate from mail Safe Attachments:** one is a per-recipient mail policy (`*-SafeAttachmentPolicy`/`*-SafeAttachmentRule`), the other is a single tenant-wide toggle (`Set-AtpPolicyForO365 -EnableATPForSPOTeamsODB`). Assuming mail-side "Block" protects file uploads is a common and costly misconfiguration. [MS Docs: Safe Attachments for SharePoint, OneDrive, and Teams](https://learn.microsoft.com/en-us/defender-office-365/safe-attachments-for-spo-odfb-teams-about)

- **Safe Links can't protect what it never sees unwrapped:** a third-party secure email gateway that rewrites URLs before Microsoft 365 filtering runs will produce links Safe Links can't re-process. If you're running dual URL-protection stacks, verify only one layer does the actual rewriting. [MS Docs: Safe Links overview](https://learn.microsoft.com/en-us/defender-office-365/safe-links-about)

- **Teams Safe Links changes are eventually consistent, not immediate:** budget up to 24 hours before treating a Teams protection toggle as broken. This single fact resolves a large fraction of "I turned it on and it's still not working" tickets. [MS Docs: Safe Links for Microsoft Teams](https://learn.microsoft.com/en-us/defender-office-365/safe-links-about#safe-links-settings-for-microsoft-teams)

- **The default quarantine policy for Safe Attachments (`AdminOnlyAccessPolicy`) is silent by design:** users get no notification and cannot self-release malware/phish detections regardless of quarantine policy permissions. If stakeholders expect visibility, you must explicitly create and assign a quarantine policy with notifications enabled. [MS Docs: Anatomy of a quarantine policy](https://learn.microsoft.com/en-us/defender-office-365/quarantine-policies#anatomy-of-a-quarantine-policy)

- **A 403/CmdletAccessDeniedException on a correctly-permissioned account is a known RBAC backend staleness issue** — don't burn time re-auditing role assignments; open a ticket referencing "RBAC configuration refresh" directly. [MS Docs: Safe Attachments permissions](https://learn.microsoft.com/en-us/defender-office-365/safe-attachments-policies-configure)
