# File Server Resource Manager (FSRM) — Hotfix Runbook (Mode B: Ops)
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

Run these on the file server hosting FSRM (not a client). Requires local admin.

```powershell
# 1. Is the FSRM service even running?
Get-Service SrmSvc | Select-Object Status, StartType

# 2. Is this an NTFS volume? (FSRM cannot manage ReFS — this silently explains most "quota won't apply" tickets)
Get-Volume | Select-Object DriveLetter, FileSystem, FileSystemLabel

# 3. Recent SRMSVC errors/warnings (all FSRM events log under this source)
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='SRMSVC'; Level=2,3} -MaxEvents 25 |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap

# 4. Does the affected quota/screen actually exist and what does it show?
Get-FsrmQuota -Path "<FolderPath>" | Select-Object Path, Size, Usage, Description, Disabled, MatchesTemplate

# 5. Config store health — quota.xml permissions (root cause of most console/service failures)
icacls "$env:SystemDrive\System Volume Information\SRM\quota.xml" 2>&1
```

| Result | Interpretation |
|---|---|
| `SrmSvc` not `Running` | Service down — jump to [Fix 1](#fix-1) |
| Volume `FileSystem` = `ReFS` | Unsupported — FSRM cannot manage this volume at all, no fix exists, must migrate data to NTFS |
| SRMSVC events reference `quota.xml` parse/access errors | Corrupted or permission-locked config store — [Fix 1](#fix-1) |
| `Get-FsrmQuota` returns nothing for a path that should have one | Quota was never created here, or it's an auto-apply template mismatch — [Fix 2](#fix-2) |
| `Usage`/`Size` don't match what Explorer shows | Nested quota — a parent folder quota is more restrictive — [Fix 3](#fix-3) |
| `icacls` shows access denied or missing entries on `quota.xml` | Permissions broken on the config store — [Fix 1](#fix-1) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
NTFS volume (FSRM refuses ReFS entirely)
      │
      ▼
SrmSvc (FSRM/Storage Reports service) running
      │
      ▼
Config store readable/writable:
  %SystemDrive%\System Volume Information\SRM\*.xml
  (quota.xml, filescrn.xml, etc. — SYSTEM + local Administrators only)
      │
      ▼
WMI repository healthy (FSRM MMC snap-in and PowerShell both ride on WMI)
      │
      ├──► Quota Management (hard/soft limits, auto-apply, templates)
      ├──► File Screening (file groups → templates → screens → exceptions)
      ├──► File Classification Infrastructure ─── needs USN Change Journal
      │       (real-time classification only — disabled = scheduled-only classification)
      ├──► File Management Jobs (act on classified/aged files)
      └──► Storage Reports ─── needs a healthy, non-corrupt target volume to write output
```

Break any layer and everything above it fails in ways that look unrelated (e.g. a dead WMI repo makes quotas look "invisible" in the console even though `quota.xml` itself is fine).

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the service is up.**
   ```powershell
   Get-Service SrmSvc
   ```
   Expected: `Status = Running`, `StartType = Automatic`. If stopped, do not just start it blind — check event 2 below first, since a corrupted `quota.xml` will make it crash again seconds after starting.

2. **Pull the last 24h of SRMSVC events.**
   ```powershell
   Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='SRMSVC'; StartTime=(Get-Date).AddHours(-24)} |
     Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap
   ```
   Expected: routine informational entries only. `0xc00cee22` or `0xc00cee2d` (XMLReader::parseURL referencing quota.xml) means the config store is corrupted or locked — go to [Fix 1](#fix-1).

3. **Verify the volume is NTFS.**
   ```powershell
   (Get-Item "<FolderPath>").PSDrive | Get-Volume | Select-Object FileSystem
   ```
   Expected: `NTFS`. `ReFS` means stop here — FSRM will never manage this volume; the only path forward is migrating the data to an NTFS volume.

4. **Check whether the quota/screen exists and matches the template it claims to.**
   ```powershell
   Get-FsrmQuota -Path "<FolderPath>" | Select-Object Path, Template, MatchesTemplate, Size, Usage
   Get-FsrmAutoQuota -Path "<FolderPath>" -ErrorAction SilentlyContinue
   ```
   Expected: `MatchesTemplate = True` if this folder is supposed to inherit template settings. `False` means someone edited the template after the quota was applied and it was never refreshed — [Fix 2](#fix-2).

5. **If "Used"/"Available" numbers look wrong, check for a nested quota.**
   ```powershell
   Get-FsrmQuota | Where-Object { $_.Path -like "$(Split-Path "<FolderPath>")*" } |
     Select-Object Path, Size, Usage
   ```
   Expected: no other quota on a parent folder with a *smaller* limit. If one exists, that parent quota is the real ceiling — [Fix 3](#fix-3).

6. **If notifications aren't firing, test the SMTP path directly.**
   ```powershell
   Send-FsrmTestEmail -ToAddress "<[email protected]>"
   ```
   Expected: email arrives within a minute. Failure means SMTP config, not FSRM, is broken — [Fix 4](#fix-4).

7. **If storage reports fail silently, check the target volume for corruption.**
   ```powershell
   chkdsk <ReportVolumeLetter>:
   ```
   Expected: no errors. If chkdsk reports problems, run `chkdsk <Volume>: /scan` then `/spotfix` in a maintenance window before regenerating reports.

---
## Common Fix Paths

<details><summary>Fix 1 — FSRM console won't load / Access Denied (0x80070005) / service won't start / quota.xml parse errors</summary>

**Symptoms:** FSRM MMC snap-in hangs or throws Access Denied opening Quota Management; `SrmSvc` fails to start; Event Viewer shows `0xc00cee22` (unexpected error) or `0xc00cee2d` (`XMLReader::parseURL ... quota.xml`).

**Cause:** Broken NTFS permissions on the hidden config store, or a genuinely corrupted XML file.

```powershell
# 1. Stop the service before touching the files
Stop-Service SrmSvc -Force

# 2. Take ownership and repair permissions on the config store
takeown /f "C:\System Volume Information\SRM\quota.xml"
icacls "C:\System Volume Information\SRM\quota.xml" /grant administrators:F
attrib -s -h "C:\System Volume Information\SRM\quota.xml"

# 3. If the file is corrupted (not just a permissions issue), back it up then remove it —
#    FSRM will regenerate a blank one on next start, and you will need to reconfigure quotas
Copy-Item "C:\System Volume Information\SRM\quota.xml" "$env:TEMP\quota.xml.bak"
Remove-Item "C:\System Volume Information\SRM\quota.xml" -Force

# 4. Restart the service
Start-Service SrmSvc
Get-Service SrmSvc
```

**If the service still won't start**, the WMI repository backing FSRM's console/PowerShell interface may be damaged:

```powershell
winmgmt /verifyrepository
winmgmt /salvagerepository
net stop winmgmt
net start winmgmt
net stop srmsvc
net start srmsvc
```

**If WMI repair doesn't help**, reregister the FSRM service DLL:

```powershell
regsvr32 /i srmsvc.dll
```

**Rollback:** if you deleted `quota.xml`, restore `$env:TEMP\quota.xml.bak` and re-run Fix 1 steps 1–2 instead of step 3 if this turns out to be a pure permissions issue you already fixed.

</details>

<details><summary>Fix 2 — Quotas/file screens not updating, not visible, or only affecting new users</summary>

**Symptoms:** Editing a quota template doesn't change behavior on folders already using it; `Set-FsrmAutoQuota` errors; new file screens don't block anything on existing folders.

```powershell
# 1. Confirm this isn't a ReFS volume — FSRM only supports NTFS
Get-Volume -DriveLetter <Letter> | Select-Object FileSystem

# 2. Verify the template itself has the settings you expect
Get-FsrmQuotaTemplate -Name "<TemplateName>" | Select-Object Name, Description, Size, SoftLimit, Threshold

# 3. Push the current template settings down to every quota derived from it
Set-FsrmAutoQuota -Path "<FolderPath>" -Template "<TemplateName>" -UpdateDerived

# 4. For a bulk push to every folder using this template (not just one path):
#    In the FSRM console: Quota Templates → right-click template → Edit Template Properties →
#    make your change → on Save, choose "Apply template to all derived quotas"
#    (there is no direct PowerShell equivalent for the bulk console action; script it with a loop
#    over Get-FsrmAutoQuota | Where Template -eq "<TemplateName>" calling Set-FsrmAutoQuota -UpdateDerived)

# 5. Force a fresh quota usage rescan on a specific path if usage numbers look stale
Update-FsrmQuota -Path "<FolderPath>"
```

**If file screens are the problem** (wrong files blocked/allowed), rebuild from a known-good template rather than hand-editing:

```powershell
# Export working config from a healthy server, import here
Get-FsrmFileScreenTemplate | Export-Clixml "\\<goodserver>\share\filescreen-templates.xml"
# On the broken server:
Import-Clixml "\\<goodserver>\share\filescreen-templates.xml" | ForEach-Object {
    New-FsrmFileScreenTemplate -Name $_.Name -IncludeGroup $_.IncludeGroup -Active:$_.Active
}
```

**Rollback:** none needed — this fix only re-applies settings that are supposed to already be in effect.

</details>

<details><summary>Fix 3 — Quota "Used"/"Available" doesn't match the "Limit" you set (nested quota)</summary>

**Symptoms:** A subfolder shows a smaller "Available" number than its own quota limit implies. Classic case: 100 MB quota on a parent folder, 200 MB quota on each subfolder — every subfolder reports only the parent's remaining space.

```powershell
# Find every quota affecting a given path, from the target folder up through its parents
$target = "<FolderPath>"
Get-FsrmQuota | Where-Object { $target -like "$($_.Path)*" } | Select-Object Path, Size, Usage, SoftLimit
```

**This is not a bug** — it's how FSRM enforces nested quota inheritance. The fix is a design decision, not a technical repair:

- Remove the more restrictive parent-level quota if it was applied by mistake, **or**
- Raise the parent quota's limit to accommodate all children, **or**
- Convert the parent quota to soft (notify-only) if the intent was just visibility, not enforcement:
  ```powershell
  Set-FsrmQuota -Path "<ParentFolderPath>" -SoftLimit
  ```

**Rollback:** `Set-FsrmQuota -Path "<ParentFolderPath>" -SoftLimit:$false` to restore hard enforcement.

</details>

<details><summary>Fix 4 — No email notifications, or only one notification for a repeated event</summary>

**Symptoms A (no email at all):** Quota/screen thresholds are hit but nobody gets an email.

```powershell
# Check current SMTP config
Get-FsrmSetting | Select-Object SmtpServer, AdminEmailAddress, FromEmailAddress

# Set/correct it
Set-FsrmSetting -SmtpServer "<smtp.contoso.com>" -AdminEmailAddress "[email protected]" -FromEmailAddress "[email protected]"

# Send a live test — this is the fastest way to confirm the SMTP path actually works
Send-FsrmTestEmail -ToAddress "[email protected]"
```

**Symptoms B (only one email even though the block/threshold event repeated many times):** This is expected behavior, not a bug — FSRM throttles repeat notifications of the same type to one per 60 minutes by default.

```powershell
# View/adjust the notification throttle window (per notification type: e-mail, event log, command, report)
Get-FsrmSetting | Select-Object *Limit*
```
Adjust via FSRM console → **File Server Resource Manager Options → Notification Limits** tab (no dedicated single-cmdlet PowerShell override — it's part of the same `Set-FsrmSetting` global options surface; verify current values with `Get-FsrmSetting` first).

**Rollback:** none — this is a configuration fix, not a destructive change.

</details>

<details><summary>Fix 5 — Excel .xlsm save fails / "Access Denied" that isn't about the target file itself</summary>

**Symptoms:** Users can't save macro-enabled Office files (`.xlsm`, `.xlsb`, `.xlam`) to a screened share. Event log shows Access Denied but not for the file the user is actually trying to save.

**Cause:** Office saves via a temporary `.tmp` file first, then renames it. If the active File Screen's file group blocks `.tmp`, the save fails before the rename ever happens.

```powershell
# Find which file group on this screen includes .tmp
Get-FsrmFileScreen -Path "<SharePath>" | Select-Object -ExpandProperty IncludeGroup
Get-FsrmFileGroup -Name "<GroupName>" | Select-Object IncludeExtension

# Remove .tmp specifically (do NOT remove the whole group if it blocks other things intentionally)
Set-FsrmFileGroup -Name "<GroupName>" -IncludeExtension (
  (Get-FsrmFileGroup -Name "<GroupName>").IncludeExtension | Where-Object { $_ -ne '*.tmp' }
)
```

**Rollback:** re-add `*.tmp` to the group's `IncludeExtension` list if this was a deliberate screen and the real fix should be a screen **exception** on this one folder instead:
```powershell
New-FsrmFileScreenException -Path "<SharePath>" -IncludeGroup "<GroupName exceptions apply to>"
```

</details>

<details><summary>Fix 6 — Storage reports keep failing with little/no Event Log detail</summary>

**Symptoms:** Scheduled or on-demand storage reports fail silently or with a generic error, and SRMSVC events give almost no detail.

```powershell
# 1. Check the health of the volume the reports are written to (this is the documented root cause)
chkdsk <ReportOutputVolume>: /scan

# 2. If errors are found, schedule an offline repair
chkdsk <ReportOutputVolume>: /spotfix

# 3. Re-run the report after the volume is clean
Start-FsrmStorageReport -Name "<ReportTaskName>"
Get-FsrmStorageReport -Name "<ReportTaskName>" | Select-Object LastRun, LastRunStatus
```

**Rollback:** none — read-only diagnostic + standard filesystem repair.

</details>

<details><summary>Fix 7 — File Screening Audit report comes back empty</summary>

**Symptoms:** The File Screening Audit storage report runs successfully but contains no data even though users have been hitting blocked screens.

```powershell
# Confirm auditing is actually being recorded — this is off by default in some configs
Get-FsrmSetting | Select-Object *Audit*
```
In the FSRM console: **File Server Resource Manager Options → File Screen Audit** tab → confirm **Record file screening activity in the auditing database** is checked. There is no dedicated cmdlet flag for this setting outside the general options dialog — verify via `Get-FsrmSetting`, then toggle it in the console and regenerate the report.

**Rollback:** none — this only affects whether future events are logged, not existing data.

</details>

---
## Escalation Evidence

```
FSRM ESCALATION — <ServerName> — <DateTime>

Symptom: [quota not applying / screen blocking wrong files / no notifications / report failing / console won't load]
Affected path(s): <FolderPath / SharePath>
Volume file system: <NTFS / ReFS — from Get-Volume>
SrmSvc status: <Running / Stopped / CrashLooping — from Get-Service SrmSvc>

Get-FsrmQuota output for affected path:
<paste>

Last 10 SRMSVC events (Application log):
<paste Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='SRMSVC'} -MaxEvents 10>

quota.xml permission check (icacls output):
<paste>

Steps already tried:
<list Fix # attempted and result>

Business impact: <users blocked from saving / quota enforcement not working / compliance reporting broken>
```

---
## 🎓 Learning Pointers

- FSRM is NTFS-only — this single fact resolves a large share of "quota won't apply" tickets on volumes that turn out to be ReFS. See [FSRM overview](https://learn.microsoft.com/en-us/windows-server/storage/fsrm/fsrm-overview).
- The config store (`quota.xml`, `filescrn.xml` under `System Volume Information\SRM`) is the single point of failure for the whole console — permission corruption there explains most "Access Denied opening FSRM" and "service won't start" tickets simultaneously. See [FSRM troubleshooting guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/fsrm-troubleshooting-guidance).
- Nested quotas are a documented, intentional behavior, not a bug — always run "View Quotas Affecting Folder" (or the `Get-FsrmQuota` parent-path sweep in this runbook) before assuming a quota calculation is wrong. See [Troubleshoot FSRM](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/troubleshoot-file-server-resource-manager).
- The 60-minute default notification throttle is why a user hammering a blocked save only generates one email — don't mistake it for a broken notification pipeline.
- If you're chasing "why did this file get blocked" with no data in the File Screening Audit report, check the audit-recording checkbox before assuming the report itself is broken — an empty report and a broken report look identical from the outside.
- For the deep architecture — quota template inheritance, File Classification Infrastructure, and how File Management Jobs act on classified files — see `FSRM-A.md`.
