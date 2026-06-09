# AppLocker — Reference Runbook (Mode A: Deep Dive)
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
- **Scope:** AppLocker policy authoring, enforcement, auditing, and break/fix on Windows 10/11 Enterprise and Server 2016+
- **Out of scope:** WDAC (Windows Defender Application Control) — see `WDAC-A.md`. AppLocker and WDAC can coexist but are managed separately.
- **Prerequisites:** AppLocker requires Enterprise/Education SKU or Server. It cannot be enforced on Home/Pro.
- **Delivery mechanism:** Group Policy (on-prem), Intune (MDM via OMA-URI or custom profile), or local policy (`secpol.msc`).
- **Service dependency:** The **Application Identity** service (`AppIDSvc`) must be running for enforcement.

---
## How It Works

<details><summary>Full architecture</summary>

AppLocker operates as a kernel-mode enforcement engine integrated into the Windows security subsystem. When a user attempts to execute a file, the sequence is:

```
User launches EXE/MSI/Script/DLL
          │
          ▼
  Application Identity Service (AppIDSvc)
          │
          ├─ Computes file identity hash (SHA256)
          ├─ Reads embedded publisher info (Authenticode)
          ├─ Resolves file path against rule conditions
          │
          ▼
  AppLocker Policy Engine (appid.sys — kernel driver)
          │
          ├─ Match against Publisher rules  (highest trust)
          ├─ Match against Path rules       (medium trust)
          ├─ Match against Hash rules       (lowest flexibility)
          │
          ▼
  Decision: ALLOW / DENY / AUDIT
          │
          ├─ ALLOW → execution continues
          ├─ DENY  → error 0x800700005 / "Access Denied"
          └─ AUDIT → execution continues, event logged (EID 8003/8006)
```

**Rule collections:**
| Collection | File types covered |
|---|---|
| Executable | .exe, .com |
| Windows Installer | .msi, .msp, .mst |
| Script | .ps1, .bat, .cmd, .vbs, .js |
| DLL | .dll, .ocx (disabled by default — high overhead) |
| Packaged apps | UWP/MSIX (.appx, .msix) |

**Rule condition priority:** Publisher > Path > Hash  
A file matching any Allow rule in a collection is allowed. If no Allow rule exists for a collection and AppLocker is in Enforce mode, ALL files in that collection are blocked — **including system binaries** unless default rules are in place.

**Audit vs Enforce mode** is set per rule collection, not globally. A common migration path: Audit all collections for 2-4 weeks → review EID 8003 logs → tune rules → switch to Enforce.

**Default rules** (auto-generated in GPMC):
- Allow Administrators: `%WINDIR%\*`, `%PROGRAMFILES%\*`, `%PROGRAMFILES(X86)%\*`
- Allow Everyone: `%WINDIR%\*` (Exe collection)
- Always enable default rules before enforcing to avoid locking out system processes.

</details>

---
## Dependency Stack

```
AppLocker Policy (GPO / Intune OMA-URI)
          │
          ▼
Group Policy CSE  ──or──  MDM PolicyCSP
          │
          ▼
  Registry: HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2
          │
          ▼
  Application Identity Service (AppIDSvc) [MUST be Running]
          │
          ▼
  appid.sys  (kernel-mode enforcement driver)
          │
          ▼
  File execution request (user-mode → kernel)
          │
          ▼
  AppLocker Event Log: Microsoft-Windows-AppLocker/EXE and DLL
                       Microsoft-Windows-AppLocker/MSI and Script
                       Microsoft-Windows-AppLocker/Packaged app-Deployment
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Legitimate app blocked, no policy change | New version changed publisher cert | `Get-AppLockerFileInformation` on new EXE; compare publisher |
| All scripts blocked after enforcing Script rules | Missing `%WINDIR%\*` default rule for Scripts | Check Script collection in policy |
| AppLocker not enforcing at all | `AppIDSvc` stopped or disabled | `Get-Service AppIDSvc` |
| Policy not applying via GPO | Slow GP processing, WMI filter, security filtering | `gpresult /h` for AppLocker-specific RSoP |
| EID 8003/8006 in Audit mode but no block | Normal — audit events fire on would-be blocks | Expected behaviour in Audit mode |
| DLL rules blocking MS Office | DLL rule collection enabled, publisher rule too narrow | Disable DLL collection or add `%PROGRAMFILES%\Microsoft Office\*` publisher rule |
| UWP/Store apps blocked | Packaged Apps collection enforced without default allow | Add "Allow Everyone: All signed packaged apps" rule |
| Policy appears in registry but no enforcement | AppIDSvc running but `appid.sys` not loaded | `sc query appid` — should be RUNNING |
| 0x800700005 on every EXE | No Exe Allow rules defined, enforcement on | Missing default Exe rules |

---
## Validation Steps

**1. Confirm AppIDSvc is running**
```powershell
Get-Service AppIDSvc | Select-Object Name, Status, StartType
```
Expected: `Status: Running`, `StartType: Automatic`  
Bad: `Status: Stopped` → AppLocker will not enforce. Fix: `Start-Service AppIDSvc; Set-Service AppIDSvc -StartupType Automatic`

**2. Check policy is present in registry**
```powershell
Get-ChildItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2' -ErrorAction SilentlyContinue |
    Select-Object Name, @{n='RuleCount';e={(Get-ChildItem $_.PSPath).Count}}
```
Expected: `Exe`, `Script`, `Msi`, `Appx` sub-keys with rule counts > 0  
Bad: No keys → policy hasn't applied. Run `gpupdate /force` or re-push Intune profile.

**3. Verify enforcement mode per collection**
```powershell
$collections = @('Exe','Script','Msi','Appx','Dll')
foreach ($col in $collections) {
    $path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2\$col"
    if (Test-Path $path) {
        $val = (Get-ItemProperty $path -Name EnforcementMode -EA SilentlyContinue).EnforcementMode
        $mode = switch ($val) { 0 {'Not Configured'} 1 {'Enforce'} 2 {'Audit'} default {'Unknown'} }
        Write-Host "$col : $mode"
    } else { Write-Host "$col : Not present" }
}
```
Expected: Collections you want enforced show `Enforce`; others show `Audit` or `Not present`.

**4. Test file against effective policy**
```powershell
Get-AppLockerPolicy -Effective | Test-AppLockerPolicy -Path "C:\Path\To\App.exe" -User Everyone
```
Expected: `PolicyDecision: Allowed`  
Bad: `PolicyDecision: DeniedByDefault` → no matching Allow rule. Add rule for this path/publisher.

**5. Review recent block/audit events**
```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 50 |
    Where-Object {$_.Id -in 8003,8004,8006,8007} |
    Select-Object TimeCreated, Id, Message |
    Format-List
```
Expected: EID 8002 (allowed), 8003 (audited — would block), 8004 (blocked), 8006 (audited script), 8007 (blocked script)

**6. Export and inspect effective policy**
```powershell
$policy = Get-AppLockerPolicy -Effective -Xml
$policy | Out-File C:\Temp\EffectiveAppLockerPolicy.xml
# Open in text editor or import to GPMC for visual review
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Policy Not Applying
1. Run `gpresult /h C:\Temp\gpreport.html` and open — search for AppLocker under Computer Configuration
2. Verify the GPO is linked to the correct OU and not filtered by security group
3. Check WMI filters on the GPO (`gpmc.msc` → GPO → Scope → WMI Filtering)
4. For Intune: Devices → Configuration profiles → check profile assignment and status per device
5. Force GP refresh: `gpupdate /force` (domain-joined) or trigger Intune sync
6. Reboot if AppIDSvc was just enabled for the first time

### Phase 2: AppIDSvc Issues
1. `Get-Service AppIDSvc` — if stopped, check Event Viewer → System for service errors
2. Common cause: AppIDSvc disabled via security hardening GPO. Check `Computer Configuration > Windows Settings > Security Settings > System Services`
3. Start and set to auto: `Set-Service AppIDSvc -StartupType Automatic; Start-Service AppIDSvc`
4. If AppIDSvc fails to start, check `appid.sys` is present: `Test-Path C:\Windows\System32\drivers\appid.sys`

### Phase 3: Rule Too Restrictive (Legitimate App Blocked)
1. Identify the blocked file from EID 8004 event — note exact path and publisher
2. Run: `Get-AppLockerFileInformation -Path "C:\Path\App.exe" | fl`
3. Choose rule type:
   - Publisher rule (preferred): allows all versions from a trusted publisher
   - Path rule: allows specific folder (risk: writeable paths can be exploited)
   - Hash rule: exact version only (breaks on app updates)
4. Create publisher rule in audit first, monitor 24-48h, then enforce

### Phase 4: Scripting Restrictions Blocking Admin Tools
1. PowerShell scripts blocked? Check Script collection enforcement mode
2. Default rule covers `%WINDIR%\System32\WindowsPowerShell\*` for Administrators
3. If running as a non-admin and using `%WINDIR%` path, that rule won't apply — must add explicit path/publisher rule for user-writable locations
4. PowerShell CLM (Constrained Language Mode) activates automatically when AppLocker enforces Script rules — test: `$ExecutionContext.SessionState.LanguageMode` should show `FullLanguage` for allowed scripts, `ConstrainedLanguage` otherwise

---
## Remediation Playbooks

<details><summary>Playbook 1 — Re-enable AppIDSvc and restore enforcement</summary>

**Scenario:** AppIDSvc is stopped/disabled; no enforcement occurring.

```powershell
# Restore AppIDSvc
Set-Service -Name AppIDSvc -StartupType Automatic
Start-Service -Name AppIDSvc

# Verify
$svc = Get-Service AppIDSvc
if ($svc.Status -eq 'Running') {
    Write-Host "[OK] AppIDSvc is running" -ForegroundColor Green
} else {
    Write-Host "[ERROR] AppIDSvc failed to start — check System Event Log" -ForegroundColor Red
}
```

**Rollback:** `Set-Service AppIDSvc -StartupType Disabled; Stop-Service AppIDSvc`  
**Note:** Stopping AppIDSvc disables ALL AppLocker enforcement — use only in emergencies.

</details>

<details><summary>Playbook 2 — Create publisher rule for blocked application</summary>

**Scenario:** Legitimate app (e.g., Slack, Chrome) blocked after AppLocker enforced.

```powershell
param(
    [string]$BlockedExePath = "C:\Program Files\Slack\slack.exe",
    [string]$PolicyOutputPath = "C:\Temp\NewAppLockerRule.xml"
)

# Get file info to build publisher rule
$fileInfo = Get-AppLockerFileInformation -Path $BlockedExePath
$fileInfo | Format-List

# Generate a publisher rule allowing all versions from same publisher
$rule = New-AppLockerPolicy -FileInformation $fileInfo -RuleType Publisher -User Everyone -RuleNamePrefix "Allow-Auto"
$rule.GetXml() | Out-File $PolicyOutputPath

Write-Host "[INFO] Review rule XML at $PolicyOutputPath before merging" -ForegroundColor Cyan
Write-Host "[INFO] To merge into local policy (test only):" -ForegroundColor Cyan
Write-Host "  Set-AppLockerPolicy -XmlPolicy $PolicyOutputPath -Merge" -ForegroundColor Yellow
```

**Rollback:** Rules are additive. To remove: `Get-AppLockerPolicy -Local -Xml` → edit XML → `Set-AppLockerPolicy -XmlPolicy <edited.xml>`  
**Best practice:** Deploy rule via GPO/Intune, not `Set-AppLockerPolicy -Local`, to avoid policy conflicts.

</details>

<details><summary>Playbook 3 — Audit mode sweep: identify all would-be blocks before enforcing</summary>

**Scenario:** Preparing to switch from Audit to Enforce. Need to identify all apps that would be blocked.

```powershell
# Collect all audit events (EID 8003 = exe/dll audit, EID 8006 = script audit)
$auditEvents = Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL',
                                      'Microsoft-Windows-AppLocker/MSI and Script' -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in 8003, 8006 }

$results = foreach ($e in $auditEvents) {
    $xml = [xml]$e.ToXml()
    [PSCustomObject]@{
        TimeCreated = $e.TimeCreated
        EventID     = $e.Id
        FilePath    = $xml.Event.EventData.Data | Where-Object {$_.Name -eq 'FilePath'} | Select-Object -ExpandProperty '#text'
        Publisher   = $xml.Event.EventData.Data | Where-Object {$_.Name -eq 'Publisher'} | Select-Object -ExpandProperty '#text'
        User        = $xml.Event.EventData.Data | Where-Object {$_.Name -eq 'User'} | Select-Object -ExpandProperty '#text'
    }
}

$results | Sort-Object FilePath -Unique | Export-Csv C:\Temp\AppLockerAuditReport.csv -NoTypeInformation
Write-Host "[OK] Audit report saved: C:\Temp\AppLockerAuditReport.csv — $($results.Count) events"
```

**Process:** Review CSV → identify patterns → create publisher/path rules → rerun audit → validate zero new events → switch to Enforce.

</details>

<details><summary>Playbook 4 — Switch collection from Audit to Enforce mode</summary>

**Scenario:** Audit sweep complete, ready to enforce Exe collection.

```powershell
# Export current effective policy
$currentXml = (Get-AppLockerPolicy -Effective -Xml)
$policyDoc = [xml]$currentXml

# Update EnforcementMode for Exe collection (0=NotConfigured, 1=Enabled/Enforce, 2=AuditOnly)
$exeRules = $policyDoc.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq 'Exe' }
if ($exeRules) {
    $exeRules.EnforcementMode = 'Enabled'
    Write-Host "[INFO] Exe collection set to Enforce mode"
}

$policyDoc.Save("C:\Temp\EnforcedAppLockerPolicy.xml")
Write-Host "[WARN] Review XML, then apply via GPO — do NOT use Set-AppLockerPolicy locally in production" -ForegroundColor Yellow
```

**Rollback:** Set `EnforcementMode` back to `AuditOnly` and redeploy GPO.  
**Warning:** Enforcing without complete default rules will block system binaries. Always test on a pilot OU first.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects full AppLocker diagnostic evidence for escalation.
.NOTES     Run as Administrator on the affected machine.
#>

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputDir = "C:\Temp\AppLockerEvidence_$timestamp"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# 1. AppIDSvc status
Get-Service AppIDSvc | Select-Object * | Export-Csv "$outputDir\AppIDSvc.csv" -NoTypeInformation

# 2. Effective policy XML
(Get-AppLockerPolicy -Effective -Xml) | Out-File "$outputDir\EffectivePolicy.xml"

# 3. Local policy XML (if any)
try { (Get-AppLockerPolicy -Local -Xml) | Out-File "$outputDir\LocalPolicy.xml" } catch {}

# 4. GPResult
gpresult /h "$outputDir\GPResult.html" /f 2>&1

# 5. Recent AppLocker events (all collections)
$logs = @(
    'Microsoft-Windows-AppLocker/EXE and DLL',
    'Microsoft-Windows-AppLocker/MSI and Script',
    'Microsoft-Windows-AppLocker/Packaged app-Deployment'
)
foreach ($log in $logs) {
    $safeName = $log -replace '[/\\]','-'
    Get-WinEvent -LogName $log -MaxEvents 500 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, Message |
        Export-Csv "$outputDir\Events-$safeName.csv" -NoTypeInformation
}

# 6. Registry dump
reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2" "$outputDir\SrpV2_Registry.reg" /y 2>&1

# 7. System info
Get-ComputerInfo | Select-Object OsName, OsVersion, CsName | Export-Csv "$outputDir\SystemInfo.csv" -NoTypeInformation

# 8. Zip it
Compress-Archive -Path $outputDir -DestinationPath "C:\Temp\AppLockerEvidence_$timestamp.zip" -Force
Write-Host "[OK] Evidence pack: C:\Temp\AppLockerEvidence_$timestamp.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Check AppIDSvc status | `Get-Service AppIDSvc` |
| Start AppIDSvc | `Start-Service AppIDSvc` |
| View effective policy | `Get-AppLockerPolicy -Effective` |
| Export effective policy XML | `Get-AppLockerPolicy -Effective -Xml \| Out-File policy.xml` |
| Test file against policy | `Get-AppLockerPolicy -Effective \| Test-AppLockerPolicy -Path "C:\app.exe"` |
| Get file publisher/hash info | `Get-AppLockerFileInformation -Path "C:\app.exe"` |
| Generate rule from file | `New-AppLockerPolicy -FileInformation (Get-AppLockerFileInformation -Path "C:\app.exe") -RuleType Publisher` |
| View block events (Exe) | `Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 50` |
| View block events (Script) | `Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/MSI and Script' -MaxEvents 50` |
| Force GP refresh | `gpupdate /force` |
| RSoP report | `gpresult /h C:\Temp\gpreport.html` |
| Check PowerShell language mode | `$ExecutionContext.SessionState.LanguageMode` |
| Check SrpV2 registry key | `Get-ChildItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2'` |

---
## 🎓 Learning Pointers

- **AppLocker vs WDAC:** AppLocker is user-mode policy evaluated by AppIDSvc; WDAC (Windows Defender Application Control) is kernel-enforced via CI.dll and significantly more tamper-resistant. For new deployments, Microsoft recommends WDAC. AppLocker remains useful for per-user/per-group rule targeting, which WDAC doesn't support natively. See [Compare WDAC and AppLocker](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/windows-defender-application-control/wdac-and-applocker-overview).

- **Constrained Language Mode (CLM):** When AppLocker enforces Script rules, PowerShell automatically drops to CLM for scripts that don't match an Allow rule. CLM blocks many attack techniques but also breaks legitimate automation. Test your scripts with `$ExecutionContext.SessionState.LanguageMode` before enforcing. See [PowerShell Constrained Language Mode](https://devblogs.microsoft.com/powershell/powershell-constrained-language-mode/).

- **DLL rule collection overhead:** Enabling DLL rules causes AppLocker to evaluate every DLL load, which can significantly impact performance on heavily loaded systems. Enable only after thorough testing. See [AppLocker DLL rules](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/applocker/dll-rules-in-applocker).

- **Path rules and writable locations:** Path rules using user-writable directories (e.g., `%APPDATA%\*`) are a common bypass — an attacker or malware drops an executable into that path. Prefer Publisher rules for trusted software and use Path rules only for controlled, admin-only directories. See [AppLocker rule condition types](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/applocker/understanding-applocker-rule-condition-types).

- **Intune delivery via OMA-URI:** AppLocker policies can be delivered via Intune using `./Vendor/MSFT/AppLocker/ApplicationLaunchRestrictions/...` OMA-URI paths. This is the preferred method for cloud-only environments. See [AppLocker CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/applocker-csp).

- **Event IDs to know:** 8002 (allowed), 8003 (audited-EXE), 8004 (blocked-EXE), 8005 (audited-MSI), 8006 (audited-Script), 8007 (blocked-Script), 8020 (audited-Packaged), 8021 (blocked-Packaged). Filter these in Event Viewer under `Microsoft-Windows-AppLocker/EXE and DLL` and `MSI and Script` logs.
