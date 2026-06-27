# Intune Platform Scripts — Hotfix Runbook (Mode B: Ops)
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

Run these first to identify the failure layer:

```powershell
# 1. Check script assignment and run status in MEM/Intune
# (Run from admin workstation with Graph access)
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome

$ScriptName = "<YourScriptDisplayName>"
$Scripts = Get-MgDeviceManagementDeviceManagementScript -Filter "displayName eq '$ScriptName'"
$Scripts | Select-Object Id, DisplayName, RunAsAccount, EnforceSignatureCheck, FileName

# 2. Get run status for a specific device
$DeviceId = "<DeviceObjectId>"
$ScriptId = $Scripts[0].Id
Get-MgDeviceManagementDeviceManagementScriptDeviceRunState -DeviceManagementScriptId $ScriptId |
    Where-Object { $_.ManagedDevice.Id -eq $DeviceId } |
    Select-Object RunState, ResultMessage, LastStateUpdateDateTime, ErrorCode
```

**Interpretation:**

| RunState | Meaning | Do This |
|----------|---------|---------|
| `pending` | Script not yet received by device | Wait 30 min, then force sync |
| `running` | Script currently executing | Wait up to 60 min |
| `success` | Script completed successfully | Done |
| `failed` | Script exited with error | Check ErrorCode + ResultMessage |
| `notApplicable` | Assignment scope miss | Check group membership |
| `unknown` | Device not checked in recently | Force device sync |

```powershell
# 3. On-device — check Intune Management Extension (IME) log
$IMELog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Select-String -Path $IMELog -Pattern "<ScriptName>" | Select-Object -Last 20
```

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Intune Portal (script uploaded + assigned)
        │
        ▼
Device enrolled in Intune (MDM enrolled, not just registered)
        │
        ▼
Intune Management Extension (IME) installed
  C:\Program Files (x86)\Microsoft Intune Management Extension\
        │
        ▼
IME Agent service running (IntuneManagementExtension.exe)
        │
        ▼
Device checks in (every 8 hours or on manual sync)
        │
        ▼
Script downloaded from Intune CDN
        │
        ▼
Script executed under configured context (SYSTEM or User)
        │
        ▼
Exit code returned to IME → reported to Intune
        │
        ▼
Run status visible in Intune portal (≤ 30 min lag)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm IME is installed and running**
```powershell
Get-Service -Name "IntuneManagementExtension" -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType
```
Expected: `Status = Running`

If not running:
```powershell
Start-Service "IntuneManagementExtension"
Get-Service "IntuneManagementExtension" | Select-Object Status
```

**Step 2 — Force IME script re-evaluation**
```powershell
# Delete IME script cache — forces re-download and re-run on next checkin
$CachePath = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies"
Remove-Item -Path "$CachePath\*" -Recurse -Force -ErrorAction SilentlyContinue

# Restart IME to trigger immediate checkin
Restart-Service "IntuneManagementExtension" -Force
```

**Step 3 — Read IME log for the script**
```powershell
$Log = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Get-Content $Log | Select-String -Pattern "Script|powershell|ExitCode" | Select-Object -Last 50
```

Expected good output:
```
[Win32App] Script execution started: <ScriptId>
[PowerShell] Script executed successfully. Exit code: 0
```

Bad output examples:
- `Exit code: 1` → Script logic error
- `Exit code: -1073741502` → Script startup failure (missing DLL, .NET issue)
- `Execution policy` → PowerShell execution policy blocking script
- `Access is denied` → Permission issue for SYSTEM or User context

**Step 4 — Check PowerShell execution policy**
```powershell
Get-ExecutionPolicy -List | Format-Table
# Intune scripts are signed via Microsoft — should work under RemoteSigned or AllSigned
# MachinePolicy or UserPolicy set to Restricted will block all scripts
```

**Step 5 — Verify script context**

Check what context the script runs under (SYSTEM vs logged-in user):
```
Intune Portal → Scripts → <Script> → Properties → Run this script using the logged on credentials: Yes/No
```
- `No` = runs as SYSTEM (no user profile access, no mapped drives)
- `Yes` = runs as logged-in user (requires user to be present and logged in)

**Step 6 — Test script manually in matching context**
```powershell
# Test as SYSTEM using PsExec (download from Sysinternals)
# .\PsExec64.exe -i -s powershell.exe
# Then paste the script content and run

# Test as current user (if script set to run as user)
# Simply paste script content into a PowerShell window
```

---

## Common Fix Paths

<details><summary>Fix 1 — IME not installed or corrupt</summary>

**Symptoms:** No IME service found; scripts never execute.

```powershell
# Check if IME is installed
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object DisplayName -like "*Intune Management Extension*" |
    Select-Object DisplayName, DisplayVersion, InstallDate

# If missing — trigger IME install by ensuring Intune enrollment is healthy
# IME installs automatically when device is MDM-enrolled and an Intune app or script targets it

# Force enrollment sync to trigger IME deployment
Start-Process "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o" -NoNewWindow -Wait
Start-Sleep -Seconds 30
Get-Service "IntuneManagementExtension" -ErrorAction SilentlyContinue | Select-Object Status
```

**Rollback:** N/A — IME is a required Intune component.

</details>

<details><summary>Fix 2 — Script stuck in "pending" state</summary>

**Symptoms:** Script assigned but never runs; device shows "Pending" in Intune.

```powershell
# Step 1: Force Intune sync from the device
# Via Company Portal app: Open Company Portal → Settings → Sync
# Or via PowerShell:
$EnrollmentPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
$Enrollments = Get-ChildItem $EnrollmentPath
$MDMEnrollment = $Enrollments | Get-ItemProperty | Where-Object { $_.EnrollmentType -eq "6" }
if ($MDMEnrollment) {
    Write-Host "MDM Enrollment found: $($MDMEnrollment.PSChildName)"
}

# Via scheduled task trigger
$task = Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" -TaskName "*Push Launch*" -ErrorAction SilentlyContinue
if ($task) { Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName }

# Step 2: Restart IME
Restart-Service "IntuneManagementExtension" -Force
Start-Sleep -Seconds 60

# Step 3: Check if script now shows as running in IME log
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" |
    Select-String "Script" | Select-Object -Last 20
```

**Rollback:** N/A — diagnostic only.

</details>

<details><summary>Fix 3 — Script fails with execution policy error</summary>

**Symptoms:** IME log shows "Execution policy" or "is not digitally signed" errors.

```powershell
# Check current effective policy
Get-ExecutionPolicy -List

# If MachinePolicy = Restricted, it's set via GPO or Intune settings catalog
# Intune scripts bypass execution policy by default via -ExecutionPolicy Bypass flag
# If still failing, check if AV or EDR is blocking PowerShell

# Verify how Intune launches scripts (should see -ExecutionPolicy Bypass):
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" |
    Select-String "ExecutionPolicy\|-Command\|powershell" | Select-Object -Last 10

# If a WDAC or AppLocker policy is blocking PowerShell scripts:
Get-AppLockerPolicy -Effective -Xml | Select-Xml "//FilePublisherRule|//FilePathRule" |
    Select-Object -ExpandProperty Node | Where-Object { $_.Action -eq "Deny" } |
    Select-Object Name, Action, @{N="Conditions";E={$_.Conditions.OuterXml}}
```

**If WDAC is blocking:** Add a signer rule or path rule allowing Intune script execution. See `WDAC-B.md`.

</details>

<details><summary>Fix 4 — Script fails because it requires user context</summary>

**Symptoms:** Script works when run manually as a user but fails as SYSTEM. Typical errors: `$env:USERPROFILE not found`, mapped drive not accessible, app not found at user path.

```powershell
# Identify current script context setting
# Intune Portal: Scripts → <Script> → Properties
# "Run this script using the logged on credentials" = Yes (User) / No (SYSTEM)

# For scripts needing user context:
# In Intune portal, change "Run this script using the logged on credentials" to Yes
# Note: Script will only run when a user is logged in — not on a headless/shared device

# To access user paths from SYSTEM context (workaround):
$Users = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notmatch "Public|Default|.*\.$" }
foreach ($User in $Users) {
    $ProfilePath = $User.FullName
    # Access user-specific resource
    Write-Host "Processing user: $($User.Name) at $ProfilePath"
}
```

**Rollback:** Change script context back to SYSTEM if the user-context fix causes other issues.

</details>

<details><summary>Fix 5 — Script re-runs when it shouldn't (or won't re-run when it should)</summary>

**Symptoms:** Script runs repeatedly on every IME sync cycle; or script ran once but needs to run again after re-assignment.

```powershell
# Force re-run: clear IME script registry cache
# This removes the "already ran" marker — Intune will re-execute on next sync

$CachePath = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies"
$ScriptId = "<IntunePolicyId>"  # From Intune portal URL when viewing the script

# Remove specific script cache entry
Remove-Item -Path "$CachePath\$ScriptId" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Cache cleared for script: $ScriptId"

# Restart IME to trigger re-execution
Restart-Service "IntuneManagementExtension" -Force

# To PREVENT re-runs (script designed to run once):
# In Intune portal: Scripts → <Script> → Properties → Run script in 64-bit PowerShell host
# Use idempotent script logic — check if already applied before executing:
if (Test-Path "C:\ProgramData\YourApp\setup.done") {
    Write-Host "Already applied. Exiting."
    exit 0
}
# ... do work ...
New-Item -Path "C:\ProgramData\YourApp\setup.done" -ItemType File -Force
```

</details>

---

## Escalation Evidence

```
INTUNE PLATFORM SCRIPT ESCALATION — Evidence Pack
====================================================
Date/Time:         [YYYY-MM-DD HH:MM UTC]
Engineer:          [Name]
Ticket:            [INC/CHG number]
Device Name:       [DEVICE-NAME]
Device Object ID:  [Entra Object ID]
Intune Device ID:  [Intune Device ID from portal]
OS Version:        [e.g., Windows 11 23H2 22631.xxxx]
Script Name:       [Display name in Intune]
Script ID:         [GUID from Intune portal URL]
Script Context:    [SYSTEM / User]
Run Schedule:      [Once / Every X hours]

INTUNE REPORTED STATUS:
  Run State:       [success / failed / pending / unknown]
  Error Code:      [if failed — e.g., 0x80004005]
  Result Message:  [exact text from Intune portal]
  Last Updated:    [DateTime]

ON-DEVICE STATE:
  IME Service:     [Running / Stopped / Not installed]
  IME Version:     [from Add/Remove Programs]
  Execution Policy (Machine): [Bypass / RemoteSigned / Restricted]
  WDAC Active:     [Yes / No]

IME LOG EXCERPT (last 30 relevant lines):
[paste from IntuneManagementExtension.log]

SCRIPT MANUAL TEST RESULT (SYSTEM context):
[paste output from PsExec test]

ACTIONS TAKEN:
1. [Describe what was attempted]
2. [Describe what changed]

ESCALATE TO: Microsoft Intune Support via admin.microsoft.com/support
ATTACH: IME log file (full), script content (redacted of secrets)
```

---

## 🎓 Learning Pointers

- **IME is the engine, not just a passthrough:** The Intune Management Extension (`Microsoft.Management.Services.IntuneWindowsAgent.exe`) is responsible for script execution, Win32 app install, and Remediation policies — not just scripts. If IME is unhealthy, multiple Intune features break simultaneously. Always check IME health first. See: [IME Overview](https://learn.microsoft.com/en-us/mem/intune/apps/intune-management-extension)

- **Script cache clearing is safe:** The IME registry cache at `HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies` only records "this script has run" markers. Deleting it is safe and forces re-evaluation — useful when a script needs to re-run after a fix, or when debugging why a script appears to be skipped. Always restart IME afterward.

- **SYSTEM context ≠ administrator context:** Scripts running as SYSTEM have more OS privilege than a local admin but have no access to user-specific resources: no mapped drives, no `HKCU` registry of the logged-in user, no `%APPDATA%`. Design scripts with context in mind — many "works on my machine" failures are SYSTEM vs. user context mismatches.

- **Exit codes matter:** Intune reports script success/failure based on PowerShell's exit code. A script that catches all errors internally but exits `0` will appear "successful" even if it did nothing useful. Conversely, a non-zero exit from a `Write-Error` or exception will mark the run as failed. Always use explicit `exit 0` (success) and `exit 1` (failure) at the end of your scripts.

- **64-bit vs 32-bit PowerShell:** The IME's "Run script in 64-bit PowerShell host" setting matters for scripts accessing registry paths. Without it, scripts run in a 32-bit host, and registry reads from `HKLM:\SOFTWARE\...` may be redirected to `HKLM:\SOFTWARE\WOW6432Node\...`. Enable 64-bit host for all production scripts unless you have a specific reason not to. See: [Intune Script Settings](https://learn.microsoft.com/en-us/mem/intune/apps/intune-management-extension#create-a-script-policy-and-assign-it)

- **Script output is limited:** Intune captures the last 4KB of `Write-Output` / `Write-Host` from a script in the ResultMessage field. For scripts that generate large output, write results to a log file in `C:\ProgramData\<YourOrg>\` and read from there — don't rely on Intune's ResultMessage for detailed diagnostics.
