# Volume Shadow Copy Service (VSS) — Reference Runbook (Mode A: Deep Dive)
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

- **Applies to:** the Volume Shadow Copy Service (VSS) on Windows Server 2016 through 2025 and Windows 10/11 clients — the underlying point-in-time snapshot mechanism used by Windows Server Backup, Azure Backup (MARS agent and MABS), most third-party backup products, client-side "Previous Versions"/File History, and application-consistent VM backups (Hyper-V VSS Writer, SQL Server Writer, Exchange Writer).
- **Covers:** the requestor/writer/provider architecture, writer state model, shadow copy storage allocation and lifecycle, common writer-specific failure patterns (SQL Server is the most frequently encountered), and VSS/COM+ service-level repair.
- **Does not cover:** the backup product's own scheduling/retention/catalog logic once VSS itself is confirmed healthy and a snapshot was successfully created and consumed (see `Azure/Backup/AzureBackup-A.md`, `ActiveDirectory/Troubleshooting/BackupRestore/AD-BackupRestore-A.md`, or the relevant application's own backup documentation for that layer); DFS Replication's separate, unrelated use of the term "staging" (see `DFS/Troubleshooting/Replication/Replication-A.md` — no shared mechanism with VSS despite both being storage-adjacent); Storage Spaces Direct's own health model (see `StorageSpacesDirect-A.md` — VSS operates on top of whatever volume/disk layer is present, S2D or otherwise, and does not interact with S2D's pool/virtual-disk health states directly).
- **Admin roles needed:** local Administrators on the server hosting the volume/application being snapshotted. No AD-level permissions are required for VSS itself, though the requesting backup product may need its own service account permissions against the applications it's snapshotting (e.g., sysadmin on SQL Server for the SQL Writer to cooperate fully).

---
## How It Works

<details><summary>Full architecture</summary>

VSS coordinates three independent roles to produce a point-in-time, crash-consistent (or application-consistent, when writers participate) snapshot of a volume without taking it offline:

**Requestor** — the component that asks for a shadow copy: a backup product (Windows Server Backup, Azure Backup's MARS/MABS agent, a third-party backup application), or the OS itself creating a scheduled snapshot for "Previous Versions"/File History. The requestor calls into the VSS API, specifies which volumes to snapshot, and — critically — whether it wants an application-consistent snapshot (which requires writer participation) or a simple crash-consistent one.

**Writers** — one per application or OS component that has registered itself with VSS to be notified before a snapshot is taken (SQL Server Writer, Exchange Writer, Hyper-V VSS Writer, Active Directory/NTDS Writer on domain controllers, System Writer, Registry Writer, IIS Metabase Writer, and dozens of others depending on what's installed). Each writer's job is to bring its application's on-disk data into a consistent state and briefly pause new writes when told to. Writers self-register when their owning service starts — this is why restarting the *application's* service, not VSS itself, is almost always the correct fix for a writer stuck in a bad state, since the registration happens as a side effect of that service's own startup.

**Provider** — the component that actually creates the shadow copy. The built-in **System Provider** (software-based, copy-on-write at the block level) is the default and by far the most common on general-purpose Windows Server deployments. **Hardware providers** (vendor-supplied, typically SAN-array-based) offload the actual snapshot mechanism to the storage array itself — VSS still coordinates the freeze/thaw timing with writers, but the snapshot data itself lives on the array, not in Windows-managed shadow storage. Confusing "the provider failed" with "a writer failed" is a common misdiagnosis, since both surface as a failed VSS operation but point at entirely different components (`vssadmin list providers` disambiguates).

**The freeze/thaw cycle, and why one writer can fail an entire snapshot.** When a snapshot is requested, VSS asks every registered writer to prepare (`PrepareForSnapshot`), then briefly freezes I/O across the writers (`Freeze`) while the provider takes the actual snapshot, then releases them (`Thaw`). This freeze window has a Microsoft-enforced timeout (historically around 10 seconds for the freeze itself, with a longer overall operation timeout around 60 seconds) — if even one writer fails to respond in time (commonly due to disk I/O contention, an aggressive AV/EDR filter driver intercepting I/O, or a genuinely overloaded application), the **entire snapshot operation fails**, not just that writer's portion. This is the single most counter-intuitive fact for engineers new to VSS: a backup covering ten unrelated volumes and applications can fail because of one slow, unrelated writer.

**Shadow copy storage.** By default, shadow copies are stored on the same volume they protect (though a dedicated storage volume can be configured), in a reserved area with a configurable maximum size. As new shadow copies are created and the storage area fills, VSS automatically deletes the oldest shadow copies to make room — silently, with no failure reported to the requestor unless the area is so constrained that even the newest requested copy cannot be created. This auto-purge behavior is why "Previous Versions" restore points can quietly disappear over time even when nothing is obviously broken, and why shadow storage sizing is a real operational concern, not a set-once-and-forget setting.

**Consumers of the resulting shadow copy** fall into two categories with different lifecycles: a backup product typically mounts the shadow copy, reads what it needs, and releases/deletes it as part of the same job (transient); the "Previous Versions"/File History mechanism instead deliberately retains a rolling set of shadow copies as end-user-facing restore points (persistent, until storage pressure or an explicit schedule prunes them).

</details>

---
## Dependency Stack

```
Layer 4 — Consumer: backup product (transient, mount→read→release) OR
              "Previous Versions"/File History (persistent restore points)
Layer 3 — Shadow copy storage area (per-volume, size-capped, auto-purges
              oldest copies on exhaustion — silent unless total capacity
              can't fit even the newest request)
Layer 2 — Provider (creates the actual snapshot)
              ├── System Provider (software, copy-on-write, default)
              └── Hardware/third-party provider (SAN-offloaded)
Layer 1 — Writers (one per registered application/component) — EVERY
              writer must report State: Stable before Layer 2 can proceed;
              a single Failed/timed-out writer blocks the whole operation
Layer 0 — Foundation:
              ├── Volume Shadow Copy Service (VSS) — runs on-demand,
              │     Manual startup type is normal, not a fault
              ├── COM+ Event System service (VSS coordination dependency)
              └── Requestor initiates the operation via the VSS API
                    (backup product, or OS-scheduled "Previous Versions")
```

A fault at Layer 0/1 (service not running, or any single writer unhealthy) blocks every snapshot on that server regardless of which volume or application the requestor actually cares about — always check writer state in full before assuming the failure is specific to the volume being backed up. A fault at Layer 3 (shadow storage exhaustion) can present with every writer healthy and no obvious error, purely as missing/incomplete restore points.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| One named writer shows `State: [8] Failed` | That application's last snapshot attempt errored | `vssadmin list writers`, restart owning service |
| `vssadmin list writers` returns nothing at all | VSS/COM+ registration broken, not an app-specific issue | `Get-Service VSS, "COM+ Event System"` |
| Backup fails, Application log shows SQLWRITER/SQLVDI errors | SQL Server VSS writer — usually a specific SQL instance/database issue | Identify instance from SQLVDI event, isolate per Playbook 1 |
| Event ID 8193, error `VSS_E_HOLD_WRITES_TIMEOUT` | A writer didn't respond within the freeze window | Disk I/O contention or AV/EDR filter driver interference |
| Event ID 8193, error `VSS_E_WRITERERROR_TIMEOUT` | Same root cause as above, reported from the writer's side | Same as above |
| `vssadmin list shadowstorage` shows Used ≈ Maximum | Shadow storage exhausted, oldest copies being purged | `vssadmin resize shadowstorage` |
| "Previous Versions" empty though backups otherwise succeed | Shadow storage exhausted, OR no schedule creating snapshots for that volume specifically | `vssadmin list shadows /for=<vol>` |
| Failure isolated to one volume only, others fine | Provider-specific (often hardware/SAN provider) issue on that volume | `vssadmin list providers` |
| Hyper-V host backup fails, guest VM's own writers unaffected | Hyper-V VSS Writer (host-side) issue — a different writer from the guest's in-guest writers | Check `Microsoft Hyper-V VSS Writer` state on the HOST |
| Backup succeeds but restore/mount of the shadow copy fails | Provider-side snapshot corruption, or the volume changed significantly since the snapshot | Re-run a fresh snapshot; escalate if reproducible |
| VSS service won't start at all | Service registration/dependency corruption | `sc.exe qc VSS`, dependency chain, SFC/DISM |

---
## Validation Steps

**1. Confirm the VSS service and its dependency**
```powershell
Get-Service VSS, "COM+ Event System" | Select-Object Name, Status, StartType
```
Good: `StartType: Manual` (normal — VSS is not meant to run continuously), `COM+ Event System: Running`/`Automatic`. Bad: VSS fails to start on demand, or COM+ Event System is stopped.

**2. Confirm every writer is Stable**
```powershell
vssadmin list writers
```
Good: every writer `State: [1] Stable`, `Last error: No error`. Bad: any writer in a non-Stable state — note the exact name and error code before proceeding.

**3. Confirm shadow copy storage headroom**
```powershell
vssadmin list shadowstorage
```
Good: `Used Shadow Copy Storage` well below `Maximum Shadow Copy Storage`. Bad: the two values converging, or `Maximum` set unrealistically low for the volume's change rate.

**4. Confirm the provider in use**
```powershell
vssadmin list providers
```
Good: expected provider present (System Provider for most deployments, or the storage vendor's hardware provider if applicable) and no provider-specific error noted. Bad: an expected hardware provider missing — check the vendor's VSS provider service.

**5. Test the mechanism directly, independent of any backup product**
```powershell
vssadmin create shadow /for=<volume>
vssadmin list shadows /for=<volume>
vssadmin delete shadows /for=<volume> /oldest
```
Good: shadow copy creates and lists successfully — this isolates whether the fault is in VSS itself or in the backup product's use of it. Bad: manual creation also fails — the fault is confirmed to be in VSS/writers/provider, not the backup application.

**6. Correlate with Application-log detail for the specific failure**
```powershell
Get-WinEvent -LogName Application -MaxEvents 200 |
  Where-Object { $_.ProviderName -match "VSS|VolSnap|Writer" -and $_.LevelDisplayName -eq "Error" } |
  Sort-Object TimeCreated | Select-Object TimeCreated, ProviderName, Id, Message
```
Good: no recent errors. Bad: a cluster of errors — the earliest one in a tight time window is usually the root cause; later ones are often downstream noise from the same failed operation.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Establish whether this is a VSS problem or a backup-product problem
1. Run `vssadmin create shadow /for=<volume>` manually, independent of the backup software. If it succeeds, the fault is in how the backup product is calling VSS (or in something specific to its own snapshot handling) rather than in VSS/writers/providers themselves — redirect troubleshooting to the backup product.

### Phase 2 — Scope the fault: one writer, or the whole VSS mechanism?
2. `vssadmin list writers` in full. A single named writer in a bad state scopes the investigation to that application; an empty or entirely-failed writer list points at VSS/COM+ registration itself.

### Phase 3 — For a single failed writer, identify and act on the OWNING application
3. Match the writer name to its owning service (SQL Server Writer → SQL Server service; Hyper-V VSS Writer → Hyper-V Virtual Machine Management service; IIS Metabase Writer → IIS-related services). Restart that service, not VSS.
4. For SQL Server specifically, cross-reference the SQLVDI/SQLWRITER Application-log errors to identify the exact instance and database at fault before restarting anything broadly.

### Phase 4 — Rule out shadow storage exhaustion, even if writers look healthy
5. `vssadmin list shadowstorage` — this is an easy step to skip because writer state can be perfectly healthy while shadow storage silently exhausts, especially on high-change-rate volumes with a conservative `maxsize`.

### Phase 5 — For timeout-class errors, investigate performance, not VSS configuration
6. `VSS_E_HOLD_WRITES_TIMEOUT`/`VSS_E_WRITERERROR_TIMEOUT` point at something external to VSS being too slow to respond within the freeze window — disk I/O saturation and AV/EDR filter-driver interference are the two most common real causes. Treat this as a performance investigation.

### Phase 6 — For an empty writer list, repair VSS/COM+ registration directly
7. Restart the VSS service and COM+ Event System; re-register the core VSS DLLs (`regsvr32`) and run `vssvc /register` if the service-restart alone doesn't restore the writer list.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Isolate and resolve a SQL Server VSS writer failure</summary>

**Scenario:** Backup fails with a generic VSS error; Application log shows paired SQLWRITER/SQLVDI errors.

```powershell
# 1. Pull the specific SQLVDI error — it names the failing instance
Get-WinEvent -LogName Application -MaxEvents 100 |
  Where-Object { $_.ProviderName -eq "SQLVDI" -and $_.LevelDisplayName -eq "Error" } |
  Select-Object -First 1 -ExpandProperty Message

# 2. Pull the paired SQLWRITER error — it often names the specific database
Get-WinEvent -LogName Application -MaxEvents 100 |
  Where-Object { $_.ProviderName -eq "SQLWRITER" -and $_.LevelDisplayName -eq "Error" } |
  Select-Object -First 1 -ExpandProperty Message

# 3. Isolate: stop the implicated instance, retry the backup
Stop-Service "MSSQL`$<InstanceName>" -Force
# ... retry backup here ...

# 4. If the backup now succeeds, the fault is confirmed SQL-side — check that
#    instance's own SQL Server error log next (not further VSS troubleshooting)
Start-Service "MSSQL`$<InstanceName>"

# 5. If multiple instances are present and the specific one can't be identified
#    from event log detail, stop all SQL instances and retry as a last-resort
#    isolation step (SQL Writer will not be used with SQL fully stopped)
```
**Rollback:** restart every stopped SQL instance immediately after the isolation test, regardless of outcome — do not leave production databases offline pending further investigation. Based on [Backup fails because of VSS writer](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/backup-fails-vss-writer).
</details>

<details><summary>Playbook 2 — Recover from an empty/broken writer list</summary>

**Scenario:** `vssadmin list writers` returns no writers on a server that previously had them, and backups are failing across the board.

```powershell
# 1. Confirm the dependency chain
Get-Service VSS, "COM+ Event System" | Select-Object Status, StartType
Start-Service "COM+ Event System" -ErrorAction SilentlyContinue

# 2. Restart VSS cleanly
net stop vss
net start vss
vssadmin list writers

# 3. If still empty, re-register core VSS COM components
cd $env:WINDIR\System32
regsvr32 /s ole32.dll
regsvr32 /s oleaut32.dll
regsvr32 /s vss_ps.dll
vssvc /register
vssadmin list writers

# 4. If still empty after re-registration, run a system file integrity check
#    (last resort before escalation — can be disruptive on a busy server)
sfc /scannow
```
**Rollback:** N/A — service restarts and DLL re-registration are non-destructive, standard repair steps. `sfc /scannow` only repairs corrupted system files and does not remove anything intentionally configured.
</details>

<details><summary>Playbook 3 — Right-size shadow copy storage to stop silent purging</summary>

**Scenario:** "Previous Versions" restore points are disappearing faster than expected, or intermittent backup failures correlate with `vssadmin list shadowstorage` showing storage near its cap.

```powershell
# 1. Baseline current allocation and usage trend
vssadmin list shadowstorage

# 2. Increase the maximum — percentage-based sizing scales with the volume
vssadmin resize shadowstorage /for=<volume> /on=<volume> /maxsize=20%

# 3. If the volume has a very high change rate, consider a DEDICATED shadow
#    storage volume rather than growing the cap on the source volume itself
#    (keeps snapshot I/O off the volume being protected)
vssadmin resize shadowstorage /for=<volume> /on=<dedicated-volume> /maxsize=100GB

# 4. Re-verify headroom after resizing
vssadmin list shadowstorage
```
**Rollback:** shrinking the maximum back down is possible with the same command using a smaller `/maxsize` value, but VSS will not shrink storage already in use below what existing shadow copies require — delete unneeded shadow copies first if reducing the cap significantly.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects VSS diagnostic evidence for escalation.
.NOTES
    Run on the affected server with local Administrator rights.
#>
$out = "C:\VSS-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

vssadmin list writers | Out-File "$out\writers.txt"
vssadmin list shadows | Out-File "$out\shadows.txt"
vssadmin list shadowstorage | Out-File "$out\shadowstorage.txt"
vssadmin list providers | Out-File "$out\providers.txt"
vssadmin list volumes | Out-File "$out\volumes.txt"

Get-Service VSS, SWPRV, "COM+ Event System" | Select-Object Name, Status, StartType |
  Export-Csv "$out\vss-services.csv" -NoTypeInformation

Get-WinEvent -LogName Application -MaxEvents 200 -ErrorAction SilentlyContinue |
  Where-Object { $_.ProviderName -match "VSS|VolSnap|SQLWRITER|SQLVDI|Writer" } |
  Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
  Export-Csv "$out\vss-events.csv" -NoTypeInformation

Write-Host "Evidence collected to $out"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `vssadmin list writers` | Writer inventory, state, last error — the primary VSS health check |
| `vssadmin list shadows` | Existing shadow copies on the system |
| `vssadmin list shadowstorage` | Shadow storage allocation vs. usage per volume |
| `vssadmin list providers` | Registered VSS providers (System vs. hardware/vendor) |
| `vssadmin list volumes` | Volumes eligible for shadow copies |
| `vssadmin create shadow /for=<vol>` | Manually create a shadow copy — isolates VSS from the backup product |
| `vssadmin delete shadows /for=<vol> /oldest` | Remove the oldest shadow copy on a volume |
| `vssadmin resize shadowstorage /for /on /maxsize` | Grow/shrink the shadow storage cap |
| `Get-Service VSS, "COM+ Event System"` | Core VSS service dependency check |
| `net stop vss` / `net start vss` | Clean VSS service restart |
| `regsvr32 ole32.dll / oleaut32.dll / vss_ps.dll` | Re-register core VSS COM components |
| `vssvc /register` | Re-register the VSS service itself |
| `sfc /scannow` | System file integrity check (last resort for persistent registration issues) |
| `Get-WinEvent -LogName Application -FilterXPath` (ProviderName VSS/VolSnap/writer-specific) | VSS and writer-specific error correlation |

---
## 🎓 Learning Pointers

- **VSS's freeze/thaw model means one unhealthy writer can fail an entire multi-volume, multi-application snapshot operation** — this is the load-bearing architectural fact behind almost every confusing VSS failure report ("why did my file server backup fail because of a SQL error?"). Always read the FULL writer list, not just the writer for the thing you expected to fail. See [Backup fails because of VSS writer](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/backup-fails-vss-writer).
- **Writers self-register via their owning service's startup — fix the application, not VSS.** Restarting the VSS service itself does nothing for a writer whose registration is intact but whose last operation errored; this is the single most common wasted troubleshooting step for engineers new to VSS.
- **Shadow storage exhaustion is silent and writer-independent** — every writer can report perfectly healthy while shadow copies quietly age out due to storage pressure, which is why `vssadmin list shadowstorage` deserves a routine check even when nothing else looks wrong.
- **`vssadmin create shadow` run manually is the fastest way to separate "VSS itself is broken" from "the backup product is misusing VSS"** — a successful manual snapshot with a failing scheduled backup redirects the entire investigation toward the backup application rather than the OS.
- **Timeout-class errors (`VSS_E_HOLD_WRITES_TIMEOUT`, `VSS_E_WRITERERROR_TIMEOUT`) are a performance symptom wearing a VSS error code** — the fix is almost never a VSS setting, it's disk I/O contention or an AV/EDR filter driver getting in the way of the freeze window.
- **For the Hyper-V-specific side of this** (host-level Hyper-V VSS Writer vs. in-guest application writers, and how VM checkpoints relate to — and differ from — VSS-based backup), see `HyperV-A.md`'s Hyper-V Replica/checkpoint sections; the two mechanisms are frequently conflated but solve different problems.
