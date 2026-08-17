# Azure VM Extensions & Boot Diagnostics — Reference Runbook (Mode A: Deep Dive)
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
- The Azure VM Agent architecture (Windows Guest Agent / `WaAppAgent.exe` / RdAgent service, and Linux `waagent`/WALinuxAgent) as the mandatory prerequisite layer underneath every VM extension
- VM extension lifecycle: GoalState delivery, handler download/install/enable, settings/status file exchange, and how `ProvisioningState` (Succeeded/Failed/Creating/Transitioning) is derived and reported to Azure Resource Manager
- Common extension failure modes: `VMExtensionProvisioningError`, `VMExtensionHandlerNonTransientError`, `VMExtensionProvisioningTimeout`, stuck/"Transitioning" extensions, and the specific handling of CustomScriptExtension (download vs. execution failures) and the Microsoft Antimalware extension (`IaaSAntimalware`, exclusion replace-not-merge behavior)
- Boot diagnostics: the hypervisor-level screenshot + serial log capture mechanism, its storage account dependency and unsupported-tier constraints, and its relationship to (but architectural independence from) the VM Agent
- Azure Serial Console as a boot-diagnostics-dependent, hypervisor-level recovery access path
- Run Command (both the original action-oriented commands and the newer Managed Run Command) as a VM-Agent-dependent diagnostic/recovery tool for when RDP/SSH is unreachable
- Cross-references to the Azure Monitor Agent (AMA) extension specifically for extension-lifecycle mechanics common to all extensions — AMA's own Data Collection Rule architecture is intentionally NOT re-explained here

**Out of scope:**
- Azure Monitor Agent's own architecture (Data Collection Rules, Data Collection Endpoints, table-plan cost model) — see `Azure/Monitor/LogAnalytics-A.md`, which owns that topic in full; this runbook covers only the shared extension-provisioning mechanics that also apply to AMA
- Azure Backup's VM extension (`AzureBackupWindowsIaasExtension` / `AzureBackupLinuxIaasExtension`) and its VSS/snapshot-specific failure modes — see `Azure/Backup/AzureBackup-A.md`, which owns backup-specific guest prerequisite health
- Azure Arc-enabled server extensions (the Connected Machine agent's own extension model for non-Azure/on-premises servers) — a materially different onboarding and identity architecture; see `Azure/Arc/AzureArc-A.md`
- VM networking (NIC/NSG/routing) beyond the specific WireServer connectivity requirement extensions depend on — see `Azure/Networking/NSG-A.md` for general NSG troubleshooting
- OS-level disk/boot-loader repair once boot diagnostics has confirmed a specific in-guest boot failure (BCD repair, GRUB repair, disk attach-to-recovery-VM workflows) — a natural follow-on topic for a future run, not covered here
- Azure Update Manager's own patch-extension lifecycle — see `Azure/UpdateManager/UpdateManager-A.md`, which shares the same VM Agent dependency but owns the patching-specific extension behavior

**Assumptions:**
- Diagnostic access: Contributor (or Virtual Machine Contributor) on the VM's resource group for ARM-level operations; RDP/SSH or Run Command access for in-guest log review
- Az PowerShell module (`Az.Compute`, `Az.Storage`) available and authenticated (`Connect-AzAccount`)
- The VM is an Azure Resource Manager (ARM) deployment model VM — classic/ASM VMs are end-of-life and not covered

---
## How It Works

<details><summary>Full architecture</summary>

**The VM Agent is the foundation everything else in this topic depends on.** Every Azure VM built from a Marketplace image ships with the Azure VM Agent pre-installed. On Windows, this is the **Windows Azure Guest Agent** service, which runs the `WaAppAgent.exe` process and is responsible for extension orchestration, certificate handling, and writing to `WaAppAgent.log`. A companion **RdAgent** service is responsible for installing and upgrading the Guest Agent itself (via its Transparent Installer component) and for sending a periodic heartbeat from the guest VM back to the host Fabric Controller. On Linux, the equivalent single daemon is `waagent` (WALinuxAgent), logging to `/var/log/waagent.log`. VMs built from a specialized/generalized custom image or migrated in from on-premises do **not** have the Agent pre-installed and require a manual install.

The Agent's only communication channel to the Azure platform is the **WireServer** — a well-known, non-routable virtual IP, `168.63.129.16`, reachable on TCP port 80 (general configuration/heartbeat) and TCP port 32526 (the HostGAPlugin endpoint extensions specifically use for settings/status exchange). This address is injected into every VNet automatically; a guest-level firewall rule, a misconfigured NSG, or a third-party proxy/AV product performing SSL inspection can each independently block it, and doing so breaks the Agent, every extension, and Run Command simultaneously — with no local symptom that obviously points at networking as the cause.

**Extension lifecycle.** An extension is identified by a `(Publisher, Type)` pair — e.g. `Microsoft.Compute.CustomScriptExtension`, `Microsoft.Azure.Security.IaaSAntimalware`, `Microsoft.Azure.Monitor.AzureMonitorWindowsAgent` — plus a `TypeHandlerVersion` and a per-VM instance `Name`. When an extension is added or updated via ARM, a **GoalState** is delivered to the VM Agent over WireServer. The Agent downloads the extension's handler package (to `C:\Packages\Plugins\<Publisher.Type>\<version>\` on Windows, `/var/lib/waagent/<Publisher.Type>-<version>/` on Linux), passes the extension's `Settings`/`ProtectedSettings` through to the handler as `RuntimeSettings`, and the handler executes its own install/enable logic. The handler writes its result to a **Status file**, which the Agent reads and reports back to ARM — this is the sole source of the `ProvisioningState` value (`Succeeded`, `Failed`, `Creating`, `Transitioning`) visible in the portal and via PowerShell/CLI. Extensions apply in the order Azure schedules them unless a template explicitly sets `provisionAfterExtensions` to declare a dependency; omitting this on a template that assumes implicit ordering is a common cause of one extension silently starting before a prerequisite extension has finished.

A **certificate** (the "Windows Azure CRP Certificate Generator") protects extension settings in transit between the platform and the Agent. If this certificate goes missing or becomes invalid — most often after an image-generalization step that didn't clean up Agent state — extensions fail with no obvious settings-related cause. Restarting the `WindowsAzureGuestAgent.exe` process (which the Windows Azure Guest Agent service automatically relaunches) regenerates it; a **VM Reapply** operation (the `Reapply` REST API, introduced 2020) achieves the same effect by re-delivering a fresh GoalState without a full VM redeploy, and is the platform-recommended first move for a stuck extension.

**Boot diagnostics operates entirely outside this pipeline.** Rather than depending on the Guest Agent, the guest OS, or the network stack inside the VM, it reads the VM's state directly from the **hypervisor**: a periodic screenshot of the virtual framebuffer, and a capture of output written to the virtual COM1 serial port. This is precisely why it remains useful when a VM never finishes booting, or when the Agent itself has failed — none of that matters to the hypervisor-level capture. Its only dependencies are the feature being enabled on the VM (`DiagnosticsProfile.BootDiagnostics.Enabled`) and a healthy, reachable storage account to write screenshot/log blobs to — either a Microsoft-managed account (default, zero configuration) or a customer-specified one. **Premium SSD and Zone-Redundant Storage (ZRS) account types are explicitly unsupported** as the boot diagnostics backend; attempting to use one produces a `StorageAccountTypeNotSupported` error at VM start. Screenshot/log data can take up to 10 minutes to land in the storage account after a boot event, which routinely gets misread as "boot diagnostics is broken" during an active outage.

**Serial Console** is a distinct, separate feature built on top of boot diagnostics rather than a synonym for it — it provides an interactive text-mode connection to COM1 (Windows: SAC, Special Administration Console; Linux: a standard serial getty), reachable from the Azure portal without any inbound network path to the VM. Because it's layered on boot diagnostics, it fails outright if boot diagnostics itself is disabled, or if a customer-specified storage account has its firewall or shared-key access misconfigured (Serial Console specifically requires storage account key access, `AllowSharedKeyAccess: $true`).

**Run Command**, by contrast, is NOT hypervisor-level — it explicitly rides the same VM Agent pipeline as extensions, executing a script inside the guest via the Agent. There are two generations: the original **action-oriented** commands (built-in `CommandId` values like `RunPowerShellScript`/`RunShellScript`, one active execution at a time, a 90-minute limit, output capped at 4 KB in the status blob, executes as SYSTEM/root) and the newer **Managed Run Command** (a first-class ARM resource type, customer-specified execution account and timeout, multiple commands in parallel or sequenced, larger output via an append blob, and Virtual Machine Scale Set support). Because Run Command depends on a working Agent, it is not an independent out-of-band recovery channel — if the Agent is fully non-responsive, Run Command will time out exactly as an extension install would, leaving Serial Console as the remaining hypervisor-level option.

</details>

---
## Dependency Stack

```
Layer 5 — Diagnostic/recovery tooling
    Run Command (rides the VM Agent — fails together with extensions if the
    Agent is dead) · Serial Console (hypervisor-level, requires boot
    diagnostics enabled as its own prerequisite, independent of the Agent)
        ▲ requires
Layer 4 — Extension instances
    Per-VM-per-Name execution: Settings/RuntimeSettings → handler → Status
    file → reported ProvisioningState (Succeeded/Failed/Creating/Transitioning)
    Optional provisionAfterExtensions dependency ordering
        ▲ requires
Layer 3 — Extension handler packages
    Downloaded/unpacked per (Publisher, Type, TypeHandlerVersion):
    Windows C:\Packages\Plugins\<Publisher.Type>\<ver>\ ·
    Linux /var/lib/waagent/<Publisher.Type>-<ver>/
        ▲ requires
Layer 2 — VM Agent (guest-installed, NOT itself an extension)
    Windows: "Windows Azure Guest Agent" service (WaAppAgent.exe) +
    "RdAgent" service (installer/heartbeat) · Linux: waagent daemon
    Must report "Ready" before ANY extension operation can begin
    Pre-installed on Marketplace images; MISSING on specialized/migrated images
        ▲ requires
Layer 1 — WireServer control channel
    168.63.129.16 : TCP 80 (config/heartbeat) + TCP 32526 (HostGAPlugin,
    extension settings/status exchange) — guest firewall/NSG/SSL-inspecting
    proxy interference here breaks Layers 2-5 simultaneously
        ▲ requires
Layer 0 — Azure Resource Manager / Fabric Controller (control plane)
    Source of every GoalState; VM Reapply re-delivers a fresh one without a
    full redeploy

Boot diagnostics — a PARALLEL, independent stack, not layered on the above:
    Hypervisor (framebuffer screenshot + COM1 serial capture)
        ▲ requires only
    Storage account (managed OR customer-specified; Standard tier only —
    Premium/ZRS unsupported) + the feature flag itself being enabled
```

A failure at Layer 1 or 2 masks everything above it in the main stack — always validate WireServer connectivity and Agent status before troubleshooting a specific extension. Boot diagnostics' independence from Layers 1-5 is precisely why it is the correct first tool when the guest is completely unreachable.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Extension `ProvisioningState: Failed`, error `VMExtensionProvisioningError` | A specific extension handler failed inside the guest — the ARM-level message is a summary, not the root cause | `Get-AzVMExtension -Status`, then the in-guest handler log |
| Extension `ProvisioningState: Failed`, error `VMExtensionHandlerNonTransientError` with a non-zero exit code | The handler itself completed but returned a failure exit code (script bug, missing dependency, package-manager lock) | In-guest handler log for the exact exit code and stderr |
| Extension stuck on `Creating`/`Transitioning` for 15-20+ minutes, no message | GoalState delivery stalled — corrupted transport certificate, agent silently stopped mid-operation, or a missing `provisionAfterExtensions` dependency ordering | VM Reapply first; then Agent service state |
| VM Agent status `Not ready` or blank in the portal | Agent service crashed/never installed (specialized/migrated image), or WireServer is unreachable | `Get-AzVM -Status`, then Agent service state and WaAppAgent.log/waagent.log |
| Every extension AND Run Command fail at once, with no per-extension pattern | WireServer (168.63.129.16:80/32526) blocked by guest firewall, NSG, or an SSL-inspecting proxy/AV product | In-guest connectivity test to 168.63.129.16 (via Run Command if still possible, or Serial Console if not) |
| CustomScriptExtension fails with a 404-style download error | Blob URI wrong, blob deleted, or a SAS token expired | `Get-AzStorageBlob` against the referenced URI; handler log's download section |
| CustomScriptExtension fails with a non-zero exit code but downloaded fine | The script itself failed — logic bug, missing prerequisite software, wrong working directory assumption | `CustomScriptHandler.log` / `handler.log` stdout/stderr sections |
| `IaaSAntimalware` extension fails or previously-working exclusions silently stop applying | The extension **replaces**, never merges, its exclusion settings on every update — a partial settings payload wipes prior exclusions | `CommandExecution.log`; registry exclusion keys under `HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\` |
| AMA extension shows `Succeeded` but the VM still isn't in scope for a Data Collection Rule | Extension-layer success only confirms install, not DCR association — an AMA-specific, not extension-generic, symptom | See `Azure/Monitor/LogAnalytics-B.md` Fix 3 (missing DCR association) — not duplicated here |
| Boot diagnostics screenshot is blank/black | Windows guest display idle timeout hasn't been disabled (common on custom/BYOL images where the provisioning agent never ran) | `powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 0` via Run Command or in-guest |
| Boot diagnostics screenshot is visibly stale (old clock/date on screen) | Same idle-timeout cause, or the storage account itself isn't refreshing (rare) — always allow the documented 10-minute lag before concluding it's broken | Re-check after 10 minutes; confirm storage account health |
| VM start fails with `StorageAccountTypeNotSupported` | Boot diagnostics storage account is Premium SSD or ZRS — both explicitly unsupported for this feature | `DiagnosticsProfile.BootDiagnostics.StorageUri` account SKU |
| Serial Console button greyed out or connection fails immediately | Boot diagnostics itself is disabled — Serial Console has zero independent functionality without it | Confirm `BootDiagnostics.Enabled` before troubleshooting Serial Console as if it were its own feature |
| Serial Console fails specifically on a VM using a custom (non-managed) boot diagnostics storage account | Storage account firewall blocking access, or `AllowSharedKeyAccess` disabled (Serial Console requires key-based access, not just RBAC) | `Get-AzStorageAccount` `NetworkRuleSet` and `AllowSharedKeyAccess` |
| Run Command hangs/times out with no output | VM Agent isn't responding — Run Command has no independent execution path of its own | Fall back to Serial Console; troubleshoot the Agent directly, not Run Command |
| Extension works fine on most fleet VMs but fails only on ones built from a captured/generalized image | Leftover extension state (binaries/logs/Status files) from the source VM confuses the new VM's reported extension state | Remove all extensions from the source VM before generalizing; reinstall fresh post-deployment |
| `'powershell' isn't recognized...` inside a RunCommand/CSE execution, but works fine over RDP | Extensions/Run Command execute as the Local System account, which can have a different effective PATH than an interactive user session | Confirm PowerShell is present in the **System** `Path` environment variable, not just the user's |
| `The remote certificate is invalid according to the validation procedure` in WaAppAgent.log | Missing Baltimore CyberTrust Root certificate, or an SSL-inspecting proxy/AV breaking the TLS chain to the platform | `certmgr.msc` root store check; exempt Azure platform endpoints from SSL inspection |

---
## Validation Steps

1. **Confirm the VM is running and the Agent reports Ready.**
   ```powershell
   Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status
   ```
   Good: `PowerState/running`, `VMAgent.Statuses.DisplayStatus = Ready`. Bad: anything else — stop and fix this layer first, every symptom above it is unreliable until this is true.

2. **Confirm WireServer reachability from inside the guest.**
   ```powershell
   Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -Name "<vmName>" -CommandId 'RunPowerShellScript' `
     -ScriptString "Test-NetConnection -ComputerName 168.63.129.16 -Port 32526; Test-NetConnection -ComputerName 168.63.129.16 -Port 80"
   ```
   Good: `TcpTestSucceeded: True` on both ports. Bad: either fails — a guest firewall rule, NSG, or SSL-inspecting proxy is very likely blocking the Agent's only channel to the platform.

3. **Confirm each extension's reported state and message.**
   ```powershell
   Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Status | Format-List *
   ```
   Good: `ProvisioningState: Succeeded`. Bad: `Failed`/stuck `Creating`/`Transitioning` — capture the exact `Statuses.Message` before taking any remediation action.

4. **Confirm the in-guest handler log matches the ARM-level symptom.**
   ```powershell
   # Windows
   Get-Content "C:\WindowsAzure\Logs\Plugins\<Publisher.Type>\<version>\*.log" -Tail 100
   ```
   Good: a specific, actionable error (exit code, missing file, blob 404). Bad: no log present at all — often means the handler package never finished downloading, pointing back at Agent/WireServer health rather than the extension's own logic.

5. **Confirm boot diagnostics configuration before relying on a screenshot/serial log.**
   ```powershell
   (Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").DiagnosticsProfile.BootDiagnostics | Select Enabled, StorageUri
   ```
   Good: `Enabled: True`, `StorageUri` pointing at a managed or Standard-tier account. Bad: `Enabled: False`, or a Premium/ZRS `StorageUri` — fix this before trusting an absent or stale screenshot as evidence of anything.

6. **Pull and inspect the actual boot diagnostics data.**
   ```powershell
   Get-AzVMBootDiagnosticsData -ResourceGroupName "<rg>" -Name "<vmName>" -Windows -LocalPath "C:\Temp\BootDiag"
   ```
   Good: a screenshot showing a recognizable, current OS state and a serial log with recent, relevant output. Bad: blank/black screenshot (check display idle timeout) or data clearly older than 10 minutes despite a recent boot event (re-check, don't over-conclude immediately).

7. **Confirm Serial Console's own prerequisite chain before troubleshooting it as an independent feature.**
   ```powershell
   Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageAcctName>" | Select AllowSharedKeyAccess
   Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageAcctName>" | Select-Object -ExpandProperty NetworkRuleSet
   ```
   Good (for a customer-managed boot diagnostics storage account): `AllowSharedKeyAccess: True`, and the VM's outbound path/allowed IPs present in the network rule set. Bad: either misconfigured — Serial Console will fail even though boot diagnostics screenshots may still work via the portal's own service path.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the platform-visible baseline**
Start at Layer 0/1 of the dependency stack every time: is the VM running, is the Agent `Ready`, is WireServer reachable. Resist diagnosing a specific extension until this baseline is confirmed — most single-extension symptoms are actually Agent/network symptoms in disguise.

**Phase 2 — Isolate to a specific extension and read its own evidence**
Once the Agent is confirmed healthy, capture the exact `ProvisioningState` and `Statuses.Message` per extension, then go straight to the in-guest handler log for that specific `(Publisher, Type)` — the ARM-level message is a summary and frequently omits the actual exit code or file path involved.

**Phase 3 — Distinguish "stuck" from "failed"**
A `Failed` state with a message is a completed, diagnosable failure. A `Creating`/`Transitioning` state with no progress for 15+ minutes is a stuck GoalState — these require different remediation (VM Reapply / certificate regeneration vs. fixing the extension's own settings/script/dependency).

**Phase 4 — If the guest is unreachable interactively, choose the right recovery tool deliberately**
Run Command only works if the Agent is at least partially alive — attempting it first wastes time if the Agent is fully dead. If Triage/Validation already showed `AgentStatus` not `Ready`, go straight to Serial Console (hypervisor-level, independent of the Agent) rather than retrying Run Command.

**Phase 5 — If the VM never boots, treat boot diagnostics as the primary evidence source, not a secondary one**
Pull the screenshot and serial log before attempting any in-guest remediation — they frequently identify the exact stop code or last-logged boot stage without needing any other access path, and remain valid evidence even if every subsequent recovery attempt also fails.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full Windows Guest Agent reinstall (Agent missing or unrecoverable via service restart)</summary>

Use when the Agent services don't exist at all, or repeated restarts don't restore a `Ready` status.

```powershell
# From inside the guest (RDP, or Run Command if the Agent is partially alive)
# 1. Stop and remove existing services if present
net stop rdagent
net stop WindowsAzureGuestAgent
sc delete rdagent
sc delete WindowsAzureGuestAgent

# 2. Move any stale Agent folders aside rather than deleting outright
mkdir C:\WindowsAzure\OLD
move C:\WindowsAzure\Packages C:\WindowsAzure\OLD\
move C:\WindowsAzure\GuestAgent C:\WindowsAzure\OLD\

# 3. Download and install the latest Agent MSI
#    (from https://github.com/Azure/WindowsVMAgent/releases)
msiexec.exe /i C:\VMAgentMSI\WindowsAzureVmAgent.2.7.<version>.fre.msi /L*v C:\Windows\Panther\msiexec.log

# 4. Confirm the services exist and are Running afterward
Get-Service RdAgent, WindowsAzureGuestAgent | Select Name, Status, StartType
```

If the MSI installation itself fails, it's frequently a faulty WMI repository (the installer uses `StdRegProv`) — verify and, if needed, salvage/reset the WMI repository (`winmgmt /verifyrepository`, `winmgmt /salvagerepository`, or as a last resort `winmgmt /resetrepository`) before retrying the MSI.

**Rollback note:** The moved `OLD` folders can be restored if the reinstall makes things worse, but a clean Agent reinstall is the Microsoft-documented recovery path and is safe to proceed with directly in the vast majority of cases.

</details>

<details><summary>Playbook 2 — Recovering from a corrupted transport certificate ("Windows Azure CRP Certificate Generator" missing)</summary>

Use when extensions fail with settings-related errors that don't correspond to any actual settings problem — a classic symptom of a broken transport certificate.

```powershell
# Option A — restart the Guest Agent process from inside the guest
# (Task Manager > Details > WindowsAzureGuestAgent.exe > End Task; it auto-restarts
#  and regenerates the certificate as part of its startup sequence)

# Option B — trigger a new GoalState without a full redeploy (recommended first attempt)
Set-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Reapply
# or via CLI:
az vm reapply -g "<rg>" -n "<vmName>"

# Option C — if Reapply doesn't resolve it, attach then remove an empty data disk
# to force a configuration refresh cycle (documented Microsoft fallback)
```

**Rollback note:** `Reapply` rarely triggers a reboot but can in edge cases involving a pending update — schedule for a maintenance window when possible. Option C's disk attach/detach is non-destructive to existing data.

</details>

<details><summary>Playbook 3 — Standardizing on a Standard-tier boot diagnostics storage account fleet-wide</summary>

Use when onboarding a client whose storage accounts default to Premium/ZRS for other workloads, which silently breaks boot diagnostics (and therefore Serial Console) on any VM pointed at one.

```powershell
# Identify VMs whose boot diagnostics storage account is an unsupported tier
$vms = Get-AzVM
foreach ($vm in $vms) {
    $uri = $vm.DiagnosticsProfile.BootDiagnostics.StorageUri
    if ($uri) {
        $acctName = ([uri]$uri).Host.Split('.')[0]
        $acct = Get-AzStorageAccount | Where-Object StorageAccountName -eq $acctName
        if ($acct.Sku.Name -match 'Premium|ZRS') {
            Write-Warning "$($vm.Name) uses unsupported boot diagnostics storage tier: $($acct.Sku.Name)"
        }
    }
}

# Remediate by switching to a managed storage account (simplest, zero-maintenance)
Set-AzVMBootDiagnostic -VM $vm -Enable -ResourceGroupName "<rg>"
Update-AzVM -ResourceGroupName "<rg>" -VM $vm
```

**Rollback note:** Switching boot diagnostics storage accounts doesn't affect any other workload on the original account; safe to change at any time, though historical screenshots/logs on the old account won't carry forward.

</details>

<details><summary>Playbook 4 — Fleet-wide extension health baseline before a client onboarding or major change window</summary>

Use before a scheduled patch cycle, image refresh, or extension rollout across a client's VM fleet, to catch Agent/extension drift before it becomes an incident mid-change.

```powershell
$rg = "<rg>"
$report = foreach ($vm in Get-AzVM -ResourceGroupName $rg) {
    $status = Get-AzVM -ResourceGroupName $rg -Name $vm.Name -Status
    [pscustomobject]@{
        VM           = $vm.Name
        PowerState   = ($status.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus
        AgentStatus  = $status.VMAgent.Statuses.DisplayStatus
        AgentVersion = $status.VMAgent.VmAgentVersion
        FailedExtensions = (Get-AzVMExtension -ResourceGroupName $rg -VMName $vm.Name -Status |
            Where-Object ProvisioningState -ne 'Succeeded').Name -join ','
        BootDiagEnabled = $vm.DiagnosticsProfile.BootDiagnostics.Enabled
    }
}
$report | Format-Table -AutoSize
```

See the Evidence Pack / `Get-AzureVMExtensionHealth.ps1` for the fuller, fleet-scale, CSV-exporting version of this same check.

**Rollback note:** N/A — read-only reporting.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Azure VM Agent, extension, and boot diagnostics evidence for escalation to Microsoft support.
.NOTES
    Run from a machine with Az PowerShell authenticated. For deeper in-guest log review,
    combine with Run Command or direct RDP/SSH access separately.
#>
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$VMName
)

$vm     = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
$status = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
$exts   = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Status

$evidence = [ordered]@{
    Timestamp         = Get-Date -Format "o"
    PowerState        = ($status.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus
    AgentStatus       = $status.VMAgent.Statuses.DisplayStatus
    AgentVersion      = $status.VMAgent.VmAgentVersion
    Extensions        = $exts | Select-Object Name, ExtensionType, TypeHandlerVersion, ProvisioningState,
                                   @{N='Message';E={$_.Statuses.Message}}
    BootDiagnostics   = $vm.DiagnosticsProfile.BootDiagnostics
}

$evidence | ConvertTo-Json -Depth 6 | Out-File ".\VMExtensions-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss).json"
Write-Host "Evidence pack written." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzVM -ResourceGroupName <rg> -Name <vm> -Status` | VM power state + VM Agent status/version |
| `Get-AzVMExtension -ResourceGroupName <rg> -VMName <vm> -Status` | Per-extension `ProvisioningState` and status message |
| `Set-AzVMExtension ...` | Add or update an extension on a VM |
| `Remove-AzVMExtension -ResourceGroupName <rg> -VMName <vm> -Name <name>` | Remove a stuck/failed extension before reinstalling |
| `Set-AzVM -ResourceGroupName <rg> -Name <vm> -Reapply` | Re-deliver a fresh GoalState without a full redeploy |
| `Invoke-AzVMRunCommand -ResourceGroupName <rg> -Name <vm> -CommandId RunPowerShellScript -ScriptString "<script>"` | Run a script in-guest via the VM Agent (action Run Command) |
| `Get-AzVMBootDiagnosticsData -ResourceGroupName <rg> -Name <vm> -Windows -LocalPath <path>` | Download the current boot screenshot + serial log |
| `Set-AzVMBootDiagnostic -VM <vm> -Enable -ResourceGroupName <rg> [-StorageAccountUri <uri>]` | Enable/reconfigure boot diagnostics (managed or custom storage) |
| `Get-AzStorageAccount -ResourceGroupName <rg> -Name <acct> \| Select AllowSharedKeyAccess` | Confirm Serial Console's shared-key-access prerequisite |
| `Start-AzVM` / `Restart-AzVM` / `Stop-AzVM` | Basic power-state control |
| `Get-Service RdAgent, WindowsAzureGuestAgent` (in-guest) | Windows Agent service state |
| `systemctl status waagent` / `walinuxagent` (in-guest) | Linux Agent daemon state |
| `Test-NetConnection -ComputerName 168.63.129.16 -Port 32526` (in-guest) | WireServer/HostGAPlugin reachability |
| `az vm extension list -g <rg> --vm-name <vm> -o table` | CLI equivalent extension listing |
| `az vm boot-diagnostics get-boot-log -g <rg> -n <vm>` | CLI serial log retrieval |

---
## 🎓 Learning Pointers

- **The VM Agent, extension handlers, and extension instances are three distinct layers, and a failure at the lowest one produces symptoms that look identical to a failure at the highest one.** A "CustomScriptExtension failed" ticket is frequently actually an Agent connectivity problem — always validate Layer 1/2 of the Dependency Stack before trusting a specific extension's own error message at face value.
- **Boot diagnostics' independence from the Guest Agent is the single most useful architectural fact in this topic.** It's the correct first diagnostic step for a VM that never boots, precisely because it doesn't share a single dependency with anything else that might be broken.
- **Run Command is not an out-of-band recovery channel — it depends on the exact same Agent that extensions do.** Treat "try Run Command" and "try reinstalling an extension" as requiring the same prerequisite health check, and reach for Serial Console instead when the Agent itself is confirmed down.
- **Premium/ZRS storage accounts are a durable, easy-to-reproduce trap for boot diagnostics** — a client's storage-standardization policy elsewhere in the environment can silently disable this feature fleet-wide with no error until someone actually needs a boot screenshot during an incident.
- **The Microsoft Antimalware extension's settings model is destructive-by-default on update** — always read back the current exclusion list before pushing a change, since a partial payload silently blanks anything not explicitly included.
- **This topic deliberately does not re-explain Azure Monitor Agent's own Data Collection Rule architecture** — an AMA extension reporting `Succeeded` here only confirms the extension-layer install succeeded; DCR association health is a separate, AMA-specific concern fully covered in `Azure/Monitor/LogAnalytics-A.md`.
- Related: [Troubleshooting Windows VM extension failures](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/troubleshoot), [Troubleshoot Azure Windows VM Agent issues](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/windows-azure-guest-agent), [How to use boot diagnostics to troubleshoot virtual machines in Azure](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/boot-diagnostics), [Run scripts in a Windows or Linux VM in Azure with Run Command](https://learn.microsoft.com/en-us/azure/virtual-machines/run-command-overview), [VM extension provisioning errors in Virtual Machine Scale Sets](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machine-scale-sets/extensions/vm-extension-provisioning-errors), [Microsoft Antimalware Extension for Windows VMs on Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/iaas-antimalware-windows), [What is IP address 168.63.129.16?](https://learn.microsoft.com/en-us/azure/virtual-network/what-is-ip-address-168-63-129-16)
