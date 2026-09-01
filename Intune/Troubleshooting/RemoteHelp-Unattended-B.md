# Intune Remote Help — Windows Unattended Support (Mode B: Ops)
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

**Windows Unattended Support with Remote Sign-In** (Intune Suite Service Release 2608, August 2026) lets an authorized helper sign in to a physical, corporate-owned, Intune-managed Windows device **without an end user present**, straight from the login screen. It is a **separate app stack and RBAC permission** from attended Remote Help (`RemoteHelp.exe`) — don't debug this ticket against `RemoteHelp-B.md`'s dependency chain; the two share only the tenant-wide enable switch and Conditional Access hookup. See `RemoteHelp-Unattended-A.md` for full architecture.

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementRBAC.Read.All","DeviceManagementManagedDevices.Read.All","DeviceManagementApps.Read.All"

# 1. Tenant-wide switch (shared with attended Remote Help — check this first regardless of mode)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings" |
  Select remoteAssistanceState, allowSessionsToUnenrolledDevices

# 2. Does the helper's role actually carry the UNATTENDED permission specifically?
#    (Help Desk Operator does NOT include this by default — a common gap)
Get-MgDeviceManagementRoleDefinition -All |
  Where-Object { $_.RolePermissions.ResourceActions.AllowedResourceActions -match 'remoteAssistance_windowsUnattendedControlRemoteSignIn' } |
  Select DisplayName, IsBuiltIn

# 3. Is the target device even eligible? (physical, Entra joined/hybrid joined, x64, Intune-managed)
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
  Select DeviceName, OperatingSystem, Model, Manufacturer, JoinType, ManagedDeviceOwnerType, ComplianceState

# 4. Are BOTH the AVD Agent and AVD Agent Bootloader Win32 apps deployed and installed on this device?
#    (RemoteHelp.exe is NOT what unattended uses — this is the #1 confusion point)
Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Remote Desktop Services Infrastructure Agent') or contains(displayName,'Remote Desktop Agent Boot Loader')" |
  Select Id, DisplayName, PublishingState

# 5. On the TARGET device itself — is the agent stack actually running? (requires local/RMM access)
Get-Service -Name RDAgent, RDAgentBootLoader -ErrorAction SilentlyContinue | Select Name, Status
Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue | Select Status
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -ErrorAction SilentlyContinue
```

| Finding | Interpretation | Do this |
|---|---|---|
| `remoteAssistanceState = disabled` | Nothing works tenant-wide — shared blocker with attended Remote Help | Go to [Fix 1](#common-fix-paths) |
| No role matches the unattended-remote-sign-in permission | Helper cannot even see "Initiate unattended control" as an option — Help Desk Operator alone is NOT enough | Go to [Fix 2](#common-fix-paths) |
| Target device model/manufacturer indicates a Cloud PC or Azure Virtual Desktop host, or `ManagedDeviceOwnerType = personal` | Hard product limitation — unattended control is physical corporate-owned devices only, full stop | Not fixable — see [Escalation](#escalation-evidence); redirect to attended support instead |
| Target device architecture is ARM64 | Unattended support requires x64 — ARM64 devices are not eligible | Not fixable — attended support still works on ARM64 |
| AVD Agent / Bootloader apps missing from catalog or not assigned to the device's group | Agent stack was never deployed — this is the single most common cause of "no unattended option" on an otherwise-eligible device | Go to [Fix 3](#common-fix-paths) |
| `RDAgent` service present but `RDAgentBootLoader` missing or stopped | Bootloader wasn't installed, or was installed before the agent (wrong order) | Go to [Fix 4](#common-fix-paths) |
| `fDenyTSConnections = 1` (or key absent with RDP not enabled) | Remote Desktop is disabled locally — the settings catalog profile never applied or was never assigned | Go to [Fix 5](#common-fix-paths) |
| IME service not running on target | Unattended session orchestration cannot start — same dependency as admin-center remote-launch for attended sessions | Go to [Fix 6](#common-fix-paths) |
| Helper sees "not supported" instantly on a device that otherwise looks eligible | Check for an existing unattended session already in progress — only one is allowed per device at a time | Go to [Fix 7](#common-fix-paths) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant setting: remoteAssistanceState = enabled
  (SHARED with attended Remote Help — same tenant-wide switch)
        │
        ▼
Helper's Intune role includes the "Remote Help app - Windows unattended
control remote sign-in" permission, explicitly scoped to the target device group
  (NOT included in built-in Help Desk Operator — must build/extend a custom role)
        │
        ▼
Target device is ELIGIBLE:
  - Physical hardware (NOT Windows 365 Cloud PC, NOT Azure Virtual Desktop,
    NOT any other virtual/session-host device)
  - Corporate-owned (NOT personal/BYOD)
  - x64 architecture (NOT ARM64)
  - Microsoft Entra joined OR Microsoft Entra hybrid joined
  - Enrolled/managed in Intune
        │
        ▼
Agent stack installed on the target device, IN ORDER:
  1. Azure Virtual Desktop Agent  (RDAgent service)
  2. Azure Virtual Desktop Agent Bootloader  (RDAgentBootLoader service — depends on #1)
  (deployed as two separate Win32 apps in Intune, with an explicit
   dependency relationship so #2 only installs after #1 is detected)
        │
        ▼
Intune Management Extension (IME) running on the target device
  (orchestrates the unattended session request — same role it plays for
   Win32 apps, Platform Scripts, Remediations, and attended remote-launch)
        │
        ▼
Remote Desktop enabled on the target device
  (via a Windows settings catalog profile — "Allow users to connect remotely
   by using Remote Desktop Services" — firewall must also permit RDP traffic)
        │
        ▼
Device powered on AND connected to the internet
  (asleep/hibernating/shut-down devices cannot receive unattended support —
   there is no wake-on-LAN integration)
        │
        ▼
No other unattended session already active on the device
  (hard limit: exactly one helper, one active unattended session, per device)
        │
        ▼
Session established → if a user IS signed in: notified, 30-second timeout
  before auto-start (or user accepts/declines) → if NO user is signed in:
  starts immediately → user's original session locked and preserved, helper
  connects to a SEPARATE Windows session via the Remote Desktop web client
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the tenant-wide switch first — shared with attended Remote Help.**
   `remoteAssistanceState` must be `enabled`. If this is the only thing wrong, both attended and unattended tickets for this tenant will show the same root cause.

2. **Confirm the helper's role has the UNATTENDED permission specifically, not just general Remote Help access.**
   This is the single most common gap: an admin assigns Help Desk Operator, assumes unattended is included (it includes attended View/Full control/Elevation, plus Android unattended — but not Windows unattended remote sign-in), and the option simply doesn't appear for the helper. A custom role must explicitly add **Remote Help app - Windows unattended control remote sign-in**, scoped to the device groups that should receive it.

3. **Confirm the target device is actually eligible before chasing agent/service issues.**
   Check `Model`/`Manufacturer` for Cloud PC or AVD host indicators, confirm `ManagedDeviceOwnerType` is `company` not `personal`, and confirm the OS architecture is x64. A Windows 365 Cloud PC or an ARM64 device will never support unattended control no matter how the agent stack is configured — don't spend triage time here.

4. **Confirm both agent apps are deployed, in the correct dependency order, to the device's assignment group.**
   The AVD Agent must install before the Bootloader — Intune enforces this at the app-dependency level if configured correctly, but a manually-created deployment can get the order wrong. Check both `Get-MgDeviceAppManagementMobileApp` results and, if you have local/RMM access, confirm both services exist on the device.

5. **Confirm Remote Desktop is actually enabled on the device, not just that the profile exists.**
   A settings catalog profile can exist and show "Succeeded" in Intune while the device itself never received it (stale profile, conflicting GPO, or a scope/assignment miss). Check `fDenyTSConnections` locally — `0` means RDP is allowed, `1` or key-absent-with-service-disabled means it isn't.

6. **Confirm IME is running on the target — required for unattended orchestration specifically.**
   Same dependency as attended remote-launch notifications; if IME is stopped, nothing about unattended will work even with a perfect agent stack.

7. **Confirm the device is actually online.**
   Unattended support has no wake capability — a sleeping, hibernating, or powered-off device will fail silently from the helper's perspective ("device not reachable"), which can look identical to an agent/service problem if you don't check power state first.

8. **If everything above checks out but the session still won't start, check for a concurrent session.**
   Only one unattended connection is permitted per device at a time. A previous session that didn't clean up properly (helper disconnected without ending the session) can block new attempts until it times out or is force-ended from the admin center.

9. **Validate end-to-end with a real pilot device before closing the ticket.**
   Passing every prerequisite check does not guarantee the Remote Desktop web client handshake succeeds — network/proxy conditions at the target site can still break the connection even when every Intune-side setting is correct.

---
## Common Fix Paths

<details><summary>Fix 1 — Remote Help disabled tenant-wide</summary>

```powershell
$payload = @{
    "@odata.type"           = "#microsoft.graph.remoteAssistanceSettings"
    "remoteAssistanceState" = "enabled"
} | ConvertTo-Json

Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/beta/deviceManagement/remoteAssistanceSettings" `
  -Body $payload -ContentType "application/json"
```

No rollback risk — opt-in tenant switch shared with attended Remote Help. Allow up to 8 hours for full propagation before assuming it hasn't taken effect.

</details>

<details><summary>Fix 2 — Helper's role missing the unattended-remote-sign-in permission</summary>

There is no built-in role that includes this permission — it must be added to a custom role explicitly, in the Intune admin center under **Tenant administration > Roles**, category "Remote Help app", permission "Windows unattended control remote sign-in". Scope the role assignment narrowly (Tier 3 / senior helpdesk only, and only to the device groups that should be eligible) — this is a deliberately high-privilege permission.

```powershell
# Confirm exactly what a custom role currently grants before editing
(Get-MgDeviceManagementRoleDefinition -RoleDefinitionId "<roleDefinitionId>").RolePermissions.ResourceActions.AllowedResourceActions
```

No rollback concern for adding the permission itself — the risk to manage is over-broad scoping, not the grant.

</details>

<details><summary>Fix 3 — AVD Agent / Bootloader not deployed or not assigned</summary>

Package and deploy both installers as separate Win32 apps, agent first:

1. Download [AVD Agent](https://go.microsoft.com/fwlink/?linkid=2310011) and [AVD Agent Bootloader](https://go.microsoft.com/fwlink/?linkid=2311028).
2. Package each as a `.intunewin` file with the Win32 Content Prep Tool.
3. Create the **Remote Desktop Services Infrastructure Agent** Win32 app first — accept the auto-populated install/uninstall commands and MSI-based detection rule.
4. Create the **Remote Desktop Agent Boot Loader** Win32 app second — on its Dependencies page, add the agent app as an **Automatically install** dependency so Intune sequences the install correctly.
5. Assign both to the same device group(s) intended to receive unattended support.

When the installer prompts for a registration token during manual testing, leave the auto-populated `INVALID_TOKEN` value unchanged — this is expected and not an error.

No rollback risk — both are additive installs with no interaction with attended Remote Help or other endpoint agents.

</details>

<details><summary>Fix 4 — Bootloader missing/stopped or installed out of order</summary>

If the bootloader was pushed before the agent (e.g., dependency wasn't configured), uninstall and reassign in the correct order rather than trying to force-start the service — the bootloader is explicitly documented as depending on the agent being present first.

```powershell
# Confirm current state directly on the device
Get-Service -Name RDAgent, RDAgentBootLoader | Select Name, Status, StartType
```

Rollback note: uninstalling and redeploying is safe: neither agent interacts with user data or other management agents, but expect a brief window where unattended control is unavailable on that device during the redeploy.

</details>

<details><summary>Fix 5 — Remote Desktop not enabled on the target device</summary>

Create (or fix the assignment on) a Windows settings catalog profile:

- **Devices > Manage devices > Configuration > Create > New policy** — Platform: Windows 10 and later, Profile type: Settings catalog.
- Add setting: **Allow users to connect remotely by using Remote Desktop Services** → **Enabled**.
- Assign to the same device group(s) as the agent apps.
- Confirm the Windows Firewall allows inbound RDP traffic (a separate firewall rule may be needed depending on your baseline).

```powershell
# Verify locally after the profile should have applied
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections
# 0 = RDP allowed, 1 = RDP denied
```

No rollback risk — enabling RDP via this specific profile only affects Remote Desktop connectivity, and it can be reverted by disabling the setting and reassigning.

</details>

<details><summary>Fix 6 — IME not running on target device</summary>

```powershell
Restart-Service IntuneManagementExtension
```

No rollback risk — this is the same non-destructive service restart used for any IME-dependent feature (Win32 apps, Remediations, attended remote-launch).

</details>

<details><summary>Fix 7 — Session blocked by a stale concurrent unattended session</summary>

From the Intune admin center, go to the device's remote assistance session history and force-end any session shown as still active that the helper knows is actually over. If no admin-center control is available for the stuck session, a device restart clears the agent state (last resort — coordinate with the user/site since it will interrupt anything genuinely in progress if the session is in fact live).

</details>

---
## Escalation Evidence

```
REMOTE HELP — UNATTENDED SUPPORT ESCALATION
Tenant: <tenantName>
Helper UPN: <helperUPN>              Helper role assigned: <roleName>
Target device name: <deviceName>      Target device UPN (last signed-in user): <userUPN>

Tenant remoteAssistanceState: <enabled/disabled>

Helper role includes "Windows unattended control remote sign-in"? <yes/no>
  Role definition ID checked: <roleDefinitionId>

Target device eligibility:
  Model/Manufacturer: <value>          Physical (not Cloud PC/AVD)? <yes/no>
  Architecture: <x64/ARM64>            Join type: <Entra joined/hybrid joined/other>
  ManagedDeviceOwnerType: <company/personal>

Agent stack on target:
  RDAgent service: <running/stopped/not installed>
  RDAgentBootLoader service: <running/stopped/not installed>
  Install order confirmed correct (agent before bootloader)? <yes/no/unknown>
  IntuneManagementExtension service: <running/stopped>
  fDenyTSConnections value: <0/1/key absent>

Device power/connectivity at time of attempt: <online/offline/unknown>
Existing/stale unattended session detected? <yes/no>

Steps already attempted: <bullet list>
```

---
## 🎓 Learning Pointers
- **This is a genuinely separate app and permission stack from attended Remote Help — not an extension of it.** `RemoteHelp.exe` is irrelevant here; the target device needs the AVD Agent + Bootloader instead. Conflating the two deployment models is the most common cause of "I deployed Remote Help but unattended still doesn't work" tickets. See [Deploy Remote Help — Unattended support](https://learn.microsoft.com/en-us/intune/remote-help/deploy#unattended-support).
- **Help Desk Operator does not include the unattended permission by default.** Every other Remote Help capability ships in that built-in role; this one specifically requires a custom role, by design, since Microsoft treats unattended access as a higher-trust action warranting deliberate opt-in. See [Role-based access control (RBAC)](https://learn.microsoft.com/en-us/intune/remote-help/plan#role-based-access-control-rbac).
- **Eligibility is a hard device-type gate, not a licensing or config problem.** Windows 365 Cloud PCs, Azure Virtual Desktop session hosts, BYOD/personal devices, and ARM64 hardware are all explicitly unsupported for unattended control — no amount of agent redeployment will make an ineligible device work. See [Supported platforms](https://learn.microsoft.com/en-us/intune/remote-help/plan#supported-platforms).
- **The 30-second auto-start window applies only when a user IS signed in.** If no one is signed in, the session starts immediately with no notification or delay — this is expected behavior, not a bug, and should be explained to customers concerned about the auto-start timer.
- **A sleeping or powered-off device fails silently from the helper's side** — there's no wake mechanism. Always confirm power/connectivity state before escalating an "unattended session won't start" ticket past agent/permission checks.
- Cross-reference: `RemoteHelp-B.md` covers the shared tenant switch and Conditional Access setup in more depth for attended sessions; this file assumes those basics are already understood.
