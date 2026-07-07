# Windows Autopilot Device Preparation — Reference Runbook (Mode A: Deep Dive)
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

This document covers **Windows Autopilot device preparation (APDP)**, a distinct enrollment mode introduced in 2024, not classic Windows Autopilot (hash-registered devices with a deployment profile — see `HybridJoin-Autopilot-A.md`, `Profile-Not-Assigned-A.md`, `TPM-Attestation-A.md` for that flow). Do not conflate the two: they have different portals surfaces (same Intune admin center, different blades), different group-membership mechanics, and — critically — **classic Autopilot profile assignment always takes precedence over a device preparation policy** if a device somehow matches both.

Assumptions:
- Devices are Windows 11, 24H2+ (or 23H2/22H2 with KB5035942+) — device prep does not support older builds at all; the deployment experience simply never launches.
- Microsoft Entra join only. Device prep does not support Hybrid Entra join, Entra registered, or on-prem AD join scenarios — if the environment requires Hybrid Join, this is the wrong tool; use classic Autopilot.
- Scenarios covered: user-driven Entra join, automatic mode (Windows 365/Cloud PC provisioning policies), and Government Community Cloud High / DoD (supported, but Windows 365 Flex shared mode is not supported in GCCH/DoD).

---
## How It Works

<details><summary>Full architecture</summary>

**The core design shift vs. classic Autopilot: Enrollment Time Grouping.**

Classic Autopilot relies on dynamic security groups: a device gets an Entra device object, a dynamic group rule re-evaluates (which can take minutes and isn't guaranteed synchronous with enrollment), and *then* policies/apps assigned to that group start flowing — hence ESP, and hence ESP timeout tuning being a whole discipline of its own (see `ESP-Stuck-A.md`).

Device preparation removes the dynamic-group wait entirely. Instead:

1. Admin creates a **device security group** — a plain *assigned* (not dynamic) group — and sets its owner to a special first-party service principal, **Intune Provisioning Client** (in some tenants displayed as **Intune Autopilot ConfidentialClient**; same object, AppID `f1346770-5b25-470b-88bd-d5744ab7952c` either way).
2. Admin creates a **device preparation policy**, which references: a **user group** (who is allowed to trigger this flow during OOBE), the **device group** (from step 1), a list of **allowed applications** and **allowed PowerShell scripts** to run during OOBE, and OOBE/user-account-type settings.
3. At OOBE, the signing-in user is checked against the user group. If they match, the device prep configuration is delivered.
4. **Enrollment Time Grouping fires**: because the Intune Provisioning Client service principal owns the device group, Intune can add the *new device object directly into that group* the instant it enrolls — no dynamic rule evaluation, no propagation delay. This direct membership write is what makes device prep "fast and reliable" relative to classic Autopilot's dynamic-group model.
5. Apps and scripts that are BOTH assigned (in Intune) to that device group AND explicitly selected inside the device prep policy are delivered during OOBE, in **System context only** (no user is signed in yet — User-context apps/scripts are silently skipped, by design, not a bug).
6. Any other policies assigned to the device group (compliance policies, configuration profiles, etc.) are synced but their application is **not tracked as part of the OOBE deployment status** — they may finish before or after OOBE completes. This is a deliberate scope limitation, not a monitoring gap: the deployment report only tracks apps/scripts, not arbitrary policy application.
7. **No ESP.** Device prep has its own OOBE progress UI (a percentage indicator) that is architecturally separate from the Enrollment Status Page used by classic Autopilot. If you see ESP during a deployment, by definition it is not a device prep deployment — the device fell back to a classic profile or plain Entra join.

**Why the strict group ownership/eligibility rules exist:** Intune Provisioning Client needs *owner* rights on the device group specifically because Microsoft's implementation adds the device object as a direct member via that service principal's identity — this is the mechanism, not an arbitrary permission checkbox. A role-assignable group is blocked from having non-role-eligible owners perform arbitrary membership writes (Entra's Privileged Role Administration protections), which is why "Microsoft Entra roles can be assigned to this group" **must** be No — it's a hard platform constraint, not a device-prep-specific rule.

</details>

---
## Dependency Stack

```
┌─────────────────────────────────────────────────────────┐
│ End-user experience: OOBE % progress UI (NOT ESP)        │
├─────────────────────────────────────────────────────────┤
│ Apps / PowerShell scripts delivered in SYSTEM context    │
│  (must be: assigned to device group AND selected in      │
│   the device prep policy)                                 │
├─────────────────────────────────────────────────────────┤
│ Enrollment Time Grouping                                  │
│  (device added DIRECTLY to device security group          │
│   at enrollment — no dynamic-group wait)                  │
├─────────────────────────────────────────────────────────┤
│ Device preparation policy                                 │
│  (user group + device group + allowed apps/scripts +       │
│   OOBE/account-type settings + priority vs other policies) │
├─────────────────────────────────────────────────────────┤
│ Device security group                                     │
│  - Assigned (not dynamic) type                             │
│  - "Assignable to Entra roles" = No                        │
│  - Owner = Intune Provisioning Client                       │
│    (AppID f1346770-5b25-470b-88bd-d5744ab7952c)             │
├─────────────────────────────────────────────────────────┤
│ Windows automatic MDM enrollment + Entra join permission   │
│  (users allowed to Entra-join devices; or corporate         │
│   identifiers if personal-device join is restricted)        │
├─────────────────────────────────────────────────────────┤
│ Device NOT registered as classic Autopilot device           │
│ Device NOT targeted by a classic Autopilot profile           │
│  (classic profile ALWAYS wins if both apply)                  │
├─────────────────────────────────────────────────────────┤
│ Windows 11 24H2+, or 23H2/22H2 + KB5035942+ preinstalled     │
│  (OEM-optimized image; below minimum = deployment never launches)│
└─────────────────────────────────────────────────────────┘
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Deployment experience never launches; goes straight to normal desktop setup | Windows build below minimum, OR device registered/profiled for classic Autopilot | `winver`; Windows Autopilot devices list |
| ESP displays during what should be a device prep deployment | Not actually a device prep deployment — classic profile or plain join took over | Windows Autopilot devices list — check registration + profile assignment |
| Policy won't save — "problem with the device security group" error | Intune Provisioning Client not owner of device group | Group → Owners in Entra admin center |
| Policy shows "0 groups assigned" despite group selected | Known intermittent Intune bug, or ownership not actually applied | Re-verify ownership; recreate group as workaround if persists |
| Can't find "Intune Provisioning Client" when setting owner | Displays as "Intune Autopilot ConfidentialClient" in some tenants, or SP doesn't exist yet | Check by AppID `f1346770-5b25-470b-88bd-d5744ab7952c`, not display name |
| "Unable to save group assignment... you do not have permission" | Admin role missing RBAC permission | Add "Enrollment time device membership assignment" + "Device configurations: Assign" |
| Apps/scripts show `Skipped` in deployment report | Not assigned to device group, wrong execution context, or Managed Installer policy active | Check assignment + context; check tenant Managed Installer policy state |
| Device gets a different (wrong) policy than expected | Multiple device prep policies target the same user; lower-priority one lost | Enrollment | Windows enrollment → Device preparation policies → check Priority column ordering |
| Priority column greyed out for a policy | Policy is in **automatic mode** (Cloud PC) — priority isn't used; assignment comes from the Cloud PC provisioning policy directly | Not a bug — expected for automatic-mode policies |
| Windows 365/Cloud PC deployment times out ~60 min regardless of configured value | Known issue — configured timeout not honored correctly for device prep on Cloud PC | Reduce blocking apps; check if tenant patch resolved it (Feb 2026 fix) |
| User ends up wrong account type (admin vs standard) and missing expected apps | Conflict between device prep "User account type" setting and Entra ID "Local administrator settings" | Cross-check both settings against the supported combination table below |
| BitLocker encrypts at 128-bit despite 256-bit configured | Known race-condition bug in device prep BitLocker delivery | Not fixable client-side; avoid device prep for 256-bit-mandatory fleets until patched |
| Custom compliance script or device health script "not running" during OOBE | Not supported during device prep deployments (initial-release limitation) | Expected — don't debug as a fault |
| Export logs button during OOBE shows no confirmation | Known UX gap — logs do save to first USB drive silently | Check the USB drive; no on-screen success/failure indicator by design (fix pending) |

---
## Validation Steps

1. **Confirm the device isn't shadowed by classic Autopilot.**
   Intune admin center → Windows enrollment → Windows Autopilot devices → search serial.
   *Good:* not listed, or listed with no profile assigned.
   *Bad:* listed AND profile-assigned — classic wins, device prep will never fire for this device.

2. **Confirm device group configuration.**
   Entra admin center → Groups → the referenced device group.
   *Good:* Membership type = Assigned; "Microsoft Entra roles can be assigned to this group" = No; Owners includes Intune Provisioning Client / Intune Autopilot ConfidentialClient (AppID `f1346770-5b25-470b-88bd-d5744ab7952c`).
   *Bad:* Dynamic membership type, role-assignable = Yes, or owner missing/wrong.

3. **Confirm policy targeting.**
   Intune admin center → Enrollment → Windows enrollment → Device preparation policies → open the policy.
   *Good:* User group populated, Device group populated (not "0 groups assigned"), priority makes sense relative to other policies targeting the same users.
   *Bad:* empty device group, unexpected priority collision with another policy.

4. **Confirm RBAC on the admin managing this.**
   Entra admin center → Roles → check the custom/built-in role assigned for Autopilot administration.
   *Good:* includes "Enrollment time device membership assignment" and "Device configurations: Assign".
   *Bad:* missing either — policy creation/assignment silently fails with permission errors.

5. **Confirm app/script execution context.**
   Intune admin center → Apps / Scripts → the specific app or script referenced in the policy → Assignment/properties.
   *Good:* configured to run in System context.
   *Bad:* User context — will show `Skipped` every time during OOBE since no user session exists yet.

6. **Confirm deployment status via the Monitor tab.**
   Intune admin center → Enrollment → Device preparation → Monitor.
   *Good:* device present, phase progressing, apps/scripts `Installed`.
   *Bad:* device missing entirely (policy never applied — re-check steps 1-3), or stuck in one phase past expected time.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-deployment (before first boot):**
- Verify OS build/media meets minimum version.
- Verify device isn't pre-registered as classic Autopilot.
- Verify corporate identifiers are loaded if enrollment restrictions block personal-device join.

**Phase 2 — Policy/group configuration (admin-side, before any device touches OOBE):**
- Verify device group ownership and eligibility (assigned, not role-assignable).
- Verify RBAC permissions on the managing admin/role.
- Verify user group membership for the intended end users.
- Verify priority ordering if multiple policies could match the same user.

**Phase 3 — OOBE / first boot:**
- Confirm the device prep progress UI appears (not ESP).
- If it doesn't appear, work backward through Phase 1/2 checks rather than assuming an OOBE-side defect — device prep has almost no OOBE-side remediation surface; nearly every failure traces back to policy/group config or the classic-Autopilot-precedence rule.

**Phase 4 — App/script delivery:**
- Cross-check assignment (device group) + policy selection + execution context for every app/script showing `Skipped`.
- Check tenant-wide Managed Installer policy state if Win32/WinGet/Enterprise Catalog apps are uniformly skipped.

**Phase 5 — Post-deployment / steady state:**
- Confirm the device landed in the correct security group (Entra admin center → group → Members) — this determines ongoing Intune policy targeting, not just the OOBE apps.
- Confirm account type (Standard vs Administrator) matches intent; cross-check the Entra "Local administrator settings" conflict table if it doesn't.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Cut a device fleet over from classic Autopilot to device preparation</summary>

1. Build the device prep policy, device group (with correct ownership), and user group first — fully validate with one pilot device before any bulk cutover.
2. For each device currently on classic Autopilot: deregister it (Windows Autopilot devices → select → Delete) *before* re-imaging/re-running OOBE. Device prep will not override an existing classic Autopilot registration.
3. Re-run OOBE (factory reset or fresh image).
4. Confirm via Monitor tab that the device appears under device preparation deployments, not the classic Autopilot enrollment log.
5. **Rollback:** if device prep proves unsuitable mid-migration (e.g., Hybrid Join is actually required), classic Autopilot registration can be re-added via `Autopilot/Scripts/Upload-Hash-Enroll2Autopilot.ps1` — this is non-destructive to the device itself, only to the intended enrollment path for future re-images.

</details>

<details><summary>Playbook 2 — Fix a device group that won't accept Intune Provisioning Client as owner</summary>

```powershell
Connect-MgGraph -Scopes "Group.ReadWrite.All","Application.Read.All"
$spAppId = "f1346770-5b25-470b-88bd-d5744ab7952c"
$sp = Get-MgServicePrincipal -Filter "appId eq '$spAppId'"

if (-not $sp) {
    Write-Warning "Intune Provisioning Client service principal not present in this tenant."
    Write-Warning "Provision it per MS Learn: 'Adding the Intune Provisioning Client service principal' before proceeding."
} else {
    $groupId = "<deviceGroupObjectId>"
    New-MgGroupOwnerByRef -GroupId $groupId -BodyParameter @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.Id)"
    }
    Write-Host "Ownership assigned. Verify in the device prep policy that '0 groups assigned' clears within a few minutes."
}
```

If the UI still shows "0 groups assigned" after confirmed ownership (a known intermittent bug), the documented workaround is to create a brand-new assigned group with ownership set correctly from creation, and repoint the policy at the new group — there is no destructive rollback concern since group membership for existing devices can be manually re-added if needed.

</details>

<details><summary>Playbook 3 — Resolve the Entra "Local administrator settings" conflict</summary>

The device prep policy's **User account type** and Entra ID's **Local administrator settings** (Entra admin center → Devices → Device settings) can silently conflict, causing provisioning to skip entirely — the user reaches desktop without the intended apps, and possibly with the wrong privilege level. Use this exact combination table (do not guess-toggle in production):

| Desired outcome | Entra "Local administrator settings" | Device prep "User account type" |
|---|---|---|
| Standard user (option 1) | None | Administrator |
| Standard user (option 2) | Selected, standard users NOT selected | Administrator |
| Standard user (option 3) | All | Standard user |
| Administrator user (option 1) | All | Administrator |
| Administrator user (option 2) | Selected, admin users selected | Administrator |

Note the counter-intuitive pattern: to get a *Standard* end result, the device prep setting is usually **Administrator** — the two settings interact rather than stacking additively. Verify against the table before changing either setting in a production tenant.

**Rollback:** setting changes here are policy-level and reversible; no device-side state is destroyed by correcting the combination, but affected devices already provisioned under a conflicting combination will need re-provisioning (factory reset) to pick up the corrected apps/scripts — the conflict causes those to be skipped entirely, not deferred.

</details>

<details><summary>Playbook 4 — Diagnose and reduce Windows 365/Cloud PC device prep timeouts</summary>

1. Confirm the tenant is still affected (fix shipped Feb 2026 for most cases) by checking whether "Minutes allowed before device preparation fails" in the Cloud PC provisioning policy is being honored — if deployments still cap near 60 minutes despite a higher configured value, treat as unresolved.
2. As an interim mitigation, reduce blocking apps in the device prep policy — move non-critical apps to device-group assignment without selecting them in the policy (they'll deliver post-OOBE instead).
3. Re-test with a pilot Cloud PC before applying fleet-wide.
4. If still failing on a current, patched tenant build, this is a live regression — escalate with Microsoft Support rather than continuing to trim the app list, since that's a workaround, not a fix.

No destructive rollback risk; this playbook only changes what's blocking vs. non-blocking during OOBE.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Windows Autopilot device preparation readiness evidence for a specific
    device group + policy pairing, for escalation or pre-deployment validation.
.DESCRIPTION
    Read-only. Checks device group type/eligibility/ownership, RBAC permission presence
    on a supplied admin UPN (best-effort — full custom role permission enumeration
    requires reading role definition permissions, not just role assignments), and
    reports whether the Intune Provisioning Client service principal exists in the tenant.
    Does not call any Intune device-preparation-policy Graph endpoint directly, since the
    device preparation policy object itself is only exposed via the Intune UI/undocumented
    beta endpoints at time of writing — this script covers the Entra-side prerequisites only.
.NOTES
    Requires: Microsoft.Graph.Groups, Microsoft.Graph.Applications, Microsoft.Graph.Identity.DirectoryManagement modules.
    Scopes: Group.Read.All, Application.Read.All, RoleManagement.Read.Directory
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DeviceGroupObjectId,
    [string]$AdminUpn
)

Connect-MgGraph -Scopes "Group.Read.All","Application.Read.All","RoleManagement.Read.Directory"

$spAppId = "f1346770-5b25-470b-88bd-d5744ab7952c"
$sp = Get-MgServicePrincipal -Filter "appId eq '$spAppId'"
Write-Host "Intune Provisioning Client SP present in tenant: $([bool]$sp)" -ForegroundColor $(if ($sp) {"Green"} else {"Red"})

$group = Get-MgGroup -GroupId $DeviceGroupObjectId -Property "displayName,groupTypes,isAssignableToRole,membershipRule"
Write-Host "Group: $($group.DisplayName)"
Write-Host "  Dynamic membership rule present: $([bool]$group.MembershipRule)" -ForegroundColor $(if ($group.MembershipRule) {"Red"} else {"Green"})
Write-Host "  Assignable to Entra roles: $($group.IsAssignableToRole)" -ForegroundColor $(if ($group.IsAssignableToRole) {"Red"} else {"Green"})

$owners = Get-MgGroupOwner -GroupId $DeviceGroupObjectId
$hasCorrectOwner = $owners | Where-Object { $_.Id -eq $sp.Id }
Write-Host "  Intune Provisioning Client is owner: $([bool]$hasCorrectOwner)" -ForegroundColor $(if ($hasCorrectOwner) {"Green"} else {"Red"})

if ($AdminUpn) {
    Write-Host "`nRBAC check for $AdminUpn (best-effort — verify 'Enrollment time device membership assignment' and 'Device configurations: Assign' manually in Entra admin center role definitions if this section is inconclusive):"
    $user = Get-MgUser -UserId $AdminUpn
    $assignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($user.Id)'"
    $assignments | ForEach-Object {
        $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $_.RoleDefinitionId
        Write-Host "  Assigned role: $($roleDef.DisplayName)"
    }
}
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MgServicePrincipal -Filter "appId eq 'f1346770-5b25-470b-88bd-d5744ab7952c'"` | Confirm Intune Provisioning Client / Intune Autopilot ConfidentialClient exists in tenant |
| `Get-MgGroup -GroupId <id> -Property "groupTypes,isAssignableToRole,membershipRule"` | Confirm device group is assigned (not dynamic) and not role-assignable |
| `Get-MgGroupOwner -GroupId <id>` | Confirm current owners of the device group |
| `New-MgGroupOwnerByRef -GroupId <id> -BodyParameter @{...}` | Add Intune Provisioning Client as group owner |
| `Get-MgGroupMember -GroupId <id>` | Confirm devices landed in the group post-enrollment |
| `winver` (on device) | Confirm Windows build meets minimum requirement |
| Intune admin center → Windows Autopilot devices | Confirm device isn't shadowed by classic Autopilot registration/profile |
| Intune admin center → Device preparation → Monitor | Real-time deployment status, per-app/script pass-fail |
| `Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<userId>'"` | List roles assigned to an admin managing device prep |
| `Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId <id>` | Inspect a role definition's permissions (for RBAC troubleshooting) |
| Entra admin center → Devices → Device settings | Check "Local administrator settings" for the account-type conflict |
| `Set-TimeZone -Id "UTC"` (on device, historical workaround) | Workaround for the (resolved) non-UTC deployment failure bug |

---
## 🎓 Learning Pointers
- Read [Overview of Windows Autopilot device preparation](https://learn.microsoft.com/en-us/autopilot/device-preparation/overview) first — the Enrollment Time Grouping section explains exactly why this is architecturally different from classic Autopilot, not just a rebrand.
- The [requirements page](https://learn.microsoft.com/en-us/autopilot/device-preparation/requirements) has an RBAC tab listing the exact permission set — cross-check any custom Autopilot admin role against it before assuming a permission error is a bug.
- [Reporting and monitoring](https://learn.microsoft.com/en-us/autopilot/device-preparation/reporting-monitoring) documents exactly what is and isn't tracked in the Monitor tab — useful for setting correct expectations with a customer about "why didn't the report show my compliance policy applying."
- Bookmark the [known issues page](https://learn.microsoft.com/en-us/autopilot/device-preparation/known-issues) — this is one of the fastest-moving Intune features in terms of documented, dated bug fixes; always check the date before treating a "known issue" as still current.
- The classic-Autopilot-precedence rule is undocumented as a "gotcha" anywhere prominent — it's stated plainly in the FAQ but easy to miss on first read. Treat it as the first thing to rule out on any "device prep isn't launching" ticket.
- Cross-reference `Autopilot/Troubleshooting/HybridJoin-Autopilot-A.md` and `Profile-Not-Assigned-A.md` for the classic-Autopilot side of this comparison — useful when advising a customer on which enrollment mode fits their environment (Hybrid Join requirement rules out device prep entirely).
