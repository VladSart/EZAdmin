# Windows LAPS via Intune — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [LAPS Flavour Comparison](#laps-flavour-comparison)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Applies to:** Windows LAPS (built into Windows 11 22H2+, Windows 10 20H2+ with April 2023 cumulative update KB5025221+)
- **Deployment method covered:** Intune (CSP-based policy); AD-integrated LAPS also referenced for hybrid comparison
- **Does not cover:** Legacy Microsoft LAPS (the old .msi-based product), macOS LAPS, non-Windows platforms
- **Licensing:** Included in all Intune/Microsoft 365 plans that include Intune device management
- **Admin roles needed:** Intune Administrator or Device Configuration Administrator; LAPS secret read requires **Local admin password recovery** RBAC permission in Intune

---

## How It Works

<details><summary>Full architecture — policy, rotation, storage, and retrieval</summary>

### What Windows LAPS Does

Windows LAPS manages a **local administrator account** on each enrolled device by:
1. Setting a randomly generated password on the designated local admin account
2. Storing that password (encrypted) in either **Entra ID** or **Active Directory**
3. Rotating the password automatically based on a configurable schedule or on-demand trigger

The key security benefit: no two devices share the same local admin password. Even if one device is compromised, the password doesn't pivot to others.

### Architectural Flow (Entra-backed LAPS)

```
Intune Policy → CSP (./Device/Vendor/MSFT/LAPS) → Windows LAPS agent (built into OS)
                                                            │
                                                     Manages local account
                                                     Generates random password
                                                            │
                                                     Password encrypted with:
                                                       - Entra ID tenant-specific key (cloud)
                                                       - DC certificate (AD-mode)
                                                            │
                                          Stored in Entra ID device object (cloud)
                                          or AD computer object attribute (hybrid)
                                            msLAPS-PasswordExpirationTime
                                            msLAPS-Password (encrypted)
                                            msLAPS-EncryptedPassword
```

### Password Storage Locations

| Mode | Storage Location | Retrieval Method |
|------|-----------------|-----------------|
| Entra-backed (cloud) | Entra device object — `localAdminPassword` property | Intune portal > Device > Local admin password |
| AD-backed (hybrid) | AD computer object — `msLAPS-*` attributes | LAPS PowerShell module, LAPS UI, ADUC |
| AD legacy (old LAPS) | AD computer object — `ms-Mcs-AdmPwd` attribute | Legacy LAPS UI or `Get-AdmPwdPassword` |

### Rotation Triggers

Password rotates when ANY of these occur:
1. `PasswordExpirationTime` is reached (configured interval, default 30 days)
2. Manual rotation triggered via Intune (Rotate local admin password action)
3. The local admin account password is successfully retrieved (if `PostAuthenticationActions` includes rotate)
4. The device detects the account password has been manually changed outside of LAPS

### Account Management Options

LAPS can manage either:
- **The built-in Administrator account** (SID S-1-5-21-...-500) — not recommended (well-known SID)
- **A custom named account** — LAPS can create it if it doesn't exist (`AccountName` + `AccountManageMode = CreateOrManage`)

### Encryption

In Entra-backed mode, the password is encrypted before upload using a Microsoft-managed Entra tenant key. Only principals with the **Local admin password recovery** Intune RBAC permission can decrypt and view it. The password in the Entra device object is never stored in plaintext.

</details>

---

## Dependency Stack

```
[Windows LAPS Agent — built into OS (Win10 20H2+ KB5025221 / Win11 22H2+)]
         │
[Intune LAPS Policy — CSP path: ./Device/Vendor/MSFT/LAPS]
    ├── BackupDirectory: AzureAD (cloud) or ActiveDirectory (hybrid)
    ├── AccountName + AccountManageMode
    ├── PasswordAgeDays, PasswordComplexity, PasswordLength
    └── PostAuthenticationActions, PostAuthenticationResetDelay
         │
[MDM Enrollment — device must be Intune enrolled]
    └── Hybrid: also requires Entra Connect sync (for AD-backed mode)
         │
[Entra ID — device object storage (cloud mode)]
    └── Local admin password property on device object
         │
[OR Active Directory — computer object (hybrid AD-backed mode)]
    ├── msLAPS-Password / msLAPS-EncryptedPassword attributes
    └── AD schema must be extended (adschema.ldf)
         │
[RBAC — "Local admin password recovery" permission]
    └── Controls who can view the password in Intune/Entra portal
         │
[Windows Version Check]
    └── Win10 20H2 + KB5025221 (April 2023 CU) minimum
        Win11 21H2 + KB5025224 minimum
        Win11 22H2+ — LAPS built in, no KB required
```

---

## LAPS Flavour Comparison

| Feature | Windows LAPS (Entra) | Windows LAPS (AD) | Legacy LAPS |
|---------|---------------------|-------------------|-------------|
| Storage | Entra device object | AD computer object | AD computer object |
| Encryption | ✅ Entra tenant key | ✅ DC cert (encrypted) | ❌ Plaintext in AD |
| Cloud-native | ✅ | ❌ | ❌ |
| Requires on-prem DC | ❌ | ✅ | ✅ |
| AD schema extension | Not required | Required | Required (different) |
| Intune managed | ✅ Native CSP | ✅ CSP + AD | Via custom script |
| Account creation | ✅ Built-in | ✅ Built-in | ❌ Manual |
| Post-auth rotation | ✅ | ✅ | ❌ |
| Audit log | Entra audit | AD audit + Event Log | AD audit + Event Log |
| Recommended for | Cloud/hybrid | On-prem heavy | Legacy only |

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| "No local admin password available" in Intune | LAPS not yet uploaded password (within grace period), or device not enrolled | Check device LAPS event log — Event ID 10018 |
| Password not rotating on schedule | Policy not delivered, or device offline during scheduled rotation | `lapschecker.exe` output; check policy delivery |
| Password works but then fails immediately | Post-auth rotation fired (password rotated after use) | Check `PostAuthenticationActions` setting |
| LAPS policy shows "Conflict" in Intune | Multiple LAPS policies assigned to same device | Remove duplicate policy assignments |
| Custom account not being created | `AccountManageMode` not set to `CreateOrManage`, or account name has space | Verify CSP setting and account name |
| Built-in admin account being managed when custom account intended | `AccountName` not set or empty in policy | Set `AccountName` explicitly in Intune policy |
| Password retrieval denied in portal | User lacks "Local admin password recovery" RBAC role | Assign role in Intune > Tenant admin > Roles |
| Event ID 10003 — backup failed | Device can't reach Entra (network issue), or throttling | Check device internet connectivity; retry |
| AD-backed LAPS not storing password | AD schema not extended, or DC version too old | Verify `msLAPS-*` attributes exist in AD schema |
| Rotation via Intune "rotate" action not working | Device offline or policy sync pending | Trigger sync first; device must check in |

---

## Validation Steps

**1. Verify Windows LAPS is supported on the device**
```powershell
# Check Windows version
[System.Environment]::OSVersion.Version
(Get-WinEvent -LogName "System" | Where-Object {$_.Id -eq 6013} | Select-Object -First 1).TimeCreated  # uptime anchor

# Check for LAPS built-in support
Get-Command lapschecker.exe -ErrorAction SilentlyContinue
# If not found: device may need KB5025221 or is too old
```

**2. Check LAPS policy delivery via registry/CSP**
```powershell
# Registry view of delivered LAPS policy (read-only)
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Policies\LAPS" -ErrorAction SilentlyContinue
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config" -ErrorAction SilentlyContinue
```
Key values to confirm: `BackupDirectory` (1=AD, 2=Entra), `PasswordAgeDays`, `AccountName`.

**3. Check LAPS agent status and last rotation**
```powershell
# LAPS event log
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 50 |
    Select-Object TimeCreated, Id, Message | Format-Table -Wrap
```
Key event IDs:
- **10018** — password successfully backed up to Entra/AD
- **10020** — password rotation triggered (reason included)
- **10023** — account created/managed successfully
- **10003** — backup failed (error code in message)

**4. Verify LAPS password is present in Entra**
```powershell
Connect-MgGraph -Scopes "DeviceLocalCredential.Read.All"
$deviceId = (Get-MgDevice -Filter "displayName eq '<ComputerName>'").Id
Get-MgDeviceLocalCredential -DeviceId $deviceId | Select-Object PasswordExpirationDateTime, AccountName
```
If no result: LAPS has not uploaded a password yet for this device.

**5. Verify RBAC permission for password retrieval**
```powershell
# Via Graph — check current user's assigned Intune roles
Connect-MgGraph -Scopes "DeviceManagementRBAC.Read.All"
$me = (Get-MgUser -UserId "me").Id
Get-MgDeviceManagementRoleAssignment | Where-Object { $_.Members -contains $me }
```
Look for role with "Local admin password recovery" permission.

**6. Check password expiry date on device**
```powershell
# Run on target device
lapschecker.exe
```
Output shows: current account, password expiry, backup directory, last backup time.

**7. Verify AD schema extension (AD-backed mode)**
```powershell
# Run on DC or with AD module
Get-ADObject -SearchBase (Get-ADRootDSE).schemaNamingContext -Filter {name -like "msLAPS-*"} |
    Select-Object Name
```
Expected: `msLAPS-Password`, `msLAPS-EncryptedPassword`, `msLAPS-PasswordExpirationTime`, `msLAPS-EncryptedPasswordHistory`.

---

## Troubleshooting Steps by Phase

### Phase 1 — Policy Not Delivered

1. Check Intune device check-in: Intune portal > Device > Device check-in status
2. Verify LAPS policy assignment — must target the device (or user) group containing this device
3. Check for policy conflicts: Intune > Device > Configuration profiles > check for "Conflict" status
4. Trigger manual sync: `Start-Process "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"`
5. Check registry after sync: `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config"`

### Phase 2 — LAPS Policy Delivered but No Password Uploaded

1. Check Event ID 10003 — backup failure — and note the error code
2. Common causes:
   - **Network:** device can't reach `enterpriseregistration.windows.net` or `login.microsoftonline.com`
   - **Not joined:** `dsregcmd /status` — verify `AzureAdJoined: YES` or `DomainJoined: YES`
   - **OS version:** device pre-KB5025221 on Win10 — LAPS is not present
3. For AD-backed mode: verify schema extension and DC reachability
4. Check `lapschecker.exe` output for explicit error messaging

### Phase 3 — Password Available but Doesn't Work

1. Check if password was rotated after retrieval (`PostAuthenticationActions = 1` or `3`)
2. In Intune portal, the displayed password may already be the new one post-rotation — verify timestamp
3. If local admin account was disabled: `net user administrator /active:yes` (or the custom account name)
4. Verify the correct account name — LAPS may manage a custom account, not the built-in Administrator

### Phase 4 — Password Not Rotating

1. Check `PasswordAgeDays` policy — confirm it's set to a value (e.g., 30)
2. Check device last seen in Intune — if offline, rotation can't happen
3. Use Intune "Rotate local admin password" device action to force immediate rotation
4. After rotation, wait for device to check in; Event ID 10020 confirms completion
5. Verify `lapschecker.exe` shows updated expiry date

### Phase 5 — Post-Authentication Rotation Breaking Workflows

**Scenario:** Engineers use the LAPS password to RDP, then find it's rotated before they finish their session.

1. Check `PostAuthenticationActions` setting:
   - `0` = No action (never rotate after use)
   - `1` = Reset password after grace period
   - `3` = Reset password AND logoff after grace period
2. Increase `PostAuthenticationResetDelay` (default 24 hours) to accommodate longer sessions
3. Or set `PostAuthenticationActions = 0` if post-use rotation is not required by policy

---

## Remediation Playbooks

<details><summary>Playbook 1 — Rotate LAPS password on-demand via Graph</summary>

```powershell
# Force immediate password rotation via Graph
Connect-MgGraph -Scopes "DeviceLocalCredential.ReadWrite.All", "Device.Read.All"

$deviceId = (Get-MgDevice -Filter "displayName eq '<ComputerName>'").Id
if (-not $deviceId) {
    Write-Error "Device not found in Entra ID"
    return
}

# Trigger rotation
Invoke-MgRotateDeviceLocalAdminPassword -DeviceId $deviceId
Write-Host "Rotation triggered. Wait for device to check in and upload new password." -ForegroundColor Green
```

</details>

<details><summary>Playbook 2 — Retrieve LAPS password from Entra via Graph</summary>

```powershell
# Retrieve current LAPS password (requires DeviceLocalCredential.Read.All)
Connect-MgGraph -Scopes "DeviceLocalCredential.Read.All", "Device.Read.All"

$computerName = "<ComputerName>"
$device = Get-MgDevice -Filter "displayName eq '$computerName'"
if (-not $device) {
    Write-Error "Device '$computerName' not found in Entra ID"
    return
}

$cred = Get-MgDeviceLocalCredential -DeviceId $device.Id
if ($cred) {
    Write-Host "Account: $($cred.AccountName)" -ForegroundColor Cyan
    Write-Host "Password expires: $($cred.PasswordExpirationDateTime)" -ForegroundColor Cyan
    # Password value is base64 encoded
    $password = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($cred.BackupDetail.Password))
    Write-Host "Password: $password" -ForegroundColor Yellow
    Write-Host "⚠️  Rotation may occur after this retrieval depending on PostAuthenticationActions setting" -ForegroundColor Red
} else {
    Write-Host "No LAPS password found for device '$computerName'" -ForegroundColor Red
}
```

</details>

<details><summary>Playbook 3 — Bulk LAPS password status report</summary>

```powershell
# Report LAPS status for all Intune-managed Windows devices
Connect-MgGraph -Scopes "DeviceLocalCredential.Read.All", "Device.Read.All", "DeviceManagementManagedDevices.Read.All"

$intuneDevices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All |
    Select-Object DeviceName, Id, EnrolledDateTime, LastSyncDateTime, AzureAdDeviceId

$report = foreach ($device in $intuneDevices) {
    $laps = $null
    try {
        $entraDevice = Get-MgDevice -Filter "deviceId eq '$($device.AzureAdDeviceId)'" -ErrorAction Stop
        if ($entraDevice) {
            $laps = Get-MgDeviceLocalCredential -DeviceId $entraDevice.Id -ErrorAction Stop
        }
    } catch {}

    [PSCustomObject]@{
        DeviceName          = $device.DeviceName
        EnrolledDate        = $device.EnrolledDateTime
        LastSync            = $device.LastSyncDateTime
        LAPSConfigured      = ($null -ne $laps)
        LAPSAccountName     = $laps.AccountName
        LAPSPasswordExpiry  = $laps.PasswordExpirationDateTime
    }
}

$report | Export-Csv "$env:TEMP\LAPS-Status-Report.csv" -NoTypeInformation

$withLAPS = ($report | Where-Object LAPSConfigured).Count
$total = $report.Count
Write-Host "LAPS configured: $withLAPS / $total ($([math]::Round($withLAPS/$total*100,1))%)" -ForegroundColor Cyan
Write-Host "Report saved to $env:TEMP\LAPS-Status-Report.csv" -ForegroundColor Green
```

</details>

<details><summary>Playbook 4 — Extend AD schema for Windows LAPS (AD-backed mode)</summary>

```powershell
# Run on a machine with Domain Admin rights
# Windows LAPS is installed natively — schema update ships with Windows

# Verify current schema state
$schemaPath = (Get-ADRootDSE).schemaNamingContext
$existing = Get-ADObject -SearchBase $schemaPath -Filter {name -like "msLAPS-*"} -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Windows LAPS schema attributes already present" -ForegroundColor Green
    $existing | Select-Object Name | Format-Table
} else {
    Write-Host "Windows LAPS schema NOT extended — running update" -ForegroundColor Yellow
    # Extend schema using the built-in cmdlet
    Update-LapsADSchema -Verbose
    Write-Host "Schema extended. Verify with Get-ADObject -Filter {name -like 'msLAPS-*'}" -ForegroundColor Green
}

# Grant computer objects permission to write their own LAPS attributes
# (Run once per OU)
Set-LapsADComputerSelfPermission -Identity "OU=Workstations,DC=domain,DC=com"
```

</details>

---

## Evidence Pack

```powershell
# Windows LAPS Evidence Collector — run on affected device
$out = "$env:TEMP\LAPS-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 1. LAPS event log
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$out\LAPS-eventlog.csv" -NoTypeInformation

# 2. lapschecker output
try {
    $lapsCheck = lapschecker.exe 2>&1
    $lapsCheck | Out-File "$out\lapschecker-output.txt"
} catch {
    "lapschecker.exe not available or failed: $_" | Out-File "$out\lapschecker-output.txt"
}

# 3. LAPS policy from registry
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Policies\LAPS",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State"
)
foreach ($path in $regPaths) {
    if (Test-Path $path) {
        Write-Output "=== $path ===" | Out-File "$out\registry-laps.txt" -Append
        Get-ItemProperty $path | Out-File "$out\registry-laps.txt" -Append
    }
}

# 4. Local admin accounts
Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordLastSet, Description |
    Out-File "$out\local-users.txt"

# 5. Intune MDM diagnostics
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "LAPS" } |
    Select-Object TimeCreated, Id, Message | Export-Csv "$out\mdm-laps-events.csv" -NoTypeInformation

# 6. Device info
dsregcmd /status > "$out\dsregcmd-status.txt"
$env:COMPUTERNAME | Out-File "$out\device-info.txt"
[System.Environment]::OSVersion | Out-File "$out\device-info.txt" -Append
(Get-HotFix | Where-Object HotFixID -eq "KB5025221") | Out-File "$out\laps-kb-check.txt"

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
Write-Host "Evidence pack: $out.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# 1. Check LAPS agent status on device
lapschecker.exe

# 2. View LAPS event log
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 20

# 3. Check LAPS policy delivery (registry)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config"

# 4. Retrieve LAPS password from Entra (Graph)
Connect-MgGraph -Scopes "DeviceLocalCredential.Read.All","Device.Read.All"
$device = Get-MgDevice -Filter "displayName eq '<ComputerName>'"
Get-MgDeviceLocalCredential -DeviceId $device.Id

# 5. Force password rotation (Graph)
Invoke-MgRotateDeviceLocalAdminPassword -DeviceId $device.Id

# 6. Check local admin accounts on device
Get-LocalUser | Where-Object Enabled | Select-Object Name, LastLogon, PasswordLastSet

# 7. Check which account LAPS is managing (registry state)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State"

# 8. Check Windows version for LAPS compatibility
[System.Environment]::OSVersion.Version
Get-HotFix -Id "KB5025221"  # Win10 LAPS requirement

# 9. Intune sync to re-deliver policy
Start-Process "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"

# 10. AD-backed: read LAPS password (Windows LAPS module)
Get-LapsADPassword -Identity <ComputerName> -AsPlainText

# 11. AD-backed: force rotation
Reset-LapsPassword -Identity <ComputerName>

# 12. AD-backed: extend schema
Update-LapsADSchema -Verbose

# 13. AD-backed: set computer OU permissions
Set-LapsADComputerSelfPermission -Identity "OU=Workstations,DC=domain,DC=com"

# 14. Check LAPS RBAC role in Intune
Connect-MgGraph -Scopes "DeviceManagementRBAC.Read.All"
Get-MgDeviceManagementRoleDefinition | Where-Object DisplayName -match "Local"
```

---

## 🎓 Learning Pointers

- **Legacy LAPS and Windows LAPS use different AD attributes** — Legacy LAPS uses `ms-Mcs-AdmPwd` (plaintext); Windows LAPS uses `msLAPS-EncryptedPassword` (encrypted). If you migrate from Legacy to Windows LAPS on AD-backed mode, both attribute sets may exist briefly during transition. The LAPS UI tool version determines which it reads. [Migration guide](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-scenarios-migrate-from-legacy-laps)

- **The built-in Administrator SID (S-1-5-500) is a well-known target** — managing a custom named account is more secure than the built-in Administrator. Use `AccountManageMode = CreateOrManage` with a unique name like `laps-admin` across all your devices. This name becomes a standard your engineers know to use.

- **PostAuthenticationActions controls the security/usability tradeoff** — rotating after use (value 1 or 3) is the most secure default because a retrieved password can only be used once. But if engineers need sustained remote access for troubleshooting, set `PostAuthenticationResetDelay` to several hours. Setting it to 0 (no rotation) defeats a key LAPS security benefit.

- **Password retrieval is fully audited in Entra** — every time someone views a LAPS password via the Intune/Entra portal or Graph API, an audit event is logged in the Entra ID audit log under category `DeviceLocalCredential`. This is your accountability trail. Set up an alert or periodic review for high-frequency retrievals.

- **Windows LAPS has no standalone agent** — on Windows 11 22H2+ and patched Windows 10 devices, the LAPS engine is built into the OS. `lapschecker.exe` is the diagnostic tool that ships with it. On older OS versions without the KB, there is no LAPS functionality at all — the policy will deliver but nothing will happen.

- **The 60-day rotation default is a starting point, not a standard** — for environments with privileged access concerns or compliance requirements (PCI-DSS, CIS Level 2), 30 days or less is recommended. For most MSP environments, 30 days is pragmatic. Align the rotation period with your password policy documentation. [LAPS deployment guide](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-deployment-intune)
