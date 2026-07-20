# Azure Backup (Recovery Services Vault) — Reference Runbook (Mode A: Deep Dive)
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

| Item | Detail |
|------|--------|
| Product | Azure Backup for Azure VMs, via Recovery Services Vault (RSV) |
| Applies to | IaaS Azure VMs (Windows and Linux), managed disks |
| Backup model | Agentless, snapshot-based (Azure Backup VM extension orchestrates guest-level consistency) |
| Out of scope | Azure Site Recovery (ASR) — shares the vault construct but is a distinct DR/replication service with its own Mobility Service agent and RPO model; on-premises/MARS agent backup (files/folders, not full VM); SQL/SAP HANA workload backup within Azure Backup (separate protection intent, different cmdlets) |
| Related | `M365/Backup/` covers SaaS data protection (Exchange/SharePoint/OneDrive mailbox and file backup) — a completely different service and threat model from infrastructure-level VM backup covered here |

---
## How It Works

<details><summary>Full architecture</summary>

Azure Backup for VMs is **agentless from an infrastructure standpoint** — there's no separate backup server or process server to manage (unlike on-prem backup products or ASR for non-Azure sources). Protection is orchestrated entirely by the Azure Backup service against the Recovery Services Vault, using two guest-level touchpoints:

1. **Azure VM Agent** (already present on most Azure VM images) — provides the channel for the Backup extension to run inside the guest.
2. **Azure Backup VM Extension** — installed automatically on first protection. On Windows, it orchestrates a VSS-based application-consistent snapshot (freezes writers, takes the snapshot, thaws). On Linux, it runs configurable pre/post scripts (default: `fsfreeze` for file-system consistency; app-consistent requires custom scripts per workload).

**Backup flow (each scheduled/on-demand run):**

```
Backup job triggered (schedule from policy, or on-demand)
    │
    ▼
Azure Backup service instructs the Backup extension inside the guest to prepare
    │  Windows: VSS snapshot request → writers quiesce → storage-level snapshot taken
    │  Linux:   pre-script runs (default fsfreeze) → snapshot taken → post-script runs (thaw)
    │
    ▼
Storage-level snapshot of all attached managed disks (OS + data disks), taken atomically
    │
    ▼
Snapshot retained locally as an "Instant Recovery Point" (fast restore path, ~1-5 days per policy)
    │
    ▼
Snapshot data copied/transferred to the vault (Recovery Services vault storage — GRS by default)
    │  First backup: full copy. Subsequent backups: incremental (block-level changes only)
    │
    ▼
Recovery point becomes a long-term restorable point per the policy's retention schedule
    (daily / weekly / monthly / yearly retention rules, each independently configurable)
```

**Recovery point consistency levels** (in order of preference for restore):
- `AppConsistent` — VSS-quiesced (Windows) or custom app-aware scripts (Linux). Safe for databases/transactional workloads.
- `FileSystemConsistent` — file system quiesced but application buffers not flushed (Linux default without custom scripts).
- `CrashConsistent` — equivalent to a power-loss snapshot. Occurs when the VM is Stopped-Deallocated at backup time, or when the app-consistent pass fails and the service falls back rather than failing the job outright.

**Instant Recovery Points vs vault-tier recovery points:**
The first few days of recovery points live as storage snapshots directly attached to the source region ("Instant Recovery Point" / snapshot tier) — these restore fastest because no data needs to be pulled from vault storage. Older recovery points (per retention policy) exist only in vault storage and take longer to restore since data is rehydrated from the vault.

**Soft delete:**
Enabled by default on all vaults created after a certain platform version. When a protected item is deleted (or a VM is deleted while still protected), the backup data isn't purged immediately — it moves to a soft-deleted state for **14 days**, recoverable via `Undo-AzRecoveryServicesBackupItemDeletion`. This is a safety net against accidental or malicious deletion (including a compromised admin account), not a retention feature — do not rely on it as a substitute for correctly configured policy retention.

</details>

---
## Dependency Stack

```
Recovery Services Vault (RSV)
    │  ├── Storage redundancy: LRS / GRS / ZRS (GRS default; required for Cross-Region Restore)
    │  ├── RBAC: Backup Contributor / Backup Operator / Backup Reader (vault-scoped roles)
    │  └── Soft delete: enabled by default, 14-day recovery window for deleted items
    │
    └── Backup Policy (schedule + retention, one policy can protect many VMs)
         │
         └── Protected Item (Backup Item) — one per VM, tracks protection + job history
              │
              └── Backup Container — registration record binding the vault to the VM resource
                   │
                   └── Guest-level prerequisites (evaluated fresh on every job run)
                        ├── Azure VM Agent — installed + heartbeat current
                        └── Azure Backup VM Extension — installed + ProvisioningState Succeeded
                             │
                             └── VM power/provisioning state
                                  ├── Running → eligible for AppConsistent (VSS/scripts run)
                                  └── Stopped-Deallocated → CrashConsistent only (no VSS pass)
                                       │
                                       └── Managed disk snapshot (atomic across all attached disks)
                                            │
                                            └── Instant Recovery Point (local snapshot, fast restore)
                                                 │
                                                 └── Transfer to vault storage (incremental after first)
                                                      │
                                                      └── Recovery point retained per policy schedule
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Job fails: `UserErrorGuestAgentStatusUnavailable` | VM Agent not running or heartbeat stale | `(Get-AzVM ... -Status).VMAgent.Statuses` |
| Job fails: `ExtensionOperationTimeout` | Backup extension not installed/corrupt, or guest under heavy load | `Get-AzVMExtension` ProvisioningState |
| Job fails: `UserErrorBackupOperationInProgress` | A prior job for the same item is still running/stuck | `Get-AzRecoveryServicesBackupJob -Status InProgress` |
| Job fails: `UserErrorVmNotInProperState` | VM in Updating/Failed provisioning state | `Get-AzVM -Status` ProvisioningState |
| Job succeeds but recovery point is `CrashConsistent` unexpectedly | VM was Stopped-Deallocated at backup time, or VSS writer failed silently | `Get-AzRecoveryServicesBackupRecoveryPoint` RecoveryPointType |
| Backup item shows `ProtectionStopped` | Protection manually disabled, or VM deleted/recreated | `Get-AzRecoveryServicesBackupItem` ProtectionStatus |
| Item missing from backup item list entirely | Container never registered, or vault context not set in session | `Set-AzRecoveryServicesVaultContext`, `Get-AzRecoveryServicesBackupContainer` |
| Restore fails: point not found | Recovery point aged out of instant-tier and vault transfer hadn't completed, or soft-delete purged it | `Get-AzRecoveryServicesBackupRecoveryPoint` full list + soft-delete item check |
| Cross-Region Restore option greyed out | Vault storage redundancy is LRS/ZRS, not GRS | `Get-AzRecoveryServicesVaultProperty` |
| Cannot delete vault | Vault still has registered/protected items, or soft-deleted items pending | `Get-AzRecoveryServicesBackupItem` across all containers; must un-protect + wait out soft delete |
| Backup succeeds but restore is unexpectedly slow | Restoring from vault-tier (not instant/snapshot-tier) recovery point — data rehydration required | Check which tier the selected recovery point lives in |

---
## Validation Steps

**1 — Confirm vault configuration and redundancy**
```powershell
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "<rg>" -Name "<vaultName>"
Get-AzRecoveryServicesVaultProperty -VaultId $vault.ID | Select-Object -ExpandProperty RedundancySettings
```
Bad: `StorageType = LocallyRedundant` when the client expects Cross-Region Restore capability — GRS is required for CRR, and changing redundancy after vault creation with existing items has restrictions.

**2 — Confirm the backup policy's retention actually matches the client's requirement**
```powershell
Set-AzRecoveryServicesVaultContext -Vault $vault
Get-AzRecoveryServicesBackupProtectionPolicy -Name "<policyName>" |
    Select-Object -ExpandProperty RetentionPolicy
```
Compare `DailySchedule`, `WeeklySchedule`, `MonthlySchedule`, `YearlySchedule` retention durations against the documented SLA/contract — a common audit finding is a policy silently retaining far less than promised.

**3 — Confirm protection status for every VM that should be covered**
```powershell
Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM |
    Select-Object Name, ProtectionStatus, LastBackupStatus, LastBackupTime |
    Sort-Object LastBackupTime
```
Bad: any VM the client expects to be protected missing from this list entirely, or `LastBackupTime` older than one retention cycle.

**4 — Confirm the Backup extension across the fleet (bulk check)**
```powershell
Get-AzVM | ForEach-Object {
    $ext = Get-AzVMExtension -ResourceGroupName $_.ResourceGroupName -VMName $_.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.ExtensionType -like "*BackupExtension*" }
    [PSCustomObject]@{ VM = $_.Name; ExtensionState = if ($ext) { $ext.ProvisioningState } else { "NotInstalled" } }
}
```
Bad: `NotInstalled` on a VM that shows as "Protected" in the vault — indicates the extension was removed post-protection (common after an OS-level cleanup script strips extensions) and the next job will fail.

**5 — Confirm soft-deleted items aren't silently consuming retention/cost**
```powershell
Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -DeleteState "ToBeDeleted"
```
Any results here are in the 14-day soft-delete window — confirm whether each was an intentional decommission or needs `Undo-AzRecoveryServicesBackupItemDeletion`.

**6 — Confirm RBAC is scoped correctly (not over-broad)**
```powershell
Get-AzRoleAssignment -Scope $vault.ID | Select-Object DisplayName, RoleDefinitionName
```
Expected: engineers who should only trigger restores have `Backup Operator`, not `Backup Contributor` (which can modify/delete policies and stop protection with data deletion).

---
## Troubleshooting Steps (by phase)

### Phase 1 — Backup Job Failures
1. Pull the specific error code via `Get-AzRecoveryServicesBackupJobDetail` — never troubleshoot from "Failed" alone.
2. Check guest-level health first (VM Agent heartbeat, extension provisioning state) — the majority of real-world failures are guest-side, not vault-side.
3. Check for a stuck/overlapping `InProgress` job before assuming the schedule is broken.
4. If the error is VSS-related, isolate to a specific writer (`vssadmin list writers` via Run Command) rather than broadly restarting services — for the full writer/provider architecture, shadow storage exhaustion, and SQL Server writer isolation (SQLWRITER/SQLVDI), see `Windows/Troubleshooting/VSS-A.md`/`VSS-B.md`.

### Phase 2 — Protection/Coverage Gaps
1. Compare the full VM inventory (`Get-AzVM`) against protected items (`Get-AzRecoveryServicesBackupItem`) to find unprotected VMs — this drift happens silently when new VMs are provisioned outside the standard deployment process.
2. Check for orphaned containers (VM deleted but backup item still shows, now in a stopped/orphaned state) versus genuinely unprotected VMs — these require different remediation (re-protect a live VM vs. clean up a stale record).
3. Verify the policy assigned to each VM matches intended retention — policies can be reassigned individually and drift from the client's original agreement over time.

### Phase 3 — Restore Failures or Slow Restores
1. Identify which tier the target recovery point lives in (instant/snapshot vs vault storage) — this alone often explains "restore is taking hours."
2. For Cross-Region Restore requests, confirm vault redundancy is GRS and that CRR was enabled on the vault (it's an explicit toggle, not automatic with GRS).
3. If a specific recovery point is missing from the list, check the soft-delete state before assuming data loss — deleted *items* go to soft delete, but individual recovery points aging out of retention are pruned per policy and are not recoverable via soft delete.

### Phase 4 — Vault-Level Issues (deletion blocked, RBAC, cost)
1. A vault cannot be deleted while it has registered containers or soft-deleted items — enumerate both before attempting cleanup.
2. Review Backup Reporting (Azure Monitor workbook, if configured) for cost trends — vault-tier storage cost scales with retained recovery point volume, and overly aggressive retention policies are a common unexpected-bill root cause.
3. Confirm immutability settings (if the client has compliance requirements) — once a vault is made immutable and the 14-day grace period expires, the setting cannot be reversed; this is a one-way door worth flagging explicitly before enabling.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Recover a soft-deleted backup item</summary>

```powershell
Set-AzRecoveryServicesVaultContext -Vault $vault

# List soft-deleted items
$deletedItem = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM `
    -DeleteState "ToBeDeleted" | Where-Object { $_.Name -like "*<vmName>*" }

# Undelete — restores the item to a protectable state with all prior recovery points intact
Undo-AzRecoveryServicesBackupItemDeletion -Item $deletedItem -Force

# Re-confirm protection is active after undelete
Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM |
    Where-Object { $_.Name -like "*<vmName>*" } | Select-Object ProtectionStatus
```

**Rollback:** none needed — this is itself the recovery action. Must be done within the 14-day soft-delete window; after that, data is unrecoverable even by Microsoft Support.

</details>

<details><summary>Playbook 2 — Restore a VM to a new location (disaster recovery from backup, not ASR)</summary>

```powershell
$backupItem = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM |
    Where-Object { $_.Name -like "*<vmName>*" }

$rp = Get-AzRecoveryServicesBackupRecoveryPoint -Item $backupItem |
    Where-Object { $_.RecoveryPointType -eq "AppConsistent" } | Select-Object -First 1

# Restore as a new VM (does not touch the original if it still exists)
Restore-AzRecoveryServicesBackupItem -RecoveryPoint $rp `
    -StorageAccountName "<restoreStagingStorageAccount>" -StorageAccountResourceGroupName "<rg>" `
    -TargetResourceGroupName "<targetRg>" -TargetVNetName "<vnet>" -TargetVNetResourceGroup "<rg>" `
    -TargetSubnetName "<subnet>"

# Monitor the restore job
Get-AzRecoveryServicesBackupJob -Status InProgress | Where-Object { $_.Operation -eq "Restore" }
```

**Rollback:** a restore creates a *new* set of disks/VM resources — it does not overwrite the source. Clean-up (if the restore was for testing only) means deleting the restored resources, not "reverting" anything.

</details>

<details><summary>Playbook 3 — Bulk-remediate VMs with a missing/corrupt Backup extension across a fleet</summary>

```powershell
$affected = Get-AzVM | ForEach-Object {
    $ext = Get-AzVMExtension -ResourceGroupName $_.ResourceGroupName -VMName $_.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.ExtensionType -like "*BackupExtension*" }
    if (-not $ext -or $ext.ProvisioningState -ne "Succeeded") { $_ }
}

foreach ($vm in $affected) {
    Write-Host "Remediating $($vm.Name)..."
    Remove-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name `
        -Name "AzureBackupWindowsWorkload" -Force -ErrorAction SilentlyContinue
    $item = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM |
        Where-Object { $_.Name -like "*$($vm.Name)*" }
    if ($item) { Backup-AzRecoveryServicesBackupItem -Item $item }
}
```

**Rollback:** extension removal/reinstall does not affect existing recovery points; safe to run broadly, but stagger across a large fleet to avoid triggering many simultaneous on-demand jobs (vault-level job throttling can queue rather than fail, but it's cleaner to batch).

</details>

<details><summary>Playbook 4 — Enable vault immutability (compliance requirement) — explicit one-way-door warning</summary>

```powershell
# Set to "Unlocked" first (reversible, 14-day compliance-relevant grace period applies once Locked)
Set-AzRecoveryServicesVaultProperty -VaultId $vault.ID -ImmutabilityState "Unlocked"

# Only after client sign-off, and understanding this becomes irreversible:
# Set-AzRecoveryServicesVaultProperty -VaultId $vault.ID -ImmutabilityState "Locked"
```

**Rollback:** `Unlocked` state CAN be reverted or set to `Locked`. **`Locked` state CANNOT be reverted, ever** — this is a deliberate Microsoft design for ransomware/compliance protection. Never set `Locked` without explicit, documented client approval; treat this identically to the regulatory-record irreversibility warning in `Security/Purview/RetentionLabels-A.md`.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Azure Backup (RSV) Evidence Collector — gathers diagnostic data for escalation
.NOTES     Run from an admin workstation with Az.RecoveryServices, Az.Compute modules.
#>

param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$VaultName,
    [string]$VMName
)

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("=== Azure Backup Evidence Pack - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===`n")

try {
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName
    Set-AzRecoveryServicesVaultContext -Vault $vault
    $redundancy = Get-AzRecoveryServicesVaultProperty -VaultId $vault.ID
    $report.Add("Vault: $($vault.Name) | Redundancy: $($redundancy.RedundancySettings.StorageType)")
} catch { $report.Add("ERROR reading vault: $_") }

try {
    $items = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM
    if ($VMName) { $items = $items | Where-Object { $_.Name -like "*$VMName*" } }
    $report.Add("`nProtected Items: $($items.Count)")
    foreach ($i in $items) {
        $report.Add("  $($i.Name) | Status: $($i.ProtectionStatus) | LastBackup: $($i.LastBackupStatus) @ $($i.LastBackupTime)")
    }
} catch { $report.Add("ERROR reading backup items: $_") }

try {
    $failedJobs = Get-AzRecoveryServicesBackupJob -Status Failed -From (Get-Date).AddDays(-7)
    $report.Add("`nFailed Jobs (last 7 days): $($failedJobs.Count)")
    foreach ($j in $failedJobs) {
        $report.Add("  $($j.WorkloadName) | $($j.Operation) | $($j.StartTime) | ErrorDetails: $($j.ErrorDetails -join '; ')")
    }
} catch { $report.Add("ERROR reading failed jobs: $_") }

if ($VMName) {
    try {
        $ext = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue |
            Where-Object { $_.ExtensionType -like "*BackupExtension*" }
        $report.Add("`nBackup Extension on $VMName : $(if ($ext) { $ext.ProvisioningState } else { 'NOT INSTALLED' })")
        $agentStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status).VMAgent.Statuses
        $report.Add("VM Agent: $($agentStatus.DisplayStatus -join ', ')")
    } catch { $report.Add("ERROR reading VM extension/agent: $_") }
}

try {
    $deleted = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -DeleteState "ToBeDeleted"
    $report.Add("`nSoft-deleted items pending: $($deleted.Count)")
} catch { $report.Add("ERROR reading soft-delete state: $_") }

$outPath = "$env:TEMP\AzureBackup-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$report | Out-File $outPath -Encoding UTF8
Write-Host "Evidence saved to: $outPath" -ForegroundColor Green
$outPath
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Set vault context (required first) | `Set-AzRecoveryServicesVaultContext -Vault $vault` |
| List failed jobs | `Get-AzRecoveryServicesBackupJob -Status Failed -From <date>` |
| Get job error detail | `Get-AzRecoveryServicesBackupJobDetail -Job $job` |
| List protected items | `Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM` |
| Trigger on-demand backup | `Backup-AzRecoveryServicesBackupItem -Item $item` |
| List recovery points | `Get-AzRecoveryServicesBackupRecoveryPoint -Item $item` |
| Restore to new VM | `Restore-AzRecoveryServicesBackupItem -RecoveryPoint $rp ...` |
| Enable protection | `Enable-AzRecoveryServicesBackupProtection -Policy $policy -Name <vm> -ResourceGroupName <rg>` |
| Stop protection (retain data) | `Disable-AzRecoveryServicesBackupProtection -Item $item` |
| Stop protection (delete data) | `Disable-AzRecoveryServicesBackupProtection -Item $item -RemoveRecoveryPoints` |
| List soft-deleted items | `Get-AzRecoveryServicesBackupItem ... -DeleteState "ToBeDeleted"` |
| Undelete soft-deleted item | `Undo-AzRecoveryServicesBackupItemDeletion -Item $item` |
| Check vault redundancy | `Get-AzRecoveryServicesVaultProperty -VaultId $vault.ID` |
| Check Backup extension state | `Get-AzVMExtension \| Where ExtensionType -like "*BackupExtension*"` |
| Check VM Agent heartbeat | `(Get-AzVM -Status).VMAgent.Statuses` |

---
## 🎓 Learning Pointers

- **Azure Backup for VMs is agentless at the infrastructure layer but not at the guest layer.** There's no process server or backup server to patch (unlike ASR or on-prem products), but the Azure VM Agent and Backup extension inside the guest are still hard dependencies — a hung guest agent fails backups even on perfectly healthy storage. See [Azure VM backup architecture](https://learn.microsoft.com/en-us/azure/backup/backup-architecture).
- **Instant Recovery Points vs. vault-tier recovery points explain most "slow restore" complaints.** Recent recovery points live as attached snapshots (fast restore); older ones live only in vault storage and must be rehydrated. This tiering is automatic per policy and isn't obvious from the portal UI unless you specifically check recovery point age. See [Instant Restore](https://learn.microsoft.com/en-us/azure/backup/backup-instant-restore-capability).
- **Soft delete protects against deletion, not against retention expiry.** A 14-day soft-delete window recovers accidentally (or maliciously) deleted *protected items* — it does not extend the retention of individual recovery points that age out per the policy's own schedule. Don't conflate the two when setting client expectations. See [Soft delete overview](https://learn.microsoft.com/en-us/azure/backup/backup-azure-security-feature-cloud).
- **Immutable vaults are a genuine one-way door.** Once `Locked`, immutability cannot be reversed by anyone, including Microsoft Support — treat this with the same caution as regulatory records in Purview retention labels ([[project_ezadmin]] pattern: always flag irreversible compliance actions explicitly before executing).
- **CrashConsistent recovery points are not automatically "bad" — but they need to be flagged for database workloads.** A crash-consistent point from a Stopped-Deallocated VM is fine for a stateless web server; recommending it for a SQL Server VM without disclosing the consistency level is a real risk the client should knowingly accept, not discover after a restore.
- **This is a distinct service from `M365/Backup/` — don't conflate the two in client conversations.** Azure Backup protects infrastructure (VM disks); M365 Backup (third-party or native) protects SaaS mailbox/file data. A client asking "is my data backed up" may mean either, and the answer requires checking both independently.
