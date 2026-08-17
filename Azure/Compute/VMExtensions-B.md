# Azure VM Extensions & Boot Diagnostics — Hotfix Runbook (Mode B: Ops)
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

Run these from Azure PowerShell (Az module) with a connected context. All five run in well under 60 seconds against a single VM.

```powershell
# 1. Is the VM actually running, and is the platform-reported VM Agent status Ready?
Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status |
  Select-Object @{N='PowerState';E={($_.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus}},
                @{N='AgentStatus';E={$_.VMAgent.Statuses.DisplayStatus}},
                @{N='AgentVersion';E={$_.VMAgent.VmAgentVersion}}

# 2. List every extension and its current provisioning state / status message
Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Status |
  Select-Object Name, ExtensionType, ProvisioningState, @{N='Message';E={$_.Statuses.Message}}

# 3. Confirm boot diagnostics is enabled and where it's writing (managed vs. custom storage account)
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").DiagnosticsProfile.BootDiagnostics |
  Select-Object Enabled, StorageUri

# 4. If RDP/SSH is unreachable, use Run Command to check the guest-side agent service
#    from OUTSIDE the VM (this itself requires the VM Agent to be at least partially alive)
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -Name "<vmName>" -CommandId 'RunPowerShellScript' `
  -ScriptString "Get-Service RdAgent, WindowsAzureGuestAgent | Select Name, Status, StartType; Test-NetConnection -ComputerName 168.63.129.16 -Port 32526"

# 5. Pull the current boot screenshot + serial log to local disk (works even if the OS never finished booting)
Get-AzVMBootDiagnosticsData -ResourceGroupName "<rg>" -Name "<vmName>" -Windows -LocalPath "C:\Temp\BootDiag"
```

| What you see | What it means |
|---|---|
| `PowerState` isn't `VM running` | Nothing extension- or agent-related can work until the VM is actually running — start it first, then re-triage |
| `AgentStatus` is blank or anything other than `Ready` | VM Agent itself is the problem, not the extension — every extension symptom downstream is noise until this is fixed — go to Fix 2 (Windows) / Fix 3 (Linux) |
| Extension `ProvisioningState` is `Failed` with a `VMExtensionProvisioningError` or `VMExtensionHandlerNonTransientError` message | A specific extension handler failed inside the guest — read the `Message` field first, it usually names the real cause (download 404, non-zero exit code, missing dependency) — go to Fix 5 |
| Extension `ProvisioningState` stuck on `Creating` or `Transitioning` for more than ~15-20 minutes with no status message | GoalState delivery is stuck, not the extension's own logic — go to Fix 4 |
| Run Command (step 4) itself times out or never returns | The VM Agent can't even accept a new GoalState — this is a Guest Agent connectivity/service problem, not a Run Command problem — go to Fix 2/3, and consider the Azure Serial Console (Fix 7) as an alternative in-guest access path |
| Boot diagnostics screenshot is blank, all-black, or clearly stale (old timestamp/date visible on screen) | Either the guest's display idle timeout is firing, or the boot diagnostics storage account itself has a problem — go to Fix 6 |
| `DiagnosticsProfile.BootDiagnostics.Enabled` is `False`, or `StorageUri` points at a Premium/ZRS account | Boot diagnostics (and therefore Serial Console) can't function — Premium and Zone-Redundant Storage are explicitly unsupported for this feature — go to Fix 6 |
| Antimalware extension (`IaaSAntimalware`) shows `Failed` | Different failure class from general extensions — check `CommandExecution.log` before assuming it's a generic Guest Agent problem — go to Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Azure Resource Manager / Fabric Controller (control plane)
  │
  ├── WireServer — the VM's ONLY channel back to the platform
  │     168.63.129.16 : TCP 80 (config) + TCP 32526 (extension/HostGAPlugin)
  │       └── Blocked by a guest firewall/NSG/proxy/third-party AV here = every
  │             extension AND every Run Command silently fails, with no local
  │             symptom that points at networking
  ▼
VM Agent (installed inside the guest OS, NOT the same thing as an extension)
  Windows: "Windows Azure Guest Agent" service runs WaAppAgent.exe
           "RdAgent" service installs/upgrades it and sends the heartbeat
  Linux:   waagent daemon, logs to /var/log/waagent.log
  │   Must report status "Ready" to the platform (visible as VM > Properties >
  │   Agent status in the portal) before ANY extension operation can begin
  ▼
Extension Handler — one per (Publisher, Type) pair, e.g.
  Microsoft.Compute.CustomScriptExtension, Microsoft.Azure.Security.IaaSAntimalware,
  Microsoft.Azure.Monitor.AzureMonitorWindowsAgent
  Downloaded + unpacked by the VM Agent to:
    Windows: C:\Packages\Plugins\<Publisher.Type>\<version>\
    Linux:   /var/lib/waagent/<Publisher.Type>-<version>/
  ▼
Extension instance execution (per VM, keyed by the extension's own Name)
  Settings/RuntimeSettings passed in → handler runs → writes a Status file →
  VM Agent reports that Status file's content back to ARM as ProvisioningState
  ▼
Reported state: Succeeded / Failed / Creating / Transitioning
```

**Boot diagnostics is architecturally separate from all of the above** — it runs
at the hypervisor level, reading the VM's virtual framebuffer and COM1 serial
port directly. It works even when the Guest Agent has never started, the OS
never finished booting, or the network stack inside the guest is completely
broken. Its only two dependencies are: (1) the feature itself being enabled on
the VM, and (2) a healthy, reachable Standard-tier storage account (managed or
customer-specified) to write the screenshot/log blobs to. **Serial Console**,
however, is a distinct third feature layered on top of boot diagnostics — it
will not function at all unless boot diagnostics is enabled first, even though
conceptually they feel like the same thing.

Key failure points:
- Blocking 168.63.129.16 (firewall, NSG misconfiguration, third-party AV/proxy doing SSL inspection) breaks the VM Agent, every extension, AND Run Command simultaneously — always rule this out before troubleshooting a single extension in isolation
- A VM created from a specialized/BYOL image or migrated from on-premises does NOT have the VM Agent pre-installed — Azure Marketplace images do
- Premium SSD and Zone-Redundant Storage accounts are explicitly unsupported as the boot diagnostics storage backend (`StorageAccountTypeNotSupported`)
- Extensions apply in the order Azure schedules them unless `provisionAfterExtensions` is explicitly set — a dependency-order assumption baked into a template without that property is a common self-inflicted "Transitioning forever" cause

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the VM is running and the platform sees a Ready Guest Agent**
```powershell
Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status
```
Expected: `PowerState/running` and `VMAgent.Statuses.DisplayStatus` = `Ready`. If either is wrong, stop here — nothing below this layer can be trusted until it's fixed.

**Step 2 — Identify exactly which extension(s) and which error**
```powershell
Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Status |
  Format-List Name, ExtensionType, ProvisioningState, Statuses
```
Expected: a specific `Code` and `Message` per extension. Capture the exact message text before doing anything destructive — reinstalling erases the evidence you'd need for escalation.

**Step 3 — Read the in-guest extension log for the failing extension**
Requires RDP/SSH, or Run Command if those are unreachable.
```powershell
# Windows — from inside the guest, or via Run Command
Get-Content "C:\WindowsAzure\Logs\Plugins\<Publisher.Type>\<version>\*.log" -Tail 100
# Linux — from inside the guest, or via Run Command
tail -n 100 /var/log/azure/<Publisher.Type>/handler.log
```
Expected: a specific error (404 on a blob download, a non-zero script exit code, a missing dependency, a timeout). This is almost always more informative than the ARM-level status message alone.

**Step 4 — If RDP/SSH is unreachable, use Run Command as the recovery path**
```powershell
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -Name "<vmName>" -CommandId 'RunPowerShellScript' `
  -ScriptString "Get-Service RdAgent, WindowsAzureGuestAgent | Select Name,Status; Get-NetFirewallProfile | Select Name,Enabled"
```
Expected: services `Running`, firewall state confirmed. **Caveat:** Run Command itself rides on the VM Agent — if the Agent is fully dead, Run Command won't work either, and you must fall back to the Serial Console (Fix 7) or a support-assisted recovery.

**Step 5 — If the VM never finished booting, pull boot diagnostics before touching anything**
```powershell
Get-AzVMBootDiagnosticsData -ResourceGroupName "<rg>" -Name "<vmName>" -Windows -LocalPath "C:\Temp\BootDiag"
```
Expected: a screenshot showing a recognizable OS state (login screen, boot logo, a specific stop code) and a serial log with the last messages before the hang. Note: screenshots/log data can take up to 10 minutes to appear in the storage account after an event — don't conclude "boot diagnostics is broken" from a single immediate check.

---
## Common Fix Paths

<details><summary>Fix 1 — VM is stopped/deallocated</summary>

**Cause:** The most common false alarm — an extension or agent "isn't responding" simply because the VM isn't running.

```powershell
Start-AzVM -ResourceGroupName "<rg>" -Name "<vmName>"
# Re-run Triage step 1 after the VM reports PowerState/running
```

**Rollback note:** N/A — starting a VM is non-destructive.

</details>

<details><summary>Fix 2 — Windows Guest Agent not running / not Ready</summary>

**Cause:** `WaAppAgent.exe` (running as the "Windows Azure Guest Agent" service) has crashed, was never installed (specialized/migrated image), or can't reach WireServer.

```powershell
# From inside the guest (RDP or Run Command)
Get-Service RdAgent, WindowsAzureGuestAgent | Select-Object Name, Status, StartType
Restart-Service RdAgent -Force
Start-Sleep -Seconds 30
Restart-Service WindowsAzureGuestAgent -Force

# Check the agent's own log for the real cause
Get-Content "C:\WindowsAzure\Logs\WaAppAgent.log" -Tail 100

# If the services don't exist at all, the agent was never installed —
# download and run the latest .msi (see Playbook 1 in the -A.md for the
# full reinstall procedure, including the WMI-repair fallback)
```

**Rollback note:** Restarting the agent services is non-destructive and doesn't affect running application workloads on the VM.

</details>

<details><summary>Fix 3 — Linux waagent not running / not Ready</summary>

**Cause:** The `walinuxagent`/`waagent` daemon has stopped, or `Provisioning.Agent` is misconfigured in `/etc/waagent.conf`.

```bash
# From inside the guest (SSH or Run Command)
systemctl status walinuxagent   # (Ubuntu/Debian) or waagent (RHEL/CentOS/SUSE)
sudo systemctl restart walinuxagent
sudo tail -n 100 /var/log/waagent.log
```

**Rollback note:** Restarting the daemon is non-destructive.

</details>

<details><summary>Fix 4 — Extension stuck in "Transitioning" / "Creating" with no progress</summary>

**Cause:** The GoalState delivered to the VM Agent never completed — often a missing `provisionAfterExtensions` dependency ordering, a corrupted transport certificate, or an agent that silently stopped mid-operation.

```powershell
# Trigger a new GoalState without a full redeploy (usually resolves a stuck
# certificate/transport state; rarely causes a reboot, but budget for one)
Set-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Reapply

# If Reapply doesn't clear it, remove and reinstall the specific extension
Remove-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Name "<extensionName>" -Force
Set-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Location "<region>" `
  -Publisher "<publisher>" -ExtensionType "<extensionType>" -Name "<extensionName>" `
  -TypeHandlerVersion "<version>" -Settings $settingsHashtable
```

**Rollback note:** `Reapply` is non-destructive to data; a short VM downtime is possible but a full reboot is uncommon. Removing/reinstalling an extension is safe for stateless extensions (CustomScriptExtension, Antimalware) — confirm any extension-managed state (e.g. AMA's Data Collection Rule associations) isn't lost before removing.

</details>

<details><summary>Fix 5 — CustomScriptExtension failing (download error or non-zero exit code)</summary>

**Cause:** Two distinct failure classes that look similar in the portal: the script/package **failed to download** (bad blob URI, expired SAS, 404), or it downloaded fine but the **script itself returned a non-zero exit code**.

```powershell
# Read the handler log for the specific failure (see Diagnosis Step 3 paths)
# Windows: C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\<ver>\CustomScriptHandler.log
# Linux:   /var/log/azure/Microsoft.Azure.Extensions.CustomScript/handler.log

# If it's a download failure, verify the blob URI and SAS token are still valid
Get-AzStorageBlob -Container "<container>" -Blob "<scriptname>.ps1" -Context $ctx

# Once the root cause (bad URI, script bug, missing dependency) is fixed,
# remove and reinstall — CSE does not auto-retry a failed run
Remove-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Name "<extensionName>" -Force
```

**Rollback note:** Safe to remove/reinstall — CustomScriptExtension has no persistent state of its own beyond what the script itself created on the VM.

</details>

<details><summary>Fix 6 — Boot diagnostics screenshot blank, all-black, or stale</summary>

**Cause:** Either the guest's display idle timeout is putting the virtual display to sleep (Windows-specific and very common), or the storage account backing boot diagnostics is unhealthy/unsupported.

```powershell
# If the OS is reachable another way (Run Command, or it recovers briefly),
# disable the display idle timeout that causes the stale-screenshot symptom
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -Name "<vmName>" -CommandId 'RunPowerShellScript' `
  -ScriptString "powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 0"

# Confirm the storage account type isn't the (unsupported) problem
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").DiagnosticsProfile.BootDiagnostics.StorageUri
# If it's a Premium_LRS or *_ZRS account, switch to a managed or Standard LRS/GRS account:
Set-AzVMBootDiagnostic -VM $vm -Enable -ResourceGroupName "<rg>" -StorageAccountUri "https://<standardStorageAcct>.blob.core.windows.net/"
Update-AzVM -ResourceGroupName "<rg>" -VM $vm
```

**Rollback note:** Non-destructive. Remember screenshots/logs can take up to 10 minutes to refresh after any change — don't re-diagnose too early.

</details>

<details><summary>Fix 7 — Serial Console unavailable / can't connect</summary>

**Cause:** Serial Console has boot diagnostics as a hard prerequisite — if boot diagnostics is disabled, misconfigured, or pointed at an unreachable custom storage account, Serial Console fails even though it looks like a separate feature.

```powershell
# Confirm boot diagnostics is enabled first (Serial Console will not work otherwise)
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").DiagnosticsProfile.BootDiagnostics.Enabled

# If using a custom (non-managed) storage account, confirm firewall and key access
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageAcctName>" |
  Select-Object -ExpandProperty NetworkRuleSet
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageAcctName>" |
  Select-Object AllowSharedKeyAccess
# AllowSharedKeyAccess must be $true — Serial Console requires storage account key access
```

**Rollback note:** N/A — read-only checks. Re-enabling storage account key access is a security-relevant change; confirm with the account owner before doing so on a production storage account.

</details>

<details><summary>Fix 8 — Microsoft Antimalware extension (IaaSAntimalware) failing</summary>

**Cause:** Distinct failure surface from general extensions — most commonly an exclusion-list update that unintentionally wiped existing exclusions (the extension **overwrites**, not merges, on every settings update), or the VM lacking outbound internet access for signature updates.

```powershell
# Check the extension's own log
Get-Content "C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.Security.IaaSAntimalware\<version>\CommandExecution.log" -Tail 100

# Confirm current exclusions actually took effect in the registry
# (Windows Server 2016/2019/2022):
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Extensions"
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Paths"

# If reapplying exclusions, always resend the FULL exclusion list —
# omitting a previously-configured exclusion in the new settings payload
# blanks it out, it does not merge
```

**Rollback note:** N/A — re-applying the extension's settings with the correct full exclusion list is the fix; there is no portal UI for this, only PowerShell/ARM template.

</details>

<details><summary>Fix 9 — RDP/SSH unreachable, need to recover the guest directly</summary>

**Cause:** Any of the above may leave you unable to reach the VM interactively. Run Command and Serial Console are the two supported recovery paths that don't require inbound network access.

```powershell
# Run Command — requires a still-functioning VM Agent
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -Name "<vmName>" -CommandId 'RunPowerShellScript' `
  -ScriptString "Get-NetFirewallRule -DisplayName 'Remote Desktop*' | Select DisplayName,Enabled"

# Serial Console — works even if the VM Agent/network stack is broken, since it's
# a hypervisor-level COM1 connection (requires boot diagnostics enabled — see Fix 7)
# Portal: VM > Support + troubleshooting > Serial console
```

**Rollback note:** N/A — both are diagnostic/recovery access paths, not configuration changes.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Azure VM Extension / Boot Diagnostics

Subscription / Resource group / VM name: ____________
VM PowerState: ____________
VM Agent status + version (Triage step 1): ____________
Affected extension(s): Name / Publisher.Type / TypeHandlerVersion: ____________
Reported ProvisioningState + exact status Message (Triage step 2): ____________
In-guest handler log excerpt (Diagnosis step 3, last 20-30 lines): ____________
WireServer connectivity confirmed (168.63.129.16:80/32526)?: ____________
Boot diagnostics enabled? Storage account type (managed/Standard/Premium/ZRS): ____________
Boot screenshot / serial log attached (yes/no, timestamp): ____________
Run Command tested — succeeded/failed/timed out: ____________
Serial Console tested — succeeded/failed: ____________

Steps already attempted:
[ ] Confirmed VM is running and re-checked after starting it
[ ] Confirmed VM Agent status and restarted RdAgent/WindowsAzureGuestAgent (or waagent)
[ ] Reviewed in-guest extension handler log for the specific error
[ ] Attempted VM Reapply
[ ] Attempted extension remove + reinstall
[ ] Confirmed boot diagnostics storage account isn't Premium/ZRS
[ ] Attempted Run Command and/or Serial Console as an alternate access path
```

---
## 🎓 Learning Pointers

- **The VM Agent is not an extension, and no extension can install, update, or report status without it.** Always confirm `AgentStatus: Ready` before troubleshooting a specific extension — a "Not ready" or blank agent status explains every downstream extension failure at once, and no amount of removing/reinstalling extensions fixes it.
- **Boot diagnostics runs at the hypervisor level and is architecturally independent of the Guest Agent, the extension pipeline, and the guest OS's own network stack.** This is exactly why it's the right first tool when a VM won't boot at all — it works even when nothing inside the guest is reachable.
- **Serial Console is a separate feature layered on top of boot diagnostics, not a synonym for it.** If boot diagnostics is disabled or its storage account is unreachable, Serial Console fails too, even though the symptom ("can't get a console") looks identical to a Serial-Console-specific bug.
- **Run Command rides on the same VM Agent that extensions depend on** — it is not an independent out-of-band channel. If the Guest Agent is fully dead, Run Command will time out exactly like an extension install would, and Serial Console (hypervisor-level) is the remaining option.
- **Premium SSD and Zone-Redundant Storage accounts are explicitly unsupported as the boot diagnostics backend** (`StorageAccountTypeNotSupported`) — a surprisingly common self-inflicted cause when a customer standardizes all storage accounts on Premium/ZRS for other reasons and boot diagnostics quietly stops working.
- **The Microsoft Antimalware extension's exclusion settings are replace-not-merge on every update** — resending a settings payload without a previously-configured exclusion silently removes it, rather than leaving it untouched.
- Related: [Troubleshooting Windows VM extension failures](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/troubleshoot), [Troubleshoot Azure Windows VM Agent issues](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/windows-azure-guest-agent), [How to use boot diagnostics to troubleshoot virtual machines in Azure](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/boot-diagnostics), [Run scripts in your VM by using Run Command](https://learn.microsoft.com/en-us/azure/virtual-machines/run-command-overview), [VM extension provisioning errors in Virtual Machine Scale Sets](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machine-scale-sets/extensions/vm-extension-provisioning-errors) (same error codes/causes apply to single VMs), [Microsoft Antimalware Extension for Windows VMs on Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/iaas-antimalware-windows)
