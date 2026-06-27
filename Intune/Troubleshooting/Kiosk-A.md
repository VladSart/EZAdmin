# Intune Kiosk / Assigned Access — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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

This runbook covers **Windows Kiosk / Assigned Access** managed via **Microsoft Intune** MDM on AzureAD-joined or Hybrid-joined devices. It covers:

- **Single-App Kiosk** (UWP) — lock device to one Store/system app
- **Single-App Kiosk** (Win32 / Shell Launcher) — replace Explorer.exe with a custom shell
- **Multi-App Kiosk** — restricted Start menu/taskbar for frontline workers

**Out of scope**: Local GPO kiosk (non-MDM), Windows 10 S Mode kiosk, Intune dedicated Android kiosk (separate MDM stack).

**Licence requirements**:
| Kiosk Type | Minimum Windows Edition |
|------------|------------------------|
| Single-App UWP | Pro, Enterprise, Education |
| Multi-App | Enterprise or Education only |
| Shell Launcher v1/v2 | Enterprise or Education only |
| Kiosk Browser app | Any (free from Store) |

---
## How It Works

<details><summary>Full architecture</summary>

### CSP Delivery Path

Intune pushes kiosk configuration via the **AssignedAccess CSP** (Configuration Service Provider). The MDM agent (`DMClient`) receives the policy as an OMA-URI payload and writes it to the Windows shell infrastructure.

```
Intune (Portal Config)
  │
  ▼
Graph API → Device Configuration Profile
  │           OMA-URI: ./Vendor/MSFT/AssignedAccess/Configuration
  ▼
MDM Agent (DMClient.exe) running as SYSTEM
  │
  ▼
AssignedAccess CSP (Windows Runtime component)
  │
  ├── Writes XML to: HKLM\SOFTWARE\Microsoft\Windows\AssignedAccess → Configuration
  ├── Registers account with ShellAppRuntime
  └── Configures auto-logon (if enabled in profile)
        │
        ▼
  Winlogon / ShellAppRuntime
  │
  ├── Single-App UWP: Launches app via ApplicationFrameHost, locks input
  ├── Multi-App: Launches restricted shell (ShellExperienceHost with lockdown XML)
  └── Shell Launcher: Replaces Shell= registry value for the kiosk account
```

### Auto-Logon Integration

When Intune's kiosk profile includes auto-logon, the CSP sets:
- `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\AutoAdminLogon = 1`
- `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\DefaultUserName = <kiosk account>`
- `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\DefaultPassword` (encrypted via LSA)

**Security implication**: This stores credentials in the registry (LSA-protected but present). For high-security environments, use a dedicated local account with a long random password — never reuse service/admin accounts.

### XML Schema Internals (Multi-App)

The assigned access XML has three root sections:
1. **`<Profiles>`** — defines what each config can see (apps, taskbar, Start layout)
2. **`<Configs>`** — maps user accounts to profiles
3. **`<BinaryDescriptionXml>`** / **`<StartLayoutXml>`** embedded inside profile

The schema is validated by the CSP on receipt. Any XML error causes a silent failure — the config is rejected with no visible UI feedback. The only evidence is in the AssignedAccess event log.

### Shell Launcher Architecture

Shell Launcher works differently from Assigned Access — it hooks into the Winlogon shell chain:
1. The **Client-EmbeddedShellLauncher** optional Windows feature must be enabled
2. ShellLauncher CSP (`./Vendor/MSFT/ShellLauncher`) sets a per-SID shell value
3. On login for that SID, `Winlogon` reads the SID-specific shell from `WESL_UserSetting` WMI class (Shell Launcher v1) or via CSP profile (v2)
4. The custom executable replaces Explorer — no taskbar, no Start menu, no desktop unless the app provides them
5. Return codes from the app determine what happens next: restart, reboot, or run another app

</details>

---
## Dependency Stack

```
Internet / Intune Service
  └── MDM Channel (HTTPS 443) — Device must reach *.manage.microsoft.com
        └── DMClient.exe (MDM Agent) — Windows service (Schedule tasks under SYSTEM)
              └── AssignedAccess CSP | ShellLauncher CSP
                    ├── Windows Edition ≥ Enterprise (for Multi-App / Shell Launcher)
                    ├── Target Account (local or AAD user)
                    │     ├── Account must exist before CSP applies config
                    │     └── Account must be enabled, not expired
                    ├── Kiosk App installed on device (system context)
                    │     ├── UWP: provisioned via Add-AppxProvisionedPackage or Intune Store app
                    │     └── Win32: deployed via Intune Win32 app, install context = System
                    └── Shell Infrastructure
                          ├── Winlogon (auto-logon keys)
                          ├── ShellAppRuntime (UWP single-app)
                          └── Client-EmbeddedShellLauncher feature (Shell Launcher)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Device boots to normal desktop for kiosk user | AssignedAccess config not applied | Check registry `HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess` |
| Kiosk profile shows "Not applicable" in Intune | Wrong Windows edition (Pro vs Enterprise) or wrong assignment type | Check device SKU with `Get-WmiObject Win32_OperatingSystem` |
| App launches then immediately closes | App crash, missing dependency, or wrong install context | Check Application event log, ensure system-context install |
| Multi-app kiosk shows blank Start | XML schema error — StartLayoutXml malformed | Validate XML against schema, check Event ID 31001 |
| Auto-logon not working | AutoAdminLogon keys missing or Credential Guard interference | Check Winlogon registry keys |
| Shell Launcher app not replacing Explorer | Feature not enabled or SID mismatch | Check `Client-EmbeddedShellLauncher` feature state |
| Kiosk exits to desktop on app crash | App return code not mapped; default is "restart app" | Check WESL_UserSetting or CSP ReturnCodeAction |
| Policy applied in Intune but never reaches device | Device check-in failed / sync issue | Check `dsregcmd /status`, last sync time in portal |
| "The signed-in user does not have access" on kiosk app | App deployed as user-context, not system | Reassign Intune app with Install behavior = System |
| Second user can break kiosk by logging in | Account filter not configured | Multi-App: add all accounts to `<Configs>`; Single-App: use auto-logon |

---
## Validation Steps

**Step 1 — Windows Edition check**
```powershell
(Get-WmiObject Win32_OperatingSystem).Caption
(Get-WmiObject Win32_OperatingSystem).OperatingSystemSKU
# SKU 48 = Enterprise, 121 = Enterprise LTSC, 4 = Enterprise (Server eval)
# SKU 1/101 = Home, 16/147 = Pro — Multi-App/ShellLauncher WILL FAIL
```
Good: Caption contains "Enterprise" or "Education". Bad: "Pro" or "Home" for anything beyond single-UWP.

**Step 2 — MDM enrollment state**
```powershell
dsregcmd /status | Select-String "MdmEnrolled|AzureAdJoined|DeviceName|TenantId"
```
Good: `MdmEnrolled : YES`, `AzureAdJoined : YES`. Bad: either NO → enrollment issue, fix before kiosk.

**Step 3 — AssignedAccess CSP registry state**
```powershell
$cfg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess" -Name "Configuration" -ErrorAction SilentlyContinue
if ($cfg) { $cfg.Configuration } else { "No configuration present" }
```
Good: returns XML with your profile. Bad: null or empty → policy didn't reach CSP.

**Step 4 — Kiosk account validation**
```powershell
$user = "<KioskAccountName>"
$acct = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
if (-not $acct) { "Account MISSING" }
else {
    [PSCustomObject]@{
        Name             = $acct.Name
        Enabled          = $acct.Enabled
        PasswordExpires  = $acct.PasswordExpires
        LastLogon        = $acct.LastLogon
        SID              = $acct.SID.Value
    }
}
```
Good: Enabled=True, PasswordExpires=null (never). Bad: Enabled=False or expires in past.

**Step 5 — App provisioning check**
```powershell
$appName = "<KioskAppName>"  # partial match OK
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*$appName*" } |
    Select DisplayName, PackageName, InstallLocation
```
Good: Package found with InstallLocation. Bad: empty → app not provisioned for all users.

**Step 6 — AssignedAccess event log success marker**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-AssignedAccess/Admin" -MaxEvents 20 |
    Where-Object { $_.Id -eq 31000 } | Select -First 1 TimeCreated, Message
```
Good: Event ID 31000 present with recent timestamp. Bad: missing or only 31001/31002 → XML rejected.

**Step 7 — Auto-logon registry check**
```powershell
$wl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Get-ItemProperty -Path $wl | Select AutoAdminLogon, DefaultUserName, DefaultDomainName
```
Good: `AutoAdminLogon = 1`, `DefaultUserName = <kioskAccount>`. Bad: `AutoAdminLogon = 0` → device won't auto-login to kiosk.

---
## Troubleshooting Steps (by phase)

### Phase 1: Policy Not Reaching Device

1. Confirm device enrolled: `dsregcmd /status` → `MdmEnrolled: YES`
2. Check last sync: Intune portal → Device → Overview → Last check-in (should be <1h for active kiosk)
3. Force sync:
   ```powershell
   Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o /c" -NoNewWindow
   ```
4. Run MDM diagnostics: `MdmDiagnosticsTool.exe -out C:\Temp\KioskDiag`
5. In the HTML report, search for `AssignedAccess` — verify the XML payload is present and shows no errors

### Phase 2: Policy Applied but Kiosk Not Active

1. Check `HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess\Configuration` for your XML
2. Look for Event ID 31000 in AssignedAccess/Admin log (applied) vs 31001 (failed)
3. If 31001: decode the error code from the event message — common codes:
   - `0x80070522`: Privilege error — MDM agent ran without SYSTEM privileges
   - `0x80070005`: Access denied — account doesn't exist yet
   - `0x8007000D`: Data invalid — malformed XML
4. If XML is rejected, export it and validate offline with an XML validator against the AssignedAccess schema
5. Re-examine the `<Configs>` section — the account/UPN must exactly match what exists on the device

### Phase 3: Kiosk Launches but App Fails

1. Check Application event log for crash events (Event ID 1000 = app crash)
2. Verify app is system-context installed:
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\*" | Where-Object { $_.PSChildName -like "*<app>*" }
   ```
3. For UWP apps, check if the package is in a "needs repair" state:
   ```powershell
   Get-AppxPackage -AllUsers | Where-Object { $_.Name -like "*<app>*" } | Select Name, Status
   ```
4. For Win32, check install log at `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log`
5. Test app launch as kiosk user:
   ```powershell
   Start-Process -FilePath "runas" -ArgumentList "/user:<KioskAccount> <AppPath>"
   ```

### Phase 4: Shell Launcher Not Working

1. Check feature installed:
   ```powershell
   Get-WindowsOptionalFeature -Online -FeatureName "Client-EmbeddedShellLauncher"
   ```
2. If state = `Disabled`: Enable it, then force a policy re-push (or enable via Intune profile)
3. Verify SID is correct in Shell Launcher config — SID mismatch is the #1 cause:
   ```powershell
   $user = "<KioskAccount>"
   $SID = (New-Object System.Security.Principal.NTAccount($user)).Translate([System.Security.Principal.SecurityIdentifier]).Value
   Write-Host "SID: $SID"
   # Compare this SID to what's in WESL_UserSetting WMI class
   Get-WmiObject -Namespace "root\standardcimv2\embedded" -Class WESL_UserSetting | Select Sid, Shell, Enabled
   ```
4. If mismatched: remove old SID entry, add correct one

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full Reset and Reprovisioning</summary>

**When**: Device in unknown state, kiosk never worked, policy applied but nothing happens.

```powershell
# Step 1: Remove existing AssignedAccess config (forces re-application)
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess" -Name "Configuration" -ErrorAction SilentlyContinue

# Step 2: Clear Shell Launcher WMI if present
try {
    $wmiClass = [wmiclass]"\\.\root\standardcimv2\embedded:WESL_UserSetting"
    $wmiClass.SetEnabled($false)
    Write-Host "Shell Launcher disabled"
} catch {
    Write-Host "Shell Launcher WMI not found (OK if not using Shell Launcher)"
}

# Step 3: Reset auto-logon
$wl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $wl -Name "AutoAdminLogon" -Value "0"

# Step 4: Force MDM sync
Start-Process "DeviceEnroller.exe" -ArgumentList "/o /c" -NoNewWindow -Wait
Start-Sleep -Seconds 30

# Step 5: Verify config returned
$cfg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess" -Name "Configuration" -ErrorAction SilentlyContinue
if ($cfg) { Write-Host "Config re-applied" -ForegroundColor Green }
else { Write-Warning "Config still missing — check Intune portal for profile errors" }
```

**Rollback**: None needed — this is a reset to pull clean config from Intune.

</details>

<details><summary>Playbook 2 — Validate and Fix Multi-App XML</summary>

**When**: Multi-app kiosk shows blank or default Start; Event ID 31001 in log.

```powershell
# Extract current (rejected or applied) XML from registry
$cfg = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess" -ErrorAction SilentlyContinue).Configuration
if ($cfg) {
    $cfg | Out-File "C:\Temp\CurrentKioskXML.xml"
    Write-Host "Exported to C:\Temp\CurrentKioskXML.xml"
} else {
    Write-Warning "No XML in registry — policy hasn't reached device yet"
}

# Validate XML is well-formed
try {
    [xml](Get-Content "C:\Temp\CurrentKioskXML.xml" -Raw)
    Write-Host "XML is well-formed" -ForegroundColor Green
} catch {
    Write-Host "XML parse error: $_" -ForegroundColor Red
}
```

Common XML mistakes:
- Package Family Name typo (get correct one via `Get-AppxPackage | Select PackageFamilyName`)
- StartLayoutXml not base64-encoded when required
- Missing `xmlns` attribute on root element
- Account name case mismatch (XML is case-sensitive for account matching)
- FullScreenMode / StartMenuAllAppsListHidden used on unsupported build

**Rollback**: Keep a copy of the working XML. In Intune, profile edits are versioned — roll back by reverting to previous profile version.

</details>

<details><summary>Playbook 3 — Re-enrol Device for Clean Kiosk State</summary>

**When**: Kiosk config is corrupted beyond repair; quickest path to clean state.

```powershell
# Unenrol from Intune (preserves AAD join)
$enrolled = Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Enrollments" |
            Get-ItemProperty | Where-Object { $_.ProviderID -eq "MS DM Server" }
$enrollmentID = $enrolled.PSChildName

if ($enrollmentID) {
    # Run unenrol
    Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/U $enrollmentID /c" -NoNewWindow -Wait
    Write-Host "Unenrolled enrollment: $enrollmentID"
} else {
    Write-Warning "No Intune enrollment found"
}
```

Then re-enrol:
1. **Settings → Accounts → Access work or school → Connect**
2. Or: `Start-Process "ms-device-enrollment:"`
3. Wait 10-15 minutes for kiosk profile to re-apply

**Rollback**: N/A — re-enrol is non-destructive to user data; only MDM policies are reset.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects full kiosk diagnostic evidence pack
.NOTES     Run as Administrator on the kiosk device
#>

$outDir = "C:\Temp\KioskEvidencePack_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# Device identity
dsregcmd /status > "$outDir\dsregcmd_status.txt"

# OS info
Get-WmiObject Win32_OperatingSystem | Select Caption, Version, BuildNumber, OperatingSystemSKU |
    Export-Csv "$outDir\os_info.csv" -NoTypeInformation

# MDM enrollment info
Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Enrollments" |
    Get-ItemProperty | Export-Csv "$outDir\enrollments.csv" -NoTypeInformation

# AssignedAccess registry
$cfg = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess" -ErrorAction SilentlyContinue).Configuration
if ($cfg) { $cfg | Out-File "$outDir\assigned_access_config.xml" }
else { "No config present" | Out-File "$outDir\assigned_access_config.xml" }

# Winlogon keys
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" |
    Select AutoAdminLogon, DefaultUserName, DefaultDomainName, Shell |
    Export-Csv "$outDir\winlogon_keys.csv" -NoTypeInformation

# Local users
Get-LocalUser | Select Name, Enabled, PasswordExpires, LastLogon, SID |
    Export-Csv "$outDir\local_users.csv" -NoTypeInformation

# AssignedAccess event log
Get-WinEvent -LogName "Microsoft-Windows-AssignedAccess/Admin" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select TimeCreated, Id, Message | Export-Csv "$outDir\assigned_access_events.csv" -NoTypeInformation

# Shell Launcher WMI
try {
    Get-WmiObject -Namespace "root\standardcimv2\embedded" -Class WESL_UserSetting |
        Select Sid, Shell, Enabled, ReturnCode |
        Export-Csv "$outDir\shell_launcher_config.csv" -NoTypeInformation
} catch {
    "Shell Launcher WMI not available or not configured" | Out-File "$outDir\shell_launcher_config.csv"
}

# Optional features
Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -like "*Shell*" -or $_.FeatureName -like "*Kiosk*" } |
    Export-Csv "$outDir\optional_features.csv" -NoTypeInformation

# Installed apps (all users)
Get-AppxProvisionedPackage -Online | Export-Csv "$outDir\provisioned_apps.csv" -NoTypeInformation

# MDM diagnostics
$mdmOut = "$outDir\MDMDiag"
New-Item -ItemType Directory -Path $mdmOut -Force | Out-Null
MdmDiagnosticsTool.exe -out $mdmOut 2>&1 | Out-Null

Write-Host "Evidence pack collected at: $outDir" -ForegroundColor Green
Write-Host "Zip and attach to ticket: Compress-Archive -Path '$outDir' -DestinationPath '$outDir.zip'"
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Get current kiosk config | `Get-AssignedAccess` |
| Get AssignedAccess XML from registry | `(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess").Configuration` |
| Check MDM enrollment | `dsregcmd /status` |
| Force MDM sync | `Start-Process DeviceEnroller.exe -Args "/o /c" -NoNewWindow` |
| Check Windows edition SKU | `(Get-WmiObject Win32_OperatingSystem).OperatingSystemSKU` |
| Check kiosk account | `Get-LocalUser -Name "<user>"` |
| Check provisioned apps | `Get-AppxProvisionedPackage -Online \| Select DisplayName` |
| Get kiosk user SID | `(New-Object System.Security.Principal.NTAccount("<user>")).Translate([SID]).Value` |
| Check Shell Launcher WMI | `Get-WmiObject -Namespace root\standardcimv2\embedded -Class WESL_UserSetting` |
| Check Shell Launcher feature | `Get-WindowsOptionalFeature -Online -FeatureName Client-EmbeddedShellLauncher` |
| AssignedAccess events | `Get-WinEvent -LogName "Microsoft-Windows-AssignedAccess/Admin" -MaxEvents 20` |
| MDM diagnostic report | `MdmDiagnosticsTool.exe -out C:\Temp\diag` |
| Auto-logon keys | `Get-ItemProperty "HKLM:\...\Winlogon" \| Select Auto*,Default*` |

---
## 🎓 Learning Pointers

- **The three kiosk modes are architecturally different**: Single-App UWP uses AssignedAccess (locks shell to one app via AppContainer restrictions), Multi-App uses AssignedAccess + a custom Start layout XML (still the same CSP, much more complex), and Shell Launcher is a completely separate subsystem that replaces Explorer.exe entirely. Treating them as variations of the same feature leads to misdiagnosis. See: https://learn.microsoft.com/en-us/windows/configuration/kiosk-methods

- **PackageFamilyName is your single most important string**: For UWP kiosk, every app reference in the XML uses PFN, not display name. Get the exact PFN with `Get-AppxPackage -AllUsers | Select Name, PackageFamilyName`. One character wrong in XML = silent failure with a cryptic event log entry. Always copy-paste, never type.

- **Multi-App kiosk XML schema changes between Windows builds**: Features like `<FullScreen>` and `<ShowTaskbar>` were added in later builds. Pushing a config with newer schema elements to older devices causes silent rejection. Always test against the lowest-build device in your fleet before rollout. Schema reference: https://learn.microsoft.com/en-us/windows/configuration/lock-down-windows-10-to-specific-apps

- **Credential Guard breaks auto-logon**: If VBS/Credential Guard is enabled and you're trying to configure auto-logon for the kiosk account, it will silently fail — Credential Guard prevents plaintext credential storage in Winlogon. Either disable Credential Guard on kiosk devices (policy carve-out), use a TPM-backed auto-logon workaround, or require manual initial login. See: https://learn.microsoft.com/en-us/windows/security/identity-protection/credential-guard/configure

- **Assigned Access is per-user, not per-device (mostly)**: The XML `<Configs>` section maps user accounts to profiles. If you want any user who logs in to get kiosk experience, every account must be listed — there's no wildcard for local accounts. Use auto-logon to a dedicated local account to avoid this complexity for true single-user kiosks.

- **The AssignedAccess/Admin event log is undersized by default**: Default max size is 1MB, which fills quickly on active kiosks with repeated lock/unlock cycles. Increase it: `wevtutil sl "Microsoft-Windows-AssignedAccess/Admin" /ms:20971520` (sets to 20MB). Without this, you'll lose the failure events you need for diagnosis.
