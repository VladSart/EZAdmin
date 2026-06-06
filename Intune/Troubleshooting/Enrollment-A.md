
# Intune Enrollment — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How Enrollment Works](#how-enrollment-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers MDM enrollment for Windows 10/11 devices via:
- **Windows Autopilot** (user-driven, pre-provisioning, self-deploying)
- **SCCM Co-management** enrollment path
- **Manual / bulk enrollment** (via Settings > Accounts > Access work or school)
- **Azure AD Join** with automatic MDM enrollment
- **Hybrid Azure AD Join** with MDM enrollment

**Out of scope:** macOS ADE enrollment (see `macOS/Troubleshooting/ADE-Enrollment-B.md`), iOS/Android.

**Assumed knowledge:** You understand AAD, MDM authority, and can read PowerShell output.

---

## How Enrollment Works

<details><summary>Full enrollment architecture</summary>

### Phase 1 — Azure AD Authentication
Device must authenticate to AAD before MDM enrollment can start.

```
User/Device authenticates to AAD
       │
       ├─ AAD checks: Is this device registered/joined?
       │      ├─ Not registered → Register device (creates AAD device object)
       │      └─ Already joined → Verify token
       │
       └─ AAD returns: access_token + device_token
```

### Phase 2 — MDM Discovery
The Windows enrollment agent performs MDM discovery using the enrolled UPN domain.

```
deviceenroller.exe discovers MDM endpoint via:
  1. Well-known endpoint: https://enterpriseenrollment.<domain>/EnrollmentServer/Discovery.svc
  2. Fallback: EnterpriseRegistration CNAME record in DNS
  3. Fallback: Azure AD MDM Discovery URL (registered in AAD > Mobility > Microsoft Intune)
```

**Common failure point:** If the tenant's domain doesn't have the AAD MDM Discovery URL set correctly under `AAD > Mobility > Microsoft Intune > MDM User Scope`, Windows can't discover the enrollment endpoint.

### Phase 3 — MDM Enrollment (OMA-DM)
After discovery, the device calls the enrollment endpoint and negotiates:

```
Device → Enrollment Server (svc/2019/06/management):
  POST /EnrollmentServer/Enrollment.svc
  Body: DeviceEnrollmentRequest (SOAP)
    - DeviceType (CIMClient_Windows)
    - OSEdition
    - EnrollmentType (Device or Full)
    - AAD Token

Server → Device:
  MDM Client Certificate (signed by Intune CA)
  WAP Provisioning Document (OMA-DM server URL, sync schedule)
```

**The MDM client certificate is how Intune authenticates the device on every subsequent sync.** Certificate expiry = device loses management.

### Phase 4 — Policy Download (OMA-DM)
Device opens an OMA-DM session and downloads initial policy payload:

```
Managed device → Intune MDM endpoint:
  Syncs: Configuration policies, compliance policies, apps
  Interval: Every 8h by default; ESP holds this to every 5min during OOBE
```

### Phase 5 — Registration in Intune Portal
Intune creates the managed device record. This is what you see in the portal.

```
Delay: Up to 15 minutes after successful enrollment
Common misconception: "Device enrolled but not showing" is usually just this delay.
```

### Key services involved
| Service | What it does | How to check |
|---------|-------------|--------------|
| `deviceenroller.exe` | Core enrollment binary | Event logs → DeviceManagement-Enterprise-Diagnostics-Provider |
| `OmaDmAgent` | Ongoing MDM sync (OMA-DM sessions) | Task Scheduler → Microsoft\Windows\EnterpriseMgmt |
| `MDM Certificate` | Device auth to MDM | `certlm.msc` → Personal > Certificates |
| `AAD token cache` | Proves AAD identity | `dsregcmd /status` → SSO State |
| `Intune Management Extension` | Win32 app/PowerShell agent | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\` |

</details>

---

## Dependency Stack

```
┌─────────────────────────────────────────────┐
│         Intune Portal (portal.azure.com)    │  ← Management plane
└─────────────────┬───────────────────────────┘
                  │ Graph API / OMA-DM
┌─────────────────┴───────────────────────────┐
│     Microsoft Intune MDM Service            │  ← Enrollment endpoint
│     (manage.microsoft.com)                 │
└─────────────────┬───────────────────────────┘
                  │ AAD-issued device token
┌─────────────────┴───────────────────────────┐
│     Azure Active Directory                  │  ← Identity plane
│     (login.microsoftonline.com)            │
└─────────────────┬───────────────────────────┘
                  │ Internet (HTTPS / port 443)
┌─────────────────┴───────────────────────────┐
│     Client Device                           │
│  ┌────────────────────────────────────┐     │
│  │  deviceenroller.exe                │     │  ← Enrollment agent
│  │  OmaDmAgent (scheduled task)       │     │  ← Sync agent
│  │  IME (IntuneManagementExtension)   │     │  ← Win32 / script agent
│  │  MDM cert (certlm.msc > Personal)  │     │  ← Auth credential
│  └────────────────────────────────────┘     │
└─────────────────────────────────────────────┘

Supporting dependencies:
  DNS ──────────────────────────────────── EnterpriseRegistration CNAME
  NTP ──────────────────────────────────── Certificate validity (time skew breaks TLS)
  Proxy/Firewall ───────────────────────── *.manage.microsoft.com, *.dm.microsoft.com
  MDM Authority ────────────────────────── Set to Intune (not SCCM/None)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "This account is not authorized to enroll" | MDM User Scope in AAD is not "All" or user is not in scope group | AAD > Mobility > Microsoft Intune > MDM User Scope |
| "MDM discovery failed" / 0x80180002 | DNS missing EnterpriseRegistration CNAME or AAD MDM URL not set | `nslookup enterpriseregistration.<domain>` |
| Enrollment hangs at "Setting up your device" | ESP apps blocking — one Win32 app failing to install | IME logs: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` |
| 0x80070774 | MDM certificate enrollment failed — CA connectivity issue | Event ID 82 in DeviceManagement-Enterprise-Diagnostics-Provider |
| Device shows "Enrollment failed" then disappears from portal | AAD token expired mid-enrollment (common in pre-provisioned Autopilot) | `dsregcmd /status` — AzureAdJoined and PRT fields |
| Device enrolls but no policies apply | MDM authority mismatch (was SCCM, switched to Intune) | Check co-management settings in SCCM + Intune |
| "You can only enroll X devices" | Intune enrollment limit reached for this user | Devices > Enrollment restrictions > Device limit |
| Enrollment succeeds but device stuck "Pending" in Intune | MDM cert issued but device hasn't completed first sync | Wait 15min; trigger sync via `Invoke-IntuneSync.ps1` |
| Event ID 76 in DEMS-Provider | AAD Join failed — device object creation error in AAD | AAD > Devices > All devices — search by hostname |
| 0x80180026 | Device already enrolled in another MDM | Check HKLM:\SOFTWARE\Microsoft\Enrollments for existing enrollment |

---

## Validation Steps

### Step 1 — Confirm AAD Join / Registration

```powershell
dsregcmd /status
```

**Good output:**
```
AzureAdJoined    : YES
WorkplaceJoined  : NO
DomainJoined     : YES        # for Hybrid Join
AzureAdPrtUpdateTime : recent timestamp
```

**Bad output:**
- `AzureAdJoined: NO` → Device hasn't completed AAD join; enrollment won't proceed
- `PRT: NO` → Primary Refresh Token missing; user can't authenticate to AAD

---

### Step 2 — Confirm MDM Enrollment Exists

```powershell
Get-Item "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
    Get-ItemProperty |
    Select-Object PSChildName, ProviderID, EnrollmentState, UPN |
    Where-Object { $_.ProviderID -like "*microsoft*" }
```

**Good output:** Row with `ProviderID = MS DM Server` and `EnrollmentState = 1`

**Bad output (EnrollmentState values):**
- `0` = Not enrolled
- `1` = Enrolled ✅
- `6` = Enrollment in progress
- `7` = Unenrolled

---

### Step 3 — Check MDM Certificate

```powershell
Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Issuer -like "*Microsoft Intune*" -or $_.Issuer -like "*MDM*" } |
    Select-Object Subject, Issuer, NotAfter, Thumbprint
```

**Good:** Certificate present, `NotAfter` > today + 60 days

**Bad:** No certificate, or `NotAfter` in past → Device will lose management on next sync attempt

---

### Step 4 — Verify OMA-DM Scheduled Tasks

```powershell
Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" |
    Select-Object TaskName, State, @{N='LastRun';E={$_.LastRunTime}} |
    Sort-Object LastRun
```

**Good:** Tasks present, `State = Ready`, LastRun within last 24h

**Bad:** Tasks missing or `State = Disabled` → OMA-DM sync not running

---

### Step 5 — Network Connectivity to MDM Endpoints

```powershell
$endpoints = @(
    "manage.microsoft.com",
    "dm.microsoft.com",
    "login.microsoftonline.com",
    "EnterpriseRegistration.windows.net",
    "EnterpriseEnrollment.windows.net",
    "fef.msuc03.manage.microsoft.com"  # may vary by region
)
$endpoints | ForEach-Object {
    $r = Test-NetConnection -ComputerName $_ -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint = $_; Reachable = $r.TcpTestSucceeded }
}
```

**Good:** All `Reachable = True`

**Bad:** Any `False` → Firewall/proxy blocking enrollment. Check [Intune network endpoints](https://docs.microsoft.com/en-us/mem/intune/fundamentals/intune-endpoints).

---

### Step 6 — Check Enrollment Event Logs

```powershell
# Last 20 enrollment-related events (errors and warnings)
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" `
    -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object { $_.Level -le 3 } |
    Select-Object TimeCreated, Id, Message |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 20 |
    Format-List
```

**Key Event IDs:**
| ID | Meaning |
|----|---------|
| 72 | Enrollment completed successfully |
| 76 | AAD Join failed |
| 82 | MDM certificate enrollment failed |
| 102 | OMA-DM sync completed |
| 201 | Enrollment failed |

---

## Troubleshooting Steps by Phase

### Phase 1 — AAD Auth Issues
1. Run `dsregcmd /status` — check AzureAdJoined, PRT, and SSO State
2. If PRT missing: `dsregcmd /refreshprt` (user context, not admin)
3. If AAD Join shows NO: check if device object exists in AAD portal
4. For Hybrid Join: verify domain controller reachability and `dsregcmd /debug`

### Phase 2 — MDM Discovery Issues
1. Check DNS: `Resolve-DnsName EnterpriseRegistration.<yourdomain>` — should resolve to `EnterpriseRegistration.windows.net`
2. Check AAD MDM Discovery URL: `AAD Portal > Mobility > Microsoft Intune > MDM Discovery URL` should be `https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc`
3. Verify MDM User Scope includes the enrolling user

### Phase 3 — Enrollment Certificate Issues
1. Open `certlm.msc` → Personal → Certificates — look for Intune/MDM cert
2. If missing: force re-enrollment via Settings > Accounts > Remove work account > Re-add
3. If expired: `dsregcmd /leave` then re-join (destructive — back up BitLocker key first)

### Phase 4 — Policy Sync Issues
1. Trigger manual sync: `Invoke-IntuneSync.ps1 -Local`
2. Check IME log for Win32/script failures: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\`
3. Check OMA-DM log: `C:\Windows\CCM\Logs\` (co-managed) or MDM Diagnostic Report

### Phase 5 — Enrollment Limit/Restriction Issues
1. Check user's current device count: Intune > Users > [user] > Devices
2. Check enrollment restriction policy: Intune > Devices > Enrollment Restrictions
3. Platform restrictions: Verify OS version and platform is allowed

---

## Remediation Playbooks

<details><summary>Playbook 1 — Force Re-Enrollment (Non-Destructive)</summary>

Use when: Device is enrolled but policies aren't applying, or enrollment shows stale.

```powershell
# Step 1: Check current enrollment state
Get-Item "HKLM:\SOFTWARE\Microsoft\Enrollments\*" | Get-ItemProperty | Select-Object PSChildName, EnrollmentState

# Step 2: Trigger sync (try this first)
Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" |
    Start-ScheduledTask

# Step 3: If sync doesn't help, reset enrollment state via Settings
# Settings > Accounts > Access work or school > [account] > Info > Sync
# (UI method, non-destructive)

# Step 4: Check results after 10 minutes
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 10 |
    Select-Object TimeCreated, Id, Message
```

**Rollback:** No rollback needed — this is non-destructive.

</details>

<details><summary>Playbook 2 — Full Re-Enrollment via Leave/Rejoin (Destructive)</summary>

Use when: Enrollment is corrupt, MDM cert is expired, or device shows "Unknown" in Intune.

⚠️ **WARNING:** This removes AAD join and MDM enrollment. BitLocker keys must be backed up first.

```powershell
# PRE-FLIGHT — back up BitLocker key to AAD BEFORE leaving
manage-bde -protectors -get C: | Select-String "ID:"
# Verify the recovery key is visible in AAD > Devices > [device] > BitLocker keys

# Step 1: Disjoin device from AAD (run as local admin)
dsregcmd /leave
# If Hybrid Joined, also run: netdom remove <computername> /domain:<domain>

# Step 2: Reboot

# Step 3: Re-join
# For AAD Join: Settings > Accounts > Access work or school > Connect > Join this device to Azure AD
# For Hybrid Join: Run gpupdate /force and wait for auto-join (may take up to 4h)

# Step 4: Verify enrollment
dsregcmd /status
Get-Item "HKLM:\SOFTWARE\Microsoft\Enrollments\*" | Get-ItemProperty
```

**Rollback:** Cannot fully reverse — device object is deleted from AAD. Create a new one via the join process.

</details>

<details><summary>Playbook 3 — Collect MDM Diagnostic Report</summary>

Use when: Escalating to Microsoft support or for complex enrollment failures.

```powershell
# Generate MDM Diagnostic Report (saves to C:\Users\Public\Documents\MDMDiagnostics)
mdmdiagnosticstool.exe -area Autopilot;DeviceEnrollment;DeviceProvisioning;TPM -zip "C:\Temp\MDMDiag_$(hostname)_$(Get-Date -Format 'yyyyMMdd').zip"

# Alternative for older builds
$path = "$env:TEMP\MDMDiag"
New-Item -ItemType Directory -Path $path -Force
MdmDiagnosticsTool.exe -out $path
```

</details>

<details><summary>Playbook 4 — Fix Duplicate Device Objects in AAD/Intune</summary>

Use when: Device appears twice in Intune, often after re-enrollment.

```powershell
# Find duplicate objects via Graph (requires DeviceManagementManagedDevices.Read.All)
$token = "<your bearer token>"
$headers = @{ Authorization = "Bearer $token" }
$name = "<DeviceName>"
$uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$name'"
$devices = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
$devices.value | Select-Object id, deviceName, enrolledDateTime, lastSyncDateTime, complianceState

# Identify the stale one (older enrolledDateTime, never synced)
# Delete stale managed device object:
$staleId = "<old-device-id>"
Invoke-RestMethod -Method Delete `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$staleId" `
    -Headers $headers
# Also delete from AAD Devices if a stale AAD object exists
```

**Rollback:** Deleting a managed device object is permanent. Confirm you're deleting the stale one.

</details>

---

## Evidence Pack

Run this on the affected device and attach the output ZIP to the escalation ticket:

```powershell
<#
.SYNOPSIS Collects Intune enrollment evidence for escalation
#>

$timestamp  = Get-Date -Format "yyyyMMdd_HHmm"
$outDir     = "$env:TEMP\IntuneEnrollmentEvidence_$timestamp"
$zipPath    = "$env:TEMP\IntuneEnrollmentEvidence_$timestamp.zip"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# 1. dsregcmd status
dsregcmd /status | Out-File "$outDir\dsregcmd_status.txt"

# 2. Enrollment registry
Get-Item "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
    Get-ItemProperty | Select-Object * |
    Out-File "$outDir\enrollment_registry.txt"

# 3. MDM Certificate
Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Issuer -like "*Microsoft*" -or $_.Issuer -like "*MDM*" } |
    Select-Object Subject, Issuer, NotAfter, Thumbprint |
    Out-File "$outDir\mdm_certs.txt"

# 4. Scheduled tasks
Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" |
    Select-Object TaskName, State, LastRunTime, LastTaskResult |
    Out-File "$outDir\scheduled_tasks.txt"

# 5. Event log (last 100 enrollment events)
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" `
    -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Level, Message |
    Export-Csv "$outDir\enrollment_events.csv" -NoTypeInformation

# 6. Network connectivity
$endpoints = @("manage.microsoft.com","dm.microsoft.com","login.microsoftonline.com","EnterpriseRegistration.windows.net")
$endpoints | ForEach-Object {
    $r = Test-NetConnection -ComputerName $_ -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint = $_; Reachable = $r.TcpTestSucceeded }
} | Export-Csv "$outDir\network_tests.csv" -NoTypeInformation

# 7. IME log (last 500 lines)
$imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $imeLog) { Get-Content $imeLog -Tail 500 | Out-File "$outDir\IME_last500.txt" }

# 8. Compress
Compress-Archive -Path "$outDir\*" -DestinationPath $zipPath -Force
Write-Host "Evidence ZIP: $zipPath" -ForegroundColor Green
Remove-Item $outDir -Recurse -Force
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check AAD join status | `dsregcmd /status` |
| Refresh PRT (user context) | `dsregcmd /refreshprt` |
| Trigger MDM sync (local) | `Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" \| Start-ScheduledTask` |
| Check enrollment registry | `Get-Item "HKLM:\SOFTWARE\Microsoft\Enrollments\*" \| Get-ItemProperty` |
| View MDM cert | `Get-ChildItem Cert:\LocalMachine\My \| Where-Object { $_.Issuer -like "*Intune*" }` |
| View enrollment events | `Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 20` |
| MDM diagnostic report | `mdmdiagnosticstool.exe -area DeviceEnrollment -zip C:\Temp\diag.zip` |
| Leave AAD (destructive) | `dsregcmd /leave` |
| DNS discovery check | `Resolve-DnsName EnterpriseRegistration.<domain>` |
| Test MDM endpoints | `Test-NetConnection manage.microsoft.com -Port 443` |
| Check IME logs | `Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 100` |
| View co-management status | `Get-WmiObject -Namespace root\ccm -ClassName SMS_Client` |

---

## 🎓 Learning Pointers

- **The MDM certificate is the device's identity.** When it expires (~1 year), the device silently loses management — no user-visible warning. Build a monitoring script that checks `NotAfter` across the fleet and alerts 60 days out. → [MS Docs: MDM enrollment certificate](https://docs.microsoft.com/en-us/windows/client-management/mdm/mdm-overview)

- **dsregcmd /status is your first tool, always.** The output tells you AAD join state, PRT health, and whether WPJ (Workplace Join) and MDM are both active. Understanding the difference between AAD Joined, Hybrid AAD Joined, and Workplace Joined saves hours of wrong-path debugging. → [MS Docs: dsregcmd](https://docs.microsoft.com/en-us/azure/active-directory/devices/troubleshoot-device-dsregcmd)

- **ESP timeouts are almost always Win32 app failures.** The Enrollment Status Page blocks OOBE until all tracked apps are installed. A single failed app holds the entire provisioning flow. IME logs at `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\` are the ground truth — not the Intune portal. → [MS Docs: ESP troubleshooting](https://docs.microsoft.com/en-us/troubleshoot/mem/intune/troubleshoot-esp)

- **OMA-DM sync frequency isn't instant.** The default check-in interval is 8 hours for Windows. If you're expecting a policy to apply immediately after assignment, it won't — trigger a manual sync or wait. → [MS Docs: MDM check-in intervals](https://docs.microsoft.com/en-us/windows/client-management/mdm/push-notification-windows-mdm)

- **Duplicate device objects are a real MSP pain.** When a device is re-enrolled without cleaning up the old managed device object, you end up with two records — one stale, one active. Policies may apply to the stale object. Always delete the old record from Intune **and** from AAD Devices when re-enrolling. → [MS Docs: Delete managed devices](https://docs.microsoft.com/en-us/mem/intune/remote-actions/devices-wipe)

- **Graph API is faster than the portal for fleet-scale work.** The Intune portal is great for one-offs, but for 50+ devices, use Graph queries with `$filter` and `$select`. The `deviceManagement/managedDevices` endpoint supports OData filtering — learn it and your triage time drops significantly. → [MS Graph: List managed devices](https://docs.microsoft.com/en-us/graph/api/intune-devices-manageddevice-list)
