# Hyper-V Host & VM — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

**This runbook covers the Windows Server Hyper-V role itself** — standalone or clustered hosts, VM state, Integration Services, checkpoints/AVHDX, Live Migration, and Hyper-V Replica. For guest-OS-level problems (the VM boots fine but something inside Windows/Linux is broken), troubleshoot the guest like any other server/client — this runbook stops at the virtualization boundary.

```powershell
# 1. VM inventory and state at a glance
Get-VM | Select-Object Name, State, Status, CPUUsage, MemoryAssigned, Uptime, ReplicationState

# 2. Integration Services health (Heartbeat is the fastest liveness signal)
Get-VM | Get-VMIntegrationService | Where-Object { $_.Name -eq "Heartbeat" } |
  Select-Object VMName, Enabled, PrimaryStatusDescription

# 3. Checkpoint inventory — orphaned/excessive chains are the #1 slow-disk/won't-start cause
Get-VM | Get-VMSnapshot | Select-Object VMName, Name, CreationTime, SnapshotType

# 4. [Clustered only] Cluster and CSV health
Get-ClusterNode | Select-Object Name, State
Get-ClusterSharedVolume | Select-Object Name, State, Node

# 5. Recent Hyper-V-VMMS / Hyper-V-Worker errors
Get-WinEvent -LogName "Microsoft-Windows-Hyper-V-VMMS-Admin" -MaxEvents 20 -ErrorAction SilentlyContinue |
  Where-Object { $_.LevelDisplayName -in "Error","Critical" }
```

| Finding | Interpretation | Do this |
|---|---|---|
| `Get-VM` shows `State: Off` unexpectedly, no admin-initiated shutdown | VM crashed or host resource exhaustion forced it down | **Fix 1** |
| VM `State: Running` but `Status` isn't `Operating normally` | Integration Services or guest-side heartbeat problem | **Fix 2** |
| Checkpoint won't delete/merge, or VM folder has `.avhdx` files not shown in Hyper-V Manager | Orphaned/broken checkpoint chain | **Fix 3** |
| Live Migration fails with Event ID 21502 | Config mismatch between source/destination hosts (switch name, hardware, auth) — see the specific sub-error in **Fix 4** | **Fix 4** |
| `Get-ClusterSharedVolume` shows a volume not `Online`, Event ID 5120 in the log | CSV communication interrupted | **Fix 5** |
| VM replication health shows `Critical`/`Warning`, or `Resynchronization Required` | Hyper-V Replica fell behind or lost sync | **Fix 6** |
| Host itself is unresponsive, `vmms.exe`/`vmwp.exe` pegged, VM stuck in "Starting"/"Stopping" | Host resource exhaustion or a stuck worker process | **Fix 7** |
| VM won't start after restore/clone/import, "Incomplete VM configuration" | Config files on non-shared storage, or version mismatch across cluster nodes | **Fix 8** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Hyper-V role installed, VMMS (Virtual Machine Management Service) running on the host
    │
Host resources available (CPU, memory headroom, storage IO) — vmwp.exe (one per VM)
    │ can't allocate what the host doesn't have
    │
Virtual switch(es) exist and are consistently named/configured
  (identically across ALL nodes if clustered — Live Migration checks this by name)
    │
VM configuration (.vmcx) + virtual disks (.vhdx) accessible at their configured paths
    │
    ├── [Standalone] Local or SMB storage reachable
    │
    ├── [Clustered] Cluster service running, quorum healthy, CSV Online on this node
    │                 (Get-ClusterSharedVolume — CSV is the shared, cluster-wide
    │                  namespace every node reads/writes VM files through)
    │
Integration Services enabled on BOTH host and guest (host enables → guest's vmicXXX
  services auto-start; mismatch = one-sided feature failure, most visibly Heartbeat)
    │
[Optional] Checkpoints — differencing disk (.avhdx) chain intact, parent/child
  relationships unbroken, enough free space to merge (~= size of the disk)
    │
[Optional] Live Migration — Kerberos/CredSSP auth configured, TCP 6600 (migration)
  and 3343 (clustering) reachable both directions, matching VM config version
    │
[Optional] Hyper-V Replica — TCP 443 (default) reachable to replica server/Broker,
  Kerberos or certificate auth valid, sufficient disk space for HRL (Hyper-V
  Replica Log / differencing) files on the primary
    │
VM running, reporting Status: Operating normally, guest workload functional
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the role and management service**
```powershell
Get-WindowsFeature Hyper-V
Get-Service VMMS | Select-Object Status, StartType
```
Expected: feature `Installed`, service `Running`. If VMMS is down, no VM management operations work at all regardless of individual VM state.

**2. Confirm VM state and Integration Services**
```powershell
Get-VM | Select-Object Name, State, Status
Get-VM -Name <vm-name> | Get-VMIntegrationService | Select-Object Name, Enabled, PrimaryStatusDescription
```
Expected: `Status: Operating normally`. `Heartbeat` is the single fastest liveness signal — if it shows `Enabled: False` or a non-OK `PrimaryStatusDescription`, the guest either doesn't have current Integration Services or the in-guest `vmicheartbeat` service is stopped/disabled.

**3. Confirm checkpoint/disk chain health**
```powershell
Get-VM -Name <vm-name> | Get-VMSnapshot
Get-VMHardDiskDrive -VMName <vm-name> | ForEach-Object { Get-VHD -Path $_.Path | Select-Object Path, ParentPath, VhdType }
```
Expected: `ParentPath` populated only for genuine differencing disks tied to a visible checkpoint. A `.avhdx` referenced on disk but not shown by `Get-VMSnapshot` is an orphan — usually left behind by a backup product that failed to clean up.

**4. [Clustered only] Confirm cluster and CSV health**
```powershell
Get-ClusterNode | Select-Object Name, State
Get-ClusterSharedVolume | Select-Object Name, State, Node
Get-ClusterResource | Where-Object { $_.ResourceType -eq "Virtual Machine" } | Select-Object Name, State, OwnerNode
```
Expected: all nodes `Up`, all CSVs `Online`, VM resources `Online` on their expected owner. A CSV that flips `Online`/`Redirected Access`/back is the classic Event ID 5120 pattern — see Fix 5.

**5. Confirm Live Migration prerequisites (if migration is failing)**
```powershell
Compare-VM -Name <vm-name> -DestinationHost <target-host>
netstat -ano | findstr /I "6600"
```
Expected: `Compare-VM` returns no incompatibilities. Port 6600 (Live Migration) listening on both hosts. `Compare-VM` is the single highest-value command here — it surfaces switch-name mismatches, processor compatibility, and config-version issues in one call before you go event-log spelunking.

**6. Confirm Hyper-V Replica health (if replication is configured)**
```powershell
Get-VMReplication | Select-Object VMName, State, Health, ReplicationHealth, PrimaryServer, ReplicaServer
Measure-VMReplication -VMName <vm-name>
```
Expected: `State: Replicating`, `Health: Normal`. `Critical`/`Warning` means either the replica has fallen too far behind (check pending HRL size) or an auth/network fault broke the last sync attempt.

---

## Common Fix Paths

<details><summary>Fix 1 — VM crashed or won't start (host resource exhaustion)</summary>

```powershell
# Check what actually happened
Get-WinEvent -LogName "Microsoft-Windows-Hyper-V-Worker-Admin" -MaxEvents 20 |
  Where-Object { $_.LevelDisplayName -in "Error","Critical" }

# Check host headroom before assuming a VM-specific fault
Get-VM | Measure-Object -Property MemoryAssigned -Sum
Get-Counter '\Memory\Available MBytes'

# If it's genuinely resource exhaustion, free capacity or reduce this VM's footprint
Set-VMMemory -VMName <vm-name> -DynamicMemoryEnabled $true -MinimumBytes 512MB -MaximumBytes 4GB

# Start it back up once headroom exists
Start-VM -Name <vm-name>
```
**Rollback:** revert dynamic memory settings to prior static allocation if dynamic memory causes application-level issues (`Set-VMMemory -VMName <vm-name> -DynamicMemoryEnabled $false -StartupBytes <original-value>`).
</details>

<details><summary>Fix 2 — Integration Services / Heartbeat unhealthy</summary>

```powershell
# Confirm enabled on the host side
Get-VMIntegrationService -VMName <vm-name>

# Re-enable if disabled
Enable-VMIntegrationService -VMName <vm-name> -Name "Heartbeat"

# Inside the guest (Windows) — confirm the matching service is actually running
Get-Service -Name vmic* | Format-Table -AutoSize

# Check the guest's Integration Services version isn't stale (Windows guest, run inside guest)
REG QUERY "HKLM\Software\Microsoft\Virtual Machine\Auto" /v IntegrationServicesVersion
```
**Rollback:** N/A — re-enabling a convenience service has no destructive side effect. If a specific service (e.g., Time Synchronization) is intentionally disabled for a domain-joined guest using NTP instead, leave that one off deliberately.
</details>

<details><summary>Fix 3 — Orphaned or broken checkpoint chain</summary>

```powershell
# Shut down first — triggers auto-merge if the chain is healthy enough for it
Stop-VM -Name <vm-name>
Get-VM -Name <vm-name> | Get-VMSnapshot | Remove-VMSnapshot

# If checkpoints are visible but won't merge, or files exist that Hyper-V Manager
# doesn't show, inspect the chain directly
Get-VMHardDiskDrive -VMName <vm-name> | ForEach-Object { Get-VHD -Path $_.Path | Select-Object Path, ParentPath }

# Manually merge an orphaned .avhdx back into its parent (verify direction first)
Merge-VHD -Path "<path-to-orphan.avhdx>" -DestinationPath "<parent.vhdx>"

Start-VM -Name <vm-name>
```
**Rollback:** back up the full VM folder before any manual `Merge-VHD` — a merge in the wrong direction or against the wrong parent is not reversible. If the chain is unrecoverable, attach the last known-good `.vhdx` to a new VM rather than continuing to fight a broken chain.
</details>

<details><summary>Fix 4 — Live Migration failure (Event ID 21502)</summary>

```powershell
# Single highest-value diagnostic — surfaces the actual mismatch in one call
Compare-VM -Name <vm-name> -DestinationHost <target-host>

# Most common: virtual switch name mismatch — switches must be named identically on every node
Get-VMSwitch -ComputerName <source-host>, <target-host> | Select-Object PSComputerName, Name

# Processor compatibility (different CPU generations across hosts)
Set-VMProcessor -VMName <vm-name> -CompatibilityForMigrationEnabled $true

# Confirm migration ports are listening on both sides
netstat -ano | findstr /I "6600"
```
**Rollback:** `Set-VMProcessor -VMName <vm-name> -CompatibilityForMigrationEnabled $false` if compatibility mode causes an unexpected feature/performance regression once migration succeeds.
</details>

<details><summary>Fix 5 — CSV interrupted (Event ID 5120)</summary>

```powershell
# Confirm current state
Get-ClusterSharedVolume | Select-Object Name, State, Node

# A single isolated STATUS_CLUSTER_CSV_AUTO_PAUSE_ERROR event can be safely ignored —
# any OTHER status code logged alongside it is the real signal. Check the System log:
Get-WinEvent -LogName System -FilterXPath "*[System[(EventID=5120)]]" -MaxEvents 20

# Bring an offline CSV back online
Get-ClusterSharedVolume -Name "<csv-name>" | Move-ClusterSharedVolume -Node <target-node>

# If storage/network connectivity is the root cause, verify paths before retrying
Get-ClusterNetwork | Select-Object Name, State, Role
```
**Rollback:** N/A — this restores the CSV to its normal state rather than changing configuration. If the CSV owner node itself is unhealthy, moving CSV ownership to a healthy node is the fix, not a rollback-requiring action.
</details>

<details><summary>Fix 6 — Hyper-V Replica health Critical/Warning</summary>

```powershell
# Check current replication health and pending change size
Get-VMReplication -VMName <vm-name> | Select-Object State, Health
Measure-VMReplication -VMName <vm-name>

# Resume a paused/failed replication
Resume-VMReplication -VMName <vm-name>

# If resync is required (health shows "Resynchronization Required")
Start-VMFailoverServerReconnect -VMName <vm-name> -ErrorAction SilentlyContinue
Start-VMResynchronization -VMName <vm-name>
```
**Rollback:** N/A — resuming/resynchronizing replication is non-destructive to the primary VM. If replication is being abandoned entirely, `Remove-VMReplication -VMName <vm-name>` cleanly tears it down (does not affect the running primary VM).
</details>

<details><summary>Fix 7 — Host unresponsive / worker process stuck</summary>

```powershell
# Identify what's actually stuck before restarting anything
Get-Process vmwp -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, CPU, WorkingSet
Get-Service VMMS | Select-Object Status

# Restarting VMMS does NOT stop running VMs (vmwp.exe processes are independent),
# but a stuck vmwp.exe for one specific VM may need to be targeted directly
Restart-Service VMMS

# Last resort for a single genuinely hung VM (this DOES interrupt that VM)
Stop-VM -Name <vm-name> -TurnOff
```
**Rollback:** N/A — `Restart-Service VMMS` is safe and non-destructive to running VMs. `Stop-VM -TurnOff` is equivalent to pulling power on that one VM; only use it after confirming graceful `Stop-VM` already failed.
</details>

<details><summary>Fix 8 — VM won't start after restore/clone/import</summary>

```powershell
# Check for the classic cause: config files on local (non-shared) storage in a cluster
Get-VM -Name <vm-name> | Select-Object Name, Path, ConfigurationLocation

# Confirm all cluster nodes support this VM's configuration version
Get-VM -Name <vm-name> | Select-Object Name, Version
Get-VMHostSupportedVersion -ComputerName <each-node>

# Upgrade configuration version if the VM was created on a newer host and moved to an older one's cluster
Update-VMVersion -Name <vm-name>
```
**Rollback:** `Update-VMVersion` is one-way — the VM configuration version cannot be downgraded afterward. Confirm every cluster node supports the target version before running it, since a downgrade requires exporting/recreating the VM.
</details>

---

## Escalation Evidence

```
Hyper-V Escalation
-------------------
Date/Time of failure:
Host name(s) / cluster name:
Affected VM(s):
Get-VM Status/State at time of failure:
Standalone or clustered (CSV name/state if clustered):
Integration Services status (Heartbeat especially):
Checkpoint chain state (orphaned/broken?):
Live Migration / Replica error code (if applicable):
Recent Hyper-V-VMMS / Hyper-V-Worker event log Critical/Error entries:
Recent changes (host patching, driver/firmware updates, storage changes, cluster node maintenance):
Attempted fixes and results:
```

---

## 🎓 Learning Pointers

- **`Compare-VM -Name <vm> -DestinationHost <host>` is the single highest-leverage Live Migration diagnostic** — it evaluates switch names, processor compatibility, and config version mismatches in one call before you need to correlate Event ID 21502 sub-codes manually. Run it first on every migration failure. See [MS Docs: troubleshoot live migration issues](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-live-migration-issues).
- **Integration Services must be enabled on BOTH host and guest to function — enabling one side without the other produces a silent, one-directional failure.** Heartbeat is the fastest liveness check precisely because it's the simplest of the six services; if it's unhealthy, don't assume the others are fine.
- **A lone `Event ID 5120` with `STATUS_CLUSTER_CSV_AUTO_PAUSE_ERROR` is normal noise and can be ignored — any OTHER status code alongside it is the real signal.** Treating every 5120 as an emergency trains engineers to ignore the ones that matter. See [MS Docs: Event ID 5120 CSV troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-server/high-availability/event-id-5120-cluster-shared-volume-troubleshooting-guidance).
- **Checkpoints are not backups and were never meant to accumulate — a chain of 50+ is itself the failure mode**, not just a symptom of one. Third-party backup software that fails to clean up its own checkpoints is the most common real-world cause; check backup job success before assuming Hyper-V itself is at fault.
- **`Update-VMVersion` is a one-way door** — verify every cluster node supports the target configuration version before running it against a VM that needs to remain portable across the cluster.
- **For the deeper dive** — CSV/quorum architecture, Live Migration authentication modes (CredSSP vs. Kerberos constrained delegation), Hyper-V Replica's HRL mechanism, and virtual switch types — see `HyperV-A.md`.
