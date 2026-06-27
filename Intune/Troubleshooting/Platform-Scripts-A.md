# Intune Platform Scripts — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers **Intune Platform Scripts** (PowerShell scripts delivered via Intune) and the **Intune Management Extension (IME)** that executes them on Windows devices. Includes:

- PowerShell scripts (`.ps1`) deployed via Intune → Devices → Scripts
- Script execution contexts (SYSTEM vs. User)
- IME health and lifecycle
- Script run reporting, error codes, and retry behavior
- Interaction with WDAC, AppLocker, and execution policies

**Not covered:** Shell scripts for macOS (see `Shell-Script-Failures-B.md`), Win32 app deployments (see `App-Deployment-A.md`), or Intune Remediations/Proactive Remediations (see `Remediations-A.md`).

**Assumptions:**
- Windows 10 1903+ or Windows 11
- Device enrolled in Intune (MDM, not just Workplace Joined)
- IME installed (auto-deploys when any Win32 app or script targets the device)

---

## How It Works

<details><summary>Full architecture — Intune Platform Script execution pipeline</summary>

### End-to-End Script Delivery

```
IT Admin → Intune Portal (scripts.manage.microsoft.com)
    │
    ▼
Script uploaded + encoded (Base64) + stored in Intune Service
    │
    ▼
Assignment: Device group or User group
    │
    ▼
Intune Service → APNs / WNS push notification
    │
    ▼
MDM Agent on device (DmEnrollment, Windows MDM)
    │
    ▼
Intune Management Extension (IME) checkin
  (polls Intune Service every 8 hours, or on demand)
    │
    ▼
Script downloaded (via HTTPS from Intune CDN)
    └── Stored temporarily in: %ProgramData%\Microsoft\IntuneManagementExtension\Scripts\
    │
    ▼
Script executed by IME:
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
                   [-WindowStyle Hidden] [-EncodedCommand <Base64>]
    │
    ├── Context: SYSTEM (default) or LoggedInUser
    ├── 64-bit or 32-bit PowerShell host (configurable)
    └── Timeout: 30 minutes (hard limit)
    │
    ▼
Exit code captured by IME
    │
    ├── 0 = Success → RunState: success
    └── Non-zero = Failure → RunState: failed + ErrorCode stored
    │
    ▼
IME reports result to Intune Service (next sync)
    │
    ▼
Status visible in Intune portal ← (up to 30 min lag)
```

### IME Architecture

```
IntuneManagementExtension.exe (Windows Service)
    │
    ├── Scheduler: checks in every 8 hours
    ├── Policy processor: parses MDM policies from Intune
    │
    ├── Script Runner
    │       └── Executes .ps1 files via powershell.exe
    │               ├── Captures stdout/stderr (4KB limit → ResultMessage)
    │               └── Records exit code
    │
    ├── Win32 App Installer (separate but same process)
    ├── Remediations Runner
    └── Health Attestation Client
    │
    Registry State: HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies\
        └── <PolicyId>\  (one key per script/app/remediation)
                ├── Status
                ├── LastAttempt
                └── ExitCode
```

### Script Run Lifecycle

```
First assignment →
    IME downloads script →
    Executes →
    Records result in registry

On subsequent syncs:
    IF registry shows "completed" → Skip (don't re-run)
    IF script policy updated (new version) → Re-run
    IF registry entry deleted → Re-run on next sync
    IF device re-enrolled → Re-run (fresh registry)
```

### Key Configuration Properties

| Property | Values | Impact |
|----------|--------|--------|
| Run this script using logged on credentials | Yes / No | User vs SYSTEM context |
| Enforce script signature check | Yes / No | Blocks unsigned scripts |
| Run script in 64-bit PowerShell | Yes / No | Affects registry view (WOW64) |
| Run frequency | Once / Every 1h–168h | Retry/repeat behavior |

</details>

---

## Dependency Stack

```
Intune Portal (Microsoft Intune Service)
        │
MDM Enrollment (device enrolled, not just registered)
        │
APNs/WNS Push (optional — sync can be manual)
        │
IME Service (IntuneManagementExtension.exe) running
        │
IME can reach Intune CDN (HTTPS to *.manage.microsoft.com)
        │
PowerShell executable available (C:\Windows\System32\WindowsPowerShell\v1.0\)
        │
Execution policy: Intune uses -ExecutionPolicy Bypass (overrides MachinePolicy)
        │
WDAC / AppLocker policy allows PowerShell and the script's content
        │
Required context: SYSTEM or logged-in user present (if user-context script)
        │
Script runs, exits 0 = success
        │
Result reported to Intune on next IME sync
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Script shows "Pending" indefinitely | IME not installed, or device offline | IME service status; device checkin time in Intune |
| Script shows "Failed" with error code 1 | Script logic error (unhandled exception) | IME log + test script manually |
| Script shows "Failed" with 0x80004005 | Access denied — SYSTEM can't reach needed resource | Script context (SYSTEM vs user); check path permissions |
| Script shows "Not applicable" | Device not in assigned group, or OS/filter mismatch | Check group membership; assignment filters |
| Script ran once, won't re-run | IME cache has "completed" marker | Delete IME registry cache for that script |
| Script re-runs on every sync | Script returns non-zero (treated as retry) | Fix script to exit 0 on idempotent re-run |
| Script result shows "Unknown" | Device hasn't checked in with Intune in >7 days | Investigate device connectivity / MDM enrollment health |
| Script output truncated | Intune's 4KB output limit exceeded | Write output to file instead of stdout |
| WDAC blocking script | WDAC policy enforced, unsigned script blocked | Check WDAC event log; add signing or WDAC rule |
| Script works as admin, fails as SYSTEM | Mapped drive, user registry, or user app path not accessible from SYSTEM | Rewrite script for SYSTEM context |

---

## Validation Steps

**1. Confirm IME is installed and current**
```powershell
$IME = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object DisplayName -like "*Intune Management Extension*"
$IME | Select-Object DisplayName, DisplayVersion, InstallDate

Get-Service "IntuneManagementExtension" | Select-Object Name, Status, StartType
```
Good: Service `Running`, version ≥ 1.44.x.x (check latest via docs)

**2. Confirm device MDM enrollment**
```powershell
$EnrollInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.EnrollmentType -eq 6 }
$EnrollInfo | Select-Object PSChildName, EnrollmentType, UPN, MDMServiceURI
```
Good: Entry with `EnrollmentType = 6` (MDM) found

**3. Verify IME log for the script**
```powershell
$Log = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
$ScriptPattern = "PowerShell|Script|ExitCode"
Get-Content $Log | Select-String $ScriptPattern | Select-Object -Last 30
```
Good: `Script executed successfully. Exit code: 0`

**4. Check IME registry state for the script**
```powershell
# Get script ID from Intune portal (appears in URL when editing the script)
$ScriptId = "<policy-guid>"
$RegPath = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies\$ScriptId"
Get-ItemProperty $RegPath -ErrorAction SilentlyContinue
```
Good: `Status = Completed`, `ExitCode = 0`

**5. Check WDAC / AppLocker blocking**
```powershell
# Check WDAC block events (Event ID 3077 = audit block, 3076 = enforce block)
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 50 |
    Where-Object { $_.Id -in @(3076, 3077) } |
    Select-Object TimeCreated, Id, Message | Format-List

# Check AppLocker block events
Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -eq "Error" } |
    Select-Object TimeCreated, Message
```

**6. Test script manually in SYSTEM context**
```powershell
# Download PsExec from Sysinternals, then:
# .\PsExec64.exe -s -i powershell.exe -ExecutionPolicy Bypass
# In the resulting SYSTEM PS window, run the script content

# Quick SYSTEM context check from IME:
whoami  # Should return: nt authority\system
```

**7. Verify connectivity to Intune CDN**
```powershell
Test-NetConnection -ComputerName "swda01.manage.microsoft.com" -Port 443
Test-NetConnection -ComputerName "swda02.manage.microsoft.com" -Port 443
Test-NetConnection -ComputerName "fef.msua01.manage.microsoft.com" -Port 443
```
Good: `TcpTestSucceeded: True` for all

---

## Troubleshooting Steps (by phase)

### Phase 1: Script never runs (stuck Pending)

1. Confirm IME service is running: `Get-Service IntuneManagementExtension`
2. If not installed, check if any Win32 app or Remediation is assigned to the device — IME is required for these; trigger assignment to auto-install IME
3. Force MDM sync: Start-Process `ms-device-enrollment:?mode=mdm` or Company Portal → Sync
4. Check IME log for "checking in" messages — absence means IME can't reach Intune service
5. Verify network: `Test-NetConnection swda01.manage.microsoft.com -Port 443`
6. Check if a proxy is required: compare IME account (SYSTEM) vs your proxy config — SYSTEM may not use user proxy settings
7. For SYSTEM proxy requirements, configure WinHTTP proxy: `netsh winhttp set proxy <proxy>:<port>`

### Phase 2: Script runs but fails

1. Read `IntuneManagementExtension.log` — look for the script name and exit code
2. If exit code is non-zero: reproduce the failure by running the script manually in the same context (SYSTEM via PsExec, or as the user)
3. Common failure patterns:
   - Missing module: `Install-Module` in script won't work in SYSTEM context without admin internet access; pre-package the module
   - Missing file path: Script assumes `C:\Users\user\Desktop` — doesn't exist in SYSTEM context
   - Requires elevation: Some actions require `RunAsAdministrator` even for SYSTEM; use `Start-Process` with `-Verb RunAs` workaround
   - Network resource: Script accesses a UNC path or web resource that's blocked from SYSTEM
4. Add explicit error handling and exit codes to the script:
   ```powershell
   try {
       # your code
       exit 0
   } catch {
       Write-Error "Script failed: $_"
       exit 1
   }
   ```

### Phase 3: Script succeeds but Intune shows wrong status

1. Wait 30 minutes after script runs — reporting lag is expected
2. Force IME sync: `Restart-Service IntuneManagementExtension`
3. Check IME registry directly for the actual exit code:
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies\<ScriptId>"
   ```
4. If registry shows success but portal shows failed: potential replication lag in Intune backend — wait 2 hours and re-check

### Phase 4: Script blocked by security controls

**WDAC:**
1. Identify block via Event ID 3076/3077 in `Microsoft-Windows-CodeIntegrity/Operational`
2. Get the blocked file hash or signer
3. Create an WDAC supplemental policy allowing the script's signer or publisher
4. See `WDAC-A.md` for full WDAC policy management procedures

**AppLocker:**
1. Identify block in `Microsoft-Windows-AppLocker/EXE and DLL` event log
2. Add a publisher or path rule for PowerShell scripts in the AppLocker policy
3. Test with `Get-AppLockerPolicy -Effective` to confirm rule applies

**Execution Policy (MachinePolicy):**
Intune uses `-ExecutionPolicy Bypass` which overrides User and Process scope, but **not** MachinePolicy or UserPolicy GPO settings. If GPO sets `MachinePolicy = AllSigned`:
- Option A: Update GPO to `MachinePolicy = RemoteSigned` 
- Option B: Sign your Intune scripts with a code signing certificate
- Option C: Add a WDAC signing rule (preferred in high-security environments)

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — IME reinstall</summary>

**Scenario:** IME is installed but corrupt; service fails to start or crashes repeatedly.

```powershell
# Step 1: Stop and disable IME
Stop-Service "IntuneManagementExtension" -Force -ErrorAction SilentlyContinue
Set-Service "IntuneManagementExtension" -StartupType Disabled

# Step 2: Uninstall IME
$IME = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*Intune Management Extension*" }
if ($IME) {
    Write-Host "Uninstalling IME..."
    $IME.Uninstall()
}

# Step 3: Clean up remnants
Remove-Item "C:\Program Files (x86)\Microsoft Intune Management Extension" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\ProgramData\Microsoft\IntuneManagementExtension" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension" -Recurse -Force -ErrorAction SilentlyContinue

# Step 4: Trigger re-install via MDM sync
# IME will reinstall automatically when any Win32 app or script is assigned
Start-Process "C:\Windows\System32\wuauclt.exe" -ArgumentList "/detectnow"
# Or trigger via enrollment sync
Start-Process "ms-device-enrollment:?mode=mdm" -ErrorAction SilentlyContinue
```

**Rollback:** N/A — IME reinstalls automatically. No data is permanently lost.

</details>

<details>
<summary>Playbook 2 — Deploy a well-structured idempotent script</summary>

**Scenario:** You need to write or fix a script that Intune will run reliably.

```powershell
<#
.SYNOPSIS    Example idempotent Intune Platform Script template
.DESCRIPTION Demonstrates best practices: idempotency check, logging, explicit exit codes
.NOTES       Context: SYSTEM, 64-bit PowerShell, RunAsAdmin not required
#>

$LogPath = "C:\ProgramData\YourOrg\Logs\ScriptName.log"
$DoneFlagPath = "C:\ProgramData\YourOrg\Flags\ScriptName.done"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry = "[$Timestamp][$Level] $Message"
    $Entry | Out-File -FilePath $LogPath -Append -Encoding utf8
    Write-Output $Entry
}

# Ensure log directory exists
New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path (Split-Path $DoneFlagPath) -Force -ErrorAction SilentlyContinue | Out-Null

Write-Log "Script started. Running as: $(whoami)"

# Idempotency check
if (Test-Path $DoneFlagPath) {
    Write-Log "Already applied (flag found at $DoneFlagPath). Exiting success."
    exit 0
}

try {
    # ---- YOUR WORK HERE ----
    Write-Log "Applying configuration..."
    # Example: Set a registry value
    Set-ItemProperty -Path "HKLM:\SOFTWARE\YourOrg" -Name "ConfigApplied" -Value 1 -Type DWORD -Force
    Write-Log "Configuration applied successfully." "OK"

    # Create done flag
    New-Item -Path $DoneFlagPath -ItemType File -Force | Out-Null
    Write-Log "Done flag created. Script complete." "OK"
    exit 0

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}
```

</details>

<details>
<summary>Playbook 3 — Bulk query script run status across fleet</summary>

**Scenario:** Need to audit script compliance across all devices.

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All" -NoWelcome

# Get all platform scripts
$Scripts = Get-MgDeviceManagementDeviceManagementScript -All
$Scripts | Format-Table DisplayName, Id, RunAsAccount, FileName

$TargetScriptId = "<script-guid>"

# Get run states for all devices
$RunStates = Get-MgDeviceManagementDeviceManagementScriptDeviceRunState -DeviceManagementScriptId $TargetScriptId -All

$Report = $RunStates | ForEach-Object {
    [PSCustomObject]@{
        DeviceName      = $_.ManagedDevice.DeviceName
        RunState        = $_.RunState
        ErrorCode       = $_.ErrorCode
        ResultMessage   = $_.ResultMessage -replace "`n"," "
        LastUpdated     = $_.LastStateUpdateDateTime
    }
}

# Summary
$Report | Group-Object RunState | Select-Object Name, Count | Sort-Object Count -Descending

# Export failed devices
$Report | Where-Object RunState -eq "failed" |
    Export-Csv "C:\Temp\ScriptFailures-$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation

Write-Host "Total devices: $($Report.Count)"
Write-Host "Success: $($Report | Where RunState -eq 'success' | Measure | Select -Exp Count)"
Write-Host "Failed: $($Report | Where RunState -eq 'failed' | Measure | Select -Exp Count)"
Write-Host "Pending: $($Report | Where RunState -eq 'pending' | Measure | Select -Exp Count)"
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Collect IME and script evidence for escalation
.NOTES       Run on affected device as Administrator
#>
[CmdletBinding()]
param([string]$ScriptPolicyId = "")

$Output = "C:\Temp\IME-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $Output -Force | Out-Null

function Write-Status { param([string]$M,[string]$S="INFO") Write-Host "[$S] $M" -ForegroundColor $(switch($S){"OK"{"Green"}"WARN"{"Yellow"}"ERROR"{"Red"}default{"Cyan"}}) }

# System info
Write-Status "Collecting system info..."
[PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    OS           = (Get-WmiObject Win32_OperatingSystem).Caption
    Build        = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    Context      = whoami
} | Export-Csv "$Output\system_info.csv" -NoTypeInformation

# IME service
Write-Status "Collecting IME service state..."
Get-Service "IntuneManagementExtension" -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Export-Csv "$Output\ime_service.csv" -NoTypeInformation

# IME version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object DisplayName -like "*Intune Management Extension*" |
    Select-Object DisplayName, DisplayVersion, InstallDate |
    Export-Csv "$Output\ime_version.csv" -NoTypeInformation

# MDM enrollment
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" -ErrorAction SilentlyContinue |
    Where-Object EnrollmentType -eq 6 |
    Select-Object UPN, MDMServiceURI, EnrollmentType |
    Export-Csv "$Output\enrollment.csv" -NoTypeInformation

# IME registry (policy cache)
if ($ScriptPolicyId) {
    Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies\$ScriptPolicyId" -ErrorAction SilentlyContinue |
        Export-Csv "$Output\script_registry.csv" -NoTypeInformation
}

# IME log (last 500 lines)
$IMELog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $IMELog) {
    Get-Content $IMELog | Select-Object -Last 500 | Out-File "$Output\ime_log_tail.txt"
}

# Execution policy
Get-ExecutionPolicy -List | Out-File "$Output\execution_policy.txt"

# WDAC events
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 30 -ErrorAction SilentlyContinue |
    Where-Object Id -in @(3076, 3077) |
    Select-Object TimeCreated, Id, Message |
    Export-Csv "$Output\wdac_blocks.csv" -NoTypeInformation

# Network connectivity
@("swda01.manage.microsoft.com","swda02.manage.microsoft.com") | ForEach-Object {
    $Result = Test-NetConnection -ComputerName $_ -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Host = $_; Reachable = $Result.TcpTestSucceeded }
} | Export-Csv "$Output\network_connectivity.csv" -NoTypeInformation

Compress-Archive -Path $Output -DestinationPath "$Output.zip" -Force
Write-Status "Evidence pack: $Output.zip" "OK"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check IME service | `Get-Service IntuneManagementExtension` |
| Restart IME | `Restart-Service IntuneManagementExtension -Force` |
| Read IME log | `Get-Content C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log \| Select -Last 100` |
| Check script registry state | `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies\<id>` |
| Clear script registry (force re-run) | `Remove-Item HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies\<id> -Recurse -Force` |
| Force MDM sync | Company Portal → Settings → Sync |
| Check execution policy | `Get-ExecutionPolicy -List` |
| Check WDAC blocks | `Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 20 \| Where Id -in 3076,3077` |
| Run script as SYSTEM (test) | `PsExec64.exe -s -i powershell.exe -ExecutionPolicy Bypass` |
| Check IME version | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" \| Where DisplayName -like "*Intune*"` |
| List all platform scripts | `Get-MgDeviceManagementDeviceManagementScript -All \| Select DisplayName, Id` |
| Get script run states | `Get-MgDeviceManagementDeviceManagementScriptDeviceRunState -DeviceManagementScriptId <id>` |
| Test Intune CDN connectivity | `Test-NetConnection swda01.manage.microsoft.com -Port 443` |

---

## 🎓 Learning Pointers

- **IME is the Swiss Army knife of Intune:** The Intune Management Extension handles platform scripts, Win32 app installs, Remediations (Proactive Remediations), and Custom Compliance scripts — all from the same process. Understanding IME deeply unlocks troubleshooting for all of these features, not just scripts. Any time multiple Intune features fail simultaneously on a device, IME is the first suspect. See: [IME Overview](https://learn.microsoft.com/en-us/mem/intune/apps/intune-management-extension)

- **The 4KB output limit is a common gotcha:** Intune captures stdout and stores it in the `ResultMessage` field, but only the first ~4KB. Long-running scripts that dump verbose output will be truncated in the portal. Best practice: always write diagnostic output to a log file (`C:\ProgramData\YourOrg\Logs\`), and keep stdout minimal — just a success/failure summary. This also makes retrospective debugging possible even if the script was replaced.

- **SYSTEM context has no user artifacts:** A common design error is writing scripts that reference `$env:USERPROFILE`, `$env:APPDATA`, mapped drives (Z:\), or `HKCU:\`. In SYSTEM context, these either don't exist or point to the SYSTEM profile. Design SYSTEM-context scripts to work entirely in `C:\ProgramData\`, `HKLM:\`, and absolute paths. If you must touch user profiles, enumerate `C:\Users\` and iterate.

- **Script assignment timing matters:** Scripts assigned to a device group run at the next IME checkin (up to 8 hours later). For immediate execution, use Intune's **"Sync"** action on the device in the portal, or trigger from the device via Company Portal. For time-sensitive deployments, combine Intune scripts with scheduled task creation — deploy the script via Intune, have the script create a local scheduled task for real-time execution.

- **Versioning your scripts:** Intune doesn't natively version-control scripts. When you update a script, Intune treats it as a new version and re-runs it on all assigned devices. This is useful but can cause unintended re-runs. Track script versions in your script header comments, and use the idempotency pattern (done-flag check) to prevent destructive re-runs when you only made a minor fix.

- **Signature check is optional but recommended for production:** The "Enforce script signature check" option requires your scripts to be signed with a code signing certificate trusted by the device. In environments with WDAC enforced, this is often required anyway. For MSP deployments at multiple clients, consider acquiring or using an Azure Key Vault-managed code signing certificate to sign all Intune scripts centrally. Reference: [Script Signing in PowerShell](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_signing)
