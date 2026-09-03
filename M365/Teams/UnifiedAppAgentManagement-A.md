# Unified App & Agent Management (Teams + M365 Admin Center) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the phased architecture behind TAC/MAC app-and-agent management convergence, not just how to click through the wizard.

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

**In scope:**
- The architecture and phased rollout of unified app/agent availability and installation management across the Teams admin center (TAC) and Microsoft 365 admin center (MAC), per Message Center post MC796790 and Microsoft Learn's `uam-tac-mac` conceptual page
- Phase A (availability unification, GA) and Phase B (installation unification, rolling out through mid-September 2026) architecture and admin workflow
- The app-setup-policy exclusion and its implications for existing Teams app deployment strategy
- Governance/consent model (Global Admin requirement) and the one-way nature of the migration

**Out of scope:**
- Teams app permission policies, app certification/publishing, or the Teams app store submission process — unrelated governance surfaces
- Intune-based application deployment (`Intune/Troubleshooting/EnterpriseAppManagement-A.md`) — a separate deployment mechanism from app *availability* governance
- Federation/external-user access controls (`M365/Teams/ExternalAccess-A.md`) — a different access-control dimension from internal app/agent availability
- Copilot agent development, publishing, or the underlying agent runtime — this runbook covers only the admin-facing availability/installation governance surface

**Assumptions:**
- Reader has Global Administrator or Teams Administrator role and familiarity with both TAC and MAC
- Tenant is a standard commercial Microsoft 365/Teams tenant (GCC High/DoD/sovereign cloud timelines may differ and are not addressed here)
- **Source-confidence note:** the phase timeline, the app-setup-policy exclusion, the Global-Admin-only consent requirement, and the wizard mechanics are drawn directly from the Microsoft Learn `uam-tac-mac` conceptual page (`ms.date` 2026-04-14, `updated_at` 2026-08-18) and Message Center post MC796790, which has itself been revised over 25 times since its original 2024-05-29 publication — treat MC796790's *current* revision, not any cached summary of it, as the single source of truth for exact dates, since this rollout's timeline has shifted multiple times (Phase 1's completion date alone moved from an original end-of-June target to "previously end of June... now complete by August 2026" per the post's own revision history).

---

## How It Works

<details><summary>Full architecture</summary>

### The Problem This Solves: Two Portals, One Underlying App Population

Before this initiative, a Teams-capable app, add-in, or Copilot agent that also worked in Outlook and the Microsoft 365 app had its availability and installation governed independently in two separate admin surfaces:

1. **Microsoft 365 admin center (MAC)** — the **Integrated apps** page (for conventional M365 apps) and the **Copilot > Agents** page (for Copilot agents specifically)
2. **Teams admin center (TAC)** — the **Manage apps** page, plus **Setup policies** for pinned/pre-installed app assignment

Because these were two independently-operated control planes over what is, in the underlying app catalog, frequently the *same app*, admins could — and in practice regularly did — configure conflicting availability (an app blocked in one portal, allowed in the other) or install/pin an app inconsistently across the surfaces where it actually runs (Teams, Outlook, the M365 app, Copilot). Microsoft's own framing of "why now" cites exactly this: mismatched settings across two portals governing one underlying app population, discovered by admins only when a support ticket surfaced the inconsistency, not proactively.

### Phase Architecture: Availability First, Then Installation

The rollout is explicitly split into two functionally distinct unification efforts, tracked under separate (though related) Roadmap IDs:

**Phase A — Unify app AVAILABILITY** (Roadmap ID 393931, then extended per 485712/503105)
Governs whether an app/agent is Allowed or Blocked tenant-wide, and for which users/groups. Rolled out in three sub-phases:
- *Phase 1*: tenants that never customized org-wide defaults/availability/block-unblock in EITHER portal → automatically and silently unified, zero admin action, confirmed via a "default phase" banner
- *Phase 2*: tenants with prior customization in either portal → require explicit admin action through a guided wizard (align org-wide defaults → align individual app-level differences → Global Admin consent)
- *Phase 3*: automatic unification for any tenant that never completed Phase 1 or 2 — not yet scheduled as of this writing; Microsoft commits to at least 60 days' advance Message Center notice before this phase begins for any given tenant

**Phase B — Unify app INSTALLATION** (Roadmap ID 567883, rolling out late August 2026 → complete mid-September 2026)
A functionally separate concern from availability: this governs whether an app is actually *installed/pinned* consistently for users across TAC and MAC, building on top of an already-availability-unified tenant. Phase B carries one architecturally important carve-out: **installations made through Teams app setup policies are explicitly excluded** — the unified installation surface and the legacy app-setup-policy mechanism remain two parallel, non-converged systems going forward for any app an org chooses to keep managing via setup policy.

### Why the App-Setup-Policy Exclusion Exists (Inferred Architectural Reasoning)

Teams app setup policies are a considerably more granular mechanism than the new unified installation surface — they support features like custom pin ordering, per-policy-group app sets, and integration with Teams-specific rollout sequencing that the MAC "Integrated apps" installation model was never designed to express. Rather than attempting to force setup-policy-driven installs into the coarser unified model (which would mean a lossy downgrade of existing granular control for any org actively using setup policies for fine-grained Teams app rollout), Microsoft has scoped Phase B to leave that mechanism alone entirely. The practical consequence: an org's Teams app deployment strategy doesn't need to change at all if it already relies on setup policies — but it also means those specific apps will never show up as "unified" in the new surface, which is expected, not a partial-migration bug.

### The Wizard Mechanics (Phase 2 / Un-Unified Tenants)

For a tenant with prior customization, the unification wizard in TAC (Teams apps > Manage apps > "Move to unified app management") walks through:

1. **Align org-wide app settings** — a single decision point: which portal's org-wide default posture (baseline availability, block/unblock stance) becomes the tenant's unified going-forward default. This is not a per-app decision at this step — it's the tenant-wide baseline.
2. **Align app-level settings** — for every individual app/agent where TAC and MAC currently disagree, the admin resolves via:
   - *Individual app-alignment*: review one app's Status/Availability side by side and pick a source portal
   - *Bulk app resolution*: select many differing apps at once and apply one portal's settings across all of them in one action
   - *CSV export*: download the full current App status/Availability comparison for offline review — useful for orgs wanting stakeholder sign-off before committing changes at scale
3. **Review summary** — any Teams or Global admin can review and adjust selections up to this point; nothing is applied yet
4. **Consent and finish** — requires **Global Administrator** specifically; this is a deliberate, hard role gate distinct from every earlier step in the flow, reflecting that the action is tenant-wide, cross-portal, and (per current documentation) not reversible through any published rollback path

### Post-Unification Steady State

Once unified, TAC's **Manage apps** (via [app centric management](https://learn.microsoft.com/en-us/microsoftteams/app-centric-management)) and MAC's **Integrated apps**/**Agents** pages become two views into the same underlying, synchronized configuration — a change made in either portal propagates automatically to the other. A newly-surfaced feature exclusive to unified tenants, the **"Popular apps in your org"** widget (Manage apps page and TAC Dashboard), analyzes third-party app usage over a trailing 90-day window and surfaces two of the most-used apps not yet installed tenant-wide, sourced from the `Ideas` API (which covers usage beyond Teams itself) — a discoverability signal that didn't exist prior to unification, since it depends on having one authoritative usage/installation dataset to analyze rather than two potentially-divergent ones.

</details>

---

## Dependency Stack

```
Tenant is a standard commercial Microsoft 365/Teams tenant
        │
Phase A (availability) rollout has reached this tenant — GA, essentially universal
   ├── Phase 1: no prior customization in either portal → auto-unified silently
   ├── Phase 2: prior customization present → requires admin wizard + Global Admin consent
   └── Phase 3: not-yet-scheduled catch-all for stragglers (60-day advance notice promised)
        │
[Tenant now availability-unified — TAC and MAC share one availability config]
        │
Phase B (installation) rollout has reached this tenant (late Aug – mid Sept 2026)
   Already-unified tenants: no additional action, existing eligible installation
   assignments remain synchronized automatically
        │
   EXCLUSION: apps installed via Teams APP SETUP POLICIES remain outside the
   unified installation surface permanently — a parallel, non-converged
   management path by design, not a temporary gap
        │
[Steady state: TAC "Manage apps" and MAC "Integrated apps"/"Agents" are two
 synchronized views of one configuration; changes in either propagate to both;
 "Popular apps in your org" widget available as a unification-exclusive feature]
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| App availability differs between TAC and MAC | Tenant hasn't completed unification (still Phase 1-eligible-but-uncustomized-check-failed, or genuinely Phase 2-pending) | TAC Manage apps banner state |
| App/agent install doesn't reflect consistently across Teams, Outlook, M365 app | Either Phase B hasn't reached this tenant yet, OR the app is installed via a setup policy (permanently excluded from Phase B) | Check setup policies first — most common root cause |
| Wizard stuck at "Review summary," no further progress | Waiting on a Global Administrator specifically — Teams admin/other roles cannot finalize | Confirm who has attempted the "Accept and finish" step |
| Copilot agent availability inconsistent post-rollout | Agents have historically had distinct sub-timing within the same overall initiative from conventional apps | Check MAC Copilot > Agents directly, and the current MC796790 revision |
| "Popular apps in your org" widget missing | Tenant not yet unified — this widget is exclusive to unified tenants | TAC Manage apps banner state |
| Settings changed in one portal don't appear in the other after a reasonable wait | Genuine sync defect (uncommon) — or the app in question is a setup-policy-managed one (won't sync by design) | Confirm setup-policy status before treating as a defect |
| Admin unsure which of two conflicting historical settings "won" after unification | The org-wide default alignment decision made during the Phase 2 wizard determined this — check who ran the wizard and which portal's defaults were selected | No live re-check possible after the fact except by inspecting current effective settings directly |

---

## Validation Steps

**1. Confirm the tenant's unification phase:**
Teams admin center > Teams apps > Manage apps — observe banner state (none/default-phase/move-to-unified).

**2. Confirm whether the specific app is setup-policy-managed:**
Teams admin center > Teams apps > Setup policies > [policy] > Installed apps — cross-reference against the app in question.

**3. Directly compare the app/agent's settings across both portals:**
TAC: Manage apps > [app] > Status/Availability.
MAC: Integrated apps (conventional apps) or Copilot > Agents (agents) > same fields.

**4. Confirm the current revision of the authoritative Message Center post:**
MC796790 in the tenant's own Message Center (admin.microsoft.com > Health > Message center), or the public archive mirror, for the latest confirmed phase timing — this post has been revised over 25 times and dates shift.

**5. For a stuck wizard, confirm role of the person attempting to finalize:**
Only Global Administrator can complete "Accept and finish" — a Teams Administrator reaching that step and reporting it "doesn't work" is expected role-gate behavior, not a bug.

---

## Troubleshooting Steps (by phase)

### Phase 1: Establish Ground Truth on Unification State
1. Check the TAC Manage apps banner directly — do not rely on an admin's memory or assumption about whether unification already happened.
2. If ambiguous, check for the "Popular apps in your org" widget's presence as a secondary confirmation signal (unification-exclusive feature).

### Phase 2: Isolate Availability vs. Installation Symptoms
1. Determine whether the reported issue is about an app being blocked/allowed differently (Phase A/availability) or about inconsistent install/pin behavior across surfaces (Phase B/installation) — these are architecturally separate concerns with separate rollout timing.
2. For installation symptoms specifically, check setup-policy status FIRST — this single check resolves the largest share of Phase B-related tickets.

### Phase 3: Direct Cross-Portal Comparison
1. Pull the specific app/agent's Status and Availability from both TAC and MAC side by side.
2. For Copilot agents, check MAC's Copilot > Agents page specifically, not just Integrated apps (a common oversight since agents are a newer app category with their own MAC surface).

### Phase 4: Wizard-Stuck or Consent-Gate Tickets
1. Confirm current wizard step and who has attempted to progress it.
2. Confirm whether a Global Administrator has actually attempted the final consent step — if not, this is the entire resolution, not a technical investigation.

### Phase 5: Genuine Defect Escalation
1. Only after confirming unification phase, setup-policy exclusion status, and a reasonable propagation wait, treat a persistent cross-portal mismatch as a genuine defect.
2. Collect the Evidence Pack output and the current MC796790 revision date before escalating to Microsoft support.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Planned, deliberate Phase 2 unification for a tenant with custom settings</summary>

```
1. Before starting the wizard, independently document current org-wide defaults
   AND every app/agent's Status/Availability in BOTH TAC and MAC (use the CSV
   export inside the wizard for the app-level data once you reach that step,
   but capture org-wide defaults beforehand since the wizard doesn't export those).
2. Decide, with input from whichever team currently manages the stricter/more
   deliberately-configured of the two portals, which portal's org-wide defaults
   should become the tenant-wide standard.
3. Walk the wizard: Align org-wide app settings → Align app-level settings
   (prefer CSV export + offline stakeholder review for tenants with a large
   number of differing apps, rather than resolving dozens individually inline).
4. Have a Global Administrator perform the final "Accept and finish" only after
   the app-level alignment has been reviewed and agreed, not as a rushed final click.
```

**Verify:** confirm the "default phase"/no-banner state afterward, and spot-check several previously-differing apps directly in both portals.

**Rollback:** none documented — this is why the pre-wizard documentation step matters; there's no "undo," only manually re-configuring individual settings back if a specific alignment choice turns out wrong.

</details>

<details><summary>Playbook 2 — Deciding whether to migrate an app off setup-policy management into the unified surface</summary>

Use when an org wants a specific app to participate in the new unified installation model (Phase B) rather than remaining setup-policy-managed.

```
1. Confirm exactly what granular control the setup policy currently provides for
   that app (custom pin ordering, per-policy-group targeting) that the unified
   installation surface may not replicate.
2. If the granular control isn't actually needed for that specific app, remove
   it from the setup policy assignment.
3. Manage the app going forward via the unified installation surface (Manage
   apps / Integrated apps) instead.
4. Confirm end-user experience post-change (pin position, default install state)
   matches expectations — this is a genuine behavior change, not just an
   administrative relocation.
```

**Verify:** confirm the app now reflects consistently across TAC and MAC installation state, and that end users see the expected pin/install behavior.

**Rollback:** re-add the app to the original setup policy configuration if the unified surface doesn't replicate needed granularity.

</details>

<details><summary>Playbook 3 — Tracking rollout timing against MC796790's revision history</summary>

Given this post's own history of 25+ revisions with shifting dates, maintain an internal note (not a Microsoft-provided mechanism) tracking:

```
- Date this tenant's Manage apps banner was last checked, and what it showed
- Date/phase this tenant completed Phase 2 unification (if applicable), and
  which admin performed it
- Date Phase B (installation) was confirmed active for this tenant (first
  observation of consistent cross-portal install sync for a non-setup-policy app)
- Any apps deliberately kept on setup-policy management post-Phase-B, and why
```

**Verify:** this is a documentation/tracking playbook, not a technical change — "verification" is simply having accurate internal records the next time a related ticket comes in.

**Rollback:** N/A.

</details>

---

## Evidence Pack

```
EVIDENCE PACK — Unified App & Agent Management
=====================================
(This is a portal-driven feature with no dedicated PowerShell audit cmdlets as of
this writing — evidence collection is manual portal inspection plus the companion
Get-UnifiedAppManagementAudit.ps1 script, which audits the MechAnism-ADJACENT signal
of Teams app setup policy assignments via the MicrosoftTeams PowerShell module,
since that IS scriptable and directly explains the Phase B exclusion for any given app.)

1. TAC Manage apps banner screenshot/state: [attach or describe]
2. MAC Integrated apps / Copilot > Agents screenshot for the affected app: [attach]
3. Setup policy audit (run Get-UnifiedAppManagementAudit.ps1): [attach CSV]
4. Current Message Center post MC796790 revision date (from admin.microsoft.com
   Message Center or the public archive): [date]
5. Timeline of any wizard interactions for this tenant (who, when, which
   org-wide default was selected): [from Playbook 3 tracking notes, if maintained]
```

---

## Command Cheat Sheet

```powershell
# There is no dedicated cmdlet surface for TAC/MAC unification state itself.
# The one directly scriptable, adjacent signal is Teams app setup policy assignment
# (relevant because setup-policy-installed apps are permanently excluded from
# Phase B installation unification):

Connect-MicrosoftTeams

# List all Teams app setup policies
Get-CsTeamsAppSetupPolicy | Select-Object Identity, PinnedAppBarApps

# Inspect a specific policy's pinned/installed apps in detail
(Get-CsTeamsAppSetupPolicy -Identity "<PolicyName>").PinnedAppBarApps

# Confirm which users/groups a given setup policy is assigned to
Get-CsOnlineUser -Filter "InterpretedUserType -eq 'PureOnlineTeamsOnlyUser'" |
    Select-Object UserPrincipalName, TeamsAppSetupPolicy

# Portal paths (no CLI equivalent as of this writing):
# TAC:  Teams admin center > Teams apps > Manage apps
# TAC:  Teams admin center > Teams apps > Setup policies
# MAC:  admin.microsoft.com > Settings > Integrated apps
# MAC:  admin.microsoft.com > Copilot > Agents
```

---

## 🎓 Learning Pointers

- **Availability and installation are two separate unification efforts on two separate timelines** (Phase A GA, Phase B rolling out through mid-September 2026) — always establish which one a symptom actually maps to before troubleshooting, since they have different exclusions and different completion states per tenant. [Unified agent and app availability management — Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/uam-tac-mac)

- **The app-setup-policy exclusion is architecturally permanent, not a temporary rollout gap** — it reflects a genuine capability mismatch (setup policies' granular pin-ordering/per-group targeting vs. the coarser unified installation model), not an oversight Microsoft is expected to close later. Don't promise a client this exclusion will disappear in a future phase.

- **Global Admin consent is a hard, deliberate gate, not a bug in the wizard.** A Teams Administrator can walk the entire alignment process and still be correctly blocked from the final "Accept and finish" step — recognize this instantly rather than troubleshooting it as a permissions error.

- **MC796790's own revision history is the best evidence that this rollout's dates move.** Cite the specific revision date you checked, not just "per the Message Center," when documenting a timeline decision for a client — the post has already shifted its own completion estimates multiple times since 2024. [MC796790 — Microsoft 365 Message Center Archive](https://mc.merill.net/message/MC796790)

- **There is no documented rollback from unification.** Treat the Phase 2 wizard's org-wide default alignment decision as consequential and worth deliberate cross-team input before a Global Admin clicks "Accept and finish" — this is unlike most Teams/M365 admin settings, which can typically be reverted with another portal change.

- **The "Popular apps in your org" widget is a genuinely new capability unlocked BY unification**, not a pre-existing feature relocated — it depends architecturally on having one authoritative, cross-surface usage dataset (via the `Ideas` API) rather than two potentially-divergent per-portal datasets, which is a good concrete example to give a client asking "what do we actually gain" beyond configuration-consistency.
