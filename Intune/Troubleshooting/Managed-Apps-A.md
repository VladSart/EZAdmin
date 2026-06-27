# Intune Managed Apps / MAM — Reference Runbook (Mode A: Deep Dive)
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

Covers **Intune Mobile Application Management (MAM)** across two deployment modes:

| Mode | Description | Enrollment required? |
|------|-------------|----------------------|
| **MAM-WE** (Without Enrollment) | App protection policies applied to personal/BYOD devices without MDM enrolment | No |
| **MAM-WI** (With Enrollment / MDM+MAM) | App protection + device compliance enforced on enrolled devices | Yes |
| **Managed Apps (MDM)** | Apps deployed via Intune with app config, required/available/uninstall intent | Yes |

**Platforms in scope:** iOS/iPadOS, Android (Android Enterprise + DA), Windows (Win32 + Microsoft Store), macOS (PKG, DMG, .intunemac).

**Assumptions:**
- Reader has Intune Administrator or Global Reader access in Intune portal.
- Graph API queries require `DeviceManagementApps.Read.All` scope.
- Test devices available for reproduction.

---

## How It Works

<details><summary>Full architecture</summary>

### MAM Architecture (App Protection Policies)

```
[User signs in to Microsoft 365 app (Outlook, Teams, etc.)]
         |
         v
[App calls MSAL → Acquires token from Entra ID]
         |
         v
[Entra ID evaluates Conditional Access]
   - "Require approved client app" OR
   - "Require app protection policy"
         |
         v
[If CA requires APP → App SDK calls Intune MAM service]
         |
         v
[Intune MAM service checks: Is user targeted by APP policy?]
   YES → Returns policy payload to app
   NO  → Access blocked or limited (depends on CA grant control)
         |
         v
[App SDK enforces policy locally]
   - Copy/paste restrictions
   - Save-as blocking
   - Screenshot prevention
   - PIN / biometric re-authentication
   - Encryption of managed data at rest
   - Selective wipe on demand
```

### MDM Managed App Architecture (App Deployment)

```
[Admin creates app in Intune: Win32 / LOB / Store / VPP]
         |
         v
[Assignment: Required / Available / Uninstall]
   - Required: installed automatically
   - Available: visible in Company Portal
   - Uninstall: removed if present
         |
         v
[Intune Management Extension (IME) on Windows]
   OR
[MDM channel on iOS/Android via Device channel]
         |
         v
[Device downloads content from Intune CDN (Azure Blob)]
         |
         v
[Detection rule evaluated post-install]
   - Registry key / file / MSI product code / custom script
   - Pass → Reported as "Installed"
   - Fail → Reported as "Not Installed" → retry loop
         |
         v
[App compliance fed back to Intune → reported in portal]
```

### App Config Policy (ACP) Flow

```
[Admin creates App Configuration Policy]
   Target: Enrolled devices (MDM channel) OR
           Managed apps (MAM channel via app SDK)
         |
         v
[Policy delivered on next sync]
         |
         v
[App reads config via managed key-value pairs or XML]
   iOS → Managed AppConfig protocol
   Android → Android Enterprise Managed Config
   Windows → WinGet / registry / ADMX ingestion
```

### Windows IME (Intune Management Extension) — Key Role

The IME (`IntuneManagementExtension.exe`) is responsible for Win32 app installs on Windows 10/11. It runs as SYSTEM and pulls work from the Intune cloud via HTTPS polling.

```
IME process flow:
  1. Poll Intune service for pending work items
  2. Download .intunewin (encrypted AES-256 archive) from CDN
  3. Decrypt and extract to %ProgramData%\Microsoft\IntuneManagementExtension\
  4. Run install command as SYSTEM (or logged-in user, depending on context)
  5. Run detection rule
  6. Report success/failure back to Intune service
```

Key IME log location: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log`

</details>

---

## Dependency Stack

```
Intune / MAM Service (cloud)
    │
    ├── Entra ID (token issuance, user/group targeting)
    │       └── Conditional Access (app protection enforcement gate)
    │
    ├── Microsoft 365 Apps / Intune-managed apps
    │       └── Intune App SDK (embedded in iOS/Android apps)
    │               └── MSAL (token acquisition)
    │
    ├── Windows IME (Win32 app deployment on Windows)
    │       ├── Network access to Intune CDN (*.manage.microsoft.com, *.do.dsp.mp.microsoft.com)
    │       └── Local SYSTEM context (install)
    │
    ├── Company Portal (user-facing enrollment / available apps)
    │       └── Intune enrollment (MDM channel, required for MDM app deployment)
    │
    ├── Apple VPP / Google Play for Work (store app sourcing)
    │       └── Volume purchase tokens (Apple) / Managed Google Play binding
    │
    └── App detection rules (Win32, LOB) → reported compliance
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| App shows "Not Installed" despite deployment | Detection rule mismatch | Check detection rule in Intune vs. what actually installs |
| MAM policy not applied — user can copy between apps | User not targeted or app not policy-managed | Check Assignments + confirm app SDK version |
| CA blocks app with "Need approved app" error | App not in approved client list or APP policy not assigned | Verify CA grant control matches policy type |
| Win32 app stuck in "Pending" | IME not running, or device offline for >7 days | Check IME service status and logs |
| iOS VPP app fails to install | VPP token expired or license exhausted | Check VPP token in Tenant admin → Connectors |
| Android work profile app not appearing | Managed Google Play sync not completed | Force sync or re-approve app in Managed Play |
| App config not being honoured | Config policy targeted to wrong channel (MAM vs MDM) | Verify target type matches enrolment state |
| Selective wipe not working | User not MAM-registered | Check MAM registration with Graph or portal |
| Win32 install fails with exit code 1603 | MSI prerequisite missing, install context wrong | Check IME log for exact error + install context |
| Company Portal shows app as "Failed" | Detection rule ran before install completed | Check retry count; review IME log timing |

---

## Validation Steps

**1. Check MAM registration status for a user**

```powershell
# Requires Microsoft.Graph module
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All"

$upn = "<UserUPN>"
$user = Get-MgUser -Filter "userPrincipalName eq '$upn'"

# Get MAM-registered devices for this user
$mamDevices = Get-MgDeviceManagementManagedAppRegistration -Filter "userId eq '$($user.Id)'"
$mamDevices | Select-Object platformType, deviceName, lastSyncDateTime, appIdentifier
```

Expected: At least one registration per managed app per device. If empty, user has never launched a managed app while authenticated.

**2. Check app protection policy assignment**

```powershell
# List all app protection policies (iOS example)
Get-MgDeviceAppManagementIosManagedAppProtection | Select-Object displayName, id

# Check assignments for a specific policy
$policyId = "<policyId>"
Get-MgDeviceAppManagementIosManagedAppProtectionAssignment -IosManagedAppProtectionId $policyId |
    Select-Object target
```

Expected: Group containing the test user should appear in assignments.

**3. Check IME status on Windows device (run on endpoint)**

```powershell
# IME service state
Get-Service -Name IntuneManagementExtension | Select-Object Name, Status, StartType

# IME version
(Get-Item "C:\Program Files (x86)\Microsoft Intune Management Extension\AgentExecutor.exe").VersionInfo.FileVersion

# Last 50 lines of IME log
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 50
```

Expected: Service **Running**, version ≥ 1.43.x (check current at aka.ms/intunemanagementextension).

**4. Check Win32 app detection rule result**

```powershell
# Find detection result in IME log
Select-String -Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" `
    -Pattern "DetectionRule|detection result|Applicability"
```

Expected: `detection result: Applicable` for installed apps.

**5. Check Android Enterprise / iOS managed app status via Graph**

```powershell
$deviceId = "<managedDeviceId>"
$appStates = Get-MgDeviceManagementManagedDeviceManagedDeviceMobileAppConfigurationState -ManagedDeviceId $deviceId
$appStates | Select-Object displayName, state, errorCode | Sort-Object state
```

Expected: All required apps show `installed`.

**6. Check VPP token health**

In Intune portal: **Tenant admin → Connectors and tokens → Apple VPP tokens**. Look for:
- Status: Active
- Expiry: >30 days
- Available licenses: >0

---

## Troubleshooting Steps (by phase)

### Phase 1 — Policy Targeting Verification

1. Navigate to **Intune → Apps → App protection policies**.
2. Open the relevant policy → **Properties → Assignments**.
3. Confirm the user's group is in **Included groups**, not **Excluded groups**.
4. Check **Targeted apps** — confirm the app (e.g., `com.microsoft.outlook`) is listed.
5. Navigate to **Intune → Apps → Monitor → App protection status**.
6. Filter by user — check `Protection status`, `iOS/Android checked in`.

### Phase 2 — App Configuration Issues

1. Navigate to **Intune → Apps → App configuration policies**.
2. Confirm `Managed devices` vs `Managed apps` targeting is correct:
   - **Managed devices**: requires MDM enrollment
   - **Managed apps**: applies via MAM channel regardless of enrollment
3. Check the key-value pairs — common mistakes: wrong bundle ID, wrong key name.
4. For iOS, confirm the app supports managed app configuration via AppConfig.org standard.
5. Force a device sync and retest.

### Phase 3 — Win32 App Deployment (Windows)

1. On the endpoint, open IME log: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log`
2. Search for the app name or its Intune policy ID (visible in portal URL).
3. Look for:
   - `DownloadComplete` — download succeeded
   - `ExitCode` — install return code (0 = success, 3010 = success/reboot needed, 1603 = fatal error)
   - `DetectionRule` result — passes or fails
4. If download fails: check network connectivity to `*.manage.microsoft.com` and CDN endpoints.
5. If install fails with 1603: run the install command manually as SYSTEM using PsExec to reproduce.

### Phase 4 — iOS/Android Store App Issues

1. For **Apple VPP**: Check token in **Tenant admin → Connectors → Apple VPP tokens**.
   - Renew expired tokens at business.apple.com.
   - Reassign licenses if exhausted.
2. For **Android — Managed Google Play**: Check app approval in **Intune → Connectors → Managed Google Play**.
   - App must be approved before it can be assigned.
   - Sync may take up to 24h for new approvals.
3. For **Android Enterprise work profile**: Confirm device is enrolled in **Work Profile** mode, not **Device Admin**.

### Phase 5 — MAM Selective Wipe Not Working

1. Navigate to **Intune → Apps → Monitor → App protection status → User status**.
2. Select user → select device → check `Registration status`.
3. If not registered: user has not launched the managed app from an Intune context. Have them sign out and back in to the app.
4. Issue wipe: **Intune → Devices → [device] → Selective wipe** (only wipes managed app data, not personal data).
5. Verify wipe completion: **Intune → Apps → Monitor → App protection status** — status should show `Wipe Pending` then `Wiped`.

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Win32 App Stuck in "Pending" / Never Installs</summary>

**Root cause:** IME not polling, or device has been offline too long.

```powershell
# Run on affected device as admin

# 1. Check and restart IME service
$svc = Get-Service -Name IntuneManagementExtension
if ($svc.Status -ne 'Running') {
    Start-Service -Name IntuneManagementExtension
    Write-Host "IME service started"
} else {
    Write-Host "IME already running — restarting to force poll"
    Restart-Service -Name IntuneManagementExtension -Force
}

# 2. Trigger a device sync (initiates IME poll)
$intuneSession = New-CimSession
Invoke-CimMethod -Namespace "root\ccm" -ClassName "SMS_Client" `
    -MethodName "TriggerSchedule" -Arguments @{sScheduleID="{00000000-0000-0000-0000-000000000021}"} `
    -CimSession $intuneSession -ErrorAction SilentlyContinue

# If above fails (no ConfigMgr), use alternative sync trigger
Start-Process -FilePath "C:\Program Files (x86)\Microsoft Intune Management Extension\agentexecutor.exe" `
    -ArgumentList "-retryQueue" -NoNewWindow -Wait

# 3. Monitor log for activity
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" `
    -Wait -Tail 30
```

**Rollback:** Not applicable — this is a monitoring/sync operation only.

</details>

<details>
<summary>Fix 2 — Win32 App Detection Rule Mismatch</summary>

**Root cause:** Detection rule doesn't match what the installer actually creates.

```powershell
# Run on a device where the app IS installed, to find correct detection values

# For MSI-based apps — find product code
Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall" |
    Get-ItemProperty |
    Where-Object { $_.DisplayName -like "*<AppName>*" } |
    Select-Object DisplayName, PSChildName, UninstallString
# PSChildName = MSI Product Code (e.g. {GUID})

# For file-based detection
$filePath = "C:\Program Files\<AppFolder>\<app.exe>"
if (Test-Path $filePath) {
    $ver = (Get-Item $filePath).VersionInfo.FileVersion
    Write-Host "File version: $ver"
}

# For registry-based detection
$regPath = "HKLM:\SOFTWARE\<Vendor>\<App>"
if (Test-Path $regPath) {
    Get-ItemProperty $regPath
}
```

Update the detection rule in Intune:
1. **Intune → Apps → [App] → Properties → Detection rules**
2. Change to the verified value from above
3. Save and force sync on test device

**Rollback:** Revert detection rule to previous value if new rule causes false positives.

</details>

<details>
<summary>Fix 3 — MAM Policy Not Enforced (User Can Copy Between Apps)</summary>

**Root cause:** User not targeted, or app not in policy's targeted app list, or app SDK version too old.

```powershell
# Graph: Check if user has MAM registrations
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All", "User.Read.All"

$upn = "<UserUPN>"
$user = Get-MgUser -Filter "userPrincipalName eq '$upn'"

$regs = Get-MgDeviceManagementManagedAppRegistration -Filter "userId eq '$($user.Id)'"
if ($regs.Count -eq 0) {
    Write-Warning "No MAM registrations found — user has not launched a managed app"
} else {
    $regs | Select-Object platformType, deviceName, lastSyncDateTime,
        @{N="AppId";E={$_.appIdentifier.bundleId ?? $_.appIdentifier.packageId}}
}

# Check policy applied status
$status = Get-MgDeviceAppManagementManagedAppStatus -Filter "displayName eq 'App protection status'"
# Or check in portal: Apps → Monitor → App protection status
```

**Resolution steps:**
1. Confirm user is in **Included groups** in the policy assignment.
2. Confirm app bundle ID is in **Targeted apps** list (e.g., `com.microsoft.outlook`).
3. Confirm app version supports Intune SDK — check compatibility matrix at [aka.ms/IntuneAppSDK](https://aka.ms/IntuneAppSDK).
4. Have user **sign out of the app** and **sign back in** — this triggers MAM registration.
5. Wait up to 30 minutes for policy to sync after sign-in.

**Rollback:** Not applicable — policy changes are additive.

</details>

<details>
<summary>Fix 4 — iOS VPP App License Exhausted</summary>

**Root cause:** All purchased licenses assigned; new users cannot install.

```powershell
# Graph: Check VPP token and license counts
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All"

# List VPP tokens
Get-MgDeviceAppManagementVppToken | Select-Object organizationName, expirationDateTime,
    lastSyncDateTime, state, countOfAppsWithAvailableLicenses

# List app licenses (run in portal for best detail):
# Intune → Apps → iOS/iPadOS → [VPP App] → Device install status / User install status
```

**Resolution:**
1. Purchase additional licenses at [business.apple.com](https://business.apple.com).
2. Sync the VPP token in **Tenant admin → Connectors → Apple VPP tokens → Sync**.
3. New licenses appear within 15 minutes.

**Alternative — revoke unused licenses:**
1. **Intune → Apps → [VPP App] → Device install status**.
2. Find devices where app was installed but device is retired/stale.
3. Retire those devices — licenses reclaim automatically on next VPP sync.

</details>

<details>
<summary>Fix 5 — App Config Policy Not Applied (iOS Managed App Config)</summary>

**Root cause:** Config policy targeting `Managed apps` but device is MDM-enrolled (should target `Managed devices`), or vice versa.

```
Targeting rules:
┌────────────────────────────────────┬──────────────────────────────┐
│ Scenario                           │ Correct ACP target           │
├────────────────────────────────────┼──────────────────────────────┤
│ Device enrolled in Intune (MDM)    │ Managed devices              │
│ BYOD, no MDM enrolment (MAM-WE)    │ Managed apps                 │
│ Both enrolled + MAM policy         │ Both (create two policies)   │
└────────────────────────────────────┴──────────────────────────────┘
```

```powershell
# Graph: List app config policies and their target type
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All"

Get-MgDeviceAppManagementManagedDeviceMobileAppConfiguration |
    Select-Object displayName, targetedMobileApps, @{N="TargetType";E={"MDM"}}

Get-MgDeviceAppManagementTargetedManagedAppConfiguration |
    Select-Object displayName, @{N="TargetType";E={"MAM"}}
```

**Resolution:** Create the policy with the correct target type. Policies cannot be changed from MDM to MAM in-place — create a new one.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Intune Managed App / MAM evidence for a device and user
.NOTES     Run locally on Windows endpoint (for IME data) and from admin workstation (for Graph data)
#>

param(
    [string]$UserUPN = "<UserUPN>",
    [string]$OutputPath = "$env:TEMP\MAM-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null

# --- LOCAL (Windows endpoint) ---

Write-Host "Collecting IME service state..." -ForegroundColor Cyan
Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType |
    Export-Csv "$OutputPath\ime-service.csv" -NoTypeInformation

Write-Host "Copying IME log..." -ForegroundColor Cyan
$imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $imeLog) {
    Copy-Item $imeLog "$OutputPath\IntuneManagementExtension.log"
}

Write-Host "Collecting installed apps snapshot..." -ForegroundColor Cyan
Get-Package | Select-Object Name, Version, ProviderName |
    Export-Csv "$OutputPath\installed-packages.csv" -NoTypeInformation

# --- GRAPH (run from admin workstation) ---

Write-Host "Connecting to Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All","User.Read.All" -NoWelcome

$user = Get-MgUser -Filter "userPrincipalName eq '$UserUPN'" -ErrorAction Stop

Write-Host "Collecting MAM registrations..." -ForegroundColor Cyan
Get-MgDeviceManagementManagedAppRegistration -Filter "userId eq '$($user.Id)'" |
    Select-Object platformType, deviceName, lastSyncDateTime, createdDateTime |
    Export-Csv "$OutputPath\mam-registrations.csv" -NoTypeInformation

Write-Host "Done. Evidence saved to: $OutputPath" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|--------------------|
| List all MAM registrations for user | `Get-MgDeviceManagementManagedAppRegistration -Filter "userId eq '<id>'"` |
| Check iOS MAM protection policies | `Get-MgDeviceAppManagementIosManagedAppProtection` |
| Check Android MAM protection policies | `Get-MgDeviceAppManagementAndroidManagedAppProtection` |
| Check Windows MAM protection policies | `Get-MgDeviceAppManagementWindowsManagedAppProtection` |
| Check VPP tokens | `Get-MgDeviceAppManagementVppToken` |
| Restart IME service | `Restart-Service IntuneManagementExtension -Force` |
| View IME log live | `Get-Content "...\IntuneManagementExtension.log" -Wait -Tail 30` |
| Trigger IME sync | `Restart-Service IntuneManagementExtension -Force` |
| Check app install status (portal) | Apps → Monitor → App install status |
| Check MAM status (portal) | Apps → Monitor → App protection status |
| Find MSI Product Code | `Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` |
| Check app config policies (MDM) | `Get-MgDeviceAppManagementManagedDeviceMobileAppConfiguration` |
| Check app config policies (MAM) | `Get-MgDeviceAppManagementTargetedManagedAppConfiguration` |
| Issue selective wipe | Intune → Devices → [device] → Selective wipe |

---

## 🎓 Learning Pointers

- **MAM-WE vs MDM+MAM:** MAM-WE (Without Enrollment) is the BYOD scenario — the device is never enrolled in MDM, but app-level policies still apply. This requires Conditional Access with "Require app protection policy" grant, not just "Require enrolled device." See [Microsoft docs on MAM-WE](https://learn.microsoft.com/en-us/mem/intune/apps/app-protection-policy).

- **The Intune App SDK is what enforces MAM policies:** The SDK is embedded by app developers (Microsoft 365 apps all include it). Third-party apps must integrate the SDK explicitly, or wrap via the Intune App Wrapping Tool. If the app doesn't have the SDK, no MAM policy can be enforced. See [Intune App SDK overview](https://learn.microsoft.com/en-us/mem/intune/developer/app-sdk).

- **Win32 app detection rules are frequently misconfigured:** The single most common cause of "Not Installed" reports is a detection rule that doesn't match the install artefact. Always validate the detection rule on a machine where the app IS installed before mass deployment.

- **IME log is your best friend for Win32 debugging:** Every download, install, detection, and failure is logged with timestamps and exit codes. The file at `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` is the definitive source of truth for Win32 app deployment on Windows. See [Intune Win32 app management](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-app-management).

- **App config policy targeting matters:** A policy targeted to "Managed apps" is delivered via the MAM channel (works even on unenrolled BYOD). A policy targeted to "Managed devices" is delivered via the MDM channel. If you deploy both, the MDM channel policy takes precedence on enrolled devices. This is a common misconfiguration in hybrid environments.

- **VPP token expiry causes silent failures:** Apple VPP tokens expire annually. When expired, apps stop being assigned and existing assignments stop renewing. Set a calendar reminder 60 days before token expiry. [Apple VPP token management](https://learn.microsoft.com/en-us/mem/intune/apps/vpp-apps-ios).
