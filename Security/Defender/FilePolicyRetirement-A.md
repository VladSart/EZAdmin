# Defender for Cloud Apps File Policy Retirement — Reference Runbook (Mode A: Deep Dive)
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
- [Governance Action Mapping](#governance-action-mapping)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

This runbook covers the retirement of **File policies** inside Microsoft Defender for Cloud Apps (MDA) — the file-based data-governance mechanism that scans files already at rest in connected apps (SharePoint, OneDrive, and third-party apps such as Box, Dropbox, Google Workspace, and Salesforce) and applies protective actions (quarantine, remove sharing, apply a label) or DLP-style detect-and-respond logic. Microsoft's retirement date is **January 6, 2027**; the replacement surface is split across two Microsoft Purview capabilities — **Purview DLP** (for detect-and-respond file policies) and **Purview auto-labeling policies** (for policies whose only action is applying a sensitivity label).

This is a narrow, migration-focused topic — it is not a general MDA reference. Cloud Discovery (Shadow IT), session policies and access policies (delivered via Conditional Access App Control), and MDA's threat-detection alerting are explicitly **out of scope** for this retirement and are documented in [`MDA-A.md`](MDA-A.md)/[`MDA-B.md`](MDA-B.md).

It is also distinct from `AppGovernance-A.md`/`-B.md` (OAuth-app risk/remediation — a different MDA/Defender XDR feature pillar entirely, sharing only the parent product) and from `Security/Purview/DLP-Policy-A.md` (the general Purview DLP reference this topic hands off to once a file policy has actually been migrated or recreated there — read that topic for ongoing Purview DLP operation, not this one).

**Assumptions:**
- Tenant has at least one active MDA File policy targeting SharePoint, OneDrive, or a connected third-party app
- Reader holds (or is scoping a project that requires) Security Administrator (MDA visibility) and Compliance Administrator (Purview DLP/auto-labeling authoring) — the two roles do not overlap and both are needed across the full migration
- Microsoft 365 E5 / E5 Compliance, or standalone Purview DLP + Information Protection & Governance licensing, is present or being budgeted for
- Reader has basic familiarity with Purview DLP policy structure (locations, conditions, sensitive information types, actions) and sensitivity labels/auto-labeling

---

## How It Works

<details><summary>Full architecture — why this retirement exists and how the migration tool is scoped</summary>

### Why Microsoft is retiring File policies

MDA File policies were built as a CASB (Cloud Access Security Broker) capability: an API-based connector scans files already stored in a connected app and applies governance actions based on content inspection. Microsoft Purview has since built out its own, deeper content-classification and DLP engine (the same Data Classification Service that MDA's file inspection already relied on under the hood) with wider location coverage (Exchange, Teams, endpoint, on-premises repositories via the DLP scanner) and a single, unified policy authoring surface. Retiring File policies collapses two overlapping content-governance engines into one, rather than maintaining parallel DLP logic in both products indefinitely.

### The migration tool's actual scope — narrower than "migrate everything"

The DLP to Purview migration tool (Defender portal → Cloud apps → Policies → Policy management → retirement banner → Migrate) is scoped to a specific subset of the total File policy population:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    All existing MDA File policies                    │
│                                                                        │
│  ┌──────────────────────────────┐  ┌───────────────────────────────┐ │
│  │  SharePoint / OneDrive        │  │  Non-Microsoft apps            │ │
│  │  (Microsoft-owned locations)  │  │  (Box/Dropbox/GWorkspace/SF)   │ │
│  │                                │  │                                 │ │
│  │  ┌──────────────┐ ┌─────────┐ │  │   Preview, phased rollout —    │ │
│  │  │ DLP detect-  │ │ Auto-   │ │  │   migration tool does NOT      │ │
│  │  │ and-respond  │ │ labeling│ │  │   cover these; manual          │ │
│  │  │              │ │         │ │  │   recreation required          │ │
│  │  │  MIGRATED    │ │ NOT     │ │  │   (Fix 4 in companion -B.md)   │ │
│  │  │  by tool     │ │ migrated│ │  │                                 │ │
│  │  │  (Can/       │ │ by tool │ │  │                                 │ │
│  │  │  Partial/    │ │ (manual │ │  │                                 │ │
│  │  │  Cannot)     │ │ only)   │ │  │                                 │ │
│  │  └──────────────┘ └─────────┘ │  │                                 │ │
│  └──────────────────────────────┘  └───────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

Only the top-left quadrant — SharePoint/OneDrive, DLP detect-and-respond policies — gets fully automated tooling. Every other quadrant requires manual recreation, which is the single most common source of underestimated migration-project scope: a client hearing "there's a migration tool" reasonably assumes full coverage, and the gap only surfaces once the wizard's per-policy verdicts are actually reviewed.

### The three-way verdict and what drives each

When the migration tool ingests a SharePoint/OneDrive DLP file policy, it classifies it into one of three verdicts before you select anything to run:

- **Can migrate** — every condition and action in the original policy has a direct Purview DLP equivalent; the tool generates a complete, functionally-equivalent Purview policy payload.
- **Partial migration** — most of the policy maps cleanly, but at least one condition or action has no direct equivalent (commonly: certain governance actions with no Purview counterpart, or content-match conditions built on MDA-specific inspection methods). The tool migrates what it can and flags the gap in that policy's Notes for manual completion.
- **Cannot migrate** — the policy's core logic (not just an edge-case action) has no reasonable Purview mapping; the tool does not attempt a partial payload and the policy must be recreated from scratch.

Expanding each policy's Notes before running the wizard is not optional busywork — it's the only place the specific gap is documented, and it's what Fix 2 in the companion `-B.md` and this document's Governance Action Mapping table below are used to resolve.

### Why migrated policies always land in Test with notifications mode

The tool intentionally never activates enforcement on a freshly created policy. This is a deliberate safety choice, not a limitation: MDA and Purview evaluate content independently and can disagree on matches (different classification timing, different scan triggers), so an untested "hot" migration could silently change what gets blocked the moment it's created. Every migrated policy requires a human decision to move from Test with notifications to On, informed by a comparison against the original policy's real match history.

### Why the old and new policies cannot both enforce indefinitely

MDA File policies and Purview DLP policies are two independent enforcement engines evaluating the same content. Running both in enforcing mode simultaneously does not "double-protect" — it creates non-deterministic outcomes (which engine's action wins, redundant/conflicting quarantine or label actions, doubled end-user notifications) and makes future troubleshooting materially harder, since two separate audit trails now exist for the same event. The correct sequencing is always: validate the new Purview policy in simulation → pilot enforcement → disable (not delete) the old MDA policy — never a simultaneous cutover.

</details>

---

## Dependency Stack

```
[MDA File policy — legacy, API-based content inspection at rest]
        │
        ▼
[Data Classification Service — the classification engine MDA's file inspection
        and Purview DLP BOTH use; this is why content conditions largely
        translate 1:1 rather than needing to be reinvented]
        │
        ▼
[Retirement clock: announced 2026 → January 6, 2027 hard cutoff]
        │
        ▼
[DLP to Purview migration tool — Defender portal, SharePoint/OneDrive DLP-type
        policies ONLY]
        ├── Can migrate      → automated, full payload
        ├── Partial migration → automated core + manual completion (see
        │                        Governance Action Mapping below)
        └── Cannot migrate   → manual recreation from scratch, Fix 2
        │
        ▼
[New Purview policy created — Test with notifications mode, always]
        │
        ├── DLP detect-and-respond → Purview DLP (Data loss prevention > Policies)
        └── Auto-labeling (NOT migration-tool-covered, ANY location) →
                Purview auto-labeling policy (Information protection > Auto-labeling)
        │
        ▼
[Validation window — simulation vs. original MDA policy's match history]
        │
        ▼
[Enforcement cutover — turn Purview policy On, THEN disable (not delete)
        the original MDA File policy]
        │
        ▼
[Non-Microsoft app (Box/Dropbox/Google Workspace/Salesforce) file policies —
        a SEPARATE, non-tool-covered path requiring an existing MDA app
        connector (reused by Purview, not replaced) and tenant-level
        availability of Purview DLP for non-Microsoft connected apps (preview,
        phased) before any policy work can begin]
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Why do we need to migrate at all" / policy stopped matching files | Retirement is real and date-driven, not a bug | Confirm retirement banner is present; cite Jan 6, 2027 date |
| Migration wizard groups a policy as Cannot migrate | Core policy logic has no Purview equivalent | Expand policy Notes in Step 1 of the wizard for the specific reason |
| Migrated policy shows "Partial migration" and something seems missing | At least one condition/action lacked a direct mapping | Cross-reference the flagged item against Governance Action Mapping below |
| Auto-labeling file policy wasn't touched by the migration tool | Tool does not migrate auto-labeling policies (any location) — "Coming soon" | Confirm policy's only action is applying a label; recreate manually (Fix 3 in `-B.md`) |
| Box/Dropbox/Google Workspace/Salesforce policy wasn't touched | Non-Microsoft apps are entirely out of automated-tool scope | Confirm target app; check Purview preview availability for that app (Fix 4 in `-B.md`) |
| New Purview policy exists but doesn't block/quarantine anything | Migrated policies always start in Test with notifications | Purview portal → policy → Mode field; switch to On once validated |
| Same content gets flagged twice, or conflicting actions occur | Old MDA policy and new Purview policy both still enforcing | Confirm MDA policy state; disable (not delete) once Purview policy is validated |
| Non-Microsoft app doesn't appear as a Purview DLP location option | Purview DLP for non-Microsoft connected apps is still in phased preview rollout | Purview portal → Create policy → check location picker for the app; if absent, not yet available in this tenant |
| Predefined-template Purview policy creation fails for a non-Microsoft app | Predefined templates (Financial/Medical/Privacy) don't support non-Microsoft app locations | Use Custom policy template instead — a hard product constraint, not a misconfiguration |
| Files already at rest aren't getting labeled by the new auto-labeling policy | Auto-labeling only labels new/changed files by default | Run an on-demand classification scan for retroactive coverage |

---

## Validation Steps

**1. Inventory every File policy and confirm its target/type before touching anything**

```
Microsoft Defender portal (security.microsoft.com) > Cloud apps > Policies > Policy management
Filter: Type = "File policy"
```

Expected: a complete list you can cross-reference against the categorization logic above (SharePoint/OneDrive vs. non-Microsoft app; DLP action vs. label action). Do this inventory pass before running the wizard at all — it's the only reliable way to catch policies that will fall into a manual-only category before you're mid-migration.

**2. Confirm the tenant is actually in scope for the retirement banner**

```
Same page — look for: "File policies in Defender for Cloud Apps are retired on
January 6, 2027" with a Migrate button
```

Expected: banner is present if any SharePoint/OneDrive DLP-type file policy exists. Its absence with file policies still configured is unusual — treat as a portal/permissions issue (confirm Security Administrator role) before assuming the tenant is somehow exempt.

**3. Run the migration wizard's Step 1 grouping without executing anything yet**

Open Migrate, let Step 1 group every selected policy, and expand Notes on every **Partial migration** and **Cannot migrate** row. Expected: a specific, named reason per policy — generic "unsupported" text without detail should be treated as a signal to test that migration manually rather than trust the tool's payload.

**4. Confirm the created Purview policy's mode before reporting migration as complete**

```
Microsoft Purview portal (purview.microsoft.com) > Data loss prevention > Policies >
[Migrated] <original name> (1P DLP)
```

Expected: Mode = **Test with notifications**. A migrated policy showing **On** immediately after the wizard finishes would be unexpected — re-confirm you're looking at the right policy, since this is not documented default wizard behavior.

**5. Confirm match parity before enforcing**

```
Purview portal > Data loss prevention > Activity explorer > filter by the migrated policy name
```

Compare match volume and match content against the original MDA file policy's own activity log for the same content over a comparable time window. Expected: broadly consistent match behavior. A significant divergence (either direction) means the condition mapping needs review before enforcement — Purview's classification engine is the same underlying service, but condition-to-condition translation is not guaranteed lossless, especially for Partial migration policies.

**6. Confirm safe cutover sequencing**

Only after Step 5 shows acceptable parity: switch the Purview policy to On, monitor for a short period, then disable (do not delete) the original MDA File policy. Expected end state: Purview policy On, MDA policy present-but-disabled, both retained for audit history until well past confidence is established.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Inventory and categorize**
1. Full File policy inventory (Validation Step 1)
2. Categorize by location (SharePoint/OneDrive vs. non-Microsoft app) and action type (DLP detect-and-respond vs. auto-labeling)
3. Flag any policy performing both a DLP action and a labeling action as two separate migration items

**Phase 2 — Run automated migration where eligible**
1. Migration wizard for SharePoint/OneDrive DLP-type policies only (Validation Steps 2-3)
2. Review every Partial/Cannot verdict's Notes before selecting policies to run
3. Cross-reference any flagged gap against the Governance Action Mapping table below

**Phase 3 — Manual recreation for everything outside automated scope**
1. Auto-labeling policies (any location) — Purview Information protection > Auto-labeling
2. Non-Microsoft app policies — confirm preview availability first, Custom template only, Advanced DLP rules required
3. Cannot migrate policies — full manual recreation using the mapping table for governance-action equivalence

**Phase 4 — Validate before enforcing**
1. Confirm Test with notifications mode on every newly created policy (Validation Step 4)
2. Run parity comparison against original MDA activity (Validation Step 5)
3. Resolve any material divergence before proceeding

**Phase 5 — Cutover and retire the original**
1. Switch validated Purview policies to On
2. Disable (not delete) the corresponding MDA File policy
3. Retain both configurations through at least one full audit/compliance cycle before considering deletion of the disabled MDA policy

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full tenant migration project plan (multiple File policies, mixed types)</summary>

1. Complete the full inventory (Phase 1) and produce a categorized list: SharePoint/OneDrive DLP (tool-eligible), SharePoint/OneDrive auto-labeling (manual), non-Microsoft app (manual, preview-gated).
2. Confirm role coverage across the project: Security Administrator (visibility into MDA policies) and Compliance Administrator (Purview authoring) — a single admin may need both, or the work may be split across two people.
3. Run the migration wizard in batches by verdict — do all "Can migrate" policies together first (lowest risk, fastest to validate), then work through "Partial migration" policies individually using the Notes + Governance Action Mapping table.
4. In parallel, begin manual recreation of every auto-labeling and Cannot-migrate policy — these have no tooling dependency and can proceed independently of the wizard batches.
5. For non-Microsoft app policies, confirm preview availability per app before committing migration-project timeline to them; document any app not yet available as an interim coverage gap with a target re-check date.
6. Validate every created policy (Phase 4) before enabling any enforcement.
7. Sequence cutovers so validated policies move to On individually, each followed by disabling its specific MDA source policy — do not do a single "big bang" cutover across all policies at once, since it removes your ability to isolate which specific migrated policy is misbehaving if something goes wrong.
8. Retain all disabled MDA policies until January 6, 2027 at minimum (they stop being evaluated anyway at that date) and through your organization's normal audit-record retention window beyond that.

**Rollback:** Because MDA policies are disabled (not deleted) throughout, any individual step in this playbook can be reversed by re-enabling the specific MDA policy and switching the corresponding Purview policy back to Test with notifications or Off.

</details>

<details><summary>Playbook 2 — Emergency path if migration wasn't started and the retirement date is imminent</summary>

1. Run the automated wizard immediately for every eligible SharePoint/OneDrive DLP policy — this is the fastest path to interim coverage even in Test with notifications mode, since it's better than zero Purview-side coverage on the retirement date.
2. Triage remaining manual-only policies by business risk (e.g., a policy protecting regulated data outranks a low-sensitivity internal-only policy) and recreate the highest-risk ones first.
3. For anything that cannot realistically be recreated before the deadline, document as an accepted interim gap with a named owner and target completion date — do not silently let coverage lapse without a record.
4. After the deadline passes, MDA File policies stop being evaluated automatically — there is no grace period or soft-retirement behavior documented by Microsoft; treat the date as a hard cutoff for planning purposes.
5. Continue completing manual recreations post-deadline in priority order; the compressed timeline changes sequencing, not the underlying validation steps (Test with notifications → parity check → enforce).

**Rollback:** N/A — this is a compressed version of Playbook 1 under time pressure, not a distinct reversible action.

</details>

---

## Governance Action Mapping

Use this table when a policy's Notes flag a specific action or condition as unmapped (Partial/Cannot migrate), or when recreating a policy manually.

| Original MDA File Policy Element | Purview Equivalent | Notes |
|---|---|---|
| Content match (built-in sensitive info types, regex, keyword lists, file type/name) | Sensitive information type / custom SIT / keyword condition in Purview DLP | Same underlying Data Classification Service — direct mapping in nearly all cases; custom regex patterns must be recreated as a custom SIT in Purview first, then referenced |
| Apply a sensitivity label (governance action) | Auto-labeling policy (separate policy type — NOT a DLP action) | Not migrated by the tool for ANY location; always requires manual recreation as its own auto-labeling policy |
| Quarantine file | DLP action: Restrict access / Block access | Direct functional equivalent |
| Remove external sharing / make private | DLP action: Restrict access to specific people, or Remove all sharing | Direct functional equivalent; verify the exact restriction scope matches original intent |
| Notify file owner | DLP policy tip / user notification action | Direct functional equivalent |
| Send alert | DLP incident report / alert configuration | Direct functional equivalent, routes to Purview's own alerting rather than MDA's alert queue |
| Trash / delete file | **No equivalent** | Flag to requesting team — needs Power Automate, retention/deletion policy, or a documented capability gap acceptance |
| Expire shared link | **No equivalent** | Flag to requesting team — needs SharePoint sharing policy configuration or Power Automate as an alternative mechanism |
| Transfer file ownership | **No equivalent** | Flag to requesting team — needs a separate manual or scripted (Graph/PnP PowerShell) process outside Purview DLP entirely |
| Discard/deny access permission changes | Not a Purview DLP concept in the same form | Evaluate whether Restrict access covers the actual business need, or document as a gap |
| Third-party app (Box/Dropbox/Google Workspace/Salesforce) any action | Purview DLP for non-Microsoft connected apps (preview) | Requires existing MDA app connector; Custom policy template only; Advanced DLP rules required; policy tips/user overrides not supported for these locations |

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects the Graph/PnP-readable subset of context for a File Policy
    Retirement migration ticket — Purview DLP policy inventory and mode state.
.DESCRIPTION
    Portal-only data (MDA File policy configuration/inventory, migration wizard
    verdicts and Notes, MDA activity log match history) is NOT retrievable via
    Graph/PowerShell and must be exported manually from the Defender portal
    (Cloud apps > Policies) and attached alongside this output. This script
    covers only the Purview-side state that IS programmatically readable, for
    confirming cutover status across many migrated policies at once.
.NOTES
    Requires the Security & Compliance PowerShell module (Connect-IPPSSession)
    rather than Microsoft Graph — Purview DLP policy cmdlets live there, not
    in Microsoft.Graph.
#>
param(
    [string]$PolicyNameFilter = "*Migrated*"
)

Connect-IPPSSession

Write-Host "=== Purview DLP policies matching '$PolicyNameFilter' ===" -ForegroundColor Cyan
Get-DlpCompliancePolicy | Where-Object { $_.Name -like $PolicyNameFilter } |
    Select-Object Name, Mode, Enabled, Workload, WhenCreated, WhenChanged |
    Sort-Object WhenCreated

Write-Host "`n=== Policies still in Test with notifications (not yet enforcing) ===" -ForegroundColor Yellow
Get-DlpCompliancePolicy | Where-Object { $_.Name -like $PolicyNameFilter -and $_.Mode -ne "Enable" } |
    Select-Object Name, Mode, WhenCreated

Write-Host "`nManually attach: Defender portal File policy inventory export, migration wizard" -ForegroundColor DarkGray
Write-Host "verdict/Notes screenshots per policy, and Activity explorer match-count comparison." -ForegroundColor DarkGray
```

---

## Command Cheat Sheet

```powershell
# Connect to Security & Compliance PowerShell (Purview DLP policy cmdlets live here, not Graph)
Connect-IPPSSession

# List all DLP policies and current mode
Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled, Workload

# Inspect a specific migrated policy's full config
Get-DlpCompliancePolicy -Identity "[Migrated] <original name> (1P DLP)" | Format-List

# Switch a validated policy from Test with notifications to enforcing
Set-DlpCompliancePolicy -Identity "<policy name>" -Mode Enable

# Revert to test mode if a false-positive spike appears post-cutover
Set-DlpCompliancePolicy -Identity "<policy name>" -Mode TestWithNotifications

# List DLP rules for a given policy (actions/conditions)
Get-DlpComplianceRule -Policy "<policy name>" | Format-List Name, Conditions, Actions

# List auto-labeling policies (separate cmdlet family)
Get-AutoSensitivityLabelPolicy | Select-Object Name, Mode, Enabled

# Portal deep links (no Graph/PowerShell equivalent exists for these)
# MDA File policy inventory:  security.microsoft.com/cloudapps > Policies > Policy management
# Migration wizard:           same page > retirement banner > Migrate
# Purview DLP policies:       purview.microsoft.com > Data loss prevention > Policies
# Purview auto-labeling:      purview.microsoft.com > Information protection > Auto-labeling
# Activity explorer:          purview.microsoft.com > Data loss prevention > Activity explorer
```

---

## 🎓 Learning Pointers

- **The retirement date is January 6, 2027 — verify against Microsoft's own Learn page, not third-party MSP blog summaries**, some of which have circulated a December 31, 2026 date. [Migrate file policies to Microsoft Purview](https://learn.microsoft.com/en-us/defender-cloud-apps/migrate-file-policies-to-purview)

- **"There's a migration tool" is not the same as "migration is automated."** The tool covers exactly one quadrant of the full policy population (SharePoint/OneDrive, DLP detect-and-respond). Auto-labeling policies and every non-Microsoft app policy require manual recreation regardless of tool availability — scope migration projects accordingly from the first client conversation, not after the wizard's verdicts come back.

- **Partial migration is a per-policy state, not a percentage** — always expand the Notes for every Partial/Cannot verdict individually rather than assuming the gap is minor. Use the Governance Action Mapping table above to identify genuinely unsupported actions (Trash file, Expire link, Transfer ownership) early, since these need a business decision (accept the gap, or build an alternative mechanism), not just more migration effort.

- **Test with notifications mode on every migrated policy is a deliberate safety default, not an incomplete migration.** Purview's classification engine can behave slightly differently from MDA's on edge-case content even though both use the same underlying Data Classification Service — validate parity via Activity explorer before ever assuming a migrated policy is a like-for-like replacement.

- **Non-Microsoft app coverage in Purview DLP is still a phased preview rollout as of this writing** — don't commit a client migration timeline to a specific app's availability without checking the location picker in that tenant first; Microsoft's own rollout communications lag actual per-tenant availability for preview features, consistent with what this repo has documented for other recent Entra/Defender preview surfaces.

- **Keep the old MDA policy disabled, not deleted, through the full transition.** It costs nothing to leave a disabled policy in place, and it is your only rollback path if a migrated Purview policy's condition mapping turns out to be lossy in a way Activity explorer's short validation window didn't catch.
