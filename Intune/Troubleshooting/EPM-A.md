# Endpoint Privilege Management (EPM) — Reference Runbook (Mode A: Deep Dive)
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

| Item | Detail |
|------|--------|
| **License** | Microsoft Intune Suite add-on (or Intune Plan 2) — EPM is NOT included in standard Intune |
| **OS** | Windows 10 22H2+ / Windows 11 22H2+ |
| **Agent** | Intune Management Extension (IME) v3.4+ required |
| **Scope** | EPM policy creation, elevation rule authoring, client-side behavior, reporting, license validation |
| **Out of scope** | macOS privilege management, 3rd-party PAM tools (BeyondTrust, CyberArk) |
| **Assumed role** | L2/L3 MSP engineer, Intune admin access |

---

## How It Works

<details><summary>Full architecture — EPM components and elevation flow</summary>

### Overview

EPM allows **standard users to run specific applications with elevated (admin) privileges** without needing to be local admins. This replaces the traditional pattern of giving users local admin access just to install printers or run legacy apps.

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Intune (Portal)                          │
│  EPM Policies (elevation rules) → MDM channel → Device     │
│  EPM Reporting → tenant-level elevation audit log          │
└──────────────────────────┬──────────────────────────────────┘
                           │ MDM / Graph API
┌──────────────────────────▼──────────────────────────────────┐
│              Windows Device                                 │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Intune Management Extension (IME)                   │  │
│  │  - Receives EPM policies from Intune                 │  │
│  │  - Writes elevation rules to local policy store      │  │
│  │  - Reports elevation events back to Intune           │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                        │
│  ┌──────────────────▼───────────────────────────────────┐  │
│  │  Microsoft Endpoint Privilege Management Service     │  │
│  │  (ElevationService / EpmAgent)                       │  │
│  │  - Intercepts elevation requests (UAC bypass path)   │  │
│  │  - Matches against local policy rules                │  │
│  │  - Grants or denies elevation                        │  │
│  └──────────────────┬───────────────────────────────────┘  │
│                     │                                        │
│  ┌──────────────────▼───────────────────────────────────┐  │
│  │  Windows Token                                       │  │
│  │  Standard User Token → Elevated Token (if rule match)│  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Elevation Types

| Type | Description | User Experience |
|------|-------------|-----------------|
| **Automatic** | Elevation happens silently when app matches rule | No prompt — runs elevated without UAC |
| **User-confirmed** | User sees EPM prompt asking "Run with elevated access?" | One-click elevation |
| **Support-approved** | User submits request → admin approves in Intune portal | Ticketing-style workflow |

### Rule Matching Logic

EPM matches rules in this priority order:
1. **File hash** (most specific, most reliable)
2. **Certificate** (publisher-based — matches any version signed by that cert)
3. **Path + product name + publisher** (flexible but less specific)

First matching rule wins. If no rule matches: elevation is denied (if "Default elevation behavior" is set to "Deny") or falls through to Windows UAC (if set to "Not configured").

### License Flow

```
Microsoft Intune Suite add-on license (or Intune Plan 2)
  → Assigned to user (not device)
  → EPM feature unlocked in Intune portal
  → EPM policies can be created and assigned
  → IME on device validates license via Intune Graph
  → If license missing: EPM agent present but rules not enforced
```

</details>

---

## Dependency Stack

```
User attempts to run app requiring elevation
        │
        ▼
EPM Agent (ElevationService) intercepts UAC trigger
        │
        ▼
Rule evaluation — file hash / cert / path match
        │
        ▼
Policy store (written by IME from Intune)
        │
        ▼
Intune Management Extension (IME v3.4+)
        │
        ▼
MDM enrollment — Intune / AAD/Entra join
        │
        ▼
License: Intune Suite or Plan 2 assigned to user
        │
        ▼
Windows 10 22H2+ / Windows 11 22H2+
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| EPM option not visible in Intune portal | License not provisioned (Intune Suite add-on required) | M365 admin center → Licenses |
| EPM policy assigned but rules not applied on device | IME version too old (need 3.4+) or EPM agent not installed | IME version + ElevationService process |
| User gets standard UAC prompt instead of EPM prompt | Rule not matching — hash/cert/path mismatch | EPM client logs + rule details |
| App runs but still shows "standard user" | Elevation type misconfigured or rule matched wrong app | Check elevation type in rule |
| Support-approved elevation request not appearing in portal | Policy type not set to "User-confirmed/Support-approved" | Review rule elevation type |
| EPM reporting shows no data | Diagnostic log upload not enabled, or device not checking in | IME sync + EPM report policy |
| "Your organization does not allow elevation of this app" | Default behavior set to "Deny" and no rule matches | Check default elevation behavior setting |
| EPM agent installed but elevations fail silently | ElevationService stopped or crashed | `Get-Service ElevationService` |
| Elevation works in testing but fails for specific user | License not assigned to that user specifically | License check for that UPN |

---

## Validation Steps

### 1. Confirm License Provisioning

```powershell
# Check locally whether IME has validated EPM license
# IME logs license status during sync

# Review IME log for EPM license validation
$imeLogs = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Select-String -Path $imeLogs -Pattern "EPM|ElevationService|PrivilegeManagement|EndpointPrivilege" |
    Select-Object -Last 30 | ForEach-Object { $_.Line }
```

### 2. Check IME Version

```powershell
# EPM requires IME 3.4+
$ime = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension' -ErrorAction SilentlyContinue
$ime | Select-Object Version, AgentVersion

# Or check the executable
(Get-Item 'C:\Program Files (x86)\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe').VersionInfo.FileVersion
# Need: 3.4.x.x or higher
```

### 3. Confirm EPM Agent (ElevationService) Running

```powershell
# Check service status
Get-Service -Name 'ElevationService' -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType

# Good: Status = Running, StartType = Automatic
# Bad: Service missing = EPM agent not installed

# Check EPM agent process
Get-Process -Name 'EpmAgent', 'ElevationService' -ErrorAction SilentlyContinue
```

### 4. Check Policy Applied on Device

```powershell
# EPM rules are stored here after IME writes them
$epmPolicyPath = 'C:\ProgramData\Microsoft\EndpointPrivilegeManagement'
If (Test-Path $epmPolicyPath) {
    Get-ChildItem $epmPolicyPath -Recurse | Select-Object FullName, LastWriteTime
} Else {
    Write-Host "EPM policy store not found — rules have not been received" -ForegroundColor Yellow
}

# Check MDM policy registry
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LocalPoliciesSecurityOptions' -ErrorAction SilentlyContinue
```

### 5. Check EPM Elevation Rules (via IME logs)

```powershell
# Find rule match attempts in logs
$imeLogs = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Select-String -Path $imeLogs -Pattern "elevation|rule|hash|certificate|ElevationService" |
    Select-Object -Last 50 | ForEach-Object { $_.Line }
```

### 6. Validate Specific File Hash for Rule

```powershell
# Get file hash to match against EPM rule configuration
Param([string]$FilePath = 'C:\Program Files\ExampleApp\setup.exe')

$hash = Get-FileHash -Path $FilePath -Algorithm SHA256
Write-Host "File: $FilePath"
Write-Host "SHA256: $($hash.Hash)"

# Also get publisher/cert info
$cert = (Get-AuthenticodeSignature -FilePath $FilePath)
Write-Host "Publisher: $($cert.SignerCertificate.Subject)"
Write-Host "Thumbprint: $($cert.SignerCertificate.Thumbprint)"
Write-Host "Valid: $($cert.Status)"
```

### 7. Check EPM Elevation Events

```powershell
# Windows Event Log — EPM elevation events
Get-WinEvent -LogName 'Microsoft-Windows-EndpointPrivilegeManagement/Admin' -MaxEvents 50 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List

# Key event IDs:
# 1001 = Elevation granted (automatic)
# 1002 = Elevation granted (user-confirmed)
# 1003 = Elevation denied
# 1004 = Support-approved elevation requested
```

---

## Troubleshooting Steps (by phase)

### Phase 1: License and Portal Issues

1. In M365 admin center (admin.microsoft.com) → Billing → Licenses, confirm **Microsoft Intune Suite** or **Intune Plan 2** is purchased and has available seats
2. Confirm the license is assigned to the **user** (not just the device)
3. In Intune portal (intune.microsoft.com) → Endpoint Security → look for "Endpoint Privilege Management" — if absent, license not provisioned
4. License propagation to device can take 15-60 minutes after assignment

### Phase 2: Agent Not Installed or Not Running

1. Check IME version: must be 3.4.x.x+. Update via Windows Update or Intune remediation
2. EPM agent installs automatically when an EPM policy is assigned to the device + IME is at correct version
3. If `ElevationService` is missing: force IME sync, then wait for agent to download and install
4. Check IME log for download errors: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log`
5. If agent is installed but service won't start: check Windows Event Log → Application for service crash details

### Phase 3: Rule Not Matching

1. Verify the rule's **file hash** matches the exact binary on the target device
   - Hash mismatches happen when: app is updated, different architecture (x86 vs x64), or different installation path
2. If using certificate-based rules: verify the app is **signed** and the signing cert matches your rule's publisher
3. If using path-based rules: confirm path is exact (case-insensitive but must match exactly; `%ProgramFiles%` vs `%ProgramFiles(x86)%` matters)
4. In Intune portal → EPM → Reports → "Elevation report" — check if elevation attempts are logged and what denial reason is given
5. Create a **test rule with a broad certificate match** temporarily to confirm the agent is working, then tighten the rule

### Phase 4: Support-Approved Flow Not Working

1. Confirm the rule's elevation type is set to **"Support-approved"** (not Automatic or User-confirmed)
2. The user must use the **right-click → "Run with elevated access"** context menu to trigger the EPM request (not double-click)
3. Admin approves in Intune → EPM → Reports → "Elevation requests"
4. Device must be online to receive the approval — offline devices won't get the approval token
5. Approval tokens expire (default: 24 hours) — if device was offline when approved, user must re-request

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Force IME sync and EPM policy refresh</summary>

```powershell
# Force IME to re-sync and pull latest EPM policies
# Run as Administrator

# Restart IME service
Restart-Service -Name IntuneManagementExtension -Force
Start-Sleep -Seconds 10

# Trigger sync via scheduled task
$taskName = 'Microsoft\Windows\EnterpriseMgmt\*'
Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' |
    Where-Object { $_.TaskName -like '*schedule*' -or $_.TaskName -like '*sync*' } |
    Start-ScheduledTask -ErrorAction SilentlyContinue

Write-Host "IME restarted. Check logs in 2-3 minutes:" -ForegroundColor Cyan
Write-Host "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
```

</details>

<details>
<summary>Playbook 2 — Collect file hash and certificate for rule authoring</summary>

```powershell
# Run this against any file you want to create an EPM rule for
# Output is ready to copy into Intune EPM rule configuration

param(
    [Parameter(Mandatory)]
    [string]$FilePath
)

If (!(Test-Path $FilePath)) {
    Write-Host "File not found: $FilePath" -ForegroundColor Red
    Exit 1
}

$hash = Get-FileHash -Path $FilePath -Algorithm SHA256
$sig = Get-AuthenticodeSignature -FilePath $FilePath
$item = Get-Item $FilePath

Write-Host "`n=== EPM Rule Evidence ===" -ForegroundColor Cyan
Write-Host "File:          $($item.FullName)"
Write-Host "Product Name:  $($item.VersionInfo.ProductName)"
Write-Host "Description:   $($item.VersionInfo.FileDescription)"
Write-Host "Version:       $($item.VersionInfo.FileVersion)"
Write-Host "SHA256 Hash:   $($hash.Hash)"
Write-Host "`n--- For certificate-based rule ---"
If ($sig.Status -eq 'Valid') {
    Write-Host "Publisher:     $($sig.SignerCertificate.Subject)"
    Write-Host "Issuer:        $($sig.SignerCertificate.Issuer)"
    Write-Host "Thumbprint:    $($sig.SignerCertificate.Thumbprint)"
    Write-Host "Valid Until:   $($sig.SignerCertificate.NotAfter)"
} Else {
    Write-Host "Signature Status: $($sig.Status) — certificate rule not usable" -ForegroundColor Yellow
}
```

</details>

<details>
<summary>Playbook 3 — Audit all EPM elevation events on a device</summary>

```powershell
# Collect last 7 days of EPM elevation activity
# Run as Administrator

$cutoff = (Get-Date).AddDays(-7)
$events = @()

Try {
    $events = Get-WinEvent -LogName 'Microsoft-Windows-EndpointPrivilegeManagement/Admin' -ErrorAction Stop |
        Where-Object { $_.TimeCreated -gt $cutoff } |
        Select-Object TimeCreated, Id,
            @{N='Result';E={ Switch($_.Id){ 1001{'Granted-Auto'} 1002{'Granted-UserConfirmed'} 1003{'Denied'} 1004{'SupportRequested'} default{$_.Id} }}},
            Message
} Catch {
    Write-Host "EPM event log not found or empty" -ForegroundColor Yellow
}

$events | Format-Table -AutoSize

$outputPath = "C:\Temp\EPM-ElevationAudit-$(Get-Date -Format 'yyyyMMdd').csv"
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
$events | Export-Csv -Path $outputPath -NoTypeInformation
Write-Host "`nExported to: $outputPath" -ForegroundColor Cyan
```

</details>

---

## Evidence Pack

```powershell
# Run as Administrator — collects EPM evidence for escalation

$lines = @()
$lines += "=== EPM EVIDENCE PACK ==="
$lines += "Date: $(Get-Date)"
$lines += "Computer: $env:COMPUTERNAME"
$lines += ""

# IME version
$lines += "--- IME Version ---"
Try {
    $imeVer = (Get-Item 'C:\Program Files (x86)\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe').VersionInfo.FileVersion
    $lines += "IME Version: $imeVer"
} Catch { $lines += "IME not found at expected path" }

# ElevationService
$lines += "`n--- EPM Service ---"
$svc = Get-Service ElevationService -ErrorAction SilentlyContinue
$lines += "ElevationService: $(If($svc){ $svc.Status } Else { 'NOT FOUND' })"

# EPM policy store
$lines += "`n--- EPM Policy Store ---"
$epmPath = 'C:\ProgramData\Microsoft\EndpointPrivilegeManagement'
If (Test-Path $epmPath) {
    $files = Get-ChildItem $epmPath -Recurse | Select-Object FullName, LastWriteTime
    $files | ForEach-Object { $lines += "$($_.LastWriteTime) — $($_.FullName)" }
} Else {
    $lines += "EPM policy store not found"
}

# Recent IME log lines for EPM
$lines += "`n--- IME Log (EPM-related, last 50 matches) ---"
$logPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
If (Test-Path $logPath) {
    Select-String -Path $logPath -Pattern "EPM|Elevation|ElevationService|PrivilegeManagement" |
        Select-Object -Last 50 | ForEach-Object { $lines += $_.Line }
}

# EPM events
$lines += "`n--- EPM Events (last 20) ---"
Try {
    Get-WinEvent -LogName 'Microsoft-Windows-EndpointPrivilegeManagement/Admin' -MaxEvents 20 -ErrorAction Stop |
        ForEach-Object { $lines += "$($_.TimeCreated) [ID $($_.Id)]: $($_.Message.Substring(0,[Math]::Min(300,$_.Message.Length)))" }
} Catch { $lines += "No EPM event log or no events" }

$out = "C:\Temp\EPM-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
New-Item -Path C:\Temp -ItemType Directory -Force | Out-Null
$lines | Out-File $out -Encoding UTF8
Write-Host "Evidence saved: $out" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check ElevationService | `Get-Service ElevationService` |
| Check IME version | `(Get-Item 'C:\Program Files (x86)\Microsoft Intune Management Extension\*.exe').VersionInfo.FileVersion` |
| Check EPM policy store | `Get-ChildItem 'C:\ProgramData\Microsoft\EndpointPrivilegeManagement' -Recurse` |
| Get file hash for rule | `Get-FileHash -Path <file> -Algorithm SHA256` |
| Get publisher/cert info | `Get-AuthenticodeSignature -FilePath <file>` |
| Check EPM events | `Get-WinEvent -LogName 'Microsoft-Windows-EndpointPrivilegeManagement/Admin' -MaxEvents 50` |
| Search IME log for EPM | `Select-String -Path 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log' -Pattern 'EPM\|Elevation'` |
| Restart IME | `Restart-Service IntuneManagementExtension` |
| Restart ElevationService | `Restart-Service ElevationService` |
| Check MDM enrollment | `dsregcmd /status` |
| Force Intune sync | `Start-Process ms-settings:workplace` |

---

## 🎓 Learning Pointers

- **License gotcha — user, not device**: EPM license (part of Intune Suite or Plan 2) must be assigned to the **user**, not just the device. If a user logs into a device and no EPM license is on their account, EPM rules won't enforce — even if the device has an EPM policy assigned. Always verify license at the user level before troubleshooting the agent. See: [EPM licensing requirements](https://learn.microsoft.com/en-us/mem/intune/protect/epm-overview#prerequisites)

- **File hash rules break on app updates**: Hash-based rules are the most precise but break whenever the app is updated (new hash). For frequently-updated apps (Chrome, Zoom, Acrobat), use **certificate-based rules** (publisher match) instead. Hash rules are best for internal or version-locked LOB apps.

- **EPM vs. local admin — this is not a permission assignment tool**: EPM elevates specific processes, not users. A user under EPM is still a standard user for everything else. This is the correct model for least-privilege — don't confuse "EPM assigned" with "user has admin rights."

- **Default elevation behavior matters at scale**: In the EPM policy, "Default elevation behavior" controls what happens when no rule matches. Set to "Deny all requests" for a strict environment (block any unmapped elevation), or "Not configured" to fall through to Windows UAC. Most MSPs set Deny and build out rules deliberately.

- **Support-approved flow for break-glass scenarios**: The support-approved elevation type creates a ticketing workflow inside Intune — ideal for software that's too risky to auto-elevate but occasionally needed. The elevation token is time-limited (configurable, default 24h) and logged in Intune's EPM report. See: [EPM support-approved elevations](https://learn.microsoft.com/en-us/mem/intune/protect/epm-support-approved)

- **EPM reporting is your audit trail**: Intune → Endpoint Security → Endpoint Privilege Management → Reports → "Elevation report" shows every elevation event (granted, denied, requested) across all managed devices. Use this for security reviews and to identify apps that need rules but don't have them yet.
