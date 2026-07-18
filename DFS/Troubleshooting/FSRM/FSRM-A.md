# File Server Resource Manager (FSRM) — Reference Runbook (Mode A: Deep Dive)
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

Covers File Server Resource Manager (FSRM) — the File and Storage Services role service that manages **quotas**, **file screening**, **file classification (FCI)**, **file management jobs**, and **storage reports** on Windows Server file servers. In scope:

- Quota Management: hard/soft quotas, auto-apply quotas, quota templates, nested-quota inheritance
- File Screening Management: file groups, file screens, file screen templates, file screen exceptions
- File Classification Infrastructure (FCI): classification property definitions, classification rules (content- and folder-based), real-time vs. scheduled classification
- File Management Jobs: condition-based actions (expire, encrypt with RMS, run custom command) driven off classification/age/location
- Storage Reports: scheduled and on-demand usage/audit reporting
- The `SrmSvc` service, its config store, and its dependency on NTFS and (optionally) the USN Change Journal
- Cluster/failover scenarios for FSRM on clustered file server roles

**Explicitly out of scope** (see cross-references):
- **DFS Namespace / DFS Replication** — FSRM operates on individual file server volumes; it has no awareness of DFS namespace paths or DFSR replication state. See `DFS/Troubleshooting/Namespace/` and `DFS/Troubleshooting/Replication/`.
- **NTFS permissions and share permissions themselves** — FSRM screens and quotas layer on top of a working NTFS ACL model; if the underlying permission is wrong, fixing FSRM won't help. See `Windows/Troubleshooting/SMB-A.md`.
- **Azure File Sync cloud tiering** as an alternative to quota-based space management — mentioned only as a cross-reference; not a topic in this repo.
- **Cluster resource group administration in general** — this runbook covers only the FSRM-specific failure modes on a clustered file server; general failover clustering administration is not covered here.

**Prerequisites:** Windows Server 2016 or later, File Server Resource Manager role service installed (part of File and Storage Services), local administrator rights on the target server, target volumes formatted NTFS.

---

## How It Works

<details><summary>Full architecture</summary>

### FSRM Component Model

```
┌────────────────────────────────────────────────────────────────────┐
│                         FSRM (SrmSvc)                                │
│                                                                        │
│  Config store: %SystemDrive%\System Volume Information\SRM\*.xml     │
│  (quota.xml, filescrn.xml, classification.xml, storagereports.xml…)  │
│  ACL'd to SYSTEM + local Administrators only                          │
│                                                                        │
│  ┌──────────────┐  ┌───────────────┐  ┌─────────────────────────┐   │
│  │Quota Mgmt    │  │File Screening │  │File Classification       │   │
│  │              │  │               │  │Infrastructure (FCI)      │   │
│  │Quota         │  │File Groups    │  │Property Definitions      │   │
│  │Templates     │  │  (ext lists)  │  │Classification Rules      │   │
│  │  ↓           │  │  ↓            │  │  (content/folder-based)  │   │
│  │Quotas /      │  │File Screen    │  │  ↓                        │   │
│  │Auto-Apply    │  │Templates      │  │Real-time (USN journal)   │   │
│  │Quotas        │  │  ↓            │  │  OR scheduled sweep      │   │
│  │  ↓           │  │File Screens   │  └─────────────┬─────────────┘   │
│  │Hard/Soft     │  │  ↓            │                │                 │
│  │enforcement   │  │Exceptions     │                ▼                 │
│  └──────────────┘  └───────────────┘  ┌─────────────────────────┐   │
│                                         │File Management Jobs     │   │
│                                         │(condition → action:     │   │
│                                         │ expire / RMS encrypt /  │   │
│                                         │ custom command)         │   │
│                                         └─────────────────────────┘   │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                     Storage Reports                            │   │
│  │  Quota Usage / File Screening Audit / Duplicate Files /        │   │
│  │  Large Files / Least/Most Recently Accessed / Files by Owner   │   │
│  └──────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────┘
        │
        ▼
   NTFS volume only — FSRM has no ReFS support whatsoever
```

### Quota Management internals

A **quota** is a size limit tied to a specific path. There are two enforcement modes:
- **Hard quota** — writes that would exceed the limit are blocked at the filesystem level (via a filter driver, not a periodic scan).
- **Soft quota** — no blocking; purely a notification/reporting mechanism, useful for visibility without user impact.

An **auto-apply quota** is a template binding applied to a parent folder that FSRM automatically re-applies to every existing subfolder *and* every subfolder created afterward. This is the standard pattern for "200 MB per user home folder" — you auto-apply once on the parent `Users\` folder and every new user folder inherits it without manual work.

**Quota templates** decouple the limit definition from its application. Editing a template does **not** retroactively change quotas already derived from it — that's a deliberate safety measure, not a bug. To propagate a template change to existing derived quotas you must explicitly push it, either via the console's "Apply template to all derived quotas" action on save, or via `Set-FsrmAutoQuota -Path <p> -Template <t> -UpdateDerived` per auto-apply quota.

**Nested quota inheritance:** if a parent folder and a subfolder both have quotas, the *more restrictive* effective limit always wins for reporting purposes on the subfolder. A 100 MB quota on `Users\` and a separately-configured 200 MB quota on `Users\jdoe\` means `jdoe`'s folder will only ever show up to 100 MB as "available," because the parent ceiling caps it. This confuses almost every engineer the first time they see it — the fix, if it's unintentional, is architectural (remove/raise the parent quota), not a repair operation.

### File Screening internals

File screening is built from three layers:
1. **File Groups** — named lists of file extensions/patterns (e.g., "Audio and Video Files" = `*.mp3, *.wav, *.avi...`).
2. **File Screen Templates** — bind one or more file groups to an enforcement mode (active = block, passive = notify only) plus notification actions.
3. **File Screens** — a template applied to an actual path.
4. **File Screen Exceptions** — carve-outs on a subfolder that override a parent screen (the *only* way to allow a blocked file type in one specific subfolder without changing the parent screen itself).

A frequently-missed detail: Microsoft Office and many other applications save files via a temporary file (often `.tmp`) that gets renamed on successful save. If `.tmp` is in a blocked file group, the *save itself* fails before the visible target file is ever touched — producing an Access Denied error that has nothing to do with the file extension the user thinks they're saving.

### File Classification Infrastructure (FCI)

FCI tags files with classification properties, either manually or automatically via **classification rules**. Rules can be:
- **Folder-based** — classify anything under a given path.
- **Content-based** — run a regular expression or string match against file content (e.g., flag any file containing what looks like 10+ Social Security Numbers).

Classification can run in two modes:
- **Scheduled** — a periodic full or incremental sweep (`Start-FsrmClassification`).
- **Continuous/real-time** — driven off the **NTFS USN Change Journal**, which lets FSRM classify a file immediately after it's modified rather than waiting for the next scheduled sweep.

Starting with Windows Server version 1803, the USN Change Journal creation on service start can be **disabled** per-volume or server-wide via the registry (`SkipUSNCreationForSystem` / `SkipUSNCreationForVolumes` under `HKLM\SYSTEM\CurrentControlSet\Services\SrmSvc\Settings`). This trades away real-time classification to reclaim the disk space the journal consumes — a deliberate, documented trade-off, not a defect. If a server was set up with this disabled and someone later expects real-time classification to "just work," it won't, and there's no error message pointing at the registry key — it has to be checked directly.

### File Management Jobs

A file management job pairs a **condition** (location, classification property, creation/modified/accessed date) with an **action** (expire the file, apply RMS encryption, run a custom command) and an optional **notification** (email warning before the action fires, giving users a grace period). This is the mechanism behind "delete anything untouched for 10 years" or "encrypt anything tagged Confidential."

### Storage Reports

Reports read from either live filesystem enumeration or, for the File Screening Audit report specifically, a **separate auditing database** that must be explicitly enabled (**Record file screening activity in the auditing database**, off by default in some deployment paths). An empty audit report and a broken audit report look identical unless you check whether recording was ever turned on.

</details>

---

## Dependency Stack

```
Layer 8: Storage Reports (reads live FS state + optional audit DB)
Layer 7: File Management Jobs (acts on classification/age/location)
Layer 6: File Classification Infrastructure (property defs + rules)
Layer 5: USN Change Journal (only required for real-time classification — optional per Layer 3 config)
Layer 4: File Screening (file groups → templates → screens → exceptions)
Layer 3: Quota Management (templates → quotas/auto-apply quotas → hard/soft enforcement)
Layer 2: FSRM config store — %SystemDrive%\System Volume Information\SRM\*.xml
          (SYSTEM + local Administrators ACL only; corruption/permission loss here
           breaks the console, PowerShell module, AND the service simultaneously)
Layer 1: SrmSvc service + WMI repository (console and PowerShell cmdlets both ride on WMI)
Layer 0: NTFS volume (hard requirement — ReFS is entirely unsupported, no workaround exists)
```

Everything above Layer 2 depends on the config store being both intact and permission-correct. A single corrupted `quota.xml` can simultaneously break the MMC console, the PowerShell cmdlets, and the service startup — which is why "the FSRM console won't open" and "SrmSvc keeps crashing" tickets so often share one root cause.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| FSRM console throws Access Denied (0x80070005) opening Quota Management | Broken ACL on `quota.xml` | `icacls "C:\System Volume Information\SRM\quota.xml"` |
| `SrmSvc` won't start; event shows `0xc00cee22` or `0xc00cee2d` | Corrupted config XML (parseURL failure) | `Get-WinEvent` filtered to `SRMSVC` source |
| Quota won't apply to a volume at all | Volume is ReFS, not NTFS | `Get-Volume \| Select FileSystem` |
| Editing a quota template doesn't change existing folders | Templates don't retroactively propagate by design | `Get-FsrmAutoQuota \| Select MatchesTemplate` |
| Subfolder "Available" space is smaller than its own quota limit implies | Nested quota — parent folder quota is more restrictive | `Get-FsrmQuota` swept up the parent path chain |
| File screen blocks the wrong extensions, or nothing at all | Corrupted/misconfigured file group or template | `Get-FsrmFileGroup` / `Get-FsrmFileScreenTemplate` |
| Office `.xlsm`/`.xlsb` save fails with Access Denied on an unrelated file | `.tmp` blocked by an active file screen (Office's save-then-rename pattern) | `Get-FsrmFileScreen -Path <p> \| Select IncludeGroup` |
| No email notifications sent at all | SMTP server/recipient not configured or unreachable | `Get-FsrmSetting`, then `Send-FsrmTestEmail` |
| Only one email for a repeated block/threshold event | Default 60-minute per-type notification throttle (expected behavior) | Notification Limits tab / `Get-FsrmSetting` |
| Storage reports fail with little/no Event Log detail | Corrupted target volume for report output | `chkdsk <volume>: /scan` |
| File Screening Audit report is empty despite known blocked-save events | Auditing database recording never enabled | File Screen Audit tab checkbox / `Get-FsrmSetting` |
| Real-time classification isn't tagging newly modified files | USN Change Journal creation disabled on this volume/server | `HKLM\SYSTEM\CurrentControlSet\Services\SrmSvc\Settings` registry keys |
| FSRM role install fails with `CBS_E_SOURCE_MISSING` | Missing SxS source / .NET 3.5 prerequisite not present | `DISM /Online /Get-Features` + installation media SxS path |
| Robocopy of FSRM-managed shares fails with Error 1317 | Unresolvable SIDs in ACLs being copied with `/copy:datsou` | Switch to `/copy:datsu` (drop owner) |
| FSRM doesn't start on the secondary node of a clustered file server | Cluster resource/storage group misplacement, or offline/corrupted cluster disk | `Get-ClusterResource`, `chkdsk` on the shared disk |

---

## Validation Steps

1. **Service state.**
   ```powershell
   Get-Service SrmSvc | Select-Object Status, StartType
   ```
   Good: `Running` / `Automatic`. Bad: `Stopped`, or `Running` but restarting in a loop (check event timestamps for repeated start/stop pairs).

2. **Config store integrity.**
   ```powershell
   Test-Path "C:\System Volume Information\SRM\quota.xml"
   icacls "C:\System Volume Information\SRM\quota.xml"
   ```
   Good: file exists, ACL includes `NT AUTHORITY\SYSTEM:(F)` and `BUILTIN\Administrators:(F)`. Bad: missing entries, or the whole `SRM` folder missing (fresh install, not yet configured — different problem than corruption).

3. **NTFS confirmation on every path you're about to manage.**
   ```powershell
   Get-Volume | Select-Object DriveLetter, FileSystem
   ```
   Good: `NTFS`. Bad: `ReFS` — stop, this volume is permanently out of scope for FSRM.

4. **Quota/template consistency.**
   ```powershell
   Get-FsrmAutoQuota | Select-Object Path, Template, MatchesTemplate
   ```
   Good: `MatchesTemplate = True` everywhere you expect inheritance. Bad: `False` entries indicate stale derived quotas needing `-UpdateDerived`.

5. **SMTP path.**
   ```powershell
   Send-FsrmTestEmail -ToAddress "<test-recipient>"
   ```
   Good: email arrives within ~60 seconds. Bad: no delivery — treat as an SMTP relay/firewall problem, not an FSRM problem.

6. **Classification mode reality check.**
   ```powershell
   Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\SrmSvc\Settings" -ErrorAction SilentlyContinue |
     Select-Object SkipUSNCreationForSystem, SkipUSNCreationForVolumes
   ```
   Good: both absent/0 if real-time classification is expected. Bad: `SkipUSNCreationForSystem = 1` on a server where someone is expecting real-time tagging.

7. **Report output volume health.**
   ```powershell
   Get-FsrmStorageReport | Select-Object Name, LastRun, LastRunStatus
   ```
   Good: `LastRunStatus = Completed`. Bad: `Failed`/`Error` — correlate with a `chkdsk` on the report output volume.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Service & store health**
Confirm `SrmSvc` is running and stable (no crash loop). Confirm the config store exists, is intact, and has correct ACLs. This phase resolves the majority of "console won't open / service won't start" tickets before touching any actual quota or screen logic.

**Phase 2 — Volume eligibility**
Confirm the target volume is NTFS. This is a hard, non-negotiable prerequisite — do not spend time debugging quota behavior on a volume until this is confirmed, since no FSRM configuration change will ever make ReFS work.

**Phase 3 — Configuration correctness**
Walk the quota/template chain (`Get-FsrmQuotaTemplate` → `Get-FsrmAutoQuota` → `Get-FsrmQuota`) or the file screen chain (`Get-FsrmFileGroup` → `Get-FsrmFileScreenTemplate` → `Get-FsrmFileScreen` → `Get-FsrmFileScreenException`) to find where the actual configuration diverges from what's expected.

**Phase 4 — Inheritance & nesting**
For quota discrepancies specifically, always sweep the full parent path chain before concluding a number is "wrong" — nested quota inheritance is a documented design, and most "wrong number" tickets are this, not corruption.

**Phase 5 — Notification & reporting pipeline**
Test SMTP independently of any specific quota/screen event (`Send-FsrmTestEmail`). Check the audit-recording flag before troubling over an empty File Screening Audit report. Check target-volume health before troubling over report generation failures.

**Phase 6 — Classification & downstream jobs**
If real-time tagging isn't happening, check the USN Change Journal registry settings before assuming a classification rule is broken — many "classification doesn't work" tickets are actually "real-time classification was deliberately disabled and nobody documented it."

---

## Remediation Playbooks

<details><summary>Playbook 1 — Stand up FSRM quota + file screening on a new file server from scratch</summary>

1. Install the role service:
   ```powershell
   Install-WindowsFeature FS-Resource-Manager -IncludeManagementTools
   ```
2. Confirm the target volume(s) are NTFS (Layer 0 — non-negotiable):
   ```powershell
   Get-Volume | Select-Object DriveLetter, FileSystem
   ```
3. Configure global settings first (SMTP, admin recipient) so test emails work throughout setup:
   ```powershell
   Set-FsrmSetting -SmtpServer "<smtp.contoso.com>" -AdminEmailAddress "[email protected]" -FromEmailAddress "[email protected]"
   Send-FsrmTestEmail -ToAddress "[email protected]"
   ```
4. Create a quota template (e.g., 200 MB soft warning at 90%, hard cap at 100%):
   ```powershell
   $threshold90 = New-FsrmQuotaThreshold -Percentage 90 -Action (New-FsrmAction -Type Email -MailTo "[Admin Email]" -Subject "Quota warning" -Body "Approaching quota limit.")
   New-FsrmQuotaTemplate -Name "200MB User Home Hard Limit" -Description "Standard user home directory quota" -Size 200GB -Threshold @($threshold90)
   ```
5. Auto-apply it to the parent folder so all existing and future subfolders inherit it:
   ```powershell
   New-FsrmAutoQuota -Path "D:\UserHomes" -Template "200MB User Home Hard Limit"
   ```
6. Build a baseline file screen (e.g., block executables/media in user shares):
   ```powershell
   New-FsrmFileGroup -Name "Blocked Media" -IncludeExtension "*.mp3", "*.wav", "*.avi", "*.mp4"
   New-FsrmFileScreenTemplate -Name "Block Media" -IncludeGroup "Blocked Media" -Active
   New-FsrmFileScreen -Path "D:\UserHomes" -Template "Block Media"
   ```
7. Schedule a baseline storage report (e.g., weekly quota usage):
   ```powershell
   New-FsrmStorageReport -Name "Weekly Quota Usage" -ReportType QuotaUsage -Namespace "D:\UserHomes" -Schedule "Sunday 00:00"
   ```
8. Validate with `Get-FsrmQuota`, `Get-FsrmFileScreen`, and `Get-FsrmStorageReport` before declaring done.

**Rollback:** `Remove-FsrmAutoQuota -Path <p>`, `Remove-FsrmFileScreen -Path <p>`, `Remove-FsrmStorageReport -Name <n>` unwind each piece independently.

</details>

<details><summary>Playbook 2 — Recover a server where the FSRM config store is corrupted</summary>

Use when Fix 1 in `FSRM-B.md` (permissions repair) doesn't resolve the issue and the XML itself is confirmed corrupted.

1. Stop the service and back up everything in the SRM config folder before deleting anything:
   ```powershell
   Stop-Service SrmSvc -Force
   $backupPath = "$env:TEMP\SRM-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
   New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
   Copy-Item "C:\System Volume Information\SRM\*.xml" $backupPath -Force
   ```
2. Remove only the specific corrupted file(s) identified from the event log's `parseURL` error — do not wipe the whole SRM folder if only `quota.xml` is implicated; `filescrn.xml`, `classification.xml`, and `storagereports.xml` may still be healthy.
   ```powershell
   Remove-Item "C:\System Volume Information\SRM\quota.xml" -Force
   Start-Service SrmSvc
   ```
3. FSRM regenerates a blank config for the removed file on next start. **All quotas defined in that file are now gone** — this is a full rebuild, not a repair, for that specific config domain.
4. Rebuild quotas from documentation, from a paired DR/secondary server's exported config, or from the backup XML if a working prior version exists and can be identified:
   ```powershell
   # If you have a known-good export from another server or a prior backup:
   Copy-Item "$backupPath\quota.xml" "C:\System Volume Information\SRM\quota.xml" -Force
   Restart-Service SrmSvc
   ```
5. Validate every quota is present and matches expected values before considering this closed — a partial silent restore is worse than an obvious total loss because it produces inconsistent enforcement across folders.

**Rollback:** the pre-repair backup in `$backupPath` is the rollback path if the "fix" makes things worse.

</details>

<details><summary>Playbook 3 — Migrate an FSRM-managed file server's data off a volume that turns out to be ReFS</summary>

Applies when a "quota won't apply" ticket resolves to Layer 0 — ReFS was never a supported FSRM target and no configuration change will fix it.

1. Confirm the volume is genuinely ReFS and this isn't a misread:
   ```powershell
   Get-Volume -DriveLetter <Letter> | Select-Object FileSystem, FileSystemLabel
   ```
2. Provision a new NTFS volume of adequate size.
3. Migrate data with a tool that preserves ACLs and timestamps (Robocopy, not Explorer copy):
   ```powershell
   robocopy "<ReFSSourcePath>" "<NTFSDestinationPath>" /E /COPYALL /DCOPY:DAT /R:2 /W:5 /LOG:"C:\Migration\fsrm-refs-migration.log"
   ```
4. Re-point shares to the new NTFS location (update SMB share paths, DFS namespace targets if applicable — see `DFS/Troubleshooting/Namespace/Namespace-A.md`).
5. Recreate FSRM quotas/screens on the new NTFS volume — none of the prior FSRM configuration transfers automatically since it never existed for this path in the first place.
6. Decommission or repurpose the old ReFS volume once migration is validated and a rollback window has passed.

**Rollback:** keep the original ReFS volume read-only and untouched until the new NTFS volume has been in production long enough to confirm no data was missed.

</details>

<details><summary>Playbook 4 — Full fleet-wide FSRM audit sweep (multiple file servers)</summary>

Use for an MSP-wide health check across every managed file server, referencing the companion script.

1. Run `Scripts/Get-FSRMAudit.ps1` against each file server (or remotely via `-ComputerName` if the script is extended for remoting — v1 is designed to run locally per server via a loop from a management host).
2. Aggregate findings: service state, config store integrity, NTFS-vs-ReFS violations, stale auto-apply quotas (`MatchesTemplate = False`), SMTP test failures, and audit-recording state.
3. Prioritize by client-facing impact: a crashed `SrmSvc` (nothing enforced) outranks a stale template mismatch (still enforcing, just outdated numbers).
4. File one remediation ticket per server, referencing the specific Fix # from `FSRM-B.md` that applies.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects FSRM diagnostic evidence for escalation to Microsoft Support or internal engineering.
#>

$out = "C:\Temp\FSRM-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-Service SrmSvc | Select-Object Status, StartType, DisplayName |
  Export-Csv "$out\service-state.csv" -NoTypeInformation

Get-Volume | Select-Object DriveLetter, FileSystem, FileSystemLabel, SizeRemaining |
  Export-Csv "$out\volumes.csv" -NoTypeInformation

Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='SRMSVC'} -MaxEvents 200 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message |
  Export-Csv "$out\srmsvc-events.csv" -NoTypeInformation

icacls "C:\System Volume Information\SRM\quota.xml" 2>&1 | Out-File "$out\quota-xml-acl.txt"
icacls "C:\System Volume Information\SRM\filescrn.xml" 2>&1 | Out-File "$out\filescrn-xml-acl.txt"

Get-FsrmQuota -ErrorAction SilentlyContinue | Select-Object Path, Size, Usage, Template, MatchesTemplate, Disabled |
  Export-Csv "$out\quotas.csv" -NoTypeInformation

Get-FsrmAutoQuota -ErrorAction SilentlyContinue | Select-Object Path, Template |
  Export-Csv "$out\autoquotas.csv" -NoTypeInformation

Get-FsrmFileScreen -ErrorAction SilentlyContinue | Select-Object Path, Template, IncludeGroup |
  Export-Csv "$out\filescreens.csv" -NoTypeInformation

Get-FsrmStorageReport -ErrorAction SilentlyContinue | Select-Object Name, LastRun, LastRunStatus |
  Export-Csv "$out\storagereports.csv" -NoTypeInformation

Get-FsrmSetting -ErrorAction SilentlyContinue |
  Select-Object SmtpServer, AdminEmailAddress, FromEmailAddress |
  Export-Csv "$out\fsrmsettings.csv" -NoTypeInformation

Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\SrmSvc\Settings" -ErrorAction SilentlyContinue |
  Select-Object SkipUSNCreationForSystem, SkipUSNCreationForVolumes |
  Out-File "$out\usn-journal-config.txt"

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence pack: $out.zip"
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-Service SrmSvc` | Check FSRM service status |
| `Get-FsrmQuota -Path <p>` | Inspect a specific quota (size, usage, template match) |
| `Get-FsrmAutoQuota` | List all auto-apply quotas and their template bindings |
| `Set-FsrmAutoQuota -Path <p> -Template <t> -UpdateDerived` | Push current template settings to an existing derived quota |
| `Update-FsrmQuota -Path <p>` | Force a fresh usage rescan on a path |
| `Get-FsrmQuotaTemplate -Name <t>` | Inspect a quota template's configured limits |
| `Get-FsrmFileGroup -Name <g>` | List extensions in a file group |
| `Get-FsrmFileScreen -Path <p>` | Inspect the active file screen on a path |
| `New-FsrmFileScreenException -Path <p> -IncludeGroup <g>` | Carve out an allow exception on a subfolder |
| `Get-FsrmClassification` | Check status of a running classification pass |
| `Start-FsrmClassification` | Kick off a manual classification sweep |
| `Get-FsrmFileManagementJob` | List configured file management jobs |
| `Get-FsrmStorageReport` | List report tasks and their last-run status |
| `Start-FsrmStorageReport -Name <n>` | Run a storage report on demand |
| `Send-FsrmTestEmail -ToAddress <addr>` | Validate the SMTP notification path independently |
| `Get-FsrmSetting` | Dump global FSRM options (SMTP, audit recording, notification limits) |
| `winmgmt /verifyrepository` / `/salvagerepository` | Diagnose/repair the WMI repository FSRM's console and cmdlets depend on |
| `regsvr32 /i srmsvc.dll` | Reregister the FSRM service COM component |
| `Install-WindowsFeature FS-Resource-Manager -IncludeManagementTools` | Install the FSRM role service |

---

## 🎓 Learning Pointers

- FSRM's ReFS incompatibility is architectural, not a missing feature — plan file server volume formats around this before deployment, not after a quota ticket surfaces it. [FSRM overview](https://learn.microsoft.com/en-us/windows-server/storage/fsrm/fsrm-overview).
- Quota templates are intentionally decoupled from already-derived quotas — treat every template edit as requiring an explicit propagation step, and build that into your change process rather than assuming "Save" is enough. [Quota Management](https://learn.microsoft.com/en-us/windows-server/storage/fsrm/quota-management).
- The USN Change Journal trade-off (`SkipUSNCreationForSystem`/`SkipUSNCreationForVolumes`) is a real, documented lever for balancing disk space against real-time classification — know it exists before troubleshooting "classification doesn't run in real time" as if it were a fault. [FSRM overview — What's New](https://learn.microsoft.com/en-us/windows-server/storage/fsrm/fsrm-overview#whats-new).
- Nested quota inheritance is the single most common source of "the numbers don't add up" tickets in FSRM environments — internalize `View Quotas Affecting Folder` (or its `Get-FsrmQuota` scripted equivalent) as a first-response habit, not a last resort. [Troubleshoot FSRM](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/troubleshoot-file-server-resource-manager).
- The config store's tight ACL (SYSTEM + local Administrators only on `System Volume Information\SRM`) is a defense-in-depth design, not an accident — any permissions "cleanup" script that touches `System Volume Information` broadly is a latent FSRM outage waiting to happen.
- For consolidated MSP-wide health checks across many file servers at once, use `Scripts/Get-FSRMAudit.ps1` rather than manually walking each server through this runbook.
