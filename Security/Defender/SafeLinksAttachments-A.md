# Defender for Office 365 — Safe Links & Safe Attachments — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers the two real-time protection engines in **Microsoft Defender for Office 365 (MDO) Plan 1/Plan 2**:

- **Safe Links** — URL rewriting (email) and time-of-click verification (email, Teams, Office apps) of hyperlinks
- **Safe Attachments** — post-anti-malware detonation scanning of file attachments in a virtual sandbox, in both mail flow and (as a separate feature) SharePoint/OneDrive/Teams

**Explicitly out of scope for this topic** (see the linked topics instead):
- Anti-spam/anti-malware/anti-phishing baseline filtering → `M365/Exchange/EOP-AntiSpam-B.md` / `-A.md`
- Attack Simulation Training (phishing *simulations*, a training tool) → `AttackSimulationTraining-B.md` / `-A.md`
- Transport rule / mail flow routing → `M365/Exchange/TransportRules-B.md` / `-A.md`
- Quarantine end-user experience details beyond what's needed to diagnose Safe Attachments blocks → see [Quarantine policies](https://learn.microsoft.com/en-us/defender-office-365/quarantine-policies)

**Assumptions:**
- Microsoft Defender for Office 365 Plan 1 or Plan 2 licensing (not just base EOP, which ships with every Exchange Online mailbox but has neither feature)
- Exchange Online PowerShell (`Connect-ExchangeOnline`) available for `*-SafeLinksPolicy`/`*-SafeAttachmentPolicy` cmdlets
- Familiarity with the general MDO policy precedence model shared across all threat policy types

---

## How It Works

<details><summary>Full architecture — policy model, mail flow position, and per-surface mechanics</summary>

### Two products, two cmdlet families, one shared precedence model

Both Safe Links and Safe Attachments split into a **policy** object (what to do) and a **rule** object (who it applies to, and at what priority) — a pattern shared with Exchange transport rules:

```
New-SafeLinksPolicy       "<PolicyName>" -EnableSafeLinksForEmail $true ...
        │
New-SafeLinksRule         "<RuleName>" -SafeLinksPolicy "<PolicyName>" -RecipientDomainIs contoso.com
        │
        └── Creates the association. In the Defender portal, these two objects are created together
            and shown as a single "policy" — but in PowerShell they're managed and removed independently.
            Removing a *Policy does NOT remove its associated *Rule, and vice versa — a common source of
            orphaned objects after portal-driven cleanup that used PowerShell for creation.
```

Identical pattern for Safe Attachments: `New-SafeAttachmentPolicy` → `New-SafeAttachmentRule`.

### Where this sits in mail flow

```
Inbound message
    │
    ▼
Connection filtering (IP reputation) + Anti-malware (signature-based)
    │
    ▼
Anti-spam filtering (content/heuristics)
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│  Safe Attachments (if policy Action ≠ Off)                       │
│    - Off: no scanning                                            │
│    - Monitor: deliver immediately, detonate async, alert only    │
│    - Block: HOLD message (~15 min typical) until detonation done │
│    - Dynamic Delivery: deliver body immediately, attachment      │
│      placeholder shown until scan completes, then swapped in     │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│  Safe Links (email surface)                                      │
│    - URLs rewritten to https://<region>.safelinks.protection.    │
│      outlook.com/... UNLESS "Do not rewrite, API-only" is set    │
│    - SharePoint/OneDrive URLs: processed but NOT wrapped (perf)  │
│    - Scanned again at time-of-click regardless of wrap state     │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
Message delivered to mailbox
```

Safe Links for **Teams** and **Office apps** are architecturally separate from this mail-flow pipeline — they are pure time-of-click services with no wrapping step, invoked by the Teams/Office client at the moment of click, gated entirely by which Safe Links policy (if any) covers the *clicking* user.

### Policy precedence — identical mechanism for both features

```
Evaluation order (STOPS at first match — this is not additive):

1. Strict preset security policy       (if enabled AND recipient is a target)
2. Standard preset security policy     (if enabled AND recipient is a target)
3. Custom policies, by ascending Priority (0 = highest; ties are not allowed)
4. Built-in protection                 (always evaluated last; fixed at "Lowest"
                                         priority; cannot be reordered)
```

**Critical implication:** a recipient's coverage is determined by exactly ONE policy — never a blend. If a recipient matches Standard preset, any custom policy that also targets them (and any exclusion configured only in that custom policy) is completely ignored. Exclusions from Built-in protection or Standard/Strict must be configured *within that specific policy's own exception list* — there is no way to "opt someone out" from a lower-priority policy once a higher one already claims them.

### Safe Attachments for SharePoint/OneDrive/Teams — a second, unrelated feature

Despite the shared name, file-upload protection for SPO/OneDrive/Teams is **not** governed by `*-SafeAttachmentPolicy`/`*-SafeAttachmentRule` at all. It's a single tenant-wide boolean:

```
Set-AtpPolicyForO365 -EnableATPForSPOTeamsODB $true|$false
```

Architecturally this makes sense once you realize the mail-side feature scans attachments *in transit through Exchange Online*, while the SPO/OneDrive/Teams feature scans files *at rest / on upload* through the SharePoint content processing pipeline — two different detonation triggers, two different products under one marketing name. A file uploaded directly to a SharePoint library never transits Exchange Online and therefore is invisible to mail Safe Attachments policies regardless of how they're configured.

A companion, independently-toggled setting controls whether users can still *download* a file already flagged malicious (they can still delete it either way):

```
Set-SPOTenant -DisallowInfectedFileDownload $true|$false
```

### Time-of-click re-verification — why "scanned at delivery" isn't the whole story

Both wrapped (Safe Links rewritten) and unwrapped (API-only mode) URLs are re-checked at the moment of click, not just at delivery. This matters because a URL that was benign when the message arrived can be weaponized hours or days later — Safe Links' rewritten-link architecture means the *same* link, clicked twice, can produce different outcomes if the destination's reputation changed in between. API-only mode (no rewriting) achieves the same re-check via a client-side call, but **only in supported Outlook builds** (Windows, Mac, web) — any other mail client bypasses the click-time check entirely and only benefits from the delivery-time scan.

### Forwarding semantics

| Forwarding type | URL rewrite behavior for the final recipient |
|---|---|
| Manual forward/reply | Always rewrapped (per-recipient, both internal and external) |
| Automatic (inbox rule or SMTP forward) | NOT rewrapped for the final recipient **unless** that recipient is also covered by an active Safe Links policy, or the URL was already wrapped in a prior communication |

This asymmetry is a frequent source of "the forwarded copy isn't protected" tickets — the fix is almost always to confirm the *final* recipient (not just the original one) is covered by a Safe Links policy.

</details>

---

## Dependency Stack

```
Microsoft 365 tenant + Exchange Online mailboxes
        │
Microsoft Defender for Office 365 Plan 1 or Plan 2 license
        │
        ├── Preset security policies (Standard / Strict) ── ALWAYS evaluated first, if enabled
        │
        ├── Custom Safe Links policy + rule ── evaluated by Priority if no preset match
        │       ├── Email sub-feature: rewrite + delivery-time scan + click-time re-check
        │       ├── Teams sub-feature: click-time only, no wrap, ≤24h activation lag
        │       └── Office apps sub-feature: click-time only, requires modern auth + work/school sign-in
        │
        ├── Custom Safe Attachments policy + rule ── evaluated by Priority if no preset match
        │       └── Mail path only — Action = Off / Monitor / Block / Dynamic Delivery
        │
        ├── Built-in protection ── fixed lowest priority, catches everyone not otherwise covered
        │
        └── Safe Attachments for SharePoint/OneDrive/Teams ── INDEPENDENT toggle
                (Set-AtpPolicyForO365 -EnableATPForSPOTeamsODB), not gated by any of the above

External dependency: mail flow path integrity
        └── No third-party gateway upstream of Microsoft 365 that pre-rewrites URLs
            (breaks Safe Links' ability to process the original link)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Custom policy exclusion doesn't work for a user | User is covered by Standard/Strict preset, which ignores custom policy exceptions entirely | `Get-EOPProtectionPolicyRule` — check preset targets first |
| Link in email isn't wrapped (`safelinks.protection.outlook.com` missing) | SharePoint/OneDrive URL (never wrapped by design), API-only mode set, or third-party gateway pre-rewrote it | `Get-SafeLinksPolicy` for `EnableSafeLinksForEmail`/rewrite mode; check mail flow connectors |
| Auto-forwarded mail's links aren't protected | Automatic forwarding doesn't rewrap unless final recipient is also covered | Confirm final (not original) recipient's policy coverage |
| Teams links not protected after policy change | Up to 24h activation delay is normal, not a bug | Wait 24h before escalating |
| File uploaded to SharePoint wasn't scanned | Mail Safe Attachments doesn't cover SPO/OneDrive/Teams — separate toggle | `Get-AtpPolicyForO365 \| fl EnableATPForSPOTeamsODB` |
| User never gets notified their mail was quarantined by Safe Attachments | Default quarantine policy `AdminOnlyAccessPolicy` has notifications off by design | Check `QuarantineTag` on the Safe Attachments policy |
| User can't self-release a Safe Attachments quarantine item even with permissive quarantine policy | Malware/phish detections by Safe Attachments can NEVER be self-released by design — only *requested* | This is expected; admin must release manually |
| Office app links not being checked | Legacy auth, non-Microsoft-365-Apps Office build, or user not signed in with work/school account | Verify auth type and Office build/channel |
| Policy change silently fails or 403s | Stale Exchange Online RBAC backend cache | Re-test after re-auth; escalate to MS Support "RBAC configuration refresh" if persists |
| Attachment delivered instantly with no scan delay | Policy Action = Off or Monitor (non-blocking), or user covered by a different policy than expected | `Get-SafeAttachmentRule` priority + `Get-SafeAttachmentPolicy` Action |
| Detonation taking far longer than 15 minutes | High tenant-wide scan volume/backlog, or Dynamic Delivery async completion (expected to feel "delayed" since body is delivered first) | Check for org-wide pattern vs. single message; if org-wide, open MS Support ticket |
| "Do not rewrite the following URLs" entry not respected in Teams or Office web app | That list is honored by email/Outlook only — Teams and Office web apps ignore it | Use Tenant Allow/Block List for a universal allow, understanding it doesn't skip Safe Links scanning itself |

---

## Validation Steps

**1. Confirm MDO licensing (not just base EOP)**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "ATP_ENTERPRISE|THREAT_INTELLIGENCE" } |
    Select-Object SkuPartNumber, @{N="Status";E={($_.ServicePlans | Where-Object ServicePlanName -match "ATP_ENTERPRISE").ProvisioningStatus}}
```
*Expected:* At least one SKU with an MDO service plan in `Success` provisioning status.

**2. Enumerate every policy and rule with priority**
```powershell
Connect-ExchangeOnline
Get-SafeLinksPolicy | Select-Object Name, EnableSafeLinksForEmail, EnableSafeLinksForTeams, EnableSafeLinksForOffice, DoNotRewriteUrls
Get-SafeLinksRule | Sort-Object Priority | Select-Object Name, State, Priority, SafeLinksPolicy
Get-SafeAttachmentPolicy | Select-Object Name, Enable, Action, QuarantineTag
Get-SafeAttachmentRule | Sort-Object Priority | Select-Object Name, State, Priority, SafeAttachmentPolicy
```
*Bad sign:* Overlapping recipient scopes across multiple enabled rules with unclear priority ordering — the admin likely doesn't know which policy actually wins for a given user.

**3. Confirm preset policy targets (these override everything else)**
```powershell
Get-EOPProtectionPolicyRule | Select-Object Name, State, Priority, SentTo, SentToMemberOf, RecipientDomainIs, ExceptIfSentTo
```
*Expected:* Clear, non-overlapping targeting; if "All users" is targeted by Standard or Strict, no custom policy or Built-in protection exclusion will ever apply.

**4. Confirm SharePoint/OneDrive/Teams Safe Attachments state**
```powershell
Get-AtpPolicyForO365 | Format-List EnableATPForSPOTeamsODB
Get-SPOTenant | Format-List DisallowInfectedFileDownload   # requires Connect-SPOService
```

**5. Confirm no upstream URL-rewriting gateway**
```powershell
Get-InboundConnector | Select-Object Name, Enabled, SenderDomains, TlsSenderCertificateName
# Cross-reference connector source with known secure email gateway vendors (Mimecast, Proofpoint,
# Barracuda, Cisco, etc.) — if present, verify their URL rewriting is disabled or accepted as authoritative.
```

**6. Confirm Safe Links Teams/Office coverage for a specific user**
```powershell
$rule = Get-SafeLinksRule | Where-Object { $_.State -eq "Enabled" } | Sort-Object Priority | Select-Object -First 1
Get-SafeLinksPolicy -Identity $rule.SafeLinksPolicy | Select-Object EnableSafeLinksForTeams, EnableSafeLinksForOffice
```

**7. Verify quarantine visibility for Safe Attachments detections**
```powershell
Get-SafeAttachmentPolicy | Select-Object Name, QuarantineTag
Get-QuarantinePolicy -Identity "<QuarantineTagName>" | Select-Object Name, EndUserQuarantinePermissions
```
*Expected (if visibility is required):* A quarantine policy other than the default `AdminOnlyAccessPolicy`, with notifications enabled.

---

## Troubleshooting Steps (by phase)

### Phase 1: Confirm the correct policy applies at all

1. Run validation step 2 and 3 together — determine the single policy (preset or custom) that actually covers the affected user, by precedence, not by which policy an admin *intended* to apply.
2. If a preset policy unexpectedly covers the user, decide whether to add them to that preset's exception list or accept preset coverage as correct.

### Phase 2: Email Safe Links not behaving as expected

1. Confirm `EnableSafeLinksForEmail` on the resolved policy.
2. Check whether `DoNotRewriteUrls` (API-only mode) is set — if so, protection still exists but only via client-side API calls in supported Outlook builds; other clients (mobile IMAP apps, third-party clients) get delivery-time scanning only.
3. Check for SharePoint/OneDrive destination URLs — these are never wrapped by design; verify via Threat Explorer that the URL was still *processed* (a distinct question from whether it was *wrapped*).
4. Check mail flow connectors for an upstream secure email gateway that may have already rewritten the URL before Microsoft 365 saw it.
5. For auto-forwarded mail specifically, re-run validation against the *final* recipient's policy coverage, not the original recipient's.

### Phase 3: Safe Attachments not blocking/delaying as expected

1. Confirm the resolved policy's `Action` value — `Off` and `Monitor` are both non-blocking by design.
2. If `Block` or `Dynamic Delivery` is set but no delay is observed, confirm the message actually matched this policy (not a different, less strict one) via priority resolution.
3. Check `QuarantineTag` — if messages ARE being blocked but the requester says "nothing happened," the block may have succeeded silently under `AdminOnlyAccessPolicy`.
4. For SharePoint/OneDrive/Teams uploads specifically, remember this is governed by `EnableATPForSPOTeamsODB`, entirely independent of the mail-side Action setting.

### Phase 4: Teams or Office app links unprotected

1. For Teams: confirm `EnableSafeLinksForTeams` on the *sender's* policy — an unprotected sender can share a link that reaches a protected recipient but still isn't checked, since Teams Safe Links validates based on chat/channel context, not purely per-recipient. Then confirm 24h has elapsed since any policy change.
2. For Office apps: confirm the user is signed in with a work/school account, using modern auth, on a Microsoft 365 Apps build (not a standalone perpetual-license Office install).

### Phase 5: Access/permission errors modifying policies

1. Re-verify role assignment (Security Administrator, Organization Management, or Global Administrator).
2. If correctly assigned and a 403/CmdletAccessDeniedException persists, this is very likely a stale RBAC backend cache on Microsoft's side — escalate to Microsoft Support referencing "RBAC configuration refresh" rather than continuing to re-audit local permissions.

### Phase 6: Tenant-wide pattern (multiple users affected)

1. Determine if the issue correlates with a specific preset policy rollout, a recent priority reordering, or a new mail flow connector.
2. Check Microsoft 365 Service Health for MDO-related incidents before assuming tenant misconfiguration.
3. Use the evidence pack script below to capture full tenant policy state for comparison against a known-good baseline or for Microsoft Support escalation.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Migrate from custom policies to Standard/Strict preset security policies</summary>

**Scenario:** Tenant has accumulated multiple overlapping custom Safe Links/Safe Attachments policies over time, and troubleshooting precedence has become error-prone. Microsoft's own guidance recommends preset policies for most organizations.

**Steps:**
1. Inventory current custom policies and their actual effective targets:
   ```powershell
   Get-SafeLinksRule | Sort-Object Priority | Select-Object Name, Priority, SentTo, SentToMemberOf, RecipientDomainIs
   Get-SafeAttachmentRule | Sort-Object Priority | Select-Object Name, Priority, SentTo, SentToMemberOf, RecipientDomainIs
   ```
2. In the Defender portal, review **Standard** and **Strict** preset security policy definitions — these already encode Microsoft's recommended settings for both features.
3. Pilot: enable Standard preset for a small user group first (do NOT target "All users" immediately).
4. Confirm no regression for 1-2 weeks, monitoring Threat Explorer for unexpected blocks.
5. Expand Standard preset to broader population; reserve Strict for high-risk user groups (executives, finance, admins).
6. Once presets cover the intended population, disable (don't delete immediately) the redundant custom policies:
   ```powershell
   Disable-SafeLinksRule -Identity "<RuleName>"
   Disable-SafeAttachmentRule -Identity "<RuleName>"
   ```
7. After a confirmed burn-in period with no issues, remove the disabled custom policies and rules.

**Rollback:** Re-enable the custom rules (`Enable-SafeLinksRule`/`Enable-SafeAttachmentRule`) and reduce preset policy scope; presets and custom policies can coexist during migration since precedence is deterministic.

</details>

<details>
<summary>Playbook 2 — Enable SharePoint/OneDrive/Teams Safe Attachments tenant-wide (previously mail-only coverage)</summary>

**Scenario:** Tenant has mail Safe Attachments fully configured but never enabled the separate SPO/OneDrive/Teams protection — a common gap since it's not part of the mail policy wizard.

**Steps:**
1. Confirm current state:
   ```powershell
   Get-AtpPolicyForO365 | Format-List EnableATPForSPOTeamsODB
   ```
2. Enable it:
   ```powershell
   Set-AtpPolicyForO365 -EnableATPForSPOTeamsODB $true
   ```
3. (Recommended) Block downloads of already-flagged files:
   ```powershell
   Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
   Set-SPOTenant -DisallowInfectedFileDownload $true
   ```
4. Create an alert policy so admins are notified on detection (Defender portal → Alert policy → New, Activity = "Detected malware in file", Category = Threat management) or via PowerShell:
   ```powershell
   New-ProtectionAlert -Name "Malicious Files in Libraries" `
       -Description "Notifies admins when malicious files are detected in SharePoint, OneDrive, or Microsoft Teams" `
       -AggregationType None -Category ThreatManagement -ThreatType Activity `
       -Operation FileMalwareDetected -NotifyUser "admin1@contoso.com"
   ```
5. Allow up to 30 minutes for the setting to take effect. Validate with a EICAR test file if permitted by change control.

**Rollback:** `Set-AtpPolicyForO365 -EnableATPForSPOTeamsODB $false` — note this does not retroactively "unscan" anything, it only stops future scanning.

</details>

<details>
<summary>Playbook 3 — Resolve URL protection gap caused by an upstream third-party gateway</summary>

**Scenario:** Organization runs a secure email gateway (Mimecast, Proofpoint, Barracuda, etc.) in front of Microsoft 365, and Safe Links appears to not be wrapping/protecting links despite correct policy configuration.

**Steps:**
1. Confirm the gateway's position in mail flow:
   ```powershell
   Get-InboundConnector | Select-Object Name, Enabled, SenderDomains, ConnectorType
   ```
2. Log into the third-party gateway's admin console and check whether its own URL-rewriting/link-protection feature is enabled.
3. **Decision point** — pick one, don't run both rewriting the same link:
   - **Option A (recommended for MDO-primary shops):** Disable URL rewriting in the third-party gateway; let Safe Links be sole authority. Keep the gateway for its other functions (spam/malware pre-filtering, DLP, etc.).
   - **Option B (gateway-primary shops):** Accept that Safe Links' email-surface protection is effectively bypassed for gateway-routed mail, and rely on the gateway's own equivalent feature; Safe Links for Teams/Office apps remains unaffected either way since those don't depend on mail flow wrapping.
4. Document the decision in the tenant's architecture notes — this is exactly the kind of configuration that gets "rediscovered" as a mystery bug 18 months later.
5. Validate: send a test message with a known-benign test URL through the full path and inspect message source for `safelinks.protection.outlook.com` wrapping.

**Rollback:** Re-enable gateway-side URL rewriting if Option A causes unexpected issues; this is a configuration toggle, not a destructive change.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Safe Links / Safe Attachments tenant configuration for escalation or audit.
.DESCRIPTION Read-only. Exports policy/rule state, preset targeting, SPO/OneDrive/Teams toggle,
             and inbound connector list (to spot third-party gateways) to CSV.
.NOTES       Requires: ExchangeOnlineManagement module (Connect-ExchangeOnline),
             optionally Microsoft.Graph and Microsoft.Online.SharePoint.PowerShell for full coverage.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\SafeLinksAttachments-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

function Write-Status { param([string]$Msg,[string]$Status="INFO") Write-Host "[$Status] $Msg" -ForegroundColor $(switch($Status){"OK"{"Green"}"WARN"{"Yellow"}"ERROR"{"Red"}default{"Cyan"}}) }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Status "Collecting Safe Links policies/rules..."
Get-SafeLinksPolicy | Select-Object Name, EnableSafeLinksForEmail, EnableSafeLinksForTeams, EnableSafeLinksForOffice, DoNotRewriteUrls |
    Export-Csv "$OutputPath\safelinks_policies.csv" -NoTypeInformation
Get-SafeLinksRule | Sort-Object Priority | Select-Object Name, State, Priority, SafeLinksPolicy, SentTo, SentToMemberOf, RecipientDomainIs |
    Export-Csv "$OutputPath\safelinks_rules.csv" -NoTypeInformation

Write-Status "Collecting Safe Attachments policies/rules..."
Get-SafeAttachmentPolicy | Select-Object Name, Enable, Action, QuarantineTag, Redirect, RedirectAddress |
    Export-Csv "$OutputPath\safeattachment_policies.csv" -NoTypeInformation
Get-SafeAttachmentRule | Sort-Object Priority | Select-Object Name, State, Priority, SafeAttachmentPolicy, SentTo, SentToMemberOf, RecipientDomainIs |
    Export-Csv "$OutputPath\safeattachment_rules.csv" -NoTypeInformation

Write-Status "Collecting preset security policy targeting..."
try {
    Get-EOPProtectionPolicyRule | Select-Object Name, State, Priority, SentTo, SentToMemberOf, RecipientDomainIs, ExceptIfSentTo |
        Export-Csv "$OutputPath\preset_policy_targeting.csv" -NoTypeInformation
} catch { Write-Status "Could not query preset policy rules: $_" "WARN" }

Write-Status "Collecting SharePoint/OneDrive/Teams Safe Attachments state..."
try {
    Get-AtpPolicyForO365 | Select-Object EnableATPForSPOTeamsODB |
        Export-Csv "$OutputPath\spo_teams_atp_state.csv" -NoTypeInformation
} catch { Write-Status "Could not query Get-AtpPolicyForO365: $_" "WARN" }

Write-Status "Collecting inbound connectors (check for third-party gateways)..."
try {
    Get-InboundConnector | Select-Object Name, Enabled, SenderDomains, ConnectorType, TlsSenderCertificateName |
        Export-Csv "$OutputPath\inbound_connectors.csv" -NoTypeInformation
} catch { Write-Status "Could not query inbound connectors: $_" "WARN" }

Write-Status "Evidence collected to: $OutputPath" "OK"
Write-Status "Files: $(Get-ChildItem $OutputPath | Measure-Object | Select-Object -ExpandProperty Count)" "OK"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List Safe Links policies | `Get-SafeLinksPolicy` |
| List Safe Links rules (priority order) | `Get-SafeLinksRule \| Sort-Object Priority` |
| Create Safe Links policy | `New-SafeLinksPolicy -Name "<Name>" -EnableSafeLinksForEmail $true` |
| Create Safe Links rule | `New-SafeLinksRule -Name "<Name>" -SafeLinksPolicy "<Policy>" -RecipientDomainIs contoso.com` |
| List Safe Attachments policies | `Get-SafeAttachmentPolicy` |
| List Safe Attachments rules | `Get-SafeAttachmentRule \| Sort-Object Priority` |
| Create Safe Attachments policy | `New-SafeAttachmentPolicy -Name "<Name>" -Enable $true` |
| Create Safe Attachments rule | `New-SafeAttachmentRule -Name "<Name>" -SafeAttachmentPolicy "<Policy>" -RecipientDomainIs contoso.com` |
| Check preset policy targeting | `Get-EOPProtectionPolicyRule` |
| Check SPO/OneDrive/Teams toggle | `Get-AtpPolicyForO365 \| fl EnableATPForSPOTeamsODB` |
| Enable SPO/OneDrive/Teams protection | `Set-AtpPolicyForO365 -EnableATPForSPOTeamsODB $true` |
| Block malicious file downloads in SPO | `Set-SPOTenant -DisallowInfectedFileDownload $true` |
| Set rule priority | `Set-SafeLinksRule -Identity "<Name>" -Priority <n>` / `Set-SafeAttachmentRule -Identity "<Name>" -Priority <n>` |
| Enable/disable a rule | `Enable-SafeLinksRule` / `Disable-SafeLinksRule` / `Enable-SafeAttachmentRule` / `Disable-SafeAttachmentRule` |
| Check inbound connectors (gateway detection) | `Get-InboundConnector` |
| Open Safe Links portal page | `security.microsoft.com/safelinksv2` |
| Open Safe Attachments portal page | `security.microsoft.com/safeattachmentv2` |
| View reports | `security.microsoft.com` → Reports → Email & collaboration → Threat protection status |

---

## 🎓 Learning Pointers

- **Preset security policies exist specifically to eliminate the precedence-debugging problem this topic largely covers.** Microsoft's stated recommendation for most tenants is to use Standard/Strict presets rather than hand-building custom Safe Links/Safe Attachments policies — every precedence bug in this runbook stems from custom policy sprawl. [MS Docs: Preset security policies](https://learn.microsoft.com/en-us/defender-office-365/preset-security-policies)

- **"Safe Attachments" is really two products wearing one name** — mail-flow detonation and SPO/OneDrive/Teams file-upload detonation are independently licensed-the-same-way but independently *configured*, with zero shared policy surface. Always ask "which Safe Attachments?" before troubleshooting. [MS Docs: Safe Attachments for SharePoint, OneDrive, and Teams](https://learn.microsoft.com/en-us/defender-office-365/safe-attachments-for-spo-odfb-teams-about)

- **Time-of-click re-verification means "scanned clean at delivery" is not a permanent guarantee** — this is a feature, not a bug, but it explains why the same email can trigger a warning today that it didn't trigger last week. Build this into user education material to reduce "why did this suddenly get blocked" tickets. [MS Docs: Safe Links overview](https://learn.microsoft.com/en-us/defender-office-365/safe-links-about)

- **Malware/phish detections by Safe Attachments can never be self-released by the recipient, regardless of quarantine policy permissiveness** — only *release requests* are possible. Set stakeholder expectations accordingly before deploying blocking policies broadly. [MS Docs: Quarantine policies](https://learn.microsoft.com/en-us/defender-office-365/quarantine-policies)

- **Dual URL-rewriting stacks (MDO Safe Links + a third-party secure email gateway) don't compose — they silently pick a winner** based on mail flow order. Audit `Get-InboundConnector` early in any MDO deployment project, not after the first "why isn't this working" ticket. [MS Docs: Safe Links about — link rewriting notes](https://learn.microsoft.com/en-us/defender-office-365/safe-links-about)

- **RBAC-related 403s on correctly-permissioned accounts are a documented Microsoft-side staleness issue**, not a local misconfiguration — knowing the exact escalation phrase ("RBAC configuration refresh") skips a support triage cycle. [MS Docs: Safe Attachments policy permissions](https://learn.microsoft.com/en-us/defender-office-365/safe-attachments-policies-configure)
