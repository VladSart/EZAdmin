# Unified Security Operations Platform (Sentinel + Defender XDR) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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

The **unified security operations platform** is Microsoft's convergence of Microsoft Sentinel (SIEM) and Microsoft Defender XDR (extended detection and response across endpoint/identity/email/cloud apps) into a single Defender portal (security.microsoft.com) experience — shared incident queue, shared advanced hunting across Sentinel and Defender XDR tables, and shared automation. This topic covers the **onboarding/connection layer** (how a Sentinel workspace gets connected to the Defender portal, the primary/secondary workspace model, the permission gates, and what changes structurally once connected) — it does not replace the existing per-feature Sentinel runbooks in this folder (`DataConnectors-A.md`, `AnalyticsRules-A.md`, etc.), which remain accurate for day-to-day operation of Sentinel itself, whether accessed via the Azure portal or the Defender portal.

This is **not** the same as:
- Ordinary Sentinel data connector health (see `DataConnectors-A.md`) — this topic is about the *portal-level* integration, not individual connector troubleshooting.
- Sentinel analytics rule tuning (see `AnalyticsRules-A.md`) — though onboarding changes which underlying tables some rules should query, covered here as a migration consideration, not rule-authoring mechanics.
- Defender XDR product health itself (MDE/MDA/MDI sensor status — see `Security/Defender/`) — onboarding assumes those products are already healthy; it changes how their *alerts get correlated*, not their own detection engines.

Assumes: a Microsoft Entra tenant with at least one Log Analytics workspace running Microsoft Sentinel, and (for full unified security operations, not just "Sentinel in the Defender portal" alone) a Microsoft Defender XDR license.

---
## How It Works

<details><summary>Full architecture</summary>

**Two separate value propositions, often conflated.** "Microsoft Sentinel in the Defender portal" is available generally — including for customers **without** Defender XDR or an E5 license; a tenant can run Sentinel entirely inside the Defender portal UI purely as a SIEM, with no Defender XDR data in the mix. "Unified security operations" specifically means a tenant that has **both** Sentinel connected **and** Defender XDR licensed/enabled, at which point Defender XDR alert/incident data and Sentinel data correlate together in one incident queue with shared advanced hunting. Getting these two concepts confused is a common source of "why don't I see Defender incidents in my Sentinel workspace" confusion — the answer is usually "because this tenant only did the first half."

**Onboarding mechanics.** Connection happens from the Defender portal itself: **System → Settings → Microsoft Sentinel → Connect a workspace** → select workspace(s) → designate the **primary workspace** → review and accept the listed product changes → **Connect**. Since **July 1, 2025**, new Sentinel workspace creations are automatically onboarded to the Defender portal as part of provisioning — manual onboarding via this flow is now primarily relevant for pre-existing workspaces that haven't yet been connected.

**Permission model — two distinct gates.** Onboarding requires:
1. At least **Security Administrator** in Microsoft Entra ID, **and**
2. Either **Owner** (an **unconditional** role assignment at subscription scope — a conditional/ABAC-scoped Owner assignment does not satisfy this requirement, even though it displays as "Owner" in the role list) **or** **User Access Administrator** + **Microsoft Sentinel Contributor**.

If a tenant has more than one Sentinel-enabled workspace, the onboarding account must also independently hold at least Security Administrator in Entra ID regardless of which specific combination of Azure roles it holds. After initial connection, day-to-day RBAC continues to be managed via ordinary Azure RBAC on the Sentinel workspace — Defender portal access simply reflects whatever Azure RBAC already grants, it does not introduce a parallel permission system for ongoing use (unlike, notably, the Sentinel data lake feature elsewhere in this folder, which does introduce an independent Entra ID directory-role system — do not confuse the two).

**Primary vs. secondary workspace — the core architectural decision.** The Defender portal supports exactly **one primary workspace** per tenant and an unlimited number of **secondary** workspaces:

- **Primary**: receives Defender XDR alert/incident correlation. Incidents from the primary workspace and from Defender XDR merge into one unified queue. The Defender XDR data connector is connected to the primary workspace only, and only one workspace can hold this connection at a time.
- **Secondary**: Sentinel-only in the Defender portal experience — no Defender XDR incidents/alerts sync to it, and it continues to operate autonomously (useful for MSSP/global-SOC scenarios where subsidiary or client workspaces should remain isolated from the parent tenant's unified queue, or where an org deliberately wants some workspaces excluded from the primary correlation view).

Switching the primary workspace is supported at any time (**System → Settings → Microsoft Sentinel → Workspaces** → select new primary → **Set as primary**), but the Defender XDR connector **automatically moves** — disconnecting from the old primary and connecting to the new one — the instant the switch completes. Anything on the old primary that depended on live Defender XDR-correlated data goes stale immediately.

**Standalone connector auto-disconnection.** To prevent duplicate, conflicting ingestion of the same underlying alerts once Defender XDR data starts flowing through the unified pipeline, onboarding a primary workspace **automatically disconnects** five standalone data connectors if they were active: Microsoft Defender for Office 365, Microsoft Entra ID Protection, Microsoft Defender for Cloud Apps, Microsoft Defender for Endpoint, and Microsoft Defender for Identity. Their alerts become **tenant-based** (surfacing through the unified Defender XDR pipeline into the primary workspace) rather than workspace-specific standalone-connector alerts. Any custom analytics rule or automation rule written against the old standalone connector's raw ingestion tables needs to be re-evaluated — the underlying data model shifted even though the alerts conceptually still "arrive."

**Two additional service-specific prerequisites, easy to miss:**
- **Microsoft Purview Insider Risk Management**: if in use, the **Microsoft 365 Insider Risk Management** data connector must be enabled on the primary workspace *before* onboarding (install the IRM solution from Content hub, configure the connector) — and explicitly disabled on any secondary workspace being onboarded, to avoid duplicate IRM alert delivery. IRM alerts correlate to the primary workspace only.
- **Microsoft Defender for Cloud**: to get tenant-wide, cross-subscription correlated Defender for Cloud incidents in the primary workspace, connect the **Tenant-based Microsoft Defender for Cloud (Preview)** connector there, and **disconnect** the legacy **Subscription-based Microsoft Defender for Cloud (Legacy)** alerts connector from every workspace in the tenant. Leaving both active risks duplicate/conflicting alert delivery.

**Bi-directional sync — primary vs. secondary differ.** For the **primary** workspace, Defender XDR incidents appear in the Azure-portal Sentinel experience under provider name "Microsoft XDR," and status/closing-reason/assignment changes made in *either* the Azure portal or the Defender portal sync to the other. For **secondary** workspaces, sync is purely workspace-to-workspace between the two portals — there is no Defender XDR cross-sync involved, since secondary workspaces never receive Defender XDR data in the first place.

**The explicit, permanent Lighthouse/GDAP gap.** Granular delegated admin privileges (GDAP) via Azure Lighthouse — the standard MSSP multi-tenant delegation mechanism (see `Azure/Lighthouse/`) — is **not supported** for Sentinel data in the Defender portal. Microsoft's documented workaround is Microsoft Entra B2B guest access instead. This is a real, current architectural gap for MSSPs already standardized on Lighthouse, not a temporary limitation with an announced fix date, and should be factored into any MSSP's Defender-portal-migration planning alongside the similar documented Lighthouse/Watchlist cross-workspace gap already covered in `Watchlists-A.md`.

**The retirement forcing function.** Microsoft Sentinel in the Azure portal is scheduled for retirement **March 31, 2027**. Combined with the July 1, 2025 auto-onboarding-by-default change for new workspaces, this makes the unified Defender portal the platform's actual long-term direction rather than an optional alternative UI — client conversations about this migration should be framed around timeline planning, not whether to adopt it at all.

</details>

---
## Dependency Stack

```
Microsoft Entra tenant
  └── Log Analytics workspace with Microsoft Sentinel enabled
        └── (auto, if created after Jul 1 2025) OR (manual) onboarding to Defender portal
              ├── Permission gate: Security Administrator (Entra ID) AND
              │     (unconditional Owner OR User Access Administrator + Sentinel Contributor)
              │     at subscription scope
              └── Workspace designated PRIMARY (one per tenant) or SECONDARY (unlimited)
                    ├── PRIMARY only: Defender XDR connector attaches here
                    │     └── Requires: Defender XDR licensing + same-tenant membership
                    │           └── Standalone MDE/MDA/MDI/O365-Defender/EntraIDProtection
                    │               connectors auto-disconnect (tenant-based alerting instead)
                    │                 └── Unified incident queue + shared advanced hunting
                    │                       (Defender XDR + Sentinel data together)
                    └── SECONDARY: Sentinel-only Defender-portal experience, no XDR sync,
                          continues operating autonomously (MSSP/global-SOC isolation use case)
  └── (permanent, current gap) Azure Lighthouse/GDAP NOT supported for this data —
        Entra ID B2B required instead for cross-tenant MSSP access
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Onboarding button fails/errors despite Owner role shown | Owner assignment is conditional (ABAC), not unconditional | Azure IAM role assignment Condition column |
| Defender incidents don't appear even though Sentinel is "connected" | Workspace connected as Sentinel-only (no Defender XDR license), or connected as a secondary workspace | Confirm Defender XDR licensing and primary/secondary designation |
| Custom analytics rule for MDE/MDI/etc. stopped firing post-onboarding | Standalone connector auto-disconnected; rule still points at the old ingestion table | Re-point rule to unified pipeline data |
| Duplicate Defender for Cloud alerts | Both Tenant-based (Preview) and Subscription-based (Legacy) connectors active simultaneously | Disconnect the legacy connector tenant-wide |
| IRM alerts missing from primary workspace after onboarding | IRM connector wasn't configured on primary before onboarding | Configure/re-verify per Remediation Playbook 2 |
| MSSP Lighthouse session can't see Sentinel/Defender data | Documented unsupported combination | Switch to Entra ID B2B guest access |
| Rules/automation on the "old" primary suddenly went stale | Primary workspace was recently switched — Defender XDR connector auto-moved | Confirm current primary designation, re-point dependencies |

---
## Validation Steps

1. **Confirm onboarding + primary/secondary state.** Defender portal → System → Settings → Microsoft Sentinel → Workspaces. Good: exactly one Primary, others correctly Secondary as intended. Bad: no primary designated, or the wrong workspace holds primary for the intended use case.

2. **Confirm the permission model for whoever will manage onboarding/changes.** Azure IAM on the subscription: unconditional Owner, or User Access Administrator + Sentinel Contributor, plus Entra ID Security Administrator. Good: at least one admin unambiguously satisfies this. Bad: only conditional-Owner accounts exist — onboarding/primary-switch operations will fail for everyone until this is fixed.

3. **Confirm standalone connector disconnection took effect cleanly.** Sentinel (Azure portal) on the primary workspace → Data connectors → check MDE/MDA/MDI/Defender for O365/Entra ID Protection status. Good: cleanly auto-disconnected, tenant-based alerting active. Bad: connector shows an ambiguous/error state — may need manual disconnect-and-confirm.

4. **Confirm service-specific prerequisites (IRM, Defender for Cloud) match the documented pre/post-onboarding requirements** if those services are in use — these are easy to miss because they're prerequisites *before* onboarding, not settings to fix after the fact (IRM in particular should be configured pre-onboarding).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Permission verification.** Validation Steps 1–2, before attempting any onboarding or primary-workspace change — this resolves the majority of "onboarding won't work" tickets.

**Phase 2 — Post-onboarding data-continuity check.** Validation Steps 3–4, run once as part of onboarding closure and again any time a rule/automation "mysteriously" stops firing shortly after an onboarding or primary-switch event.

**Phase 3 — MSSP access-model review.** If Lighthouse/GDAP is in play, confirm this up front as a known limitation rather than debugging it as a support ticket (Remediation Playbook 3).

**Phase 4 — Timeline planning.** For tenants still fully on the Azure-portal Sentinel experience, treat the March 31, 2027 retirement date as a planning input, not an emergency — but don't let it slip unaddressed either.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield onboarding for a single-workspace tenant</summary>

1. Confirm prerequisites: Log Analytics workspace with Sentinel enabled; account with Entra ID Security Administrator + unconditional Owner (or User Access Administrator + Sentinel Contributor) at subscription scope.
2. If Microsoft Purview Insider Risk Management is in use, configure its connector on this workspace **first** (it will become primary by default as the only workspace).
3. If Microsoft Defender for Cloud is in use, plan the Tenant-based (Preview) vs. Subscription-based (Legacy) connector switch as part of the same change.
4. Defender portal → System → Settings → Microsoft Sentinel → Connect a workspace → select the workspace → it is automatically the primary (only one workspace) → review product changes → Connect.
5. Post-connect: verify standalone connectors auto-disconnected cleanly (Validation Step 3), and re-point any custom rules that referenced their old tables.

</details>

<details><summary>Playbook 2 — Multi-workspace / MSSP-style tenant with primary + secondary design</summary>

1. Decide deliberately which workspace should be primary — typically the central/global SOC workspace, not a subsidiary or client-isolated one.
2. Onboard the primary first (Playbook 1 steps), then connect additional workspaces as secondary via the same "Connect a workspace" flow, explicitly selecting them as secondary rather than attempting to promote each to primary.
3. Confirm secondary workspaces are NOT expected to show Defender XDR incidents — this is correct, isolated behavior, not a defect, and is the basis for keeping subsidiary/client data out of the global SOC's unified queue when desired.
4. For any workspace requiring true cross-tenant delegated access by an MSSP analyst, set up Entra ID B2B guest access rather than relying on existing Lighthouse/GDAP delegation, which does not extend to this data.

</details>

<details><summary>Playbook 3 — Migrating an MSSP off a Lighthouse-only access model for this specific integration</summary>

1. Inventory which analysts currently rely on Lighthouse/GDAP-delegated sessions specifically for Sentinel-in-Defender-portal access.
2. Provision Entra ID B2B guest accounts in each client tenant for those analysts, with appropriate Sentinel/Security roles.
3. Retain Lighthouse/GDAP for everything else it still legitimately covers (general Azure resource management) — this is a scoped gap, not a reason to abandon Lighthouse as an MSSP delegation strategy overall.
4. Document this exception clearly for the team, since it's a common point of confusion — "we have Lighthouse access" does not imply "we can see this client's unified incidents."

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Collects unified security operations onboarding/state evidence for
          escalation or migration-planning documentation.
#>
Connect-AzAccount
$sub = Get-AzSubscription  # confirm target subscription context

# Owner role assignments and their condition state — the #1 onboarding blocker to verify
Get-AzRoleAssignment | Where-Object { $_.RoleDefinitionName -eq 'Owner' } |
    Select-Object DisplayName, SignInName, RoleDefinitionName, Scope, Condition

# Sentinel-enabled workspaces in the subscription (cross-reference against Defender
# portal's Workspaces page for primary/secondary designation, which is not exposed
# via this cmdlet — capture that page manually alongside this export)
Get-AzOperationalInsightsWorkspace | ForEach-Object {
    [PSCustomObject]@{
        WorkspaceName = $_.Name
        ResourceGroup = $_.ResourceGroupName
        Location      = $_.Location
    }
} | Export-Csv -Path ".\UnifiedSecOps-Workspaces.csv" -NoTypeInformation

# Standalone connector state on a given workspace (requires the Az.SecurityInsights module)
# Get-AzSentinelDataConnector -ResourceGroupName <rg> -WorkspaceName <ws> |
#     Select-Object Name, Kind, Etag
```

---
## Command Cheat Sheet

```
Portal locations (no PowerShell cmdlet surface for onboarding/primary designation itself):
  Connect/manage workspaces:      security.microsoft.com → System → Settings → Microsoft Sentinel → Workspaces
  Set/change primary workspace:   same page → select workspace → Set as primary
  Offboard a workspace:           same page → select workspace → Disconnect workspace
  Standalone connector status:    Sentinel (Azure portal) → Data connectors (per workspace)
```

```powershell
# Verify Owner role assignment condition (unconditional required for onboarding)
Get-AzRoleAssignment | Where-Object { $_.RoleDefinitionName -eq 'Owner' } | Select DisplayName, Scope, Condition

# Inventory Sentinel-enabled workspaces
Get-AzOperationalInsightsWorkspace
```

---
## 🎓 Learning Pointers

- [Connect Microsoft Sentinel to the Microsoft Defender portal — Microsoft Learn](https://learn.microsoft.com/en-us/unified-secops/microsoft-sentinel-onboard) (updated 2026-08-07) — the authoritative prerequisites, permission model, and onboarding/offboarding steps.
- [Multiple Microsoft Sentinel workspaces in the Defender portal — Microsoft Learn](https://learn.microsoft.com/en-us/azure/sentinel/workspaces-defender-portal) (updated 2026-06-01) — the primary/secondary architecture, permission tables, and bi-directional sync behavior in full detail.
- "Sentinel in the Defender portal" and "unified security operations" are related but distinct claims — the former needs no Defender XDR license at all; the latter is what actually merges Defender XDR and Sentinel incident data. Confirm which one a client actually has before diagnosing a gap.
- The **unconditional Owner** requirement is the most common onboarding blocker in practice — a conditional (ABAC) Owner assignment passes a casual glance at the role list but fails the actual check.
- GDAP/Azure Lighthouse is explicitly unsupported for this specific data path — cross-reference `Azure/Lighthouse/Lighthouse-A.md` before assuming an MSSP delegated-access gap here is a Lighthouse misconfiguration rather than a documented platform boundary.
- March 31, 2027 is the retirement date for Sentinel in the Azure portal — plan client migrations on that horizon, especially for MSSPs whose delegated-access model (Lighthouse) needs a parallel B2B transition for this specific integration.
