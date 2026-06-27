# Intune Kiosk / Assigned Access — Hotfix Runbook (Mode B: Ops)
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

Run these on the kiosk device (local or via Intune Remote Help / PowerShell remoting):

```powershell
# 1. What Assigned Access config is active?
Get-AssignedAccess

# 2. Is the MDM enrollment healthy?
dsregcmd /status | Select-String -Pattern "MdmEnrolled|AzureAdJoined|WorkplaceJoined"

# 3. Check the kiosk account exists and is enabled
Get-LocalUser -Name "<KioskAccountName>" | Select Name, Enabled, PasswordExpires, LastLogon

# 4. Any recent shell launcher / assigned access events?
Get-WinEvent -LogName "Microsoft-Windows-AssignedAccess/Admin" -MaxEvents 30 |
    Select TimeCreated, Id, Message | Format-Table -Wrap

# 5. What's the current shell for the kiosk user?
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name Shell
```

| Result | Likely Cause | Next Action |
|--------|-------------|-------------|
| `Get-AssignedAccess` returns nothing | Profile not applied / wiped | [Fix 1](#fix-1--reapply-assigned-access-profile) |
| Kiosk account disabled or locked | Password policy / AAD sync | [Fix 2](#fix-2--fix-kiosk-account-state) |
| `MdmEnrolled: NO` | Device unenrolled mid-session | Re-enrol or wipe/reprovision |
| Shell = `explorer.exe` | Kiosk shell launcher not applied | [Fix 3](#fix-3--force-shell-launcher-via-csp) |
| Events show `AssignedAccess: Failed` | XML config corrupt | [Fix 4](#fix-4--rebuild-assigned-access-xml) |
| App never launches | App not provisioned for kiosk user | [Fix 5](#fix-5--ensure-app-is-provisioned-for-kiosk-user) |

---
## Dependency Cascade

<details><summary>What must be true for kiosk mode to work</summary>

```
Azure AD / Entra ID
  └── Device enrolled in Intune (AzureAD Joined or Hybrid Joined)
        └── Intune Device Configuration Profile (Kiosk type) assigned
              └── Profile targets correct group (device or user)
                    ├── Kiosk account exists on device (local or AAD user)
                    │     └── Account enabled, not locked, no expiry issues
                    ├── Assigned Access CSP receives config (MDM push)
                    │     └── AssignedAccess/Configuration OMA-URI applied
                    ├── App provisioned for kiosk user
                    │     ├── Win32 / Store app deployed to device
                    │     └── App exists in kiosk user's context
                    └── Shell Launcher (if non-UWP) licensed + configured
                          └── Requires Windows 10/11 Enterprise or Education
```

**Licence note**: Multi-App Kiosk and Shell Launcher require **Windows Enterprise or Education**. Single-App Kiosk (UWP only) works on Pro.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the policy reached the device**
```powershell
# Check MDM diagnostic report
$mdmPath = "$env:TEMP\MDMDiagReport"
New-Item -ItemType Directory -Path $mdmPath -Force | Out-Null
MdmDiagnosticsTool.exe -out $mdmPath
# Open MDMDiagReport.html in browser — look for AssignedAccess CSP
Start-Process "$mdmPath\MDMDiagReport.html"
```
Expected: AssignedAccess CSP shows your XML payload. Bad: missing or error state.

**Step 2 — Validate Assigned Access XML in registry**
```powershell
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess"
Get-ItemProperty -Path $regPath | Select -ExpandProperty Configuration
```
Expected: XML config with your kiosk app/user. Bad: empty or null.

**Step 3 — Check kiosk user's app context**
```powershell
# Run as kiosk user (or check provisioned packages)
Get-AppxPackage -AllUsers | Where-Object { $_.Name -like "*<KioskAppName>*" } |
    Select Name, PackageFullName, InstallLocation
```
Expected: Package found with InstallLocation populated. Bad: empty — app not provisioned.

**Step 4 — Event log deep dive**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-AssignedAccess/Operational" -MaxEvents 50 |
    Select TimeCreated, Id, Message | Where-Object { $_.Message -match "error|fail" } |
    Format-Table -Wrap
```
Event ID 31000 = config applied successfully. Event ID 31001/31002 = failures.

**Step 5 — Shell Launcher validation (non-UWP kiosk)**
```powershell
# Check Shell Launcher feature state
$sl = Get-WindowsOptionalFeature -Online -FeatureName "Client-EmbeddedShellLauncher" 2>$null
if (-not $sl) { "Shell Launcher feature not found — check Windows edition" }
else { $sl | Select FeatureName, State }

# Check Shell Launcher CSP config
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList" -ErrorAction SilentlyContinue
```

---
## Common Fix Paths

<details><summary>Fix 1 — Reapply Assigned Access Profile</summary>

**When**: `Get-AssignedAccess` returns nothing; policy shows applied in Intune but not on device.

```powershell
# Force Intune sync
Invoke-Command -ScriptBlock {
    $session = New-CimSession
    $params = @{
        Namespace = 'root\ccm'
        ClassName = 'SMS_Client'
        MethodName = 'TriggerSchedule'
    }
    Invoke-CimMethod @params -Arguments @{sScheduleID='{00000000-0000-0000-0000-000000000021}'} -ErrorAction SilentlyContinue
}

# Or via MDM agent
Start-Process -FilePath "DeviceEnroller.exe" -ArgumentList "/o /c /t" -NoNewWindow -Wait

# Then trigger scheduled task
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" -TaskName "Schedule*" -ErrorAction SilentlyContinue
```

After sync, check Intune portal: Device → Device configuration → Kiosk profile — status should move to "Succeeded".

**Rollback**: N/A (this is read-only triage + sync trigger)

</details>

<details><summary>Fix 2 — Fix Kiosk Account State</summary>

**When**: Kiosk account disabled, locked, or password expired.

```powershell
$kioskUser = "<KioskAccountName>"

# Enable account
Enable-LocalUser -Name $kioskUser

# Unlock if locked
# (local accounts don't "lock" the same way, but reset anyway)
$pass = ConvertTo-SecureString "TempP@ssw0rd123!" -AsPlainText -Force
Set-LocalUser -Name $kioskUser -Password $pass -PasswordNeverExpires $true

# Verify
Get-LocalUser -Name $kioskUser | Select Name, Enabled, PasswordExpires, IsAccount
```

**For AAD/Entra kiosk accounts**: Reset password in Entra admin center or via Graph, then verify sign-in is not blocked by CA policy.

```powershell
# Check if AAD account is blocked from sign-in (requires Graph PowerShell)
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUser -Filter "displayName eq '<KioskDisplayName>'" | Select DisplayName, AccountEnabled, SignInActivity
```

**Rollback**: If setting a temp password, revert to no-password/auto-login after testing.

</details>

<details><summary>Fix 3 — Force Shell Launcher via CSP (Emergency Local Apply)</summary>

**When**: Shell is still `explorer.exe` after policy sync. Emergency local fix while investigating Intune.

```powershell
# CAUTION: This is a local override. Re-image or re-enrol to make Intune authoritative again.
# Requires Windows Enterprise/Education

# Enable Shell Launcher feature
Enable-WindowsOptionalFeature -Online -FeatureName "Client-EmbeddedShellLauncher" -NoRestart

# Apply via WMI (Shell Launcher v1)
$ShellLauncherClass = [wmiclass]"\\.\root\standardcimv2\embedded:WESL_UserSetting"
$ShellLauncherClass.SetEnabled($true)

# Set shell for kiosk user (get SID first)
$kioskUser = "<KioskAccountName>"
$SID = (New-Object System.Security.Principal.NTAccount($kioskUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$ShellLauncherClass.SetCustomShell($SID, "C:\Path\To\<KioskApp>.exe", $null, $null, 0)

Write-Host "Shell Launcher configured for SID: $SID"
```

**Rollback**:
```powershell
$ShellLauncherClass.RemoveCustomShell($SID)
$ShellLauncherClass.SetEnabled($false)
```

</details>

<details><summary>Fix 4 — Rebuild Assigned Access XML</summary>

**When**: Registry shows corrupt/empty XML config; profile shows error in Intune.

1. In **Intune portal** → Devices → Configuration → your Kiosk profile → Edit
2. Re-enter the kiosk account UPN/username exactly as it appears locally
3. For Multi-App kiosk, re-validate the XML schema against: https://learn.microsoft.com/en-us/windows/configuration/lock-down-windows-10-to-specific-apps
4. Save and re-assign — force a sync

**PowerShell validation of XML before pushing**:
```powershell
$xmlContent = @'
<?xml version="1.0" encoding="utf-8" ?>
<AssignedAccessConfiguration xmlns="...">
  <!-- paste your XML here -->
</AssignedAccessConfiguration>
'@

try {
    [xml]$xmlContent
    Write-Host "XML is well-formed" -ForegroundColor Green
} catch {
    Write-Host "XML parse error: $_" -ForegroundColor Red
}
```

**Rollback**: Keep a copy of the last working XML — paste it back into the profile if the new one fails.

</details>

<details><summary>Fix 5 — Ensure App is Provisioned for Kiosk User</summary>

**When**: Kiosk config applies but app never launches; app shows in Device installs but not in kiosk user's context.

```powershell
$kioskUser = "<KioskAccountName>"
$appName   = "<KioskAppPackageName>"  # e.g., "Microsoft.WindowsCalculator"

# Check provisioned (all-users) install
$provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*$appName*" }
if (-not $provisioned) {
    Write-Warning "App not provisioned for all users — install will not be in kiosk user context"
}

# For Win32 apps — check if installed in system context
$installed = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                              "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" |
             Where-Object { $_.DisplayName -like "*$appName*" }
$installed | Select DisplayName, InstallLocation, InstallDate
```

**If UWP app not provisioned**:
- In Intune, set app assignment to **Required** for **All Devices** (not All Users)
- Ensure **Install behavior** is set to **System** for Win32
- After assignment change, trigger sync and wait 15 min

</details>

---
## Escalation Evidence

```
=== KIOSK ESCALATION PACK ===
Date/Time        : [datetime]
Device Name      : [hostname]
Entra Device ID  : [Get-Item "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts" | ...]
Intune Device ID : [portal: device properties]
Windows SKU      : [winver / (Get-WmiObject Win32_OperatingSystem).Caption]
Windows Build    : [(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild]
Kiosk Account    : [local username or UPN]
Kiosk App        : [app name / package family name]
Kiosk Type       : [Single-App UWP / Single-App Win32 / Multi-App / Shell Launcher]

MDM Enrolled     : [dsregcmd /status → MdmEnrolled]
AAD Joined       : [dsregcmd /status → AzureAdJoined]
Profile Status   : [Intune portal → Device config → Kiosk profile → device status]
Last Sync        : [Intune portal → Device → Last check-in]

AssignedAccess Registry : [HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess → Configuration value]
Shell Value             : [HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon → Shell]

Event Log Errors :
[paste from: Get-WinEvent -LogName "Microsoft-Windows-AssignedAccess/Admin" -MaxEvents 20]

MDM Diag Errors  :
[paste relevant section from MDMDiagReport.html → AssignedAccess CSP]
```

---
## 🎓 Learning Pointers

- **Single-App vs Multi-App vs Shell Launcher**: Single-App (UWP) runs on Pro, locks to one Store app, uses `AssignedAccess/Configuration`. Multi-App requires Enterprise/Education and uses a full XML profile. Shell Launcher is for Win32 replacement of explorer.exe — needs the optional feature + Enterprise licence. See: https://learn.microsoft.com/en-us/windows/configuration/assigned-access/overview

- **Kiosk account must be local or auto-created**: AAD accounts work but are finicky — local accounts with `PasswordNeverExpires` and auto-logon are far more reliable in production. Intune can create local accounts via the Kiosk profile; always use that over manual creation.

- **App must be in device context, not user context**: Win32 kiosk apps must install as **System** or the kiosk account won't find them. UWP apps must be provisioned (all-users install). A user-context Win32 install will silently fail to launch.

- **MDM Diagnostics Tool is your friend**: `MdmDiagnosticsTool.exe -out C:\Temp\diag` dumps a full HTML report including the exact XML the CSP received. Event ID 31000 in the AssignedAccess/Admin log = success; anything else = read the message carefully.

- **Profile assignment pitfall**: Kiosk profiles assigned to **user groups** apply when that user signs in. Profiles assigned to **device groups** apply at machine scope. For single-account kiosk, always assign to **device group** — user-targeted kiosk profiles are unreliable for auto-logon scenarios.

- **Shell Launcher v1 vs v2**: Shell Launcher v2 (WMI-based) was deprecated in favour of v1 (CSP-based) for Intune management. If mixing methods, conflicts occur. Stick to CSP-delivered config and use `Get-WindowsOptionalFeature` to verify the feature is enabled before applying. Ref: https://learn.microsoft.com/en-us/windows-hardware/customize/enterprise/shell-launcher
