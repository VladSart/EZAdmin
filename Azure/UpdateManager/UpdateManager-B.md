# Azure Update Manager — Hotfix Runbook (Mode B: Ops)
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

Run these first — in order. Stop as soon as one gives you the answer.

```powershell
# 1. Is the machine even reporting an assessment at all?
Get-AzVM -ResourceGroupName <rg> -Name <vmName> -Status |
  Select-Object -ExpandProperty Statuses | Where-Object { $_.Code -like "PowerState*" }

# 2. Trigger a fresh on-demand assessment and read the real status (never trust a stale portal tile)
Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vmName>

# 3. Is the patch extension actually present and healthy on the machine?
Get-AzVMExtension -ResourceGroupName <rg> -VMName <vmName> |
  Where-Object { $_.Name -like "*PatchExtension*" -or $_.Publisher -like "*CPlat*" } |
  Select-Object Name, Publisher, ProvisioningState

# 4. Is the machine actually attached to the maintenance schedule you think it is?
Get-AzConfigurationAssignment -ResourceGroupName <rg> -ResourceName <vmName> `
  -ResourceType "virtualMachines" -ProviderName "Microsoft.Compute"

# 5. For Azure Arc-enabled servers specifically — is the Arc agent itself connected?
#    (a "patching isn't working" ticket on a non-Azure server is very often actually an Arc problem)
Get-AzConnectedMachine -ResourceGroupName <rg> -Name <machineName> | Select-Object Status, LastStatusChange
```

| If... | Then... |
|---|---|
| Step 1 shows the VM is stopped/deallocated | Machine isn't running — assessment/patching can't happen on a powered-off VM. Start it, no further diagnosis needed. |
| Step 2 fails or returns no data, and the extension in Step 3 is missing entirely | [Fix 1 — Patch extension never installed / stuck](#fix-1) |
| Step 3 shows `ProvisioningState` other than `Succeeded` | [Fix 1 — Patch extension never installed / stuck](#fix-1) |
| Portal/Resource Graph shows **Not assessed** with a red `HRESULT` exception | [Fix 2 — Update agent misconfigured (HRESULT error)](#fix-2) |
| Step 4 returns nothing, or references a maintenance configuration that no longer exists | [Fix 3 — Machine not actually on the schedule you expect](#fix-3) |
| Update history shows **Failed — Maintenance window exceeded = true** | [Fix 4 — Maintenance window too short](#fix-4) |
| Step 5 shows the Arc agent `Disconnected` (Arc-enabled server only) | Not an Update Manager problem — fix Arc connectivity first (see `Azure/Arc/AzureArc-B.md`); patching cannot work on a disconnected Arc machine |
| Linux VM, error mentions `sudo` / `root is not in the sudoers file` | [Fix 5 — Linux sudo privileges missing](#fix-5) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Machine is powered on and reachable
    │
    ├── Azure VM Agent (Windows/Linux) or Azure Connected Machine agent (Arc-enabled server)
    │       │  ← for Arc-enabled servers, the Arc agent connection itself must be healthy
    │       │     FIRST — see Azure/Arc/ — before any Update Manager operation can succeed
    │       ▼
    │   Patch extension installed on first use
    │       (Microsoft.CPlat.Core.WindowsPatchExtension / ...LinuxPatchExtension)
    │       │  ← auto-installed on the FIRST Check for updates / Install now /
    │       │     Periodic Assessment / scheduled run — never installed ahead of time
    │       ▼
    │   AllowExtensionOperations = true on the VM's OSProfile
    │       (a VM created with this explicitly disabled cannot run ANY extension,
    │        not just this one — a silent, easy-to-miss root cause)
    │       ▼
    │   Underlying update agent on the guest OS
    │       ├── Windows: Windows Update Agent (WUA) — configured for Windows Update,
    │       │     Microsoft Update, or WSUS; Update Manager only ever sees what
    │       │     "Check for updates" would show locally, nothing more
    │       └── Linux: distro package manager + local/public repo reachability +
    │             root/sudo privileges for the extension (runs update ops as root)
    │       ▼
    └── RBAC permission on the specific machine
            (Virtual Machine Contributor for Azure VMs, Azure Connected Machine
             Resource Administrator for Arc-enabled servers — or the granular
             Microsoft.Compute/.../assessPatches|installPatches actions)

Scheduled (not on-demand) patching adds a SEPARATE resource chain on top:
    Microsoft.Maintenance/maintenanceConfigurations (the schedule itself)
            │
            └── Microsoft.Maintenance/configurationAssignments
                    (the link between one schedule and one machine — this is its
                     own resource; a schedule existing does NOT mean any machine
                     is actually assigned to it)
```

**The single most common false escalation:** assuming "patching is broken" when the real fault is one layer down — the Arc agent, the VM agent, or the guest OS's own update client — none of which Update Manager can repair from its side. Confirm the layer below is healthy before touching anything Update-Manager-specific.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the machine is on and the agent is responsive before anything else.**
   ```powershell
   Get-AzVM -ResourceGroupName <rg> -Name <vmName> -Status
   ```
   Good: `PowerState/running`, `VM Agent` status `Ready`. Bad: stopped/deallocated, or agent not ready — fix that first, this isn't an Update Manager problem yet.

2. **Force a fresh assessment rather than reading a stale compliance tile.**
   ```powershell
   Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vmName>
   ```
   Good: returns `AssessPatchesResultStatus: Succeeded` with a patch count. Bad: `Failed`, `InProgress` that never completes, or an exception — the extension or the underlying agent is the problem, not "no updates are due."

3. **Check the extension's own provisioning state — it is separate from the VM agent.**
   ```powershell
   Get-AzVMExtension -ResourceGroupName <rg> -VMName <vmName> -Name "WindowsPatchExtension"
   ```
   Good: `ProvisioningState: Succeeded`. Bad: `Creating`, `Failed`, or the extension doesn't exist at all — it only installs itself the first time ANY Update Manager operation runs, so a brand-new VM that's never had `Check for updates` clicked will show nothing here until you trigger Step 2 once.

4. **For a red HRESULT exception on Windows, decode the code before guessing.**
   Double-click/expand the exception in the portal, or read it from Resource Graph. `0x8024402C` / `0x8024401C` / `0x8024402F` = network connectivity to the update source. `0x80072EE2` = can't reach WSUS. `0x8024002E` = Windows Update service disabled. `0x80070005` = access denied (often `%WinDir%\SoftwareDistribution` permissions or low disk space). Full table in Learning Pointers.

5. **Confirm the machine is genuinely attached to the maintenance schedule it's supposed to be on.**
   ```powershell
   Get-AzConfigurationAssignment -ResourceGroupName <rg> -ResourceName <vmName> -ResourceType "virtualMachines" -ProviderName "Microsoft.Compute"
   ```
   Good: returns an assignment whose `MaintenanceConfigurationId` matches the schedule you expect. Bad: empty — the VM was never actually assigned (a very common gap after a VM move — assignments do not survive a resource group/subscription move automatically).

6. **If the schedule ran but "failed," check whether it was actually a maintenance-window-exceeded, not a real failure.**
   ```powershell
   Get-AzMaintenanceUpdateResourceUpdate -ResourceGroupName <rg> -ProviderName "Microsoft.Compute" -ResourceType "virtualMachines" -ResourceName <vmName> -ApplyRuleName "myMaintenanceRun"
   ```
   Good: `Status: Succeeded`. Bad: `Status: Failed` with `MaintenanceWindowExceeded: true` in the properties — this is a timing problem (Fix 4), not a patch failure.

7. **For Arc-enabled servers, always validate the Arc layer before the Update Manager layer.**
   ```powershell
   Get-AzConnectedMachine -ResourceGroupName <rg> -Name <machineName> | Select-Object Status, LastStatusChange, AgentVersion
   ```
   Good: `Status: Connected`, recent `LastStatusChange`. Bad: `Disconnected`/`Expired` — go to `Azure/Arc/AzureArc-B.md` first; nothing in this file will help until that's fixed.

---
## Common Fix Paths

<details><summary id="fix-1">Fix 1 — Patch extension never installed / stuck</summary>

**Symptom:** `Get-AzVMExtension` shows no `WindowsPatchExtension`/`LinuxPatchExtension` at all, or it's stuck `Creating`/`Failed`.

**Root cause:** the extension only auto-installs the first time an Update Manager operation (Check for updates, Install now, Periodic Assessment, or a scheduled run) actually executes against the machine. A VM that's never had any of those triggered has no extension yet — this is expected, not a bug — and a VM created with `AllowExtensionOperations` set to `false` can never get one until that's changed.

```powershell
# Confirm AllowExtensionOperations isn't the blocker (Azure VM only)
(Get-AzVM -ResourceGroupName <rg> -Name <vmName>).OSProfile.AllowExtensionOperations

# Trigger the extension install indirectly by running an on-demand assessment
Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vmName>

# If the extension is present but stuck/failed, remove it and let the next operation reinstall it clean
Remove-AzVMExtension -ResourceGroupName <rg> -VMName <vmName> -Name "WindowsPatchExtension" -Force
Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vmName>
```

For Azure Arc-enabled servers, the same idea applies via the Arc-side extension cmdlets, and only after confirming the Arc agent is `Connected` first (Diagnosis Step 7):
```powershell
Remove-AzConnectedMachineExtension -ResourceGroupName <rg> -MachineName <machineName> -Name "WindowsAgent.PatchExtension"
# Then trigger an on-demand assessment/patch operation to reinstall
```

**Rollback:** N/A — removing and letting Update Manager reinstall the extension is non-destructive; it does not touch any already-installed OS patches.

</details>

<details><summary id="fix-2">Fix 2 — Update agent misconfigured (HRESULT error, Windows)</summary>

**Symptom:** Portal/Resource Graph shows **Not assessed** with a red `HRESULT` exception under the machine.

**Root cause:** the Windows Update Agent itself (not Update Manager) can't reach or process its configured source. Update Manager only relays what the local WUA reports — it cannot fix the WUA's own configuration.

```powershell
# Read the exact exception first — the HRESULT code determines the fix
# (in the portal: expand the red exception text under the machine's compliance row)

# If pointed at WSUS, confirm the registry keys are actually correct
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name WUServer, WUStatusServer -ErrorAction SilentlyContinue

# Confirm the Windows Update service itself isn't disabled
Get-Service wuauserv | Select-Object Status, StartType
Set-Service wuauserv -StartupType Manual
Start-Service wuauserv

# Test locally — if "Check for updates" fails in Settings too, this confirms it's the
# agent/source, not Update Manager, before you spend more time on the Azure side
```

| HRESULT | Meaning | Action |
|---|---|---|
| `0x8024402C` / `0x8024401C` / `0x8024402F` | Network connectivity to the update source | Confirm outbound reachability to Windows Update / WSUS endpoints |
| `0x8024001E` | Service/system shutting down mid-operation | Retry |
| `0x8024002E` | Windows Update service disabled | Enable and start `wuauserv` |
| `0x80072EE2` | Can't reach configured WSUS server | Check `WUServer`/`WUStatusServer`, WSUS availability |
| `0x80070422` | Windows Update service has no enabled devices / is disabled | Re-enable the service |
| `0x80070005` | Access denied | Check `%WinDir%\SoftwareDistribution` permissions, disk space on C: |

**Rollback:** N/A — these are read/repair actions on the guest OS's own update client, not Azure-side changes.

</details>

<details><summary id="fix-3">Fix 3 — Machine not actually on the schedule you expect</summary>

**Symptom:** `Get-AzConfigurationAssignment` returns nothing, or returns an assignment pointing at a different/old maintenance configuration than expected. Very common after moving a VM to a different resource group or subscription.

**Root cause:** `Microsoft.Maintenance/configurationAssignments` is its own resource, separate from the maintenance configuration (the schedule) itself — and **assignments do not migrate automatically when a VM moves resource group or subscription.**

```powershell
# Confirm the maintenance configuration itself still exists and has the settings you expect
Get-AzMaintenanceConfiguration -ResourceGroupName <rg> -Name <configName>

# Create (or re-create) the assignment linking this VM to that schedule
New-AzConfigurationAssignment -ResourceGroupName <rg> -Location <region> `
  -ResourceName <vmName> -ResourceType "VirtualMachines" -ProviderName "Microsoft.Compute" `
  -ConfigurationAssignmentName "<assignmentName>" `
  -MaintenanceConfigurationId "/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Maintenance/maintenanceConfigurations/<configName>"
```

If the VM was moved and is using a **dynamic scope** (Azure Policy-based), don't recreate the assignment manually mid-cycle — wait for or trigger the next scheduled run first, which removes the stale assignment on its own, then let the policy re-evaluate and reassign after the move completes.

**Rollback:** `Remove-AzConfigurationAssignment` with the same identifying parameters removes the link without touching the VM or the schedule definition itself.

</details>

<details><summary id="fix-4">Fix 4 — Maintenance window too short ("Maintenance window exceeded")</summary>

**Symptom:** Update history shows **Failed**, with **Maintenance window exceeded: true**, even though the window "looked" long enough.

**Root cause:** Update Manager reserves time before it will even start the next step. **10 minutes are always reserved for reboot** on top of an average per-update install-time budget (about 15 minutes for standard updates, 20 minutes for a Windows service pack, before the reboot reservation is added). If less than that combined figure remains, Update Manager skips scanning/downloading/installing the remaining updates entirely rather than risk a mid-install cutoff — this is by design, not a bug.

```powershell
# Re-run on demand with a longer explicit duration to confirm this really is a timing issue
Invoke-AzVmInstallPatch -ResourceGroupName <rg> -VmName <vmName> -Windows `
  -RebootSetting IfRequired -MaximumDuration PT4H -ClassificationToIncludeForWindows Critical,Security

# If confirmed, widen the recurring schedule's duration
Update-AzMaintenanceConfiguration -ResourceGroupName <rg> -Name <configName> -Duration "04:00"
```

**Rollback:** widening a maintenance window has no destructive side effect; narrow it back with the same cmdlet if the longer window causes scheduling conflicts elsewhere.

</details>

<details><summary id="fix-5">Fix 5 — Linux sudo privileges missing</summary>

**Symptom:** `Error Message: Extension returned non-zero exit code for Install: 88`, or an exception containing `root is not in the sudoers file`.

**Root cause:** the Linux patch extension runs assessment/install operations as `root` via `sudo` — Update Manager needs kernel-driver and OS-security-patch-level access, which cannot be granted at a lower privilege tier. If `root` isn't permitted in `/etc/sudoers`, every operation fails identically regardless of network/agent health.

```bash
sudo visudo
# Add this line at the end of the file, save, and exit:
root ALL=(ALL) ALL
```

Then retry the assessment from the Azure side:
```powershell
Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vmName>
```

**Rollback:** removing the added sudoers line reverts the change; do so only after confirming no other automation on the box also depends on it.

</details>

---
## Escalation Evidence

Copy this template and fill in before escalating:

```
AZURE UPDATE MANAGER ESCALATION — <date/time>
Machine: <vmName>   Type: <Azure VM / Arc-enabled server>   Resource Group: <rg>   Subscription: <subId>

Power state / Arc connection status: <running / stopped / Connected / Disconnected>
Patch extension name + ProvisioningState: <paste Get-AzVMExtension output>
Last on-demand assessment result: <Succeeded/Failed — paste Invoke-AzVMPatchAssessment output>
Exact exception text (if any, including HRESULT code): <paste in full>

Maintenance configuration assigned: <yes/no — paste Get-AzConfigurationAssignment output>
Maintenance configuration name + window duration: <name / HH:MM>
Update history for last run: <Succeeded / Failed / Completed with warnings>
Maintenance window exceeded flag: <true/false>

Guest-OS-side check (Windows: wuauserv status / WSUS registry keys; Linux: sudoers, repo reachability):
  <paste>

What's been tried:
  <bullet list>

Business impact / urgency:
  <one line>
```

---
## 🎓 Learning Pointers

- **Update Manager only ever sees what "Check for updates" would show locally on the machine itself** — it doesn't publish, host, or curate updates. If the wrong updates (or none) show up, the fix is almost always the guest OS's own update-source configuration (Windows Update vs. WSUS vs. Microsoft Update; the configured Linux repo), not anything on the Azure side. See [How Update Manager works](https://learn.microsoft.com/en-us/azure/update-manager/workflow-update-manager).
- **The patch extension installs itself lazily, on first use, never ahead of time.** A brand-new VM showing no extension at all in `Get-AzVMExtension` is completely normal until the first `Check for updates`/`Install now`/periodic assessment/scheduled run actually fires. Don't treat "no extension yet" as a fault on its own. See [Prerequisites for Azure Update Manager](https://learn.microsoft.com/en-us/azure/update-manager/prerequisites).
- **Maintenance configuration assignments are their own resource and do not survive a VM's move to a different resource group or subscription.** A "the schedule stopped working" ticket right after a move is this, almost every time — the schedule itself is fine, the link to this specific VM just needs recreating. See [Troubleshoot known issues with Azure Update Manager](https://learn.microsoft.com/en-us/azure/update-manager/troubleshoot).
- **Ten (Windows) or fifteen (Linux) minutes of every maintenance window are always reserved for reboot, on top of a per-update install-time budget** — a window that looks generous on paper can still be too short once that reservation and the average install-time estimate are subtracted. Widen the window rather than assume the patch itself is the problem.
- **For Azure Arc-enabled servers, Update Manager is entirely dependent on a healthy Arc Connected Machine agent underneath it** — a disconnected or expired Arc agent produces symptoms that look exactly like a patching failure but have nothing to do with Update Manager. Always confirm `Azure/Arc/AzureArc-B.md`'s triage first for non-Azure machines. See [Azure Arc-enabled servers overview](https://learn.microsoft.com/en-us/azure/azure-arc/servers/overview).
- **On Linux, the extension runs update operations as root via sudo, by design** — a hardened sudoers policy that restricts root is one of the most common silent causes of "patching just doesn't work" on Linux fleets, and it fails identically whether or not the network path and repos are fine. See [Prerequisites for Azure Update Manager](https://learn.microsoft.com/en-us/azure/update-manager/prerequisites).
