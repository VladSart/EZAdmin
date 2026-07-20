# Volume Shadow Copy Service (VSS) — Hotfix Runbook (Mode B: Ops)
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

**This runbook covers the Volume Shadow Copy Service (VSS) itself** — writer state, shadow storage, and the requestor/writer/provider snapshot mechanism that backup software (Windows Server Backup, Azure Backup, third-party) and client-side "Previous Versions" both depend on. It does not cover the backup product's own scheduling/retention UI — see `Azure/Backup/AzureBackup-B.md` for the Azure Backup side of a failed job once VSS itself is confirmed healthy.

```powershell
# 1. VSS writer state — the fastest single "is VSS healthy" check
vssadmin list writers

# 2. Existing shadow copies (snapshots currently held)
vssadmin list shadows

# 3. Shadow storage allocation per volume — exhaustion causes silent backup failures
vssadmin list shadowstorage

# 4. VSS-related service state
Get-Service VSS, SWPRV, "COM+ Event System" | Select-Object Name, Status, StartType

# 5. Recent VSS error events
Get-WinEvent -LogName Application -MaxEvents 50 |
  Where-Object { $_.ProviderName -in "VSS","VolSnap" -and $_.LevelDisplayName -in "Error","Warning" }
```

| Finding | Interpretation | Do this |
|---|---|---|
| A writer shows `State: [8] Failed`, error not `[0x0]` | That specific writer errored on its last snapshot attempt | **Fix 1** |
| `vssadmin list writers` returns no writers at all | VSS service/registration problem, or COM+ Event System stopped | **Fix 2** |
| Backup fails, Application log shows SQLWRITER/SQLVDI errors | SQL Server VSS writer is the actual failure point, not the backup app | **Fix 3** |
| `vssadmin list shadowstorage` shows `Used Shadow Copy Storage` near `Maximum Shadow Copy Storage` | Shadow storage exhausted — oldest snapshots being deleted, new ones may fail | **Fix 4** |
| "Previous Versions" tab empty for a share/volume where it used to work | Shadow copies not scheduled, or storage exhausted | **Fix 4** / **Fix 5** |
| Event ID 8193 with `VSS_E_HOLD_WRITES_TIMEOUT`/`VSS_E_WRITERERROR_TIMEOUT` | A writer took too long to freeze I/O (disk bottleneck, AV interference) | **Fix 6** |
| `Get-Service VSS` shows `Stopped` and won't start | VSS service itself is broken — deeper repair needed | **Fix 7** |
| Backup works for some volumes but fails for one specific volume | Provider-specific issue (often a third-party/hardware VSS provider) on that volume | **Fix 8** |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Volume Shadow Copy Service (VSS, "Volume Shadow Copy") — runs on demand,
  not continuously; Startup Type "Manual" is normal, not a fault
    │
COM+ Event System service running (VSS coordination relies on it)
    │
VSS Requestor (backup app: Windows Server Backup, Azure Backup MARS/MABS
  agent, third-party product, or the OS's own "Previous Versions" feature)
  initiates a snapshot request
    │
VSS Writers (one per application that registers with VSS — SQL Server,
  Exchange, Hyper-V, AD, System Writer, IIS Metabase, Registry, etc.) —
  EACH must report State: [1] Stable before a snapshot can proceed
    │
VSS Provider creates the actual snapshot:
    ├── System Provider (software, built into Windows — most common)
    └── Hardware/third-party provider (SAN array-based — snapshot offloaded
    │     to storage hardware, VSS only coordinates timing)
    │
Freeze (writers pause I/O briefly) → Snapshot created → Thaw (writers
  resume I/O) — this whole freeze/thaw window has a Microsoft-enforced
  timeout; a writer too slow to respond fails the ENTIRE snapshot, not
  just its own data
    │
Shadow copy storage area (on the source volume by default, or a
  dedicated volume) — has a configurable maximum size; exhaustion causes
  oldest shadow copies to be silently deleted to make room
    │
Shadow copy exposed to: the requesting backup app (which reads it and
  releases it), OR retained as a "Previous Versions" restore point for
  end users
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the VSS service itself**
```powershell
Get-Service VSS | Select-Object Status, StartType
```
Expected: `StartType: Manual` is normal (VSS runs on demand). If a snapshot is in progress it should show `Running`; otherwise `Stopped` is also normal at rest.

**2. Confirm every writer reports Stable**
```powershell
vssadmin list writers
```
Expected: every writer's `State: [1] Stable` and `Last error: No error`. Any writer in `[8] Failed` or a non-`[1]` state is the actual root cause — identify it by name before looking anywhere else.

**3. Confirm shadow storage isn't exhausted**
```powershell
vssadmin list shadowstorage
```
Expected: `Used Shadow Copy Storage` comfortably below `Maximum Shadow Copy Storage` (or `Maximum Shadow Copy Storage: UNBOUNDED`). Values close together mean old shadow copies are being aggressively purged and new snapshot attempts may fail outright.

**4. Confirm which specific application/component owns a failed writer**
```powershell
vssadmin list writers | Select-String -Pattern "Writer name|State|Last error" -Context 0,2
```
Expected: cross-reference the failed writer's name (e.g., `SqlServerWriter`, `Microsoft Hyper-V VSS Writer`, `System Writer`) against the owning service — that service is what needs restarting or investigating, not VSS itself.

**5. Confirm recent VSS error events with detail**
```powershell
Get-WinEvent -LogName Application -MaxEvents 100 |
  Where-Object { $_.ProviderName -in "VSS","VolSnap","SQLWRITER","SQLVDI" -and $_.LevelDisplayName -eq "Error" } |
  Select-Object TimeCreated, ProviderName, Id, Message
```
Expected: the first error in a cluster of related errors usually names the actual failing component (application/database name) — later errors are often downstream consequences of the same root failure.

---
## Common Fix Paths

<details><summary>Fix 1 — A specific writer is in Failed state</summary>

```powershell
# Identify the failed writer and its error code
vssadmin list writers

# Restart the OWNING service, not VSS itself — most writers self-register
# when their parent service starts. Examples:
Restart-Service -Name MSSQLSERVER -Force   # SQL Server Writer
Restart-Service -Name W3SVC -Force         # IIS Metabase Writer
Restart-Service -Name NTDS -Force -ErrorAction SilentlyContinue  # AD/NTDS Writer (DC only, disruptive)

# Re-check
vssadmin list writers
```
**Rollback:** N/A — restarting the owning application service is the documented fix. Confirm application/service availability impact before restarting a production service (SQL, a DC's NTDS, etc.) outside a maintenance window.
</details>

<details><summary>Fix 2 — No writers listed at all</summary>

```powershell
# Confirm the dependency chain first
Get-Service VSS, "COM+ Event System" | Select-Object Name, Status, StartType
Start-Service "COM+ Event System" -ErrorAction SilentlyContinue

# Re-register core VSS components (safe, idempotent)
net stop vss
net start vss
vssadmin list writers

# If still empty, re-register the VSS COM DLLs (run from an elevated prompt)
cd /d %windir%\system32
regsvr32 /s ole32.dll
regsvr32 /s oleaut32.dll
regsvr32 /s vss_ps.dll
vssvc /register
```
**Rollback:** N/A — re-registering system DLLs and restarting the VSS service are non-destructive, standard repair steps.
</details>

<details><summary>Fix 3 — SQL Server VSS writer causing backup failure</summary>

```powershell
# Identify the specific SQL instance from the paired SQLVDI/SQLWRITER
# Application-log errors (the instance name appears in the SQLVDI entry)
Get-WinEvent -LogName Application -MaxEvents 50 |
  Where-Object { $_.ProviderName -eq "SQLVDI" -and $_.LevelDisplayName -eq "Error" } |
  Select-Object -First 1 -ExpandProperty Message

# Test the theory: stop the affected instance, retry the backup
Stop-Service "MSSQL`$<InstanceName>" -Force
# ... retry backup job here ...

# If backup succeeds with SQL stopped, the fault is genuinely SQL-side —
# check that instance's own SQL error log next, not the backup product
Start-Service "MSSQL`$<InstanceName>"
```
**Rollback:** restart the SQL instance immediately after the isolation test regardless of outcome — do not leave a production database instance stopped.
</details>

<details><summary>Fix 4 — Shadow storage exhausted</summary>

```powershell
# Confirm current allocation
vssadmin list shadowstorage

# Increase the maximum (example: cap at 20% of the source volume, adjust to fit)
vssadmin resize shadowstorage /for=C: /on=C: /maxsize=20%

# If shadow copies are simply no longer needed on a volume, delete the oldest
vssadmin delete shadows /for=C: /oldest
```
**Rollback:** N/A for resizing (increasing the cap is non-destructive). `vssadmin delete shadows` permanently removes the targeted shadow copies — confirm no "Previous Versions" restore or in-flight backup depends on them first.
</details>

<details><summary>Fix 5 — Previous Versions empty for a share/volume</summary>

```powershell
# Confirm shadow copies actually exist for the volume
vssadmin list shadows /for=D:

# If none exist, confirm a schedule/task is configured to create them
# (modern Windows Server: no built-in GUI tab — verify via scheduled task
# or the backup product responsible for creating snapshots on this volume)
Get-ScheduledTask | Where-Object { $_.TaskName -match "ShadowCopyVolume" }

# Manually trigger one to confirm the mechanism itself still works
vssadmin create shadow /for=D:
```
**Rollback:** N/A — creating a test shadow copy is non-destructive; remove it afterward with `vssadmin delete shadows /for=D: /oldest` if it was only for validation.
</details>

<details><summary>Fix 6 — Writer timeout (VSS_E_HOLD_WRITES_TIMEOUT / VSS_E_WRITERERROR_TIMEOUT)</summary>

```powershell
# Confirm disk I/O isn't the bottleneck during the snapshot window
Get-Counter '\PhysicalDisk(_Total)\Avg. Disk sec/Transfer'

# Check for AV/EDR interference — a filter driver holding I/O can cause
# a writer to blow its freeze timeout
fltmc filters

# Retry the backup during a lower-I/O window if this is load-related, and
# confirm the AV product has documented VSS/backup-process exclusions applied
```
**Rollback:** N/A — this is diagnostic. Any AV exclusion or scheduling change should follow the vendor's/organization's own change-control process.
</details>

<details><summary>Fix 7 — VSS service itself won't start</summary>

```powershell
Get-Service VSS | Select-Object Status, StartType
Get-WinEvent -LogName System -MaxEvents 50 | Where-Object { $_.ProviderName -eq "Service Control Manager" -and $_.Message -match "VSS" }

# Confirm the service's dependencies are healthy
Get-Service VSS -RequiredServices | Select-Object Name, Status

sc.exe qc VSS
Start-Service VSS
```
**Rollback:** N/A. If the service binary/registration itself is corrupted and a restart doesn't resolve it, this typically requires an OS-level repair (SFC/DISM) or, in persistent cases, escalation — do not attempt registry-level service repair without a verified backup of the registry hive first.
</details>

<details><summary>Fix 8 — Failure isolated to one volume (provider-specific)</summary>

```powershell
# Confirm which provider is in play for the affected volume
vssadmin list providers

# System (software) provider issues are rare and usually resolved by Fix 2/7.
# A hardware/third-party provider failure is vendor-specific — confirm the
# provider's own service is running and check its vendor-specific event log
Get-Service | Where-Object { $_.DisplayName -match "VSS|Shadow" }
```
**Rollback:** N/A — diagnostic only. Provider-specific remediation follows the storage vendor's own support process once isolated to their component.
</details>

---
## Escalation Evidence

```
VSS Escalation
---------------
Date/Time of failure:
Server/volume affected:
vssadmin list writers output (full, especially any non-Stable state + error code):
vssadmin list shadowstorage output:
Backup product and job name:
Application log errors (VSS/VolSnap/writer-specific sources, e.g. SQLWRITER/SQLVDI):
Recent changes (backup product update, AV/EDR change, storage change, service pack/patch):
Attempted fixes and results:
```

---
## 🎓 Learning Pointers

- **One writer's failure fails the entire snapshot, not just that writer's own data** — VSS's freeze/thaw model requires every registered writer to reach `Stable` before a shadow copy can be created, so a single unrelated writer error can block a backup that has nothing to do with that application. Always check `vssadmin list writers` in full, not just the section for the app you expect is failing.
- **Restart the failed writer's owning application service, not the VSS service itself** — most writers self-register when their parent service starts; restarting VSS does nothing for a writer whose registration is fine but whose last snapshot attempt errored. See [Backup fails because of VSS writer](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/backup-fails-vss-writer).
- **Shadow storage exhaustion fails silently from the writer's perspective** — writers can all show `Stable` while backups still fail or "Previous Versions" comes up empty, because the shadow copy storage area itself ran out of room and began purging. Check `vssadmin list shadowstorage` even when every writer looks healthy.
- **A `VSS_E_WRITERERROR_TIMEOUT` is a symptom of something ELSE being slow (disk I/O, AV filter driver), not a VSS bug to patch around** — treat it as a performance investigation, not a VSS-service repair.
- **"No VSS writers are listed"** is a distinct, more fundamental failure mode from "a writer failed" — it points at VSS/COM+ registration itself, not any one application. See [No VSS writers are listed](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/no-vss-writers-listed-run-vssadmin-list).
- **For the deeper dive** — requestor/writer/provider architecture, hardware vs. software providers, and the shadow copy lifecycle — see `VSS-A.md`.
