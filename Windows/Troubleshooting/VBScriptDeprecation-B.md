# VBScript Deprecation — Hotfix Runbook (Mode B: Ops)
> Fix or escalate a broken (or about-to-break) VBScript dependency in under 10 minutes — slmgr.vbs, OSPP.VBS, logon scripts, vendor installers, VBA `VBScript.RegExp`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

> **Source note (checked 2026-09-25):** Microsoft's three-phase plan (Windows IT Pro Blog, "VBScript deprecation: Timelines and next steps", May 2024) is still the governing timeline. **Phase 1 (now):** VBScript is a Feature on Demand (FOD), preinstalled and **enabled** by default on Windows 11 24H2+. **Phase 2 (~2027, date not published):** the FOD is **disabled by default**; admins can still turn it back on. **Phase 3 (TBD):** VBScript is removed and there's no fallback. In September 2026 Microsoft shipped the **OSLicense** PowerShell module as the `slmgr.vbs` replacement on Windows 11 (Windows IT Pro Blog, "Keep Windows activation automation working with PowerShell"). It's **not** in Windows Server 2025 or earlier. Nothing is broken by default today. If a VBScript dependency fails right now, someone has either removed the FOD or blocked `wscript`/`cscript` with ASR, AppLocker or WDAC.

Run these first:

```powershell
# 1. Is the VBScript FOD present and enabled on this device?
Get-WindowsCapability -Online -Name 'VBSCRIPT*' | Select-Object Name, State

# 2. Can the engine actually run? (Writes a temp .vbs, runs it with cscript, deletes it)
$t = Join-Path $env:TEMP 'vbs-probe.vbs'; 'WScript.Echo "VBS-OK"' | Set-Content $t -Encoding ASCII
cscript.exe //nologo $t; Remove-Item $t -Force

# 3. What has used VBScript on this device recently? (Deprecation telemetry, event 4096)
Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='VBScriptDeprecationAlert'; Id=4096 } -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, @{n='Msg';e={ ($_.Message -split "`n" | Select-Object -First 12) -join ' ' }}

# 4. Is the replacement for slmgr.vbs available yet?
Get-Module -ListAvailable -Name '*OSLicense*' | Select-Object Name, Version, Path
[System.Environment]::OSVersion.Version

# 5. Is something policy-blocking script hosts? (ASR "Block JS/VBS launching downloaded content", AppLocker)
Get-MpPreference | Select-Object -ExpandProperty AttackSurfaceReductionRules_Ids -ErrorAction SilentlyContinue
Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue | Select-Object -ExpandProperty RuleCollections | Where-Object { $_.RuleCollectionType -eq 'Script' }
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Capability `VBSCRIPT~~~~` = `Installed`, probe prints `VBS-OK` | Engine is healthy. The failure isn't the deprecation. Look at the script itself, ASR/AppLocker (row 5) or permissions |
| Capability = `NotPresent`, probe fails with "no script engine for file extension .vbs" | FOD removed by an admin, image build or hardening baseline. **Fix 1** (re-enable, stopgap), then **Fix 2/3** (migrate) |
| Event 4096 entries exist | You have live VBScript consumers. The event includes the process tree and call stack. Feed them into **Fix 5** (inventory) before Phase 2 |
| Failing thing is `slmgr.vbs` (activation, KMS, rearm) | **Fix 2** — OSLicense cmdlets (Win 11 with the Sept 2026 update). Server 2025 keeps using slmgr for now |
| Failing thing is `OSPP.VBS` (Office activation/licence status) | **Fix 3** — no full PowerShell replacement for Office activation yet. Keep the FOD enabled on these devices and escalate |
| Excel/Access macro fails at `New RegExp` or `CreateObject("VBScript.RegExp")` | **Fix 4** — update M365 Apps to 2508+ (RegExp is built into VBA), or keep the FOD enabled |
| Vendor installer or driver (e.g. AMD chipset installer) fails silently | **Fix 1** to unblock, then vendor escalation. Don't rewrite vendor code |
| ASR rule `d3e037e1-3eb8-44c8-a917-57927947596d` in Block mode | That ASR rule blocks JS/VBS from launching *downloaded* executables. It isn't the deprecation. See `Security/Defender/` ASR runbooks |

---

## Dependency Cascade

<details><summary>What must be true for a VBScript dependency to keep working</summary>

```
Windows 11 24H2+ / Server 2025 (VBScript shipped as a FOD, not inbox)
        │
        ├── FOD "VBSCRIPT~~~~" State = Installed ◄── Phase 2 (~2027) flips the default to disabled
        │        │                                  Phase 3 (TBD) removes it, no re-enable
        │        └── vbscript.dll registered (engine for .vbs, WSH, ASP Classic, VBScript.RegExp COM)
        │
        ├── Script host allowed to run
        │        ├── wscript.exe / cscript.exe not blocked by AppLocker/WDAC script rules
        │        └── ASR rules not blocking the specific behaviour
        │
        └── The consumer
                 ├── slmgr.vbs ─────────── replacement: OSLicense module (Win 11 Sept 2026+; NOT Server 2025)
                 ├── OSPP.VBS (Office) ─── replacement: none complete yet (keep FOD on)
                 ├── Printing_Admin_Scripts (prnmngr/prnport/prndrvr.vbs) ─ replacement: PrintManagement cmdlets
                 ├── winrm.vbs (winrm qc / winrm set) ─ replacement: Set-WSManQuickConfig / WSMan: drive
                 ├── GPO logon/startup .vbs, scheduled tasks, RMM jobs ─ replacement: PowerShell rewrite
                 ├── VBA "VBScript.RegExp" ── replacement: built-in VBA RegExp (M365 Apps 2508+)
                 └── Vendor installers/LOB apps ─ replacement: vendor fix only
```

Not affected: `Scripting.FileSystemObject` and `Scripting.Dictionary` (scrrun.dll). Microsoft's Office team confirmed no change to them (Microsoft 365 Developer Blog comments, Sept 2025). JScript is outside this deprecation.

</details>

---

## Diagnosis & Validation Flow

1. **Confirm the FOD state**
   ```powershell
   Get-WindowsCapability -Online -Name 'VBSCRIPT*'
   ```
   Expected (Phase 1): `Name : VBSCRIPT~~~~` / `State : Installed`.
   `NotPresent` means someone removed it. Check your image build, Intune remediation or hardening baseline before re-adding it.

2. **Prove the engine executes**
   ```powershell
   $t = Join-Path $env:TEMP 'vbs-probe.vbs'; 'WScript.Echo "VBS-OK"' | Set-Content $t -Encoding ASCII
   cscript.exe //nologo $t; $LASTEXITCODE; Remove-Item $t -Force
   ```
   Expected: `VBS-OK` and exit code `0`.
   "There is no script engine for file extension .vbs" means the FOD is missing. "Access is denied" or a silent block means AppLocker/WDAC; check `Microsoft-Windows-AppLocker/MSI and Script`.

3. **Identify the consumer from telemetry**
   ```powershell
   Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='VBScriptDeprecationAlert'; Id=4096 } -MaxEvents 50 |
       ForEach-Object { $_.Message } | Select-String -Pattern '\.vbs|\.exe' | Select-Object -First 30
   ```
   Expected: process names such as `cscript.exe`, `wscript.exe`, `msiexec.exe` or `EXCEL.EXE`, plus the script path.
   No events and a working probe means nothing on this device uses VBScript during normal operation.
   *Community sources disagree on the log location (Application vs Applications and Services Logs → Microsoft → Windows → Windows Script Host). If Application is empty, check the other.*

4. **For activation tickets, check OSLicense availability**
   ```powershell
   Get-Command -Module OSLicense -ErrorAction SilentlyContinue | Select-Object Name
   ```
   Expected on Windows 11 with the Sept 2026 cumulative update: `Get-OSLicenseInfo`, `Invoke-OSLicense`, `Get-KmsLicenseInfo`, `Set-KmsLicenseInfo`, `Invoke-KmsLicense`.
   Empty on Windows 11 means it isn't patched. Install the latest CU. Empty on Server 2025 is expected; keep using slmgr there.

5. **For VBA tickets, check the Office build**
   ```powershell
   (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue).VersionToReport
   ```
   Expected: `16.0.19127.20154` or later (Version 2508+) for built-in RegExp.
   An older build means macros using `VBScript.RegExp` break once the FOD is disabled.

---

## Common Fix Paths

<details><summary>Fix 1 — Re-enable the VBScript FOD (stopgap only)</summary>

Use this to unblock a business-critical dependency now. It stops working in Phase 3.

```powershell
# Requires elevation. Pulls from Windows Update unless a FOD source/WSUS policy says otherwise.
Add-WindowsCapability -Online -Name 'VBSCRIPT~~~~'
Get-WindowsCapability -Online -Name 'VBSCRIPT*' | Select-Object Name, State
```

If WSUS-managed devices fail with `0x800f0954`, enable "Download repair content and optional features directly from Windows Update instead of WSUS" (GPO: *Computer Configuration → Administrative Templates → System → Specify settings for optional component installation and component repair*), or point `-Source` at a mounted FOD ISO:

```powershell
Add-WindowsCapability -Online -Name 'VBSCRIPT~~~~' -Source '<D:\LanguagesAndOptionalFeatures>' -LimitAccess
```

**Rollback / reverse (disable to test readiness):**
```powershell
Remove-WindowsCapability -Online -Name 'VBSCRIPT~~~~'
```
Log a ticket with the dependency name and owner every time you re-enable. The goal is to shrink the list, not normalise it.
</details>

<details><summary>Fix 2 — Replace slmgr.vbs with the OSLicense module (Windows 11)</summary>

Run elevated. The cmdlets return objects with `Success`, `ErrorCode` (HRESULT) and `ErrorMessage`, so there's no text parsing.

| Task | slmgr.vbs | OSLicense |
|---|---|---|
| Status | `/dlv` | `Get-OSLicenseInfo` |
| All products | `/dlv all` | `Get-OSLicenseInfo -All` |
| Activate online | `/ato` | `Invoke-OSLicense -ActivateOnline` |
| Install key | `/ipk` | `Invoke-OSLicense -InstallProductKey '<key>'` |
| Uninstall key | `/upk` | `Invoke-OSLicense -UninstallProductKey` |
| Clear key from registry | `/cpky` | `Invoke-OSLicense -ClearProductKeyFromRegistry` |
| Rearm | `/rearm` | `Invoke-OSLicense -Rearm` |
| Set KMS host | `/skms host:1688` | `Set-KmsLicenseInfo -ServerName '<kmshost>' -Port 1688` |
| Clear KMS host | `/ckms` | `Invoke-KmsLicense -ClearServer` |
| KMS info | `/dlv` (partial) | `Get-KmsLicenseInfo` |

```powershell
$info = Get-OSLicenseInfo
$info | Select-Object Name, LicenseStatus, PartialProductKey, GracePeriodRemaining

if ($info.LicenseStatus -ne 'Licensed') {
    $r = Invoke-OSLicense -ActivateOnline
    if (-not $r.Success) { Write-Warning "Activation failed: $($r.ErrorMessage) (HRESULT $($r.ErrorCode))" }
}
```

Notes:
- Mapping per LazyAdmin (16 Sept 2026). Verify with `Get-Help <cmdlet> -Full` on your build before bulk rollout.
- Don't log the `ProductKey` property of `-InstallProductKey` results.
- **Not in WinPE.** Move activation out of the PE phase into a post-OOBE step.
- **Server 2025 and earlier:** no OSLicense. slmgr.vbs keeps working as long as the FOD is enabled. Leave server automation alone until Server vNext.
- No built-in remoting. Wrap in `Invoke-Command -ComputerName <pc> -ScriptBlock { Get-OSLicenseInfo }`.
</details>

<details><summary>Fix 3 — OSPP.VBS (Office volume/LTSC activation)</summary>

There's no full PowerShell replacement for Office activation yet. MVP reporting (Tech Community, Sept 2026) says Office LTSC 2024 ships a PowerShell script in the OSPP folder that can *check* licensing but can't *activate*.

```powershell
# Where OSPP lives
Get-ChildItem 'C:\Program Files\Microsoft Office\Office16\OSPP.VBS','C:\Program Files (x86)\Microsoft Office\Office16\OSPP.VBS' -ErrorAction SilentlyContinue
# Look for the new PowerShell companion script
Get-ChildItem 'C:\Program Files\Microsoft Office\Office16\*.ps1' -ErrorAction SilentlyContinue
```

Action:
1. Keep the VBScript FOD **enabled** on devices that need OSPP (Fix 1). Tag them in your RMM/Intune with a device category or group.
2. For Microsoft 365 Apps (subscription), OSPP is a diagnostics tool only. Use `M365/Apps/Deployment-UpdateChannels-B.md` for activation issues, not OSPP.
3. Escalate to Microsoft if an LTSC/volume estate has no supported activation path after Phase 2 lands.
</details>

<details><summary>Fix 4 — VBA macros using VBScript.RegExp</summary>

```powershell
# Update Click-to-Run Office to current build for the device's channel
& "$env:CommonProgramFiles\Microsoft Shared\ClickToRun\OfficeC2RClient.exe" /update user displaylevel=false forceappshutdown=false
```

- **M365 Apps 2508 (build 19127.20154)+:** RegExp is built into VBA. Early-bound `Dim r As RegExp` and late-bound `CreateObject("VBScript.RegExp")` both work even with the FOD disabled.
- **Older builds or perpetual/LTSC Office without the update:** late binding works only while the FOD is enabled. Early binding against the "Microsoft VBScript Regular Expressions 5.5" reference breaks when the FOD is gone.
- If `New RegExp` fails on a 2508+ build, run an Office **Quick Repair**. A community report shows `vbe7.dll` not refreshing until repair.
- Macros that shell out to `.vbs` files (`Shell "wscript ..."`) break in Phase 3 regardless of Office version. Rewrite them.
</details>

<details><summary>Fix 5 — Inventory before Phase 2 (fleet)</summary>

```powershell
# Local file scan (edit the paths)
Get-ChildItem -Path 'C:\Scripts','C:\ProgramData' -Recurse -Include *.vbs,*.wsf,*.ps1,*.cmd,*.bat -ErrorAction SilentlyContinue |
    Select-String -Pattern 'slmgr|ospp\.vbs|cscript|wscript|\.vbs\b|prnmngr|prnport|winrm\.vbs' |
    Select-Object Path, LineNumber, Line | Export-Csv "$env:TEMP\vbs-refs.csv" -NoTypeInformation

# SYSVOL logon/startup scripts (run from a domain-joined admin box)
Get-ChildItem "\\$env:USERDNSDOMAIN\SYSVOL\$env:USERDNSDOMAIN\Policies" -Recurse -Include *.vbs,*.wsf -ErrorAction SilentlyContinue |
    Select-Object FullName, LastWriteTime
```

For per-device telemetry, event reading and scheduled-task scanning, run `Windows/Scripts/Get-VBScriptDependencyAudit.ps1` (it works as an Intune Remediation detection script with `-Quiet`).
</details>

<details><summary>Fix 6 — Other inbox .vbs tools you'll meet</summary>

| Inbox script | PowerShell replacement |
|---|---|
| `prnmngr.vbs` (add/list/delete printers) | `Get-Printer`, `Add-Printer`, `Remove-Printer` |
| `prnport.vbs` | `Get-PrinterPort`, `Add-PrinterPort` |
| `prndrvr.vbs` | `Get-PrinterDriver`, `Add-PrinterDriver` |
| `prnqctl.vbs` (test page, pause/resume) | `Get-PrintJob`, `Suspend-PrintJob`, `Resume-PrintJob` |
| `winrm.vbs` (`winrm quickconfig`, `winrm set`) | `Set-WSManQuickConfig`, `Set-Item WSMan:\localhost\...` |
| `slmgr.vbs` | OSLicense (Fix 2) |

`winrm.cmd` wraps `winrm.vbs`, so `winrm qc` in build scripts is a VBScript dependency even though it doesn't look like one.
</details>

---

## Escalation Evidence

```
VBScript dependency escalation
------------------------------
Ticket #:                 <ticket>
Device / OS build:        <hostname> / <Get-ComputerInfo OsBuildNumber>
VBSCRIPT~~~~ FOD state:   <Installed | NotPresent>
Probe (cscript) result:   <VBS-OK | error text>
Consumer:                 <slmgr.vbs | OSPP.VBS | logon script path | vendor app + version | VBA workbook>
Event 4096 sample:        <paste process tree / call stack excerpt>
OSLicense available:      <Yes (version) | No>
Office build (if VBA):    <VersionToReport>
Blocking policy found:    <None | ASR rule id | AppLocker/WDAC rule>
Stopgap applied:          <FOD re-enabled on <date> | none>
Business impact:          <what stops working and for whom>
Owner for migration:      <name/team/vendor>
Audit CSV attached:       <Get-VBScriptDependencyAudit output path>
```

---

## 🎓 Learning Pointers

- The deprecation is about the **engine being off by default**, not the files being deleted. `slmgr.vbs` still sits in System32 during Phase 2. That's why failures will be confusing. See [VBScript deprecation: Timelines and next steps](https://techcommunity.microsoft.com/blog/windows-itpro-blog/vbscript-deprecation-timelines-and-next-steps/4148301).
- Event **4096 from `VBScriptDeprecationAlert`** is Microsoft's built-in inventory feed. Collect it centrally (WEF, Sentinel/Log Analytics, RMM) now so Phase 2 isn't a surprise. [ControlUp write-up](https://www.controlup.com/blog/preparing-for-vbscript-deprecation-gain-visibility-before-it-becomes-a-problem/) covers the fields.
- OSLicense is the first Microsoft-supplied replacement for an inbox VBScript tool. Read [Keep Windows activation automation working with PowerShell](https://techcommunity.microsoft.com/blog/windows-itpro-blog/keep-windows-activation-automation-working-with-powershell/4540459) and the [LazyAdmin mapping](https://lazyadmin.nl/powershell/microsoft-is-retiring-slmgr-vbs-heres-what-to-use-instead/).
- For Office macros, [Prepare your VBA projects for VBScript deprecation](https://devblogs.microsoft.com/microsoft365dev/how-to-prepare-vba-projects-for-vbscript-deprecation/) has the early/late binding compatibility tables.
- The same pattern played out with WMIC (`Windows/Troubleshooting/WMICRemoval-B.md`): FOD → off by default → gone. Use the same inventory-first approach.
- Karl-WE's (MVP) running [state-of-VBScript-deprecation post](https://techcommunity.microsoft.com/discussions/windowsserverinsiders/blog-windows-insiders---state-of-vbscript-deprecation---september-2026/4525768) lists inbox and third-party dependencies (AMD chipset installer, WSUS/IIS scripts, VAMT). Check it before blaming your own scripts.
