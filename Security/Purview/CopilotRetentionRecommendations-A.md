# Purview Copilot & AI App Retention Insights (Roadmap 561209) — Reference Runbook (Mode A: Deep Dive)
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

Covers **Microsoft 365 Roadmap ID 561209** — a new insights-and-recommendations capability inside
Microsoft Purview Data Lifecycle Management that analyzes observed Copilot and other AI app usage and
recommends retention policies to govern the resulting prompts and responses. Per community reporting
dated 2026-07-14, preview begins ~August 2026 with GA targeted for September 2026 across Worldwide
commercial, GCC, GCC High, and DoD (rollout timing may vary by cloud instance). **As of this writing,
Microsoft has not published a dedicated Learn conceptual page for 561209 itself** — this runbook is
built primarily from Microsoft's existing, stable `retention-policies-copilot` documentation (the
mechanism the recommendations feed into) plus community reporting on the recommendation layer itself,
with the confidence gap between the two flagged explicitly throughout.

**Covers:**
- The existing, GA retention architecture for Copilot/AI app messages that any recommendation ultimately
  configures (Exchange-backed hidden-folder storage, timer-job processing, SubstrateHolds)
- The three retention locations: Microsoft Copilot experiences, Enterprise AI apps, Other AI apps
- What is and isn't known about the new recommendation layer specifically, sourced and dated

**Does not cover:**
- General Purview retention policy mechanics outside the AI-app locations — see `RetentionLabels-A.md`
  and `Security/Purview/` for the broader Data Lifecycle Management model
- Purview's network-layer DLP for unmanaged AI services (blocking/inspecting traffic to ChatGPT/Gemini
  etc. before it's even sent) — see `NetworkDataSecurity-A.md`; this runbook covers retention of
  content Purview has already been configured to collect, not preventing that content from existing
- eDiscovery case creation/search mechanics generally — see `eDiscovery-A.md`

**Build context (subject to Microsoft revision — reconfirm before treating any date below as final):**
- Roadmap ID 561209, first reported 2026-07-14, updated same date
- Preview: ~August 2026. GA: targeted September 2026
- The underlying retention mechanism it recommends into (separate Copilot/Teams-chat locations) has
  been GA since the split documented in `retention-policies-copilot` (Learn page `ms.date` 2025-09-23,
  `updated_at` 2026-06-25)

---
## How It Works

<details><summary>Full architecture — from AI app message to compliance copy to recommendation</summary>

### The existing retention mechanism (what any recommendation ultimately configures)

Retention policies for AI apps cover three separate locations, each with its own scope:

| Location | Includes |
|---|---|
| **Microsoft Copilot experiences** | Microsoft 365 Copilot, Security Copilot, Copilot in Fabric, Copilot Studio |
| **Enterprise AI apps** | Entra-registered AI apps, ChatGPT Enterprise, Microsoft Foundry |
| **Other AI apps** | ChatGPT, Google Gemini, consumer Microsoft Copilot, DeepSeek |

Content in the first-party **Microsoft Copilot experiences** category is captured automatically once a
user has Copilot licensing/access. Content for **Enterprise AI apps** and **Other AI apps** is captured
only when a [collection policy](https://learn.microsoft.com/en-us/purview/collection-policies-solution-overview)
is explicitly configured to capture it — a retention policy applied to an app category with no active
collection policy governs nothing, because there is nothing collected to retain or delete.

Behind the scenes, captured prompts and responses are copied into a **hidden folder inside the Exchange
Online mailbox of the user who ran the AI app** — the same mailbox `RecipientTypeDetails: UserMailbox`
also used for Teams private-channel and cloud-Teams message storage. This hidden folder is not
browsable by users or admins directly; it exists to be searched by eDiscovery tools.

An Exchange timer job periodically evaluates items in that folder (typically **1-7 days** per run).
When an item's retention period expires, the timer job moves it to **SubstrateHolds** — a second hidden
folder present in every mailbox for holding "soft-deleted" items pending permanent removal. The item
sits in SubstrateHolds for **at least 1 day**, then is permanently deleted the next time the timer job
runs (again typically 1-7 days). A delete-only policy configured for just 1 day can therefore still take
on the order of **16 days** end-to-end before the message stops being returned by eDiscovery — the
short configured duration is a policy threshold, not a wall-clock deletion guarantee.

The **first principle of retention** governs every stage: if the same mailbox is also subject to a
longer retention policy for the same location, a Litigation Hold, a delay hold, or an eDiscovery hold,
permanent deletion from SubstrateHolds is suspended regardless of what a shorter or delete-only policy
says. Preservation always wins over deletion when multiple controls apply.

Critically, **what a user sees in the AI app's chat history is not authoritative evidence of the
compliance copy's state.** Deleting a chat client-side (where the app supports it) or submitting a
request to delete a user's full Copilot interaction history starts the same backend process described
above — it does not instantly purge the Exchange-side copy. Conversely, an item can remain visible in
the AI app for a short window after the retention backend has already begun processing its removal,
due to communication/caching delays between the backend service and the app.

### The new insights/recommendations layer (Roadmap 561209)

Microsoft's roadmap description states the feature will provide **insights into Copilot and AI app
usage** and **recommend retention policies** administrators can use to govern those interactions.
This is explicitly framed as an *insights-and-recommendations* layer on top of the existing mechanism
above — not a new storage, collection, or deletion pathway. The stated goal is to close the gap between
an organization's formal retention plan (often built from interviews, licensing records, or assumptions
about AI adoption) and its actual, observed AI usage, by having Purview surface where usage exists and
suggest policy coverage for it.

As of this writing, Microsoft's public roadmap entry does **not** disclose: the dashboards or metrics
shown, the specific thresholds or logic driving a recommendation, whether recommendations differ by
department/geography/data-sensitivity, whether the interface exposes prompt/response content directly
or only aggregate counts, or whether recommended policies can ever be auto-activated versus requiring
manual creation. Treat all of the above as open questions to verify directly against the live Purview
portal and Microsoft Learn once the preview is available in-tenant, not as settled behavior.

</details>

---
## Dependency Stack

```
[Microsoft Purview portal — Data Lifecycle Management]
        |
[NEW: Insights & recommendations layer — Roadmap 561209]
  └─ Reads observed AI app activity signals (undisclosed specifics)
        |
[Visibility requires collection for the relevant AI app category]
  ├─ Microsoft Copilot experiences  → automatic, licensing-gated
  ├─ Enterprise AI apps             → requires an active collection policy
  └─ Other AI apps                 → requires an active collection policy
        |
[Recommendation surfaced → admin decision (manual review assumed, not confirmed auto-apply)]
        |
[EXISTING mechanism any accepted recommendation configures]
  Exchange hidden mailbox folder (per-user, per-AI-app-category)
        |
  Timer job evaluates expiry (1-7 days per run)
        |
  SubstrateHolds hidden folder (>=1 day minimum hold)
        |
  Timer job permanent deletion (1-7 days per run)
        |
[First principle of retention — evaluated at every stage]
  Longer policy / Litigation Hold / delay hold / eDiscovery hold on the same mailbox
  ALWAYS suspends permanent deletion, regardless of any shorter/delete-only policy
        |
[Inactive mailbox — user offboarded]
  Retained AI app content persists in the inactive mailbox, remains eDiscovery-searchable,
  subject to whatever retention policy applied before the mailbox went inactive
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Admin can't find the recommendation UI at all | Preview not yet rolled out to this tenant, or wrong portal area | Confirm tenant cloud + rollout wave; check Purview portal Data Lifecycle Management area directly, not the Message Center description alone |
| Recommendation covers Copilot but shows zero for a known ChatGPT Enterprise deployment | No collection policy configured for Enterprise AI apps | `Get-CollectionPolicy` — confirm a policy exists, is enabled, and targets the right workload |
| Admin assumes accepting a recommendation instantly deletes old data | Confuses policy creation with immediate execution | Explain the existing timer-job cadence (1-7 days per stage); nothing is instant even after policy creation |
| "Delete after 1 day" recommendation didn't remove content from eDiscovery after 2 days | Expected — multi-stage timer-job timing, not a stuck job | Walk the SubstrateHolds + timer-job math; typically ~16 days worst case for a 1-day delete-only policy |
| Recommended delete policy seems to have no effect on a specific mailbox | Another retention policy or hold on that mailbox is winning per the first principle of retention | `Get-RetentionCompliancePolicy` scoped to the mailbox; check for Litigation Hold / eDiscovery hold |
| User's AI chat history shows a conversation as gone, but eDiscovery still returns it | UI state is not authoritative for the compliance copy | Confirm via eDiscovery search directly rather than trusting the AI app's own history view |
| Security team surprised by an AI app referenced in a recommendation | Shadow AI usage the org didn't know about | Cross-reference Entra enterprise app registrations / DLP telemetry; treat as a security finding, not only a retention one |

---
## Validation Steps

1. **Confirm what retention policies currently exist for AI-app locations.**
   ```powershell
   Connect-IPPSSession -UserPrincipalName <adminUPN>
   Get-RetentionCompliancePolicy | Select-Object Name, Enabled, Copilot
   ```
   Good: policies list with `Copilot`/AI-location properties populated as expected. Bad: an admin
   believed a Teams-chat policy also covered Copilot — verify it doesn't, per the current split.

2. **Confirm collection policies exist for non-first-party AI apps.**
   ```powershell
   Get-CollectionPolicy | Select-Object Name, Enabled, Workload
   ```
   Good: an enabled policy targeting the relevant Enterprise/Other AI app. Bad: no policy — any
   retention recommendation for that app category is retaining nothing because nothing is collected.

3. **Confirm role/licensing readiness ahead of the August 2026 preview window.**
   Review which admins hold Data Lifecycle Management-relevant roles (Compliance Administrator, Data
   Lifecycle Management Administrator) and confirm awareness of potential pay-as-you-go billing implications
   for AI-app retention locations before broadly accepting recommendations.

4. **Spot-check a specific user's retained AI content via eDiscovery, never via the AI app UI.**
   Open a Content Search or eDiscovery case scoped to the user's mailbox with a relevant keyword/date
   range. This is the only authoritative way to confirm retention state described in this runbook.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Recommendation visibility**
Confirm preview rollout status for the tenant's cloud instance; confirm the admin is looking in the
correct Purview portal area (Data Lifecycle Management, not a generic Copilot admin page).

**Phase 2 — Recommendation accuracy**
Cross-check the recommendation's implied AI app coverage against `Get-CollectionPolicy` and
`Get-RetentionCompliancePolicy` output. A recommendation with no visibility into an app that's actually
in heavy use points to a collection-configuration gap, not a broken recommendation engine.

**Phase 3 — Post-acceptance behavior**
If a recommendation was accepted and turned into a live policy, but expected retention/deletion
behavior isn't observed, troubleshoot it as the existing (unchanged) AI-app retention mechanism —
walk the timer-job/SubstrateHolds timing model and check for a competing hold, exactly as with any
pre-561209 Copilot retention policy.

**Phase 4 — Governance/process**
If recommendations are being accepted without compliance/legal review, that's a process gap to flag
to the org, not a platform defect — Microsoft's own roadmap language stops short of framing this as an
autonomous compliance decision.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Preview-window readiness pass (before recommendations go live)</summary>

```
1. Inventory currently-allowed AI apps in the environment (licensed Copilot experiences, Entra-registered
   enterprise AI apps, any sanctioned "Other AI apps" access).
2. Confirm collection policies are enabled for every Enterprise/Other AI app category the org wants
   visibility into BEFORE the preview begins surfacing recommendations — a recommendation engine can
   only analyze what Purview can already see.
3. Document existing AI-app retention policies and their exact location scope (Get-RetentionCompliancePolicy),
   flagging any older policy that may still assume the pre-split "Teams chats and Copilot interactions"
   combined location.
4. Confirm role assignments: limit who can view/accept recommendations to personnel with a legitimate
   compliance function, especially if the interface later proves to expose more than aggregate counts.
5. Verify licensing/pay-as-you-go readiness for the AI-app retention locations before the org is asked
   to accept its first recommendation.
```

**Rollback:** N/A — preparatory only, no configuration changes made.

</details>

<details><summary>Playbook 2 — Structured review process for a surfaced recommendation</summary>

```
1. Capture the recommendation's stated scope (AI app category, approximate affected population,
   proposed retain/delete behavior) via screenshot/export before acting.
2. Route through compliance, legal, privacy, and Microsoft 365 admin review jointly — do not let a
   single admin unilaterally accept a policy recommendation with legal retention implications.
3. Confirm whether the recommendation identifies a regulatory/business-record obligation Purview cannot
   itself determine (Purview surfaces technical activity; it does not know what any specific law,
   contract, or internal policy actually requires).
4. On approval, create/edit the retention policy explicitly (Create-retention-policies guidance) and
   verify the resulting policy's location scope matches exactly what was reviewed — do not assume any
   one-click "accept" flow (if offered) produces the intended scope without verification.
5. Document the decision (accepted / modified / rejected, and why) for future audit and to avoid the
   same recommendation being re-litigated without context each review cycle.
```

**Rollback:** `Set-RetentionCompliancePolicy -Identity "<Name>" -Enabled $false` to pause, or
`Remove-RetentionCompliancePolicy -Identity "<Name>"` to fully remove a policy created from an
accepted recommendation.

</details>

---
## Evidence Pack

```powershell
# Purview Copilot/AI App Retention — Evidence Pack
Connect-IPPSSession -UserPrincipalName <adminUPN>

Write-Host "=== AI-App-Relevant Retention Policies ===" -ForegroundColor Cyan
Get-RetentionCompliancePolicy | Select-Object Name, Enabled, Copilot, ExchangeLocation | Format-Table -AutoSize

Write-Host "=== Collection Policies (Enterprise/Other AI app capture) ===" -ForegroundColor Cyan
Get-CollectionPolicy 2>$null | Select-Object Name, Enabled, Workload | Format-Table -AutoSize

Write-Host "=== Retention Compliance Rules referencing AI/Copilot locations ===" -ForegroundColor Cyan
Get-RetentionComplianceRule | Where-Object { $_.Comment -match "Copilot|AI app" -or $_.RetentionComplianceAction } |
    Select-Object Name, Comment, RetentionDuration, RetentionComplianceAction | Format-Table -AutoSize

Write-Host "NOTE: The Roadmap 561209 recommendation engine itself has no PowerShell/Graph read surface" -ForegroundColor Yellow
Write-Host "as of this writing. Capture recommendation screenshots from the Purview portal manually." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-RetentionCompliancePolicy` | List retention policies, including AI-app location scope |
| `Get-RetentionCompliancePolicy -Identity "<Name>" \| fl *` | Full detail on one policy's exact location targeting |
| `Get-RetentionComplianceRule` | Underlying rules (duration, retain vs. delete action) per policy |
| `Get-CollectionPolicy` | Confirm capture is configured for Enterprise/Other AI apps |
| `Set-RetentionCompliancePolicy -Identity "<Name>" -Enabled $false` | Pause a policy created from an accepted recommendation |
| `Remove-RetentionCompliancePolicy -Identity "<Name>"` | Delete a policy created from a rejected/incorrect recommendation |
| `Connect-IPPSSession` | Required session for all commands above |
| eDiscovery Content Search (portal) | Authoritative check for actual retained/deleted state — not the AI app UI |

---
## 🎓 Learning Pointers

- **Insights-and-recommendations is a UX/decision-support layer, not a new retention mechanism.**
  Understanding the underlying, already-GA architecture in
  [Learn about retention for Copilot & AI apps](https://learn.microsoft.com/en-us/purview/retention-policies-copilot)
  is the fastest way to reason about anything this new feature surfaces.
- **A recommendation is exactly as good as the collection configuration behind it.** An AI app with
  zero recommendation coverage may simply be uncollected, not unused — pair this feature with a
  collection-policy audit rather than trusting silence as evidence of no activity.
- **The "first principle of retention" (preservation wins) is the single most load-bearing fact for
  troubleshooting any AI-app retention behavior**, recommended or manually configured — most "why
  didn't this delete" tickets resolve to a competing hold or longer policy.
- **This is preview-status with an undocumented recommendation engine as of this writing.** Re-verify
  UI specifics, thresholds, and any auto-activation question directly against the live Purview portal
  and Microsoft's roadmap/Learn pages once available in-tenant — do not treat this runbook's framing
  of "manual review required" as a permanent guarantee if Microsoft's documentation later states
  otherwise.
- Community analysis, dated and sourced: [Purview Recommends Copilot Retention Policies in September 2026](https://windowsforum.com/windows-news.4/microsoft-purview-recommends-copilot-retention-policies-in-september-2026.438268/).
- Official architecture reference: [Learn about retention for Copilot & AI apps](https://learn.microsoft.com/en-us/purview/retention-policies-copilot) (`ms.date` 2025-09-23, `updated_at` 2026-06-25).
