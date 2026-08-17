# Viva Insights — Hotfix Runbook (Mode B: Ops)
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

Viva Insights is two products wearing one name: **Personal insights** (private, individual-facing, opted in/out per user, never admin-visible) and **Organizational insights** (manager/leader dashboards, Copilot Dashboard, Agent Dashboard, advanced analysis — aggregated, de-identified, admin-configured). Almost every ticket resolves faster once you know which one you're actually looking at — a "why can't I see this" from an end user is nearly always Personal; a "why can't this manager/analyst see this" is nearly always Organizational.

```
1. Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All"

2. Confirm whether the requester should be an Entra-native Viva Insights admin
   (Insights Administrator / Insights Analyst are real, PIM-eligible Entra roles;
   Manager and Group Manager are NOT):
   Get-MgDirectoryRole -Filter "DisplayName eq 'Insights Administrator'" |
     Get-MgDirectoryRoleMember

3. Connect-ExchangeOnline
   Confirm current Viva Feature Access Management (VFAM) state for the Viva
   Insights web app — this is what actually gates Copilot Dashboard, Agent
   Dashboard, and advanced analysis access as of the current platform version:
   Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app"

4. If the ticket is "a manager can't see their team," confirm team size against
   the Minimum team size setting (checked in the Viva Insights web app →
   Manager settings → Manager hierarchy — no Graph/PowerShell read exists for
   this; see Fix 1).

5. If the ticket is "a dashboard/setting change hasn't shown up yet," check the
   propagation-delay table in Fix 6 before assuming the change failed.
```

| Result | Action |
|--------|--------|
| Ticket is about the requester's own personal app/add-in/digest | → Fix 5: this is the Personal insights branch — opt-in/opt-out, not an admin RBAC issue |
| Manager reports team size below 5, or reports 0 in the Manager hierarchy search | → Fix 1: minimum team size not met — not a licensing or role bug |
| Someone was told they're "Insights Admin" but you can't find the role anywhere | → Fix 2: confirm which of the four surfaces (Entra role / AI Administrator / Manager settings / Group Manager) actually applies |
| Copilot Dashboard access was previously managed via the old admin center toggle or PowerShell and stopped working | → Fix 3: that control was retired — Viva Feature Access Management (VFAM) is now the only path |
| Minimum group size looks different in two different places | → Fix 4: there are two separate settings depending on whether the tenant holds a Viva Insights license |
| A setting was changed and the dashboard still shows the old state | → Fix 6: check the propagation-delay table before re-changing anything |
| Someone turned on Partitions and now wants it off | → Fix 7: one-way setting, contact Microsoft Support |
| AI Administrator was assigned but still can't open the Viva Insights web app | → Fix 8: the role does not grant itself automatic app access |
| Agent Dashboard is missing entirely | → Fix 9: still public preview, gated separately from the Copilot Dashboard |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Entra ID tenant
    │
M365 license
    ├─ E3/E5 core SKU → Personal insights only (app, add-in, digest)
    ├─ Microsoft 365 Copilot license → Personal insights AND Organizational
    │    insights bundled automatically (since ~March 2025)
    └─ Standalone Viva Insights add-on / Viva Suite → Organizational insights
         without requiring a Copilot license
    │
    ├── PERSONAL INSIGHTS (per-user, private)
    │       │
    │   Tenant default-on/default-off setting
    │   (governs whether a newly licensed user auto-opts-in or must
    │    self-opt-in)
    │       │
    │   Processed and stored inside the user's OWN Exchange Online mailbox
    │   — no admin, manager, or analyst can see this data through any
    │   normal surface
    │       │
    │   End-user opt-out (separate control — governs whether the user's
    │   DE-IDENTIFIED behavioral metrics appear in row-level Organizational
    │   outputs; does NOT affect their own personal app; does NOT apply to
    │   Copilot usage data, which is always row-level visible)
    │
    └── ORGANIZATIONAL INSIGHTS (admin-configured, aggregated)
            │
        Viva Insights web app — the single on/off gate for Copilot
        Dashboard + Agent Dashboard + Consumption Dashboard + advanced
        analysis + admin tools, controlled via Viva Feature Access
        Management (VFAM)
            │
        Gradual >50-Copilot-license tenant rollout gate (Copilot Dashboard
        settings management)
            │
        Admin role model — 4 real surfaces, not 1:
            ├─ Insights Administrator (true Entra directory role, PIM-eligible;
            │    Global Administrator inherits it automatically)
            ├─ Insights Analyst (true Entra directory role, PIM-eligible)
            ├─ AI Administrator (true Entra directory role, built for Copilot
            │    governance — can ALSO manage most Viva Insights/Copilot
            │    Dashboard settings, but does NOT get automatic web-app access)
            └─ Manager / Group Manager (NOT Entra roles — Manager is a
                 computed eligibility state set via Manager settings inside
                 the Viva Insights web app itself; Group Manager is a
                 Viva-native-only formal role for the leader experience,
                 span of control ≥9 licensed users)
            │
        Minimum team size (≥5) — gates whether a manager sees ANY team
        insights at all
            │
        Minimum group size (≥5, default 10 for Copilot-only tenants) —
        gates whether a specific data point within an approved view is
        suppressed; TWO separate configuration surfaces depending on
        whether the tenant holds a Viva Insights license
            │
        Privacy settings — Partitions (one-way once enabled), keyword
        suppression, domain suppression, domain reclassification (all take
        up to 7 days to propagate)
            │
        Copilot Dashboard / Agent Dashboard (public preview) / Consumption
        Dashboard / Advanced analysis (Power BI templates, custom queries)
```

</details>

---
## Diagnosis & Validation Flow

**1. Separate Personal from Organizational before doing anything else.** A user complaining they "can't see their insights" is almost always describing their own personal app (Personal insights branch) — an admin/RBAC investigation on the Organizational branch will waste time. Confirm which surface the user is actually describing before picking a fix.

**2. Confirm the real assignment surface for the role in question.** Only Insights Administrator, Insights Analyst, and AI Administrator are genuine Entra directory roles. Manager is not a role at all — it's an eligibility state (team size ≥5) toggled via Manager settings inside the Viva Insights web app. Group Manager is a formal role, but it only exists inside the Viva Insights web app, not Entra/PIM. Searching PIM for "Group Manager" or "Manager" will correctly return nothing — that's expected, not a bug.
Command: Step 2 in Triage (for Insights Administrator/Analyst); Fix 1 for Manager/Group Manager.

**3. For Copilot Dashboard access tickets, confirm VFAM state before trusting old documentation or muscle memory.** The Microsoft 365 admin center's original "Copilot Dashboard" toggle and any older PowerShell-based access method are explicitly retired — Microsoft's own current documentation states them as "no longer available." Viva Feature Access Management (`Get/Add/Update/Remove-VivaModuleFeaturePolicy`) is the only supported control surface now, and it gates the entire Viva Insights web app as one unit, not Copilot Dashboard alone.
Command: Step 3 in Triage.

**4. For "manager can't see their team," check team size before role assignment.** A manager can be perfectly eligible by role and still see nothing if their direct+indirect report count is below the tenant's Minimum team size setting (floor of 5). This has no Graph/PowerShell read — it must be checked in the Viva Insights web app's Manager hierarchy search.

**5. For any "I changed a setting and nothing happened yet" ticket, check propagation delay before re-touching the setting.** Delays range from 1 hour (Manager settings) to 7 days (organizational data uploads, keyword/domain suppression, domain reclassification) — see the table in Fix 6. Re-applying a change that simply hasn't propagated yet risks creating conflicting or duplicate configuration.

---
## Common Fix Paths

<details><summary>Fix 1 — A manager or leader reports they can't see any team/organization insights</summary>

This is almost always a team-size or eligibility gap, not a licensing or permissions bug.

1. Confirm the manager's team size (direct + indirect reports, including the manager) in the Viva Insights web app: **Settings → Manager settings → Manager hierarchy** → search the manager's email address. This shows licensing status, team size, and licensed team size — there is no Graph/PowerShell equivalent for this specific check.
2. Confirm the tenant's current **Minimum team size** (floor of 5) in **Settings → Manager settings**. If the manager's team size is below this number, they are correctly excluded — this is enforced privacy behavior, not a defect.
3. Confirm the manager is actually enabled for access — either via **All managers**, a specific Entra security group, or an uploaded `.csv` list in Manager settings. A manager can meet the minimum team size and still have no access if they were never added under one of these three enablement modes.
4. If enabling via a security group, confirm the manager is a **member**, not just an owner, of the referenced Entra ID group.
5. Remember changes to Manager settings take effect after **1 hour** — don't re-touch the setting inside that window assuming it failed.

**Rollback:** Remove the manager from the enabled group/CSV list, or reduce back to the prior enablement mode — no data is destroyed by this change, it only toggles visibility.

</details>

---

<details><summary>Fix 2 — Someone was told they're an "Insights Admin" / "Group Manager" but the role isn't showing up where expected</summary>

Viva Insights spans **four** distinct role/access surfaces — searching the wrong one is the single most common time-sink on these tickets.

| Role/state | Real Entra directory role? | Where it's actually assigned | Notes |
|---|---|---|---|
| Insights Administrator | Yes | Entra ID / M365 admin center Role assignments / PIM (search "Insights") | Global Administrator inherits this automatically |
| Insights Analyst | Yes | Entra ID / M365 admin center Role assignments / PIM (search "Insights") | Full analyst access to advanced analysis tools |
| AI Administrator | Yes | Entra ID / M365 admin center Role assignments / PIM | Can manage most Viva Insights/Copilot Dashboard settings, but does **not** get automatic access to the Viva Insights web app itself (see Fix 8) |
| Manager | **No** | Viva Insights web app → Manager settings (CSV or Entra security group) | Not technically an assignable role at all — a computed eligibility + enablement state |
| Group Manager | **No** | Viva Insights web app → Manager settings (leader experience) | Formal role name, but Viva-native only — never appears in Entra/PIM role search |

1. Confirm which row in the table above actually matches what the requester needs before searching further.
2. For Insights Administrator/Analyst/AI Administrator, verify via:
   ```powershell
   Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
   $role = Get-MgDirectoryRole -Filter "DisplayName eq 'Insights Administrator'"
   Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id
   ```
3. For Manager/Group Manager, there is no Graph/PowerShell membership list — confirm directly in the Viva Insights web app's Manager settings page (CSV export or Entra group membership).

**Rollback:** Remove via the same surface it was granted through — removing an Entra role does nothing for Manager/Group Manager enablement, and vice versa.

</details>

---

<details><summary>Fix 3 — Copilot Dashboard access stopped working after being set up "the old way"</summary>

Microsoft's current documentation explicitly states: the original Microsoft 365 admin center "Copilot Dashboard" access control, and any PowerShell method that predates Viva Feature Access Management, are **no longer available**. If a prior runbook, internal note, or ticket history references either of those, treat it as stale.

1. Confirm current state via VFAM:
   ```powershell
   Connect-ExchangeOnline
   Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app"
   ```
2. If no enabling policy is found, or the tenant-wide default is disabled, re-enable via the M365 admin center: **Settings → Microsoft Viva → Viva Insights → Set up and management → Access Management → Manage access settings for Microsoft Copilot Dashboard**, or apply a policy directly:
   ```powershell
   Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app" `
     -Name "EnableForAll" -Everyone -IsFeatureEnabled $true
   ```
3. Remember this single control now gates the **entire** Viva Insights web app — Copilot Dashboard, Agent Dashboard, Consumption Dashboard, and advanced analysis together — not Copilot Dashboard in isolation. Disabling it for scoping reasons will remove all four at once.
4. Allow up to **24 hours** for user/group-level access changes to take effect before re-investigating.

**Rollback:**
```powershell
Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "Viva Insights web app" `
  -Name "DisableForAll" -Everyone -IsFeatureEnabled $false
```

</details>

---

<details><summary>Fix 4 — Minimum group size looks different in two different places</summary>

This is expected, not a data-integrity bug — there are genuinely **two separate** minimum-group-size settings, gated by whether the tenant holds a Viva Insights license.

1. **Tenant has NO Viva Insights license (Copilot-only):** set via **M365 admin center → Settings → Microsoft Viva → Microsoft Viva Insights → Copilot Dashboard in Microsoft 365 → Manage minimum group size**. Default is **10**; can be lowered to a floor of **5**. This value applies specifically to the Copilot Dashboard/Agent Dashboard's group-level metric comparisons.
2. **Tenant HAS a Viva Insights license:** set via the Viva Insights web app itself → **Privacy settings → Minimum group size** (floor of 5, no platform-stated default — the Insights Administrator or AI Administrator must set it explicitly). This value applies more broadly — advanced analysis Power BI templates and organization-insights group comparisons in Outlook/Teams, in addition to the Copilot Dashboard.
3. Confirm which license state actually applies to the tenant before assuming the two numbers should match — they are legitimately independent settings that happen to share a name and a floor value.
4. Both changes take effect within **24 hours**.

**Rollback:** Set the value back to its prior number through the same portal path used above — this is a privacy threshold, not a destructive change; there's no data loss either direction, only a change in what's visible.

</details>

---

<details><summary>Fix 5 — End user says personal insights/digest/add-in stopped working, or wants out entirely</summary>

Confirm which of the two independent opt-out mechanisms actually applies before making a change.

1. **Tenant default-on/off** (Insights Administrator-controlled): governs whether a newly licensed user must proactively opt themselves in before their own Viva Insights app/Outlook add-in becomes active and before they start contributing to incremental data (like email read rates) at all. Check/change via **Configure personal insights defaults** in the Viva Insights web app.
2. **End-user opt-out** (self-service, always available regardless of the default setting): governs whether the user's own **de-identified behavioral metrics** appear in row-level Organizational outputs (Power BI reports, person queries). This does **not** disable the user's own personal app experience, and does **not** apply to Microsoft 365 Copilot usage data, which remains visible at the row level regardless of this setting.
3. Users self-manage option 2 via the Viva Insights app in Teams or on the web → **Settings → Privacy**. Admins can also opt a user out via PowerShell:
   ```powershell
   Connect-ExchangeOnline
   Set-VivaInsightsSettings -Identity <user@contoso.com> -Enabled $false -Feature headspace
   ```
   Note: `Set-VivaInsightsSettings` only controls a narrow set of features (Headspace, Meeting Effectiveness Survey preview) — it is **not** the cmdlet for the tenant default-on/off setting or the row-level End-user opt-out control, both of which are web-app/admin-center-only as of this writing.
4. Changes to end-user opt-out preference take effect after **1 day**. A user can opt back in at any time; their previous preference is preserved.

**Rollback:** The user (or an admin acting for a DSR) can reverse either setting the same way it was set — opting back in restores prior behavior with no data loss, since opted-out processing simply stops rather than deleting historical data.

</details>

---

<details><summary>Fix 6 — A setting was changed and the dashboard/report still shows the old state</summary>

Propagation delay varies significantly by setting — check this table before re-applying any change.

| Setting | Propagation delay |
|---|---|
| Viva Insights web app user/group access (VFAM) | 24 hours |
| Minimum group size (either configuration path) | 24 hours |
| Manager settings (team size, enablement mode) | 1 hour |
| User exclusion list (VFAM) | Up to 3 days |
| Organizational data upload (either upload path) | Up to 7 days |
| Keyword suppression / Domain suppression / Domain reclassification (Privacy settings) | Up to 7 days (next data refresh) |
| End-user opt-out preference | 1 day |

1. Confirm what was changed and cross-reference this table before assuming the change failed.
2. If the elapsed time exceeds the documented delay, re-verify the setting was actually saved (not just previewed) before escalating.

**Rollback:** N/A — this is a diagnostic wait-and-verify step, not a configuration change.

</details>

---

<details><summary>Fix 7 — Partitions was turned on and now needs to be turned back off</summary>

This is a genuinely one-way setting.

1. Confirm Partitions is actually the setting in question: **Privacy settings → Partitions** in the Viva Insights web app — this creates analyst workspaces scoped to specific employee data/attributes.
2. Once turned on, **Partitions cannot be turned off without contacting Microsoft directly** — there is no self-service reversal in the admin UI or via PowerShell.
3. Existing analysts retain full tenant-data access through the "global partition" even after Partitions is enabled; only newly assigned analysts must be manually assigned a partition going forward.
4. If this was enabled in error, open a Microsoft Support request rather than searching further for a self-service toggle — none exists.

**Rollback:** Not self-service. Escalate to Microsoft Support.

</details>

---

<details><summary>Fix 8 — AI Administrator was assigned the role but still can't open the Viva Insights web app</summary>

This is documented, expected behavior, not a propagation delay or a permissions bug.

1. Confirm the role assignment itself:
   ```powershell
   Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
   $role = Get-MgDirectoryRole -Filter "DisplayName eq 'AI Administrator'"
   Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id
   ```
2. If the user is correctly listed, the missing piece is that **the AI Administrator role does not grant automatic access to the Viva Insights web app** — Microsoft's current documentation states this explicitly. The admin must be separately added to web app access, by themselves or another admin with access.
3. Add the AI Administrator to web app access via **M365 admin center → Settings → Microsoft Viva → Viva Insights → Set up and management → Manage access settings for Microsoft Copilot Dashboard → Users → Add**, or via VFAM PowerShell (Fix 3).
4. Allow the standard 24-hour propagation window before re-checking.

**Rollback:** Remove the individual user's access grant the same way it was added — the underlying AI Administrator role assignment is unaffected either way.

</details>

---

<details><summary>Fix 9 — Agent Dashboard is missing or shows nothing</summary>

1. Confirm the tenant is actually eligible: the Agent Dashboard is **public preview only** as of this writing (GA targeted for late September 2026) — if the tenant hasn't opted into Viva Insights previews, or is outside the gradual >50-Copilot-license rollout, the dashboard legitimately won't appear yet.
2. Confirm the Viva Insights web app itself is enabled (Fix 3) — Agent Dashboard access requires **both** the web app control and its own separate VFAM control to be enabled.
3. Check the dedicated control:
   ```powershell
   Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "AgentDashboard"
   ```
4. If disabled, enable via **M365 admin center → Viva Insights → Set up and management → Access Management → Turn Advanced Insights on or off → Feature access management → Agent Dashboard → Add policy**, or via PowerShell:
   ```powershell
   Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "AgentDashboard" `
     -Name "EnableForAll" -Everyone -IsFeatureEnabled $true
   ```
5. Since this is a preview feature that processes personal data, confirm the client has reviewed the Previews section of the Microsoft Products and Services Data Protection Addendum before enabling broadly — don't treat this as a routine, no-conversation toggle.

**Rollback:**
```powershell
Add-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId "AgentDashboard" `
  -Name "DisableForAll" -Everyone -IsFeatureEnabled $false
```

</details>

---
## Escalation Evidence

```
=== VIVA INSIGHTS ESCALATION TEMPLATE ===
Affected user(s)/UPN(s): ___________
Branch (Personal insights / Organizational insights — confirm before proceeding): ___________
Symptom (can't see personal app / manager can't see team / Copilot Dashboard
access / Agent Dashboard missing / role confusion / group size mismatch /
opt-out confusion / partitions / AI Admin no app access / propagation delay):
___________
Tenant license state (E3/E5 only / Copilot license / standalone Viva
Insights add-on or Suite): ___________
Entra role membership for the requester (Insights Administrator / Insights
Analyst / AI Administrator) — Step 2 in Triage: ___________
VFAM state for "Viva Insights web app" — Step 3 in Triage: ___________
Manager team size, if applicable (from Manager hierarchy search): ___________
Time since the relevant setting was last changed (cross-reference Fix 6's
propagation table): ___________
Screenshot of the exact error/blank state (attach): ___________
```

---
## 🎓 Learning Pointers

- **Viva Insights is two products under one name — diagnose the branch before the symptom.** Personal insights is private-by-design and processed inside the user's own mailbox with no admin visibility; Organizational insights is admin-configured, aggregated, and RBAC'd. A huge share of "wrong portal" and "wrong fix" time loss traces back to not making this split explicit first. [MS Docs: Personal insights privacy guide for admins](https://learn.microsoft.com/en-us/viva/insights/personal/overview/privacy-guide-admins)

- **Only three of the four Viva Insights admin surfaces are real Entra directory roles.** Insights Administrator, Insights Analyst, and AI Administrator are PIM-eligible Entra roles; Manager and Group Manager are not — they're configured entirely inside the Viva Insights web app. Don't spend time searching PIM for a role that was never going to be there. [MS Docs: Roles in Viva Insights](https://learn.microsoft.com/en-us/viva/insights/advanced/setup-maint/user-roles)

- **The old Copilot Dashboard access controls are retired — Viva Feature Access Management is the only current path.** If a runbook, internal wiki page, or prior ticket references the Microsoft 365 admin center's original Copilot Dashboard toggle or an older PowerShell method, treat it as historical. `Get/Add/Update/Remove-VivaModuleFeaturePolicy` against the `VivaInsights` module is current as of 2026. [MS Docs: Manage settings for the Copilot Dashboard, Agent Dashboard, and Viva Insights web app](https://learn.microsoft.com/en-us/viva/insights/advanced/admin/manage-settings-copilot-dashboard)

- **Minimum group size is two different settings wearing one name, split by license state.** Copilot-only tenants configure it in the M365 admin center (default 10); tenants with a Viva Insights license configure a separate control inside the Viva Insights web app's own Privacy settings (no stated default, floor of 5). Confirm which license state applies before assuming a mismatch is a bug. [MS Docs: Customize Viva Insights privacy settings](https://learn.microsoft.com/en-us/viva/insights/advanced/setup-maint/privacy-settings)

- **Propagation delay ranges from 1 hour to 7 days depending on which setting changed.** Re-applying a change inside its documented propagation window is a common cause of duplicate or conflicting configuration — check the delay table before touching a setting a second time. [MS Docs: Manage settings for the Copilot Dashboard, Agent Dashboard, and Viva Insights web app](https://learn.microsoft.com/en-us/viva/insights/advanced/admin/manage-settings-copilot-dashboard)

- **End-user opt-out and the tenant default-on/off setting are not the same control, and neither one touches Copilot usage data.** Opting out of row-level behavioral metrics doesn't disable a user's own personal app, and no opt-out setting hides Microsoft 365 Copilot usage data, which is always visible at the row level. Get this distinction right before promising a user or a client a specific privacy outcome. [MS Docs: Customize Viva Insights privacy settings](https://learn.microsoft.com/en-us/viva/insights/advanced/setup-maint/privacy-settings)
