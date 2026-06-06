# Intune Remediations (Proactive Remediations) — Hotfix Runbook (Mode B: Ops)
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

Run these on the **affected device** (or via Intune remote shell / PowerShell remoting):

```powershell
# 1. Check Intune Management Extension (IME) service state
Get-Service -Name IntuneManagementExtension | Select-Object Name, Status, StartType

# 2. Check IME last heartbeat and version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension" |
    Select-Object LastHeartbeatOrCheckIn, Version

# 3. List all Remediation script execution results on device
$logPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log"
if (Test-Path $logPath) {
    Select-String -Path $logPath -Pattern "Remediation|Health|detection|remediation" |
        Select-Object -Last 50 | ForEach-Object { $_.Line }
} else { Write-Warning "AgentExecutor.log not found" }

# 4. Check if device has valid Intune enrollment
$enrollment = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderID -eq "MS DM Server" }
$enrollment | Select-Object EnrollmentType, UPN, AADResourceID

# 5. Verify PowerShell execution policy won't block scripts
Get-ExecutionPolicy -List | Where-Object { $_.Scope -in "LocalMachine","Process","CurrentUser" }
```

| If you see | Do this |
|------------|---------|
| IME service Stopped | Fix 1 — Restart IME service |
| LastHeartbeatOrCheckIn > 8 hours ago | Fix 2 — Force IME sync |
| No enrollment record | Fix 3 — Re-enroll / check Intune license |
| Execution policy = Restricted or AllSigned (LocalMachine) | Fix 4 — Adjust execution policy via Intune policy |
| AgentExecutor.log missing | Fix 5 — Reinstall IME |
| Script errors about "Access Denied" | Fix 6 — Check script run-as context |
| Detection reports "not compliant" but remediation not running | Fix 7 — Check remediation assignment and schedule |

---
## Dependency Cascade

<details><summary>What must be true for Remediations to work</summary>

```
Intune Service (cloud)
  └── Device enrolled & licensed (Intune P1/P2 or Business Premium)
        └── IME installed (IntuneManagementExtension.exe)
              └── IME service running (IntuneManagementExtension)
                    └── IME can reach *.manage.microsoft.com (HTTPS/443)
                          └── Script assignment targets device/user group
                                └── Detection script runs (SYSTEM or logged-on user)
                                      └── Detection exits 1 (non-compliant) → Remediation triggers
                                            └── Remediation script runs
                                                  └── Remediation exits 0 (success)
                                                        └── Status reported to Intune portal
```

**Key constraints:**
- Remediations require **Windows 10 1903+** or **Windows 11**
- License: **Intune P1** (included in M365 Business Premium, E3+EMS E3, E5)
- Scripts run as **SYSTEM** by default; optionally as **logged-on user**
- Max script size: **200 KB** each (detection + remediation)
- Schedule: minimum **15 minutes**, up to daily
- Detection script must exit `0` (compliant) or `1` (non-compliant/trigger remediation)
- Remediation script must exit `0` (success) or non-zero (failure)
- IME polls every **~8 hours** by default; forced sync = faster

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm IME is running and healthy**
```powershell
Get-Service IntuneManagementExtension | Select-Object Status, StartType
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension").LastHeartbeatOrCheckIn
```
Expected: `Running`, `Automatic`. Heartbeat within last 8 hours.  
Bad: Stopped, or heartbeat > 24 hours → go to Fix 1 or Fix 2.

**Step 2 — Check IME can reach Intune endpoints**
```powershell
$endpoints = @(
    "eas.manage.microsoft.com",
    "r.manage.microsoft.com",
    "fef.msua06.manage.microsoft.com",
    "dm3-prod-byoa-ams.manage.microsoft.com"
)
foreach ($e in $endpoints) {
    $result = Test-NetConnection -ComputerName $e -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint = $e; Reachable = $result.TcpTestSucceeded }
}
```
Expected: All `True`.  
Bad: Any `False` → firewall/proxy blocking → network team.

**Step 3 — Review AgentExecutor log for script execution**
```powershell
$log = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log"
Get-Content $log | Select-String "HealthScript|Remediation|Exit Code|Error" | Select-Object -Last 40
```
Expected: Lines showing `Exit Code: 0` for detection (compliant) or remediation.  
Bad: `Exit Code: 1` on detection (expected — triggers remediation), non-zero on remediation = script logic error.

**Step 4 — Check remediation assignment in portal**
- Intune portal → Devices → Remediations → select script → **Device status**
- Look for your device: status should show `With issues` (detection failed) → then `Remediated` after remediation runs.
- If device not listed: assignment group may not include device/user.

**Step 5 — Check script output/error in portal**
- Device row → **...** → **Device check-in status** → shows stdout/stderr (max 2048 chars) from last run.

**Step 6 — Validate script logic locally**
```powershell
# Run detection script manually as SYSTEM using PsExec (if available)
# Or run directly to test logic (will run as your account, not SYSTEM):
& "C:\Temp\Detection.ps1"
$LASTEXITCODE  # Should be 0 (compliant) or 1 (non-compliant)
```

---
## Common Fix Paths

<details><summary>Fix 1 — IME service stopped or not starting</summary>

```powershell
# Check service state
Get-Service IntuneManagementExtension

# Attempt restart
Restart-Service IntuneManagementExtension -Force

# If it fails to start, check event log for errors
Get-WinEvent -LogName Application -MaxEvents 50 |
    Where-Object { $_.ProviderName -like "*IntuneManagementExtension*" } |
    Select-Object TimeCreated, LevelDisplayName, Message

# If service missing entirely, reinstall IME
# Download from: https://go.microsoft.com/fwlink/?linkid=2093925
# Or trigger reinstall via re-enrollment (see Fix 3)
```

**Rollback:** N/A — restarting the service is non-destructive.

</details>

<details><summary>Fix 2 — Force IME sync (pull new policies immediately)</summary>

```powershell
# Method 1: Restart IME (triggers immediate check-in on startup)
Restart-Service IntuneManagementExtension -Force
Start-Sleep -Seconds 30

# Method 2: Invoke via registry signal
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension" `
    -Name "LastHeartbeatOrCheckIn" -Value "1970-01-01T00:00:00" -Type String
Restart-Service IntuneManagementExtension -Force

# Method 3: Company Portal → Sync (requires Company Portal installed)
# User action: Open Company Portal → Devices → [Device name] → Sync

# Method 4: From Intune portal
# Devices → All Devices → [Device] → Sync
```

Wait 5–10 minutes then re-check AgentExecutor.log for new Remediation runs.  
**Rollback:** N/A — sync is non-destructive.

</details>

<details><summary>Fix 3 — Device not in assignment group / remediation not targeting device</summary>

**In Intune portal:**
1. Devices → Remediations → [Script package] → Properties → Assignments
2. Confirm the device's Azure AD group is in **Required** assignments
3. Check group membership: Azure AD → Groups → [Group] → Members

```powershell
# Check what groups this device/user is in (run on device)
# Get device's Entra Object ID
$deviceId = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\*").SrvClientId
Write-Host "Device Object ID area — check Intune portal for exact ID"

# Get current user's group memberships via Graph (requires Graph permissions)
# Connect-MgGraph -Scopes "GroupMember.Read.All"
# $userId = (Get-MgContext).Account | Get-MgUser
# Get-MgUserMemberOf -UserId $userId.Id | Select-Object -ExpandProperty AdditionalProperties
```

If device is missing from group: add it (direct member) or wait for group sync (~1–2 hours for dynamic groups).  
**Rollback:** Remove device from group if added in error.

</details>

<details><summary>Fix 4 — PowerShell execution policy blocking scripts</summary>

IME runs scripts with `-ExecutionPolicy Bypass` internally, so local execution policy **should not** affect IME scripts. If you're seeing execution policy errors, it's likely a different issue:

```powershell
# Verify what IME actually uses by checking its process launch
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Select-Object CommandLine | Where-Object { $_.CommandLine -like "*executionpolicy*" }

# If a GPO is enforcing execution policy and overriding IME's bypass:
# Check: HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell" -ErrorAction SilentlyContinue
```

If a policy is enforcing `Restricted` and overriding IME's bypass, the policy must be removed or adjusted via GPO/Intune Settings Catalog.  
**Do not** set execution policy to Unrestricted via script as a fix — remediate the enforcing policy.

</details>

<details><summary>Fix 5 — Reinstall Intune Management Extension</summary>

```powershell
# Step 1: Stop the service
Stop-Service IntuneManagementExtension -Force -ErrorAction SilentlyContinue

# Step 2: Uninstall IME via WMI/App list
$app = Get-WmiObject -Class Win32_Product |
    Where-Object { $_.Name -like "*Intune Management Extension*" }
if ($app) {
    Write-Status "Uninstalling IME..." -Status "INFO"
    $app.Uninstall()
} else {
    Write-Warning "IME not found in Win32_Product — may need manual uninstall"
}

# Step 3: Clear IME data directory (optional — removes cached scripts)
# WARNING: This removes all IME cached data
# Remove-Item "$env:ProgramData\Microsoft\IntuneManagementExtension" -Recurse -Force

# Step 4: IME will reinstall automatically on next Intune check-in
# Trigger via: sync from Company Portal, or wait for next check-in cycle
# OR download installer manually:
# https://go.microsoft.com/fwlink/?linkid=2093925
```

**Rollback:** IME reinstalls from Intune automatically. No manual rollback needed.  
⚠️ Clearing IME data removes execution history — scripts will re-run on next sync.

</details>

<details><summary>Fix 6 — Script failing due to run-as context (SYSTEM vs. user)</summary>

Some scripts need user context (e.g., checking HKCU registry, user-installed apps). By default, remediations run as SYSTEM.

**In Intune portal:**
1. Devices → Remediations → [Script package] → Properties
2. **Run this script using the logged-on credentials** → toggle to **Yes**
3. Script will now run as the logged-in user

⚠️ If **no user is logged in**, the script will **not run** when using logged-on credentials mode.

```powershell
# Test what context your detection script runs in (add this to detection script temporarily):
$context = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
# Write to a temp file since stdout goes to Intune portal
$context | Out-File "C:\Temp\script_context.txt"
exit 0
```

**Rollback:** Revert run-as toggle to SYSTEM if user-context causes issues.

</details>

<details><summary>Fix 7 — Remediation not running despite detection showing non-compliant</summary>

```powershell
# Check if "Run remediation when" schedule is set too infrequently
# Also check if "Scope tags" are excluding the device

# View remediation schedule in portal:
# Devices → Remediations → [Package] → Properties → Settings
# "Run script" frequency: Every 15 min / 1 hour / 4 hours / 8 hours / 12 hours / 24 hours / Once

# Check last run times via portal:
# Devices → Remediations → [Package] → Device status → Last detection run / Last remediation run

# Force immediate re-run by modifying detection state:
# Portal: Device status → [Device] → "Run detection" button (if available)
# Or: Sync device to trigger next scheduled run
```

If detection runs but remediation doesn't trigger — verify detection script is exiting with code `1`:
```powershell
# Wrong (no exit code = defaults to 0 = "compliant" = no remediation):
Write-Output "Not compliant"

# Correct:
Write-Output "Not compliant"
exit 1
```

</details>

---
## Escalation Evidence

```
INTUNE REMEDIATIONS ESCALATION
==============================
Ticket #: ___________
Engineer: ___________
Date/Time: ___________

DEVICE INFORMATION
Device Name: ___________
Entra Device ID: ___________
OS Version: ___________
IME Version: ___________
Last IME Heartbeat: ___________

REMEDIATION PACKAGE
Package Name: ___________
Package ID: ___________
Detection Script Exit Code (last run): ___________
Remediation Script Exit Code (last run): ___________
Last Detection Run: ___________
Last Remediation Run: ___________
Script Output (from portal): ___________

CHECKS PERFORMED
[ ] IME service running
[ ] IME can reach Intune endpoints (all reachable: Y/N)
[ ] Device in assignment group (Y/N)
[ ] AgentExecutor.log reviewed
[ ] Script logic tested locally
[ ] Run-as context verified (SYSTEM/User)

ERROR DETAILS
AgentExecutor.log snippet: ___________
Portal device status: ___________

ACTIONS TAKEN
1. ___________
2. ___________

CURRENT STATUS
___________
```

---
## 🎓 Learning Pointers

- **Exit codes are everything.** Detection must exit `1` to trigger remediation — missing `exit 1` is the #1 cause of "detection runs but nothing happens." See [Remediations overview](https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations).
- **SYSTEM vs. user context** completely changes what registry hives and user profile paths are accessible. Test scripts in both contexts before deploying. The `Run this script using the logged-on credentials` toggle in portal properties is the key switch.
- **AgentExecutor.log is your friend** — it captures stdout/stderr from every script run, exit codes, timestamps, and policy IDs. Most Remediations issues are diagnosable from this log alone without touching the portal.
- **Script output limit is 2048 characters** in the Intune portal's device status view. If your scripts write verbose output, use log files written to `C:\ProgramData` or Windows Event Log for full detail.
- **Scope tags can silently exclude devices.** If a Remediation package has scope tags set, devices without matching scope tags will not receive the policy even if they're in the assignment group. Check: portal → [Package] → Properties → Scope tags.
- **Remediations replaced "Proactive Remediations"** branding in 2023 — same feature, new name. Some MS Docs and third-party guides still use the old name. [Current docs](https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations).
