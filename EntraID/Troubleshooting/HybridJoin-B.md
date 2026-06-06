# Entra Hybrid Join (HAADJ) — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes. Device in on-prem AD but not appearing in Entra, or appearing but not MDM enrolled.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these on the affected device. Stop when you find the break.

```powershell
# 1. Is the device joined to on-prem AD AND Entra?
dsregcmd /status
# Look for:
#   DomainJoined     : YES   (on-prem AD join — prerequisite)
#   AzureAdJoined    : YES   (Entra hybrid join complete)
#   DomainName       : <your domain>
#   TenantName       : <your tenant>

# 2. Can the device reach a domain controller?
nltest /dsgetdc:<yourdomain.com>
# Expected: a DC name and IP. FAIL here = AD comms broken — fix networking before everything else.

# 3. Check Entra Connect sync status (run on Entra Connect server)
Import-Module ADSync
Get-ADSyncConnectorRunStatus
Get-ADSyncScheduler | Select-Object SyncCycleEnabled, NextSyncCyclePolicyType, CurrentlyRunning

# 4. Does the device object exist in Entra?
# (Run from any machine with Microsoft.Graph or Azure AD PowerShell)
Connect-MgGraph -Scopes "Device.Read.All"
Get-MgDevice -Filter "displayName eq '<COMPUTERNAME>'" | Select-Object DisplayName, TrustType, IsManaged, ApproximateLastSignInDateTime

# 5. Check the device registration event log on the affected device
Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 30 |
  Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
  Select-Object TimeCreated, Id, Message | Format-Table -Wrap
```

**Interpret — if X then do Y:**

| Finding | Next action |
|---------|------------|
| `DomainJoined: NO` | Device is not in on-prem AD — re-join to domain first. HAADJ cannot proceed. |
| `AzureAdJoined: NO` + device not in Entra portal | Work through [Dependency Cascade](#dependency-cascade) top-down |
| `AzureAdJoined: YES` but `IsManaged: false` in Entra | MDM auto-enrollment not triggering — see [Fix 5](#fix-5--mdm-auto-enrollment-not-triggering) |
| Device appears in Entra but marked `Pending` | SCP reached but device cert not yet issued — wait 15 min or force sync |
| Duplicate device objects in Entra | See [Fix 6](#fix-6--duplicate-device-objects) |
| Entra Connect `CurrentlyRunning: True` stuck | See [Fix 2](#fix-2--entra-connect-sync-not-syncing-device) |
| Event ID 301 in Device Registration log | Enterprise DRS endpoint unreachable — proxy issue, see [Fix 4](#fix-4--enterprise-registration-endpoint-blocked-by-proxy) |

---

## Dependency Cascade

<details><summary>What must be true for Hybrid Join to succeed — click to expand</summary>

```
[Device is domain-joined to on-prem AD]
    │
    ▼
[Entra Connect running with device sync scope enabled]
    │   Device objects must be in the sync scope OU
    │   Hybrid AD join feature enabled in Entra Connect wizard
    │
    ▼
[Service Connection Point (SCP) configured]
    │   SCP lives in: CN=62a0ff2e-97b9-4513-943f-0d221bd30080,
    │                  CN=Device Registration Configuration,
    │                  CN=Services,CN=Configuration,DC=<domain>
    │   Contains: Entra tenant ID + tenant name
    │   Device reads SCP at first logon to discover the DRS endpoint
    │
    ▼
[Device can reach enterprise registration endpoint]
    │   https://enterpriseregistration.windows.net
    │   https://login.microsoftonline.com
    │   https://device.login.microsoftonline.com
    │   Must not be SSL-inspected — certificate pinning applies
    │
    ▼
[Device registers with Entra DRS — certificate issued]
    │   Device gets a machine certificate from Entra
    │   This is what AzureAdJoined: YES means
    │
    ▼
[Entra device object created by Entra Connect sync]
    │   Entra Connect syncs the on-prem AD computer object
    │   Links it to the registered device
    │
    ▼
[MDM auto-enrollment triggered]
    │   Requires Intune license assigned to user
    │   MDM scope in Entra must include the device/user
    │   Enrollment URL discovered via MDM policy in Entra
    │
    ▼
[Device appears in Intune as Hybrid Entra Joined + Compliant]
```

</details>

---

## Diagnosis & Validation Flow

Work top-to-bottom. Fix the first broken layer before moving down.

**Step 1 — Verify on-prem AD join and DC connectivity**
```powershell
# On affected device
dsregcmd /status | Select-String "DomainJoined|DomainName|WorkplaceJoined"

# Test DC reachability
nltest /dsgetdc:<domain> /force
Test-ComputerSecureChannel -Verbose
```
Expected: `DomainJoined: YES`, secure channel is healthy. If `Test-ComputerSecureChannel` returns `False` → repair with `-Repair` switch or re-join.

**Step 2 — Verify SCP exists and has correct tenant info**
```powershell
# Run on any domain-joined machine (or on Entra Connect server)
$scp = Get-ADObject -Identity "CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,CN=Configuration,$((Get-ADDomain).DistinguishedName)" `
    -Properties keywords, serviceBindingInformation -ErrorAction SilentlyContinue

if ($null -eq $scp) {
    Write-Host "SCP MISSING — this is why devices cannot find the DRS endpoint" -ForegroundColor Red
} else {
    $scp | Select-Object Name, keywords, serviceBindingInformation | Format-List
}
```
Expected: `keywords` contains `AzureADName:<tenantname>` and `AzureADId:<tenantGUID>`.

**Step 3 — Verify Entra Connect device sync configuration**
```powershell
# On Entra Connect server
Import-Module ADSync

# Check hybrid join is configured
Get-ADSyncAADCompanyFeature | Select-Object DeviceWriteback, SelfServicePasswordReset

# Check device sync filter — are the computer OUs in scope?
Get-ADSyncConnector | Where-Object {$_.SubType -eq "Windows Azure Active Directory (Microsoft)"} |
    Select-Object Name, Type

# Trigger a delta sync and watch for errors
Start-ADSyncSyncCycle -PolicyType Delta
Start-Sleep -Seconds 60
Get-ADSyncConnectorRunStatus
```

**Step 4 — Check device object in Entra**
```powershell
Connect-MgGraph -Scopes "Device.Read.All"
$device = Get-MgDevice -Filter "displayName eq '<COMPUTERNAME>'" -All

if (-not $device) {
    Write-Host "Device NOT in Entra — sync issue or device never registered" -ForegroundColor Red
} else {
    $device | Select-Object DisplayName, DeviceId, TrustType, IsManaged,
        IsCompliant, ApproximateLastSignInDateTime, OperatingSystem,
        OperatingSystemVersion, ProfileType | Format-List
}
```
`TrustType` values: `ServerAd` = Hybrid, `AzureAd` = Entra-only join, `Workplace` = Registered.

**Step 5 — Test DRS endpoint reachability from device**
```powershell
# On the affected device
$endpoints = @(
    "https://enterpriseregistration.windows.net",
    "https://login.microsoftonline.com",
    "https://device.login.microsoftonline.com",
    "https://autologon.microsoftazuread-sso.com"
)

foreach ($url in $endpoints) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Host "OK      $url ($($response.StatusCode))" -ForegroundColor Green
    } catch {
        Write-Host "FAIL    $url — $($_.Exception.Message)" -ForegroundColor Red
    }
}
```

**Step 6 — Trigger manual device registration (on affected device)**
```powershell
# Force the scheduled task that runs device registration
$task = Get-ScheduledTask -TaskName "Automatic-Device-Join" -TaskPath "\Microsoft\Windows\Workplace Join\" -ErrorAction SilentlyContinue
if ($task) {
    Start-ScheduledTask -TaskName "Automatic-Device-Join" -TaskPath "\Microsoft\Windows\Workplace Join\"
    Write-Host "Task triggered. Wait 2-3 minutes then re-run dsregcmd /status"
} else {
    Write-Host "Task not found — check OS version or if Workplace Join feature is present" -ForegroundColor Yellow
}

# Watch for registration events
Start-Sleep -Seconds 90
Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 20 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap
```

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — SCP missing or incorrect tenant info</summary>

**Symptom:** SCP query returns nothing, or keywords show wrong tenant ID.

```powershell
# Create or fix the SCP — run on Entra Connect server or DC
# Requires: Azure AD Connect installed, or run from Entra Connect wizard

# Option A: Use Entra Connect wizard (safest)
# Open Entra Connect → Configure → Configure device options → Configure Hybrid Azure AD join
# The wizard will create/fix the SCP automatically

# Option B: Manual creation via PowerShell (advanced — confirm tenant details first)
Import-Module ActiveDirectory

$tenantId   = "<your-tenant-GUID>"          # From Entra portal → Overview
$tenantName = "<yourtenant>.onmicrosoft.com" # Your tenant domain

$configNC  = (Get-ADRootDSE).configurationNamingContext
$scpPath   = "CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configNC"

# Check if it exists
$existing = Get-ADObject -Identity $scpPath -ErrorAction SilentlyContinue

if (-not $existing) {
    # Create it
    New-ADObject -Name "62a0ff2e-97b9-4513-943f-0d221bd30080" `
        -Type "serviceConnectionPoint" `
        -Path "CN=Device Registration Configuration,CN=Services,$configNC" `
        -OtherAttributes @{
            keywords           = "AzureADName:$tenantName", "AzureADId:$tenantId"
            serviceBindingInformation = "https://device.login.microsoftonline.com/"
        }
    Write-Host "SCP created" -ForegroundColor Green
} else {
    # Fix it
    Set-ADObject -Identity $scpPath -Replace @{
        keywords           = "AzureADName:$tenantName", "AzureADId:$tenantId"
        serviceBindingInformation = "https://device.login.microsoftonline.com/"
    }
    Write-Host "SCP updated" -ForegroundColor Green
}

# Verify
Get-ADObject -Identity $scpPath -Properties keywords, serviceBindingInformation | Format-List
```

> After SCP is fixed, affected devices need to re-run the Automatic-Device-Join scheduled task. Devices read the SCP at logon — a reboot may be required for cached values to clear.

</details>

<details id="fix-2"><summary>Fix 2 — Entra Connect not syncing device / device not in scope</summary>

**Symptom:** Device exists in on-prem AD, SCP is correct, but device never appears in Entra.

```powershell
# On Entra Connect server

# Step 1: Check if device's OU is in sync scope
# Open Entra Connect → Customize synchronization options → Domain/OU filtering
# Ensure the computer OU containing affected devices is checked

# Step 2: Check if Hybrid AD Join is enabled in Entra Connect
Import-Module ADSync
Get-ADSyncAADCompanyFeature

# Step 3: If device OU was recently added to scope, run a full sync
Start-ADSyncSyncCycle -PolicyType Initial
# Warning: Initial sync is heavier — schedule during low-traffic hours if possible
# Delta sync is sufficient if the device was already in scope but just missed
Start-ADSyncSyncCycle -PolicyType Delta

# Step 4: Check sync errors after cycle completes (wait ~5 min)
Start-Sleep -Seconds 300
Get-ADSyncConnectorRunStatus

# Check for specific device sync errors
$deviceName = "<COMPUTERNAME>"
# Look in Synchronization Service Manager (miisclient.exe) for the computer object
# Or query the metaverse directly:
Search-ADSyncObject -AttributeName "displayName" -AttributeValue $deviceName -ObjectType "computer" -SearchConnectedDirectories $true
```

**If devices are in scope but still not syncing — check sync rules:**
```powershell
# Verify the device sync rule is active
Get-ADSyncRule | Where-Object { $_.Name -like "*Computer*" -or $_.Name -like "*Device*" } |
    Select-Object Name, Enabled, Direction | Format-Table
```

</details>

<details id="fix-3"><summary>Fix 3 — Hybrid Join not enabled in Entra Connect wizard</summary>

**Symptom:** Entra Connect is syncing devices, but `dsregcmd /status` shows `AzureAdJoined: NO` on all machines, and no device objects appear in Entra with `TrustType: ServerAd`.

```powershell
# Verify on Entra Connect server
Import-Module ADSync
# This should show DeviceWriteback or Hybrid Azure AD join is configured
Get-ADSyncGlobalSettings | Select-Object -ExpandProperty Parameters |
    Where-Object { $_.Name -like "*Device*" -or $_.Name -like "*Hybrid*" }
```

**Correct fix:** Run the Entra Connect wizard:
1. Open **Azure AD Connect** on the sync server
2. Choose **Configure** → **Configure device options**
3. Select **Configure Hybrid Azure AD join** → Next
4. Select your forest and **Add** the service account
5. Complete the wizard — it will configure SCP and sync rules automatically

> Do not manually edit sync rules unless you are experienced with ADSync — the wizard is the supported path.

</details>

<details id="fix-4"><summary>Fix 4 — Enterprise registration endpoint blocked by proxy</summary>

**Symptom:** Step 5 connectivity test shows failures to `enterpriseregistration.windows.net` or `device.login.microsoftonline.com`. Event ID 301 in Device Registration/Admin log.

```powershell
# On affected device — detailed proxy diagnostics
netsh winhttp show proxy

# Check if system proxy is set (device registration uses SYSTEM context, not user proxy)
# User IE proxy settings do NOT apply here
[System.Net.WebProxy]::GetDefaultProxy()

# Test with explicit bypass
$testUrl = "https://enterpriseregistration.windows.net/<yourtenant>.onmicrosoft.com/discover?api-version=1.7"
Invoke-WebRequest -Uri $testUrl -UseBasicParsing

# Check WPAD/proxy auto-config
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
```

**Fix — add proxy exclusions for device registration (on proxy server AND as WinHTTP proxy bypass):**

Required bypass list:
```
enterpriseregistration.windows.net
device.login.microsoftonline.com
login.microsoftonline.com
autologon.microsoftazuread-sso.com
```

```powershell
# Set WinHTTP proxy bypass (deploy via GPO: Computer Configuration → Windows Settings → WinHTTP Proxy)
# Or manually for testing:
netsh winhttp set proxy proxy-server="<proxyhost>:<port>" bypass-list="*.microsoftonline.com;enterpriseregistration.windows.net;device.login.microsoftonline.com"
```

> SSL inspection (MITM) on these endpoints breaks device registration due to certificate pinning. The proxy must **not** inspect these URLs — add them as SSL bypass rules on the proxy appliance.

</details>

<details id="fix-5"><summary>Fix 5 — MDM auto-enrollment not triggering</summary>

**Symptom:** `AzureAdJoined: YES` and device appears in Entra, but `IsManaged: false` and device is absent from Intune.

```powershell
# On affected device — check enrollment status
dsregcmd /status | Select-String "MDM|EnterpriseJoined|IsManaged|Compliant"

# Check MDM enrollment URLs are present (populated from Entra MDM configuration)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments" -ErrorAction SilentlyContinue

# Check scheduled enrollment task
Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" -ErrorAction SilentlyContinue |
    Select-Object TaskName, State, LastRunTime, LastTaskResult

# Trigger enrollment manually
$enrollTask = Get-ScheduledTask -TaskName "Schedule #3 created by enrollment client" `
    -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" -ErrorAction SilentlyContinue
if ($enrollTask) {
    Start-ScheduledTask -TaskName $enrollTask.TaskName -TaskPath $enrollTask.TaskPath
}

# Or trigger via deviceenroller directly
& "$env:SystemRoot\System32\deviceenroller.exe" /c /AutoEnrollMDM
```

**If MDM enrollment tasks are absent — verify Entra MDM scope:**
1. Go to **Entra portal** → **Mobility (MDM and MAM)** → **Microsoft Intune**
2. Confirm **MDM User scope** is set to `All` or includes the affected user's group
3. Confirm **MDM Terms of use URL**, **MDM Discovery URL**, and **MDM Compliance URL** are populated (they auto-populate for Intune)

```powershell
# Verify user has Intune license
Connect-MgGraph -Scopes "User.Read.All"
$user = Get-MgUser -UserId "<upn>" -Property AssignedLicenses, DisplayName
$user.AssignedLicenses | ForEach-Object {
    Get-MgSubscribedSku -SubscribedSkuId $_.SkuId | Select-Object SkuPartNumber
}
# Must include INTUNE_A or equivalent SKU
```

</details>

<details id="fix-6"><summary>Fix 6 — Duplicate device objects in Entra</summary>

**Symptom:** `Get-MgDevice` returns multiple objects with the same `displayName`. Stale objects can block re-registration or cause Conditional Access failures.

```powershell
Connect-MgGraph -Scopes "Device.ReadWrite.All"

$deviceName = "<COMPUTERNAME>"
$dupes = Get-MgDevice -Filter "displayName eq '$deviceName'" -All |
    Select-Object DeviceId, DisplayName, TrustType, ApproximateLastSignInDateTime, IsManaged, IsCompliant

$dupes | Format-Table

# Identify the stale one — oldest LastSignIn + IsManaged: false
# The active device will have a recent sign-in and IsManaged: true

# Disable the stale object first (safer than immediate delete — wait 24h, then delete)
$staleId = "<stale-device-object-id>"
Update-MgDevice -DeviceId $staleId -AccountEnabled:$false

# After confirming no impact, delete it
Remove-MgDevice -DeviceId $staleId
```

> Duplicates typically appear after re-imaging without cleaning up the old object, or after a device name change. Once the old object is removed, the active device should re-register cleanly on next sign-in.

</details>

---

## Escalation Evidence

```
HAADJ Failure — Evidence Pack
====================================
Device name:              
OS version:               [dsregcmd /status → OSVersion]
Domain:                   
Tenant:                   
Entra Connect server:     

dsregcmd /status output:
  DomainJoined:           [YES / NO]
  AzureAdJoined:          [YES / NO]
  EnterpriseJoined:       [YES / NO]
  DomainName:             
  TenantName:             
  AzureAdPrt:             [YES / NO — PRT health]

SCP present:              [YES / NO — see Step 2]
SCP tenant ID matches:    [YES / NO]
Device in Entra:          [YES / NO / Pending]
Device TrustType:         [ServerAd / AzureAd / Workplace / Missing]
Entra Connect sync:       [Last sync time, any errors?]
DRS endpoint reachable:   [YES / NO — output of Step 5]
Proxy in use:             [YES / NO — proxy name/type]
SSL inspection bypass:    [Configured / Not configured]
MDM scope includes user:  [YES / NO]
User has Intune license:  [YES / NO]

Event log errors:
  Device Registration log: [Event IDs seen]
  Application log:          [Any AADJ / enrollment errors]

Steps already tried:
```

---

## 🎓 Learning Pointers

- **HAADJ vs Entra Join — know the difference before you troubleshoot.** HAADJ (Hybrid) keeps the device in on-prem AD AND registers it with Entra. Entra Join (modern) has no on-prem AD object at all. They have completely different registration flows, SCP is only relevant to HAADJ, and you diagnose them with different `dsregcmd` fields. [MS Docs: Device identity overview](https://learn.microsoft.com/en-us/entra/identity/devices/overview)

- **The SCP is read by the device in SYSTEM context at logon.** It contains only two pieces of info: the tenant ID and the DRS endpoint. A wrong tenant ID sends all your devices to the wrong tenant — a surprisingly common migration mistake. Verify it with the AD query in Step 2 before blaming anything else.

- **Entra Connect device writeback vs device sync are different things.** Device *sync* replicates on-prem computer objects up to Entra. Device *writeback* pushes Entra-registered device objects back down to on-prem AD (used for on-prem Conditional Access with AD FS). HAADJ needs sync, not writeback. Conflating these wastes significant time. [MS Docs: Entra Connect device options](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-device-options)

- **The Automatic-Device-Join scheduled task is the trigger mechanism.** It runs at logon and every hour. If you want to test registration without rebooting or waiting, run the task manually and watch the Device Registration/Admin event log in real time: `Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 5` after triggering it.

- **Proxy SSL inspection is the single most common root cause in enterprise environments.** `enterpriseregistration.windows.net` and `device.login.microsoftonline.com` use certificate pinning. A MITM proxy that re-signs these connections will silently break registration with event ID 301 or a generic "failed to register" message. The fix is a bypass rule on the proxy — not a certificate trust change on the devices.

- **`dsregcmd /debug` exists and is much more verbose than `/status`.** When `/status` gives you `AzureAdJoined: NO` with no obvious cause, run `dsregcmd /debug` and redirect output to a file — it traces each step of the registration attempt including HTTP responses. [MS Docs: Troubleshoot hybrid Entra joined devices](https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-hybrid-join-windows-current)
