# Intune Enrollment — Hotfix Runbook (Mode B: Ops)

> Device won't enroll. Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis Flow](#diagnosis--validation-flow)
- [Fix Paths](#common-fix-paths)
- [Error Code Reference](#common-error-codes)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

```powershell
# Run on the device — this is the single most important command
dsregcmd /status

# Key fields to check:
# AzureAdJoined        : YES / NO
# EnterpriseJoined     : NO (should always be NO for modern devices)
# DomainJoined         : YES / NO
# MDMEnrollmentURL     : should contain manage.microsoft.com
# MDMUrl               : should contain manage.microsoft.com
# AzureAdPrt           : YES (if NO = identity/auth issue, fix that first)
```

**Interpret:**
| dsregcmd result | Problem | Go to |
|----------------|---------|-------|
| AzureAdJoined = NO | Device not joined to Entra | Fix Entra join first |
| AzureAdPrt = NO | PRT missing — auth broken | See `EntraID/Troubleshooting/` |
| MDMEnrollmentURL = empty | MDM scope or auto-enroll not configured | [Fix 2](#fix-2--mdm-auto-enrolment-not-configured) |
| AzureAdJoined = YES, MDM URL = empty | User not in MDM scope | [Fix 2](#fix-2--mdm-auto-enrolment-not-configured) |
| All YES but device still "pending" | Device hasn't checked in yet | [Fix 5](#fix-5--force-enrolment-sync) |

---

## Dependency Cascade

<details><summary>What must be true for enrollment to succeed</summary>

```
User has Intune licence (EMS E3/E5, M365 E3/E5, or standalone)
    → User is in MDM scope (All Users or assigned group)
    → Device can reach MDM endpoints:
        *.manage.microsoft.com (HTTPS 443)
        *.microsoftonline.com
        *.windows.net
    → Device is Entra Joined (or Hybrid Joined for HAADJ enrollment)
    → No enrollment restrictions blocking device type/platform/OS version
    → Device limit not exceeded (default 15 per user)
    → Device not already enrolled (stale record in Intune)
    → MDM authority = Microsoft Intune (check in Intune admin portal)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Licence check**
```powershell
# Connect to Graph
Connect-MgGraph -Scopes "User.Read.All","DeviceManagementManagedDevices.Read.All"

# Check user licence
Get-MgUserLicenseDetail -UserId <UPN> | Select SkuPartNumber
# Need to see: INTUNE_A, EMS, SPE_E3, SPE_E5, or equivalent
```

**Step 2 — MDM scope**
```
Intune Admin Center (intune.microsoft.com)
→ Devices → Enroll devices → Automatic Enrollment
→ MDM User Scope: check if user's group is included
→ MAM User Scope: separate from MDM (don't confuse)
```

**Step 3 — Enrollment restrictions**
```
Intune → Devices → Enroll devices → Enrollment restrictions
→ Check: does the device platform (Windows) pass?
→ Check: OS version restrictions — is 24H2 allowed?
→ Check: personally owned blocking?
→ Check: device limit restriction
```

**Step 4 — Stale device record**
```powershell
# Check for duplicate/stale Intune device records
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
  Select DeviceName, Id, EnrolledDateTime, ComplianceState, ManagementState
# Multiple records = stale. Delete the old ones.
```

**Step 5 — Network connectivity to MDM endpoints**
```powershell
# On the device
Test-NetConnection manage.microsoft.com -Port 443
Test-NetConnection dm.microsoft.com -Port 443
Test-NetConnection enterpriseenrollment.contoso.com -Port 443  # If using CNAME

# Check corporate proxy — MDM traffic must not be intercepted
Invoke-WebRequest -Uri "https://manage.microsoft.com" -UseBasicParsing
```

**Step 6 — Check enrollment event log**
```powershell
# This is the most detailed error source
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" |
  Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
  Sort-Object TimeCreated -Descending |
  Select TimeCreated, Id, Message -First 20 | Format-Table -Wrap
```

---

## Common Fix Paths

<details><summary>Fix 1 — User not licensed</summary>

```powershell
# Assign Intune licence via Graph
$user = Get-MgUser -UserId "<UPN>"
$skuId = (Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq "INTUNE_A" }).SkuId

Set-MgUserLicense -UserId $user.Id `
  -AddLicenses @{SkuId = $skuId} `
  -RemoveLicenses @()

# Allow 5–10 minutes for licence propagation, then retry enrollment
```

</details>

<details id="fix-2"><summary>Fix 2 — MDM auto-enrolment not configured</summary>

```
Intune Admin Center → Devices → Enroll devices → Windows enrollment → Automatic enrollment
Set MDM User Scope to: All (or add specific group)
Set MAM User Scope separately if needed

Alternatively via Entra ID:
Entra Portal → Mobility (MDM and MAM) → Microsoft Intune
MDM User Scope: All or specific groups
MDM Terms of use URL / Discovery URL: leave as default
```

</details>

<details><summary>Fix 3 — Stale/duplicate device record</summary>

```powershell
# Find all Intune records for this device
Get-MgDeviceManagementManagedDevice `
  -Filter "deviceName eq '<deviceName>'" |
  Select DeviceName, Id, EnrolledDateTime, ManagementState | Format-Table

# Delete old records (keep the most recent or the active one)
Remove-MgDeviceManagementManagedDevice -ManagedDeviceId "<staleId>"

# Also clean up Entra ID device objects if duplicated
Get-MgDevice -Filter "displayName eq '<deviceName>'" |
  Select DisplayName, Id, RegisteredDateTime, TrustType

# Then retry enrollment on device
```

</details>

<details><summary>Fix 4 — Enrollment restrictions blocking device</summary>

```
Intune → Devices → Enroll devices → Enrollment device platform restrictions
Check "Windows (MDM)" restriction assigned to user's group
Common blocks:
  - OS version minimum set higher than device's current build
  - "Personally owned" blocked (if device not corp-owned in Entra)
  - Manufacturer/model blocked

Fix: Adjust restriction or create a higher-priority restriction for this user/group
```

</details>

<details id="fix-5"><summary>Fix 5 — Force enrolment sync</summary>

```powershell
# Option 1: Task Scheduler (most reliable)
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" -TaskName "Schedule #1 created by enrollment client"

# Option 2: DeviceEnroller
Start-Process "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"

# Option 3: Via Intune portal
# Devices → find device → Sync button

# Option 4: Company Portal app → Settings → Sync
```

</details>

<details><summary>Fix 6 — Hybrid Join enrollment (HAADJ) failing</summary>

```powershell
# Check hybrid join state
dsregcmd /status | Select-String "DomainJoined|AzureAdJoined|EnterpriseJoined"
# Should show: DomainJoined=YES, AzureAdJoined=YES for HAADJ

# Check Entra Connect sync
# Run on Entra Connect server:
Get-ADSyncScheduler
Start-ADSyncSyncCycle -PolicyType Delta  # Force a delta sync

# Check if device synced to Entra
Get-MgDevice -Filter "displayName eq '<deviceName>'" | Select TrustType
# TrustType should be "ServerAD" for HAADJ

# Common HAADJ failures:
# - SCP (Service Connection Point) not configured
# - Enterprise registration endpoint not reachable
# - Device not in sync scope for Entra Connect
```

</details>

---

## Common Error Codes

| Code | Meaning | Fix |
|------|---------|-----|
| 0x80180014 | MDM enrolment blocked by restriction | Check enrollment restrictions |
| 0x80180026 | Device limit exceeded | Delete stale Intune records |
| 0x8018002a | MDM authority not set | Set authority to Intune in admin portal |
| 0x80070774 | Auto-enrollment timed out | Force sync, check network to MDM endpoints |
| 0xcaa9001f | Token acquisition failed | PRT issue — fix Entra join first |
| 0x80192ee2 | Network error to MDM endpoint | Firewall/proxy blocking manage.microsoft.com |
| 80180003 | Device not licensed | Assign Intune licence |

---

## Escalation Evidence

```
Intune Enrollment Failure — Evidence Pack
==========================================
Device name:             
Device platform/OS:      [Win11 24H2, etc.]
User UPN:                
Error code:              [from device event log or portal]
dsregcmd /status output: [full paste — remove any sensitive domain info]
MDM scope setting:       [All / Specific groups — which group?]
Licence confirmed:       [Yes/No — which SKU?]
Enrollment restrictions: [Any blocks found?]
Stale records found:     [Yes/No — how many?]
Network test results:    [manage.microsoft.com 443 — OK/FAIL]
Enrollment type:         [Autopilot / Manual / Auto-enroll / HAADJ]
MDMDiagnostics zip:      [Attach if available]
```

---

## 🎓 Learning Pointers

- **`dsregcmd /status` is the starting point for everything** — this single command tells you join state, PRT health, MDM enrollment URL, and TPM state. Memorise the key fields. It's faster than opening any portal.
- **MDM scope vs MAM scope** — these are completely separate settings. MAM (Mobile Application Management) manages apps without device enrollment. MDM manages the whole device. Many engineers confuse them and set MAM when they meant MDM scope.
- **Enrollment restrictions priority** — Intune processes restrictions in priority order (1 is highest). If you have a "block personally owned" rule at priority 1 and an "allow" rule at priority 2, the block wins. This trips up complex environments constantly.
- **HAADJ timing** — Hybrid join requires: domain join → Entra Connect sync (up to 30 min on delta) → device restarts and completes Entra registration. The process has multiple async stages. Don't expect it to complete in under an hour in a new setup.
- **MDMDiagnosticsTool** — When nothing else gives you the error, this tool generates a zip with all MDM-related logs. `mdmdiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning -zip C:\MDMLogs.zip` — this is what you attach to Microsoft support cases.
