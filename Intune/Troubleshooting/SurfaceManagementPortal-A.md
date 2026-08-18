# Surface Management Portal — Reference Runbook (Mode A: Deep Dive)
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

Covers **Microsoft Surface Management Portal** — a workspace embedded inside the **Microsoft Intune admin center** (`intune.microsoft.com > All services > Surface Management Portal`) that centralizes device compliance/health insights, warranty and protection-plan coverage, support-request tracking, service orders (replacement/repair), Surface IT Tools, carbon-emissions estimates, and (as of 2026) Security Copilot integration — all scoped to Intune-enrolled Surface-brand hardware.

Architecturally, this is **not** a separate licensed product: access requires only (a) an Intune admin-center subscription and (b) at least one enrolled Surface device, plus an appropriate Microsoft 365 admin role. It sits alongside, but is distinct from, the separate **Surface Support Portal** (a related but independently-accessed Surface portal with its own role nuances) and the **Surface API Management Service** (a separate programmatic entitlement/coverage API product, not a Graph extension of Intune).

Assumes the reader is already comfortable with standard Intune device management (enrollment, compliance policy, Graph device queries) — this file focuses on what's specific to the Surface Management Portal layer, not general Intune device lifecycle.

**Does not cover:**
- Autopilot/enrollment mechanics for Surface hardware itself — see `Autopilot/_AGENT.md` and `Intune/Troubleshooting/Enrollment-A.md`. Surface devices enroll exactly like any other Windows Autopilot/Intune-managed device; nothing about enrollment mechanics is Surface-specific.
- BitLocker, compliance policy design, or driver update (WDfB) mechanics — see `Windows/Troubleshooting/BitLocker-A.md`, `Intune/Troubleshooting/Policy-Conflict-A.md`, `Intune/Troubleshooting/DriverManagement-A.md`. Surface Management Portal's Insights *surface* some of this data but does not own the underlying compliance/driver-update engines.
- The **Surface Support Portal** in depth — a related but separately-accessed portal (self-service warranty lookup/registration outside the Intune admin center context) with its own role-requirement nuances; only cross-referenced here where the role model overlaps.
- The **Surface API Management Service** in depth — a distinct product providing programmatic coverage/entitlement lookups; referenced as the answer to "can we automate this" but not documented step-by-step here, since it requires its own separate onboarding outside Intune/Graph.
- Security Copilot's general capabilities, licensing, or Security Compute Unit economics — see `Security/Copilot/SecurityCopilot-A.md`; only the Surface-specific plugin integration is covered here.

---
## How It Works

<details><summary>Full architecture</summary>

### Where the portal actually lives

Surface Management Portal is a first-party **workspace inside the Intune admin center**, not a standalone Azure/M365 service with its own URL, tenant setting, or license SKU. It is reached via **All services > Surface Management Portal** once signed into `intune.microsoft.com`. There is no separate "enable this feature" tenant toggle — its *availability* is gated purely by whether the tenant has an Intune subscription and at least one enrolled Surface device; its *content* is gated by the signed-in admin's Microsoft 365 role assignments.

### Data population trigger

Enrollment of a Surface device into Intune is a **necessary but not sufficient** condition for the portal to show data about it. Comprehensive device information (warranty status, hardware telemetry feeding Insights) begins flowing into the portal only once the assigned **end user signs in on the device for the first time** post-enrollment — a distinct trigger from `EnrolledDateTime` in the Intune device record. This is the single most common source of "the portal shows nothing" tickets for genuinely freshly-deployed hardware, and it is a timing gap rather than a misconfiguration.

### Six functional areas

1. **Monitor** — the landing dashboard: device count by model, cross-cutting Insights notifications, recently-updated support requests, a warranty/coverage summary, and a Surface IT blog news feed. Acts as a triage entry point into the other five areas rather than owning distinct data of its own.
2. **Warranty and coverage** — per-device warranty/protection-plan status (Expired / Covered / Expiring / Eligible for optional coverage), with drill-down to the affected device list per status. This is the portal's core "why did we build this" value proposition for an MSP: proactive warranty-lapse visibility instead of reactive discovery mid-repair.
3. **Support** — self-service creation and tracking of **support requests** (Technical support / Warranty and Service / Product Safety Concern categories), each producing a **Case ID** and routed to a Microsoft Customer Service Representative via the requester's chosen contact method.
4. **Service orders** — a related but functionally distinct flow from Support: creation of **replacement/repair orders** for serialized devices/accessories or non-serialized accessories, with a **service offer** selection (Advanced Exchange, Same Unit Repair, Standard Exchange), shipping/billing address management, and bulk submission (up to 100 devices via CSV upload). Produces a separate **service order ID** with email confirmation and shipping label where applicable.
5. **Insights** — a customizable card-based dashboard surfacing ten documented signals: Devices not compliant, Devices inactive 30+ days, Devices not registered, Devices covered, Devices expiring within 60 days, Devices eligible for optional coverage, Devices expired, Devices not encrypted, Devices with less than 10% storage, Devices eligible for Windows 11 update. Several of these (compliance, encryption, storage, OS-upgrade eligibility) are effectively a curated re-presentation of standard Intune device-management data filtered to Surface hardware; the warranty/coverage-specific cards are unique to this portal.
6. **Carbon emissions** — lifecycle emissions estimates (Production ~86%, Usage ~14%, Transportation/End of Life negligible), filterable by device age — a sustainability-reporting feature layered on the same enrolled-Surface-device dataset, of limited day-to-day MSP-operational relevance but occasionally requested for ESG reporting.

Two supporting surfaces sit alongside these six: **Surface IT Tools** (links to the downloadable Surface IT Toolkit — Asset Tag CLI, UEFI Assemblies installer, Diagnostics App Console, Brightness Control) and the **Surface API Management Service** (a separate product for programmatic coverage/entitlement lookups, not part of the Intune Graph surface).

### RBAC model — the Global Reader co-requirement

Surface Management Portal roles are real **Microsoft Entra built-in role templates**, but assigned through the **Microsoft 365 admin center** (`admin.microsoft.com > Roles > Role assignments`) — not Intune's own RBAC/Scope Tag system, and not the Entra admin center's Roles blade directly (though the underlying role objects are the same ones documented in Entra's built-in-roles reference).

The architecturally important nuance: **Microsoft Hardware Warranty Administrator** and **Microsoft Hardware Warranty Specialist**, when used specifically for Surface Management Portal (as opposed to the separate Surface Support Portal), each require **Global Reader** to be assigned *in addition* — a two-role combination, not a single toggle. This is stated explicitly in Microsoft's own documentation rather than being an inferred workaround, and it produces no distinct error message when missing: the portal simply underperforms (missing warranty/support visibility) rather than denying access outright, which is what makes it the top misdiagnosis pattern for this feature.

### Security Copilot integration architecture

Copilot for Surface Management Portal is delivered as a **plugin within the Security Copilot platform** (not a feature toggle inside Intune itself), enabled via **Security Copilot portal > Sources > Manage Sources > "Surface Management Portal"**. It requires **no additional license** beyond Security Copilot itself — a deliberate, explicitly-stated position — but does consume the tenant's provisioned **Security Compute Units (SCUs)** per query, same as any other Security Copilot plugin. Once enabled, natural-language prompts (fleet coverage summaries, per-device troubleshooting, end-of-service timelines, best-practice guidance) are answered by matching against built-in Intune/Surface prompt templates plus general Security Copilot reasoning, and Copilot chat additionally offers direct links into relevant Microsoft documentation as the query is typed.

</details>

---
## Dependency Stack

```
[Intune subscription active on the tenant]
        |
        ▼
[At least one Surface-model device enrolled in Intune]
        |
        ▼
[Assigned end user signs in on the device — first time, post-enrollment]
        |         (this is the actual data-population trigger, NOT EnrolledDateTime)
        ▼
[Surface Management Portal populates: Monitor / Warranty and coverage /
 Support / Service orders / Insights / Carbon emissions]
        |
        ▼
[Admin signs into intune.microsoft.com > All services > Surface Management Portal]
        |
        ▼
[Admin's Microsoft 365 role assignment(s) — assigned via admin.microsoft.com, NOT Intune RBAC]
        |
        ├── Global Admin                                     (full access, discouraged for this task)
        ├── Microsoft Hardware Warranty Administrator + Global Reader   (full warranty/service management)
        ├── Microsoft Hardware Warranty Specialist    + Global Reader   (own-request warranty/service management)
        ├── Service Support Administrator                    (view + create/manage replacement requests)
        ├── Billing Administrator                             (view + create/manage + ship-to addresses)
        └── Global Reader alone                               (read-only across the board)
        |
        ▼
[Portal content renders per role's permission set]
        |
        ▼
[Optional layer: Security Copilot integration]
        |
        ├── Security Copilot licensed + Security Compute Units provisioned
        └── "Surface Management Portal" plugin enabled under Manage Sources
                (only certain roles can toggle plugins — separate from portal-access roles above)
        |
        ▼
[Optional layer: Surface API Management Service]
        (separate product for programmatic warranty/coverage/entitlement lookups —
         its own onboarding, not a Graph permission scope on an existing Intune app registration)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Portal doesn't appear under All services | No Intune subscription, or zero Surface devices enrolled | `Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')"` — expect ≥ 1 |
| Portal loads, shows zero devices despite Surface hardware enrolled | End user hasn't signed in on the device yet post-enrollment | Compare `EnrolledDateTime` vs. `LastSyncDateTime`; absent/near-equal implies no real usage yet |
| Warranty Administrator/Specialist assigned but warranty/support data still missing/incomplete | Missing co-requisite **Global Reader** assignment — Surface Management Portal-specific requirement | `Get-MgRoleManagementDirectoryRoleAssignment` for the admin — confirm both roles present |
| Admin can't locate where to assign the role | Looking in Intune RBAC or Entra admin center Roles blade instead of Microsoft 365 admin center | Point to `admin.microsoft.com > Roles > Role assignments` |
| "We just gave them Global Admin" | Works but is explicitly discouraged by Microsoft for this narrow use case | Recommend the scoped Hardware Warranty + Global Reader combination instead |
| Support-request status doesn't match Intune device state (re-enrolled/re-imaged device) | Support/service-order backend is matched by serial number at request-creation time, not continuously synced with the current Intune device object | Compare serial number on the request/Case ID vs. current `Get-MgDeviceManagementManagedDevice` record |
| "Can we pull warranty data with Graph/PowerShell?" | No documented Graph API exists for warranty/coverage/support/service-order/Insights data — portal-only UI feature | Confirm what subset (compliance/encryption/storage/OS-eligibility) actually is Graph-derivable via `Get-SurfaceManagementPortalAudit.ps1` before promising more |
| Security Copilot gives generic, non-Surface-specific answers | Surface Management Portal plugin not enabled in Security Copilot's Manage Sources, or SCUs exhausted | Security Copilot portal > Sources > Manage Sources > confirm plugin toggle; check SCU consumption |
| Devices missing from Insights despite being Surface-brand hardware | Device `Manufacturer`/`Model` string doesn't literally contain "Surface" (OEM rebrand, generic/custom asset naming) | `Get-MgDeviceManagementManagedDevice` — inspect actual `Manufacturer`/`Model` field values |
| New support request or service order form won't submit | A required wizard field is incomplete (Ship-to address, Billing address for paid orders, Contact details) | Walk the multi-step wizard back to the flagged step rather than assuming a platform defect |
| Carbon emissions tab shows unexpected/placeholder-looking figures | Estimates are lifecycle-model-based (Production/Usage/Transportation/End-of-Life percentages), not device-specific telemetry | Treat as an organizational-average sustainability estimate, not a per-device measurement |

---
## Validation Steps

**Step 1 — Confirm tenant-level prerequisites**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')" -All | Measure-Object
```
Expected: ≥ 1. This is the hard gate on portal visibility — no enrolled Surface device means no portal entry point regardless of licensing or role assignment.

**Step 2 — Confirm data-population state per device**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')" -All |
    Select-Object DeviceName, SerialNumber, EnrolledDateTime, LastSyncDateTime, UserPrincipalName,
                  ComplianceState, IsEncrypted
```
A device with `LastSyncDateTime` at or near `EnrolledDateTime` (no meaningful gap) has likely not been signed into by an end user yet — expect a thin or empty portal entry for it.

**Step 3 — Confirm role assignment completeness for the affected admin**
```powershell
$user = Get-MgUser -UserId "<UPN>"
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($user.Id)'" |
    ForEach-Object {
        $def = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $_.RoleDefinitionId
        [PSCustomObject]@{ Role = $def.DisplayName; TemplateId = $def.TemplateId }
    }
```
For a Hardware Warranty Administrator/Specialist, confirm **Global Reader** (`TemplateId f2ef992c-3afb-46b9-b7cf-a126ee74c451`) is also present in the results — its absence is the top root cause for "role assigned but portal underperforms."

**Step 4 — Confirm the role was assigned through the correct surface**
Portal: **admin.microsoft.com > Roles > Role assignments** → search the role name → **Assigned** tab → confirm the user is listed. If the user only appears assigned via a PIM-eligible or group-based path, confirm activation/group membership is currently in effect, not just eligible.

**Step 5 — Confirm Security Copilot plugin state (Copilot-specific tickets only)**
Portal-only, no Graph read available: **Security Copilot portal > Sources > Manage Sources** → confirm **Surface Management Portal** shows enabled. Cross-check SCU consumption if responses seem throttled or generic rather than absent.

**Step 6 — Confirm expectations for programmatic/automated access**
There is no Graph endpoint for warranty, coverage, support-request, service-order, or Insights-card data. Confirm which portion of a "can we automate this" request is actually Graph-derivable (compliance/encryption/storage/OS-eligibility, per `Get-SurfaceManagementPortalAudit.ps1`) versus which portion requires either manual export or the separate Surface API Management Service.

---
## Troubleshooting Steps (by phase)

### Phase 1: Tenant/device prerequisites

1. Confirm Intune subscription is active and at least one Surface device shows in `Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')"`.
2. If zero devices, confirm whether any pending Surface hardware is mid-enrollment (Autopilot ESP, manual MDM enrollment) — the portal will populate automatically once enrollment and first sign-in complete, no manual portal-side registration step exists.
3. For OEM-rebranded or custom-imaged Surface devices, confirm the `Model` field genuinely contains "Surface" — a device that doesn't self-identify this way will not surface in Insights even if it is physically Surface hardware.

### Phase 2: Data-population timing

1. Compare `EnrolledDateTime` and `LastSyncDateTime` for the affected device(s).
2. If a genuine post-enrollment sign-in has occurred and data is still absent after roughly 24 hours, treat as a service-side issue and escalate rather than continuing to wait indefinitely.
3. Confirm this isn't actually a role-visibility issue masquerading as a data gap — re-verify Phase 3 before concluding it's a population delay.

### Phase 3: Role assignment

1. Pull the affected admin's full role assignment list (Validation Step 3).
2. For Hardware Warranty Administrator/Specialist tickets specifically, confirm Global Reader co-assignment before investigating anything else.
3. Confirm the assignment was made via the Microsoft 365 admin center, not attempted (and failed to actually take effect) via Intune RBAC or the Entra admin portal.
4. Allow up to ~30 minutes for role propagation before treating a fresh assignment as ineffective.

### Phase 4: Feature-specific verification (Support / Service orders / Insights / Carbon emissions)

1. For Support/Service order mismatches, compare the serial number on the Case ID/service order against the device's current Intune record — expect drift after re-image/re-enrollment, not a sync bug.
2. For Insights gaps, confirm the specific card's underlying condition against the device's actual Graph-reported state (compliance, encryption, storage, OS version) using `Get-SurfaceManagementPortalAudit.ps1`.
3. For Carbon emissions confusion, reset expectations that figures are lifecycle-model estimates, not per-device telemetry.

### Phase 5: Security Copilot and automation requests

1. Confirm plugin enablement and SCU headroom for Copilot-specific complaints.
2. For automation/API requests, scope the conversation to what's Graph-derivable (device-compliance-adjacent Insights data) versus what requires the Surface API Management Service or manual export (warranty/coverage/support/service-order/full Insights data).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Correct role assignment for a warranty-focused technician (from scratch)</summary>

1. Confirm the technician's actual task scope: full warranty/service management (Administrator) vs. own-request-only (Specialist) vs. billing-adjacent (Billing Administrator) vs. read-only oversight (Global Reader alone).
2. **admin.microsoft.com > Roles > Role assignments** → locate `Microsoft Hardware Warranty Administrator` (or `Specialist`) → **Assigned** tab → **Add users** → select the technician → **Save**.
3. Repeat the same steps for **Global Reader** — this second assignment is not optional for Surface Management Portal access with either Hardware Warranty role.
4. Document both assignments for internal tracking/compliance, and inform the technician of the ~30-minute propagation window before they test.
5. Validate: have the technician sign in to `intune.microsoft.com > All services > Surface Management Portal` and confirm warranty/coverage and support-request data renders.

**Rollback:** remove both role assignments from the Assigned tab if reassigning to a different technician or revoking access.

</details>

<details><summary>Playbook 2 — Downgrade an over-privileged Global Admin to a scoped role</summary>

1. Confirm via `Get-MgRoleManagementDirectoryRoleAssignment` that the user currently holds Global Admin and identify their actual day-to-day Surface-portal task.
2. Assign the narrowest matching scoped role (+ Global Reader if it's a Hardware Warranty role) using Playbook 1's steps.
3. Have the user validate portal functionality under the new scoped role **before** removing Global Admin, to avoid a mid-troubleshooting access gap.
4. Once confirmed working, remove Global Admin from the user unless a separate, independently-justified need exists.
5. Document the change — this is a security-posture improvement worth recording for audit/compliance purposes.

**Rollback:** re-add Global Admin if the scoped role combination proves insufficient for a legitimately broader task; investigate further before assuming Global Admin is the only path.

</details>

<details><summary>Playbook 3 — Onboard Security Copilot integration for Surface Management Portal</summary>

1. Confirm the tenant holds a Security Copilot license and has provisioned sufficient Security Compute Units for expected query volume.
2. Sign in to the **Security Copilot portal**.
3. In the prompt bar, select **Sources** → **Manage Sources**.
4. Activate the **Surface Management Portal** plugin; close the plugin pane.
5. Confirm the account performing this has a role permitted to toggle plugins (see [Manage plugins in Microsoft Security Copilot](https://learn.microsoft.com/en-us/copilot/security/manage-plugins)) — if not, identify who does before troubleshooting further as "broken."
6. Validate with a documented sample prompt (e.g., "Generate a warranty coverage report for all devices" or "List all my Surface device models' end of service date").

**Rollback:** deactivate the plugin under Manage Sources — no other tenant-wide side effects.

</details>

<details><summary>Playbook 4 — Build a Graph-based proxy report for what the portal's Insights tab can't be automated for</summary>

1. Run `Get-SurfaceManagementPortalAudit.ps1` (see Scripts/) to pull the Graph-derivable subset of Insights signals (compliance, encryption, storage headroom, Windows 11 eligibility) tenant-wide for Surface-model devices.
2. Cross-reference the script's role-assignment audit output (Hardware Warranty Administrator/Specialist holders missing Global Reader) as a proactive fix-before-it's-a-ticket check.
3. For the remaining Insights signals with no Graph equivalent (warranty/coverage status, support-request/service-order state, registration status) direct stakeholders to the portal UI directly or, for genuine automation needs at scale, evaluate the separate Surface API Management Service rather than attempting to reverse-engineer the data from Graph.
4. Schedule this script to run periodically (e.g., weekly) as a lightweight proactive-monitoring substitute for the portal's own Insights cards, explicitly scoped to what it can and cannot see.

**Rollback:** N/A — read-only reporting.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Surface Management Portal access/data evidence for escalation
.NOTES     Run with an account holding at least DeviceManagementManagedDevices.Read.All
           and RoleManagement.Read.Directory Graph scopes. Output saved to current directory.
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
$out    = ".\SurfaceMgmtPortalEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $output.Add("=" * 60)
    $output.Add("  $Title")
    $output.Add("=" * 60)
    try { $output.Add((&$Body | Out-String).Trim()) }
    catch { $output.Add("ERROR: $($_.Exception.Message)") }
    $output.Add("")
}

Add-Section "Collection metadata" {
    "Collected : $ts"
    "Tenant    : $((Get-MgContext).TenantId)"
}

Add-Section "Enrolled Surface-model devices" {
    Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')" -All |
        Select-Object DeviceName, Model, SerialNumber, EnrolledDateTime, LastSyncDateTime,
                      ComplianceState, IsEncrypted, UserPrincipalName |
        Format-Table -AutoSize | Out-String
}

Add-Section "Global Reader role holders (co-requisite for Hardware Warranty roles)" {
    $globalReaderId = "f2ef992c-3afb-46b9-b7cf-a126ee74c451"
    Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$globalReaderId'" |
        ForEach-Object { (Get-MgUser -UserId $_.PrincipalId -ErrorAction SilentlyContinue).UserPrincipalName } |
        Out-String
}

Add-Section "Microsoft Hardware Warranty Administrator/Specialist role holders" {
    $hwaId = "1501b917-7653-4ff9-a4b5-203eaf33784f"
    $hwsId = "281fe777-fb20-4fbb-b7a3-ccebce5b0d96"
    foreach ($roleId in @($hwaId, $hwsId)) {
        Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$roleId'" |
            ForEach-Object { (Get-MgUser -UserId $_.PrincipalId -ErrorAction SilentlyContinue).UserPrincipalName }
    } | Out-String
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Count enrolled Surface-model devices | `Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')" -All \| Measure-Object` |
| Full Surface device inventory + sync/compliance state | `Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')" -All \| Select DeviceName,SerialNumber,EnrolledDateTime,LastSyncDateTime,ComplianceState,IsEncrypted` |
| Confirm an admin's role assignments | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<ObjectId>'"` |
| Resolve a role definition name from its ID | `Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId <RoleDefId>` |
| List all Global Reader holders (co-requisite check) | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'"` |
| List Hardware Warranty Administrator holders | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '1501b917-7653-4ff9-a4b5-203eaf33784f'"` |
| List Hardware Warranty Specialist holders | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '281fe777-fb20-4fbb-b7a3-ccebce5b0d96'"` |
| Portal access | `https://intune.microsoft.com` > All services > Surface Management Portal |
| Role assignment surface | `https://admin.microsoft.com` > Roles > Role assignments |
| Security Copilot plugin management | Security Copilot portal > prompt bar > Sources > Manage Sources |

---
## 🎓 Learning Pointers

- **The Global Reader co-requirement for Hardware Warranty Administrator/Specialist is the single highest-value fact to know before troubleshooting this feature** — it is stated explicitly in Microsoft's documentation but produces no error message when missing, only a silently underpowered portal. Build it into first-response triage rather than rediscovering it per ticket. [Assign admin roles for Surface portals](https://learn.microsoft.com/en-us/surface/surface-portal-admin-roles)

- **Data population is gated on end-user sign-in, not device enrollment.** `EnrolledDateTime` alone tells you nothing about whether the portal has meaningful data for a device — always cross-check `LastSyncDateTime` and, where possible, confirm an actual user session has occurred. [Surface Management Portal overview](https://learn.microsoft.com/en-us/surface/surface-management-portal)

- **This portal has no comprehensive Graph API — automation promises need to be scoped carefully.** Only the subset of Insights that overlaps standard Intune device-management data (compliance, encryption, storage, Windows 11 eligibility) is genuinely Graph-derivable; warranty, coverage, support-request, service-order, and registration-status data exist only in the portal UI or the separate Surface API Management Service. Don't let a client assume a full programmatic warranty pipeline is achievable via Graph alone. [Overview of Microsoft Surface Management Portal](https://learn.microsoft.com/en-us/intune/device-management/tools/surface-management-portal)

- **Role assignment lives in the Microsoft 365 admin center, not Intune RBAC or the Entra admin portal's own Roles blade** — despite the roles themselves being genuine Entra built-in role templates with documented template IDs. This is a recurring "wrong portal" support pattern worth flagging early. [Microsoft Entra built-in roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference)

- **Security Copilot integration for this portal carries no incremental license cost** beyond Security Copilot itself, consuming only Security Compute Units — an unusually generous packaging decision worth mentioning proactively to any client already invested in Security Copilot who manages Surface fleets. [Security Copilot in Microsoft Surface Management Portal](https://learn.microsoft.com/en-us/intune/intune-service/copilot/security-copilot-surface-portal)

- **Support requests and service orders are backed by a separate hardware-service system matched by serial number at request time**, not a live sync against the current Intune device object — expect and explain drift after any re-image/re-enrollment event rather than treating it as a data-integrity bug. [Surface Management Portal overview](https://learn.microsoft.com/en-us/surface/surface-management-portal)
