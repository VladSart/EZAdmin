# Viva Insights — Reference Runbook (Mode A: Deep Dive)
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
- The dual-model architecture: Personal insights (private, per-user) vs. Organizational insights (admin-configured, aggregated) — how they share a brand but not a data path
- The four-surface admin/access model: Insights Administrator, Insights Analyst, AI Administrator (all real Entra directory roles), and Manager/Group Manager (Viva-native only, not Entra roles)
- Privacy architecture: de-identification, minimum team size vs. minimum group size, Partitions, keyword/domain suppression, domain reclassification
- Personal insights opt-in/opt-out mechanics, including the distinction between the tenant default setting and the End-user opt-out control
- Viva Feature Access Management (VFAM) as the current control surface for the Viva Insights web app, Copilot Dashboard, and Agent Dashboard
- Licensing paths: Microsoft 365 E3/E5 core, standalone Viva Insights add-on/Viva Suite, and Microsoft 365 Copilot license bundling
- GDPR/data-subject-request mechanics as they apply to Viva Insights specifically

**Not in scope (see cross-references):**
- Viva Goals (OKR tracking) — a related-but-distinct Viva module with a materially different admin surface and lower relevance to IT/L2-L3 troubleshooting; not covered here
- Deep Power BI report authoring/DAX inside advanced analysis — covered only to the extent needed to explain analyst role access
- Microsoft 365 Copilot licensing, Conditional Access, and grounding/permission troubleshooting for Copilot itself — see `M365/Copilot/Copilot-A/B.md` (this file covers Viva Insights' own admin/privacy model, including where it intersects with Copilot Dashboard, not Copilot licensing/CA mechanics broadly)
- Microsoft Graph `employeeExperience` API surface — Viva Insights does not expose the same first-party Graph automation surface that Viva Engage does; almost all administration here is web-app/admin-center/VFAM PowerShell, not Graph REST
- Microsoft 365 group-based licensing mechanics — see `M365/Licensing/Group-Based-Licensing-A/B.md`

**Assumed knowledge:**
- Comfortable with the Entra admin center, Microsoft Graph PowerShell SDK, and Exchange Online PowerShell (`ExchangeOnlineManagement` module)
- Understands the general concept of de-identified/aggregated data and minimum-aggregation-threshold privacy patterns
- Has at least Global Reader for read/evidence-collection steps; Insights Administrator, AI Administrator, or Global Administrator for any write action described here

---

## How It Works

<details><summary>Full architecture</summary>

### Two products, one brand

Viva Insights is not one system with a permissions layer — it's two architecturally separate products that happen to share a name and, for licensed-with-Copilot tenants, a bundled license:

1. **Personal insights** — private, individual-facing. Shown through the Viva Insights app in Teams and on the web, the Outlook add-in, inline Outlook suggestions, and (currently paused) Briefing/Digest emails. This data is computed from and stored inside **the employee's own Exchange Online mailbox**. No admin, manager, or analyst surface in the product can read an individual's personal insights data — the only way it becomes visible to anyone else is if the employee independently screenshots or shares it themselves.

2. **Organizational insights** — admin-configured, aggregated, de-identified. This is the Manager/Leader experience (Copilot Dashboard, Agent Dashboard, Consumption Dashboard) and the advanced insights app (analyst tools, custom queries, Power BI templates). This branch is what an Insights Administrator, Insights Analyst, AI Administrator, or enabled Manager interacts with.

The two branches use overlapping raw material (Microsoft 365 collaboration signals: email, calendar, chat, call metadata) but process, store, and expose it completely differently. A support engineer who doesn't establish which branch a ticket belongs to first will frequently investigate the wrong RBAC surface, the wrong portal, and the wrong propagation-delay expectation.

### Personal insights: mailbox data vs. incremental data

Personal insights draws on two categories of data:

- **Mailbox data** — information the employee could already access themselves by going about their job (their own sent mail, their own meeting attendance, their own chat history). Viva Insights just performs the aggregation/calculation work for them (e.g., "how much time did I spend in meetings this week").
- **Incremental data** — de-identified information about *other* people that wouldn't otherwise be available to the employee, most notably **email read rates** and **document open rates**. To prevent this from becoming a surveillance vector, Viva Insights only tracks read rates for messages sent to **5 or more recipients**, and never displays a rate of exactly 0% or 100% — it shows a range instead, specifically so no one can conclude "this specific person did or didn't open my email."

Both categories are computed and stored inside the employee's own mailbox. This is why personal insights data disappears cleanly when a license is removed or a mailbox is deleted — there's no separate central data store to purge.

### Organizational insights: the admin/access model has four surfaces, not one

Unlike a typical Microsoft 365 workload where "who can administer this" is a short list of Entra roles, Viva Insights splits access across four genuinely different mechanisms:

| Surface | Real Entra directory role? | Assigned via | What it grants |
|---|---|---|---|
| **Insights Administrator** | Yes | Entra ID / M365 admin center Role assignments / PIM | Organizational data upload, Privacy settings, Partitions, Manager settings — the full administrative surface |
| **Insights Analyst** | Yes | Entra ID / M365 admin center Role assignments / PIM | Full analyst tools: advanced analysis, custom queries, Power BI templates, automatic Copilot/Agent/Consumption Dashboard access (with global partition scope) |
| **AI Administrator** | Yes | Entra ID / M365 admin center Role assignments / PIM | A newer, Copilot-governance-focused role that can *also* manage most Viva Insights/Copilot Dashboard settings (web app access, Agent Dashboard, exclusion lists, minimum group size) without needing Global Administrator or Insights Administrator — but does **not** grant itself automatic access to the Viva Insights web app (must be separately added) |
| **Manager** | **No** | Viva Insights web app → Manager settings (all managers / Entra security group / uploaded `.csv`) | Team-scoped aggregated insights in Copilot Dashboard and Consumption Dashboard, gated by Minimum team size |
| **Group Manager** | **No** | Viva Insights web app → Manager settings (leader experience) | The "leader" experience — for users with a broader span of control (≥9 licensed users); Viva-native only, never appears in Entra/PIM |

Two consequences follow directly from this split. First, **Global Administrator automatically inherits Insights Administrator privileges** — no separate assignment step is needed, which is a frequent source of "why can this Global Admin already do this" confusion when reviewing a tenant's Insights Administrator membership list and finding it empty despite an admin clearly having access. Second, **Manager and Group Manager will never show up in an Entra role audit** — a script or reviewer that only enumerates `Get-MgDirectoryRoleMember` against Insights Administrator/Analyst/AI Administrator is, by design, blind to who currently has manager-level access; that list only exists inside the Viva Insights web app's own Manager settings page (CSV export or referenced Entra group membership).

### Two aggregation thresholds that are commonly conflated

Viva Insights enforces privacy through **de-identification plus a minimum-aggregation-threshold model**, and there are genuinely two different thresholds involved:

- **Minimum team size** (floor of 5) — gates whether a manager can see *any* organization insights about their team at all. Team size counts the manager plus every direct and indirect report in the reporting hierarchy.
- **Minimum group size** (floor of 5; default of 10 specifically for the Copilot Dashboard's own control on Copilot-only tenants) — gates whether a *specific comparison/data point* within an already-approved view gets suppressed, because too few people are represented to avoid re-identification risk.

These are not the same knob, and — this is the more surprising part — **minimum group size itself has two independent configuration surfaces** depending on whether the tenant holds a Viva Insights license:

- Tenants **without** a Viva Insights license (Copilot-only) set it in the **Microsoft 365 admin center** under Viva Insights → Copilot Dashboard settings (default 10, minimum 5).
- Tenants **with** a Viva Insights license set it inside the **Viva Insights web app's own Privacy settings** page (minimum 5, no platform-stated default — an Insights Administrator or AI Administrator must set it deliberately).

A tenant that transitions from Copilot-only to also holding Viva Insights licenses can end up with two different historical values sitting in two different places, and reconciling them requires knowing both surfaces exist.

### Viva Feature Access Management (VFAM) replaced the old Copilot Dashboard controls

As documented directly by Microsoft (updated as recently as August 13, 2026 — five days before this writing): **"Previous controls to manage access to the dashboard using the Copilot Dashboard control in the Microsoft 365 admin center or using PowerShell are no longer available."** The current and only supported control surface is **Viva Feature Access Management (VFAM)**, exposed through a family of Exchange Online PowerShell cmdlets:

```
Get-VivaModuleFeature              — list features in a Viva module that support access policies
Get-VivaModuleFeaturePolicy        — view existing access policies for a feature
Add-VivaModuleFeaturePolicy        — create a new access policy (tenant/group/user scope)
Update-VivaModuleFeaturePolicy     — modify an existing policy
Remove-VivaModuleFeaturePolicy     — delete a policy
Get-VivaModuleFeatureEnablement    — check whether a feature is enabled for a specific user/group
```

Critically, the `"Viva Insights web app"` feature is now a **single on/off gate for the entire experience** — Copilot Dashboard, Agent Dashboard, Consumption Dashboard, and advanced analysis together. Disabling it for one purpose (say, scoping out Agent Dashboard preview access) disables all four unless a more granular, feature-specific VFAM policy (like `AgentDashboard`) is layered separately on top. Any runbook or internal note still describing a standalone "Copilot Dashboard" toggle in the admin center predates this consolidation and should be treated as stale.

### Personal insights opt-in/opt-out is genuinely two separate controls

This is a recurring source of client miscommunication, so it's worth stating precisely:

1. **Tenant default-on/default-off** — an Insights Administrator setting that determines whether a newly licensed employee is automatically opted into their own personal app/add-in and begins contributing to incremental data immediately ("default on"), or must proactively opt themselves in first ("default off"). This governs whether personal insights processing happens **at all** for a given employee by default.

2. **End-user opt-out** — a separate, always-available, self-service control (Viva Insights app → Settings → Privacy) that a user can toggle regardless of the tenant default. This governs specifically whether the user's **de-identified behavioral metrics** (their contribution to incremental data used in row-level Organizational outputs — Power BI reports, person queries) appear in those outputs going forward. It does **not** disable the user's own personal insights experience, and it explicitly does **not** apply to Microsoft 365 Copilot usage data, which remains visible at the row level regardless of this setting.

Conflating these two in a client conversation about privacy commitments is an easy and consequential mistake — "the user opted out" can mean either "they never contributed at all" or "their own experience is unaffected but their de-identified data stopped flowing into organizational reports," and those are materially different guarantees.

### Licensing paths

- **Microsoft 365 E3/E5** — includes Personal insights as a core service plan. Organizational insights (manager/leader access, advanced analysis) requires an additional Viva Insights add-on or Viva Suite license.
- **Microsoft 365 Copilot license** — since approximately March 2025, bundles both Personal insights **and** Organizational insights automatically for anyone holding a Copilot license, without requiring a separate Viva Insights license.
- **Standalone Viva Insights add-on / Viva Suite** — grants Organizational insights (manager/leader, advanced analysis) independent of Copilot licensing.

A Viva Insights service plan is automatically applied whenever a Global Administrator assigns either a Viva Insights license or a Microsoft 365 Copilot license — there's no separate manual service-plan-enablement step required beyond the license assignment itself.

### GDPR and data subject rights

Because personal insights data lives in each employee's own mailbox, most GDPR mechanics map cleanly onto existing Exchange Online obligations:

- **Exclusion from processing** — simply don't assign a Viva Insights-enabled license (or opt the user out — see above).
- **Access** — the user can view their own insights in the app; there's no separate bulk-export API, so a DSR access request is fulfilled by the employee reviewing their own app/screenshotting it.
- **Deletion** — removing the user from Entra ID removes all their data within 30 days by default; a permanent, immediate deletion is available via the standard Entra ID hard-delete flow for urgent DSRs.

</details>

---

## Dependency Stack

```
Entra ID tenant
    └── M365 license
        ├── E3/E5 (Personal insights core only)
        ├── Standalone Viva Insights add-on / Viva Suite (adds Organizational
        │    insights without Copilot)
        └── Microsoft 365 Copilot license (bundles Personal + Organizational
             insights automatically, since ~March 2025)
            │
            ├── PERSONAL INSIGHTS
            │       └── Tenant default-on/off (Insights Administrator-set)
            │           └── Processed/stored in employee's own Exchange
            │               Online mailbox — no admin/analyst visibility
            │               └── End-user opt-out (separate, self-service;
            │                   governs row-level de-identified data only;
            │                   never applies to Copilot usage data)
            │
            └── ORGANIZATIONAL INSIGHTS
                    └── Viva Insights web app (VFAM-gated single on/off
                        surface — Copilot Dashboard + Agent Dashboard +
                        Consumption Dashboard + advanced analysis together)
                        └── Gradual >50-Copilot-license tenant rollout gate
                            └── Admin role model (4 surfaces):
                                Insights Administrator / Insights Analyst /
                                AI Administrator (all true Entra roles) +
                                Manager / Group Manager (Viva-native only,
                                never in Entra/PIM)
                                └── Minimum team size (≥5) — gates manager
                                    access entirely
                                    └── Minimum group size (≥5, default 10
                                        for Copilot-only tenants; TWO
                                        separate config surfaces by license
                                        state) — gates individual data-point
                                        suppression
                                        └── Privacy settings: Partitions
                                            (one-way), keyword suppression,
                                            domain suppression, domain
                                            reclassification (all ≤7-day
                                            propagation)
                                            └── Copilot Dashboard / Agent
                                                Dashboard (public preview) /
                                                Consumption Dashboard /
                                                Advanced analysis (Power BI
                                                templates, custom queries)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| End user can't find their personal Viva Insights data / app | Tenant default-off setting requires self-opt-in, or license not yet propagated | Confirm tenant default setting + license assignment; this is the Personal branch, not an RBAC issue |
| Manager reports zero team insights despite being enabled | Team size below the tenant's Minimum team size (floor 5) | Manager hierarchy search in the Viva Insights web app (no PowerShell equivalent) |
| "Insights Admin"/"Group Manager" role can't be found in Entra/PIM | Manager and Group Manager are not Entra roles at all | Cross-check against the 4-surface role table in How It Works |
| Copilot Dashboard access configured via an old admin-center toggle no longer works | That control is retired; VFAM (`Get/Add/Update/Remove-VivaModuleFeaturePolicy`) is now the only supported path | `Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app"` |
| Minimum group size shows a different number than expected | Two independent settings exist, split by whether the tenant holds a Viva Insights license | Confirm license state, then check the matching one of the two config surfaces |
| A setting was changed and the dashboard hasn't updated | Propagation delay not yet elapsed (ranges 1 hour to 7 days depending on setting) | Cross-reference the delay table in `VivaInsights-B.md` Fix 6 |
| Partitions can't be turned back off | Genuinely one-way; no self-service reversal exists | Confirm with Microsoft Support, not further portal searching |
| AI Administrator assigned but can't open the Viva Insights web app | Role does not grant automatic web-app access; must be separately added | `Get-MgDirectoryRoleMember` for AI Administrator, then check VFAM user/group access list |
| Agent Dashboard missing entirely | Still public preview; requires both the web app control and its own separate VFAM control enabled | `Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "AgentDashboard"` |
| A user's opted-out but their Copilot usage still shows in reports | Expected — End-user opt-out never applies to Copilot usage data | Confirm this is Copilot usage data, not behavioral collaboration metrics, before treating as a bug |

---

## Validation Steps

**Step 1 — Confirm which branch the ticket belongs to**
There's no command for this — it's a triage judgment call. A ticket about "my own insights/digest/app" is Personal. A ticket about "a manager/analyst/dashboard" is Organizational. Getting this wrong before investigating wastes the rest of the validation flow.

---

**Step 2 — Confirm Entra-native role membership**
```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
foreach ($roleName in @("Insights Administrator","Insights Analyst","AI Administrator")) {
    $role = Get-MgDirectoryRole -Filter "DisplayName eq '$roleName'"
    if ($role) {
        Write-Host "--- $roleName ---"
        Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id |
            Select-Object Id, AdditionalProperties
    } else {
        Write-Host "$roleName role not yet activated in this tenant."
    }
}
```
*Good:* Membership matches what the ticket/client expects.
*Bad:* Empty result for a user "definitely" holding Manager or Group Manager — those are never Entra roles; confirm in the Viva Insights web app's Manager settings instead.

---

**Step 3 — Confirm VFAM state for the Viva Insights web app**
```powershell
Connect-ExchangeOnline
Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app"
```
*Good:* A policy exists and reflects the intended tenant/group/user scope.
*Bad:* No policy found, or `IsFeatureEnabled = $false` for a user who should have access — check whether this is a tenant-wide default or a scoped override.

---

**Step 4 — Confirm Agent Dashboard's independent control (if relevant)**
```powershell
Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "AgentDashboard"
```
*Good:* Enabled where expected, understanding this is still a public-preview feature.
*Bad:* Disabled, or no policy at all — confirm the tenant is even in the gradual preview rollout before assuming this is a misconfiguration.

---

**Step 5 — Confirm minimum group size against the correct configuration surface**
```powershell
# No direct Graph/PowerShell read exists for either surface as of this writing.
# Confirm manually against the correct portal path based on license state:
#   No Viva Insights license -> M365 admin center -> Viva Insights ->
#     Copilot Dashboard in Microsoft 365 -> Manage minimum group size
#   Has Viva Insights license -> Viva Insights web app -> Privacy settings ->
#     Minimum group size
```
*Good:* The value matches the client's documented privacy posture, and you've confirmed which of the two surfaces is authoritative for this tenant.
*Bad:* Two different values found because both surfaces were checked without first confirming license state — reconcile which one is actually live, don't assume they should match.

---

## Troubleshooting Steps (by phase)

### Phase 1: Branch Identification
1. Run Validation Step 1 before anything else.
2. For a Personal-branch ticket, confirm license assignment and the tenant default-on/off setting rather than investigating RBAC.
3. For an Organizational-branch ticket, proceed to Phase 2.

### Phase 2: Role/Access Surface Confirmation
1. Run Validation Step 2.
2. Cross-reference the 4-surface table in How It Works to identify the correct assignment mechanism (Entra role vs. Viva Insights web app Manager settings) before searching further.
3. Remember Global Administrator inherits Insights Administrator automatically — don't expect to find a Global Admin explicitly listed in that role's membership.

### Phase 3: Dashboard/Feature Access (VFAM)
1. Run Validation Steps 3 and 4.
2. Confirm whether the issue is the umbrella "Viva Insights web app" control or a feature-specific control layered on top (Agent Dashboard, auto-enablement).
3. If referencing older documentation or a prior internal runbook, confirm it predates the VFAM consolidation before trusting its steps.

### Phase 4: Privacy Threshold Confirmation
1. Run Validation Step 5 for minimum group size; check Minimum team size separately in the Viva Insights web app's Manager settings for manager-visibility tickets.
2. Confirm which of the two minimum-group-size surfaces is authoritative for the tenant's current license state before reconciling a discrepancy.
3. For Partitions-related tickets, confirm the one-way nature of the setting before promising a reversal path exists.

### Phase 5: Propagation and Timing
1. Confirm what was changed and when.
2. Cross-reference against the propagation-delay table (`VivaInsights-B.md` Fix 6) before re-applying or escalating.
3. For organizational data uploads specifically, confirm whether an `EffectiveDate` field was set correctly — a missing or future-dated `EffectiveDate` can add further delay beyond the standard 7 days.

### Phase 6: Opt-In/Opt-Out and GDPR Requests
1. Confirm which of the two opt-out mechanisms (tenant default vs. End-user opt-out) actually applies to the request.
2. For a formal DSR, map the request to the correct mechanism (exclusion = unlicense/opt-out; access = self-service in-app view; deletion = Entra user removal, 30-day default or immediate hard-delete).
3. Document the mechanism used in the client's DSR response — the two opt-out controls carry meaningfully different privacy guarantees and shouldn't be described interchangeably.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Delegate Copilot Dashboard/Viva Insights administration via AI Administrator (least privilege)</summary>

Use when a client wants to delegate Viva Insights/Copilot Dashboard administration without granting Global Administrator or full Insights Administrator.

1. Assign the AI Administrator role to the target user via Entra ID (or PIM, for time-bound/eligible assignment).
2. Confirm the assignment:
   ```powershell
   Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
   $role = Get-MgDirectoryRole -Filter "DisplayName eq 'AI Administrator'"
   Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id
   ```
3. Critical extra step: the AI Administrator does **not** get automatic Viva Insights web app access. Add them explicitly:
   ```powershell
   Connect-ExchangeOnline
   Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app" `
     -Name "EnableAIAdmin-<userAlias>" -Users "<user@contoso.com>" -IsFeatureEnabled $true
   ```
4. Confirm the AI Administrator can now manage Manager settings, minimum group size, exclusion lists, and Agent Dashboard controls — but confirm with the client whether Organizational data upload and full Privacy settings (Partitions, keyword/domain suppression) are also needed, since those remain Insights Administrator-scoped rather than AI Administrator-scoped.
5. Allow 24 hours for the web app access grant to propagate before considering the delegation complete.

**Rollback:**
```powershell
Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app" `
  -Name "DisableAIAdmin-<userAlias>" -Users "<user@contoso.com>" -IsFeatureEnabled $false
```
Then remove the AI Administrator role assignment via Entra ID/PIM if the delegation should be fully reversed.

</details>

---

<details><summary>Playbook 2 — Enable manager/leader access for a defined set of managers</summary>

Use when onboarding a new client tenant's manager-visibility rollout, or expanding an existing one.

1. Confirm current eligible/enabled manager counts in the Viva Insights web app → Manager settings.
2. Set (or confirm) the tenant's Minimum team size — cannot go below 5.
3. Choose an enablement mode deliberately rather than defaulting to "All managers":
   - **All managers** — broadest; every manager meeting the minimum team size gets access.
   - **Entra security group** — recommended for MSP-managed tenants; easiest to audit and adjust via standard group membership changes.
   - **Uploaded `.csv`** — most precise, but requires manual re-upload for every roster change; the tool will surface per-row errors (e.g., invalid email) on upload.
4. Select **Grant managers scoped access to Copilot insights**, and optionally **Grant managers scoped access to Consumption insights** (this second option requires the first to already be enabled).
5. Save changes; allow 1 hour for propagation.
6. Spot-check via Manager hierarchy search for 2-3 representative managers to confirm team size, licensing status, and access all show correctly before declaring the rollout complete.

**Rollback:** Switch back to a narrower enablement mode (remove the group/CSV, or revert from "All managers"), or disable **Grant managers scoped access to Copilot insights** entirely — no underlying data is deleted, only visibility changes.

</details>

---

<details><summary>Playbook 3 — Reconcile minimum group size across the two configuration surfaces</summary>

Use when a client is transitioning from Copilot-only to also holding Viva Insights licenses (or vice versa), and the two group-size values have diverged.

1. Confirm current license state definitively — check whether any users currently hold a Viva Insights service plan (via `Get-MgUserLicenseDetail` for a sample of users, looking for a Viva Insights SKU) versus Copilot-only.
2. Document both current values:
   - M365 admin center → Viva Insights → Copilot Dashboard in Microsoft 365 → Manage minimum group size (Copilot-only surface, default 10)
   - Viva Insights web app → Privacy settings → Minimum group size (Viva-Insights-licensed surface, no stated default)
3. Confirm with the client which value should be authoritative going forward — this is a policy decision, not a technical one; there's no platform mechanism that keeps the two in sync automatically.
4. Update the now-secondary/legacy surface to match, purely for consistency in future audits — understand that only the surface matching the tenant's *current* license state is actually enforced by the platform in real time.
5. Allow 24 hours for the change to take effect; re-verify via the Copilot Dashboard's group-comparison views.

**Rollback:** Revert either value independently through its own portal path — these are privacy thresholds, not destructive changes.

</details>

---

<details><summary>Playbook 4 — Roll out Copilot Dashboard and Agent Dashboard tenant-wide via VFAM, with staged rollback</summary>

Use for a controlled tenant-wide enablement (or a controlled preview rollout of Agent Dashboard specifically).

1. Confirm the tenant meets the eligibility gate for the feature in question (e.g., the gradual >50-Copilot-license rollout for Copilot Dashboard settings management; public-preview opt-in for Agent Dashboard).
2. Enable the umbrella control first:
   ```powershell
   Connect-ExchangeOnline
   Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app" `
     -Name "EnableForAll" -Everyone -IsFeatureEnabled $true
   ```
3. If Agent Dashboard is in scope, layer its own control on top after confirming the client has reviewed the preview data-processing terms:
   ```powershell
   Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "AgentDashboard" `
     -Name "EnableForAll" -Everyone -IsFeatureEnabled $true
   ```
4. Optionally scope the Agent 365 Dashboard's reporting to exclude non-public (org/user-created) agents if the client wants to see only Microsoft/third-party-published agents:
   ```powershell
   Add-VivaModuleFeaturePolicy -ModuleId VivaInsights `
     -FeatureId "Agent365DashboardNonPublicAgentsVisibility" `
     -Name "ExcludeNonPublicAgents" -Everyone -IsFeatureEnabled $false
   ```
5. Verify all applied policies:
   ```powershell
   Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app"
   Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "AgentDashboard"
   ```
6. Allow 24 hours before declaring the rollout complete; re-check with a small pilot group of users first if the client prefers a staged rollout over tenant-wide `-Everyone`.

**Rollback:** Reverse each `Add-VivaModuleFeaturePolicy` call with the equivalent `-IsFeatureEnabled $false` policy (as shown in `VivaInsights-B.md` Fix 3 and Fix 9), or remove the policy outright:
```powershell
Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "AgentDashboard" |
    Remove-VivaModuleFeaturePolicy
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Viva Insights admin/access evidence collector.
.DESCRIPTION Read-only. Collects Entra-native role membership (Insights
             Administrator, Insights Analyst, AI Administrator), current VFAM
             policy state for the Viva Insights web app and Agent Dashboard,
             and license-plan evidence for a specific user — the evidence
             needed for role-confusion, dashboard-access, and licensing
             tickets.
.PARAMETER   UserUpn   UPN of a specific affected user (optional; skips
             user-scoped checks if omitted).
.EXAMPLE     .\Get-VivaInsightsEvidence.ps1 -UserUpn user@contoso.com
.NOTES       Requires Microsoft.Graph and ExchangeOnlineManagement modules.
             No pwsh available in this authoring environment to execute-test
             directly — reviewed manually for cmdlet/parameter correctness
             against current Microsoft Graph PowerShell SDK and Exchange
             Online PowerShell documentation.
#>
[CmdletBinding()]
param(
    [string]$UserUpn
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All" -NoWelcome
Connect-ExchangeOnline -ShowBanner:$false

$outPath = "$env:TEMP\VivaInsights-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine("=== VIVA INSIGHTS EVIDENCE PACK ===")
$null = $sb.AppendLine("Collected: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC")
$null = $sb.AppendLine("")

# 1. Entra-native role membership
Write-Status "Checking Entra-native Viva Insights role membership..."
$null = $sb.AppendLine("--- Entra-Native Roles ---")
foreach ($roleName in @("Insights Administrator","Insights Analyst","AI Administrator")) {
    $role = Get-MgDirectoryRole -Filter "DisplayName eq '$roleName'" -ErrorAction SilentlyContinue
    if (-not $role) {
        $null = $sb.AppendLine("$roleName : role not activated in this tenant")
        continue
    }
    $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id
    $null = $sb.AppendLine("$roleName members:")
    if ($members.Count -eq 0) {
        $null = $sb.AppendLine("  (no direct members — check whether Global Administrator inherits this implicitly)")
    }
    foreach ($m in $members) {
        $upn = ""
        if ($m.AdditionalProperties.ContainsKey("userPrincipalName")) { $upn = $m.AdditionalProperties["userPrincipalName"] }
        $null = $sb.AppendLine("  - $upn")
    }
}
$null = $sb.AppendLine("Reminder: Manager and Group Manager are NOT Entra roles and will never appear above.")
$null = $sb.AppendLine("")

# 2. VFAM state for the Viva Insights web app and Agent Dashboard
Write-Status "Checking VFAM policy state..."
$null = $sb.AppendLine("--- VFAM Policies ---")
foreach ($featureId in @("Viva Insights web app","AgentDashboard")) {
    try {
        $policies = Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId $featureId -ErrorAction Stop
        $null = $sb.AppendLine("Feature: $featureId")
        if ($policies) {
            foreach ($p in $policies) {
                $null = $sb.AppendLine("  Policy: $($p.Name) | Enabled: $($p.IsFeatureEnabled) | Scope: $($p.Everyone)")
            }
        } else {
            $null = $sb.AppendLine("  No explicit policy found — platform default applies.")
        }
    } catch {
        $null = $sb.AppendLine("Feature: $featureId - NOT COLLECTED (error: $($_.Exception.Message))")
        Write-Status "Could not read VFAM policy for '$featureId': $($_.Exception.Message)" "WARN"
    }
}
$null = $sb.AppendLine("")

# 3. User-scoped checks (optional)
if ($UserUpn) {
    Write-Status "Checking user-scoped evidence for $UserUpn..."
    $null = $sb.AppendLine("--- User: $UserUpn ---")
    try {
        $user = Get-MgUser -UserId $UserUpn
        $licenses = Get-MgUserLicenseDetail -UserId $user.Id
        $null = $sb.AppendLine("Licenses:")
        foreach ($lic in $licenses) {
            $null = $sb.AppendLine("  - $($lic.SkuPartNumber)")
        }
        $null = $sb.AppendLine("Reminder: no Graph/PowerShell read exists for Manager/Group Manager enablement or")
        $null = $sb.AppendLine("team size — confirm those directly in the Viva Insights web app Manager settings.")
    } catch {
        $null = $sb.AppendLine("Error collecting user-scoped evidence: $($_.Exception.Message)")
        Write-Status "Error collecting user-scoped evidence: $($_.Exception.Message)" "ERROR"
    }
    $null = $sb.AppendLine("")
}

$null = $sb.AppendLine("--- Manual Evidence To Attach ---")
$null = $sb.AppendLine("1. Screenshot of Manager hierarchy search result (team size, licensed team size)")
$null = $sb.AppendLine("2. Screenshot of the current Minimum group size value from BOTH configuration surfaces")
$null = $sb.AppendLine("3. Screenshot of the exact error/blank dashboard state")
$null = $sb.AppendLine("4. Timestamp of the last relevant setting change, for propagation-delay cross-reference")

$sb.ToString() | Out-File $outPath -Encoding UTF8
Write-Status "Evidence written to: $outPath" "OK"
notepad $outPath
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|---------|
| Check Insights Administrator/Analyst/AI Administrator membership | `Get-MgDirectoryRole -Filter "DisplayName eq '<role>'" \| Get-MgDirectoryRoleMember` |
| Check VFAM state for the Viva Insights web app | `Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app"` |
| Check VFAM state for Agent Dashboard | `Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "AgentDashboard"` |
| List all Viva Insights features that support VFAM policies | `Get-VivaModuleFeature -ModuleId VivaInsights` |
| Check whether a feature is enabled for a specific user | `Get-VivaModuleFeatureEnablement -ModuleId VivaInsights -FeatureId "<feature>" -UserId <upn>` |
| Enable the Viva Insights web app tenant-wide | `Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app" -Everyone -IsFeatureEnabled $true` |
| Disable the Viva Insights web app tenant-wide | `Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app" -Everyone -IsFeatureEnabled $false` |
| Remove a VFAM policy | `Remove-VivaModuleFeaturePolicy` (pipe from `Get-VivaModuleFeaturePolicy`) |
| Toggle a narrow personal-insights feature (Headspace / Meeting Effectiveness Survey preview) for one user | `Set-VivaInsightsSettings -Identity <upn> -Enabled $false -Feature headspace` |
| Check a user's assigned licenses (for Viva Insights/Copilot SKU presence) | `Get-MgUserLicenseDetail -UserId <upn>` |
| Set Minimum group size (Copilot-only tenant) | M365 admin center → Viva Insights → Copilot Dashboard in Microsoft 365 → Manage minimum group size |
| Set Minimum group size (Viva-Insights-licensed tenant) | Viva Insights web app → Privacy settings → Minimum group size |
| Set Minimum team size / manager enablement | Viva Insights web app → Manager settings |
| Search a specific manager's team size/eligibility | Viva Insights web app → Manager settings → Manager hierarchy |
| Turn on Partitions (one-way, no self-service reversal) | Viva Insights web app → Privacy settings → Partitions |
| Configure personal insights default on/off | Viva Insights web app → Configure personal insights defaults |
| Assign Insights Administrator/Analyst roles | M365 admin center → Role assignments → search "Insights" (or PIM) |

---

## 🎓 Learning Pointers

- **Diagnose the branch (Personal vs. Organizational) before the symptom — it's the single highest-leverage triage step in this topic.** The two branches have completely different data storage, visibility, and RBAC models despite sharing a product name. [MS Docs: Personal insights privacy guide for admins](https://learn.microsoft.com/en-us/viva/insights/personal/overview/privacy-guide-admins)

- **Four admin surfaces exist, but only three are real Entra directory roles.** Insights Administrator, Insights Analyst, and AI Administrator are PIM-eligible; Manager and Group Manager are Viva Insights web app-native constructs that will never appear in an Entra role audit, by design. Build any MSP-scale access review around this split explicitly. [MS Docs: Roles in Viva Insights](https://learn.microsoft.com/en-us/viva/insights/advanced/setup-maint/user-roles)

- **The old Copilot Dashboard access controls (M365 admin center toggle, legacy PowerShell) are explicitly retired as of current Microsoft documentation.** Viva Feature Access Management — `Get/Add/Update/Remove-VivaModuleFeaturePolicy` against the `VivaInsights` module — is the only supported path now, and it was still being actively documented as recently as August 13, 2026. Expect this surface to keep evolving faster than most Microsoft 365 admin controls. [MS Docs: Manage settings for the Copilot Dashboard, Agent Dashboard, and Viva Insights web app](https://learn.microsoft.com/en-us/viva/insights/advanced/admin/manage-settings-copilot-dashboard)

- **Minimum group size is really two settings, and which one is live depends on the tenant's license state, not on which portal an admin happens to find first.** Reconciling a discrepancy requires confirming license state before assuming either surface is "wrong." [MS Docs: Customize Viva Insights privacy settings](https://learn.microsoft.com/en-us/viva/insights/advanced/setup-maint/privacy-settings)

- **Partitions is a one-way door.** Unlike almost every other privacy control in this topic, once enabled there's no self-service reversal — only a Microsoft Support engagement. Treat enabling it as a decision, not a routine toggle, and say so explicitly before a client turns it on. [MS Docs: Customize Viva Insights privacy settings](https://learn.microsoft.com/en-us/viva/insights/advanced/setup-maint/privacy-settings)

- **The End-user opt-out control and the tenant default-on/off setting are frequently described interchangeably in client conversations, but they're not the same privacy guarantee.** One governs whether personal processing happens at all by default; the other governs only whether de-identified behavioral data flows into row-level organizational outputs — and neither ever hides Copilot usage data. Get this distinction precise before it ends up in a client-facing privacy commitment. [MS Docs: Data-protection considerations for manager, leader, and advanced insights](https://learn.microsoft.com/en-us/viva/insights/Privacy/Data-protection-considerations)
