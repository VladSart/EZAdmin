# Power Automate Desktop — Machine Runtime & Unattended RPA — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope:**
- Power Automate for desktop (PAD) machine registration, the Machine Runtime App, and direct connectivity (the model that replaced the on-premises data gateway for desktop flows)
- Attended and unattended desktop flow execution — session lifecycle, connection identity, error-code taxonomy
- Machine groups, maintenance mode, sharing/permissions, and Process/Unattended RPA capacity licensing as they affect run scheduling

**Explicitly out of scope, with cross-references:**
- Cloud flow ownership and connection-identity governance for non-desktop connectors (SharePoint, Outlook, etc.) — see `Troubleshooting/Flow-Ownership-Transfer-A.md`
- Connector authentication failures for standard (non-desktop-flow) connectors — see `Troubleshooting/Connector-Auth-B.md`
- DLP policy blocking of the desktop flow connector itself — see `Troubleshooting/DLP-Policies-A.md`
- Building or editing desktop flow automation logic (UI selectors, actions) — this is an infrastructure/runtime runbook, not an authoring guide
- The **on-premises data gateway** as used by cloud flows for other connectors (SQL, file system, etc.) — that gateway product is unrelated and still supported; only the *desktop-flow-specific* gateway model is retired

**Assumes:**
- Power Automate for desktop installed on the target Windows machine(s), version 2.8.73.21119 or later for direct connectivity
- Familiarity with Power Automate cloud flows (trigger/action model) — this document focuses on the machine/runtime layer beneath them
- Environment Maker, Desktop Flow Machine Owner, or Tenant/Environment Admin role for registration and machine-group administration

---
## How It Works

<details><summary>Full architecture — from gateway retirement to direct connectivity, sessions, and capacity</summary>

### The gateway is gone — direct connectivity is the only supported model

Historically, desktop flows connected to on-premises machines through the on-premises data gateway, the same product used for other on-premises connectors. **Gateways for desktop flows are no longer supported.** Every machine now connects directly to the Power Automate cloud via the **Machine Runtime App**, using **direct connectivity** — available in PAD 2.8.73.21119 and later, and not available on Windows 10/11 **Home** editions (Home lacks the RDP host capability the model depends on). Any environment still showing desktop flow connections routed through a gateway needs migration: **Data → Gateways → [gateway] → Connections** tab lists every desktop flow connection still pinned to it, each of which must be individually recreated as "directly to machine."

### Registration: what actually happens

When you sign in to the Machine Runtime App, it registers the machine against the **currently selected Power Automate environment**. Registration requires:
- The **MicrosoftFlowExtensionsCore** Dataverse solution at version ≥ 1.2.4.1 in that environment
- Network reachability from the machine to the required cloud endpoints (below)
- Environment Maker or Desktop Flow Machine Owner permission for the signed-in user
- The Dataverse **`RegisterFlowMachine`** process must be active in that environment's solution — if a security/compliance sweep deactivates custom Dataverse processes tenant-wide, this one breaks registration silently and the fix is an environment-admin action inside Dataverse, not a machine-side one

Registration is **environment-scoped** — a machine runs desktop flows for exactly one environment at a time. Switching environments removes all of that machine's existing connections, which is a common self-inflicted breakage after an admin "just changes the environment" without warning downstream flow owners.

### The service account: UIFlowService

All cloud-to-machine communication and session management is performed by the **Power Automate service**, registered as the Windows service **UIFlowService**, running by default as the virtual account **`NT SERVICE\UIFlowService`**. This account — not the interactive user — is what actually:
- Calls out to Power Automate cloud endpoints
- Enumerates existing Windows sessions on the machine
- Creates and tears down RDP sessions for unattended runs

Because it's a service account, it is subject to normal Windows service-account constraints: it needs "Log on as a service," it needs to not be blocked by "Deny log on locally"/"Deny log on through Remote Desktop Services" policies, and — critically — it needs membership in **Remote Desktop Users** to enumerate or create sessions at all. A GPO that scopes "Remote Desktop Users" membership tightly (common in security-hardened environments) will silently break unattended automation on any machine it touches, often well after the automation was first set up (the GPO refresh cycle, not the initial deployment, is when it breaks).

The account can be changed (Machine runtime → Troubleshoot → Change account, or the `TroubleshootingTool.Console.exe` CLI) — useful when the default virtual account can't traverse an authenticated proxy that requires a real domain identity. Note that **upgrading Power Automate for desktop resets the service account back to the default virtual account**, which is why scripted upgrade pipelines should always re-apply the custom account afterward rather than assuming it persists.

### Required network endpoints

| Endpoint | Purpose | Notes |
|---|---|---|
| `*.dynamics.com` | Dataverse — machine registration, environment data | Contacted for the specific Dataverse org once registered |
| `*.servicebus.windows.net` | Azure Relay — machine-cloud communication channel | Static relay endpoint pre-registration; specific endpoint post-registration |
| `*.gateway.prod.island.powerapps.com` | Desktop flow service | Required up to PAD version 2.51 |
| `*.api.powerplatform.com` | Desktop flow service | Required starting PAD version 2.52 — **both** may be needed during a mixed-version fleet transition |
| `config.edge.skype.com` | Only for Entra ID username/password auth with NLA on unattended runs | PAD ≥ 2.50 |

The **UIFlowService account**, not the logged-in interactive user, must be able to reach these — a proxy exception scoped to interactive browsing sessions will pass a manual test but still break scheduled unattended runs.

### Attended vs. unattended: two fundamentally different session models

**Attended runs** require the connection's Windows identity to already have an **active, unlocked** interactive session on the machine — Power Automate attaches to that existing session rather than creating one. This is why attended automation is bound to "someone is logged in and unlocked right now," and cannot be scheduled unsupervised.

**Unattended runs** are fundamentally different: Power Automate **creates its own RDP session** using the credentials stored in the connection, keeps the screen locked for the duration (so nothing is visible even if someone walks up to the console), runs the flow, then signs the session off and releases it — unless "Reuse sessions for unattended runs" is enabled at the machine or machine-group level, in which case the session is left locked (not signed off) for reuse by the next run.

Critically, **connecting to the machine's console session is not available for unattended runs** — it is always an RDP session, which is why RDP must be enabled on the target machine as a hard, non-optional requirement, not a configurable preference.

Session-collision rules differ by OS:
- **Windows 10/11**: cannot run an unattended flow if **any** active session exists for that user — even a merely locked one. The session must be fully signed off first.
- **Windows Server**: a **locked** session for the *same* connection user blocks the run; sessions belonging to other users don't interfere, and Server's multi-session model is what makes it the practical choice for machines running several different unattended connections concurrently.

### Capacity: unattended bots, Process license, and the shared pool

Running unattended flows requires **unattended bots** on the machine. A bot is created by allocating **Process capacity** (or the legacy **Unattended RPA capacity add-on** — as of the current licensing model these are combined into one interchangeable capacity pool) to that machine. Each unattended bot on a machine can carry exactly **one** simultaneous unattended run; a machine needing 3 concurrent unattended runs needs 3 bots allocated. The maximum bots a single machine supports depends on its OS/hardware, up to **10** on capable Windows Server editions. **Enable auto-allocation** lets bots be created on-demand as unattended runs require them, remaining allocated afterward until manually deallocated — useful for bursty workloads but worth monitoring, since it silently consumes shared environment capacity.

Process capacity can *also* be allocated directly to a **cloud flow** (not a machine) to license it for the **Process plan**, decoupling premium-action execution from any individual user's license and granting a 250,000-action daily entitlement (stackable up to 10 licenses = 2,500,000/day). This is a separate use of the same capacity pool from allocating bots to machines — don't conflate "the cloud flow needs a Process license to run premium actions independently of a user" with "the machine needs an unattended bot to execute desktop automation." Only **solution-aware** cloud flows (flows added to a Dataverse solution) can have Process capacity assigned or stacked.

### Machine groups

Machines can be pooled into **machine groups** (max 50 machines per group) for load balancing and horizontal scale — a desktop flow connection targets the group rather than one machine, and Power Automate routes each run to an available member. Settings like "Reuse sessions for unattended runs" and maintenance mode apply at the group level and are **inherited** by member machines; removing a machine from a group **retains** whatever settings it inherited at the time of removal rather than reverting them.

**Maintenance mode** (Monitor → Machines → machine or group → Settings) stops new runs from being assigned to a machine — existing in-flight runs are not canceled — useful for patching/redeployment windows without an abrupt kill of active automation. A machine can't be manipulated individually if maintenance mode was set at the group level; it must be toggled for the whole group.

</details>

---
## Dependency Stack

```
Layer 6:  Desktop flow run success (attended or unattended)
Layer 5:  Session state satisfies the mode's rules (active+unlocked for attended;
          zero/no-locked-same-user session for unattended) — OS-dependent rules differ
Layer 4:  Unattended bot capacity allocated to the machine (unattended only) —
          Process capacity / legacy Unattended RPA capacity pool
Layer 3:  Desktop flow connection created "directly to machine" with valid credentials
Layer 2:  UIFlowService running, correct account, Remote Desktop Users membership,
          "Log on as a service" right, not blocked by Deny-logon GPOs
Layer 1:  Network reachability from the service account to required cloud endpoints
          (*.dynamics.com, *.servicebus.windows.net, *.gateway.prod.island.powerapps.com
          or *.api.powerplatform.com per version)
Layer 0:  Machine registered to the correct Power Automate environment
          (MicrosoftFlowExtensionsCore ≥ 1.2.4.1, RegisterFlowMachine process active,
          registering user has Environment Maker / Desktop Flow Machine Owner role)
```

A failure at Layer 0–2 breaks **every** flow on that machine regardless of connection. A failure at Layer 3+ is connection- or run-specific. Always triage top-down from Layer 0 when multiple unrelated flows on the same machine fail simultaneously — it's almost never a coincidence of several broken connections at once.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Every flow on a machine suddenly fails, machine shows offline in portal | UIFlowService stopped, or network path to cloud endpoints broken | `Get-Service UIFlowService`; diagnostic tool endpoint test |
| Registration fails with "error connecting to Power Automate cloud services" | Proxy/firewall/TLS blocking the service account's outbound calls | Diagnostic tool; verify proxy config includes the service account, not just interactive users |
| Registration fails: "a cloud process needed for machine registration has been deactivated in Dataverse" | `RegisterFlowMachine` process disabled in the environment's Dataverse solution (often by an unrelated security sweep) | Environment admin checks the solution's process list in Dataverse |
| `WindowsIdentityIncorrect` (401) | Connection credentials don't match a valid sign-in format for the machine's join type | Confirm format: `domain\user` (AD), `user@domain` (Entra), `machinename\user`/`.\\user` (local) |
| `SessionCreationWinLogonFailure` | Windows couldn't create the logon session — often a stuck/corrupted session state | Restart the machine; this error code's documented remediation is a reboot, not a config change |
| `AttendedUserSessionNotActive` / `AttendedUserNotLoggedIn` | Attended run attempted with no matching unlocked interactive session | Confirm the correct user is logged in AND unlocked, not just logged in |
| `SessionExistsForTheUserWhenUnattended` / `Win10AlreadyHasActiveSession` | Windows 10/11 has any session (even locked) for the connection's user | `query user`; `logoff <id>` |
| `UnattendedUserSessionLocked` / `UnattendedUserSessionDisconnected` | Session-state edge case during an unattended run — see linked per-code troubleshooting doc, distinct remediation per code | Match exact code, don't generalize between these two |
| `RDPIsNotEnabled` | RDP disabled on target machine — hard requirement for all unattended runs | `(Get-ItemProperty 'HKLM:\...\Terminal Server').fDenyTSConnections` |
| `RdpPermissionNotGranted` | Connection user lacks Administrators/Remote Desktop Users membership, or a Deny-logon local policy blocks them | `secpol.msc` → User Rights Assignment → Deny log on locally / through RDS |
| `UIFlowServiceNoRdpPermissions` / `SessionNotFoundAfterCreation` | **UIFlowService account itself** (not the connection user) lacks Remote Desktop Users membership | `net localgroup "Remote Desktop Users"` |
| `NoCandidateMachine` | Run exceeded queue wait time — usually zero/insufficient unattended bot capacity, or every machine in the group is busy/in maintenance mode | Portal → Machines → machine/group → Settings → Unattended bots slider; check maintenance mode |
| `GroupIsEmpty` | Desktop flow connection targets a machine group with zero member machines | Add machines to the group |
| `XrmMachineGroupNotFound` | The targeted machine group was deleted after the connection was created | Recreate the group and update the connection |
| `MSEntraLogonFailure` / `MSEntraMachineAlwaysPromptingForPassword` / `MSEntraRemoteDesktopAppConsentRequired` | Entra ID-specific unattended auth issue — CBA/NLA consent not configured for the RDP app ID | Confirm `a4a365df-50f1-4397-bc59-1a1564b8bb9c` (MSRDspId) has Entra RDP auth enabled and consent prompt hidden for the target device group |
| `SessionCreationInvalidCredentials` | Username format wrong for join type in the unattended connection | Entra-joined: `user@domain.com`; domain-joined: `domain\user` |
| `AccountLockedOut` | On-prem account lockout policy tripped by repeated sign-in/password-rotation attempts — not a Power Automate licensing issue | Check Entra/AD sign-in logs and lockout policy for the connection account |
| `TotalChunksMismatch` / `DesktopFlowMalformedMachineResponse` / `WcfServerCrash` | Data corruption, low disk space, unstable network, or an outdated PAD version during a run | Check free disk space, network stability, confirm latest PAD version; for `TotalChunksMismatch` on PAD ≥ 2.36, check/clear the local cache folder |
| `DesktopFlowsActionThrottled` (429) | Too many desktop flows sharing one connection | Distribute flows across multiple connections |
| `OnPremiseDataGatewayNotAvailable` (502) | A connection is **still using the deprecated gateway model** | Migrate the connection to direct connectivity — see Remediation Playbook 3 |
| Flow runs fine manually, fails only when scheduled unattended | Screen resolution mismatch between authoring session and the unattended RDP session's default resolution | Set explicit screen resolution for unattended mode (`how-to/set-screen-resolution-unattended-mode`) |
| Cloned VM's machine intermittently steals another machine's runs / shows odd version history | VM was cloned **after** Power Automate machine runtime had already registered — duplicate machine identity | Delete stale machine record in portal, re-register from the clone; never clone post-registration |

---
## Validation Steps

1. **Confirm machine registration and version, not just "it's connected."**
   Portal → Monitor → Machines → machine details.
   Good: status connected, version ≥ 2.8.73.21119 (direct connectivity floor).
   Bad: version pre-dates direct connectivity — the machine may still be relying on a now-unsupported gateway path and needs an upgrade, not just a reconnect.

2. **Confirm the service account has every required right, not just service-running status.**
   ```powershell
   Get-Service UIFlowService | Select-Object Status
   (Get-CimInstance Win32_Service -Filter "Name='UIFlowService'").StartName
   net localgroup "Remote Desktop Users"
   ```
   Good: running, expected account, account present in the group.
   Bad: running but *not* in Remote Desktop Users — this passes a superficial "service is up" check while still failing every unattended run at session-creation time.

3. **Confirm RDP is enabled AND reachable, not just enabled locally.**
   `fDenyTSConnections = 0` confirms the local policy, but also confirm no network firewall (host or perimeter) blocks port 3389 from the Power Automate cloud service's session-creation path — Power Automate's RDP session creation is cloud-orchestrated, not a direct third-party RDP client connection, so this is less about "can I RDP in from my laptop" and more about the internal loopback/local session-creation mechanism working, which the built-in diagnostic tool validates more reliably than a manual port test.

4. **Confirm capacity allocation matches expected concurrency, not just "greater than zero."**
   Portal → Machines → machine → Settings → Unattended bots.
   Good: bot count ≥ expected simultaneous unattended runs for that machine.
   Bad: 1 bot allocated but the client expects 3 flows to run concurrently on the same machine — this manifests as queuing/timeout (`NoCandidateMachine`), not an outright failure, so it's easy to misdiagnose as a network issue.

5. **Confirm OS-appropriate session-collision behavior was actually tested, not assumed from a different OS.**
   Good: validated on the actual target OS (Windows 10/11 vs. Server) since the collision rules genuinely differ.
   Bad: automation tested and signed off on a Windows Server dev VM, then deployed to Windows 11 client machines with different (stricter) session rules — a frequent cause of "worked in testing, fails in production."

---
## Troubleshooting Steps (by phase)

**Phase 1 — Machine-level health (Layers 0–2).** Confirm registration, service status, service account rights, and network reachability before looking at any specific flow or connection. This is the highest-leverage phase — a Layer 0–2 fix resolves every flow on the machine at once.

**Phase 2 — Connection-level validation (Layer 3).** Confirm the desktop flow connection is "directly to machine" (not a stale gateway reference), credentials are in the correct format for the machine's join type, and the connection hasn't silently broken (portal shows connection health per action in a flow's designer).

**Phase 3 — Capacity and scheduling (Layer 4).** For unattended flows specifically, confirm bot allocation matches expected concurrency and that the machine/group isn't in maintenance mode or fully queued. `NoCandidateMachine` and long queue waits live here, not in Phase 1 or 2.

**Phase 4 — Session-state validation (Layer 5).** Match the OS-specific session rules against actual current session state (`query user`) at the time of the failed run — note that session state is transient, so reproduce as close to real-time as possible rather than relying on a stale report.

**Phase 5 — Error-code-driven remediation.** Once the run itself has failed, the returned error code is authoritative — use the [Symptom → Cause Map](#symptom--cause-map) to jump directly to the documented fix rather than re-walking Phases 1–4 from scratch for a run that already has a specific, known error code attached.

**Phase 6 — Fleet-wide sweep for recurring/systemic issues.** If the same error code recurs across multiple machines (e.g., every machine missing Remote Desktop Users membership after a GPO change), treat it as a policy/deployment issue, not a per-machine break-fix — see Remediation Playbook 4 and `Scripts/Get-PADMachineHealth.ps1`.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Onboard a new unattended automation machine cleanly</summary>

1. Install Power Automate for desktop ≥ 2.8.73.21119, checking "Install the machine-runtime app to connect to the Power Automate cloud portal" during setup.
2. Sign in to the Machine Runtime App — confirms direct-connectivity registration to the correct environment (verify with the environment selector before signing in if the user has access to multiple).
3. Add the service account (default `NT SERVICE\UIFlowService`, or a custom domain account if the network requires authenticated proxy traversal) to **Remote Desktop Users**.
4. Enable RDP (`fDenyTSConnections = 0`), confirm no Deny-logon local/GPO policy conflicts.
5. Allocate at least 1 unattended bot to the machine (Process capacity or legacy Unattended RPA capacity) via Monitor → Machines → machine → Settings.
6. Create the desktop flow connection as **"directly to machine"** — never recreate a gateway-based connection on a new machine; that model is retired.
7. Run a test unattended flow manually (Portal → Run) before relying on a schedule trigger, and validate screen resolution behavior if the flow was authored at a different resolution than the unattended RDP session default.

No rollback needed — purely additive setup.

</details>

<details><summary>Playbook 2 — Migrate a legacy gateway-based desktop flow connection to direct connectivity</summary>

1. Identify affected connections: **Data → Gateways → [gateway] → Connections** tab lists every desktop flow connection still using it.
2. Confirm the target machine is on PAD ≥ 2.8.73.21119 and registered via direct connectivity (re-register if it's an old install that predates this model).
3. For each affected cloud flow action: open the action → **+ Add new connection** under "My connections" → **Connect** field → select **Directly to machine** → choose the machine → supply sign-in credentials → **Create**.
4. Re-point the action to the new connection and save the flow.
5. Test-run the flow before decommissioning the old gateway-based connection.
6. Once all connections referencing a gateway are migrated, the gateway itself can be evaluated for removal if it serves no other (non-desktop-flow) connectors — check its other Connections tabs first.

**Rollback:** the old gateway-based connection isn't deleted by this process unless done manually — keep it until the new connection is validated in production, then remove it explicitly.

</details>

<details><summary>Playbook 3 — Recover a machine stuck in a bad state after a cloned-VM registration collision</summary>

1. Confirm the symptom: intermittent `SessionNotFound`/`MachineNotFound` errors, or one machine's runs appearing to execute on a different physical/virtual machine than expected.
2. Portal → Monitor → Machines → identify the duplicate/stale machine record(s) — check "Machine version" history for an unexplained jump, a common tell for a post-registration clone.
3. Delete the stale machine record(s): select → **Delete machine** in the command bar (deletion is portal-only; the Machine Runtime App itself has no delete option).
4. On the actual affected VM(s), re-register cleanly via the Machine Runtime App.
5. Recreate any desktop flow connections that pointed at the deleted machine record, since connections reference the machine's registration ID, not just its name.
6. Going forward: never clone a VM image **after** Power Automate machine runtime has registered it — clone the base image before first sign-in/registration, or de-register before capturing a golden image.

**Rollback:** none required — deleting a stale duplicate machine record doesn't affect the correctly-registered machine sharing that name.

</details>

<details><summary>Playbook 4 — Fleet-wide remediation for a systemic GPO/policy regression (e.g., Remote Desktop Users scope tightened)</summary>

1. Confirm the pattern: multiple machines failing with the *same* error code (`UIFlowServiceNoRdpPermissions`, `RdpPermissionNotGranted`) around the same time window — check Group Policy change history for a Remote Desktop Users / Deny-logon policy update in that window.
2. Run `Scripts/Get-PADMachineHealth.ps1` across the affected machine fleet (via remote PowerShell / your RMM's script-push mechanism) to get a consolidated pass/fail report rather than checking machines one at a time.
3. Work with the identity/security team to either scope the GPO to explicitly include the automation service account(s), or move affected machines to an OU excluded from the tightened policy if that's organizationally appropriate.
4. Re-run the health script after the policy fix propagates (allow for GPO refresh interval, typically up to 90–120 minutes by default, or force with `gpupdate /force` on a test machine first) to confirm remediation before declaring the incident closed.

**Rollback:** if the GPO exception causes unrelated security concerns, revert and instead move the automation service account to a dedicated, tightly-scoped domain account used only for Power Automate desktop automation — a common compromise between security hardening and functional RPA.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Local machine-runtime evidence pack for a Power Automate Desktop escalation.
.DESCRIPTION
    Collects UIFlowService state, RDP/session config, group membership, PAD version,
    and current session state on the machine where it's run. Intended to be run ON
    the affected machine (or pushed via RMM/remote PowerShell to several).
#>
$evidence = [ordered]@{
    Timestamp            = Get-Date -Format "o"
    ComputerName          = $env:COMPUTERNAME
    UIFlowServiceStatus   = (Get-Service -Name "UIFlowService" -ErrorAction SilentlyContinue).Status
    UIFlowServiceAccount  = (Get-CimInstance Win32_Service -Filter "Name='UIFlowService'" -ErrorAction SilentlyContinue).StartName
    RDPEnabled            = ((Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server" -ErrorAction SilentlyContinue).fDenyTSConnections -eq 0)
    RemoteDesktopUsers    = (net localgroup "Remote Desktop Users") -join "; "
    CurrentSessions       = (query user 2>$null) -join "; "
    OSCaption             = (Get-CimInstance Win32_OperatingSystem).Caption
}

$padExe = Get-ChildItem "$env:ProgramFiles(x86)\Power Automate Desktop" -Filter "PAD.Console.Host.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($padExe) { $evidence["PADVersion"] = $padExe.VersionInfo.ProductVersion }

$evidence | Format-List
$outPath = "C:\Evidence\PAD-MachineRuntime-$env:COMPUTERNAME-$(Get-Date -Format yyyyMMdd-HHmm).json"
New-Item -ItemType Directory -Path (Split-Path $outPath) -Force -ErrorAction SilentlyContinue | Out-Null
$evidence | ConvertTo-Json | Out-File $outPath -Encoding utf8
Write-Host "Evidence written to $outPath" -ForegroundColor Green
```

Pair with a portal-side export (Monitor → Machines → machine → run history export, and Monitor → the failed cloud flow run → error code/details) for the cloud-side half of the picture, since capacity allocation, machine group membership, and exact error codes are portal-only data with no local equivalent.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-Service UIFlowService` | Check the Power Automate desktop service status |
| `(Get-CimInstance Win32_Service -Filter "Name='UIFlowService'").StartName` | Confirm which account the service runs as |
| `net localgroup "Remote Desktop Users"` | Confirm service/connection account can enumerate/create sessions |
| `query user` | List active/disconnected sessions on the machine |
| `logoff <sessionID>` | Force sign-off a colliding session before an unattended run |
| `(Get-ItemProperty 'HKLM:\...\Terminal Server').fDenyTSConnections` | Confirm RDP enabled (0) vs. disabled (1) |
| `secpol.msc` → User Rights Assignment | Check Deny log on locally / through RDS for the service or connection account |
| Machine runtime → Troubleshoot → Launch diagnostic tool | Authoritative per-machine endpoint connectivity test |
| Machine runtime → Troubleshoot → Change account | Change the UIFlowService logon account |
| `TroubleshootingTool.Console.exe ChangeUIFlowServiceAccount` | Scripted service-account change (upgrade pipelines) |
| Portal: Monitor → Machines | Registration status, version, group membership, unattended bot allocation, maintenance mode |
| Portal: Data → Gateways → [gateway] → Connections | Find desktop flow connections still on the retired gateway model |
| Portal: Monitor → Cloud flows / Desktop flows → run details | Exact error code for a failed run |

---
## 🎓 Learning Pointers
- The single biggest documentation trap in this space: **gateways for desktop flows are retired**, but plenty of internal runbooks, prior client documentation, and even related topics in this repo (see the note in `Troubleshooting/Flow-Ownership-Transfer-A.md`'s Scope section) still describe a "machine/gateway identity" model. Always confirm current architecture against [Manage machines](https://learn.microsoft.com/en-us/power-automate/desktop-flows/manage-machines) rather than trusting older internal notes, including this repo's own older cross-references.
- Windows 10/11 and Windows Server have genuinely different unattended session-collision rules — don't assume test results from one generalize to the other. This is the top cause of "worked in the lab, fails at the client."
- `UIFlowService`'s rights (Remote Desktop Users, Log on as a service, not Deny-logon-blocked) are a GPO-fragile dependency — a security team tightening group scope for unrelated reasons is a common, delayed-onset cause of fleet-wide automation breakage that looks like a Power Automate outage but isn't.
- Process capacity and legacy Unattended RPA capacity are the same pool today — allocate it deliberately per-machine (bots) or per-flow (Process plan), and remember these are two different *uses* of the same licensed capacity, not two different products.
- The built-in diagnostic tool (Troubleshoot tab → Launch diagnostic tool) is purpose-built and version-aware — prefer it over manual `Test-NetConnection` once past initial 60-second triage, since it knows which endpoint set applies to the installed PAD version.
- Microsoft Learn references used in this document: [Manage machines](https://learn.microsoft.com/en-us/power-automate/desktop-flows/manage-machines), [Troubleshoot desktop flows runtime](https://learn.microsoft.com/en-us/power-automate/desktop-flows/troubleshoot), [Run unattended desktop flows](https://learn.microsoft.com/en-us/power-automate/desktop-flows/run-unattended-desktop-flows), [Error codes for attended/unattended runs](https://learn.microsoft.com/en-us/troubleshoot/power-platform/power-automate/desktop-flows/troubleshoot-errors-running-attended-or-unattended-desktop-flows), [Machine registration failure](https://learn.microsoft.com/en-us/troubleshoot/power-platform/power-automate/desktop-flows/desktop-flow-machine-registration-troubleshooting), [Process capacity](https://learn.microsoft.com/en-us/power-automate/desktop-flows/capacity-process).
- Companion hotfix runbook: `MachineRuntime-B.md`. For cloud-flow-side ownership/connection governance, see `Troubleshooting/Flow-Ownership-Transfer-A.md`; for DLP blocking the desktop flow connector itself, see `Troubleshooting/DLP-Policies-A.md`.
