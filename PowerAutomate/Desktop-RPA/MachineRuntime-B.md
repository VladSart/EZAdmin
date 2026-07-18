# Power Automate Desktop — Machine Runtime & Unattended RPA — Hotfix Runbook (Mode B: Ops)
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

Trigger for this runbook: a desktop flow (attended or unattended) is failing to start or is failing mid-run on a specific registered machine, or a machine won't register/reconnect to Power Automate at all. Run these **on the affected machine** (Power Automate portal has no PowerShell cmdlets for machine/session state — this is a local diagnostic surface).

```powershell
# 1. Is the Power Automate service running, and as which account?
Get-Service -Name "UIFlowService" | Select-Object Name, Status, StartType
(Get-CimInstance Win32_Service -Filter "Name='UIFlowService'").StartName

# 2. Is that account allowed to enumerate/create remote sessions?
net localgroup "Remote Desktop Users"

# 3. Is RDP enabled (required for ALL unattended runs)?
(Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server").fDenyTSConnections
# 0 = RDP enabled (good). 1 = RDP disabled (blocks every unattended run).

# 4. Is there an active/locked session that will collide with an unattended run?
query user

# 5. Can the machine reach every required Power Automate endpoint?
Test-NetConnection login.microsoftonline.com -Port 443
Test-NetConnection *.servicebus.windows.net -Port 443 -WarningAction SilentlyContinue  # wildcard for illustration — test the specific relay endpoint from the diagnostic tool logs
Test-NetConnection *.api.powerplatform.com -Port 443 -WarningAction SilentlyContinue
```

| Result | Interpretation |
|---|---|
| `UIFlowService` not `Running`, or `StartName` isn't `NT SERVICE\UIFlowService` (and no one changed it deliberately) | Service is down or misconfigured — go to [Fix 1](#common-fix-paths) |
| Service account **not** listed in "Remote Desktop Users" | Sessions can't be enumerated/created → `UIFlowServiceNoRdpPermissions` / `SessionNotFoundAfterCreation` errors — go to [Fix 2](#common-fix-paths) |
| `fDenyTSConnections = 1` | RDP disabled — every unattended run fails with `RDPIsNotEnabled` — go to [Fix 3](#common-fix-paths) |
| `query user` shows an **active or locked session** for the connection's user, machine is Windows 10/11 | Unattended run can't start (Win10/11 requires **zero** sessions for that user, even locked) — go to [Fix 4](#common-fix-paths) |
| `query user` shows an active/locked session for the connection's user, machine is **Windows Server** | Same-user locked session blocks unattended runs on Server too; a *different* user's session does not — go to [Fix 4](#common-fix-paths) |
| Endpoint tests fail | Network/proxy/firewall is blocking required Power Automate services — go to [Fix 5](#common-fix-paths) |
| Everything above is healthy but the run still fails with a specific error code | Skip to [Diagnosis & Validation Flow](#diagnosis--validation-flow) and match the exact error code in the Common Fix Paths error-code table |

---
## Dependency Cascade

<details><summary>What must be true for a desktop flow run to start and complete</summary>

```
Machine registered to an environment (Power Automate machine runtime, signed in)
      │
      ▼
UIFlowService running as a service account with:
   - "Remote Desktop Users" membership (to enumerate/create Windows sessions)
   - "Log on as a service" right
   - Network reachability to *.dynamics.com, *.servicebus.windows.net,
     *.gateway.prod.island.powerapps.com (≤ v2.51), *.api.powerplatform.com (v2.52+)
      │
      ▼
Desktop flow connection created ("directly to machine" — gateways are retired)
      │
      ▼
      ├── ATTENDED run: connection's Windows identity must already have an
      │   ACTIVE, UNLOCKED session on the machine at trigger time
      │
      └── UNATTENDED run: requires an unattended bot allocated to the machine
          (Process capacity / legacy Unattended RPA capacity), RDP enabled,
          and — Windows 10/11: zero existing sessions for that user (even locked)
          — Windows Server: no LOCKED session for that same user
              │
              ▼
          Power Automate creates a new RDP session (or reuses one if
          "Reuse sessions for unattended runs" is enabled) using the
          connection's stored credentials
      │
      ▼
Flow executes → session is locked during the run (unattended) → session is
signed off and released when the flow completes (unless reuse is enabled)
```

The two failure modes people conflate: a **machine-level** problem (service down, no network, wrong service account) breaks every flow on that machine regardless of which flow or connection is used, while a **connection-level** problem (bad credentials, session state conflict, licensing) breaks only flows using that specific connection. Triage machine health first — it's the cheaper, more common root cause.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the machine shows as connected in the portal.**
   Power Automate portal → **Monitor** → **Machines** → select the machine.
   Expected: status shows connected/online, version populated.
   Bad: machine missing entirely (deleted/re-registered elsewhere) or shown offline — re-registration may be required (Fix 6).

2. **Match the exact error code from the failed run.**
   Portal → **Monitor** → **Cloud flows** (or **Desktop flows**) → the failed run → open run details → note the error code shown (e.g. `SessionCreationWinLogonFailure`, `MSEntraLogonFailure`, `WindowsIdentityIncorrect`).
   This code is the fastest path to the right fix — see the [error-code table](#common-fix-paths) below rather than guessing from symptoms alone.

3. **Confirm run mode (attended vs. unattended) matches what the flow expects.**
   Attended runs require a real interactive user at the keyboard with a matching, unlocked session. Unattended runs must have **no colliding session** at all. A flow accidentally left on the wrong connection type is a common self-inflicted cause.

4. **Check for a capacity/licensing gap on unattended runs specifically.**
   ```powershell
   # No supported PowerShell surface for this — check in-portal:
   # Monitor > Machines > <machine> > Settings > "Unattended bots" slider
   ```
   Expected: at least 1 unattended bot allocated if this machine runs unattended flows. `NoCandidateMachine` / long queue times often trace back to zero bots allocated, not a technical fault.

5. **Run the built-in diagnostic tool for connectivity-specific failures.**
   Machine runtime app → **Troubleshoot** tab → **Launch diagnostic tool**. It tests each required endpoint individually and reports exactly which one is unreachable — faster and more authoritative than manual `Test-NetConnection` guessing once you're past the initial 60-second triage.

6. **If registration itself is failing (not a run), check the specific registration error text.**
   "There was an error connecting to the Power Automate cloud services" / "A cloud process needed for machine registration has been deactivated in Dataverse" point to different causes — network/proxy vs. a deactivated Dataverse `RegisterFlowMachine` process respectively. Don't apply a network fix to a Dataverse-process problem or vice versa.

---
## Common Fix Paths

<details><summary>Fix 1 — UIFlowService not running or wrong service account</summary>

```powershell
# Restart the service first — cheapest fix
Restart-Service -Name "UIFlowService" -Force

# If it won't stay running, check Windows Event Viewer > Applications and Services Logs
# for UIFlowService entries, then verify/reset the service account:
```
Use the in-app tool (preferred — handles the password securely):
Machine runtime → **Troubleshoot** → **Change account** → **This account** → supply `DOMAIN\user` + password → **Configure**.

Or scripted (useful for imaging/upgrade pipelines, since upgrades reset the account to the default virtual account):
```powershell
cd "$env:ProgramFiles(x86)\Power Automate Desktop"
# temp.txt must contain ONLY the account password
".\TroubleshootingTool.Console.exe" ChangeUIFlowServiceAccount DOMAIN\svc-pad < temp.txt
Remove-Item temp.txt
```
**Rollback:** re-run with the original account, or omit the account name to reset to the default `NT SERVICE\UIFlowService` virtual account (check tool's built-in reset command by running it with no arguments).

Not supported on **hosted machines** — the service account there is Microsoft-managed.

</details>

<details><summary>Fix 2 — Service account can't enumerate/create sessions (Remote Desktop Users)</summary>

```powershell
# Add the UIFlowService account (or custom service account) to Remote Desktop Users
Add-LocalGroupMember -Group "Remote Desktop Users" -Member "NT SERVICE\UIFlowService"
# If using a custom domain service account instead:
Add-LocalGroupMember -Group "Remote Desktop Users" -Member "DOMAIN\svc-pad"
```
Also check **Local Security Policy** (`secpol.msc` → Local Policies → User Rights Assignment) — confirm the service account is **not** listed under "Deny log on locally" or "Deny log on through Remote Desktop Services." A GPO-pushed deny rule silently overrides group membership and is the most common recurrence cause after this fix appears to "stop working" post-reboot.

</details>

<details><summary>Fix 3 — RDP disabled on the target machine</summary>

```powershell
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Restart-Service -Name "TermService" -Force
```
**Rollback:** set `fDenyTSConnections` back to `1` and disable the firewall group if RDP must stay closed for security policy reasons — but note unattended desktop flows **cannot function at all** without RDP enabled; this is a hard product requirement, not a configurable workaround.

</details>

<details><summary>Fix 4 — Colliding session blocking an unattended run</summary>

```powershell
# Identify the session(s) for the connection's user
query user

# Sign off the specific session ID found above
logoff <sessionID>
```
Windows 10/11: **any** existing session for that user (even locked) blocks the run — sign it off entirely.
Windows Server: only a **locked** session for the *same* user blocks the run; a different user's session is fine, and an unlocked session for the same user may be reusable if "Reuse sessions for unattended runs" is enabled (Monitor → Machines → machine/group → Settings).

**Rollback:** none needed — signing off a stale automation session is non-destructive to the machine itself. If a real user was actively using that session, coordinate before running this.

</details>

<details><summary>Fix 5 — Network/proxy blocking required endpoints</summary>

Required endpoints (confirm exact list via the in-app diagnostic tool, which reports precisely what's unreachable):
```
*.dynamics.com
*.servicebus.windows.net
*.gateway.prod.island.powerapps.com   (Power Automate for desktop ≤ v2.51)
*.api.powerplatform.com               (v2.52+)
config.edge.skype.com                 (only if using Entra sign-in credentials + NLA for unattended)
```
If behind a proxy, configure the machine runtime app for proxy use (Machine runtime → Settings → proxy configuration) — the `UIFlowService` account making the calls, not just the interactive user, must be able to traverse the proxy. A proxy rule scoped only to interactive user sessions is the most common reason "it works when I test manually but fails as a scheduled run."

**Rollback:** revert proxy/firewall changes if they cause unrelated issues — but note these endpoints are a hard requirement; there is no functional workaround for blocking them.

</details>

<details><summary>Fix 6 — Machine registration failing outright</summary>

```powershell
# Confirm current registration state
# (Machine runtime app > Machine settings shows registration status locally)
```
- **"Error connecting to Power Automate cloud services" / TLS error** → network/proxy issue, apply Fix 5 first.
- **"A cloud process needed for machine registration has been deactivated in Dataverse"** → the `RegisterFlowMachine` Dataverse process was deactivated (often by a security/DLP sweep) — an environment admin must reactivate it in the Dataverse solution before registration can succeed. This is not a machine-side fix.
- **Cloned VM that was already registered before cloning** → delete the stale machine record in the portal (Monitor → Machines → select → Delete machine) and re-register from the clone. Never clone a VM *after* Power Automate machine runtime has already registered it — this produces duplicate/ghost machine identities that intermittently steal each other's runs.
- Confirm Power Automate for desktop is version **2.8.73.21119 or later** for direct connectivity (no gateway) — earlier versions cannot register without a now-deprecated gateway and must be upgraded first.

**Rollback:** re-registering does not affect other machines; deleting a machine record removes its run history association going forward but is otherwise non-destructive.

</details>

---
## Escalation Evidence

```
Power Automate Desktop / Machine Runtime Escalation — <date>
Machine name: <name>
OS: <Windows 10 / 11 / Server 20xx>
Power Automate for desktop version: <version — confirm ≥ 2.8.73.21119 for direct connectivity>
Run mode affected: <Attended / Unattended>
Exact error code from failed run: <e.g. SessionCreationWinLogonFailure>
UIFlowService status: <Running/Stopped>, account: <NT SERVICE\UIFlowService or custom>
Remote Desktop Users membership confirmed: <Yes/No>
RDP enabled (fDenyTSConnections): <0/1>
Unattended bots allocated to this machine: <count, from portal>
Diagnostic tool endpoint test results: <pass/fail per endpoint, attach export>
Machine group (if applicable) and other machines in group affected: <Y/N>
Escalating because: <e.g. Dataverse RegisterFlowMachine process deactivated — needs environment admin, or capacity exhausted — needs additional Process license>
```

---
## 🎓 Learning Pointers
- **Gateways for desktop flows are retired.** If you inherited documentation or a client environment describing a "Power Automate gateway" for desktop flows, that's stale — machines now connect directly via the Machine Runtime App (direct connectivity, PAD ≥ 2.8.73.21119). Check **Data → Gateways → [gateway] → Connections** to find any desktop flow connections still pinned to a gateway and migrate them to "directly to machine." Microsoft Learn: [Manage machines](https://learn.microsoft.com/en-us/power-automate/desktop-flows/manage-machines#switch-from-gateways-to-direct-connectivity).
- Ownership vs. runtime identity applies here too, same as cloud flows: fixing the machine doesn't fix a bad *connection*, and vice versa — triage both layers, not just one. See `Troubleshooting/Flow-Ownership-Transfer-A.md` for the cloud-flow-side version of this same conflation.
- Windows 10/11 vs. Windows Server have **different** session-collision rules for unattended runs — this single distinction accounts for a large share of "works on my test Server VM, fails on the client's Windows 11 machine" tickets.
- The in-app diagnostic tool (Troubleshoot tab → Launch diagnostic tool) is more authoritative than manual connectivity testing — it tests the exact endpoints for that machine's actual registration/version state, not a generic list.
- `Process capacity` and legacy `Unattended RPA capacity` are the same shared pool today — don't chase two different licensing concepts if a client mentions either term from older documentation.
- Deep dive on the connectivity architecture, session lifecycle, error-code taxonomy, and capacity/licensing model: `MachineRuntime-A.md`.
