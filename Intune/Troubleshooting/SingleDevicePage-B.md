# Intune New Device Page (2609 Default Rollout) — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** starting with Intune's **September 2026 (2609) service release**, the redesigned **single device page** becomes the **default and only** device-details experience in the Intune admin center — the legacy tabbed device page (separate Overview/Hardware/Managed apps/Device compliance/etc. blades reached via the left-nav) is retired for all admins, not rolled out as an opt-in toggle. This is a **console UI/navigation change, not a data or policy change** — nothing about device compliance evaluation, configuration delivery, or the underlying Graph object model is different. The overwhelming majority of "device page" tickets after the 2609 rollout are **"where did X go"** navigation confusion, not actual functional regressions. Confirm this distinction before spending time on device-side diagnostics — if the same fact is retrievable via Graph/PowerShell, the data itself is fine and the ticket is a UI-orientation issue.

Run these first, in this order:

```powershell
# 1 — Confirm you're looking at a genuine data/functional problem, not a navigation problem, by
#     cross-checking the same device fact via Graph rather than the portal UI.
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
    Select-Object DeviceName, ComplianceState, ManagementState, LastSyncDateTime, OSVersion

# 2 — Confirm the admin's assigned Intune RBAC role — the new page shows only actions the signed-in
#     admin's role permits, so a "missing action/tab" report is very often an RBAC scope, not a bug.
Get-MgDeviceManagementRoleAssignment | Select-Object DisplayName, ScopeType

# 3 — Confirm the device itself last checked in recently — the new page's "Device action status"
#     panel depends on current action/report data, and a stale device will show sparse status
#     regardless of which page design is used.
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
    Select-Object DeviceName, LastSyncDateTime, ManagementAgent

# 4 — If the admin reports the page itself is broken/blank/won't load (not just "I can't find X"),
#     rule out a browser-side rendering issue before escalating as a product bug.
#     (No PowerShell equivalent — see Fix 4.)
```

| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| Admin can't find the Hardware tab / a specific field they used to click to | Legacy tab layout retired — fields moved into the new "Device details" section | Fix 1 |
| Admin can't find the Overview tab's compliance/configuration summary | Replaced by "Tools and reports" section, grouped differently | Fix 1 |
| A device action (Retire/Wipe/Sync/Restart) the admin expects isn't visible | RBAC role scoping — the new page only shows actions the signed-in role is permitted to take, and hides (not greys out) the rest | Fix 2 |
| Device action history/status the admin ran yesterday is missing | "Device action status" panel is scoped to that device and has its own filter/search — confirm filters aren't narrowing the view | Fix 3 |
| Page loads blank, partially, or with layout glitches | Browser cache/rendering issue following the console's own client-side update, not a data problem | Fix 4 |
| Admin insists the legacy page should still be available (e.g., via a URL bookmark or "switch back" toggle) | Expected as of 2609 — the legacy page is fully retired, not dual-run or reachable by preference toggle | Fix 5 |
| Scope tags the admin expects to see/edit aren't visible | Scope tags moved into the "Properties" section's editing view, not the old location | Fix 1 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Intune tenant on/after the 2609 service release]
    │   (rollout is a Microsoft-controlled service-side release; not a per-tenant
    │    admin toggle — cannot be deferred locally once the release reaches the tenant)
    └── [Admin center session serving the new single device page by default]
            └── [Signed-in admin's Intune RBAC role determines which tabs/actions render]
                    │   (role-based visibility is enforced client-side in the new layout —
                    │    a narrower role sees a genuinely smaller page, not a greyed-out one)
                    └── [Underlying Graph managedDevice object + related reports/policies
                         — completely unchanged by this UI redesign]
                            └── [Page renders: Essentials (top, always visible) +
                                 Device action status + Tools and reports + Properties +
                                 Device details tabs, sourced from the same Graph data
                                 the legacy page used]
```

**Key fact:** every layer below "admin center session" is identical to the legacy page. If a fact is wrong or missing at the Graph layer, that is a genuine data/sync problem (route to `Enrollment-A.md`/`CustomCompliance-A.md`/the relevant policy runbook) — not a New Device Page problem. The New Device Page layer only changes *where* and *how* that same data is presented, and *which* actions a given RBAC role can see.

</details>

---
## Diagnosis & Validation Flow

1. **Classify the ticket first: navigation confusion vs. genuine data/functional issue.**
   Ask (or check) whether the same fact is retrievable via Graph/PowerShell (Triage step 1). If yes, this is a UI-orientation issue — go straight to Fix 1/2/3 depending on what's missing. If the Graph data itself is wrong, this ticket does not belong in this runbook — route to the underlying feature's own runbook.

2. **Confirm the admin's RBAC role and scope.**
   ```powershell
   Get-MgDeviceManagementRoleAssignment | Select-Object DisplayName, ScopeType, ScopeTagIds
   ```
   The new page enforces role-based action/tab visibility more visibly than the legacy page did (fewer greyed-out controls, more outright-hidden ones) — a role with narrower permissions will render a smaller page. This is very frequently mistaken for a bug.

3. **Confirm device sync recency**, since the new page's status panels reflect current state, not historical:
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
       Select-Object DeviceName, LastSyncDateTime
   ```
   A device that hasn't synced recently will show sparse/stale data on *either* the old or new page — don't attribute this to the redesign.

4. **If the complaint is rendering/layout (blank page, missing panels, broken buttons) rather than "I can't find X":**
   Treat as a browser-side issue first (Fix 4) — hard refresh, clear the admin center's cached state, try an incognito/different browser profile — before escalating as a service defect.

5. **If none of the above resolves it and the behavior is reproducible across browsers/admins/devices:**
   This is a genuine service-side defect candidate — escalate with the Escalation Evidence template below, since local troubleshooting has no further lever (the new page is a Microsoft-hosted client, not something admin-side config can alter).

---
## Common Fix Paths

<details><summary>Fix 1 — Field/tab the admin used to use has moved, not disappeared</summary>

1. Reassure/redirect rather than troubleshoot — this is expected behavior after the 2609 rollout, not a defect.
2. Map the admin's expectation to the new layout:
   - Old **Hardware** tab → new **Device details** section (physical specs + key Entra/Intune management info consolidated).
   - Old **Overview** tab's compliance/configuration summary → new **Tools and reports** section.
   - Old scattered **scope tags** location → new **Properties** section's editing view.
   - Old separate **device action** history views → new **Device action status** panel (searchable/filterable, on the same page rather than a separate blade).
3. Point the admin at the **Essentials** section at the top of the page — it's visible regardless of which tab is selected, and covers most of the "at a glance" facts admins previously hunted for across tabs.
4. If this is a recurring pattern across your admin team, treat it as a documentation/training gap (see Learning Pointers) rather than a series of individual tickets.

</details>

<details><summary>Fix 2 — Expected device action isn't visible</summary>

1. Confirm the signed-in admin's RBAC role via Triage step 2/Diagnosis step 2.
2. Compare the role's assigned permissions against the specific action in question (e.g., Wipe requires a role with the Remote tasks permission covering that action) — the new page **hides** ungranted actions rather than showing them greyed out with a tooltip, which is the most common source of "the button is just gone" reports following 2609.
3. If the admin's role should legitimately include the action, verify the role assignment's scope (group/OU) actually covers this device — a correct role with the wrong scope produces the same hidden-action symptom.
4. If access is confirmed correct and the action is still missing, treat as a service-side defect candidate (Diagnosis step 5).

</details>

<details><summary>Fix 3 — Device action status/history looks incomplete</summary>

1. Confirm the **Device action status** panel's own filter/search isn't narrowing the visible set (date range, action type, status) — it defaults to a recent window, not full history.
2. Cross-check the same action's status via Graph if in doubt:
   ```powershell
   Get-MgDeviceManagementManagedDeviceRemoteActionResult -ManagedDeviceId "<DeviceId>"
   ```
3. Remember this panel is scoped to the single device you're viewing — bulk/fleet-wide action status is still a separate report, not something this page consolidates.

</details>

<details><summary>Fix 4 — Page loads blank, partially, or with layout glitches</summary>

1. Hard refresh (Ctrl/Cmd+Shift+R) — the admin center ships client-side updates continuously, and a stale cached bundle is the most common cause of a broken-looking page immediately after a release boundary like 2609.
2. Clear the browser's cached data for `intune.microsoft.com`/`endpoint.microsoft.com`, or try an incognito/private window.
3. Try a different supported browser to isolate a browser-specific rendering bug from a genuine service issue.
4. If the issue persists across browsers and reappears after a clean cache, capture a screenshot plus browser console errors and escalate (Escalation Evidence) — this is now a genuine service-side rendering defect candidate, not an environment issue.

</details>

<details><summary>Fix 5 — Admin wants the legacy page back</summary>

1. Set expectations clearly: as of the 2609 release, the legacy device page is **fully retired**, not available via toggle, preference setting, or bookmarked URL fallback. There is no supported way to opt back in.
2. Redirect to Fix 1's mapping table to close the gap between old habits and the new layout.
3. If the underlying complaint is a genuine workflow regression (not just unfamiliarity — e.g., a specific field genuinely isn't present anywhere in the new page), confirm that carefully against current Microsoft Learn documentation before assuming it's simply relocated, and escalate as a product feedback item if it's truly missing.

</details>

---
## Escalation Evidence

```
INTUNE NEW DEVICE PAGE — ESCALATION TEMPLATE
============================================
Tenant:                        <tenant name/ID>
Admin UPN:                     <affected admin's UPN>
Admin's Intune RBAC role(s):   <role name(s) + scope>
Browser + version:              <browser/version>
Device(s) affected:            <device name(s)/ID(s)>
Reproducible across browsers:   <Y/N>
Reproducible across admins:     <Y/N>
Same fact confirmed via Graph:  <Y/N — paste Graph output if checked>
Screenshot / console errors:    <attach>
Expected vs actual:             <what the admin expected to see/do vs what happened>
```

---
## 🎓 Learning Pointers

- This is a **console UI redesign becoming the mandatory default with the 2609 release** — no underlying device data, policy evaluation, or compliance logic changed. Treat "device page" tickets as navigation issues first, functional issues second, and validate that assumption via a quick Graph cross-check (Triage step 1) before deep-diving.
- The single most common new-page complaint pattern is a **hidden (not greyed-out) action** due to RBAC scoping — the new layout is more strict/visible about role-based rendering than the legacy tabs were, which reads as "a button disappeared" to admins whose role never actually had that permission.
- Proactively distribute the old-tab-to-new-section mapping (Fix 1) to your admin team **before** 2609 lands in your tenant, if you have advance notice via Message Center — this single artifact prevents the majority of first-week tickets after rollout.
- See [What's new in Microsoft Intune](https://learn.microsoft.com/en-us/intune/whats-new/) for the official 2609 release notes and rollout timeline, and the in-development notes for any last-minute layout changes ahead of GA in your tenant's release ring.
- Because rollout is service-controlled (not a per-tenant admin toggle), there is no supported way to defer or opt out locally — plan admin communications around Microsoft's published rollout timeline rather than your own change window.
