# Azure Backup (Recovery Services Vault) — Hotfix Runbook (Mode B: Ops)
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

Run these from an admin workstation with the `Az.RecoveryServices` module, after setting vault context.

```powershell
# 0. Set vault context (required before any other Az.RecoveryServices cmdlet)
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "<rg>" -Name "<vaultName>"
Set-AzRecoveryServicesVaultContext -Vault $vault

# 1. Any backup jobs currently Failed or InProgress-stuck?
Get-AzRecoveryServicesBackupJob -Status Failed -From (Get-Date).AddDays(-2)

# 2. Is the target VM actually protected (not orphaned/unregistered)?
Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM |
    Where-Object { $_.Name -like "*<vmName>*" } |
    Select-Object Name, ProtectionStatus, LastBackupStatus, LastBackupTime

# 3. Is the Azure VM Agent / Backup extension healthy on the VM?
Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status |
    Select-Object -ExpandProperty Statuses

# 4. Is the VM actually running (not deallocated/failed provisioning state)?
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status).Statuses |
    Where-Object Code -like "PowerState/*"

# 5. Latest recovery point available for restore?
Get-AzRecoveryServicesBackupRecoveryPoint -Item $backupItem | Select-Object -First 3 RecoveryPointTime, RecoveryPointType
```

**Interpretation:**

| Finding | Action |
|---|---|
| Job shows `UserErrorGuestAgentStatusUnavailable` | Fix 1 — VM Agent heartbeat missing |
| Job shows `ExtensionOperationTimeout` / extension not installed | Fix 2 — Backup extension missing or corrupt |
| Job shows `UserErrorBackupOperationInProgress` | Fix 3 — concurrent job collision, wait or cancel |
| Job shows `UserErrorVmNotInProperState` | Fix 4 — VM in a transient/failed state, stabilize first |
| `ProtectionStatus` = `ProtectionStopped` or item missing entirely | Fix 5 — protection was stopped or container needs re-registration |
| Job shows `UserErrorRestrictedAppsOrFeatureBlocking` / VSS writer error | Fix 6 — application-consistent snapshot (VSS) failure |
| Everything green but restore is what's needed | See [Escalation Evidence](#escalation-evidence) → gather recovery point list, use restore flow (out of scope for hotfix — portal or `Restore-AzRecoveryServicesBackupItem`) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Recovery Services Vault (RSV)
    │
    ├── Backup Policy (schedule + retention) applied to the VM
    │
    ▼
VM registered as a Backup Item (container) in the vault
    │
    ▼
Azure VM Agent running + heartbeat current (guest-level prerequisite)
    │
    ▼
Azure Backup VM Extension installed and registered
    │  (Windows: VSS-based app-consistent snapshot orchestration)
    │  (Linux: pre/post scripts + fsfreeze for app/file-system consistency)
    │
    ▼
VM in a stable power/provisioning state (Running, or Stopped-Deallocated is allowed
    but produces only crash-consistent/offline snapshots — no VSS pass)
    │
    ▼
Storage-level snapshot triggered (instant recovery point, retained locally ~1-5 days)
    │
    ▼
Snapshot data transferred/tiered to vault storage (incremental after first full backup)
    │
    ▼
Recovery point available for restore (subject to policy retention + soft-delete state)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the backup job's actual failure reason**
```powershell
$job = Get-AzRecoveryServicesBackupJob -Status Failed -From (Get-Date).AddDays(-2) | Select-Object -First 1
Get-AzRecoveryServicesBackupJobDetail -Job $job
```
Expected: `ErrorDetails` on the job object gives a specific error code (not just "Failed"). Match the code against the table above — guessing without the code wastes time.

**Step 2 — Confirm VM Agent heartbeat**
```powershell
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status).VMAgent.Statuses
```
Expected: `DisplayStatus = "Ready"` and a recent timestamp. If missing or stale (>15 min), the guest agent is unresponsive — Azure Backup cannot orchestrate an app-consistent snapshot without it.

**Step 3 — Confirm the Backup extension is installed and healthy**
```powershell
Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" |
    Where-Object { $_.Publisher -like "*Backup*" -or $_.ExtensionType -like "*BackupExtension*" } |
    Select-Object Name, ProvisioningState
```
Expected: `ProvisioningState = "Succeeded"`. `Failed` or missing entirely means the extension needs reinstall (Fix 2).

**Step 4 — Confirm no overlapping job is holding the lock**
```powershell
Get-AzRecoveryServicesBackupJob -Status InProgress |
    Where-Object { $_.WorkloadName -eq "<vmName>" }
```
Only one backup job can run per protected item at a time — a stuck `InProgress` job blocks every subsequent scheduled run silently until it times out (can take hours).

**Step 5 — Confirm protection state and container registration**
```powershell
Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -Status Registered |
    Where-Object { $_.FriendlyName -eq "<vmName>" }
```
Expected: container present with `Status = Registered`. If absent, the VM was likely removed/re-created with the same name and needs re-protection, not just a retry.

**Step 6 — Confirm recovery point freshness (if a restore is what's actually needed)**
```powershell
$backupItem = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM |
    Where-Object { $_.Name -like "*<vmName>*" }
Get-AzRecoveryServicesBackupRecoveryPoint -Item $backupItem | Select-Object -First 5 RecoveryPointTime, RecoveryPointType
```
`RecoveryPointType = AppConsistent` is the highest quality (VSS-quiesced); `CrashConsistent` recovery points come from Stopped-Deallocated VMs or a failed VSS pass and may have unflushed disk writes on restore.

---
## Common Fix Paths

<details><summary>Fix 1 — VM Agent heartbeat missing (UserErrorGuestAgentStatusUnavailable)</summary>

```powershell
# Confirm the VM Agent service state from inside the guest (via Run Command — no RDP/SSH needed)
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -VMName "<vmName>" `
    -CommandId 'RunPowerShellScript' -ScriptPath ".\Check-VMAgent.ps1"
# (script body on the target: Get-Service WindowsAzureGuestAgent | Select Status)

# If the service is stopped, restart it via Run Command:
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -VMName "<vmName>" `
    -CommandId 'RunPowerShellScript' `
    -ScriptString 'Restart-Service WindowsAzureGuestAgent -Force'

# Linux equivalent — check waagent:
# Invoke-AzVMRunCommand ... -CommandId 'RunShellScript' -ScriptString 'systemctl status walinuxagent'
```

**Rollback:** none needed — this only restarts a service.

</details>

<details><summary>Fix 2 — Backup extension missing/corrupt (ExtensionOperationTimeout)</summary>

```powershell
# Remove the stuck/failed extension
Remove-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Name "AzureBackupWindowsWorkload" -Force

# Trigger an on-demand backup — Azure Backup reinstalls the extension automatically as part of the job
Backup-AzRecoveryServicesBackupItem -Item $backupItem
```

**Rollback:** none — extension reinstall is self-healing and non-destructive to existing recovery points.

</details>

<details><summary>Fix 3 — Concurrent job collision (UserErrorBackupOperationInProgress)</summary>

```powershell
# Identify the stuck job
$stuckJob = Get-AzRecoveryServicesBackupJob -Status InProgress | Where-Object { $_.WorkloadName -eq "<vmName>" }

# Jobs running past their expected window (Azure VM backup typically completes in under a few hours
# for normal-sized disks) can be cancelled if genuinely stuck:
Stop-AzRecoveryServicesBackupJob -Job $stuckJob

# Then re-trigger on demand
Backup-AzRecoveryServicesBackupItem -Item $backupItem
```

**Rollback:** cancelling an in-progress job does not affect previously completed recovery points. A cancelled job simply means that specific increment didn't complete — the next scheduled/on-demand run picks up normally.

</details>

<details><summary>Fix 4 — VM in a transient/failed state (UserErrorVmNotInProperState)</summary>

```powershell
# Check current provisioning + power state
Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status |
    Select-Object -ExpandProperty Statuses

# If stuck in "Updating" or "Failed" provisioning state, a redeploy (moves the VM to a new host,
# preserves disks) often clears it:
# Stop-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Force
# (from portal: VM blade > Support + troubleshooting > Redeploy)

# Once the VM shows PowerState/running and ProvisioningState/succeeded, retry backup:
Backup-AzRecoveryServicesBackupItem -Item $backupItem
```

**Rollback:** redeploy is disruptive (brief downtime, ephemeral disk data on the temp disk is lost) — confirm with the client/change process before redeploying a production VM solely to fix backups.

</details>

<details><summary>Fix 5 — Protection stopped or container not registered</summary>

```powershell
# Check current protection status
$backupItem = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM |
    Where-Object { $_.Name -like "*<vmName>*" }
$backupItem.ProtectionStatus   # ProtectionStopped means retention continues but no new backups run

# Re-enable protection using the existing policy (does NOT lose prior recovery points if soft-delete
# retention window hasn't expired)
$policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name "<policyName>"
Enable-AzRecoveryServicesBackupProtection -ResourceGroupName "<rg>" -Name "<vmName>" -Policy $policy

# If the VM was deleted and recreated with the same name, the OLD backup item shows as "orphaned" —
# it must be protected as a NEW item; the old item's recovery points remain separately restorable
# under its original (now-stale) container until retention expires.
```

**Rollback:** re-enabling protection is additive and non-destructive — it does not delete or alter existing recovery points.

</details>

<details><summary>Fix 6 — Application-consistent snapshot failure (VSS writer error)</summary>

```powershell
# From inside the guest (Run Command) — identify the failing VSS writer
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -VMName "<vmName>" `
    -CommandId 'RunPowerShellScript' -ScriptString 'vssadmin list writers'

# A writer in "Failed" or "Retryable error" state blocks app-consistent snapshots but Azure Backup
# will typically fall back to a crash-consistent (or file-system-consistent) recovery point rather
# than failing the job outright — confirm which type actually landed:
Get-AzRecoveryServicesBackupRecoveryPoint -Item $backupItem | Select-Object -First 1 RecoveryPointType

# Common fix: restart the specific failing writer's service (e.g. SQL VSS Writer, IIS Admin) via
# Run Command, or restart the VSS service itself as a broader (more disruptive) fix:
Invoke-AzVMRunCommand -ResourceGroupName "<rg>" -VMName "<vmName>" `
    -CommandId 'RunPowerShellScript' -ScriptString 'Restart-Service VSS -Force'
```

**Rollback:** restarting VSS/a writer service is low-risk but can briefly interrupt the associated workload (e.g. a SQL VSS writer restart is safe; restarting the VSS service itself can affect any other VSS-aware process running concurrently) — schedule outside business hours for production database VMs where possible.

</details>

---
## Escalation Evidence

```
=== Azure Backup Escalation Pack ===
Date/Time:                 _______________
Recovery Services Vault:   _______________
Resource Group:            _______________
VM Name:                   _______________
Subscription:               _______________

Job ID:                    _______________
Job Status:                Failed / InProgress-stuck / Completed with warnings
Error Code:                _______________ (e.g. UserErrorGuestAgentStatusUnavailable)

VM Agent heartbeat:        Ready / Stale / Missing
Backup extension state:    Succeeded / Failed / Not Installed
Protection status:         Protected / ProtectionStopped / Not Registered
Last successful backup:    _______________
Latest recovery point type: AppConsistent / CrashConsistent / FileSystemConsistent

Actions taken so far:
1.
2.
3.

Escalation contact: Microsoft Support via Azure Portal > Recovery Services Vault > Support + troubleshooting > New Support Request
Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-troubleshoot
```

---
## 🎓 Learning Pointers

- **One job at a time, per item — and it's not obvious from the portal.** Azure Backup serializes backup jobs per protected item. A stuck `InProgress` job silently blocks every subsequent scheduled run until it times out, which can take hours — always check for a stuck job before assuming the schedule itself is broken. See [Azure Backup troubleshooting guide](https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-troubleshoot).
- **Crash-consistent vs app-consistent is a real data-integrity distinction, not just metadata.** A crash-consistent recovery point (from a Stopped-Deallocated VM, or a failed VSS pass) may restore with unflushed writes for database workloads — always check `RecoveryPointType` before recommending a restore point for a SQL/Exchange VM. See [Backup and restore consistency](https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-introduction#vm-app-consistent-backup).
- **Soft delete is on by default and changes the "deleted item" recovery story.** A protected item stopped with "Delete Backup Data" doesn't immediately purge — it enters a 14-day soft-delete state and can be un-deleted (`Undo-AzRecoveryServicesBackupItemDeletion`) within that window before the client's data is truly gone. See [Soft delete for Azure Backup](https://learn.microsoft.com/en-us/azure/backup/backup-azure-security-feature-cloud).
- **The VM's guest agent is a hard dependency most engineers forget.** Azure Backup for VMs isn't purely an infrastructure-level snapshot — it needs the guest agent alive to orchestrate VSS (Windows) or run pre/post freeze scripts (Linux). A VM with a hung or uninstalled agent will fail backups even though the disks themselves are perfectly healthy.
