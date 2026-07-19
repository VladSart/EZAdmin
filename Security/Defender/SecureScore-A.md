# Microsoft Secure Score — Reference Runbook (Mode A: Deep Dive)
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

Covers **Microsoft Secure Score** as surfaced in the Microsoft Defender portal at `security.microsoft.com/securescore` — a single tenant-wide security posture measurement spanning four categories (Identity, Device, Apps, Data) and computed from recommendations across Microsoft Entra ID, Exchange Online, SharePoint Online, Microsoft Teams, Defender for Endpoint, Defender for Identity, Defender for Cloud Apps, Purview Information Protection, App Governance (OAuth app risk), and a growing set of connected non-Microsoft products (Okta, Salesforce, ServiceNow, GitHub, Docusign, Zoom, Citrix ShareFile). Covers the scoring model, the Microsoft Graph `secureScore`/`secureScoreControlProfiles` API surface, RBAC, history/trend/comparison features, and MSP fleet-review patterns.

**Explicitly out of scope (covered elsewhere, same name/different product):**
- **Defender for Cloud's Secure Score** — an entirely separate Azure-resource-scoped CSPM score computed via the `Az.Security` module (`Get-AzSecuritySecureScore`), covering Azure/AWS/GCP resource posture, not M365 workload posture. See `DefenderForCloud-A.md`. There is zero data overlap between the two APIs.
- **Microsoft Secure Score for Devices** — the underlying device-level exposure/configuration scoring engine inside Defender Vulnerability Management that feeds the *Device* category of this score. This doc covers how that category rolls up into the tenant score and its status-management quirks; TVM's own scanning architecture, exposure score calculation internals, and remediation workflow live in `DefenderVulnMgmt-A.md`.
- **Microsoft Purview Compliance Manager score** — a separate regulatory/compliance-assessment score (GDPR, ISO 27001, NIST, etc.) with its own improvement-action model. Not built in this repo as of this writing; do not conflate a client asking about "compliance score" with Secure Score.
- Any specific remediation steps for the underlying product misconfigurations a recommendation points at (MFA policy design, DLP policy authoring, ASR rule tuning, etc.) — follow the recommendation's `ActionUrl` into the owning product's own runbook (`Security/ConditionalAccess/`, `Security/Purview/DLP-Policy-A.md`, `Security/Defender/ASR-Rules-A.md`, etc.).

---

## How It Works

<details><summary>Full architecture</summary>

Secure Score is not a live query against every product every time someone loads the page. It is a **precomputed, periodically-synced aggregate**:

```
Per-product control definitions (secureScoreControlProfiles)
        │  Microsoft-authored list of ~200+ possible recommended actions,
        │  each tagged with: controlCategory (Identity/Device/Apps/Data),
        │  maxScore (≤10 pts), rank, implementationCost, userImpact, tier,
        │  service (which product owns it), threats[] it mitigates,
        │  and an actionUrl straight into the owning product's admin UI
        ▼
Tenant-specific evaluation (controlScores, embedded in the secureScore object)
        │  each control is checked against LIVE tenant configuration and
        │  awarded 0 to maxScore points — most controls are binary
        │  (100% or 0%), some are percentage-of-population
        │  (e.g. "% of users covered by a Conditional Access MFA policy")
        ▼
Aggregation into a single secureScore object per sync
        │  currentScore / maxScore, enabledServices[], licensedUserCount,
        │  activeUserCount, averageComparativeScores[] (peer benchmarking)
        ▼
Refresh cadence (NOT uniform across products):
        │  - Real-time: the portal visualization reflects the latest
        │    already-computed snapshot instantly
        │  - Daily: a full recompute sync runs once per day for most
        │    products — this is the actual "did my fix take effect" clock
        │  - Weekly / Monthly: Microsoft Teams and Microsoft Entra
        │    recommendations specifically refresh on a slower cadence —
        │    a documented exception, not a bug
        ▼
Portal / Graph API surface (RBAC-gated, see Dependency Stack Layer 5)
```

**The scoring math, precisely:** each control has a `maxScore` of 10 points or less. Most controls are scored in a strictly binary fashion — implement the recommended setting/policy and you get 100% of the points, or 0% if not. A smaller set of controls award **partial credit as a percentage of population covered**. Microsoft's own worked example: a control worth 10 points for "protect all users with MFA," with only 50 of 100 total users actually covered, awards `50/100 × 10 = 5` points. This is why rolling out a control to a pilot group moves the score partially, not to zero or full — a very common point of confusion when an engineer expects "I turned on the policy" to mean "I get full points."

**License-agnostic scoring model:** Secure Score always shows the **full set of possible recommendations for a product**, regardless of which specific license SKU/edition/plan the tenant owns. This is deliberate — Microsoft wants the security-best-practices catalog visible even to tenants who would need to buy something to act on it. The practical consequence: `maxScore` for a given product is identical across tenants with different license tiers; what varies is whether the tenant can actually *act* on a given recommendation (gated by license) and whether the underlying product is present at all (`enabledServices`). The portal's "Current license score" view specifically filters to what's achievable *without* a new purchase — use that view, not the raw achievable-max, when scoping a no-additional-spend improvement plan for a client.

**Security defaults interaction:** turning on [Microsoft Entra security defaults](https://learn.microsoft.com/en-us/entra/fundamentals/security-defaults) automatically awards full points for three specific recommended actions — "Ensure all users can complete MFA" (9 pts), "Require MFA for administrative roles" (10 pts), and "Enable policy to block legacy authentication" (7 pts) — 26 points with zero additional Conditional Access policy authoring. Building CA-based sign-in-risk or user-risk policies **on top of** security defaults for the same coverage doesn't add points and creates policy sprawl; the correct move (per Microsoft's own guidance) is to mark those specific CA-adjacent recommendations **Resolved through alternative mitigation** instead of duplicating the control. See `Security/ConditionalAccess/CA-Design-A.md` for the broader CA design implications of running security defaults alongside custom CA policies (generally not recommended together — pick one model).

</details>

---

## Dependency Stack

```
Layer 5: Presentation & RBAC
              │  Portal (security.microsoft.com/securescore): Overview /
              │  Recommended actions / History / Metrics & trends tabs
              │  Gated by Defender XDR Unified RBAC "Exposure Management"
              │  (read/manage, under Security posture category) OR legacy
              │  Entra global roles. Graph API access specifically is
              │  STILL legacy-role-only — Unified RBAC coverage for the
              │  API is not yet shipped as of this writing.
Layer 4: Aggregation & Benchmarking
              │  secureScore object: currentScore, maxScore, enabledServices,
              │  averageComparativeScores (AllTenants / TotalSeats /
              │  IndustryTypes bases — anonymized, can't identify peer
              │  tenants), history retained for trend/regression graphs
Layer 3: Control Evaluation Engine
              │  secureScoreControlProfiles definitions × live tenant config
              │  = controlScores. Refresh cadence: real-time view, daily
              │  sync (most), weekly/monthly (Teams & Entra specifically)
Layer 2: Workload Configuration State
              │  The actual settings being measured: Entra CA policies,
              │  MFA registration, Exchange transport/anti-phish config,
              │  SharePoint/OneDrive sharing settings, Teams meeting
              │  policies, MDE ASR/exploit protection, MDI sensor config,
              │  MDCA app policies, Purview sensitivity labels/DLP,
              │  App Governance OAuth app risk, connected non-Microsoft
              │  apps (Okta/Salesforce/ServiceNow/GitHub/Docusign/Zoom/
              │  Citrix ShareFile)
Layer 1: Licensing & Provisioning Gate
              │  A workload must be BOTH licensed AND provisioned/enabled
              │  to appear in EnabledServices. Missing here = the entire
              │  category of recommendations for that product is absent
              │  from the score, not just zero-scored. Confirmed via
              │  Get-MgSubscribedSku + the product's own onboarding state.
```

**The single most common architectural misunderstanding:** engineers instinctively look for a missing/wrong *configuration* when a recommendation is absent from the score. Just as often the real cause is Layer 1 — the product isn't in `EnabledServices` at all, so there's no control to evaluate in the first place. Always check `EnabledServices` before troubleshooting a "missing recommendation" as a config problem.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Score dropped overnight with no known change | Genuine regression — CA policy disabled, license removed shrinking a percentage-based control's denominator, TVM exception granted | Diff last 2 `Get-MgSecuritySecureScore` snapshots + portal History tab |
| Expected product/recommendations entirely absent | Product not in `EnabledServices` — unlicensed, unprovisioned, or still within the 24–48h propagation window | `$score.EnabledServices` + `Get-MgSubscribedSku` |
| Fixed a setting, score unchanged after a few minutes | Normal — 24–48h refresh delay for most controls | Re-check after 48h, not before |
| Fixed a Teams or Entra recommendation, score still stale after 48h | Teams/Entra refresh weekly/monthly, not daily — documented exception | Wait out the correct cadence; don't escalate prematurely |
| Rolled a policy out to half the org, expected full points | Percentage-based scoring, not binary — partial credit only | Confirm the control is population-based via `secureScoreControlProfiles` remediation text |
| Third-party MFA/DLP tool addresses a control, score never moves | Microsoft has zero visibility into non-Microsoft tools by default | Manually set status "Resolved through third party" |
| "Device" category recommendation stuck "To address" despite a fix | Device category is a read-through of TVM, not independently editable; the exception may be per-device-group (doesn't count) not Global (does) | Fix in Defender Vulnerability Management, confirm exception scope |
| A user reports blank/no-access on the Secure Score page | Missing Unified RBAC "Exposure Management" role or legacy Entra global role | Check Defender portal Roles + Entra role assignments |
| A Graph-based script 403s but the portal works fine for the same person | Graph API access to Secure Score is legacy-role-gated only; Unified RBAC custom roles aren't yet honored by the API | Assign a legacy Entra role (e.g. Security Reader) alongside the custom RBAC role |
| Comparison chart numbers look implausible vs. known competitors | Peer set is anonymized and statistically modeled (by seat count / industry), not a literal named-peer comparison | Treat as directional, not exact — don't over-promise precision to clients |
| New tenant shows a very low or 0 score immediately after setup | Expected — nothing has been configured yet, this is the pre-baseline state | Confirm via `CreatedDateTime`/`LicensedUserCount` that the tenant is genuinely new, then build a ramp plan (Playbook 4) |
| Score for a specific control regressed but nobody changed that product's settings | A percentage-based control's *denominator* changed (bulk license removal, offboarded users) even though the numerator (policy) is untouched | Compare `ActiveUserCount`/`LicensedUserCount` across the same date range as the regression |
| Client asks why their score differs from a vendor's marketing claim of "industry average" | Vendor is citing a different, non-Microsoft benchmark; Microsoft's own comparison is anonymized peer data inside the tenant's own portal only | Point to Metrics & trends > Comparison trend as the only Microsoft-sourced benchmark |

---

## Validation Steps

**1. Confirm Graph connectivity and permission scope**
```powershell
Connect-MgGraph -Scopes "SecurityEvents.Read.All"
(Get-MgContext).Scopes
```
Expected (good): `SecurityEvents.Read.All` present. Bad: missing scope — re-consent, or the signed-in account/app lacks a qualifying legacy Entra role (Unified RBAC alone won't satisfy Graph calls yet).

**2. Pull the latest score snapshot**
```powershell
$score = Get-MgSecuritySecureScore -Top 1
$score | Format-List CreatedDateTime, CurrentScore, MaxScore, LicensedUserCount, ActiveUserCount
```
Expected (good): `CreatedDateTime` within the last ~24h. Bad: a stale date well beyond 24h suggests the daily sync itself is broken tenant-side — rare, escalate to Microsoft if confirmed.

**3. Confirm EnabledServices matches known licensed workloads**
```powershell
$score.EnabledServices
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits
```
Expected (good): every actively-licensed, provisioned workload appears. Bad: a known-licensed workload absent — check provisioning state in that product's own portal before assuming a Secure Score bug.

**4. Pull full control profile catalog and cross-reference current scores**
```powershell
$controls = Get-MgSecuritySecureScoreControlProfile -All
$joined = foreach ($c in $score.ControlScores) {
    $profile = $controls | Where-Object Id -eq $c.ControlName
    [pscustomobject]@{
        Control = $c.ControlName; Category = $c.ControlCategory
        Current = $c.Score; Max = $profile.MaxScore
        Rank = $profile.Rank; Cost = $profile.ImplementationCost
        UserImpact = $profile.UserImpact
    }
}
$joined | Sort-Object Rank
```
Expected (good): a full joined table. Bad: nulls in `Max`/`Rank` for a given control name — a naming mismatch between the two endpoints, worth flagging to Microsoft as a data-quality issue rather than assuming your own script is broken.

**5. Check for controls with a manual status override**
```powershell
$controls | Where-Object { $_.ControlStateUpdates.State -ne "Default" } |
    Select-Object Title, @{N="State";E={$_.ControlStateUpdates[-1].State}},
        @{N="UpdatedBy";E={$_.ControlStateUpdates[-1].UpdatedBy}},
        @{N="UpdatedDateTime";E={$_.ControlStateUpdates[-1].UpdatedDateTime}}
```
Expected: a short, deliberate list — every override should be traceable to a documented compensating control. Bad: overrides nobody can explain, or overrides for tools that are no longer in use (stale credit).

**6. Confirm RBAC alignment for the requesting engineer**
Portal: Defender portal > Permissions & roles > Roles → search for "Exposure Management" under Security posture. Entra: check for Security Administrator (or higher), Exchange Administrator, or SharePoint Administrator for write access; Security Reader/Global Reader/etc. for read-only.

**7. Cross-check the portal's own comparison view against the Graph data**
```powershell
$score.AverageComparativeScores | Select-Object Basis, AverageScore
```
Expected: three bases — `AllTenants`, `TotalSeats`, `IndustryTypes` — each with a plausible average given `CurrentScore`/`MaxScore`. Bad: wildly implausible averages — a portal rendering issue rather than a data problem, since the Graph API is the same source of truth as the UI.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm scope
Rule out the wrong-product confusion first (Defender for Cloud CSPM vs. TVM device score vs. this tenant-wide score). This single step resolves a large share of "the numbers don't match what I expected" tickets before any real troubleshooting starts.

### Phase 2 — Snapshot and history pull
Get current score, `EnabledServices`, and at least a 30-day history via repeated `-Top N` pulls or the portal History tab. Establish whether this is a point-in-time confusion (delay/percentage scoring) or a genuine regression.

### Phase 3 — Control-level drill-down
For a specific stuck/missing/regressed recommendation, join `secureScoreControlProfiles` against `controlScores` to get category, rank, cost, and user impact — then follow the control's `ActionUrl` into the owning product to verify live configuration state directly (don't trust the score alone as ground truth for the underlying setting).

### Phase 4 — Manual status reconciliation
Check `ControlStateUpdates` for any non-default state. Confirm every override still has a valid, currently-in-place compensating control behind it. Stale overrides are a common audit finding — a client's score can look better than their actual posture if a third-party tool was decommissioned without reverting the status.

### Phase 5 — RBAC and automation access
If the reporting user or an automation script can't retrieve expected data, separate "portal access" (Unified RBAC or legacy Entra role) from "Graph API access" (legacy Entra role only, currently) — they are not the same gate and a fix to one does not fix the other.

### Phase 6 — MSP fleet-scale review
For quarterly/recurring client reviews across multiple managed tenants, loop the evidence-pack pattern (see Evidence Pack below) per tenant and roll up into a comparison view — flag tenants below an agreed baseline percentage, flag stale manual overrides, and flag `EnabledServices` gaps against the client's known license entitlement.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Investigate and close out a score regression end-to-end</summary>

**Scenario:** Client asks "why did our score drop 15 points last week" ahead of a QBR.

1. Pull a 30+ day history via repeated `Get-MgSecuritySecureScore -Top N` (or the portal History tab, which breaks out per-action detail more cleanly).
2. Identify the exact date of the drop and which category (Identity/Device/Apps/Data) absorbed it.
3. Cross-reference that date against: CA policy change history (`Security/ConditionalAccess/`), bulk license removal/offboarding events, TVM exceptions granted (`DevenderVulnMgmt-B.md`), and any manual Secure Score status reverts.
4. Once the root cause config change is identified, decide with the client: was it intentional (accept the score impact, document why) or accidental (revert it)?
5. If reverted, allow the normal 24–48h (or weekly/monthly for Teams/Entra) refresh window before re-measuring — don't re-open the ticket prematurely.

**Rollback:** N/A — this is an investigation/config-correction playbook, not a destructive change.
</details>

<details>
<summary>Playbook 2 — Reconcile manual status overrides across a tenant (pre-audit or pre-QBR hygiene pass)</summary>

**Scenario:** A client's Secure Score looks unusually high relative to their known control maturity — suspected stale "Resolved through third party" overrides.

1. Pull every control with a non-default `ControlStateUpdates` state (Validation Step 5).
2. For each, confirm with the client whether the cited third-party tool or alternate mitigation is still actually in place and actively enforced — not just historically true.
3. For any override that no longer has a valid backing control, revert the status to "To address" via the portal (no Graph write cmdlet is documented for this in the stable API; the portal action is the supported path) and document the reversal with a timestamp and reason.
4. Re-pull the score after the normal refresh window to confirm the corrected (lower, more honest) number.
5. Present the corrected score alongside a remediation plan for the newly-reopened items — this is a more defensible position for an audit or security review than an inflated number built on stale overrides.

**Rollback:** N/A — this playbook only removes inaccurate credit, no destructive technical change.
</details>

<details>
<summary>Playbook 3 — MSP quarterly fleet-wide posture review across managed tenants</summary>

**Scenario:** Recurring quarterly review across every managed client tenant, mirroring the same MSP fleet-review pattern used for Defender for Cloud (`DefenderForCloud-A.md` Playbook 4).

1. Loop the evidence-pack script (below) across each tenant context the MSP has delegated/GDAP access to.
2. For each tenant, capture: current score %, `EnabledServices` vs. known license entitlement (flagging gaps), count of non-default manual overrides, and the 90-day regression trend.
3. Flag tenants below an internally agreed baseline percentage for prioritized follow-up.
4. Flag any tenant with `EnabledServices` missing a product the client is confirmed to be paying for — this is either a provisioning gap (actionable) or a stale license record (billing conversation).
5. Roll the per-tenant results into a single comparison view for the account team ahead of QBRs — score %, high-severity open recommendations, and override count are usually the three numbers stakeholders actually want.

**Rollback:** N/A — read-only reporting playbook.
</details>

<details>
<summary>Playbook 4 — New tenant baseline ramp plan</summary>

**Scenario:** A newly onboarded client tenant shows a very low or near-zero Secure Score, causing alarm during the first review.

1. Confirm via `CreatedDateTime`, `LicensedUserCount`, and product onboarding state that this is genuinely a fresh tenant with minimal configuration yet, not a data problem.
2. Pull the full `secureScoreControlProfiles` catalog and sort by `Rank` (Microsoft's own priority ordering, weighing points remaining against implementation cost/user impact/complexity) to build a prioritized 30/60/90-day improvement plan rather than attempting everything at once.
3. Sequence low-`ImplementationCost`/low-`UserImpact` high-`MaxScore` controls first — these are the fastest, least-disruptive wins and demonstrate visible progress in the first review cycle.
4. Explicitly set client expectations that Teams/Entra recommendation updates lag on a weekly/monthly cadence — a ramp plan that assumes daily visibility into those categories will look "stuck" even when work is progressing.
5. Re-baseline and present progress at the next scheduled review using the History tab's activity log as the evidence trail.

**Rollback:** N/A — planning playbook, no technical change.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects a full Secure Score evidence pack for escalation or a client review.
#>
[CmdletBinding()]
param([string]$OutputPath = "C:\Temp\SecureScore-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')")

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$score = Get-MgSecuritySecureScore -Top 1
$history = Get-MgSecuritySecureScore -Top 30 | Sort-Object CreatedDateTime
$controls = Get-MgSecuritySecureScoreControlProfile -All

$score | ConvertTo-Json -Depth 6 | Out-File "$OutputPath\current_snapshot.json"
$history | Select-Object CreatedDateTime, CurrentScore, MaxScore |
    Export-Csv "$OutputPath\score_history_30.csv" -NoTypeInformation

$joined = foreach ($c in $score.ControlScores) {
    $p = $controls | Where-Object Id -eq $c.ControlName
    [pscustomobject]@{
        Control = $c.ControlName; Category = $c.ControlCategory; Current = $c.Score
        Max = $p.MaxScore; Rank = $p.Rank; Cost = $p.ImplementationCost
        UserImpact = $p.UserImpact; Tier = $p.Tier; ActionUrl = $p.ActionUrl
        LastState = $p.ControlStateUpdates[-1].State
    }
}
$joined | Sort-Object Rank | Export-Csv "$OutputPath\control_breakdown.csv" -NoTypeInformation

$controls | Where-Object { $_.ControlStateUpdates[-1].State -notin @("Default", $null) } |
    Select-Object Title, ControlCategory, @{N="State";E={$_.ControlStateUpdates[-1].State}},
        @{N="UpdatedBy";E={$_.ControlStateUpdates[-1].UpdatedBy}},
        @{N="UpdatedDateTime";E={$_.ControlStateUpdates[-1].UpdatedDateTime}} |
    Export-Csv "$OutputPath\manual_overrides.csv" -NoTypeInformation

Write-Host "Evidence pack written to $OutputPath" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Connect with correct scope | `Connect-MgGraph -Scopes "SecurityEvents.Read.All"` |
| Latest score snapshot | `Get-MgSecuritySecureScore -Top 1` |
| Score history (N snapshots) | `Get-MgSecuritySecureScore -Top 30` |
| Full control catalog | `Get-MgSecuritySecureScoreControlProfile -All` |
| One control's profile | `Get-MgSecuritySecureScoreControlProfile -SecureScoreControlProfileId "<Id>"` |
| EnabledServices for the tenant | `(Get-MgSecuritySecureScore -Top 1).EnabledServices` |
| Per-category rollup | `$score.ControlScores \| Group-Object ControlCategory` |
| Comparison benchmarks | `(Get-MgSecuritySecureScore -Top 1).AverageComparativeScores` |
| Licensed SKUs (EnabledServices cross-check) | `Get-MgSubscribedSku` |
| Manual status overrides | `$controls \| Where-Object { $_.ControlStateUpdates.State -ne "Default" }` |
| Portal — overview/recommendations | `https://security.microsoft.com/securescore` |
| Portal — Unified RBAC roles | Defender portal > Permissions & roles > Roles |
| Confirm current Graph scopes | `(Get-MgContext).Scopes` |
| Check a device-category exception scope | Defender portal > Vulnerability management > Recommendations > select item > Exception history |
| Full evidence pack | See Evidence Pack script above |

---

## 🎓 Learning Pointers

- **The scoring model is weighted, not a simple pass/fail average.** A single unresolved high-weight control can move the score more than ten resolved low-weight controls — don't assume "most recommendations are done" translates linearly to "score should be near-max." [MS Docs: Microsoft Secure Score](https://learn.microsoft.com/en-us/defender-xdr/microsoft-secure-score)
- **`EnabledServices` is the single highest-leverage first check** for any "missing recommendation" ticket — it silently gates entire categories of controls out of the score with no error message anywhere in the portal.
- **Graph API RBAC lags the portal's own Unified RBAC model.** As of this writing, Graph calls against Secure Score still require a legacy Entra global role even for a user/app that already has full portal access via a Unified RBAC custom role — worth re-checking Microsoft's own documentation periodically, since this is explicitly called out as a temporary gap Microsoft intends to close. [MS Docs: Secure Score permissions](https://learn.microsoft.com/en-us/defender-xdr/microsoft-secure-score#secure-score-permissions)
- **Device-category exception scope matters for score accuracy, not just for TVM.** A per-device-group exception genuinely protects those devices but will never move the tenant-wide Secure Score number — only a Global exception does. This is worth explaining proactively to clients who scope exceptions narrowly for good security reasons and then ask why the score didn't move.
- **Comparison benchmarks are anonymized and statistically modeled**, not a literal peer-tenant lookup — treat "vs. similar organizations" numbers as directional guidance for a client conversation, not as a precise competitive claim. [MS Docs: Track your Secure Score history](https://learn.microsoft.com/en-us/defender-xdr/microsoft-secure-score-history-metrics-trends)
- **Manual overrides ("resolved through third party"/"alternate mitigation") don't self-heal when the underlying tool goes away.** Build a Secure Score status review into any MSP offboarding/decommission checklist for security tooling — this is a realistic, low-effort way to prevent posture drift from hiding behind an inflated score.
