# Azure Update Manager — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Azure Update Manager** — the current, native, non-Automation-dependent patch management service for Azure VMs and Azure Arc-enabled servers: on-demand assessment/install, periodic assessment, scheduled patching via maintenance configurations, the extension model, and the guest-OS-side dependencies that account for most real "patching isn't working" tickets.

**Explicitly out of scope, with cross-references:**
- **Azure Automation's legacy Update Management solution** — retired 31 August 2024. It was a completely different architecture (Log Analytics workspace + Automation account + installed MMA/OMS agent). If a client's Automation account still shows an active Update Management solution, that's dead functionality to be decommissioned, not migrated in place — see `Azure/Automation/AzureAutomation-A.md` Scope & Assumptions and Remediation Playbook 4.
- **Automatic VM Guest Patching** (`patchMode: AutomaticByPlatform` without a maintenance configuration attached) and **Hotpatching** — related, adjacent Azure Compute features that patch without Update Manager scheduling. Covered only where they intersect Update Manager's own patch-mode settings (Symptom → Cause Map); not a design guide for either.
- **On-premises WSUS server administration itself** (WSUS server health, GPO deployment, client-side targeting) — Update Manager only consumes whatever a machine's WSUS-pointed Windows Update Agent reports; a broken WSUS server is an Active Directory/WSUS-team problem, not an Update Manager one.
- **Windows Server Update Services (WSUS) product retirement planning** and **Configuration Manager (SCCM/MECM) software update points** — adjacent patching architectures with their own dedicated troubleshooting surfaces, not duplicated here.
- **Azure Arc onboarding and connectivity itself** — a hard prerequisite for Update Manager on non-Azure machines, fully covered in `Azure/Arc/AzureArc-A.md`; this file assumes the Arc agent is already `Connected` and cross-references rather than repeats that layer.

---
## How It Works

<details><summary>Full architecture</summary>

Azure Update Manager is built as **native functionality directly on the Azure VM and Azure Arc-enabled server resource types** — there is no separate service account, no Log Analytics workspace, and no pre-installed agent beyond the Azure VM Agent (already present on every Azure VM) or the Azure Connected Machine agent (already required for any Arc-enabled server, for Sentinel/Defender for Cloud or anything else). This is the single biggest architectural difference from the retired Automation-based Update Management solution, and it's why Update Manager has "zero onboarding" for any machine that's already an Azure VM or already Arc-connected.

**The extension layer.** Update Manager does its actual work through one VM extension per operating system family: `Microsoft.CPlat.Core.WindowsPatchExtension` on Windows, `Microsoft.CPlat.Core.LinuxPatchExtension` on Linux. Critically, **this extension is never pre-installed** — it installs itself automatically the first time any Update Manager operation runs against that machine: a manual **Check for updates**, a manual **Install now**, enabling **Periodic Assessment**, or the first time a scheduled maintenance run fires. A machine that's never had any of those four things happen shows no extension at all, and that is expected behavior, not a fault. For Azure Arc-enabled servers specifically, two extensions get installed instead of one — the OS-specific patch extension plus the underlying Arc agent's own extension-management plumbing — which is why an unhealthy Arc connection breaks Update Manager before Update Manager itself is ever reached.

**The relationship to the guest OS's own update client is the second core architectural fact.** Update Manager does not publish, host, mirror, or curate updates in any way. On Windows, it drives the same **Windows Update Agent (WUA)** APIs that back the **Check for updates** button in Settings — whatever source WUA is configured to use (Windows Update, Microsoft Update, or a local WSUS server) is exactly what Update Manager sees and installs from. On Linux, it drives the distribution's own package manager against whatever repositories (public or private/local) that machine is configured to use. This means Update Manager inherits every pre-existing update-source misconfiguration on a machine — a machine that can't check for updates locally cannot be fixed by Update Manager, because Update Manager is calling the exact same underlying API.

**On-demand vs. periodic vs. scheduled — three distinct operational modes, all built on the same extension:**
- **On-demand assessment/install** (`Invoke-AzVMPatchAssessment` / `Invoke-AzVmInstallPatch`, or the REST `assessPatches`/`installPatches` actions) — a single, synchronous-feeling operation triggered manually or via automation, useful for emergency out-of-band patching or first-time extension bootstrap.
- **Periodic assessment** — an opt-in setting (`AssessmentMode: AutomaticByPlatform`) that has the extension re-check for updates roughly every 24 hours on its own, without installing anything, so compliance data stays fresh between manual checks. This is what feeds the tenant-wide compliance dashboard without requiring anyone to click "Check for updates" repeatedly.
- **Scheduled (recurring) patching** — the production pattern for most MSP fleets: a `Microsoft.Maintenance/maintenanceConfigurations` resource (the schedule: window, recurrence, timezone, which classifications/KBs/packages to install, reboot behavior) combined with a separate `Microsoft.Maintenance/configurationAssignments` resource that links one specific machine (or a dynamic-scope group of machines matched by Azure Policy) to that schedule. **These are two independent resources** — a schedule existing tells you nothing about which machines are actually on it; the assignment is the only source of truth for that, and assignments are explicitly documented as not surviving a resource-group or subscription move automatically.

**Maintenance window arithmetic is a real, non-obvious failure mode worth understanding precisely.** During an install run, Update Manager continuously checks remaining window time before starting each next step. It permanently reserves **10 minutes for reboot on Windows, 15 minutes on Linux**, on top of an average per-update install-time estimate — roughly 10 minutes per non-service-pack Windows update, 15 minutes for a Windows service pack (the combined commonly-cited figures of "25 minutes non-SP / 30 minutes SP" already fold the reboot reservation in). If the time remaining after that arithmetic isn't enough, Update Manager **skips the scan/download/install of the remaining updates entirely** rather than risk cutting off an install mid-flight and leaving the machine in an undetermined state — a deliberate safety choice, not a bug, and it surfaces as `Failed` with `Maintenance window exceeded: true` even though "the window looked long enough" at a glance. An already-started individual update installation is never forcibly killed even if it runs the window over.

**Success/failure semantics are stricter than most engineers assume.** A deployment is marked `Succeeded` only if every selected update installs AND every dependent operation (reboot, final re-assessment) also completes. A single failed update, a reboot that never happens, or a machine that fails to come back up after reboot all mark the whole run `Failed` — not partially successful. A few specific, narrower scenarios are deliberately marked `Completed with warnings` instead of `Failed`: updates required a reboot but **Never reboot** was selected, or (Ubuntu 18 and earlier specifically) ESM packages were skipped because no Ubuntu Pro license was present.

**Data retention is short and easy to be surprised by.** All assessment and install-result data is written to **Azure Resource Graph**, not a long-term log store — pending-update data (`patchassessmentresources` table) retains only **7 days**, and install-result data (`patchinstallationresources` table) retains only **30 days**. A ticket asking "what patched on this machine 6 weeks ago" cannot be answered from Resource Graph at all; that history is simply gone unless it was separately exported (e.g., to a Log Analytics workspace or Storage via Diagnostic Settings, or captured by a workbook snapshot at the time).

</details>

---
## Dependency Stack

```
Layer 7 — Patch installation outcome (Succeeded / Failed / Completed with warnings)
Layer 6 — Maintenance window arithmetic (10-15min reboot reservation + per-update time budget)
              — only relevant for scheduled runs; on-demand installs use -MaximumDuration directly
Layer 5 — Scheduling resources (two independent resources — a schedule existing proves nothing
              about which machines are actually assigned to it)
              ├── Microsoft.Maintenance/maintenanceConfigurations (the schedule/window/content)
              └── Microsoft.Maintenance/configurationAssignments (machine ↔ schedule link —
                    does NOT survive a resource group/subscription move automatically)
Layer 4 — Guest OS update client / package manager
              ├── Windows: WUA source config (Windows Update / Microsoft Update / WSUS)
              └── Linux: distro package manager + repo reachability + sudo/root privilege
Layer 3 — Patch extension health
              (Microsoft.CPlat.Core.WindowsPatchExtension / ...LinuxPatchExtension —
               installs lazily on FIRST use, not pre-provisioned; ProvisioningState must
               be Succeeded)
Layer 2 — AllowExtensionOperations = true on the VM's OSProfile
              (disables ALL extensions on that VM if false — not specific to this one)
Layer 1 — Base compute agent
              ├── Azure VM Agent (Azure VMs — near-universally already present)
              └── Azure Connected Machine agent (Arc-enabled servers — a full
                    prerequisite subsystem of its own; see Azure/Arc/)
Layer 0 — Machine is powered on and RBAC permission exists to act on it
              (Virtual Machine Contributor / Azure Connected Machine Resource
               Administrator, or the granular assessPatches/installPatches actions)
```

A ticket that presents as "patching is broken" is disproportionately actually stuck at Layer 4 (the guest OS's own update client) or Layer 5 (an assignment gap after a VM move) — always rule those out before assuming Update Manager itself has failed, since Update Manager has no ability to originate a failure independent of the layers beneath it.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Machine shows **Not assessed** with a red `HRESULT` exception | Guest OS update agent (WUA on Windows) misconfigured, not an Update Manager fault | Expand the exception text; decode the HRESULT against Microsoft's Windows Update error code list |
| `0x8024402C` / `0x8024401C` / `0x8024402F` | Network connectivity to the update source | Confirm outbound reachability to Windows Update/WSUS endpoints |
| `0x80072EE2` | Can't reach configured WSUS server | Check `WUServer`/`WUStatusServer` registry values, WSUS server availability |
| `0x8024002E` / `0x80070422` | Windows Update service (`wuauserv`) disabled | Enable and start the service |
| `0x80070005` | Access denied — often `SoftwareDistribution` folder permissions or low disk space | Check permissions and free space on the system drive |
| No patch extension present on `Get-AzVMExtension` at all | Update Manager has genuinely never run an operation against this machine yet | Trigger any on-demand operation once — this is expected, not a fault |
| Extension present but `ProvisioningState` stuck `Creating`/`Failed` | Extension deployment itself failed | Remove and let the next operation reinstall it clean |
| Every extension fails to deploy on this VM specifically, not just this one | `AllowExtensionOperations` is `false` on the VM's `OSProfile` | `(Get-AzVM ...).OSProfile.AllowExtensionOperations` |
| Linux: `Extension returned non-zero exit code for Install: 88` / `root is not in the sudoers file` | Sudo privileges not granted to root for extension operations | `sudo visudo` and add `root ALL=(ALL) ALL` |
| Periodic assessment shows non-compliant right after VM creation (specialized/migrated/restored image) | Known modification-policy limitation — assessment settings don't apply correctly at creation time for these VM creation paths | Run an Azure Policy remediation task for the affected resources |
| Scheduled patching never attaches / schedule setting missing after resource creation | Same class of known **Deploy If Not Exists** policy limitation as periodic assessment above | Run a remediation task |
| "Should apply but isn't happening" for a gallery image or encrypted-disk VM under a policy assignment | The policy's managed identity lacks read on the gallery image (historically not part of Virtual Machine Contributor) | Manually grant the managed identity read on the gallery image/disk resource |
| Update history: `Failed`, **Maintenance window exceeded: true** | Reboot reservation + per-update time estimate exceeded the configured window | Widen the maintenance configuration's `Duration` |
| `ShutdownOrUnresponsive` error on a scheduled run | Known limitation: machine deleted and recreated with the same resource ID within the last 8 hours | Wait out the 8-hour window; it self-resolves |
| Patches skipped, machine shown as losing its schedule, machine was off | Machine was shut down at/near the scheduled trigger time | Ensure machines are powered on at least 15 minutes before the scheduled window |
| Scheduled patching stopped after a VM move to another RG/subscription | Configuration assignment doesn't migrate automatically on resource move | Recreate the `configurationAssignment` (static scope) or wait for the next dynamic-scope evaluation cycle |
| Can't change patch orchestration to manual via **Change update settings** | VM is set to `AutomaticByOS`/Windows-automatic-updates orchestration, which blocks that specific change path | Switch to **Customer Managed Schedules (Preview)** (`AutomaticByPlatform` + `ByPassPlatformSafetyChecksOnUserSchedule`) with no schedule attached instead |
| Azure Arc-enabled server never produces assessment data at all | Subscription isn't registered to `Microsoft.Compute` resource provider (yes, even for Arc machines) | `Get-AzResourceProvider -ProviderNamespace Microsoft.Compute` → `RegistrationState` |
| Azure Arc-enabled server: can't patch at all | Windows/Linux OS update extension never triggered/installed, OR the Arc agent connection itself is unhealthy | Confirm Arc `Status: Connected` first (`Azure/Arc/AzureArc-B.md`), then trigger an on-demand operation |

---
## Validation Steps

1. **Confirm the machine layer is healthy before anything Update-Manager-specific.**
   ```powershell
   Get-AzVM -ResourceGroupName <rg> -Name <vmName> -Status
   ```
   Good: `PowerState/running`, VM Agent `Ready`. Bad: stopped, or agent not ready.

2. **Confirm extension operations aren't globally disabled on this VM.**
   ```powershell
   (Get-AzVM -ResourceGroupName <rg> -Name <vmName>).OSProfile.AllowExtensionOperations
   ```
   Good: `$true` or `$null` (default true on most images). Bad: explicit `$false` — no extension of any kind, from any Azure service, can ever install here until this changes (requires a VM redeploy in most cases — this is not a live-toggle setting on an existing VM).

3. **Force a fresh assessment and read the structured result, not the portal tile.**
   ```powershell
   Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vmName>
   ```
   Good: `Succeeded` with a populated patch count. Bad: `Failed` or an exception — decode against the Symptom → Cause Map above.

4. **Confirm the patch extension's own provisioning state, separate from the VM Agent.**
   ```powershell
   Get-AzVMExtension -ResourceGroupName <rg> -VMName <vmName> -Name "WindowsPatchExtension"
   ```
   Good: `Succeeded`. Bad: `Creating` (still deploying, or genuinely stuck) or `Failed`.

5. **Confirm the actual maintenance configuration assignment, not just the schedule's existence.**
   ```powershell
   Get-AzConfigurationAssignment -ResourceGroupName <rg> -ResourceName <vmName> -ResourceType "virtualMachines" -ProviderName "Microsoft.Compute"
   ```
   Good: returns an assignment whose `MaintenanceConfigurationId` matches the expected schedule. Bad: empty result — the schedule may be perfectly healthy and simply never linked to this machine.

6. **For Arc-enabled servers, validate the resource-provider registration and Arc connection before anything else.**
   ```powershell
   Get-AzResourceProvider -ProviderNamespace Microsoft.Compute | Select-Object RegistrationState
   Get-AzConnectedMachine -ResourceGroupName <rg> -Name <machineName> | Select-Object Status, LastStatusChange
   ```
   Good: `Registered`, `Status: Connected`. Bad: either one wrong blocks periodic assessment data from ever generating, regardless of anything else being correct.

7. **Query Resource Graph directly for the authoritative, fleet-wide compliance state rather than clicking through individual VM blades.**
   ```kusto
   patchassessmentresources
   | where type == "microsoft.compute/virtualmachines/patchassessmentresults/softwarepatches"
   | summarize count() by tostring(properties.classifications), tostring(properties.patchName)
   ```
   Good: recognizable patch/classification data within the last 7 days. Bad: empty — either no assessment has run recently, or the 7-day retention window has already lapsed since the last one; re-run an assessment rather than concluding "no data" means "no updates."

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the machine and base agent layer.** Power state, VM Agent readiness (Azure VM) or Arc connection status (Arc-enabled server), and `AllowExtensionOperations`. Nothing above this layer can be diagnosed meaningfully until it's confirmed healthy — this resolves the class of ticket that looks like Update Manager but is actually a more fundamental compute/connectivity problem.

**Phase 2 — Confirm the extension and guest OS update client.** Extension `ProvisioningState`, then whether the underlying WUA/package-manager configuration can succeed locally (would "Check for updates" work if clicked by hand on the machine itself?). If a `HRESULT` exception is present, decode it against the table before guessing further — the code virtually always names the exact subsystem at fault (network, service state, WSUS pointer, permissions).

**Phase 3 — Confirm scheduling resources independently of the machine itself.** The maintenance configuration (the schedule) and the configuration assignment (the machine-to-schedule link) are two separate resources — verify both exist and that the assignment references the correct configuration, especially after any resource-group or subscription move, which is documented to break the assignment silently.

**Phase 4 — Confirm maintenance window sizing if a scheduled run reports failure.** Check the `Maintenance window exceeded` property specifically before assuming a genuine patch failure — this is a timing/sizing issue with a known, deterministic cause (reboot reservation + per-update time budget), not a platform defect.

**Phase 5 — Azure Policy layer (if using policy-driven onboarding/scheduling at scale).** Confirm the subscription is registered for `Microsoft.Compute` (yes, even for Arc-only fleets), and check for the two documented **Deploy If Not Exists** policy limitations affecting specialized/migrated/restored VMs — these require a manual remediation task run, they don't self-heal.

**Phase 6 — Escalate with evidence, not conclusions.** If Phases 1-5 are all clean and the failure persists, this has moved past configuration and needs either a Microsoft support case (a genuine backend/extension platform issue) or deeper log review directly on the machine (`waagent.log`/extension logs on Linux, `WindowsUpdateExtension.log`/`CommandExecution.log` under the extension's plugin folder on Windows). Package the [Evidence Pack](#evidence-pack) output rather than re-describing portal screenshots from memory.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide onboarding to scheduled patching (new client engagement)</summary>

**When to use:** Onboarding a new MSP client whose VM/Arc estate has no consistent patching strategy today (mix of manual, Automation-based legacy Update Management, or nothing at all).

1. Inventory the estate and confirm every machine's base layer is healthy first — `Get-AzVM -Status` for Azure VMs, `Get-AzConnectedMachine` for Arc-enabled servers. Fix any disconnected/stopped machines before proceeding; scheduling on top of an unhealthy base layer just produces silent failures later.
2. Confirm `Microsoft.Maintenance` resource provider is registered on every subscription in scope:
   ```powershell
   Register-AzResourceProvider -ProviderNamespace Microsoft.Maintenance
   ```
3. Create one or more maintenance configurations matching the client's actual change-window agreement (not a default Microsoft example duration):
   ```powershell
   New-AzMaintenanceConfiguration -ResourceGroup <rg> -Name "<configName>" `
     -MaintenanceScope InGuestPatch -Location <region> `
     -StartDateTime "<yyyy-MM-dd HH:mm>" -TimeZone "<e.g. Eastern Standard Time>" `
     -Duration "03:00" -RecurEvery "Week Saturday" `
     -InstallPatchRebootSetting IfRequired `
     -WindowParameterClassificationToInclude Critical,Security,UpdateRollup
   ```
4. Assign machines — prefer **dynamic scope** (Azure Policy-based, matched by tag/resource group/subscription criteria) for fleets that grow over time, so new VMs are picked up automatically; use static per-machine assignment only for a small, stable set.
5. Enable **Periodic Assessment** tenant-wide via the built-in Azure Policy for continuous compliance visibility between scheduled runs, rather than relying solely on the schedule's own pre-run assessment.
6. Validate against a small pilot batch (5-10 machines) for one full cycle before expanding to the whole estate — confirm actual `Succeeded` outcomes in Resource Graph, not just that the schedule fired.

**Rollback:** removing a configuration assignment (`Remove-AzConfigurationAssignment`) or deleting the maintenance configuration itself (`Remove-AzMaintenanceConfiguration`) stops all future scheduled activity immediately with no effect on already-installed patches.

</details>

<details><summary>Playbook 2 — Migrating off Azure Automation's retired Update Management</summary>

**When to use:** Any client Automation account still showing an active legacy Update Management solution (retired 31 August 2024) — flagged as a decommission item, per `Azure/Automation/AzureAutomation-A.md` Remediation Playbook 4.

1. Inventory every machine currently registered against the legacy Update Management solution in the Automation account/Log Analytics workspace.
2. Build the equivalent maintenance configuration(s) in Update Manager first — window, recurrence, classifications — matching the client's existing patching cadence as closely as possible, and validate against a pilot batch before touching production scheduling.
3. Assign the same machines to the new maintenance configuration(s) via `configurationAssignments` (static or dynamic scope).
4. Run both systems in parallel for one full patch cycle if the client's risk tolerance allows it, to compare compliance outcomes before fully cutting over.
5. Remove the legacy solution from the Automation account and Log Analytics workspace only after the new schedule has demonstrated at least one clean cycle — do not decommission the old path first "to be tidy."

**Rollback:** re-enabling the legacy Automation-based solution is not possible once formally retired platform-wide — there is no rollback to the old solution itself, only to a prior working maintenance-configuration definition if the new setup needs adjustment.

</details>

<details><summary>Playbook 3 — Recovering a machine stuck "Not assessed" for weeks</summary>

**When to use:** A specific machine has shown `Not assessed` or a stale compliance state for an extended period, well beyond a single missed cycle.

1. Confirm base layer health first (Validation Steps 1, 6) — a machine that's been powered off, or an Arc agent that's been disconnected, produces exactly this symptom and is not an extension/agent bug.
2. Force a fresh on-demand assessment and capture the exact result, not just pass/fail:
   ```powershell
   Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vmName>
   ```
3. If it fails with an `HRESULT`, resolve the underlying WUA/package-manager issue directly on the machine (see Symptom → Cause Map) — this cannot be fixed from the Azure side.
4. If the extension itself is stuck, remove and let it reinstall clean:
   ```powershell
   Remove-AzVMExtension -ResourceGroupName <rg> -VMName <vmName> -Name "WindowsPatchExtension" -Force
   Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vmName>
   ```
5. Re-check Resource Graph after a short delay to confirm the assessment actually landed — remember the 7-day retention on `patchassessmentresources` means older manual checks may already be gone even if they once succeeded.

**Rollback:** N/A — this playbook is diagnostic-and-repair only; no destructive step is involved.

</details>

<details><summary>Playbook 4 — Fleet-wide MSP audit sweep</summary>

**When to use:** Onboarding a new client's existing VM/Arc estate, or a periodic health sweep across all managed tenants.

1. Run `Scripts/Get-AzureUpdateManagerHealth.ps1` against every subscription in scope.
2. Treat any machine with a missing or unhealthy patch extension as a priority — it means that machine has effectively never been successfully assessed or patched through Update Manager, regardless of what the portal's summary tile might imply.
3. Treat any maintenance configuration with zero assignments as an immediate finding — a schedule that exists but protects nothing is a common and easy-to-miss gap, especially after machine moves or decommissions changed the fleet without anyone updating the assignments.
4. Cross-reference any machine still showing signs of the legacy Automation-based Update Management solution for migration per Playbook 2.
5. Document findings per client rather than remediating live during a discovery sweep — changing maintenance windows or reassigning schedules is disruptive enough to warrant its own scheduled change, not a same-session fix.

**Rollback:** N/A — this playbook is read-only by design; all actual remediation happens via Playbooks 1-3.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Azure Update Manager evidence — extension state, assessment/install history,
    and maintenance configuration assignment — for a single machine, for escalation.
.NOTES
    Read-only. Run with Connect-AzAccount already authenticated against the target subscription.
#>
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$VMName,
    [string]$OutputPath = ".\UpdateManager-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
)

$evidence = [System.Collections.Generic.List[string]]::new()
$evidence.Add("=== Azure Update Manager Evidence Pack — $(Get-Date -Format o) ===")

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
$evidence.Add("`n--- VM Status ---")
$evidence.Add(($vm.Statuses | Select-Object Code, DisplayStatus | Format-Table -AutoSize | Out-String))

$evidence.Add("`n--- Patch Extension ---")
$ext = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName |
    Where-Object { $_.Publisher -like "*CPlat*" -or $_.Name -like "*PatchExtension*" }
$evidence.Add(($ext | Select-Object Name, Publisher, ProvisioningState | Format-Table -AutoSize | Out-String))

$evidence.Add("`n--- On-Demand Assessment (triggered now) ---")
try {
    $assess = Invoke-AzVMPatchAssessment -ResourceGroupName $ResourceGroupName -VMName $VMName
    $evidence.Add(($assess | Format-List | Out-String))
} catch {
    $evidence.Add("Assessment call failed: $($_.Exception.Message)")
}

$evidence.Add("`n--- Maintenance Configuration Assignment ---")
try {
    $assignment = Get-AzConfigurationAssignment -ResourceGroupName $ResourceGroupName -ResourceName $VMName `
        -ResourceType "virtualMachines" -ProviderName "Microsoft.Compute"
    $evidence.Add(($assignment | Format-List | Out-String))
} catch {
    $evidence.Add("No configuration assignment found or query failed: $($_.Exception.Message)")
}

$evidence -join "`n" | Out-File -FilePath $OutputPath -Encoding utf8
Write-Host "Evidence written to $OutputPath"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzVM -ResourceGroupName <rg> -Name <vm> -Status` | Confirm power state and VM Agent readiness |
| `Invoke-AzVMPatchAssessment -ResourceGroupName <rg> -VMName <vm>` | Trigger an on-demand assessment (also bootstraps the extension on first use) |
| `Invoke-AzVmInstallPatch -ResourceGroupName <rg> -VmName <vm> -Windows -RebootSetting IfRequired -MaximumDuration PT2H -ClassificationToIncludeForWindows Critical` | Trigger an on-demand install with an explicit duration |
| `Get-AzVMExtension -ResourceGroupName <rg> -VMName <vm> -Name "WindowsPatchExtension"` | Check patch extension provisioning state |
| `Remove-AzVMExtension -ResourceGroupName <rg> -VMName <vm> -Name "WindowsPatchExtension" -Force` | Force a clean extension reinstall on next operation |
| `(Get-AzVM -ResourceGroupName <rg> -Name <vm>).OSProfile.AllowExtensionOperations` | Confirm extensions aren't globally blocked on this VM |
| `New-AzMaintenanceConfiguration -ResourceGroup <rg> -Name <name> -MaintenanceScope InGuestPatch ...` | Create a recurring patching schedule |
| `Update-AzMaintenanceConfiguration -ResourceGroupName <rg> -Name <name> -Duration "04:00"` | Widen a schedule's maintenance window |
| `New-AzConfigurationAssignment -ResourceGroupName <rg> -ResourceName <vm> -ResourceType VirtualMachines -ProviderName Microsoft.Compute -ConfigurationAssignmentName <name> -MaintenanceConfigurationId <id>` | Link a machine to a schedule |
| `Get-AzConfigurationAssignment -ResourceGroupName <rg> -ResourceName <vm> -ResourceType virtualMachines -ProviderName Microsoft.Compute` | Confirm a machine's actual schedule assignment |
| `Remove-AzConfigurationAssignment -ResourceGroupName <rg> -ResourceName <vm> -ResourceType virtualMachines -ProviderName Microsoft.Compute -ConfigurationAssignmentName <name>` | Unlink a machine from a schedule |
| `Get-AzConnectedMachine -ResourceGroupName <rg> -Name <machine>` | Confirm Arc agent connection status (Arc-enabled servers) |
| `Get-AzResourceProvider -ProviderNamespace Microsoft.Compute` | Confirm resource-provider registration (required even for Arc-only fleets) |
| `Register-AzResourceProvider -ProviderNamespace Microsoft.Maintenance` | Register the Maintenance RP before first-time schedule creation |
| Resource Graph: `patchassessmentresources` / `patchinstallationresources` | Fleet-wide pending-update (7-day) / install-result (30-day) query tables |

---
## 🎓 Learning Pointers

- **Update Manager is architecturally independent of Azure Automation** — no Automation account, no Log Analytics workspace, no pre-installed agent beyond what the VM/Arc machine already needs for basic Azure management. A client migrating off the retired Automation-based Update Management solution is moving to a genuinely different platform, not a version upgrade of the same one. See [What is Azure Update Manager?](https://learn.microsoft.com/en-us/azure/update-manager/overview).
- **The patch extension installs itself lazily on first use — never assume its absence means something is broken.** A brand-new VM or a machine that's simply never had any Update Manager operation run against it will show zero extension until the first Check for updates, Install now, Periodic Assessment enable, or scheduled run fires. See [Prerequisites for Azure Update Manager](https://learn.microsoft.com/en-us/azure/update-manager/prerequisites).
- **A maintenance configuration and a configuration assignment are two separate Azure resources, and only the assignment proves a machine is actually covered.** Assignments are explicitly documented as not surviving a resource-group or subscription move — this is the single most common "the schedule just stopped working" root cause after routine housekeeping. See [How to programmatically manage updates for Azure VMs](https://learn.microsoft.com/en-us/azure/update-manager/manage-vms-programmatically).
- **Ten minutes (Windows) or fifteen minutes (Linux) of every maintenance window are permanently reserved for reboot, and per-update install-time estimates are added on top before Update Manager will even start the next step** — this is precise, deterministic arithmetic, not vague guidance, and it's worth sizing windows against it explicitly rather than copying a default duration from a different client. See [Troubleshoot known issues with Azure Update Manager](https://learn.microsoft.com/en-us/azure/update-manager/troubleshoot).
- **Resource Graph retention for update data is short: 7 days for pending/assessment data, 30 days for install results.** Any client-facing reporting need beyond that window requires a separate export (Diagnostic Settings to a Log Analytics workspace or Storage, or a scheduled Workbook snapshot) set up in advance — this cannot be reconstructed retroactively. See [How Update Manager works](https://learn.microsoft.com/en-us/azure/update-manager/workflow-update-manager).
- **RBAC for Update Manager can be scoped far more granularly than the blanket Virtual Machine Contributor / Azure Connected Machine Resource Administrator roles** — dedicated actions exist for read-only compliance viewing versus triggering on-demand operations versus managing schedules, useful for handing a client's helpdesk read access without granting patch-install rights. See [Roles and permissions in Azure Update Manager](https://learn.microsoft.com/en-us/azure/update-manager/roles-permissions).
- **On Linux, the extension always runs as root via sudo — there is no lower-privilege mode.** A hardened sudoers baseline that excludes root is a common, silent, total blocker that looks identical to a network or repository problem until the specific exit-code-88 sudoers error is read directly. See [Prerequisites for Azure Update Manager](https://learn.microsoft.com/en-us/azure/update-manager/prerequisites).
