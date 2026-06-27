# Intune App Protection Policies (MAM) — Reference Runbook (Mode A: Deep Dive)
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

Covers Intune **App Protection Policies (APP)** — also referred to as **Mobile Application Management (MAM)**. Applies to:

- **MAM-WE (MAM Without Enrollment)** — apps managed without device enrollment; primary BYOD scenario
- **MAM with MDM** — enrolled devices where APP adds data layer protection on top of device management
- **iOS/iPadOS and Android** — the two platforms supported for APP (Windows app protection is separate, managed via WIP/MIP)
- Managed apps: Microsoft 365 apps (Outlook, Teams, Edge, Word, Excel, PowerPoint, OneDrive, SharePoint), plus third-party apps with the Intune SDK or App Wrapping Tool

Assumes engineer has **Intune Administrator** or **Global Administrator** role. Device enrollment is NOT required for MAM-WE, but users must sign into managed apps with their organizational account (UPN).

---

## How It Works

<details><summary>Full architecture</summary>

### MAM Architecture Overview

```
Corporate Data Flow with APP:

  User signs in to Managed App (e.g., Outlook)
          │
          ▼
  Microsoft Authentication Library (MSAL)
          │  authenticates user
          ▼
  Entra ID → issues token + checks Conditional Access
          │
          ▼
  Intune App SDK (embedded in managed app)
          │  checks in with Intune MAM service
          ▼
  Intune MAM Service
          ├─► Downloads APP policy for this user + app
          ├─► Evaluates compliance (PIN required? biometric? jailbreak check?)
          └─► Enforces data protection (copy/paste restrictions, save-as controls, etc.)
          │
          ▼
  Corporate data accessed within the "MAM boundary"
          │
          └─► Personal apps / personal copy-paste: BLOCKED by policy
              Save to personal cloud storage: BLOCKED by policy
              Screen capture: BLOCKED (Android) / watermarked (iOS via MDM)
```

### The MAM Boundary (Managed vs. Unmanaged Context)

The core concept of APP is the **managed context**:

```
┌─────────────────────────────────────────────────┐
│              MANAGED CONTEXT                     │
│  (corporate identity within managed apps)        │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ Outlook  │  │  Teams   │  │   Edge   │       │
│  │ (corp)   │  │  (corp)  │  │  (corp)  │       │
│  └──────────┘  └──────────┘  └──────────┘       │
│       │                │            │            │
│       └────────────────┴────────────┘            │
│              ↕ Data can flow freely              │
└─────────────────────────────────────────────────┘
         │                     │
         │ CUT/PASTE BLOCKED   │ SAVE-AS BLOCKED
         ▼                     ▼
┌─────────────────────────────────────────────────┐
│           UNMANAGED CONTEXT                      │
│  (personal apps, personal identity)              │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ Gmail    │  │ WhatsApp │  │ Notes    │       │
│  │ (personal│  │          │  │ (personal│       │
│  └──────────┘  └──────────┘  └──────────┘       │
└─────────────────────────────────────────────────┘
```

### App Registration with Intune SDK

For an app to be MAM-capable, it must either:
1. **Contain the Intune App Protection SDK** (for first-party Microsoft apps and ISV partners)
2. Be **wrapped** with the Intune App Wrapping Tool (for in-house or LOB apps)
3. Be a **web clip / browser bookmark** (using Microsoft Edge as the managed browser)

The SDK registers the app with the MAM service at first sign-in. The app checks in periodically (default: every 30 minutes while active, plus on launch).

### iOS vs. Android Differences

| Feature | iOS/iPadOS | Android |
|---------|-----------|---------|
| App SDK check-in | Per-app, via MSAL | Per-app, via MSAL or Company Portal (broker) |
| Broker required | No (optional Authenticator) | Yes (Company Portal or Authenticator required as broker) |
| Personal profile separation | App-level (no OS isolation) | Android Enterprise Work Profile (hardware-enforced) |
| Screen capture block | Requires MDM enrollment | APP policy can block (FLAG_SECURE) |
| App config delivery | APP or MDM config | APP or MDM config |
| Selective wipe | Wipes corporate data from app | Wipes corporate data from app |

### MAM-WE Policy Delivery (No Enrollment)

1. User opens managed app and signs in with corporate UPN
2. App SDK contacts Intune MAM endpoint: `https://manage.microsoft.com`
3. Intune looks up the user, finds targeted APP policy
4. Policy is downloaded and cached in the app
5. App enforces policy (PIN, copy/paste, etc.)
6. Check-in occurs: every 30 min while app is active, on every cold start

### Selective Wipe

When Selective Wipe is triggered (via Intune portal or Graph):
- The next time the managed app checks in (within 30 min or on next launch), it receives the wipe command
- App deletes all corporate data stored within its MAM boundary (emails, files, cached tokens)
- App data stored in personal storage (e.g., photos saved to camera roll) is NOT wiped
- The wipe does NOT affect the device or personal apps

</details>

---

## Dependency Stack

```
Managed App (Intune SDK embedded)
        │
        ├─► MSAL Authentication Library
        │        └─► Entra ID (token issuance + Conditional Access evaluation)
        │
        ├─► Intune MAM Service (manage.microsoft.com)
        │        ├─► Policy lookup (by UPN → targeted group → APP policy)
        │        └─► Wipe command delivery
        │
        ├─► iOS/Android Broker (optional on iOS, REQUIRED on Android)
        │        ├─► Microsoft Authenticator (iOS or Android)
        │        └─► Intune Company Portal (Android — preferred broker)
        │
        └─► App Store / Google Play (app must be installed from public store or VPP/MDM)

Supporting services:
  ├─► Entra ID Group (APP targeted to group containing the user)
  ├─► Conditional Access (can require approved client app or app protection policy)
  └─► Intune Audit Log (tracks policy assignment, check-ins, wipe requests)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| User not prompted for PIN in managed app | APP not targeted to user, or app not MAM-capable | Check group assignment + check App Protection Status in Intune portal |
| "Your organization's data cannot be pasted here" | App protection policy working as designed; may be user confusion | Confirm this is expected behaviour; check if destination app should be added to allowed list |
| Outlook shows "Your company hasn't allowed this action" | APP blocking specific action (save-as, print, screen share) | Review APP policy settings for this user |
| Android: APP not applying despite policy targeting | Company Portal not installed (broker missing) | Require Company Portal install; it's required for MAM broker on Android |
| iOS: Corporate account shows as "Not protected" | App check-in failed; token expired; policy not targeted | Check Intune > Apps > Monitor > App protection status |
| Selective wipe did not complete | App hasn't checked in since wipe was issued | App must launch and reach manage.microsoft.com; check network |
| Conditional Access blocking despite managed app | CA "Require app protection policy" condition not matching platform | Check CA policy grant conditions and app protection status report |
| User can't open Office attachment in unmanaged app | Policy "Send org data to other apps" = "Policy managed apps only" | Expected; user must open in managed app |
| New managed app not receiving policy | App version doesn't include Intune SDK; or app targeted wrong | Check app in Intune > Client Apps > App protection policies > Apps list |
| Policy check-in taking too long | Network blocking manage.microsoft.com or proxy intercepting TLS | Verify network access to MAM endpoint |

---

## Validation Steps

### 1. Check App Protection Status for a user
```powershell
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome
$upn = "<UserPrincipalName>"

# Get managed app registrations (check-in records)
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/managedAppRegistrations?`$filter=userId eq '$(Get-MgUser -UserId $upn | Select-Object -Expand Id)'" |
    Select-Object -Expand value |
    Select-Object id, displayName, platformType, managementSdkVersion, lastSyncDateTime, appliedPolicies
```

Alternatively, in Intune portal: **Apps > Monitor > App protection status** → search by user.

### 2. List all App Protection Policies
```powershell
# iOS policies
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections" |
    Select-Object -Expand value | Select-Object id, displayName, periodBeforePinReset, dataBackupBlocked

# Android policies
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/androidManagedAppProtections" |
    Select-Object -Expand value | Select-Object id, displayName, periodBeforePinReset, dataBackupBlocked
```

### 3. Verify which apps are included in a policy
```powershell
$policyId = "<PolicyId>"  # Get from step 2

# iOS
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections/$policyId/apps" |
    Select-Object -Expand value | Select-Object id, mobileAppIdentifier, version
```

### 4. Check policy group assignments
```powershell
# iOS
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections/$policyId/assignments" |
    Select-Object -Expand value | Select-Object id, intent, target
```

### 5. Verify user is in the targeted group
```powershell
$groupId = "<GroupId>"  # From assignment target
$userId  = (Get-MgUser -UserId "<UPN>").Id
$member  = Get-MgGroupMember -GroupId $groupId | Where-Object { $_.Id -eq $userId }
if ($member) { "User IS in the group" } else { "User NOT in the group — policy will NOT apply" }
```

### 6. Check managed app registrations (check-in health)
```powershell
$userId = (Get-MgUser -UserId "<UPN>").Id
$regs = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/managedAppRegistrations?`$filter=userId eq '$userId'" |
    Select-Object -Expand value

$regs | Select-Object @{N="App";E={$_.displayName}}, @{N="Platform";E={$_.platformType}},
    @{N="SDKVersion";E={$_.managementSdkVersion}}, @{N="LastSync";E={$_.lastSyncDateTime}},
    @{N="PolicyCount";E={($_.appliedPolicies).Count}} | Format-Table -AutoSize
```

**Good:** Recent `LastSync` (within last 24–48 hours if user is active), `PolicyCount > 0`.  
**Bad:** `LastSync` is days ago, or `PolicyCount = 0` — app hasn't received policy.

### 7. Verify MAM endpoint reachability (from device perspective)
The device must be able to reach `manage.microsoft.com` on port 443. On a managed device:
```powershell
# Windows proxy check (for Windows MAM):
Test-NetConnection -ComputerName manage.microsoft.com -Port 443

# For iOS/Android - check via corporate proxy/firewall logs
# URL: https://manage.microsoft.com
# Required for: Policy delivery, wipe commands, check-in
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Policy not applying at all (user sees no restrictions)

Checklist (verify in order):
1. Is the app MAM-capable? Check [Intune protected apps list](https://learn.microsoft.com/en-us/mem/intune/apps/apps-supported-intune-apps) or confirm SDK is embedded
2. Is the policy targeted to a group containing the user?
3. Is the user signed into the app with their **organizational account** (not personal)?
4. Has the app checked in recently? (see Validation Step 6)
5. On Android: is Company Portal installed and signed in?

```powershell
# Quick policy targeting check
$upn = "<UPN>"
$userId = (Get-MgUser -UserId $upn).Id

# Get all groups user is member of
$userGroups = Get-MgUserMemberOf -UserId $userId | Select-Object -Expand id

# Get APP assignments
$iosPolicies = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections" |
    Select-Object -Expand value

foreach ($policy in $iosPolicies) {
    $assignments = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections/$($policy.id)/assignments" |
        Select-Object -Expand value
    
    $targeted = $assignments | Where-Object { $_.target.'@odata.type' -match 'GroupAssignmentTarget' -and $userGroups -contains $_.target.groupId }
    if ($targeted) {
        Write-Host "User IS targeted by iOS policy: $($policy.displayName)" -ForegroundColor Green
    }
}
```

### Phase 2 — Policy applying but wrong settings

Retrieve the full policy configuration:
```powershell
$policyId = "<PolicyId>"
$policy = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections/$policyId" 
$policy | ConvertTo-Json -Depth 5
```

Key settings to verify:

| Setting | Property Name | Common Values |
|---------|--------------|---------------|
| Copy/paste to unmanaged apps | `allowedOutboundClipboardSharingLevel` | `blocked`, `managedAppsWithPasteIn`, `managedApps`, `allApps` |
| Save-as to personal storage | `allowedOutboundDataTransferDestinations` | `none`, `managedApps`, `allApps` |
| Open from personal storage | `allowedInboundDataTransferSources` | `none`, `managedApps`, `allApps` |
| PIN required | `pinRequired` | `true` / `false` |
| Block screen capture (Android) | `screenCaptureBlocked` | `true` / `false` |
| Jailbreak/root detection | `jailbroken` | `true` (block) |
| Backup to iCloud/Google | `dataBackupBlocked` | `true` / `false` |

### Phase 3 — Android: APP not working, Company Portal issues

On Android, the **Intune Company Portal acts as the MAM broker**. Without it, MAM check-in may fail or be inconsistent.

Required state on Android:
- Company Portal app **installed** (even if device is not enrolled)
- Company Portal app **up to date** (old versions may not support latest MAM features)
- User **signed into Company Portal** with corporate account

```powershell
# Check managed app registration (will show if CP is acting as broker)
# In portal: Apps > Monitor > App protection status > [User] > Android apps
# Look for "Android: Registered" status

# Force re-registration: user must sign out of managed app and sign back in
# This triggers a fresh MAM registration request
```

### Phase 4 — Selective wipe not completing

```powershell
# Check wipe request status via Graph
$userId = (Get-MgUser -UserId "<UPN>").Id
$wipeStatus = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/managedAppRegistrations?`$filter=userId eq '$userId'&`$expand=operations" |
    Select-Object -Expand value

$wipeStatus | ForEach-Object {
    [PSCustomObject]@{
        App           = $_.displayName
        Platform      = $_.platformType
        LastSync      = $_.lastSyncDateTime
        PendingOps    = ($_.operations | Where-Object { $_.state -eq 'notStarted' }).Count
    }
}
```

Wipe completes when:
1. App launches and checks in (reaches `manage.microsoft.com`)
2. Wipe command is received
3. App deletes corporate data and reports completion

If wipe is stuck: user hasn't opened the app since wipe was issued. Options:
- Push a notification to the user asking them to open the app once
- If device is MDM-enrolled, trigger a device compliance check to prompt check-in
- Wait — selective wipe is not immediate; it can take hours if the device is offline

### Phase 5 — Conditional Access "Require app protection policy" not working

```powershell
# Check sign-in logs for CA evaluation
Connect-MgGraph -Scopes "AuditLog.Read.All" -NoWelcome
$upn = "<UPN>"
$signins = Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn'" -Top 20 |
    Select-Object CreatedDateTime, AppDisplayName, Status, 
        @{N="CAResult";E={$_.AppliedConditionalAccessPolicies | ConvertTo-Json -Depth 2}} |
    Format-List
```

Common CA + APP mismatch issues:
- CA policy targets **"All Cloud Apps"** but APP only covers specific apps — CA may be enforcing on apps where APP isn't supported
- Platform mismatch: CA policy targets iOS but APP policy isn't deployed for iOS
- App not in the approved apps list within CA grant (different from APP targeting)
- User authenticated from a non-mobile device where APP doesn't apply

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Force app re-registration with Intune MAM</summary>

**Scenario:** Policy isn't applying despite correct targeting. Force a fresh check-in.

Steps for user to perform:
1. **Sign out** of the managed app (e.g., in Outlook: Settings → [Account] → Sign Out)
2. On Android: **Sign out of Company Portal** (Settings → Account → Sign Out)
3. **Clear app cache** (Android: Settings → Apps → [App] → Storage → Clear Cache)
4. **Re-launch the app** and sign back in with corporate account
5. App will re-register with MAM service and download fresh policy

**Verification:**
```powershell
# Check registration timestamp — should update within minutes of re-sign-in
$userId = (Get-MgUser -UserId "<UPN>").Id
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/managedAppRegistrations?`$filter=userId eq '$userId'" |
    Select-Object -Expand value | Select-Object displayName, lastSyncDateTime | Format-Table
```

</details>

<details>
<summary>Fix 2 — Trigger selective wipe via Graph</summary>

**Scenario:** Employee terminated or device lost/stolen. Need to remove corporate data from managed apps.

```powershell
Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All" -NoWelcome

$userId = (Get-MgUser -UserId "<UPN>").Id

# Get all managed app registrations for the user
$regs = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/managedAppRegistrations?`$filter=userId eq '$userId'" |
    Select-Object -Expand value

Write-Host "Found $($regs.Count) managed app registration(s) for $userId"
$regs | Select-Object id, displayName, platformType, lastSyncDateTime | Format-Table

# Issue selective wipe for each registration
foreach ($reg in $regs) {
    Write-Host "Issuing wipe for: $($reg.displayName) ($($reg.platformType))..."
    Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/managedAppRegistrations/$($reg.id)/operations" `
        -Body (@{ "@odata.type" = "#microsoft.graph.managedAppOperation"; displayName = "wipe" } | ConvertTo-Json) `
        -ContentType "application/json"
}

Write-Host "`nWipe commands issued. Corporate data will be removed on next app check-in." -ForegroundColor Yellow
```

**Important:** Selective wipe only removes data in the managed app's MAM boundary. Files saved to personal storage (camera roll, personal OneDrive) are NOT wiped.

**Rollback:** No rollback. Once wiped, the user must re-authenticate and corporate data re-syncs from cloud. Selective wipe does NOT harm personal data.

</details>

<details>
<summary>Fix 3 — Audit and update APP policy settings</summary>

**Scenario:** Policy is too restrictive (user can't work effectively) or not restrictive enough (compliance requirement not met). Review and adjust.

```powershell
Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All" -NoWelcome

$policyId = "<iOSPolicyId>"

# Get current settings
$current = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections/$policyId"

# Example: Relax copy/paste to allow managed-app-to-managed-app (common business need)
$update = @{
    allowedOutboundClipboardSharingLevel = "managedAppsWithPasteIn"
    # Options: blocked | managedAppsWithPasteIn | managedApps | allApps
}

Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections/$policyId" `
    -Body ($update | ConvertTo-Json) `
    -ContentType "application/json"

Write-Host "Policy updated. Changes take effect on next app check-in (up to 30 minutes)." -ForegroundColor Green
```

**Rollback:** Re-run PATCH with the original setting values captured in the `$current` object.

</details>

<details>
<summary>Fix 4 — Add a new managed app to an existing policy</summary>

**Scenario:** New LOB app or ISV partner app needs to be included in the existing protection policy.

```powershell
Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All" -NoWelcome

$policyId    = "<iOSPolicyId>"
$bundleId    = "<com.vendor.appbundleid>"  # iOS bundle ID from App Store
$appName     = "<App Display Name>"

$appBody = @{
    "@odata.type" = "#microsoft.graph.managedMobileApp"
    mobileAppIdentifier = @{
        "@odata.type" = "#microsoft.graph.iosMobileAppIdentifier"
        bundleId = $bundleId
    }
}

Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections/$policyId/apps" `
    -Body ($appBody | ConvertTo-Json -Depth 5) `
    -ContentType "application/json"

Write-Host "App '$appName' ($bundleId) added to policy." -ForegroundColor Green
Write-Host "Note: The app must contain the Intune SDK or be wrapped to enforce protection." -ForegroundColor Yellow
```

For Android:
```powershell
$policyId    = "<AndroidPolicyId>"
$packageName = "<com.vendor.apppackage>"

$appBody = @{
    "@odata.type" = "#microsoft.graph.managedMobileApp"
    mobileAppIdentifier = @{
        "@odata.type" = "#microsoft.graph.androidMobileAppIdentifier"
        packageId = $packageName
    }
}

Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/androidManagedAppProtections/$policyId/apps" `
    -Body ($appBody | ConvertTo-Json -Depth 5) `
    -ContentType "application/json"
```

</details>

<details>
<summary>Fix 5 — Exempt specific URLs/apps from clipboard restrictions</summary>

**Scenario:** Users need to copy content from managed apps to a specific approved tool (e.g., internal ticketing system) but clipboard policy is blocking them.

App Configuration Policies can set allowed transfer targets for specific apps. For Microsoft Edge as managed browser:

```powershell
# Create App Config Policy to allow specific URL exceptions in Edge
# Navigate to: Intune > Apps > App configuration policies > Add > Managed apps
# Target: Microsoft Edge for iOS or Android
# Key: com.microsoft.intune.mam.managedbrowser.AllowedOutboundClipboardSharingExceptions
# Value: <comma-separated URLs or app bundle IDs>

# Example via Graph:
$configBody = @{
    "@odata.type" = "#microsoft.graph.targetedManagedAppConfiguration"
    displayName = "Edge - Clipboard Exceptions"
    description = "Allow clipboard copy to approved internal tools"
    targetedAppManagementLevels = "selectedPublicApps"
    customSettings = @(
        @{
            name  = "com.microsoft.intune.mam.managedbrowser.AllowedOutboundClipboardSharingExceptions"
            value = "https://yourticketsystem.contoso.com"
        }
    )
}
# Note: full implementation requires adding the app target and group assignment
# Use Intune portal for complete setup; the above is a reference for settings
```

</details>

---

## Evidence Pack

```powershell
<#
  App Protection Policy Evidence Collector
  Requires: DeviceManagementApps.Read.All, AuditLog.Read.All
  Output: $env:TEMP\APP-Evidence-<timestamp>.txt
#>
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All","AuditLog.Read.All","User.Read.All" -NoWelcome

$upn       = "<UserPrincipalName>"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile   = "$env:TEMP\APP-Evidence-$timestamp.txt"
$sep       = "`n" + ("=" * 70) + "`n"

function Write-Section {
    param([string]$Title, [scriptblock]$Block)
    $result = try { & $Block | Out-String } catch { "ERROR: $($_.Exception.Message)" }
    Add-Content $outFile "$sep### $Title ###$sep$result"
}

$userId = (Get-MgUser -UserId $upn).Id
Set-Content $outFile "=== App Protection Policy Evidence === $(Get-Date) === User: $upn ==="

Write-Section "iOS App Protection Policies (all)" {
    Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections" |
        Select-Object -Expand value |
        Select-Object id, displayName, pinRequired, dataBackupBlocked, allowedOutboundClipboardSharingLevel | Format-Table
}
Write-Section "Android App Protection Policies (all)" {
    Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/androidManagedAppProtections" |
        Select-Object -Expand value |
        Select-Object id, displayName, pinRequired, dataBackupBlocked, allowedOutboundClipboardSharingLevel | Format-Table
}
Write-Section "User Managed App Registrations (check-ins)" {
    Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/managedAppRegistrations?`$filter=userId eq '$userId'" |
        Select-Object -Expand value |
        Select-Object displayName, platformType, managementSdkVersion, lastSyncDateTime,
            @{N="PoliciesApplied";E={($_.appliedPolicies).Count}} | Format-Table
}
Write-Section "User Group Memberships (for targeting verification)" {
    Get-MgUserMemberOf -UserId $userId | 
        ForEach-Object { Get-MgGroup -GroupId $_.Id -ErrorAction SilentlyContinue } |
        Select-Object Id, DisplayName | Format-Table
}
Write-Section "Recent Intune Audit Events for User" {
    Get-MgAuditLogDirectoryAudit -Filter "initiatedBy/user/id eq '$userId' and loggedByService eq 'Microsoft Intune'" -Top 20 |
        Select-Object ActivityDateTime, OperationType, Result | Format-Table
}

Write-Host "Evidence saved to: $outFile" -ForegroundColor Green
Invoke-Item (Split-Path $outFile)
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|-------------------|
| View APP status (portal) | Intune > Apps > Monitor > App protection status |
| List iOS APP policies | `Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/iosManagedAppProtections"` |
| List Android APP policies | `Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/androidManagedAppProtections"` |
| Get user's app registrations | Filter by `userId eq '<id>'` on `/managedAppRegistrations` |
| Trigger selective wipe | POST to `/managedAppRegistrations/<id>/operations` with `wipe` |
| Check wipe status | GET `/managedAppRegistrations/<id>/operations` |
| Add app to policy | POST to `/iosManagedAppProtections/<id>/apps` |
| Check policy assignments | GET `/iosManagedAppProtections/<id>/assignments` |
| Force policy re-delivery | User: sign out → clear cache → sign back in |
| Check CA + APP alignment | Entra > Security > Sign-in logs > [entry] > Conditional Access |
| Update policy setting | PATCH `/iosManagedAppProtections/<id>` with changed properties |

---

## 🎓 Learning Pointers

- **MAM-WE (without enrollment) is the cornerstone of BYOD strategy.** Unlike MDM which manages the whole device, MAM-WE only manages corporate data within specific apps. Users keep full personal privacy — IT can never see or wipe personal apps, photos, or personal data. This makes it legally and culturally acceptable for personal devices. Always clarify this to users before they enable the corporate account. See: [App protection policies overview](https://learn.microsoft.com/en-us/mem/intune/apps/app-protection-policy)

- **Android REQUIRES the Company Portal as a broker, even for BYOD/MAM-WE.** Unlike iOS where the Intune SDK can operate independently, Android MAM relies on Company Portal for broker authentication. Users must install it from Play Store. This is a deployment friction point on BYOD Android — include it in your BYOD onboarding instructions. The app itself doesn't need to be signed in for all MAM scenarios, but it needs to be present. See: [Android app protection policy settings](https://learn.microsoft.com/en-us/mem/intune/apps/app-protection-policy-settings-android)

- **Selective wipe is async — it only completes when the app opens and checks in.** For a terminated employee whose device you don't control, you cannot guarantee immediate wipe. This is a key risk to communicate to HR/Legal. Mitigations: revoke the user's Entra token immediately (which blocks re-authentication), then rely on MAM wipe for data cleanup when the app next opens. Token revocation via `Revoke-MgUserSignInSession` is immediate and prevents new access. See: [Wipe managed app data using Microsoft Intune](https://learn.microsoft.com/en-us/mem/intune/apps/apps-selective-wipe)

- **App Protection Policies and Conditional Access are complementary, not redundant.** CA can *require* an approved client app or *require* app protection policy as a grant condition. APP then *enforces* data residency within that app. You need both: CA to gate access, APP to contain data. A common gap is CA configured for "Require approved client app" but not "Require app protection policy" — this allows unmanaged versions of approved apps. See: [Require approved client app or app protection policy](https://learn.microsoft.com/en-us/entra/identity/conditional-access/howto-policy-approved-app-or-app-protection)

- **The "Open In Management" feature on iOS is the predecessor of APP data transfer controls.** iOS has a native system-level "Managed Open-In" feature. Intune's APP data transfer settings (`allowedOutboundDataTransferDestinations`) layer on top of this. When troubleshooting "why can't I open this in another app," understand whether the block is coming from iOS-native MDM Open-In controls (if device is enrolled) or from the Intune App Protection SDK data transfer policy. They behave differently. See: [iOS/iPadOS app protection policy settings](https://learn.microsoft.com/en-us/mem/intune/apps/app-protection-policy-settings-ios)

- **Not every app in the App Store is MAM-capable.** An app must include the Intune SDK or be wrapped with the Intune App Wrapping Tool. You can view the list of Microsoft-maintained MAM-enabled apps at the Intune protected apps page. For third-party apps, the ISV must have integrated the SDK. You can't MAM-enable an arbitrary app just by adding it to the policy — the policy will exist but won't be enforced in that app. See: [Microsoft Intune protected apps](https://learn.microsoft.com/en-us/mem/intune/apps/apps-supported-intune-apps)
