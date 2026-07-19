# Adaptive Protection (Purview + Entra Insider Risk) — Hotfix Runbook (Mode B: Ops)
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

Before touching anything, classify the ticket into one of three buckets — Adaptive Protection has **no unified diagnostic surface**; each enforcement arm (DLP, Conditional Access, Data Lifecycle Management/DLM) is diagnosed differently.

| # | Command | Interpretation |
|---|---------|-----------------|
| 1 | `Connect-IPPSSession; Get-InsiderRiskPolicy \| Select Name, IsEnabled` | No enabled policy → Adaptive Protection has nothing to feed it. Escalate to `Security/Purview/Insider-Risk-B.md` first — do not troubleshoot AP until IRM itself is generating alerts. |
| 2 | Purview portal → **Insider Risk Management → Adaptive protection → Users assigned insider risk levels** | User missing from this list → they have never met an Elevated/Moderate/Minor level condition. Not an AP bug — check IRM alert history for that user instead. |
| 3 | `Connect-MgGraph -Scopes Policy.Read.All; Get-MgIdentityConditionalAccessPolicy \| Where DisplayName -like "*Insider*" \| Select DisplayName, State` | `state = "enabledForReportingButNotEnforced"` → this is the default from Quick Setup. It will **never block anyone** until explicitly promoted to `enabled`. The #1 "AP isn't working" ticket. |
| 4 | Purview portal → **Data Loss Prevention → Policies** → filter for the condition **"Insider risk level for Adaptive Protection is"** → check **Policy status** column | `Run the policy in simulation mode` → also the Quick Setup default. Simulation-mode DLP policies generate reports/policy tips only, never block. |
| 5 | Purview portal → **Data lifecycle management → Adaptive Protection in Data Lifecycle Management** toggle | `Off` → deleted-item preservation for Elevated users is **not** running, even if the DLP/CA arms are fully live. This toggle is independent of the master Adaptive Protection on/off switch and is easy to miss. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft 365 Audit Log (UAL) — ON, tenant-wide
        │
        ▼
Insider Risk Management policy — enabled, users in scope, generating alerts/insights
        │
        ▼
Adaptive Protection — turned ON (up to 36h propagation after toggling)
        │
        ├── Insider risk LEVEL assigned to user (Elevated / Moderate / Minor)
        │       ↳ NOT the same value as alert SEVERITY (High/Medium/Low) — different construct
        │
        ├──► DLP arm
        │       requires: DLP policy with condition "Insider risk level for
        │       Adaptive Protection is", scoped to Exchange / Teams / Devices only
        │       (SharePoint/OneDrive NOT supported as a DLP location for this condition)
        │       ↳ Endpoint (Devices) DLP additionally needs Advanced classification
        │         scanning and protection, OR a manually added "File Type is" condition
        │       ↳ policy must be OUT of simulation mode to actually enforce
        │
        ├──► Conditional Access arm  (needs Entra ID P2)
        │       requires: CA policy with condition "Insider risk" = Elevated/Moderate/Minor
        │       ↳ Graph property: conditions.insiderRiskLevels — DISTINCT from
        │         conditions.userRiskLevels / signInRiskLevels (Identity Protection —
        │         different signal, different licence, frequently confused)
        │       ↳ policy must be State = enabled, not "report-only"
        │
        └──► Data Lifecycle Management arm
                requires: "Adaptive protection in Data Lifecycle Management" setting = On
                ↳ must be explicitly opted into if AP was turned on for a tenant that
                  already had DLM/retention configured — not automatic in that case
                ↳ only protects Elevated-level users; only SPO/OneDrive/Exchange deletes;
                  120-day preservation, not a permanent hold
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the tenant has Entra ID P2 (for CA) and E5/E5 Compliance (for IRM/DLP/DLM)**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
```
Expected: an AAD_PREMIUM_P2 SKU and an E5/E5 Compliance SKU with available seats. Missing P2 → the CA arm cannot function even if AP shows "on" in Purview; missing E5 Compliance for a specific user → that user is invisible to IRM regardless of AP config.

**2. Confirm Adaptive Protection itself is on**
Purview portal → Insider Risk Management → Adaptive protection → Adaptive Protection settings tab.
Expected: toggle = **On**. If it was just turned on, allow **up to 36 hours** before expecting levels/actions to apply — this is a documented propagation window, not a fault.

**3. Confirm the user in question has an assigned insider risk level**
Purview portal → Adaptive protection → Users assigned insider risk levels → search user.
Expected: a level (Elevated/Moderate/Minor) with an "Assigned to user" date. If absent, the problem is upstream in IRM — go to `Insider-Risk-B.md`.

**4. Confirm the CA policy is enforcing, not reporting**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.DisplayName -like "*Insider*" -or $_.Conditions.InsiderRiskLevels } |
    Select-Object DisplayName, State
```
Expected: `State = "enabled"`. `enabledForReportingButNotEnforced` = report-only, will not block.

**5. Confirm the DLP policy is enforcing, not simulating**
Purview portal → Data Loss Prevention → Policies → [policy] → Status column.
Expected: **On**. `Run the policy in simulation mode` = audit-only, no user-facing block, regardless of how the rule conditions evaluate.

**6. Confirm the DLM opt-in if deleted-content preservation is the complaint**
Purview portal → Data lifecycle management → Adaptive Protection in Data Lifecycle Management.
Expected: **On**. This is a separate toggle from the master AP switch.

**7. If everything above checks out and enforcement still isn't happening, check for a "most restrictive wins" collision**
If the user is also targeted by an independent (non-AP) DLP or CA policy, only the **most restrictive** combined outcome applies for DLP; for CA, **all matching enabled policies apply** (standard CA "AND" behavior) — an independent Exclude rule on another policy can silently carve the user out. Review every CA/DLP policy the user is in scope for, not just the AP one.

---
## Common Fix Paths

<details><summary>Fix 1 — CA policy stuck in Report-only (most common ticket)</summary>

```
# Portal-only — the CA policy's report-only state is not toggleable via a single cmdlet
# flag name; do it in the Entra admin center to also capture the confirmation dialog:

Entra admin center → Protection → Conditional Access → Policies → [Insider Risk policy]
  → Enable policy → switch from "Report-only" to "On" → Save
```
Before flipping: pull report-only impact data first (Conditional Access → Insights and reporting → filter by this policy) to confirm it isn't about to block accounts you didn't intend to scope. This is a **live access-blocking change** — treat it with the same care as any other CA promotion.

**Rollback:** flip back to Report-only immediately; effect is near-instant, no propagation delay on the way back down.

</details>

<details><summary>Fix 2 — DLP policy stuck in simulation mode</summary>

```
Purview portal → Data Loss Prevention → Policies → [Adaptive Protection policy]
  → Edit policy → Policy mode → change "Run the policy in simulation mode" to
    "Run the policy in production mode. Turn on protection actions" (or equivalent
     "On" state depending on portal version) → Save
```
Recommended: review simulation-mode alerts/policy tips for at least a few days first to confirm the rule fires on the traffic you expect before promoting.

**Rollback:** revert Policy mode back to simulation; takes effect within minutes.

</details>

<details><summary>Fix 3 — Insider risk level not assigned despite confirmed IRM alerts</summary>

Check the built-in level definitions against the actual alert(s):
```
Purview portal → Adaptive protection → Insider risk levels → Edit [level] → review criteria
```
Common cause: the level is configured on **"Specific user activity"** criteria (additive — ALL conditions must match, including occurrence count within the Past activity detection window, default 7 days) rather than **"Alert generated or confirmed"** criteria (met if ANY one alert-severity condition matches). A single high-severity alert will NOT assign Elevated if the level is activity-count-based and the user hasn't crossed the occurrence threshold yet.

Fix: either lower the occurrence threshold, extend the Past activity detection window (5–30 days), or switch the level to alert-based criteria if a single confirmed high-severity alert should be sufficient for your risk appetite.

**Rollback:** revert the threshold/window/criteria change; takes effect on next evaluation cycle, no propagation delay beyond normal processing.

</details>

<details><summary>Fix 4 — Endpoint (Devices) DLP policy scoped to AP condition does nothing</summary>

```
# Verify Advanced classification scanning and protection is enabled:
Purview portal → Data Loss Prevention → Endpoint DLP settings → Advanced classification
  scanning and protection → confirm On

# If the policy was hand-built (not from Quick Setup), confirm the rule also has:
#   Conditions → File Type is → at least one file type selected
# The "Insider risk level for Adaptive Protection is" condition alone is NOT
# sufficient for Endpoint DLP without one of the two prerequisites above.
```

**Rollback:** N/A — this is enabling a missing prerequisite, not a destructive change.

</details>

<details><summary>Fix 5 — Deleted-content preservation (DLM) not happening for an Elevated user</summary>

```
Purview portal → Data lifecycle management → Adaptive Protection in Data Lifecycle
  Management → toggle to On
```
If this is the first time enabling it and Adaptive Protection was already on before this toggle existed/was noticed, the auto-created retention label policy is created **at toggle time**, not retroactively — content already deleted before the toggle was turned on is **not** recoverable through this mechanism. Escalate to standard eDiscovery/backup recovery paths for anything already gone.

**Rollback:** turning the toggle back Off **deletes** the auto-created DLM policy outright (not just pauses it) — confirm with the client/compliance owner before disabling, since re-enabling later creates a fresh policy with no continuity from the old one.

</details>

<details><summary>Fix 6 — Scoped Purview admin can't see "Quick setup" / can't configure AP</summary>

Working as designed: **scoped admins for Microsoft Purview administrative units cannot use Quick setup.** They also only see the AP dashboard tabs (Insider risk levels / Users assigned / DLP / CA) that match role groups they hold — a scoped admin missing Conditional Access Administrator/Security Administrator/Global Administrator will never see the Conditional Access tab, for example, regardless of their IRM role.

Fix: either use Custom setup with a non-scoped Global/Compliance Administrator for initial configuration, or grant the specific role group needed for the missing tab.

</details>

<details><summary>Fix 7 — Someone is troubleshooting Adaptive Protection using `Get-MgRiskyUser` / sign-in `RiskLevelAggregated`</summary>

Wrong signal. `Get-MgRiskyUser`, `RiskLevelAggregated` on sign-in logs, and the Conditional Access `userRiskLevels`/`signInRiskLevels` conditions all belong to **Microsoft Entra ID Protection** — a completely separate risk engine based on sign-in/identity anomalies, not Purview Insider Risk Management. Adaptive Protection's own signal is the Graph `conditions.insiderRiskLevels` property and the Purview-side Elevated/Moderate/Minor construct. The two systems can coexist in the same tenant and even the same CA policy, but they are diagnosed, licensed (Entra ID P2 for both, but different feature blades), and reported on separately. Redirect the investigation to the correct policy/condition before spending more time on it.

</details>

---
## Escalation Evidence

```
=== Adaptive Protection Escalation ===
Tenant:                     <tenantName>
Ticket #:                   <ticketNumber>
Affected user(s):           <UPN or list>
Reported symptom:           <e.g. "Elevated-risk user still has app access" / "deleted files not preserved">

Licensing confirmed:
  Entra ID P2 present:        <Yes/No>
  E5 / E5 Compliance present: <Yes/No>

Adaptive Protection master toggle:      <On/Off, since when>
User's assigned insider risk level:     <Elevated/Moderate/Minor/None>
  Assigned on:                          <date>
  Source IRM policy:                    <policy name>

CA policy state:              <enabled / enabledForReportingButNotEnforced / disabled>
DLP policy status:            <On / simulation mode>
DLM opt-in toggle:            <On/Off>

Other CA/DLP policies in scope for this user (possible collision): <list or "none found">

Attempts made:               <fixes already tried, from this runbook>
Escalating because:          <e.g. "toggle states all correct, still not enforcing after 36h+ window">
```

---
## 🎓 Learning Pointers

- **Every enforcement arm ships OFF by default from Quick Setup.** CA is Report-only, both DLP policies are simulation mode — this is intentional so nothing blocks a real user on day one, but it means "I turned on Adaptive Protection" and "Adaptive Protection is actually blocking anyone" are two different milestones separated by a manual promotion step per arm. [Configure Adaptive Protection](https://learn.microsoft.com/en-us/purview/insider-risk-management-adaptive-protection#configure-adaptive-protection)

- **Insider risk *levels* (Elevated/Moderate/Minor) and alert *severity* (High/Medium/Low) are different scales measuring different things.** A High-severity alert does not automatically mean Elevated risk level — level assignment depends on the specific criteria configured (alert-based OR activity-count-based). Do not assume parity between the two words "high" and "elevated" when reading a ticket. [Insider risk levels](https://learn.microsoft.com/en-us/purview/insider-risk-management-adaptive-protection#insider-risk-levels)

- **Adaptive Protection's Conditional Access signal is not Entra ID Protection's risk signal.** `insiderRiskLevels` (Graph) / "Insider risk" (portal condition) is a distinct construct from `userRiskLevels`/`signInRiskLevels` and `Get-MgRiskyUser`. Conflating the two wastes troubleshooting time on the wrong API surface. [Insider risk as a CA condition](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-conditions#insider-risk)

- **DLP under Adaptive Protection only covers Exchange, Teams, and Devices** — not SharePoint or OneDrive as direct locations for the "Insider risk level for Adaptive Protection is" condition. If a client expects SPO/OneDrive sharing to be blocked by AP-driven DLP, set that expectation correctly; the DLM arm (deleted-item preservation) is the mechanism that covers SPO/OneDrive/Exchange, and it does something different (preserve, not block). [DLP + Adaptive Protection](https://learn.microsoft.com/en-us/purview/dlp-adaptive-protection-learn)

- **Turning Adaptive Protection off does not delete the underlying IRM/DLP/CA policies** — only the DLM policy is deleted when its own sub-toggle is turned off. A tenant can end up with orphaned CA/DLP policies still referencing insider risk levels that are no longer being assigned to anyone, which is silent and easy to miss in an audit. Always check for stale AP-condition policies when decommissioning. [Disable Adaptive Protection](https://learn.microsoft.com/en-us/purview/insider-risk-management-adaptive-protection#disable-adaptive-protection)
