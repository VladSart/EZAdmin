# Intune Remote Help — Windows Unattended Support (Mode A: Deep Dive)
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
- **Remote Help — Windows Unattended Support with Remote Sign-In**, shipped in Intune Suite Service Release 2608 (August 2026): a session mode letting an authorized helper access and control a physical, corporate-owned, Intune-managed Windows device without an end user present or accepting a per-session prompt.
- The Azure Virtual Desktop Agent / Agent Bootloader deployment model this feature depends on, the dedicated RBAC permission, device eligibility rules, and the session lifecycle (start, in-progress, user-reclaim, end).

**Out of scope, with pointers:**
- **Attended Remote Help** (`RemoteHelp.exe`, view-only/full-control/elevation sessions with the sharer present) — a related but architecturally separate app and permission set. See `RemoteHelp-A.md`/`-B.md`. This document assumes the reader already understands the shared tenant-wide `remoteAssistanceState` switch and Conditional Access setup covered there and does not repeat that material in full.
- **Android unattended control** — a different permission (`Remote Help — Unattended`, i.e. `remoteAssistance_androidUnattendedControl` in RBAC) scoped to Android dedicated devices only, unrelated to the Windows agent stack described here. Covered briefly in `RemoteHelp-A.md`'s RBAC table.
- **Windows 365 / Azure Virtual Desktop's own connection stack** (RDP directly to a Cloud PC or session host) — a different product entirely. Unattended Remote Help explicitly does **not** support connecting *to* a Cloud PC or AVD host as the target; it targets physical hardware only. See `Azure/Windows365/Windows365-A.md` for the Cloud PC connection stack itself.
- General Win32 app deployment troubleshooting for the agent packages themselves (detection rules, content sync, install failures unrelated to Remote Help) — see `Intune/Troubleshooting/App-Deployment-A.md`.

**Assumed baseline:**
- Tenant already has attended Remote Help configured and working (`remoteAssistanceState = enabled`, appropriate licensing) — unattended support builds on top of this, it doesn't replace it.
- Target devices are enrolled in Intune, Microsoft Entra joined or Microsoft Entra hybrid joined, and physically exist as corporate-owned hardware (not virtual, not personal).
- Reader has `DeviceManagementConfiguration.Read.All`, `DeviceManagementRBAC.Read.All`, `DeviceManagementManagedDevices.Read.All`, and `DeviceManagementApps.Read.All` Graph scopes available for the checks in this document.
- Feature availability assumes a tenant on or past Intune Suite Service Release 2608; a tenant that hasn't yet received this service release may not show the unattended option at all regardless of configuration — confirm current release version before deep troubleshooting on an unexpectedly-missing feature.

---

## How It Works

<details><summary>Full architecture</summary>

### Why a Separate App Stack Exists

Attended Remote Help (`RemoteHelp.exe`) is architecturally built around a *sharer present and consenting* model — its entire UI, session-code exchange, and notification flow assume a human on the other end actively accepting a connection. Unattended support needed a fundamentally different mechanism: the ability to establish a session against a device's **login screen itself**, before or without any user session existing. Rather than retrofit the attended client, Microsoft built unattended support on top of the **Azure Virtual Desktop (AVD) connection infrastructure** — the same remoting stack that powers Windows 365 and AVD session hosts — repurposed to connect to a physical endpoint instead of a cloud session host.

This is why the target device needs the **AVD Agent** (`RDAgent` service) and **AVD Agent Bootloader** (`RDAgentBootLoader` service) installed, not `RemoteHelp.exe`. These are the same binaries Microsoft ships for AVD session hosts, registering the physical Windows device as a connectable endpoint within Microsoft's remoting control plane — but scoped, for this feature, to a single physical machine rather than a session-host pool. The registration token field in the installer is deliberately left as the auto-populated `INVALID_TOKEN` placeholder for this scenario: Intune orchestrates the actual connection authorization out-of-band via the Remote Help/Intune admin-center flow, not via AVD host-pool registration.

### Session Establishment Flow

1. Helper (with the dedicated RBAC permission) selects a target device in **Devices > All devices**, then **New remote assistance session > Remote Help > Continue > Initiate unattended control**.
2. Intune validates, server-side, that: the helper has the permission scoped to this device; the device isn't a personal/BYOD device; the device is currently reporting compliant-or-warns-only state; and the device meets the documented prerequisites (agent stack, IME). Any failure here surfaces as an explicit, specific notification to the helper — this is a deliberate design choice so helpers aren't left guessing which prerequisite is missing.
3. Intune orchestrates the connection through the AVD control plane and IME on the target, and the admin center shows real-time progress while this happens.
4. Once ready, the helper's browser opens a new tab launching **Windows App (web client)** — the same client technology used for Windows 365/AVD web access — and the helper signs in with the same account used for the Intune admin center.
5. Inside the session, the helper authenticates a **second time**, at the Windows sign-in screen itself, using one of: a local Windows account (`ComputerName\UserName`), an Active Directory domain account (`Domain\UserName`), a UPN, or a Microsoft Entra ID account (UPN). This second authentication is enforced with least privilege — signing in as a standard user does not grant admin rights just because the connection is "unattended."

### The Two Session Sub-Scenarios

**No user signed in:** the unattended session starts immediately with no notification to anyone, since there is no active user session to interrupt.

**A user IS actively signed in:** Windows displays a notification on the device. The signed-in user can select **Yes** (continue) or **No** (cancel). If they don't respond within **30 seconds**, the session **auto-starts** — this is intentional (the design assumption is that a device left unattended with a pending, unanswered notification is itself evidence no one is actively at the keyboard) but is worth explaining proactively to security-conscious customers, since it means a helper can gain access even from a device that technically has someone "signed in" but away from their desk.

When the session auto-starts or is accepted, the user's **existing session is locked and preserved** (not terminated) and the helper connects into a **separate Windows session** on the same device. The original user cannot observe helper activity, but they retain the ability to reclaim the device at any moment by signing back in at the lock screen — at which point they're notified a support session is active and offered the choice to let it continue or disconnect it. This reclaim-at-will design is the core privacy/control balance Microsoft built into the feature: IT gets access without requiring presence, but the end user is never fully locked out of their own device.

### Post-Session State

When the session ends (by either party, or by timeout), the device returns to its pre-session state and the original user's session — with all open work — remains exactly as it was. No data loss is documented as part of normal session teardown.

</details>

---

## Dependency Stack

```
Layer 7 — Session Layer
  Windows App (web client) session, authenticated twice (admin-center identity,
  then in-session Windows sign-in) — least privilege enforced at the second auth

Layer 6 — Orchestration Layer
  Intune Management Extension (IME) on the target device — receives and
  orchestrates the unattended connection request

Layer 5 — Connectivity Layer
  Remote Desktop enabled on the target (Windows settings catalog CSP) +
  Windows Firewall permitting RDP traffic + device powered on and online
  (no wake capability — asleep/hibernating/off devices are unreachable)

Layer 4 — Remoting Agent Layer
  Azure Virtual Desktop Agent (RDAgent) installed FIRST, then
  Azure Virtual Desktop Agent Bootloader (RDAgentBootLoader) — bootloader
  has a hard dependency on the agent being present

Layer 3 — Device Eligibility Layer
  Physical hardware (NOT Cloud PC / AVD host) + corporate-owned (NOT BYOD) +
  x64 architecture (NOT ARM64) + Microsoft Entra joined or hybrid joined +
  Intune-enrolled

Layer 2 — RBAC Layer
  Helper's Intune role includes "Remote Help app - Windows unattended
  control remote sign-in", explicitly scoped to the target device's group
  (NOT present in any built-in role — must be added to a custom role)

Layer 1 — Tenant Layer
  remoteAssistanceState = enabled (shared switch with attended Remote Help)
  Intune Suite Service Release 2608 or later applied to the tenant
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Initiate unattended control" option doesn't appear at all for the helper | Helper's role lacks the unattended-remote-sign-in permission (Help Desk Operator alone is insufficient) | `Get-MgDeviceManagementRoleDefinition` filtered for the permission string |
| Option appears but selecting it immediately shows "not supported for this device" | Device fails eligibility — Cloud PC, AVD host, BYOD, or ARM64 | `Model`/`Manufacturer`/`ManagedDeviceOwnerType` on the managed device object |
| Option appears, helper is eligible, device is eligible, but connection times out with "prerequisites missing" | Agent stack (RDAgent/RDAgentBootLoader) not installed, or IME not running | Local service check on target, or Win32 app assignment/install status in Intune |
| Agent services show "not installed" despite app deployment showing "succeeded" in Intune | Bootloader installed before agent completed (dependency misconfigured), or content sync issue | Verify app dependency chain configuration; check `IntuneManagementExtension.log` on target |
| Connection reaches the device but fails at the Windows sign-in screen inside the session | Helper is using invalid/mistyped credentials for the SECOND authentication (device-local), not the admin-center identity | Confirm the account format used (`ComputerName\User`, `Domain\User`, or UPN) matches what the target actually accepts |
| Session starts but helper has no admin rights despite expecting them | Least-privilege enforcement is working as designed — the account used for in-session sign-in determines privilege, not the helper's Intune role | Use an account with the appropriate local/domain privilege for the in-session sign-in, not just Intune RBAC |
| "Device not reachable" or connection hangs indefinitely | Device asleep, hibernating, or powered off — unattended has no wake mechanism | Confirm power state via last-check-in time and, if available, physical/RMM confirmation |
| Second attempt fails immediately with a generic error, first attempt "succeeded" but nothing visibly connected | A prior session didn't tear down cleanly and is still counted as active — one unattended session per device at a time | Check session history in the admin center; force-end if a stale session is shown active |
| Feature entirely absent from the admin center regardless of RBAC/licensing | Tenant hasn't received Intune Suite Service Release 2608 yet | Confirm current service release version against Microsoft's release notes |
| Works for one device in a group but not a near-identical device in the same group | Per-device agent install state differs — group-level assignment success doesn't guarantee every device actually completed install | Per-device Win32 app install status, not just assignment-level reporting |
| User complains IT accessed their device without warning | Expected behavior if no one was signed in at the time, or if the 30-second notification window elapsed unanswered | Confirm against session start time and device sign-in state — not a bug to "fix" |
| Helper reports full control works but file transfer/clipboard is unavailable | Local resource redirection (file transfer, clipboard, virtual printer) is a per-session opt-in prompt, not automatic | Confirm the helper accepted the local-resource-access prompt when connecting |

---

## Validation Steps

1. **Confirm tenant service release eligibility.** Cross-reference the tenant's current Intune service release against Microsoft's release notes for Suite Service Release 2608 or later. Good: feature-eligible. Bad: the admin center simply won't offer "Initiate unattended control" as an option, and no amount of RBAC/agent work will surface it.

2. **Confirm the tenant-wide switch.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings"
   ```
   Good: `remoteAssistanceState = enabled`. Bad: `disabled` — blocks both attended and unattended identically.

3. **Confirm the helper's RBAC grant, scoped correctly.**
   ```powershell
   Get-MgDeviceManagementRoleDefinition -All | Where-Object {
     $_.RolePermissions.ResourceActions.AllowedResourceActions -match 'remoteAssistance_windowsUnattendedControlRemoteSignIn'
   }
   ```
   Good: at least one role definition matches, and the helper's assignment scope includes the target device's group. Bad: no match (permission was never added to any custom role) or the role exists but the helper's specific assignment scope excludes the target device.

4. **Confirm target device eligibility before troubleshooting further.**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
     Select DeviceName, Model, Manufacturer, OperatingSystemVersion, ManagedDeviceOwnerType, JoinType
   ```
   Good: physical OEM model/manufacturer, `ManagedDeviceOwnerType = company`, x64 OS. Bad: model/manufacturer strings indicating a virtual/Cloud PC device, or `personal` ownership — stop here, this device will never be eligible.

5. **Confirm both agent apps are assigned and reporting installed for this specific device**, not just assigned at the group level.
   ```powershell
   Get-MgDeviceAppManagementMobileAppInstallSummary -MobileAppId "<agentAppId>"
   ```
   Good: device-level install status shows succeeded for both the agent and bootloader apps. Bad: assignment shows targeted but install status is pending, failed, or not applicable.

6. **Confirm local agent service state directly on the device** (requires local or RMM access).
   ```powershell
   Get-Service -Name RDAgent, RDAgentBootLoader, IntuneManagementExtension | Select Name, Status, StartType
   ```
   Good: all three `Running`. Bad: any stopped or missing — trace back to the corresponding Win32 app's install log.

7. **Confirm Remote Desktop is actually enabled locally**, not just that a profile targets the device.
   ```powershell
   Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections
   ```
   Good: `0`. Bad: `1` or the profile never applied — check Configuration > Policies > [profile] > Device status in the admin center for this specific device.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Scope the failure mode.** Does the option not appear at all (RBAC/service-release), appear but reject the device immediately (eligibility), appear and attempt but time out (agent/IME/connectivity), or connect but fail at the in-session Windows sign-in (credential format/local account)? Each phase below maps to one of these.

**Phase 2 — RBAC and service release.** Confirm service release version and the helper's specific permission grant and scope (Validation Steps 1 and 3). This phase resolves "option doesn't appear" tickets, which are the most common first-deployment issue.

**Phase 3 — Device eligibility.** Confirm physical/corporate-owned/x64/joined-state (Validation Step 4) before spending any time on agent deployment — an ineligible device will reject the session instantly regardless of agent state, and diagnosing agent issues on an ineligible device wastes triage time.

**Phase 4 — Agent and orchestration layer.** Confirm both Win32 apps installed in the correct order and both services running, plus IME (Validation Steps 5–6). This phase resolves the bulk of "times out with prerequisites missing" tickets.

**Phase 5 — Connectivity and power state.** Confirm RDP enabled locally, firewall permits it, and the device is powered on and online. A device that's merely asleep produces symptoms identical to an agent failure from the helper's side — always check power state here even if agent checks passed.

**Phase 6 — In-session authentication.** If the connection itself succeeds but the Windows sign-in inside the session fails, this is unrelated to everything above — confirm the helper is using a correctly-formatted local/domain/UPN account with appropriate privilege for the target device, not their Intune admin-center identity.

**Phase 7 — Concurrency and session hygiene.** If a device that previously worked now instantly rejects new attempts, check for a stale prior session before re-investigating agent/RBAC layers that hadn't previously been a problem.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full unattended-support rollout to a new device group</summary>

1. Confirm tenant service release ≥ 2608 and `remoteAssistanceState = enabled`.
2. Build (or extend) a custom Intune role containing **Remote Help app - Windows unattended control remote sign-in**, scoped to the target Tier 3/senior-helpdesk security group as the assignee and the intended device group as the scope group.
3. Package the AVD Agent and AVD Agent Bootloader as separate Win32 apps; configure the bootloader with an **Automatically install** dependency on the agent app.
4. Assign both apps to the target device group.
5. Create a Windows settings catalog profile enabling **Allow users to connect remotely by using Remote Desktop Services**; assign to the same device group. Confirm firewall baseline permits inbound RDP.
6. Pilot against 2–3 known-eligible physical devices before full rollout; validate both the "user signed in, notification/accept flow" and "no user signed in, immediate start" scenarios.
7. Document the eligibility gate (physical/corporate/x64/joined) in customer-facing rollout communication so helpdesk doesn't field confused tickets about Cloud PCs or BYOD devices being excluded.

Rollback: disable the custom role assignment (or remove the permission from the role) to immediately revoke unattended capability without touching the agent deployment; uninstalling the agent apps is a separate, non-urgent cleanup step if fully decommissioning the feature.

</details>

<details><summary>Playbook 2 — Diagnosing a device that "used to work" and now doesn't</summary>

1. Confirm nothing changed at the tenant/RBAC layer first (a role edit or scope change affecting many devices at once is more likely than a single-device local failure).
2. Check the device's current agent service state locally or via RMM — an agent update, a conflicting endpoint protection policy, or a manual uninstall are the most common single-device regressions.
3. Check for Windows Update-driven changes to the Remote Desktop or firewall configuration that could have reset the settings catalog profile's effect (rare, but settings catalog profiles reapply on a schedule, not continuously).
4. Check session history for a stuck prior session before assuming a configuration regression.
5. If isolated to one device and no clear cause emerges, a full agent stack reinstall (uninstall bootloader, uninstall agent, redeploy in order) resolves the majority of single-device cases without further investigation.

Rollback: none needed — this playbook is diagnostic/corrective, not destructive, at every step.

</details>

<details><summary>Playbook 3 — Responding to a user privacy/trust complaint about unattended access</summary>

1. Pull the session record for the device/time in question from Intune audit logs and Remote Help session history — confirm helper identity, start/end time, and whether the session auto-started (no user signed in) or was accepted/timed-out (user signed in).
2. Explain the documented behavior plainly: sessions cannot observe or be observed mid-session by the original user, the user can reclaim the device at any time by signing in, and Microsoft does not record session content (screen/keystrokes) — only session metadata, retained 30 days.
3. If the complaint centers on the 30-second auto-start window specifically, this is a legitimate design discussion (not a bug) — the tenant's RBAC scoping is the actual control lever here: unattended access should only be granted to devices/users where this behavior has been communicated and accepted as part of the support model.
4. If governance needs tightening, narrow the custom role's scope group rather than trying to change the 30-second window, which isn't configurable.

Rollback: not applicable — this is a communication/governance playbook, not a technical remediation.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only evidence collector for a Remote Help Windows Unattended Support escalation.
.DESCRIPTION
    Run with Graph scopes: DeviceManagementConfiguration.Read.All, DeviceManagementRBAC.Read.All,
    DeviceManagementManagedDevices.Read.All, DeviceManagementApps.Read.All
    Does not modify any tenant, device, or role configuration.
#>
param(
    [Parameter(Mandatory)] [string]$DeviceName,
    [Parameter(Mandatory)] [string]$HelperUpn
)

$evidence = [ordered]@{}

$evidence.TenantSetting = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings"

$evidence.Device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$DeviceName'" |
  Select-Object DeviceName, Model, Manufacturer, OperatingSystemVersion, ManagedDeviceOwnerType, ComplianceState

$evidence.HelperRoles = Get-MgDeviceManagementRoleAssignment -All |
  Where-Object { (Get-MgDeviceManagementRoleAssignmentMember -RoleAssignmentId $_.Id) -contains $HelperUpn } |
  ForEach-Object {
    $role = Get-MgDeviceManagementRoleDefinition -RoleDefinitionId $_.RoleScopeTagIds
    [PSCustomObject]@{
      RoleName             = $role.DisplayName
      HasUnattendedPerm     = $role.RolePermissions.ResourceActions.AllowedResourceActions -match 'remoteAssistance_windowsUnattendedControlRemoteSignIn'
    }
  }

$evidence.AgentApps = Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Remote Desktop Services Infrastructure Agent') or contains(displayName,'Remote Desktop Agent Boot Loader')" |
  Select-Object Id, DisplayName, PublishingState

$evidence | ConvertTo-Json -Depth 6 | Out-File ".\RemoteHelpUnattended-Evidence-$DeviceName-$(Get-Date -Format yyyyMMdd-HHmm).json"
Write-Host "Evidence written. Attach the JSON file plus local service-state output (RDAgent/RDAgentBootLoader/IntuneManagementExtension/fDenyTSConnections) captured directly on the target device." -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Tenant-wide switch | `Invoke-MgGraphRequest -Method GET -Uri ".../remoteAssistanceSettings"` |
| Find roles with the unattended permission | `Get-MgDeviceManagementRoleDefinition -All \| Where RolePermissions...AllowedResourceActions -match 'windowsUnattendedControlRemoteSignIn'` |
| Device eligibility snapshot | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<name>'" \| Select Model,Manufacturer,ManagedDeviceOwnerType,JoinType` |
| Agent apps in catalog | `Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Remote Desktop Services Infrastructure Agent')"` |
| Per-device install status | `Get-MgDeviceAppManagementMobileAppInstallSummary -MobileAppId "<id>"` |
| Local agent service state | `Get-Service RDAgent, RDAgentBootLoader, IntuneManagementExtension` |
| Local RDP enabled check | `Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections` |
| Restart orchestration service | `Restart-Service IntuneManagementExtension` |
| Confirm attended tenant CA service principal (shared setup) | `New-MgServicePrincipal -AppId "1dee7b72-b80d-4e56-933d-8b6b04f9a3e2"` |

---

## 🎓 Learning Pointers
- **Unattended support is built on AVD remoting infrastructure, not the attended Remote Help client.** This architectural choice explains almost every "why don't the same fixes apply" confusion between the two modes — they share a UI entry point and a tenant switch, and nothing else in the actual connection mechanism. See [Deploy Remote Help](https://learn.microsoft.com/en-us/intune/remote-help/deploy#unattended-support).
- **The unattended RBAC permission is deliberately excluded from every built-in role.** Treat this as an intentional high-trust gate, not an oversight — plan custom-role scoping as part of initial rollout design, not as a reactive fix. See [Role-based access control (RBAC)](https://learn.microsoft.com/en-us/intune/remote-help/plan#role-based-access-control-rbac).
- **Device eligibility (physical/corporate/x64/joined) is absolute — there is no override.** Don't let a customer request "just enable it for our Cloud PCs too" turn into a lengthy troubleshooting exercise; it's a documented, non-configurable exclusion. See [Supported platforms](https://learn.microsoft.com/en-us/intune/remote-help/plan#supported-platforms).
- **The 30-second auto-start behavior when a user is present is a documented, intentional design, not a race condition or bug** — factor it into customer privacy/governance conversations proactively rather than treating user complaints about it as a technical defect to fix. See [Get help — unattended note](https://learn.microsoft.com/en-us/intune/remote-help/start-session#get-help).
- **In-session authentication is a second, independent identity boundary from the admin-center identity used to launch the session.** A helper with full Intune RBAC access can still be denied local privilege inside the session if they sign in with an under-privileged account — this is least-privilege working as designed, not a bug to escalate.
- This feature shipped in Intune Suite Service Release 2608 (August 2026) — re-verify current documentation before engagements, since Microsoft has stated Remote Help continues to evolve rapidly (see the shared Planning Considerations note in `RemoteHelp-A.md`). See [Remote Help on Windows: Unattended Support with Remote Sign-In Is Here](https://techcommunity.microsoft.com/blog/intunecustomersuccess/remote-help-on-windows-unattended-support-with-remote-sign-in-is-here/4549772).
