# Unified App & Agent Management (Teams + M365 Admin Center) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate an app/agent availability mismatch ticket in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

> **Source note:** Corroborated directly from Message Center post MC796790 ("Unified management of app and agent availability and installation in Teams, Outlook, and the Microsoft 365 app," last updated 2026-09-01) and the official Microsoft Learn conceptual page (`microsoftteams/uam-tac-mac`, `ms.date` 2026-04-14, `updated_at` 2026-08-18). This is a multi-phase, multi-year rollout (Roadmap IDs 393931, 485712, 503105, 567883) that began end of September 2025 and, as of this writing, is in **Phase B — unifying app *installation*** (rolling out late August 2026, completing mid-September 2026), layered on top of Phase A's already-completed app *availability* unification. Distinct from this repo's existing `M365/Teams/ExternalAccess-A.md`/`-B.md` (federation/external-user access controls) and `Intune/Troubleshooting/EnterpriseAppManagement-A.md`/`-B.md` (Intune app deployment) — this topic covers the Teams admin center (TAC) ↔ Microsoft 365 admin center (MAC) app/agent availability and installation *synchronization* layer specifically.

Run these first — results tell you which fix path to follow:

```
# This is a portal-driven feature — there is no PowerShell cmdlet surface for
# unification state itself as of this writing. Triage is manual portal inspection:

# 1. Is this tenant already unified, or still on separate TAC/MAC configuration?
#    Teams admin center > Teams apps > Manage apps
#    Look for either:
#      - A "default phase, no action required" banner (tenant auto-unified, Phase 1) OR
#      - A "Move to unified app management" banner (tenant has custom settings, needs action) OR
#      - No banner at all + a "Popular apps in your org" widget visible (already unified)

# 2. Was the app/agent installed via a Teams "app setup policy" specifically?
#    Teams admin center > Teams apps > Setup policies > [policy name] > Installed apps
#    (Phase B explicitly does NOT unify app-setup-policy-based installations —
#     this is the single most common source of "why did this stop/not sync" tickets)

# 3. Is the specific app/agent's availability actually different between the two portals?
#    TAC:  Teams admin center > Teams apps > Manage apps > [app name] > Status/Availability
#    MAC:  admin.microsoft.com > Settings > Integrated apps  (or Copilot > Agents, for agents)
#    Compare Status (Allowed/Blocked) and Availability (Everyone/Specific users-groups) side by side

# 4. Who is reporting the issue — an end user missing an app, or an admin seeing
#    inconsistent settings between portals?
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Tenant shows "default phase" banner, never customized settings in either portal | Already auto-unified (Phase 1) — a reported mismatch is likely a caching/propagation delay, not a real config difference — Fix 1 |
| Tenant shows "Move to unified app management" banner | Tenant has NOT yet unified — this alone explains any TAC/MAC mismatch tickets; unification itself is the fix — Fix 2 |
| App was installed via a Teams **app setup policy** | Expected: Phase B explicitly excludes app-setup-policy installs from unification — this is documented behavior, not a bug — Fix 3 |
| Tenant already unified but a specific app still shows different Status/Availability in TAC vs. MAC | Sync propagation delay (uncommon) OR the app is one of the narrower "supported app" set for unification — Fix 4 |
| User missing Copilot agent access after this rollout reached the tenant | Check MAC Copilot > Agents availability AND TAC app management together — availability for agents specifically now spans both — Fix 1/Fix 2 as applicable |
| Admin wants to know when Phase 3 (automatic unification for stragglers) hits this tenant | No fixed date published — Microsoft commits to 60 days' advance notice before Phase 3 begins; not an escalation-worthy question, just documentation — Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant is in scope for the rollout (all Microsoft 365/Teams tenants, phased timeline)
        │
Phase A — App/Agent AVAILABILITY unification (rolled out Sept 2025 → complete)
   Phase 1: tenants that NEVER modified org-wide defaults/availability/block-unblock
            in either TAC or MAC → auto-unified, zero admin action
   Phase 2: tenants that DID modify settings in either portal previously
            → require an explicit admin action via a wizard in TAC:
              "Move to unified app management" → resolve any discrepancies →
              Global admin consent required to finalize
   Phase 3: automatic unification for any tenant that skipped Phase 1/2
            (future — Microsoft commits to 60 days' advance notice, no date set yet)
        │
Phase B — App/Agent INSTALLATION unification (rolling out late Aug 2026 → mid-Sept 2026)
   Requires Phase A already complete for that tenant (already-unified tenants:
   no additional action; existing eligible installation assignments stay synced)
   EXCLUDES app-setup-policy-based Teams app installations — those remain
   Teams-admin-center-only and are NOT unified as part of Phase B
        │
Only a GLOBAL ADMIN can give consent and finalize the "move to unified" wizard
   Teams admins / other roles can review and align settings up to the
   "Review summary" step, but cannot apply the final change
        │
Once unified: changes to org-wide defaults, app status, or availability made
in EITHER TAC or MAC auto-propagate to the other — a genuine single source
of truth going forward, not two systems admins must remember to keep in sync
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Determine the tenant's current unification phase**

Teams admin center > **Teams apps** > **Manage apps**. Look for one of three states:
- No banner, "Popular apps in your org" widget visible → already unified
- "Default phase, no action required" banner → auto-unified via Phase 1, nothing to do
- "Move to unified app management" banner → tenant has custom settings requiring the wizard (Phase 2)

**Step 2 — If a mismatch is reported, confirm it isn't the documented app-setup-policy exclusion**

Teams admin center > **Teams apps** > **Setup policies** > [relevant policy] > check if the app in question is pinned/installed via that policy specifically. If yes, this is expected, documented Phase B scope — not a defect.

**Step 3 — Compare the specific app/agent's settings directly across both portals**

TAC: Teams admin center > Teams apps > Manage apps > [app] > review Status and Availability.
MAC: admin.microsoft.com > Settings > Integrated apps (for general M365 apps) or Copilot > Agents (for Copilot agents specifically) > review the same app/agent's Status and Availability.

A genuine, persistent difference between the two — for an already-unified tenant, outside the app-setup-policy exclusion — is the actual anomaly worth escalating.

**Step 4 — For an un-unified tenant, walk the wizard to identify and resolve differences**

Teams admin center > Teams apps > Manage apps > **Move to unified app management** > **Align org-wide app settings** (choose which portal's org-wide defaults to apply) > **Align app-level settings** (individual app-by-app, bulk-by-portal, or CSV export/review) > **Review summary** > Global admin **Accept and finish**.

**Step 5 — Confirm which roadmap phase governs the specific symptom**

Availability-only symptoms (an app blocked/allowed differently) map to Phase A (already GA). Installation-only symptoms (an app that shows correct availability but doesn't actually get installed/pinned consistently) map to Phase B (rolling out through mid-September 2026) — a Phase B symptom on a tenant Microsoft hasn't yet reached with that specific sub-rollout is expected, not a fault.

---

## Common Fix Paths

<details><summary>Fix 1 — Reported mismatch is a propagation delay on an already-unified tenant</summary>

**Cause:** Sync between TAC and MAC, while automatic, is not always instantaneous — a change made in one portal can take some time to visibly reflect in the other.

**Remediation:**
1. Re-check both portals after a short wait (start with 30-60 minutes; this is not a documented fixed SLA, so use judgment and re-check rather than assuming a hard number).
2. If still mismatched after a reasonable wait, re-save the setting in whichever portal it was originally changed in to re-trigger sync, rather than changing it in the other portal (which could create a genuine conflict).
3. If persistent beyond a business day, escalate as a genuine sync defect (see Escalation Evidence).

**Rollback:** N/A — no configuration change made by this fix path itself.

</details>

<details><summary>Fix 2 — Tenant hasn't unified yet; walk the wizard</summary>

**Cause:** The tenant previously modified org-wide defaults, app availability, or block/unblock settings in either TAC or MAC, so Phase 1 auto-unification didn't apply — an explicit admin action is required.

**Remediation:**
1. Teams admin center > Teams apps > Manage apps > **Move to unified app management**.
2. **Align org-wide app settings**: choose which portal's org-wide defaults (app availability, block/unblock posture) should become the tenant-wide standard going forward.
3. **Align app-level settings**: for every app/agent with differing Status/Availability between TAC and MAC, resolve via individual app alignment, bulk resolution (apply one portal's settings across multiple apps at once), or export to CSV for offline review with stakeholders before deciding.
4. **Review summary**: any Teams or Global admin can review and adjust up to this step.
5. **Accept and finish**: requires a **Global Administrator** specifically — this is the one step in the flow with a hard role requirement.

**Rollback:** There is no documented "un-unify" path back to separate TAC/MAC management once consent is given — treat this as a one-way migration and plan the org-wide default and app-level alignment decisions deliberately (e.g., with input from whichever team manages the stricter of the two portals' current settings) rather than clicking through quickly.

</details>

<details><summary>Fix 3 — App-setup-policy installation is out of scope (expected, not a bug)</summary>

**Cause:** Microsoft's own Phase B messaging is explicit: "App installation is no longer managed through Teams app setup policies. App installations previously made through app setup policies are not unified as part of this change." Any app pinned/installed via a Teams app setup policy remains governed by that policy specifically, independent of the new unified installation management surface.

**Remediation:**
1. Confirm the app in question is indeed installed via a setup policy (Teams admin center > Teams apps > Setup policies).
2. If the goal is to bring that app under the new unified installation model instead, it needs to be removed from the setup policy and managed via the unified installation surface directly (Manage apps / Integrated apps) — this is a deliberate re-scoping decision, not a defect fix, and should be confirmed with the app owner before changing.
3. If the setup-policy-based install is intentional and working as designed, no action is needed — document this as expected behavior for the ticket.

**Rollback:** N/A — this fix path is a clarification/documentation outcome unless the admin explicitly chooses to re-scope the app's management surface.

</details>

<details><summary>Fix 4 — Genuine post-unification mismatch on an unexpected app/agent</summary>

**Cause:** A small set of apps/agents may not be fully in scope for the current phase of unification (Microsoft's rollout has historically excluded specific app types incrementally, expanding coverage over successive sub-phases per Roadmap IDs 485712/503105/567883).

**Remediation:**
1. Confirm the app/agent type — Copilot agents (MAC: Copilot > Agents) have historically had a slightly different unification timeline than conventional Teams/M365 apps.
2. Check the current Message Center post MC796790 for the latest revision — it has been updated over 25 times since 2024 and is the authoritative source for exactly which app/agent categories are unified as of any given date.
3. If the app/agent type is confirmed in scope and still mismatched, this is genuinely unexpected — collect evidence (Escalation Evidence section) and escalate to Microsoft support rather than attempting a workaround.

**Rollback:** N/A — escalation path, not a self-service fix.

</details>

<details><summary>Fix 5 — Admin asking about Phase 3 automatic-unification timing</summary>

**Cause:** Not an incident — an informational question about a future rollout phase for tenants that skipped both Phase 1 and Phase 2.

**Remediation:**
1. Confirm the tenant hasn't actually already unified via Phase 1 or 2 (Step 1 of Diagnosis).
2. If genuinely still un-unified, inform the admin that Microsoft has not published a Phase 3 start date but commits to at least 60 days' advance notice via Message Center before it begins.
3. Recommend proactively completing Phase 2 (Fix 2) on the admin's own timeline rather than waiting for automatic unification, to retain control over the org-wide default and app-level alignment decisions.

**Rollback:** N/A — advisory only.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Unified App & Agent Management Issue
=====================================
Tenant unification phase observed: [Not unified / Auto-unified Phase 1 / Manually unified Phase 2 / Unclear]
Banner shown in TAC > Manage apps: [text/screenshot]
App/Agent name affected:            [name]
App/Agent type:                     [Teams app / M365 app / Copilot agent]
Installed via app setup policy:     [Yes/No — policy name if yes]
TAC Status/Availability:            [value]
MAC Status/Availability:            [value]
Time elapsed since last change in either portal: [duration]
Global admin who performed unification (if applicable): [name, date]
Message Center post MC796790 revision reviewed: [Yes/No — date checked]

Symptom description:
[what was reported — missing app, mismatched availability, install not syncing]

Steps already attempted:
[ ] Confirmed tenant's current unification phase via the Manage apps banner
[ ] Confirmed the app isn't installed via a Teams app setup policy (Phase B exclusion)
[ ] Compared Status/Availability directly in both TAC and MAC
[ ] Waited a reasonable propagation window and re-checked
[ ] Reviewed the current revision of Message Center post MC796790
[ ] Attempted re-save in the portal where the setting was originally changed
```

---

## 🎓 Learning Pointers

- **This is a multi-year, multi-phase rollout, not a single feature flip** — Phase A (availability) began rolling out September 2025 and completed; Phase B (installation) is rolling out late August through mid-September 2026 as of this writing; Phase 3 (automatic unification for stragglers) has no published date yet. Always confirm which phase governs the specific symptom before troubleshooting. [MC796790 — Microsoft 365 Message Center Archive](https://mc.merill.net/message/MC796790)

- **"App setup policy installs are not unified" is the single highest-value fact to know cold** — it explains a large share of "why didn't this sync" tickets that otherwise look like a genuine defect. Confirm this exclusion before spending time on deeper diagnosis.

- **Only a Global Administrator can finalize the move-to-unified wizard**, even though Teams admins can review and adjust settings up to the summary step — a ticket stuck at "Review summary" with no progress is very often simply waiting on the right role to click Accept, not a technical blocker.

- **Treat unification as one-way.** No documented path exists to revert a tenant back to separately-managed TAC/MAC app settings after Global Admin consent — walk the alignment wizard deliberately, ideally with input from whichever team currently manages the stricter of the two portals' settings, rather than accepting default selections quickly. [Unified agent and app availability management — Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/uam-tac-mac)

- **Copilot agents and conventional apps have historically had slightly different rollout timing within this same overall initiative** — when in doubt about whether a specific app/agent type is in scope yet, check the current revision of MC796790 directly rather than assuming uniform coverage across all app/agent categories.
