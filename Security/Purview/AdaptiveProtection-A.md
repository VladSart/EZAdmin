# Adaptive Protection (Purview + Entra Insider Risk) — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Purview Adaptive Protection: the ML-driven bridge that converts Insider Risk Management (IRM) risk signal into automatic enforcement across three downstream systems — Data Loss Prevention (DLP), Data Lifecycle Management (DLM), and Microsoft Entra Conditional Access (CA).
- Insider risk *level* assignment logic (Elevated / Moderate / Minor), Quick Setup vs. Custom Setup, the four-way permission model, and the on/off/disable lifecycle.
- Cross-references to `Insider-Risk-A.md`/`-B.md` for the upstream IRM signal-generation layer (out of scope here — see that pair for policy tuning, HRMS connector, and audit log prerequisites).

**Out of scope (covered elsewhere):**
- Microsoft Entra ID Protection user/sign-in risk (`Get-MgRiskyUser`, `userRiskLevels`/`signInRiskLevels` CA conditions) — a **separate, unrelated risk engine**; see `EntraID/Troubleshooting/IdentityProtection-A.md`. Do not conflate the two "risk level" vocabularies.
- General Insider Risk Management policy design, HRMS connector, and audit log health — see `Insider-Risk-A.md`.
- General DLP policy design and locations beyond the Adaptive Protection condition — see the DLP topic files in this folder.
- General Conditional Access design, filters, and troubleshooting — see `Security/ConditionalAccess/CA-Design-A.md` and `CA-Troubleshooting-A.md`.
- Purview Communication Compliance — unrelated Purview module, no PowerShell surface, see `CommunicationCompliance-A.md`.

**Assumed baseline:**
- Microsoft 365 E5 or E5 Compliance add-on (IRM/DLP/DLM)
- Microsoft Entra ID P2 (Conditional Access "Insider risk" condition — currently a **preview** feature)
- Insider Risk Management Admin/Analyst role assigned, at least one active IRM policy generating alerts
- Unified Audit Log enabled tenant-wide (hard prerequisite for IRM, therefore for Adaptive Protection)
- Tenant hosted in a commercial cloud region — **not available in US Government cloud** at time of writing; verify via [Azure dependency availability by country/region](https://learn.microsoft.com/en-us/troubleshoot/azure/general/dependency-availability-by-country)

---

## How It Works

<details><summary>Full architecture</summary>

### The core idea

Adaptive Protection does not generate risk signal itself — it **consumes** signal already produced by an Insider Risk Management policy (alerts and their severity, or raw activity insights) and translates that signal into a per-user **insider risk level** (Elevated / Moderate / Minor). That level is then exposed as a condition three downstream systems can react to. Nothing about DLP, DLM, or CA changes unless a policy in one of those systems is explicitly configured to look for the Adaptive Protection insider-risk-level condition.

```
                     ┌─────────────────────────────────────┐
                     │   Insider Risk Management (IRM)      │
                     │   policy(ies) — alerts + activity     │
                     │   insights, Low/Medium/High severity  │
                     └───────────────┬───────────────────────┘
                                     │ (feeds)
                                     ▼
                     ┌─────────────────────────────────────┐
                     │        Adaptive Protection            │
                     │  ML-scored insider risk LEVEL         │
                     │  per user: Elevated / Moderate / Minor│
                     │  (distinct scale from alert severity) │
                     └───┬───────────────┬───────────────┬───┘
                         │               │               │
                         ▼               ▼               ▼
              ┌───────────────┐ ┌───────────────┐ ┌───────────────────┐
              │  DLP policies  │ │  Conditional   │ │  Data Lifecycle    │
              │  (Exchange,    │ │  Access        │ │  Management        │
              │  Teams,        │ │  (Entra ID P2, │ │  (auto-created     │
              │  Devices only) │ │  preview)      │ │  120-day preserve  │
              │  condition:    │ │  condition:    │ │  for Elevated-level│
              │  "Insider risk │ │  "Insider risk"│ │  deletes in SPO /  │
              │  level for AP  │ │  = Elevated/   │ │  OneDrive/Exchange)│
              │  is"           │ │  Moderate/Minor│ │                    │
              └───────────────┘ └───────────────┘ └───────────────────┘
```

### Insider risk levels vs. alert severity — the single most important distinction

Microsoft's own documentation flags this explicitly because it is the most common source of misdiagnosis:

- **Insider risk levels** (Elevated, Moderate, Minor) — the Adaptive Protection construct. Assigned per admin-defined **conditions**: either (a) alert generated/confirmed at a chosen severity, or (b) a specific activity type occurring N times at a chosen severity within a configurable lookback window ("Past activity detection", default 7 days, range 5–30).
- **Alert severity levels** (Low, Medium, High) — the underlying IRM construct, calculated from risk scores on active alerts. Used by analysts/investigators to prioritize triage in the IRM alert queue.

A single High-severity alert does **not** automatically produce an Elevated insider risk level. Whether it does depends entirely on which of the two criteria types (alert-based vs. activity-based) the specific insider risk level definition uses, and — for activity-based definitions — whether the occurrence-count threshold within the detection window has actually been met. Conditions for activity-based levels are **additive** (all must be met); conditions for alert-based levels are **not additive** (any one match is sufficient).

### Built-in level definitions (Quick Setup defaults — customizable)

| Level | Built-in criteria |
|---|---|
| Elevated | Users with high-severity alerts, OR at least 3 sequence insights each with a high-severity alert for specific risk activities, OR one or more confirmed high-severity alerts |
| Moderate | Users with medium-severity alerts, OR at least 2 data-exfiltration activities with high-severity scores |
| Minor | Users with low-severity alerts, OR at least 1 data-exfiltration activity with a high-severity score |

### Multi-policy resolution

If a user is in scope for multiple IRM policies feeding Adaptive Protection and receives alerts of different severities across them, the user is assigned the **highest** severity's corresponding level — not an average, not the most recent.

### Level lifecycle: assignment, timeframe, and reset

- **Insider risk level timeframe** (default 7 days, range 5–30): how long a level stays assigned before automatic reset.
- If the user meets the same level's criteria again while already assigned, the timeframe **extends** by the full configured duration (does not stack additively beyond that).
- **Risk level expiration options** (enabled by default): the level also resets early if the associated alert is dismissed or the associated case is closed. This can be disabled if you want the level to persist through dismissal/closure regardless.
- Manual reset via **Expire** on the Users assigned insider risk levels tab — removes the current level immediately; existing alerts/cases are untouched; a new level can be assigned again on the next qualifying trigger.

### Quick Setup vs. Custom Setup

**Quick Setup** requires zero pre-existing configuration. It provisions, in one action:
1. A new IRM policy (Data leaks template, all users/groups scope, a subset of Office indicators, "activity over baseline" risk booster)
2. The three built-in insider risk level definitions (table above)
3. A CA policy named **"1-Block access for users with Insider Risk (Preview)"**, scoped to all users, Office 365 apps, Insider risk = Elevated, Block access, created in **Report-only** mode
4. An auto-created DLM policy for 120-day preservation of Elevated-level users' deletes (auto-applied only if AP was not previously configured; otherwise requires explicit opt-in)
5. Two DLP policies, each with a Block rule (Elevated) and an Audit rule (Moderate+Minor), both starting in **simulation mode**:
   - "Adaptive Protection policy for Teams and Exchange DLP"
   - "Adaptive Protection policy for Endpoint DLP"

Quick Setup completion takes up to **72 hours**. Once turned on, expect up to **36 hours** before levels and downstream actions actually apply to user activity. **Do not disable Adaptive Protection while Quick Setup is still completing** — Microsoft documents this can lead to policy errors.

**Custom Setup** is the same five building blocks, but each is created or mapped to pre-existing policies manually, in five explicit steps (IRM policy → level criteria → DLP policy → CA policy → turn on). Use this path for any tenant that already has IRM, DLP, or CA policies in production — Quick Setup's "all users" defaults are usually wrong for an established environment.

Note: scoped Purview administrative-unit admins **cannot** use Quick Setup at all — Custom Setup or a non-scoped admin is required for initial configuration.

### Disable lifecycle

Turning Adaptive Protection off: stops new level assignments, stops sharing levels with DLP/DLM/CA, and **resets all existing user levels** — this can take up to 6 hours to fully propagate. The underlying IRM, DLP, and CA policies are **not automatically deleted** and will continue to exist (referencing a condition that will simply never match again) unless manually cleaned up. The DLM arm is the one exception: its own sub-toggle ("Adaptive protection in Data Lifecycle Management") being turned off **deletes** the auto-created DLM policy outright, and it will not silently re-create itself if re-enabled later — a fresh policy is created with no continuity.

</details>

---

## Dependency Stack

```
Microsoft 365 Audit Log (UAL) — tenant-wide, hard prerequisite for IRM
    │
    ▼
Insider Risk Management (IRM) — E5/E5 Compliance, ≥1 active policy generating
alerts/insights for users in scope
    │
    ▼
Adaptive Protection — master toggle ON (up to 36h propagation)
    │
    ├── Insider risk level definitions (Elevated/Moderate/Minor)
    │       ├── Alert-based criteria (non-additive — any match) OR
    │       └── Activity-based criteria (additive — all must match, within
    │           configurable 5–30 day Past activity detection window)
    │
    ├── Level assignment to individual users
    │       └── Insider risk level timeframe (5–30 days) governs auto-reset;
    │           dismiss/close-triggered early reset unless disabled
    │
    ├── DLP arm
    │       ├── Requires: Compliance Admin / Compliance Data Admin /
    │       │   DLP Compliance Management / Global Admin to configure
    │       ├── Requires: DLP policy scoped to Exchange, Teams, and/or
    │       │   Devices ONLY (no SharePoint/OneDrive as direct AP-DLP location)
    │       ├── Endpoint (Devices) additionally requires: Advanced
    │       │   classification scanning and protection ON, or manual
    │       │   "File Type is" condition
    │       └── Policy Status must be On (not simulation mode) to enforce
    │
    ├── Conditional Access arm  (requires Entra ID P2)
    │       ├── Requires: Global Admin / CA Admin / Security Admin to configure
    │       ├── Graph condition: conditions.insiderRiskLevels
    │       │   (DISTINCT from conditions.userRiskLevels/signInRiskLevels —
    │       │    those belong to unrelated Entra ID Protection)
    │       └── Policy State must be "enabled" (not report-only) to enforce
    │
    └── Data Lifecycle Management arm
            ├── Requires: explicit opt-in via "Adaptive protection in Data
            │   Lifecycle Management" setting if AP predates DLM being noticed
            ├── Scope: SharePoint, OneDrive, Exchange Online deletes only,
            │   Elevated-level users only
            └── Effect: 120-day preservation (recoverable via Microsoft
                support), NOT a legal hold, NOT retroactive to pre-toggle deletes
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Elevated user still has full app access | CA policy in Report-only (Quick Setup default) | `Get-MgIdentityConditionalAccessPolicy` → `State` |
| Elevated user still able to share sensitive content externally | DLP policy in simulation mode (Quick Setup default) | Purview → DLP → Policies → Status column |
| No users ever show an insider risk level | Underlying IRM policy generates no alerts, or AP master toggle off | See `Insider-Risk-B.md` Triage first |
| User has High-severity alert but no Elevated level | Level defined on activity-count criteria, threshold not yet met (not the same as alert severity) | Adaptive protection → Insider risk levels → Edit → review criteria type |
| Level assigned but resets almost immediately | Associated alert dismissed / case closed, and "Risk level expiration options" enabled (default) | Check alert/case status for the user |
| DLP action not applying to SharePoint/OneDrive sharing | AP-DLP condition does not support SPO/OneDrive as a location — expected limitation, not a bug | Confirm client's actual expectation; point to DLM arm for delete-preservation instead |
| Endpoint DLP AP policy fires on nothing | Missing Advanced classification scanning and protection, or missing File Type is condition on hand-built policy | Purview → Endpoint DLP settings |
| Independent Device DLP policy seems to be "losing" to AP's policy | Working as designed — most restrictive combined outcome wins for DLP | Compare both policies' action severity |
| Deleted files not preserved for a known Elevated user | DLM sub-toggle never explicitly opted in, OR deletion occurred before toggle was turned on | Purview → Data lifecycle management → Adaptive protection toggle + timestamp |
| AP shows "on" but nothing has changed for 10 minutes | Still within the up-to-36-hour propagation window after initial enable | Check enable timestamp vs. current time |
| Scoped Purview admin can't find Quick setup / can't see all AP tabs | Scoped admin limitation — role-group-to-tab mapping | Confirm admin's role group membership vs. the 4-tab permission table |
| Troubleshooting references `Get-MgRiskyUser` / `RiskLevelAggregated` and finds nothing relevant | Wrong system — that's Entra ID Protection, not Adaptive Protection | Redirect to `conditions.insiderRiskLevels` / Purview Adaptive protection dashboard |
| CA + DLP + DLM all configured correctly per this doc but AP was recently disabled tenant-wide | Master toggle off resets all user levels within up to 6h; underlying policies still exist but never match | Purview → Adaptive protection settings → confirm On/Off + last-changed |
| AP disabled months ago but orphaned CA/DLP policies referencing insider risk levels still exist | Disabling AP does not delete downstream policies (only the DLM policy is auto-deleted) | Audit CA/DLP policies for the insider-risk condition even when AP shows Off |

---

## Validation Steps

**1. Confirm licensing (Entra ID P2 + E5/E5 Compliance)**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits |
    Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2|SPE_E5|M365_E5|ENTERPRISEPREMIUM" }
```
Expected: an AAD_PREMIUM_P2 line with available seats (for CA arm) and an E5/E5 Compliance line (for IRM/DLP/DLM). Absence of P2 does not block IRM/DLP/DLM — only the CA arm.

**2. Confirm the Adaptive Protection master toggle and its last-changed state**
Purview portal → Insider Risk Management → Adaptive protection → Adaptive Protection settings tab.
Expected: On. If recently toggled, note the timestamp — allow up to 36h before escalating "nothing is happening."

**3. Confirm insider risk level definitions match intended enforcement design**
Purview portal → Adaptive protection → Insider risk levels → review each of Elevated/Moderate/Minor.
Expected: criteria type (alert-based vs. activity-based) and thresholds documented and agreed with the compliance owner — this is a policy decision, not a technical default to leave unreviewed.

**4. Confirm downstream policy states (the three arms) are what the ticket assumes**
```powershell
# Conditional Access arm
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.Conditions.InsiderRiskLevels -or $_.DisplayName -like "*Insider*" } |
    Select-Object DisplayName, State
```
```
# DLP arm — portal check (no dedicated read cmdlet surfaces the AP condition cleanly)
Purview portal → Data Loss Prevention → Policies → filter for "Insider risk level for
Adaptive Protection is" condition → note Policy status per policy
```
```
# DLM arm — portal check
Purview portal → Data lifecycle management → Adaptive protection in Data Lifecycle
Management → On/Off
```
Expected: each arm's state matches what the requester believes is configured. Mismatches here explain the overwhelming majority of "Adaptive Protection isn't working" tickets.

**5. Confirm the specific user's assigned level and its source policy**
Purview portal → Adaptive protection → Users assigned insider risk levels → search user → open detail pane → **Adaptive protection summary** tab.
Expected: current risk level, assignment date, reset date, and the specific IRM policy responsible are all visible in one place. This tab also lists exactly which DLP and CA policies are currently in scope for that user based on their level — the fastest way to confirm end-to-end wiring for one person.

**6. Confirm no independent/conflicting policy is carving the user out**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgIdentityConditionalAccessPolicy | Select-Object DisplayName, State,
    @{N="ExcludedUsers";E={$_.Conditions.Users.ExcludeUsers -join ","}},
    @{N="ExcludedGroups";E={$_.Conditions.Users.ExcludeGroups -join ","}}
```
Expected: the affected user/their groups are not present in any other enabled policy's exclusion list that would otherwise be expected to cover them.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm signal is reaching Adaptive Protection at all

**Step 1** — Verify IRM is generating alerts for the user (see `Insider-Risk-A.md` Validation Steps 1–5 in full; do not duplicate that work here).

**Step 2** — Verify the Adaptive Protection master toggle is On and check the enable timestamp against the 36-hour propagation window.

**Step 3** — Verify the user appears on the **Users assigned insider risk levels** tab with a non-empty level. If absent despite confirmed IRM alerts, re-check the level definition criteria (Step 4 below) before assuming a platform fault.

### Phase 2 — Level assignment mismatches expectation

**Step 4** — Open the specific insider risk level's edit pane and determine whether it's alert-based (non-additive) or activity-based (additive, with an occurrence-count + detection-window requirement). Cross-reference against the user's actual alert/activity history in IRM to confirm whether the criteria were genuinely met.

**Step 5** — If multiple IRM policies are in scope for the user, confirm which policy produced the highest-severity result — that is the one driving the assigned level, per the multi-policy "highest wins" rule.

### Phase 3 — Level assigned but downstream enforcement absent

**Step 6** — Check the CA policy state (`enabled` vs. `enabledForReportingButNotEnforced`) via Graph. Report-only is the single most common root cause industry-wide for this class of ticket.

**Step 7** — Check the DLP policy Status column in the portal for simulation vs. production mode.

**Step 8** — For Endpoint DLP specifically, confirm Advanced classification scanning and protection is enabled, or that a File Type is condition exists on a hand-built policy.

**Step 9** — For DLM, confirm the sub-toggle opt-in state and cross-check the deletion timestamp against the toggle's enable timestamp (no retroactive coverage).

### Phase 4 — Enforcement present but "wrong" outcome

**Step 10** — For DLP: pull every policy (not just the AP one) scoped to the user/location and compare action severity — the most restrictive combined outcome wins, which can look like the AP policy being "ignored" when it's actually being correctly superseded by a stricter independent policy.

**Step 11** — For CA: list every enabled policy in scope for the user (standard CA "all matching policies apply, ANDed" behavior) and check for an unrelated Exclude condition carving the user out of the Insider Risk policy specifically.

### Phase 5 — Suspected wrong-system troubleshooting

**Step 12** — If prior troubleshooting referenced `Get-MgRiskyUser`, `RiskLevelAggregated`, or the `userRiskLevels`/`signInRiskLevels` CA conditions, stop and redirect: none of these are part of Adaptive Protection. Confirm the correct Graph property (`conditions.insiderRiskLevels`) and Purview dashboard are being used before continuing.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield Adaptive Protection rollout via Custom Setup (established tenant)</summary>

**Prerequisites:** E5/E5 Compliance, Entra ID P2, Global Admin or the four role groups below, existing or new IRM policy.

```
# Step 1 — Create or select the IRM policy (portal)
Purview → Insider Risk Management → Policies → Create policy (or select existing)
Recommended starting template for a first rollout: "Data leaks" (broadest signal coverage)

# Step 2 — Configure insider risk level criteria (portal)
Purview → Adaptive protection → Insider risk levels → Edit each of Elevated/Moderate/Minor
Decide alert-based vs. activity-based criteria WITH the compliance/legal stakeholder —
this is a risk-appetite decision, not a default to accept blindly.

# Step 3 — Create or edit the DLP policy (portal; PowerShell can list/verify afterward)
Purview → Data Loss Prevention → Policies → Create policy
Condition: "Insider risk level for Adaptive Protection is" + desired level(s)
Location: Exchange, Teams, and/or Devices only
RECOMMENDATION: leave in simulation mode for at least 5-7 business days before promoting

# Step 4 — Create or edit the CA policy (Entra admin center or Graph)
Entra admin center → Conditional Access → Policies → New policy
Condition: Insider risk = <level(s)>
Grant: Block access (Elevated) or lighter controls (Moderate/Minor)
State: Report-only initially — MANDATORY first step, do not skip

# Step 5 — Turn on Adaptive Protection
Purview → Adaptive protection → Adaptive Protection settings → On
Allow up to 36 hours before validating end-to-end.

# Step 6 — After confirming report-only/simulation results look correct, promote:
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"
$policy = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<policy name>'"
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -State "enabled"
```

**Rollback:** revert the CA policy State back to `enabledForReportingButNotEnforced`; revert the DLP policy to simulation mode. Both take effect within minutes. The IRM policy and level definitions can be disabled independently without affecting other tenant configuration.

</details>

<details><summary>Playbook 2 — Promote from Quick Setup defaults to production enforcement</summary>

```
# 1. Review report-only CA impact for at least 5-7 days
Entra admin center → Conditional Access → Insights and reporting →
  filter by "1-Block access for users with Insider Risk (Preview)"

# 2. Review DLP simulation-mode alerts for the same window
Purview → DLP → Alerts → filter by the two Adaptive Protection policies

# 3. Confirm no unexpected users would be blocked/audited before promoting
# 4. Promote CA policy
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"
$p = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '1-Block access for users with Insider Risk (Preview)'"
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -State "enabled"

# 5. Promote each DLP policy via the portal (Policy mode → production)
```

**Rollback:** identical to Playbook 1's rollback — revert state/mode on each arm independently.

</details>

<details><summary>Playbook 3 — Opt in to DLM deleted-content preservation for an already-live Adaptive Protection deployment</summary>

```
Purview → Data lifecycle management → Adaptive protection in Data Lifecycle Management → On
```
Document the exact enable timestamp — content deleted before this point is not covered and must go through standard eDiscovery/backup recovery instead. Communicate the 120-day (not permanent) preservation window and the Microsoft-support-assisted restore process to the client so expectations are set correctly.

**Rollback:** turning this Off **deletes** the auto-created DLM policy (destructive to the policy object, not to already-preserved content within its retention window). Confirm with the compliance owner before disabling; re-enabling later creates a brand-new policy with no continuity.

</details>

<details><summary>Playbook 4 — Full Adaptive Protection decommission</summary>

```
# 1. Turn off the master toggle
Purview → Adaptive protection → Adaptive Protection settings → Off
# Allow up to 6 hours for all user levels to reset and stop propagating

# 2. Clean up orphaned downstream policies (NOT automatic)
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.InsiderRiskLevels }
# Manually disable or delete each returned policy per client agreement

# Portal: Purview → DLP → Policies → find AP-condition policies → disable/delete per agreement

# 3. DLM policy is auto-deleted only if its own sub-toggle is explicitly turned off:
Purview → Data lifecycle management → Adaptive protection in Data Lifecycle Management → Off

# 4. Underlying IRM policy is untouched by any of the above — decommission separately
#    if IRM itself is also being retired (see Insider-Risk-A.md)
```

**Rollback:** none in the destructive sense — decommissioning is reversible by re-running Playbook 1, but with no continuity of prior level history, prior DLM preservation policy, or prior CA/DLP policy objects if they were deleted rather than just disabled. Recommend disable-not-delete for anything that might be revisited within the same engagement.

</details>

---

## Evidence Pack

```powershell
#Requires -Modules Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Users, ExchangeOnlineManagement

function Get-AdaptiveProtectionEvidencePack {
    param([string]$TenantName = "CUSTOMER")

    Write-Host "=== Adaptive Protection Evidence Pack — $TenantName ===" -ForegroundColor Cyan
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportPath = "C:\Temp\AdaptiveProtection-Evidence-$TenantName-$timestamp"
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

    # 1. Licensing check
    Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome
    Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits |
        Export-Csv "$reportPath\Licensing.csv" -NoTypeInformation
    Write-Host "[OK] Licensing exported"

    # 2. Conditional Access policies referencing insider risk
    Connect-MgGraph -Scopes "Policy.Read.All" -NoWelcome
    Get-MgIdentityConditionalAccessPolicy |
        Where-Object { $_.Conditions.InsiderRiskLevels -or $_.DisplayName -like "*Insider*" } |
        Select-Object DisplayName, State, CreatedDateTime, ModifiedDateTime |
        Export-Csv "$reportPath\CA-InsiderRisk-Policies.csv" -NoTypeInformation
    Write-Host "[OK] CA policies exported"

    # 3. IRM policy list (upstream signal source)
    Connect-IPPSSession -ShowBanner:$false
    Get-InsiderRiskPolicy | Select-Object Name, IsEnabled, CreatedDateTime, ModifiedDateTime |
        Export-Csv "$reportPath\IRM-Policies.csv" -NoTypeInformation
    Write-Host "[OK] IRM policies exported"

    # 4. Note: DLP policy list + status and DLM opt-in toggle have no clean read cmdlet
    #    surfacing the Adaptive Protection condition specifically — capture via portal
    #    screenshot: Purview > DLP > Policies, and Purview > Data lifecycle management >
    #    Adaptive protection in Data Lifecycle Management.
    "See portal screenshots for DLP policy status and DLM opt-in toggle state (no clean PowerShell/Graph read surface for the AP-specific condition as of this writing)." |
        Out-File "$reportPath\MANUAL-STEPS-REQUIRED.txt"
    Write-Host "[INFO] Manual portal evidence required for DLP/DLM — see MANUAL-STEPS-REQUIRED.txt" -ForegroundColor Yellow

    Write-Host "`nEvidence pack saved to: $reportPath" -ForegroundColor Green
}

Get-AdaptiveProtectionEvidencePack -TenantName "<CUSTOMER_NAME>"
```

---

## Command Cheat Sheet

```powershell
# --- Licensing ---
# Confirm P2 + E5/E5 Compliance present
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# --- Conditional Access arm ---
# List all CA policies referencing insider risk
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.InsiderRiskLevels } |
    Select-Object DisplayName, State

# Promote a report-only Insider Risk CA policy to enforced
$p = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<name>'"
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -State "enabled"

# Demote back to report-only
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -State "enabledForReportingButNotEnforced"

# --- Upstream IRM (source signal) ---
Connect-IPPSSession
Get-InsiderRiskPolicy | Select Name, IsEnabled
Get-InsiderRiskAlert -AlertStatus NeedsReview | Group-Object Severity

# --- Portal-only actions (no PowerShell/Graph cmdlet surface exists for these) ---
# - Turning the Adaptive Protection master toggle on/off
# - Editing insider risk level definitions/criteria/thresholds
# - Viewing the Users assigned insider risk levels tab / Adaptive protection summary
# - DLP policy simulation-mode vs. production-mode toggle for the AP condition
# - DLM "Adaptive protection in Data Lifecycle Management" opt-in toggle
# - Quick Setup / Custom Setup wizards themselves

# --- WRONG SYSTEM — do not use these for Adaptive Protection troubleshooting ---
# Get-MgRiskyUser                          <- Entra ID Protection, not Adaptive Protection
# ...RiskLevelAggregated on sign-in logs   <- Entra ID Protection, not Adaptive Protection
# conditions.userRiskLevels / signInRiskLevels on a CA policy <- Entra ID Protection
```

---

## 🎓 Learning Pointers

- **Adaptive Protection is a routing layer, not a detection engine.** All the actual risk detection happens in Insider Risk Management upstream; Adaptive Protection's only job is to translate that signal into a level and expose it as a condition three other systems can consume. Diagnose upstream (IRM) before downstream (AP) — a broken AP symptom is very often a broken IRM cause. [Adaptive Protection overview](https://learn.microsoft.com/en-us/purview/insider-risk-management-adaptive-protection)

- **"Insider risk level" and "alert severity" are two different vocabularies that happen to share adjective-like words.** Elevated/Moderate/Minor vs. High/Medium/Low. Do not assume a High-severity alert equals an Elevated risk level — check which criteria type (alert-based vs. activity-based, additive vs. non-additive) the specific level definition actually uses. [Insider risk levels](https://learn.microsoft.com/en-us/purview/insider-risk-management-adaptive-protection#insider-risk-levels)

- **Every arm ships safe-by-default and requires a deliberate promotion step.** CA starts Report-only, DLP starts in simulation mode. This is a feature (prevents day-one false-positive blocking) but means initial rollout success ("I turned it on") and production enforcement ("it's actually blocking people") are two separate milestones that must both be tracked. [Configure Adaptive Protection](https://learn.microsoft.com/en-us/purview/insider-risk-management-adaptive-protection#configure-adaptive-protection)

- **Adaptive Protection's Conditional Access signal and Entra ID Protection's risk signal are unrelated systems that happen to live in the same CA policy conditions list.** `insiderRiskLevels` ≠ `userRiskLevels`/`signInRiskLevels`. Different licensing story, different detection engine, different Graph properties, different portal blade. Confirm which one a ticket is actually about before spending time on it. [Insider risk as a CA condition](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-conditions#insider-risk)

- **DLM's opt-in toggle is independent of the master Adaptive Protection switch and is not retroactive.** A tenant can have AP fully live for CA and DLP while deleted-content preservation silently does nothing because this specific toggle was never flipped — and even once flipped, it will not recover anything deleted before that moment. [Retention + Adaptive Protection](https://learn.microsoft.com/en-us/purview/retention#dynamically-mitigate-the-risk-of-accidental-or-malicious-deletes)

- **Disabling Adaptive Protection leaves orphaned CA/DLP policies behind.** Only the DLM policy is auto-deleted on its own sub-toggle; everything else must be manually cleaned up or it will sit inert (and confusing to the next admin who finds it) indefinitely. Build orphan-policy checks into any tenant offboarding or Purview configuration audit. [Disable Adaptive Protection](https://learn.microsoft.com/en-us/purview/insider-risk-management-adaptive-protection#disable-adaptive-protection)
