# WMIC Removal from Windows — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why WMIC is going away, what actually depends on it, and how to migrate durably.

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

**In scope:**
- The Windows Management Instrumentation Command-line (WMIC, `wmic.exe`) utility's deprecation and full removal timeline, per Microsoft's official KB5067470
- The distinction between WMIC (a thin CLI wrapper, being removed) and WMI (the underlying management infrastructure, permanently staying)
- Practical migration from WMIC syntax to PowerShell CIM cmdlets and programmatic (.NET/COM) alternatives
- Fleet-level discovery of WMIC dependencies (scripts, scheduled tasks, GPO logon scripts, third-party/RMM agents) ahead of the 2026 hard-removal feature update

**Out of scope:**
- General WMI repository corruption/health troubleshooting (`winmgmt /verifyrepository`, `/salvagerepository`) except where needed to distinguish it from a WMIC-removal symptom
- WMI security/DCOM hardening (namespace ACLs, WinRM-vs-DCOM transport) — a related but separate topic
- Non-Windows/cross-platform CIM implementations (Open Management Infrastructure on Linux, etc.)

**Assumptions:**
- Reader has local admin or GPO-edit rights, and basic PowerShell scripting familiarity
- Target environment includes a mix of Windows 11 client and Windows Server versions on varying update cadences
- **Source-confidence note:** every fact in this runbook — the deprecation timeline (2016/2021/2022/2024/2025/2026), the "no Feature on Demand after full removal" detail, the specific `wmic path win32_process get Name` → `Get-CimInstance Win32_Process | Select-Object Name` translation example, and the explicit confirmation that WMI itself is unaffected — is drawn directly from Microsoft's own official Support KB (KB5067470, originally published 2025-09-12, last revised 2026-02-13) and the companion Tech Community blog post. This is unusually well-documented and dated by Microsoft directly (not a third-party inference or a preview/roadmap item), so confidence in the facts below is high.

---

## How It Works

<details><summary>Full architecture</summary>

### WMIC vs. WMI: Two Different Things Being Conflated in Most Tickets

The single most important architectural fact, and the one most support tickets get wrong initially: **WMIC and WMI are not the same thing**, and only one of them is going away.

- **WMI (Windows Management Instrumentation)** is Microsoft's implementation of the DMTF's Common Information Model (CIM) — a management infrastructure exposing system information and control surfaces (processes, services, hardware, OS configuration, and thousands of other classes) through a standardized, queryable object model, accessible via COM/DCOM locally or remotely. WMI is a foundational Windows subsystem used by an enormous range of first- and third-party software (Group Policy, System Center, most RMM/monitoring tools, PowerShell itself). **WMI is not being removed, deprecated, or reduced in capability by this change in any way.**

- **WMIC (`wmic.exe`)** is a single, specific command-line *client* — a thin text-based wrapper that translates command-line syntax like `wmic path win32_process get Name` into the equivalent WMI query, executes it, and formats the tabular output. It was introduced as a convenience CLI in Windows XP/Server 2003 and has had no meaningful feature investment since. **This is the only thing being removed.**

Every capability WMIC ever exposed remains fully available through WMI's other client interfaces — it is a removal of one specific access method, not a removal of the underlying functionality.

### The Full Deprecation-to-Removal Timeline

| Year | Milestone | State |
|---|---|---|
| 2016 | Deprecated in Windows Server 2012 | Still functional, flagged as legacy |
| 2021 | Deprecated in Windows 10, version 21H2 | Still functional, flagged as legacy |
| 2022 | Windows 11, version 22H2 | Available as a Feature on Demand (FoD), preinstalled and enabled by default |
| 2024 | Windows 11, versions 23H2 and 24H2 | Disabled by default; still available to re-enable as a FoD |
| 2025 | Windows 11, version 25H2 upgrade | Removed if previously installed; still restorable as a FoD |
| 2026 | Next Windows 11 feature update | **Fully removed. No Feature on Demand restore path exists.** |

This is a deliberate, multi-year, publicly telegraphed deprecation curve — not a sudden removal. The 2026 step is qualitatively different from every prior step: it is the first point at which there is genuinely no supported way to get `wmic.exe` back on that machine.

### Why Microsoft Is Removing It: Security Hardening, Not Just Cleanup

Microsoft's stated rationale frames this explicitly as a security-hardening action: WMIC is a long-documented "living-off-the-land binary" (LOLBin) — a legitimate, pre-installed administrative tool that attackers and malware families have repeatedly abused for host reconnaissance, lateral movement staging, and defense evasion, precisely because it is trusted, signed, and present by default. Removing it from the default OS image closes off that abuse surface without removing any actual management capability, since PowerShell's CIM cmdlets and programmatic interfaces provide a full (in fact broader) superset of what WMIC could do — arguably a better security posture, since PowerShell's own logging/transcription/AMSI integration provides far more auditability than WMIC's plain-text invocation ever did.

### Syntax Translation Model

WMIC's grammar wraps WQL (WMI Query Language) queries and method calls in a terse, positional CLI syntax:

```
wmic <alias/path> [where <clause>] get <properties> [/format:<format>]
wmic <alias/path> [where <clause>] call <method>
```

PowerShell's CIM cmdlets expose the identical underlying WMI classes and methods directly as first-class PowerShell objects:

```powershell
Get-CimInstance -ClassName <ClassName> [-Filter <WQL-where-clause-without-WHERE-keyword>]
Invoke-CimMethod -InputObject <CimInstance> -MethodName <Method> [-Arguments <hashtable>]
```

Because the underlying WMI class names, property names, and method signatures are completely unchanged, the translation is almost always mechanical rather than requiring new research — the class `Win32_Process` and its `Name` property mean exactly the same thing to both `wmic path win32_process get Name` and `Get-CimInstance Win32_Process | Select-Object Name`. This is the single most reassuring fact to relay to a team dreading a large-scale migration.

### `Get-WmiObject` vs. `Get-CimInstance`: Which One to Actually Use

Two PowerShell cmdlet families can query WMI: the legacy `Get-WmiObject`/`Invoke-WmiMethod` family (DCOM-based, uses the older WMI-specific PowerShell provider) and the newer `Get-CimInstance`/`Invoke-CimMethod` family (WSMan/WinRM-based by default, part of the CIM cmdlets introduced in PowerShell 3.0, cross-platform-capable via Open Management Infrastructure). Microsoft's own guidance points to **CIM cmdlets as the modern, preferred replacement** — `Get-WmiObject` remains present in Windows PowerShell 5.1 for backward compatibility but is not present at all in PowerShell 7+, and is not receiving further investment. Any WMIC migration undertaken today should target `Get-CimInstance`/`Invoke-CimMethod`, not `Get-WmiObject`, to avoid a second migration later.

</details>

---

## Dependency Stack

```
Windows Management Instrumentation (WMI) — the underlying subsystem
   ALWAYS PRESENT, unaffected by this change, exposed via COM/DCOM
        │
   ┌────┴─────────────────────────────────────────┐
   │                                                │
WMIC (wmic.exe)                          Other WMI client interfaces
   BEING REMOVED (fully, 2026,                (unaffected, fully supported)
   no FoD restore after that point)               │
   │                                    ┌──────────┼──────────────┐
   Feature on Demand ("WMIC")      PowerShell CIM cmdlets   .NET / COM API
   package — installed by            (Get-CimInstance,      (System.Management,
   default through Win11 22H2,       Invoke-CimMethod)       raw WMI COM interfaces)
   disabled-by-default 23H2/24H2,         │
   removed-on-25H2-upgrade,          PowerShell 3.0+ (WSMan/
   fully gone after the 2026         WinRM-based by default)
   feature update
        │
Consumers that break when WMIC specifically is removed:
   - Batch files / .cmd / .bat scripts calling wmic.exe directly
   - PowerShell scripts that shell out to wmic.exe instead of using CIM cmdlets
   - GPO logon/startup/shutdown scripts referencing wmic
   - Scheduled Task actions with wmic.exe as the executable
   - Third-party RMM, monitoring, backup, or legacy AV agents that internally
     shell out to wmic.exe rather than using the WMI API directly
        │
Consumers UNAFFECTED (because they never depended on the wmic.exe binary):
   - PowerShell scripts already using Get-CimInstance / Get-WmiObject / Invoke-CimMethod
   - Group Policy itself (uses WMI filters via the WMI API, not wmic.exe)
   - System Center / most modern management tooling (uses WMI COM/DCOM directly)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Script/batch file suddenly errors with "'wmic' is not recognized..." | WMIC removed on this build (expected per timeline) | `Get-Command wmic.exe`, `Get-WindowsCapability -Online -Name "WMIC*"` |
| Scheduled task fails silently after an OS upgrade | Task action directly invokes `wmic.exe`, which is now gone | `Get-ScheduledTask` action inspection; Task Scheduler history/Event Viewer for the specific task |
| RMM/monitoring dashboard shows stale or missing inventory data after fleet upgrades | Agent internally shells to WMIC rather than using the WMI API | Check vendor release notes for WMIC-removal awareness; confirm agent version |
| `Get-CimInstance`/`Get-WmiObject` ALSO fail, not just `wmic.exe` | Not a WMIC-removal issue — underlying WMI service/repository problem | `Get-Service Winmgmt`; `winmgmt /verifyrepository` |
| Works on some machines, fails on others of the same script | Machines are on different builds/FoD states — some haven't crossed the removal line yet | `Get-ComputerInfo -Property OsBuildNumber` across the fleet; correlate with WMIC presence |
| GPO logon script fails for an entire OU simultaneously | The GPO script itself calls WMIC — a single fix remediates the whole OU | Inspect SYSVOL script content directly, not just individual machine state |
| A previously-working `Add-WindowsCapability -Online -Name "WMIC~~~~"` stopgap stops working | Machine has crossed into the fully-removed (2026 feature update) state — FoD restore is no longer possible at all | `Get-ComputerInfo -Property OsBuildNumber`; compare against the documented 2026 removal build |

---

## Validation Steps

**1. Confirm WMIC's actual current state on the machine:**
```powershell
Get-Command wmic.exe -ErrorAction SilentlyContinue
Get-WindowsCapability -Online -Name "WMIC*" | Select-Object Name, State
```

**2. Confirm OS build/version to place the machine correctly on the timeline:**
```powershell
Get-ComputerInfo -Property WindowsProductName, OsBuildNumber, WindowsVersion
```

**3. Confirm the underlying WMI subsystem is healthy (isolate WMIC-specific vs. WMI-wide issues):**
```powershell
Get-Service Winmgmt | Select-Object Status, StartType
Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object Caption, Version
```

**4. Enumerate every local WMIC dependency:**
```powershell
Get-ScheduledTask | ForEach-Object {
    $a = $_.Actions | Where-Object { $_.Execute -like "*wmic*" -or $_.Arguments -like "*wmic*" }
    if ($a) { [PSCustomObject]@{ Task = $_.TaskName; Path = $_.TaskPath } }
}
Get-ChildItem -Path "C:\Scripts","C:\ProgramData" -Include *.ps1,*.bat,*.cmd -Recurse -ErrorAction SilentlyContinue |
    Select-String -Pattern "wmic" -SimpleMatch
```

**5. Confirm a proposed PowerShell/CIM replacement produces equivalent output before deploying it:**
Run both the old WMIC command (on a machine that still has it) and the proposed `Get-CimInstance`/`Invoke-CimMethod` replacement side-by-side, and diff the output fields — property names carry over exactly, but default output formatting differs (WMIC's default tabular text vs. PowerShell object properties), which can break downstream parsing logic that expected WMIC's specific text layout.

---

## Troubleshooting Steps (by phase)

### Phase 1: Confirm This Is Actually a WMIC-Removal Issue
1. Confirm `wmic.exe` is genuinely absent (not just erroring for an unrelated reason like a permissions or PATH issue).
2. Confirm the underlying WMI service and `Get-CimInstance` work independently — if they don't either, this is a WMI health issue, not a removal issue, and this runbook does not apply.

### Phase 2: Inventory the Actual Dependency
1. Identify every specific script, scheduled task, GPO object, or third-party agent invoking `wmic.exe` on the affected machine.
2. Distinguish internally-authored dependencies (which you can fix directly) from third-party/vendor dependencies (which require vendor engagement, per Fix 3 in the -B.md runbook).

### Phase 3: Translate and Rewrite
1. For each WMIC command found, identify the underlying WMI class and property/method names (unchanged from WMIC to CIM).
2. Rewrite using `Get-CimInstance`/`Invoke-CimMethod` (not the legacy `Get-WmiObject`/`Invoke-WmiMethod`, which is itself a dead-end for PowerShell 7+ environments).
3. Validate output equivalence against the original WMIC output before replacing it in production, particularly for scripts with downstream text-parsing logic tied to WMIC's specific output formatting.

### Phase 4: Fleet-Wide Discovery and Sequencing
1. Run a fleet-wide scan (the companion `Get-WMICUsageAudit.ps1` script) to find every GPO logon script, scheduled task, and common script-directory reference to WMIC before the 2026 feature update reaches production rings.
2. Prioritize GPO-delivered scripts and centrally-deployed scheduled tasks — fixing one GPO script remediates every machine in its scope, versus fixing individual machine-level scripts one at a time.
3. Sequence remediation against your Windows Update/feature-update ring rollout schedule so fixes land ahead of the machines that will actually lose WMIC.

### Phase 5: Vendor and Third-Party Coordination
1. For any third-party software found shelling out to WMIC internally, check vendor release notes/KB articles for WMIC-removal-aware updates.
2. Track vendor remediation timelines against your own feature-update rollout plan; use the temporary FoD re-add (Fix 2 in -B.md) only as a bounded stopgap on pre-removal-line builds, never as a long-term dependency.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide WMIC dependency discovery and remediation tracking</summary>

```
1. Run Get-WMICUsageAudit.ps1 against representative machines across every OS build
   tier currently in your fleet (not just the oldest/soonest-to-upgrade tier — GPO
   scripts and scheduled tasks are usually identical across tiers).
2. Separately enumerate GPO SYSVOL scripts tenant/domain-wide (the script itself
   checks local script directories and scheduled tasks; SYSVOL policy scripts are
   best reviewed directly via \\<domain>\SYSVOL\<domain>\Policies\ or the Group
   Policy Management Console's script-policy settings).
3. Build a remediation backlog prioritized: GPO-delivered scripts first (widest
   blast radius per fix), then centrally-deployed scheduled tasks, then
   individually-scripted machine-level dependencies, then third-party/vendor
   dependencies (tracked separately against vendor timelines).
4. Sequence backlog completion against your organization's feature-update ring
   schedule so remediated scripts land ahead of, not behind, the machines that
   will lose WMIC.
```

**Verify:** re-run the discovery script periodically through the remediation window to confirm the WMIC-dependency count trends to zero ahead of the fleet's feature-update rollout.

**Rollback:** N/A — a discovery/tracking exercise, not a configuration change.

</details>

<details><summary>Playbook 2 — Bridging pattern for scripts that cannot be fully rewritten immediately</summary>

For legacy batch files where a full PowerShell rewrite isn't immediately feasible (e.g., owned by a team without PowerShell scripting capacity, or embedded in a larger unowned automation chain):

```batch
:: Instead of:
wmic path win32_process get Name,ProcessId

:: Bridge via inline PowerShell invocation from the same batch file:
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Select-Object Name,ProcessId"
```

This removes the hard `wmic.exe` dependency immediately (the batch file no longer breaks on WMIC removal) while deferring the full rewrite to PowerShell-native scripting. Microsoft's own migration guidance explicitly endorses this as a valid interim pattern, not just a hack.

**Verify:** confirm the bridged command produces output the surrounding batch logic can still parse — PowerShell's default object output differs from WMIC's plain-text tabular format, so downstream parsing may still need adjustment even with this bridge in place.

**Rollback:** revert to the original WMIC line on a still-eligible (pre-removal) machine if the bridge introduces a regression; this is not viable at all once the machine has fully lost WMIC.

</details>

<details><summary>Playbook 3 — Emergency stopgap immediately after an unplanned break (bounded, time-limited)</summary>

Use only when a critical, unplanned break is discovered on a machine that has NOT yet taken the full-removal 2026 feature update, and a proper rewrite cannot be completed before the business needs the dependent process working again.

```powershell
Get-WindowsCapability -Online -Name "WMIC*"
Add-WindowsCapability -Online -Name "WMIC~~~~"
```

Treat this as a dated exception with an explicit remediation deadline tied to that machine's next scheduled feature update — not a resolution. Log the stopgap and its expiry in your change/ticketing system so it isn't forgotten before the machine updates out from under it.

**Rollback:**
```powershell
Remove-WindowsCapability -Online -Name "WMIC~~~~"
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect WMIC removal / dependency evidence for escalation or planning.
.NOTES     Read-only. No configuration changes.
#>

$OutputDir = "C:\Temp\WMICRemoval-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. WMIC presence/state
Get-Command wmic.exe -ErrorAction SilentlyContinue | Out-File "$OutputDir\WMICCommand.txt"
Get-WindowsCapability -Online -Name "WMIC*" | Out-File "$OutputDir\WMICCapability.txt"

# 2. OS build/version
Get-ComputerInfo -Property WindowsProductName, OsBuildNumber, WindowsVersion |
    Out-File "$OutputDir\OSInfo.txt"

# 3. WMI service/health baseline (isolate WMIC-specific vs. WMI-wide issues)
Get-Service Winmgmt | Out-File "$OutputDir\WinmgmtService.txt"
Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\CimBaseline.txt"

# 4. Local scheduled tasks referencing WMIC
Get-ScheduledTask | ForEach-Object {
    $a = $_.Actions | Where-Object { $_.Execute -like "*wmic*" -or $_.Arguments -like "*wmic*" }
    if ($a) { [PSCustomObject]@{ Task = $_.TaskName; Path = $_.TaskPath; Action = $a.Execute } }
} | Out-File "$OutputDir\WMICScheduledTasks.txt"

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Check WMIC presence/state
Get-Command wmic.exe -ErrorAction SilentlyContinue
Get-WindowsCapability -Online -Name "WMIC*"

# Confirm OS build for timeline placement
Get-ComputerInfo -Property WindowsProductName, OsBuildNumber, WindowsVersion

# WMI service health baseline
Get-Service Winmgmt
Get-CimInstance -ClassName Win32_OperatingSystem

# Common WMIC → CIM translations
# wmic path win32_process get Name           -> Get-CimInstance Win32_Process | Select-Object Name
# wmic bios get serialnumber                 -> (Get-CimInstance Win32_BIOS).SerialNumber
# wmic process where name="x" call terminate -> Get-CimInstance Win32_Process -Filter "Name='x'" | Invoke-CimMethod -MethodName Terminate
# wmic logicaldisk get caption,freespace     -> Get-CimInstance Win32_LogicalDisk | Select-Object Caption, FreeSpace
# wmic qfe list                              -> Get-CimInstance Win32_QuickFixEngineering | Select-Object HotFixID, InstalledOn

# Temporary FoD re-add (pre-removal-line builds only, stopgap)
Add-WindowsCapability -Online -Name "WMIC~~~~"
Remove-WindowsCapability -Online -Name "WMIC~~~~"

# Bridge pattern from a batch file
:: powershell -NoProfile -Command "Get-CimInstance Win32_Process | Select-Object Name,ProcessId"
```

---

## 🎓 Learning Pointers

- **WMI and WMIC are architecturally distinct, and confusing them is the single most common misdiagnosis on this topic.** Lead every conversation about this removal — with clients, colleagues, or in a ticket — with that distinction: the management capability isn't going away, only one specific 20-plus-year-old CLI wrapper around it is. [WMIC removal from Windows — Microsoft Support (KB5067470)](https://support.microsoft.com/en-us/topic/windows-management-instrumentation-command-line-wmic-removal-from-windows-e9e83c7f-4992-477f-ba1d-96f694b8665d)

- **The 2026 removal is qualitatively different from every prior deprecation step** — it is the first point with no Feature on Demand restore path at all. Don't let a client (or your own team) treat this the way they treated the 2024 "disabled by default" step, where re-enabling was one command away; plan real rewrites, not reflexive re-adds.

- **Prefer `Get-CimInstance`/`Invoke-CimMethod` over the legacy `Get-WmiObject`/`Invoke-WmiMethod` family when rewriting** — the latter is Windows-PowerShell-5.1-only and entirely absent from PowerShell 7+, so writing new WMIC replacements against it just defers a second migration. [WMI in PowerShell — Microsoft Learn](https://learn.microsoft.com/powershell/scripting/learn/ps101/07-working-with-wmi?view=powershell-7.5)

- **Output format equivalence is not automatic.** Property and class names translate directly, but WMIC's plain-text tabular output and PowerShell's object output are structurally different — any downstream script that parsed WMIC's raw text output (rather than treating it as structured data) needs its parsing logic revisited alongside the command itself, not just a drop-in command swap.

- **GPO logon scripts and scheduled tasks are the highest-leverage remediation targets in any fleet**, because a single fix at the policy/task-definition level remediates every machine in scope, versus discovering and fixing the same break repeatedly on individual endpoints as the removal reaches them one update ring at a time.

- **This is explicitly framed by Microsoft as a security hardening action** (removing a documented living-off-the-land binary), which is useful context for explaining the "why now, why permanently" question to a client who assumes this is simply arbitrary tool churn. [WMI command line (WMIC) utility deprecation: Next steps — Microsoft Tech Community](https://techcommunity.microsoft.com/blog/windows-itpro-blog/wmi-command-line-wmic-utility-deprecation-next-steps/4039242)
