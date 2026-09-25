# VBScript Deprecation — Reference Runbook (Mode A: Deep Dive)
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

**In scope:** the Windows VBScript engine (`vbscript.dll`) and everything that loads it: `.vbs`/`.wsf` through Windows Script Host (`wscript.exe`/`cscript.exe`), inbox admin scripts (`slmgr.vbs`, `winrm.vbs`, `Printing_Admin_Scripts\*.vbs`, IIS/WSUS legacy scripts), Office `OSPP.VBS`, VBA references to `VBScript.RegExp`, MSI custom actions of type VBScript, GPO logon/startup scripts, and third-party installers.

**Out of scope:** JScript/`jscript9.dll`, `Scripting.FileSystemObject`/`Scripting.Dictionary` (in `scrrun.dll`, which Microsoft says isn't changing), and VBScript in Internet Explorer (already disabled by default for IE in 2019 and gone with IE).

**Assumptions:** Windows 11 24H2+ clients and Windows Server 2025 hosts. Intune or GPO/RMM management. The admin can run elevated PowerShell 5.1.

**Source status (checked 2026-09-25):**

| Fact | Source | Confidence |
|---|---|---|
| Three-phase plan, Phase 2 "~2026 or 2027", Phase 3 TBD | Windows IT Pro Blog, May 2024; restated by Microsoft 365 Developer Blog, Sept 2025 | High (Microsoft) |
| Phase 2 now expected ~2027 / "fall 2027" | LazyAdmin (16 Sept 2026); MVP Tech Community post (updated Sept 2026) | Medium. No Microsoft date published |
| OSLicense module replaces slmgr.vbs on Windows 11 | Windows IT Pro Blog "Keep Windows activation automation working with PowerShell" (Sept 2026), via search summary and heise/4sysops coverage | High. Primary post not fetched in full this run |
| Shipping KB | Search summary of the Microsoft post: Aug 2026 preview **KB5120998** or later. LazyAdmin: Sept 2026 security update **KB5124008** | Medium. Consistent (preview → Patch Tuesday) but only the September KB number is from a full read |
| OSLicense not in Server 2025, planned for next Server release (vNext build 29651) | Microsoft post (search summary) + LazyAdmin | High |
| Event 4096 `VBScriptDeprecationAlert` | ControlUp (Apr 2026): Application log. Other community posts: Applications and Services Logs → Windows Script Host | Medium. Check both |
| VBA RegExp built in from Office 2508 (19127.20154) | Microsoft 365 Developer Blog, Sept 2025 | High |

---

## How It Works

<details><summary>Full architecture</summary>

### 1. From inbox component to Feature on Demand

Until Windows 11 23H2, `vbscript.dll` was an inbox OS component. It was always there and couldn't be removed. Starting with Windows 11 24H2 (and Server 2025) it was repackaged as a **Feature on Demand** capability, `VBSCRIPT~~~~`. That repackaging is the mechanism for the whole deprecation:

```
          Phase 1 (now)               Phase 2 (~2027)                Phase 3 (TBD)
   ┌──────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────┐
   │ FOD preinstalled     │   │ FOD present but          │   │ FOD not offered      │
   │ + enabled by default │──►│ DISABLED by default      │──►│ engine removed       │
   │ everything works     │   │ admin can Add-Windows-   │   │ no re-enable path    │
   │ event 4096 telemetry │   │ Capability to restore    │   │                      │
   └──────────────────────┘   └──────────────────────────┘   └──────────────────────┘
```

Being a FOD means three things:

- **State is per device** and can be changed with `Add-/Remove-WindowsCapability` or DISM. Hardening baselines can already remove it today, which is the main source of "Phase 2 breakage" tickets in 2026.
- **Re-adding it needs a source.** That's Windows Update by default. WSUS-only devices need the "optional component installation and component repair" policy or a FOD ISO, otherwise you get `0x800f0954`.
- **Feature updates may reset it.** Expect the Phase 2 feature update to apply the new default on upgrade. Treat any re-enable as something to re-verify after each feature update. (That's inferred from how the WMIC FOD behaved on the 25H2 upgrade, not something Microsoft has documented for VBScript.)

### 2. Who loads the engine

`vbscript.dll` is an Active Scripting engine. It's loaded in-process by any host that asks for the "VBScript" language:

| Host | Examples | What breaks when the engine is gone |
|---|---|---|
| Windows Script Host (`wscript.exe`, `cscript.exe`) | `.vbs`, `.wsf`, `slmgr.vbs`, `winrm.vbs`, printer scripts, GPO logon scripts | "There is no script engine for file extension '.vbs'" |
| COM clients via `CreateObject("VBScript.RegExp")` | VBA macros, legacy .NET/C++ apps, HTA | Error 429 "ActiveX component can't create object" |
| Windows Installer | MSI custom action type 6/38/54 (VBScript) | Installer fails with 1720/1721 or rolls back |
| `mshta.exe` | HTA front-ends, old vendor configurators | Script errors in the HTA |
| IIS (ASP Classic) | `.asp` pages | Server-side script errors. Microsoft hasn't said anything specific about ASP Classic (MVP complaint, Tech Community June 2026) |

The key point: **you can't find all consumers by searching for `.vbs` files.** MSI custom actions and COM `CreateObject` calls don't leave `.vbs` files on disk. That's why Microsoft added runtime telemetry.

### 3. Deprecation telemetry (event 4096)

Current Windows 11 builds write an event whenever the engine is loaded:

- **Provider:** `VBScriptDeprecationAlert`
- **Event ID:** 4096
- **Log:** Application (ControlUp). Some community posts say Applications and Services Logs → Microsoft → Windows → Windows Script Host. Query both.
- **Payload:** "VBScript is scheduled for deprecation…" plus the **process tree and call stack** that loaded the engine.

That payload is the most useful artefact you have. It catches MSI custom actions, VBA and vendor EXEs as well as `.vbs` files. Centralise it (Windows Event Forwarding, Azure Monitor Agent DCR, Sentinel, or your RMM) and rank by distinct process tree.

### 4. The OSLicense module (slmgr replacement)

`slmgr.vbs` is a ~145 KB VBScript wrapper over the Software Protection Platform (SPP) WMI classes (`SoftwareLicensingService`, `SoftwareLicensingProduct`). The OSLicense module wraps the same SPP layer with cmdlets:

```
 Get-OSLicenseInfo / Invoke-OSLicense / *-KmsLicense*
                 │
                 ▼
     SPP WMI provider (SoftwareLicensingProduct / Service)
                 │
                 ▼
     sppsvc (Software Protection service) ──► activation endpoints / KMS host / AD-BA
```

Because both sit on SPP, the licensing *state* is identical. You're only changing the client tool. Three design differences matter:

1. **Structured results.** `Success`, `Operation`, `ProductName`, `ErrorCode` (HRESULT), `ErrorMessage` and `RestartRequired` replace text in a dialog box.
2. **No remoting parameter.** Use `Invoke-Command`. `slmgr \\host` has no equivalent.
3. **Availability gap.** Windows 11 with the Aug/Sept 2026 update only. Not WinPE, not Server 2025. Mixed estates will run both tools for a year or more.

If you can't wait for OSLicense on a device, you can read status directly from SPP WMI. This works on any supported Windows with no VBScript:

```powershell
Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" |
    Select-Object Name, LicenseStatus, GracePeriodRemaining, PartialProductKey
# LicenseStatus: 0=Unlicensed 1=Licensed 2=OOBGrace 3=OOTGrace 4=NonGenuineGrace 5=Notification 6=ExtendedGrace
```

The ApplicationID `55c92734-…` identifies Windows. Office products use a different ApplicationID. That's the same filter `slmgr.vbs` uses internally.

### 5. Office: OSPP.VBS and VBA

- `OSPP.VBS` is Office's own `slmgr` equivalent for volume/LTSC activation (KMS/MAK) and licence inspection. MVP reporting says LTSC 2024 now ships a PowerShell script alongside it that can **inspect but not activate**. Until Microsoft ships a full replacement, devices running volume-licensed Office need the FOD kept on in Phase 2.
- **VBA RegExp.** From Microsoft 365 Apps Version 2508 (Build 19127.20154), `vbe7.dll` includes native `RegExp`, `Match`, `MatchCollection` and `SubMatches` classes. Late-bound `CreateObject("VBScript.RegExp")` resolves to the built-in classes on 2508+, so existing macros keep working after VBScript is disabled, **as long as Office is current**. Perpetual/LTSC builds weren't confirmed to have received this (reader comment on the Microsoft post, Sept 2025).

### 6. Why Phase 2 is the risky phase

In Phase 2 the files are still there, so `slmgr.vbs` still exists and `winrm qc` still resolves to `winrm.cmd`. Only the engine is off. Failures look like "the tool is broken" rather than "the tool is gone", and unattended callers (RMM, scheduled tasks, task sequences) often **swallow the WSH error** and report success. That's why the telemetry-driven inventory has to be done *before* Phase 2 reaches the fleet.

</details>

---

## Dependency Stack

```
Layer 6  Business process  ── activation compliance, printer mapping, logon drive maps, LOB reports
            │
Layer 5  Consumer           ── slmgr.vbs │ OSPP.VBS │ GPO .vbs │ RMM job │ MSI CA │ VBA macro │ vendor EXE
            │
Layer 4  Host               ── wscript/cscript │ msiexec │ mshta │ Office VBE │ IIS asp.dll
            │
Layer 3  Policy gates       ── AppLocker/WDAC script rules │ ASR rules │ SRP (legacy)
            │
Layer 2  Engine             ── vbscript.dll (FOD "VBSCRIPT~~~~")  ◄── Phase 2 off-by-default / Phase 3 removed
            │
Layer 1  Servicing          ── Windows Update / WSUS FOD source │ feature update resets │ image build/baselines
            │
Layer 0  OS                 ── Windows 11 24H2+ / Server 2025 (FOD-packaged)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "There is no script engine for file extension '.vbs'" | FOD removed/disabled | `Get-WindowsCapability -Online -Name VBSCRIPT*` |
| `slmgr /dlv` does nothing or shows no dialog; RMM activation job "succeeds" but device stays unlicensed | Engine off; the caller ignores the WSH exit code | Probe with cscript; check `SoftwareLicensingProduct` via CIM |
| `winrm quickconfig` fails in a build script | `winrm.cmd` → `winrm.vbs` needs the engine | Replace with `Set-WSManQuickConfig -Force` |
| Printer logon script using `prnmngr.vbs` fails | Engine off | Replace with `Add-Printer -ConnectionName` |
| Excel macro: runtime error 429 on `CreateObject("VBScript.RegExp")` | Office < 2508 and engine off | Office `VersionToReport` |
| Excel macro: compile error "User-defined type not defined" on `RegExp` | Early binding on Office < 2508, or `vbe7.dll` not refreshed | Update + Quick Repair |
| MSI install fails with 1720/1721 | VBScript custom action | `msiexec /i <pkg> /l*v log.txt`, search the log for "CustomAction" |
| AMD chipset driver install fails silently | Installer uses VBScript for platform checks (MVP report) | Event 4096 during install; re-enable FOD temporarily |
| Re-enable fails with `0x800f0954` | WSUS-managed, no FOD source | GPO "optional component installation" / `-Source` |
| FOD re-enabled but disabled again next month | Feature update reset, or a baseline/remediation removes it | Intune remediation history; `DISM /Online /Get-Capabilities` after update |
| Script blocked but FOD installed | AppLocker/WDAC script rules or ASR | `Microsoft-Windows-AppLocker/MSI and Script` log; `Get-MpPreference` |
| `Get-OSLicenseInfo` not recognised | Not Windows 11 with the Aug/Sept 2026 update, or it's Server/WinPE | OS build + installed KBs |

---

## Validation Steps

1. **FOD state**
   `Get-WindowsCapability -Online -Name 'VBSCRIPT*' | Select Name, State`
   Good: `VBSCRIPT~~~~  Installed`. Bad: `NotPresent` (removed) or no row (pre-24H2 inbox, meaning it's not FOD-packaged and can't be disabled this way).

2. **Engine executes**
   `cscript //nologo <temp probe.vbs>` → Good: `VBS-OK`, `$LASTEXITCODE` 0. Bad: engine error or AppLocker block event 8007 (script blocked) in `MSI and Script`.

3. **COM activation of RegExp** (the VBA dependency, tested without Office)
   ```powershell
   try { $re = New-Object -ComObject VBScript.RegExp; $re.Pattern = '\d+'; $re.Test('abc123') } catch { $_.Exception.Message }
   ```
   Good: `True`. Bad: "Class not registered" (80040154), meaning the engine is gone and only Office 2508+ built-in RegExp will work inside VBA.
   *Run this in Windows PowerShell 5.1. PowerShell 7 also supports `-ComObject` on Windows.*

4. **Telemetry flowing**
   `Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='VBScriptDeprecationAlert'} -MaxEvents 1`
   Good: returns an event (engine used, telemetry works) or "No events were found" on a clean device. Bad: "provider not found" on a build without the telemetry. Update the device.

5. **Replacement tooling present**
   `Get-Command Get-OSLicenseInfo -ErrorAction SilentlyContinue`
   Good on Win 11 patched: returns the cmdlet. Expected absent on Server 2025/WinPE.

6. **Activation state without slmgr**
   CIM query from How It Works §4. Good: `LicenseStatus = 1`.

---

## Troubleshooting Steps (by phase)

### Phase A — Is it the deprecation at all?
1. Run Validation 1–2. If the engine works, stop. The problem is the script, its permissions or a policy gate (Layer 3).
2. Check for a policy gate: AppLocker `MSI and Script` log (8006 would-block in audit mode, 8007 blocked), WDAC CodeIntegrity events (3077), Defender ASR events (1121 block) in `Microsoft-Windows-Windows Defender/Operational`.

### Phase B — Why is the engine missing?
1. `Get-WindowsCapability` history: check `C:\Windows\Logs\CBS\CBS.log` for `VBSCRIPT` remove operations and their timestamps.
2. Check Intune: Devices → Scripts and remediations, for anything calling `Remove-WindowsCapability`. Also security baselines/hardening packs (CIS L2 and several vendor baselines remove it).
3. Check the image: `DISM /Image:<mount> /Get-Capabilities | findstr VBSCRIPT` on the reference WIM.

### Phase C — Who needs it?
1. Pull event 4096 from the device and group by process tree.
2. Scan scheduled tasks, GPO scripts (SYSVOL), `Run` keys and local script folders (the audit script does all four).
3. For MSI failures, a verbose log names the failing custom action. Check `CustomAction` table type via Orca if needed.

### Phase D — Decide: restore, replace or escalate
- **Inbox tool with a replacement** (slmgr, printer scripts, winrm.vbs): replace.
- **Inbox tool without one** (OSPP activation): restore FOD on a tagged device group and escalate to Microsoft.
- **Your own scripts:** rewrite in PowerShell.
- **Vendor code:** restore FOD for that device group and open a vendor case with the 4096 call stack.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Fleet readiness assessment (Intune Remediation, detection-only)</summary>

1. Deploy `Windows/Scripts/Get-VBScriptDependencyAudit.ps1 -Quiet` as the **detection** script of an Intune Remediation with **no remediation script**. Run it as System, 64-bit, daily.
2. Exit code 1 = device has VBScript consumers (event 4096 in the look-back window or file/task references). Exit 0 = clean.
3. Export the Remediation results (the script's single-line STDOUT summary lands in "Pre-remediation detection output").
4. Rank consumers by device count and assign an owner to each.

No changes are made. Safe to run in production.
</details>

<details><summary>Playbook 2 — Controlled disable pilot (simulate Phase 2 early)</summary>

Do this on a **pilot ring** of devices that are clean in Playbook 1.

```powershell
# Detection (Intune Remediation): non-compliant if VBScript is still installed
$c = Get-WindowsCapability -Online -Name 'VBSCRIPT~~~~'
if ($c.State -eq 'Installed') { Write-Output 'VBScript installed'; exit 1 } else { exit 0 }
```
```powershell
# Remediation
Remove-WindowsCapability -Online -Name 'VBSCRIPT~~~~' | Out-Null
Write-Output 'VBScript FOD removed'
```

**Rollback:** swap the remediation for `Add-WindowsCapability -Online -Name 'VBSCRIPT~~~~'`, or remove the pilot group assignment and push Fix 1 from the B runbook. Needs a FOD source (see How It Works §1).

Watch helpdesk tickets and event logs for two weeks per ring before widening.
</details>

<details><summary>Playbook 3 — slmgr.vbs → OSLicense migration for RMM/Intune scripts</summary>

Wrap both tools so one script works across a mixed estate:

```powershell
function Get-WindowsActivationState {
    if (Get-Command Get-OSLicenseInfo -ErrorAction SilentlyContinue) {
        $i = Get-OSLicenseInfo
        [PSCustomObject]@{ Source='OSLicense'; Name=$i.Name; Status=[string]$i.LicenseStatus; GraceMinutes=$i.GracePeriodRemaining }
    } else {
        $p = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | Select-Object -First 1
        $map = @{0='Unlicensed';1='Licensed';2='OOBGrace';3='OOTGrace';4='NonGenuineGrace';5='Notification';6='ExtendedGrace'}
        [PSCustomObject]@{ Source='SPP-CIM'; Name=$p.Name; Status=$map[[int]$p.LicenseStatus]; GraceMinutes=$p.GracePeriodRemaining }
    }
}
Get-WindowsActivationState
```

For activation actions (not just status) on devices without OSLicense, you can call SPP WMI methods directly without VBScript:

```powershell
# Activate (equivalent of slmgr /ato) using SPP WMI, works on Server 2025
$p = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | Select-Object -First 1
Invoke-CimMethod -InputObject $p -MethodName Activate
# Install a key (slmgr /ipk)
$svc = Get-CimInstance SoftwareLicensingService
Invoke-CimMethod -InputObject $svc -MethodName InstallProductKey -Arguments @{ ProductKey = '<product-key>' }
Invoke-CimMethod -InputObject $svc -MethodName RefreshLicenseStatus
# Set KMS host (slmgr /skms)
Invoke-CimMethod -InputObject $svc -MethodName SetKeyManagementServiceMachine -Arguments @{ MachineName = '<kmshost>' }
Invoke-CimMethod -InputObject $svc -MethodName SetKeyManagementServicePort -Arguments @{ PortNumber = [uint32]1688 }
```

These are the same WMI methods `slmgr.vbs` calls. Test in a lab first. `InstallProductKey` changes the edition/channel and can't be undone without the old key.
</details>

<details><summary>Playbook 4 — GPO logon/startup scripts</summary>

1. Inventory:
   ```powershell
   Import-Module GroupPolicy
   Get-GPO -All | ForEach-Object {
       $gpo  = $_
       $path = "\\$env:USERDNSDOMAIN\SYSVOL\$env:USERDNSDOMAIN\Policies\{$($gpo.Id)}"
       Get-ChildItem $path -Recurse -Include *.vbs,*.wsf -ErrorAction SilentlyContinue |
           Select-Object @{n='GPO';e={$gpo.DisplayName}}, FullName, LastWriteTime
   } | Export-Csv "$env:TEMP\gpo-vbs-scripts.csv" -NoTypeInformation
   ```
2. Rewrite common patterns: drive maps → GPP Drive Maps or Intune; printer maps → GPP Printers / Universal Print; environment checks → PowerShell logon script.
3. Replace the script entry in the GPO. Keep the old `.vbs` in a `retired` folder for 90 days for rollback.
</details>

<details><summary>Playbook 5 — Office estate</summary>

1. Microsoft 365 Apps: make sure every channel is ≥ 2508. Check `VersionToReport` in the M365 Apps admin center inventory.
2. Volume/LTSC Office: tag devices that use OSPP for KMS/MAK. They stay in a "VBScript required" exclusion group for Phase 2 until Microsoft ships an activation replacement.
3. Macro owners: search shared drives for `VBScript_RegExp_55` references and `Shell "wscript`/`cscript` calls in exported VBA modules.
</details>

---

## Evidence Pack

```powershell
# Collect-VBScriptEvidence — read-only. Output: folder + zip on the desktop.
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) "VBS-Evidence-$env:COMPUTERNAME-$(Get-Date -f yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-ComputerInfo -Property OsName, OsVersion, OsBuildNumber, WindowsVersion | Out-File "$out\os.txt"
Get-WindowsCapability -Online -Name 'VBSCRIPT*' | Format-List | Out-File "$out\fod.txt"
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 15 | Out-File "$out\hotfix.txt"

$probe = Join-Path $env:TEMP 'vbs-probe.vbs'; 'WScript.Echo "VBS-OK"' | Set-Content $probe -Encoding ASCII
& cscript.exe //nologo $probe 2>&1 | Out-File "$out\probe.txt"; Remove-Item $probe -Force

foreach ($log in 'Application','Microsoft-Windows-Windows Script Host/Operational') {
    Get-WinEvent -FilterHashtable @{ LogName=$log; Id=4096 } -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -like '*VBScript*' -or $_.Message -like '*VBScript*' } |
        Select-Object TimeCreated, ProviderName, Message |
        Export-Csv "$out\event4096-$($log -replace '[\\/ ]','_').csv" -NoTypeInformation
}

Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/MSI and Script' -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Export-Csv "$out\applocker-script.csv" -NoTypeInformation

Get-Module -ListAvailable -Name '*OSLicense*' | Select-Object Name, Version, Path | Out-File "$out\oslicense.txt"
Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" |
    Select-Object Name, ApplicationID, LicenseStatus, GracePeriodRemaining | Out-File "$out\spp.txt"
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue) |
    Select-Object VersionToReport, CDNBaseUrl, Platform | Out-File "$out\office.txt"

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

For the full dependency scan (scheduled tasks, Run keys, script folders), add the CSV from `Windows/Scripts/Get-VBScriptDependencyAudit.ps1`.

---

## Command Cheat Sheet

| Purpose | Command |
|---|---|
| FOD state | `Get-WindowsCapability -Online -Name 'VBSCRIPT*'` |
| Re-enable | `Add-WindowsCapability -Online -Name 'VBSCRIPT~~~~'` |
| Disable (pilot) | `Remove-WindowsCapability -Online -Name 'VBSCRIPT~~~~'` |
| DISM equivalent | `DISM /Online /Get-CapabilityInfo /CapabilityName:VBSCRIPT~~~~` |
| Deprecation events | `Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='VBScriptDeprecationAlert';Id=4096}` |
| RegExp COM test | `New-Object -ComObject VBScript.RegExp` |
| OSLicense present? | `Get-Module -ListAvailable -Name '*OSLicense*'` |
| Activation status | `Get-OSLicenseInfo` (or the SPP CIM query) |
| Activate | `Invoke-OSLicense -ActivateOnline` |
| Set KMS | `Set-KmsLicenseInfo -ServerName '<kmshost>' -Port 1688` |
| winrm.vbs replacement | `Set-WSManQuickConfig -Force` |
| prnmngr replacement | `Add-Printer -ConnectionName '\\<server>\<queue>'` |
| Office build | `(Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration).VersionToReport` |
| AppLocker script blocks | `Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/MSI and Script' -MaxEvents 50` |
| Full audit | `.\Get-VBScriptDependencyAudit.ps1 -LookbackDays 30` |

---

## 🎓 Learning Pointers

- **FOD packaging is the mechanism.** Once you know VBScript is a capability, every question ("can I turn it back on?", "why did it come back after the upgrade?") becomes a servicing question. See [Features on Demand overview](https://learn.microsoft.com/windows-hardware/manufacture/desktop/features-on-demand-v2--capabilities) and [VBScript deprecation: Timelines and next steps](https://techcommunity.microsoft.com/blog/windows-itpro-blog/vbscript-deprecation-timelines-and-next-steps/4148301).
- **Replace the tool, not the platform.** `slmgr.vbs` was always a thin client over SPP WMI. OSLicense and the raw CIM methods reach the same service. [Keep Windows activation automation working with PowerShell](https://techcommunity.microsoft.com/blog/windows-itpro-blog/keep-windows-activation-automation-working-with-powershell/4540459) and [SoftwareLicensingService class](https://learn.microsoft.com/previous-versions/windows/desktop/sppwmi/softwarelicensingservice).
- **Telemetry beats grep.** MSI custom actions and COM `CreateObject` calls don't leave `.vbs` files. Event 4096's call stack is the only complete inventory. See the [ControlUp write-up](https://www.controlup.com/blog/preparing-for-vbscript-deprecation-gain-visibility-before-it-becomes-a-problem/).
- **Office is on a separate track.** VBA RegExp was fixed from the Office side (2508). OSPP activation hasn't been. Read [Prepare your VBA projects for VBScript deprecation](https://devblogs.microsoft.com/microsoft365dev/how-to-prepare-vba-projects-for-vbscript-deprecation/).
- **Compare with WMIC** (`Windows/Troubleshooting/WMICRemoval-A.md`). It followed the same FOD → default-off → removed path, and 25H2 showed that a feature update can apply the new default on upgrade.
- **Track third-party blockers** in the MVP-maintained [state-of-VBScript-deprecation thread](https://techcommunity.microsoft.com/discussions/windowsserverinsiders/blog-windows-insiders---state-of-vbscript-deprecation---september-2026/4525768): AMD chipset installer, WSUS/IIS scripts, VAMT, ConfigMgr OSD.
