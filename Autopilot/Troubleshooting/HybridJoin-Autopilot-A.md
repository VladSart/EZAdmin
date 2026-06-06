# Hybrid Azure AD Join via Autopilot — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers **Windows Autopilot with Hybrid Azure AD Join (HAADJ)** — the deployment scenario where a device is simultaneously joined to on-premises Active Directory and registered in Entra ID (Azure AD). This is the most complex Autopilot scenario and the one most prone to failure.

**Scope:**
- Device fails to complete HAADJ during Autopilot ESP (Enrollment Status Page)
- Device completes Autopilot but shows `AzureAdJoined: NO` or `DomainJoined: NO`
- Intune ODJ (Offline Domain Join) connector failures
- Entra Connect (AAD Connect) sync not surfacing device object
- Domain join completes on-premises but device never registers with Entra ID

**Assumes:**
- Intune subscription with Autopilot licence (Intune P1 or M365 Business Premium+)
- On-premises AD with Entra Connect (Azure AD Connect) in place
- Intune Connector for Active Directory (ODJ Connector) installed on a domain-joined server
- Device within corporate network or connected via VPN with line-of-sight to DC

---

## How It Works

<details><summary>Full HAADJ Autopilot architecture</summary>

### The Critical Difference: HAADJ vs. Azure AD Join

| | Azure AD Join (AADJ) | Hybrid Azure AD Join (HAADJ) |
|--|--|--|
| Domain | Entra ID only | Both on-prem AD + Entra ID |
| Mechanism | Direct AAD join in OOBE | ODJ blob + Entra Connect sync |
| Network req | Internet only | Must reach DC during ESP |
| Complexity | Low | High |
| Autopilot support | Native | Requires ODJ Connector |

### HAADJ Autopilot Flow (step by step)

```
1. Device boots → detects Autopilot profile (downloaded from MEM)
2. OOBE begins → user/device auth to Windows Autopilot Deployment Service (WADS)
3. Intune receives enrollment request
4. Intune calls ODJ Connector: "generate a domain join blob for this device"
   └── ODJ Connector contacts on-prem DC
   └── Creates computer account in AD (in configured OU)
   └── Generates encrypted ODJ blob
   └── Returns blob to Intune
5. Intune delivers ODJ blob to device via MDM channel
6. Device processes ODJ blob → joins on-prem domain (offline, cached credentials)
7. Device restarts
8. Enrollment Status Page (ESP) continues
9. After restart: device authenticates to AD domain
10. Entra Connect syncs the new computer object from AD → Entra ID
    └── Sync interval: default 30 minutes (can be faster with delta sync)
11. Device receives Hybrid Azure AD Join ticket (PRT) once synced
12. ESP: "Device Setup" and "Account Setup" phases complete
13. Autopilot complete → desktop appears
```

### Where It Goes Wrong

The HAADJ flow has **three distinct failure domains**:
- **Domain:** ODJ Connector → DC communication (ports, permissions, OU)
- **Sync:** Entra Connect sync latency or filtering rules
- **Device:** Device not reaching DC during/after restart, PRT not obtained

The ODJ blob is **time-sensitive.** It is generated at the time of enrollment request. If the device doesn't process it within ~7 days, it expires. More practically, if the device isn't on-network when it restarts to complete domain join, the blob will fail to process.

### ODJ Connector Requirements

The ODJ Connector server must:
- Be domain-joined
- Have HTTPS outbound to `*.manage.microsoft.com` and `*.microsoftonline.com`
- Run as a service account with "Create Computer Objects" permission in the target OU
- Have **no** HTTP proxy interrupting the HTTPS connection (or proxy explicitly excluded)

</details>

---

## Dependency Stack

```
Autopilot HAADJ Success
        │
        ├── Windows Autopilot Deployment Service (WADS)
        │     └── Device hardware hash registered in Autopilot
        │     └── Autopilot profile assigned (HAADJ type)
        │
        ├── Intune ODJ Connector (on-prem server)
        │     ├── Service running: "Microsoft Intune ODJ Connector Service"
        │     ├── Connectivity: server → *.manage.microsoft.com (HTTPS/443)
        │     ├── AD permissions: create computer objects in target OU
        │     └── Connector certificate (auto-renewed, must be valid)
        │
        ├── On-premises Active Directory
        │     ├── DC reachable from ODJ Connector server
        │     ├── OU path exists and is correct in Intune HAADJ profile
        │     └── Computer object created successfully
        │
        ├── Entra Connect (Azure AD Connect)
        │     ├── Sync running (delta every 30 min by default)
        │     ├── Computer objects not filtered by OU/attribute
        │     ├── Device writeback enabled (for compliant device CA)
        │     └── No sync errors for the computer object
        │
        ├── Device network (during ESP)
        │     ├── Line-of-sight to DC (for domain join processing)
        │     ├── DNS resolving internal domain
        │     └── If VPN: pre-logon VPN or device tunnel must be active
        │
        └── Entra ID device registration
              ├── Computer object synced to Entra ID
              └── Device PRT obtained (dsregcmd /status → AzureAdJoined: YES)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-----------------|-------|
| ESP stuck at "Identifying" | Autopilot profile not assigned / hash not registered | Intune → Devices → Windows enrollment → Devices |
| ESP stuck at "Securing your hardware" | TPM attestation timeout | TPM in BIOS enabled; network to Attestation Service |
| ESP stuck at "Joining your org's network" | ODJ blob generation failed | ODJ Connector logs on connector server |
| Domain join fails (event 4097/4098) | ODJ Connector can't reach DC | Connectivity from connector server to DC on LDAP/Kerberos |
| Device joins AD but `AzureAdJoined: NO` | Entra Connect not syncing device | `Start-ADSyncSyncCycle -PolicyType Delta` |
| `AzureAdJoined: YES` but `DeviceCompliant: NO` | Compliance policy not yet evaluated | Wait 8h or trigger sync; check Intune enrollment status |
| `DomainJoined: YES`, `AzureAdJoined: NO` after days | Hybrid join task never ran | Check `dsregcmd /debug` for AAD task scheduler errors |
| ESP times out after restart | Device not reaching DC in allowed timeframe | VPN/network pre-logon; increase ESP timeout |
| Connector shows "Not connected" in Intune | Certificate expired or service stopped | Restart service; check cert expiry in connector portal |
| Duplicate computer objects in AD | Retry created second object | Clean stale objects; check OU; check naming conflict |

---

## Validation Steps

### Step 1 — Verify ODJ Connector health

```powershell
# Run on the ODJ Connector server
# Check service status
Get-Service "Microsoft Intune ODJ Connector Service" | Select-Object Status, StartType

# Check connector log (last 50 lines)
Get-Content "C:\ProgramData\Microsoft\Windows\Intune ODJ Connector\Logs\ODJConnectorService.log" -Tail 50

# Check connector certificate expiry
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*ODJConnector*" -or $_.Subject -like "*Intune*" } |
    Select-Object Subject, NotAfter, Thumbprint
```

**Good:** Service running, no errors in log, certificate valid for > 30 days
**Bad:** `ODJConnectorService` stopped; log shows `HTTP 403` or `No DC found`; certificate expired

---

### Step 2 — Check computer object in AD

```powershell
# Run on a DC or machine with AD module
Import-Module ActiveDirectory

$deviceName = "<ComputerName>"
$device = Get-ADComputer -Filter "Name -eq '$deviceName'" -Properties *
if ($device) {
    Write-Host "Found in AD: $($device.DistinguishedName)" -ForegroundColor Green
    $device | Select-Object Name, DistinguishedName, Created, Enabled, OperatingSystem
} else {
    Write-Host "NOT found in AD" -ForegroundColor Red
}
```

**Good:** Computer object exists in the expected OU, `Enabled: True`
**Bad:** Not found → ODJ step failed; found in wrong OU → check HAADJ profile OU setting

---

### Step 3 — Verify Entra Connect has synced the device

```powershell
# Check if device exists in Entra ID via Graph
Connect-MgGraph -Scopes "Device.Read.All"

$deviceName = "<ComputerName>"
Get-MgDevice -Filter "displayName eq '$deviceName'" |
    Select-Object DisplayName, Id, OperatingSystem, TrustType,
        @{n="IsCompliant";e={$_.AdditionalProperties['isCompliant']}},
        @{n="IsManaged";e={$_.AdditionalProperties['isManaged']}},
        @{n="ApproximateLastSignIn";e={$_.ApproximateLastSignInDateTime}}
```

**Good:** Device exists with `TrustType: ServerAd` (= HAADJ), `IsManaged: True`
**Bad:** Device not found → Entra Connect hasn't synced yet; `TrustType: AzureAd` → device is AADJ not HAADJ

---

### Step 4 — Force Entra Connect delta sync

```powershell
# Run on the Entra Connect server
Import-Module ADSync

# Check last sync time
Get-ADSyncScheduler | Select-Object NextSyncCyclePolicyType, LastSyncCycleResult, NextSyncCycleStartTime

# Trigger delta sync immediately
Start-ADSyncSyncCycle -PolicyType Delta
Write-Host "Delta sync started. Check again in 2-3 minutes." -ForegroundColor Cyan

# Check for sync errors
Get-ADSyncConnectorRunStatus
```

**Good:** Last sync was recent, `LastSyncCycleResult: Success`, no connector errors
**Bad:** Sync errors showing — check specific connector (AD or AAD) for error details

---

### Step 5 — Check device state post-Autopilot

```powershell
# Run on the affected device (as any user, or SYSTEM)
dsregcmd /status

# Key fields:
# DomainJoined      : YES  ← on-prem AD join succeeded
# AzureAdJoined     : YES  ← Entra ID registration succeeded (HAADJ complete)
# DomainName        : <your-domain.local>
# WorkplaceJoined   : NO   ← should be NO for domain-joined devices

# If AzureAdJoined is NO but DomainJoined is YES, trigger the scheduled task:
dsregcmd /debug
# Look for: "Performing AAD join" — if not present, task hasn't run
```

**Good:** Both `DomainJoined: YES` and `AzureAdJoined: YES`
**Bad:** `AzureAdJoined: NO` — see Phase 3 troubleshooting

---

## Troubleshooting Steps (by phase)

### Phase 1 — Pre-provisioning / ODJ Connector

1. On the ODJ Connector server, open Event Viewer → Applications and Services Logs → Microsoft → Windows → AAD
2. Look for Event ID 4097 (ODJ blob request) or 4098 (failure)
3. Check `C:\ProgramData\Microsoft\Windows\Intune ODJ Connector\Logs\ODJConnectorService.log`
4. Verify the service account has `Create Computer Objects` in the OU specified in the Intune HAADJ profile
5. Test DC connectivity from connector server: `Test-NetConnection -ComputerName <DC> -Port 389`

### Phase 2 — Domain Join Processing (device side)

1. On device, check: `C:\Windows\Panther\UnattendGC\setupact.log` for domain join errors
2. Event Viewer → System → look for Netlogon errors (event 5719) indicating DC unreachable
3. Verify DNS: `nslookup <domain.local>` must return internal DNS results
4. If behind corporate firewall/proxy, ensure device can reach DC on ports 88 (Kerberos), 389 (LDAP), 445 (SMB)
5. If using VPN: pre-logon VPN (device tunnel) must be established before ODJ blob is processed

### Phase 3 — Entra ID Registration (post domain join)

1. Check if device object exists in Entra ID: `Get-MgDevice -Filter "displayName eq '<name>'"`
2. If not found: force Entra Connect delta sync (Step 4)
3. If found but `TrustType` is wrong: device was AADJ'd, not HAADJ'd — re-provision
4. On device: `dsregcmd /refreshprt` to force Entra ID PRT acquisition after sync
5. Check for scheduled task: Task Scheduler → `\Microsoft\Windows\Workplace Join\Automatic-Device-Join`

### Phase 4 — Post-enrollment compliance

1. After `AzureAdJoined: YES` confirmed, allow 15-30 min for Intune compliance evaluation
2. Check Intune → Devices → [Device] → Device compliance — should show compliant
3. If compliance check fails immediately: ensure compliance policy targets the correct group
4. Force policy sync: `Start-Process "$env:ProgramFiles\Microsoft Intune Management Extension\agentexecutor.exe" -Args '-SyncDeviceConfig'`

---

## Remediation Playbooks

<details><summary>Fix 1 — Restart ODJ Connector and re-trigger enrollment</summary>

```powershell
# Run on ODJ Connector server
Restart-Service "Microsoft Intune ODJ Connector Service" -Force
Start-Sleep -Seconds 10
Get-Service "Microsoft Intune ODJ Connector Service" | Select-Object Status

# Verify it re-registered with Intune
Get-Content "C:\ProgramData\Microsoft\Windows\Intune ODJ Connector\Logs\ODJConnectorService.log" -Tail 20
# Look for: "Successfully registered connector" or "Heartbeat successful"
```

**Then:** In Intune, delete the pending device enrollment and retry Autopilot (wipe + re-provision, or use the Reset option).

**Rollback:** N/A — restarting service is non-destructive.

</details>

<details><summary>Fix 2 — Grant ODJ Connector service account correct AD permissions</summary>

```powershell
# Run on a DC with AD DS Tools installed
Import-Module ActiveDirectory

$serviceAccountSAM = "<OdjConnectorServiceAccount>"
$targetOU           = "OU=Autopilot-Devices,DC=contoso,DC=local"

# Grant "Create Computer Objects" on the target OU
$acl = Get-Acl -Path "AD:\$targetOU"
$identity = [System.Security.Principal.NTAccount]"<DOMAIN>\$serviceAccountSAM"
$adRight   = [System.DirectoryServices.ActiveDirectoryRights]"CreateChild,DeleteChild"
$type      = [System.Security.AccessControl.AccessControlType]"Allow"
$inheritanceType = [System.DirectoryServices.ActiveDirectorySecurityInheritance]"All"
$schemaId  = [Guid]"bf967a86-0de6-11d0-a285-00aa003049e2" # Computer objects schema GUID

$ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $identity, $adRight, $type, $schemaId, $inheritanceType)
$acl.AddAccessRule($ace)
Set-Acl -Path "AD:\$targetOU" -AclObject $acl

Write-Host "Permissions granted. Test a new enrollment." -ForegroundColor Green
```

**Rollback:** Remove the ACE using `$acl.RemoveAccessRule($ace)` + `Set-Acl`.

</details>

<details><summary>Fix 3 — Force Entra Connect sync for a specific computer object</summary>

```powershell
# Run on Entra Connect server
Import-Module ADSync

# Option A: Delta sync (syncs all changes since last run)
Start-ADSyncSyncCycle -PolicyType Delta

# Option B: Full sync (re-evaluates all objects — slower, use sparingly)
# Start-ADSyncSyncCycle -PolicyType Initial

# Monitor sync completion
$timeout = 300 # 5 minutes
$elapsed = 0
do {
    Start-Sleep 10
    $elapsed += 10
    $status = Get-ADSyncConnectorRunStatus
    Write-Host "[$elapsed s] Sync status: $($status.RunState)"
} while ($status.RunState -ne "Idle" -and $elapsed -lt $timeout)

Write-Host "Sync complete. Check device in Entra ID portal." -ForegroundColor Green
```

</details>

<details><summary>Fix 4 — Manually trigger Hybrid Join registration on device</summary>

```powershell
# Run on the device (requires domain membership already complete)
# Option A: Trigger scheduled task
$task = Get-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -TaskName "Automatic-Device-Join" -ErrorAction SilentlyContinue
if ($task) {
    Start-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -TaskName "Automatic-Device-Join"
    Write-Host "Task triggered. Wait 2-3 minutes then run dsregcmd /status" -ForegroundColor Cyan
} else {
    Write-Host "Task not found — device may need to be re-provisioned" -ForegroundColor Red
}

# Option B: Force PRT refresh (after device is already in Entra ID)
dsregcmd /refreshprt
```

</details>

<details><summary>Fix 5 — Re-provision a device that completed AADJ instead of HAADJ</summary>

A device enrolled as Azure AD Join (cloud-only) instead of Hybrid Azure AD Join cannot be converted in-place. It must be re-provisioned.

```powershell
# Step 1 — Verify the device is AADJ (not HAADJ)
# dsregcmd /status → AzureAdJoined: YES, DomainJoined: NO = AADJ only

# Step 2 — In Intune: Devices → [Device] → Wipe
# Ensure "Wipe device, but keep enrollment state and associated user account" is UNCHECKED

# Step 3 — Delete device from Entra ID to prevent stale object
Connect-MgGraph -Scopes "Device.ReadWrite.All"
$deviceId = "<EntraDeviceObjectId>"
Remove-MgDevice -DeviceId $deviceId

# Step 4 — Delete device from AD if a stale computer object exists
Remove-ADComputer -Identity "<ComputerName>" -Confirm:$false

# Step 5 — Re-provision: device will go through Autopilot HAADJ flow again
# Ensure: HAADJ Autopilot profile is assigned, ODJ Connector is healthy
```

**⚠️ Wipe is destructive. Confirm device is not the only device for that user.**

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect HAADJ Autopilot diagnostic evidence
.NOTES     Run on the ODJ Connector server AND on the affected device separately
#>

# ========== Run on ODJ CONNECTOR SERVER ==========
param(
    [string]$ComputerName = "",
    [string]$OutputDir    = "$env:TEMP\HAADJ-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
)

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# ODJ Connector service status
Get-Service "Microsoft Intune ODJ Connector Service" |
    Select-Object Name, Status, StartType |
    Export-Csv "$OutputDir\ODJConnector-Service.csv" -NoTypeInformation

# ODJ Connector logs (last 200 lines)
$logPath = "C:\ProgramData\Microsoft\Windows\Intune ODJ Connector\Logs\ODJConnectorService.log"
if (Test-Path $logPath) {
    Get-Content $logPath -Tail 200 | Out-File "$OutputDir\ODJConnector-Log.txt"
}

# Connector certificate
Get-ChildItem Cert:\LocalMachine\My |
    Select-Object Subject, NotBefore, NotAfter, Thumbprint, HasPrivateKey |
    Export-Csv "$OutputDir\ConnectorCerts.csv" -NoTypeInformation

# Entra Connect sync status (if on same server)
try {
    Import-Module ADSync -ErrorAction Stop
    Get-ADSyncScheduler | Export-Csv "$OutputDir\SyncScheduler.csv" -NoTypeInformation
    Get-ADSyncConnectorRunStatus | Export-Csv "$OutputDir\SyncConnectorStatus.csv" -NoTypeInformation
} catch { Write-Host "ADSync module not found on this server (normal if ODJ Connector is separate)" }

# DC connectivity from connector
if ($ComputerName -ne "") {
    Get-ADComputer -Filter "Name -eq '$ComputerName'" -Properties * 2>$null |
        Select-Object Name, DistinguishedName, Created, Enabled |
        Export-Csv "$OutputDir\ADComputerObject.csv" -NoTypeInformation
}

# ========== Run on AFFECTED DEVICE ==========
# dsregcmd /status
dsregcmd /status | Out-File "$OutputDir\dsregcmd-status.txt"
dsregcmd /debug  | Out-File "$OutputDir\dsregcmd-debug.txt"

# Device event logs
Get-WinEvent -LogName "Microsoft-Windows-AAD/Operational" -MaxEvents 50 2>$null |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$OutputDir\AAD-EventLog.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputDir" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check ODJ Connector service | `Get-Service "Microsoft Intune ODJ Connector Service"` |
| View ODJ Connector logs | `Get-Content "C:\ProgramData\...\ODJConnectorService.log" -Tail 50` |
| Check computer in AD | `Get-ADComputer -Filter "Name -eq '<name>'" -Properties *` |
| Check device in Entra ID | `Get-MgDevice -Filter "displayName eq '<name>'"` |
| Force Entra Connect delta sync | `Start-ADSyncSyncCycle -PolicyType Delta` (on AAD Connect server) |
| Check sync schedule | `Get-ADSyncScheduler` |
| Check device registration state | `dsregcmd /status` (on device) |
| Force Hybrid Join task | `Start-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -TaskName "Automatic-Device-Join"` |
| Force PRT refresh | `dsregcmd /refreshprt` |
| Test DC connectivity | `Test-NetConnection -ComputerName <DC> -Port 389` |
| Force Intune sync | `Start-Process "agentexecutor.exe" -Args '-SyncDeviceConfig'` |
| Check Netlogon errors | `Get-WinEvent -LogName System \| Where-Object {$_.Id -eq 5719}` |

---

## 🎓 Learning Pointers

- **HAADJ Autopilot requires line-of-sight to a DC during the ESP.** The ODJ blob is processed at first boot after domain join, and Kerberos authentication requires reaching a DC. If the device is on a guest network or untrusted Wi-Fi without VPN, the domain join will silently fail. Always pre-provision on corporate network or use device tunnel VPN. See: [HAADJ Autopilot requirements](https://learn.microsoft.com/en-us/autopilot/windows-autopilot-hybrid)

- **The ODJ blob has a 30-day validity window** but practically the device must process it before the next restart timeout. Unenrolled devices left on shelf after Autopilot provisioning starts can expire their ODJ blob. Check blob timestamps in ODJ Connector logs if getting "expired credential" errors. See: [ODJ Connector troubleshooting](https://learn.microsoft.com/en-us/mem/intune/enrollment/windows-autopilot-hybrid#troubleshoot-intune-connector-issues)

- **Entra Connect sync latency is 30 minutes by default.** After the computer object is created in AD, it won't appear in Entra ID until the next delta sync cycle. For production deployments, consider setting sync interval to 5 minutes during provisioning windows: `Set-ADSyncScheduler -CustomizedSyncCycleInterval 00:05:00`. See: [Entra Connect scheduler](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-sync-feature-scheduler)

- **Duplicate computer accounts are a common re-provisioning issue.** If a device was previously enrolled, its AD computer object may exist in a different OU. The ODJ Connector will attempt to create a new one and may fail on duplicate naming. Always clean up stale AD and Entra ID objects before re-provisioning. See: [Autopilot re-deployment](https://learn.microsoft.com/en-us/autopilot/troubleshoot-oobe)

- **ESP timeout default is 60 minutes.** HAADJ Autopilot can take 30-45 minutes in good conditions due to sync latency. Increase ESP timeout to 90-120 minutes for HAADJ deployments to prevent false failures: Intune → Devices → Windows → Enrollment → Enrollment Status Page → Edit timeout. See: [ESP configuration](https://learn.microsoft.com/en-us/autopilot/enrollment-status)

- **Consider moving to AADJ if on-prem dependency can be removed.** HAADJ exists primarily for legacy on-prem app and GPO dependency. Modern deployments using only Intune policies, Microsoft 365, and cloud-based resources are better served by pure AADJ, which is faster, simpler, and doesn't require ODJ Connector. See: [AADJ vs HAADJ decision guide](https://learn.microsoft.com/en-us/entra/identity/devices/plan-device-deployment)
