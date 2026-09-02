# Intune New Device Page (2609 Default Rollout) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the **redesigned single device page** in the Intune admin center (Devices > All devices > select a device), which becomes the **default and sole** device-details experience for all admins starting with Intune's **September 2026 (2609) service release** — the previous multi-tab device page (Overview, Hardware, Managed apps, Device compliance, Device configuration, etc., each a separate blade) is retired, not offered as a parallel or opt-in experience.

**In scope:**
- The new page's information architecture (Essentials, Device action status, Tools and reports, Properties, Device details) and how it maps onto the legacy tab layout
- RBAC-driven action/tab visibility differences between the legacy and new experiences
- The (unchanged) underlying data model — this is a presentation-layer change only
- Practical support-team readiness ahead of and immediately after the 2609 rollout lands in a given tenant

**Explicitly out of scope:**
- Any change to compliance policy evaluation, configuration profile delivery, or Conditional Access — none occurred; this is a console UI redesign only. See the relevant feature's own runbook (`CustomCompliance-A.md`, `Policy-Conflict-A.md`, etc.) for anything data/policy-related.
- Device actions' underlying mechanics (Retire, Wipe, Sync, Remote lock, etc.) — unchanged by this redesign; see `Enrollment-A.md` and the specific action's own documentation for mechanics.
- The Intune company portal / end-user experience — this redesign is admin-console-only.

**Assumes:** engineer has a working Intune admin center account with at least read access, and basic familiarity with Intune RBAC roles and Graph's `deviceManagement/managedDevices` resource.

**Source-confidence note:** this is a recently-announced (2026) console redesign rolling out on a Microsoft-controlled release schedule. Section layout names and grouping described here are accurate as of the 2609 announcement and initial public-preview reporting; re-verify exact section names/behavior against the live [What's new in Microsoft Intune](https://learn.microsoft.com/en-us/intune/whats-new/) page once 2609 lands in your tenant, since minor labeling can shift between preview and GA.

---
## How It Works

<details><summary>Full architecture</summary>

**What actually changed, and what didn't.** The legacy device page presented device information and actions across a set of separately-loaded tabs/blades in the Intune admin center's left-hand device-details navigation — Overview, Hardware, Managed apps, Device compliance, Device configuration, Discovered apps, and more, each essentially its own page requiring a full navigation action to reach. The new single device page consolidates this into **one full-page layout organized by tabs within a single page shell**, backed by the same underlying Microsoft Graph `deviceManagement/managedDevices` object and its related report/policy-state endpoints. No new data is exposed, no data is removed from the product — it is purely reorganized and re-labeled at the presentation layer.

**The new information architecture:**

- **Essentials** — sits at the top of the page and remains visible regardless of which tab is selected below it; carries the highest-frequency at-a-glance facts (device name, ownership, compliance state, OS, primary user) that previously required a trip to the Overview tab.
- **Device action status** — a searchable/filterable panel showing pending, running, and recently completed remote actions for this specific device, consolidating what was previously only visible via a separate bulk action-status report or by re-navigating after triggering an action.
- **Tools and reports** — replaces the old Overview tab's scattered links; groups compliance status, configuration status, and remediation script results together in one place rather than requiring separate navigation to each.
- **Properties** — a consolidated, clean editing view for admin-modifiable fields (including scope tags, now visible directly rather than requiring a separate scope-tag management screen).
- **Device details** — replaces the old Hardware tab; contains physical hardware specifications alongside key Entra ID/Intune management metadata that was previously split across tabs.

**RBAC enforcement is now more visibly strict.** In the legacy layout, an admin without permission for a given action would frequently still see the control, greyed out, sometimes with a tooltip explaining why. The new layout instead **omits** controls the signed-in admin's RBAC role doesn't grant — the page a Helpdesk Operator role sees is genuinely smaller/different than the page a full Intune Administrator sees, not a visually-restricted version of the same page. This is a deliberate design change (reducing UI clutter for narrowly-scoped roles) but is also the single largest source of "a button disappeared" tickets immediately following rollout, since admins accustomed to seeing-but-not-clicking now see nothing at all for actions outside their role.

**Rollout mechanics.** This is a **service-side release**, delivered on Microsoft's own Intune service release cadence (the "2609" designation follows Intune's YYMM release-numbering convention) — not a tenant-level feature flag or Settings Catalog policy an admin can control, defer, or roll back. Once the release reaches a given tenant's service ring, every admin in that tenant sees the new page; there is no parallel-run period and no supported way to revert to the legacy layout afterward.

</details>

---
## Dependency Stack

```
Layer 4:  Presentation — the single device page's tab/section layout and
          RBAC-driven show/hide logic (this topic's actual subject matter)
              ↑ requires
Layer 3:  Admin center client — served to the browser as part of Intune's
          continuously-updated web client; version/rollout controlled entirely
          by Microsoft's service release schedule (2609 = September 2026)
              ↑ requires
Layer 2:  Signed-in admin's Intune RBAC role + scope tags — determines which
          Layer 4 elements render; unrelated to and unaffected by this redesign
              ↑ requires
Layer 1:  Underlying Microsoft Graph data — deviceManagement/managedDevices,
          compliance/configuration state, remote-action results — completely
          unchanged by this UI redesign; identical data backed the legacy page
```

Reading this stack for triage: almost every real ticket resolves at Layer 4 (presentation/navigation) or Layer 2 (RBAC scoping). A Layer 1 problem (wrong or missing data) is never actually a "New Device Page" issue, even though it will be reported as one by an admin who only interacts with the device through this page — always cross-check Layer 1 via Graph directly (Validation Steps) before assuming the page redesign is at fault.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| A previously-visible tab/field is "gone" | Layer 4 reorganization — content moved to a different section, not removed | Map against the How It Works section-by-section mapping |
| A device action control is missing entirely (not greyed out) | Layer 2 RBAC — new layout hides ungranted actions rather than disabling them visibly | Admin's role assignment + scope |
| Compliance/config status shown differs from what the admin expects | Layer 1 — a genuine data issue, unrelated to this redesign | Cross-check via `Get-MgDeviceManagementManagedDevice`; route to the relevant policy runbook |
| Page loads blank/broken/glitchy | Layer 3 — browser-side cache/rendering issue following a client update | Hard refresh, clear cache, try another browser |
| Admin wants the old page back | Layer 3/4 — service-controlled rollout with no opt-out; expected post-2609 | Redirect to section-mapping documentation |
| Different admins report different visible content for the same device | Layer 2 — expected; each admin's RBAC role renders a different page, this is by design | Compare role assignments, not the page itself |

---
## Validation Steps

1. **Establish ground truth via Graph before trusting either the old or new page's rendering.**
   ```powershell
   Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
       Select-Object DeviceName, ComplianceState, ManagementState, LastSyncDateTime, OSVersion, Model, Manufacturer
   ```
   This is the Layer 1 data every presentation layer (old or new) is built from — if this looks correct, the ticket is a Layer 2-4 (presentation/RBAC) issue by elimination.

2. **Confirm the admin's effective RBAC role and scope tags:**
   ```powershell
   Get-MgDeviceManagementRoleAssignment | Select-Object DisplayName, ScopeType, ScopeTagIds, ResourceScopes
   ```
   Compare the specific missing action/tab against what that role is documented to permit — see [Role-based access control for Microsoft Intune](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/overview) for the current built-in role permission matrix.

3. **Confirm device action history independently of the page's own panel:**
   ```powershell
   Get-MgDeviceManagementManagedDeviceRemoteActionResult -ManagedDeviceId "<DeviceId>"
   ```
   Useful when the Device action status panel's own filters are suspected of narrowing what's displayed.

4. **For rendering complaints, isolate browser vs. service:**
   Reproduce in a different, unaffected browser or an incognito/private session with cache cleared. A defect that only reproduces in one browser/profile is environmental; one that reproduces cleanly across browsers/admins is a genuine service-side candidate.

5. **Cross-reference the live release notes** for the exact 2609 rollout date/ring your tenant is on, since Microsoft rolls service releases out progressively — a tenant may see the new page days-to-weeks apart from another tenant, which explains inconsistent reports across an MSP's customer base during the rollout window.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Classify the report.**
Before any deep troubleshooting, determine whether the ticket describes (a) missing/relocated information, (b) a missing action, (c) incorrect data, or (d) a broken/glitchy page. Each maps to a different layer in the Dependency Stack and a different remediation path — conflating them wastes time.

**Phase 2 — For (a) and (b): map against the redesign, don't debug.**
These are expected outcomes of the redesign and RBAC enforcement respectively, not defects. Resolve via documentation/mapping (Remediation Playbook 1), not technical troubleshooting.

**Phase 3 — For (c): treat as an unrelated data/policy issue.**
Route to the owning feature's runbook. Do not spend time on the New Device Page itself — the redesign is not a plausible root cause for incorrect underlying data.

**Phase 4 — For (d): standard web-client triage.**
Hard refresh, cache clear, cross-browser test, then escalate with full evidence (Escalation Evidence template in `SingleDevicePage-B.md`) if it reproduces cleanly. There is no admin-side configuration lever for a genuine rendering defect in a Microsoft-hosted client.

**Phase 5 — Rollout-window awareness.**
During the weeks immediately surrounding a tenant's 2609 rollout, expect a temporary spike in Phase 1(a)/(b)-type tickets purely from unfamiliarity — this is time-bound and self-resolving as admins adjust, not a sign of an escalating problem.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Proactive admin-team readiness ahead of 2609</summary>

1. Confirm your tenant's expected 2609 rollout window via Message Center and the official [What's new in Microsoft Intune](https://learn.microsoft.com/en-us/intune/whats-new/) page.
2. Build and distribute a short internal reference mapping legacy tabs to new sections (see How It Works section-by-section breakdown) to every admin/helpdesk agent who touches the device page.
3. Explicitly call out the RBAC-visibility change (hidden vs. greyed-out actions) in that same communication — this single point prevents the most common false "bug report."
4. After rollout, monitor ticket volume for a 1-2 week settling period; treat a sustained (not just initial-week) elevated volume as a signal that the internal reference needs improvement, not that the product has a defect.

</details>

<details><summary>Playbook 2 — Triaging a suspected genuine service-side defect</summary>

1. Reproduce with a second admin account holding a different RBAC role, to rule out Layer 2.
2. Reproduce in a second, unrelated browser/profile with cache cleared, to rule out Layer 3.
3. Cross-check the underlying Graph data (Validation Step 1) to rule out Layer 1.
4. If the issue survives all three isolation steps, it is a genuine Layer 3/4 (client/presentation) defect — capture the Escalation Evidence template from `SingleDevicePage-B.md` and open a support case, since there is no admin-side remediation available for a defect in Microsoft's own hosted client code.

</details>

---
## Evidence Pack

```powershell
# Intune New Device Page — Evidence Pack (run against Microsoft Graph; requires
# DeviceManagementManagedDevices.Read.All and DeviceManagementRBAC.Read.All)

Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All","DeviceManagementRBAC.Read.All"

$deviceName = "<DeviceName>"

$evidence = [PSCustomObject]@{
    Device       = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'" |
                       Select-Object DeviceName, Id, ComplianceState, ManagementState, LastSyncDateTime, OSVersion, Model, Manufacturer
    RoleAssignments = Get-MgDeviceManagementRoleAssignment | Select-Object DisplayName, ScopeType, ScopeTagIds
    Timestamp    = Get-Date -Format "o"
}

$evidence | ConvertTo-Json -Depth 6 | Out-File "$env:TEMP\SingleDevicePage-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$evidence
```

---
## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Ground-truth device data (bypass the page entirely) | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<Name>'"` |
| Confirm admin's RBAC role/scope | `Get-MgDeviceManagementRoleAssignment` |
| Confirm device action history independently | `Get-MgDeviceManagementManagedDeviceRemoteActionResult -ManagedDeviceId "<Id>"` |
| Official release notes | [What's new in Microsoft Intune](https://learn.microsoft.com/en-us/intune/whats-new/) |
| Built-in role permission reference | [Role-based access control for Microsoft Intune](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/overview) |
| Legacy → new section mapping | See How It Works, this file |

---
## 🎓 Learning Pointers

- This redesign is a textbook case of **presentation-layer change vs. data-layer change** — nearly every real ticket resolves once you separate "the page looks different" from "the data is wrong." Build that separation into your triage habit for any future console redesign, not just this one.
- The **RBAC hide-vs-grey-out** change is the single highest-value fact in this topic — it explains the majority of "an action vanished" reports and has a purely administrative (not technical) resolution: confirm the role, don't debug the page.
- Because this is a **service-controlled rollout** (Intune's own YYMM release cadence) rather than a tenant-level toggle, MSPs managing multiple tenants should expect the new page to appear on different dates across their customer base — don't assume a customer reporting the old page still exists is on a supported "opt-out," they're simply on an earlier release ring.
- [What's new in Microsoft Intune](https://learn.microsoft.com/en-us/intune/whats-new/) is the authoritative source for exact 2609 rollout timing and any last-minute layout adjustments between preview and GA — re-check it before finalizing internal training material.
- See `Enrollment-A.md` and `Policy-Conflict-A.md` for anything that turns out, after Layer 1 validation, to be a genuine data/policy issue rather than a presentation issue — this runbook deliberately does not duplicate that troubleshooting content.
