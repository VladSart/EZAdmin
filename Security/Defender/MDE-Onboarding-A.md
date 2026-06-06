# Microsoft Defender for Endpoint Onboarding — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- MDE onboarding via Microsoft Intune (Windows 10/11, Windows Server 2019/2022)
- MDE onboarding via local script (pilot/testing)
- MDE onboarding via GPO (hybrid/on-prem joined)
- MDE onboarding via Microsoft Defender for Cloud (servers)
- Sensor health validation, SENSE service troubleshooting
- License validation and workspace binding
- Offboarding and re-onboarding procedures

**Does not cover:**
- macOS/Linux MDE onboarding (see macOS runbook)
- MDE features (EDR, ASR, threat hunting) — see respective runbooks
- Third-party security product conflicts (handled per-vendor)

**Assumptions:**
- Defender Antivirus is present (not replaced by a third-party AV in active mode)
- Device is Entra ID joined or Hybrid Joined (cloud-based onboarding)
- Admin has Microsoft 365 Defender portal access (security.microsoft.com)
- License: Microsoft Defender for Endpoint P1 or P2 (or Microsoft 365 E5, Business Premium, Defender for Business)

---
## How It Works

<details><summary>Full architecture — MDE onboarding end-to-end</summary>

**The SENSE service is the core.**

MDE's Windows sensor is the `SENSE` service (`Windows Defender Advanced Threat Protection Service`). This service:
1. Collects security signals from the kernel, ETW providers, and Defender AV
2. Authenticates to MDE cloud using a machine certificate or onboarding blob
3. Streams telemetry to MDE cloud infrastructure
4. Receives response actions (isolation, live response, etc.) from the portal

**Onboarding methods and how they provision the SENSE service:**

```
Method 1: Intune (preferred for cloud-native)
  Intune policy → IME delivers onboarding blob → Written to registry
  HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status
  SENSE service reads blob → Authenticates to MDE cloud

Method 2: Local onboarding script (WindowsDefenderATPOnboardingScript.cmd)
  Script runs → Writes onboarding config to registry
  Starts SENSE service → SENSE authenticates to MDE cloud

Method 3: GPO (on-prem/hybrid)
  GPO delivers .onboarding file → Written to C:\ProgramData\Microsoft\Windows Defender\
  SENSE reads config → Authenticates to MDE cloud

Method 4: Defender for Cloud (servers)
  Azure Arc agent + Defender for Cloud extension → Provisions SENSE config
```

**What happens during first onboarding:**
1. Onboarding blob/config is written to the device
2. `SENSE` service starts (or restarts if already running)
3. SENSE authenticates using the onboarding blob (contains tenant ID + workspace key)
4. First heartbeat sent to MDE cloud (can take up to **1 hour** to appear in portal)
5. Device shows as "Onboarded" in portal → initial scan begins
6. EDR telemetry streaming starts; alerts can appear within minutes of onboarding

**Cloud endpoints SENSE communicates with:**
- `*.oms.opinsights.azure.com` — workspace telemetry
- `*.blob.core.windows.net` — package downloads
- `*.securitycenter.windows.com` — MDE cloud backend
- `winatp-gw-*.microsoft.com` — regional gateway (varies by tenant geo)
- `ctldl.windowsupdate.com` — certificate revocation

**Certificate-based authentication (newer onboarding):**
Modern MDE onboarding uses Azure AD device identity (device certificate) for authentication — no static onboarding blob secret. The SENSE service uses the device's Entra ID TPM-backed certificate for mutual TLS.

</details>

---
## Dependency Stack

```
Microsoft 365 Defender Portal (security.microsoft.com)
  └── MDE License active on tenant (P1/P2, E5, Business Premium, Defender for Business)
        └── Onboarding package generated for correct OS platform
              └── Device meets OS prerequisites (Win10 1709+ for full EDR; 1507+ basic)
                    └── Entra ID Join or Hybrid Join (for cloud-native onboarding)
                    │     └── Device in correct Intune assignment group (for Intune method)
                    │           └── Intune delivers MDE config profile
                    │                 └── IME writes onboarding config to registry
                    └── Network: Device can reach MDE cloud endpoints (443/HTTPS)
                          └── SENSE service installed (built into Windows 10 1709+)
                                └── SENSE service running and healthy
                                      └── Windows Defender AV not disabled/replaced
                                            └── Device appears in MDE portal (up to 1 hour)
                                                  └── Heartbeat maintained (every 5 min)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Device not in MDE portal after 24h | Onboarding config not delivered; SENSE not running | Registry blob, SENSE service state |
| SENSE service won't start | Missing onboarding blob; service corrupted; AV conflict | Event Log 1000/7031, registry |
| Device shows "Inactive" in portal | SENSE can't reach cloud endpoints | Network connectivity to MDE URLs |
| Device shows "Misconfigured" | Tamper protection preventing config; duplicate onboarding | Portal device page, registry |
| Onboarding via Intune not applying | IME not running; policy not assigned; wrong platform profile | IME logs, Intune portal |
| "Device already onboarded to another workspace" | Stale onboarding config from previous MDE tenant | Registry cleanup required |
| SENSE starts but no alerts | Tamper protection conflict; passive mode active; AV integration issue | Defender status, passive mode reg key |
| GPO onboarding not working | GPO not applying; wrong .onboarding file for OS version | gpresult, event log |
| Server onboarding failing | Missing MMA workspace config; Defender for Cloud extension issue | Azure Arc status, extension logs |

---
## Validation Steps

**Step 1 — Verify SENSE service state**
```powershell
Get-Service -Name Sense | Select-Object Name, Status, StartType
```
Expected: `Running`, `Automatic`.  
Bad: `Stopped` or `Disabled` → investigate start failure.

**Step 2 — Verify onboarding blob exists in registry**
```powershell
$mdePath = "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"
if (Test-Path $mdePath) {
    Get-ItemProperty $mdePath | Select-Object OnboardingState, OrgId, SenseIsRunning
} else {
    Write-Warning "MDE registry key not found — device likely not onboarded"
}
```
Expected: `OnboardingState = 1`, `SenseIsRunning = 1`.  
Bad: Key missing or `OnboardingState = 0` → onboarding blob was never written.

**Step 3 — Verify SENSE can reach cloud endpoints**
```powershell
$mdeEndpoints = @(
    "winatp-gw-eus.microsoft.com",
    "winatp-gw-neu.microsoft.com",
    "us-v20.events.data.microsoft.com",
    "eu-v20.events.data.microsoft.com",
    "settings-win.data.microsoft.com"
)
foreach ($ep in $mdeEndpoints) {
    $r = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint = $ep; Reachable = $r.TcpTestSucceeded }
}
```
Expected: All `True`.  
Bad: Any `False` → network/proxy blocking MDE telemetry.

**Step 4 — Check Windows Defender AV integration**
```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled, `
    TamperProtectionSource, IsTamperProtected
```
Expected: `AMRunningMode = Normal`, `AntivirusEnabled = True`, `RealTimeProtectionEnabled = True`.  
Bad: `AMRunningMode = Passive` on workstation without a reason; `AntivirusEnabled = False` → third-party AV taking over.

**Step 5 — Check MDE event log for errors**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-SENSE/Operational" -MaxEvents 30 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-Table -Wrap
```
Key event IDs:
- **5** — SENSE service started successfully
- **6** — SENSE service stopped
- **15** — Onboarding completed
- **19** — Onboarding failed
- **25** — SENSE can't communicate with service
- **84** — Windows Defender AV health check

**Step 6 — Confirm device appears in portal**
Portal: security.microsoft.com → Assets → Devices  
Filter: Device name or serial number  
Expected: Device listed, status `Active`, last seen < 1 hour ago.

---
## Troubleshooting Steps (by phase)

### Phase 1: Onboarding Config Delivery

**For Intune onboarding:**
1. Intune portal → Endpoint Security → Endpoint Detection & Response → verify policy exists and is assigned
2. On device: check IME is running (`Get-Service IntuneManagementExtension`)
3. On device: check IME logs at `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\`
4. Look for "WindowsDefenderATP" or "MDE" entries in `AgentExecutor.log`

**For GPO onboarding:**
1. `gpresult /h C:\Temp\gpresult.html` — verify MDE policy is applied
2. Check `C:\ProgramData\Microsoft\Windows Defender Advanced Threat Protection\` for onboarding file
3. Check registry: `HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection`

**For local script:**
1. Run script as Administrator
2. Check exit code: `echo %errorlevel%` — 0 = success
3. Check `$env:TEMP\MDATPClientAnalyzer.log` for errors

### Phase 2: SENSE Service

1. Attempt to start: `Start-Service Sense`
2. If fails, check event log: `Get-WinEvent -LogName "Microsoft-Windows-SENSE/Operational" -MaxEvents 20`
3. If Event ID 19 (onboarding failed) — registry blob is invalid or expired
4. Check for AV conflicts: `Get-MpComputerStatus | Select AMRunningMode`
5. Run MDE Client Analyzer (MDEClientAnalyzer.exe) from Microsoft Download Center

### Phase 3: Network / Cloud Connectivity

1. Run MDE URL test tool or manual Test-NetConnection
2. If behind proxy: check `netsh winhttp show proxy`
3. Set proxy for SENSE if needed:
```powershell
# Set WinHTTP proxy (SENSE uses WinHTTP, not IE proxy settings)
netsh winhttp set proxy proxy-server="http=<proxyServer>:<port>" bypass-list="<bypass>"
```
4. Check TLS inspection — TLS 1.2+ required; deep inspection can break SENSE auth
5. Verify certificate trust (SENSE uses certificate pinning for some endpoints)

### Phase 4: License & Tenant

1. Portal: Settings → Endpoints → Onboarding — download correct onboarding package for OS
2. Portal: Settings → License — verify Defender for Endpoint license active
3. If tenant recently migrated or has multiple tenants: device may be bound to wrong workspace

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full SENSE service reset and re-onboarding</summary>

Use when SENSE is broken and you want to cleanly re-onboard.

```powershell
# Step 1: Stop SENSE service
Stop-Service Sense -Force -ErrorAction SilentlyContinue

# Step 2: Offboard device (use offboarding script from portal)
# Portal: Settings → Endpoints → Offboarding → download offboarding package for OS
# Run offboarding script as Administrator
# Wait 5 minutes

# Step 3: Clear onboarding registry
Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection" -Recurse -Force -ErrorAction SilentlyContinue

# Step 4: Clear cached onboarding data
$mdePaths = @(
    "$env:ProgramData\Microsoft\Windows Defender Advanced Threat Protection",
    "$env:ProgramData\Microsoft\Windows Defender\Definition Updates\StoreUpdateLog"
)
foreach ($path in $mdePaths) {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Cleared: $path"
    }
}

# Step 5: Re-run onboarding script (downloaded from portal)
# Run as Administrator
# C:\Temp\WindowsDefenderATPOnboardingScript.cmd

# Step 6: Start SENSE
Start-Service Sense
Start-Sleep -Seconds 30
Get-Service Sense | Select-Object Status

# Step 7: Verify
$mdePath = "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"
Get-ItemProperty $mdePath | Select-Object OnboardingState, SenseIsRunning
```

**Rollback:** Re-run onboarding script to restore onboarded state.  
⚠️ Device will be removed from portal during offboard. Historical data is retained for 6 months.

</details>

<details><summary>Playbook 2 — Fix "Device already onboarded to another workspace"</summary>

This occurs when a device was onboarded to a different MDE tenant (e.g., MSP managing multiple clients).

```powershell
# Step 1: Identify current OrgId
$status = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -ErrorAction SilentlyContinue
Write-Host "Current OrgId: $($status.OrgId)"

# Step 2: Stop SENSE
Stop-Service Sense -Force

# Step 3: Clear all MDE registry entries
$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection"
)
foreach ($regPath in $registryPaths) {
    if (Test-Path $regPath) {
        Remove-Item $regPath -Recurse -Force
        Write-Host "Removed: $regPath"
    }
}

# Step 4: Clear configuration files
$configPath = "$env:ProgramData\Microsoft\Windows Defender Advanced Threat Protection"
if (Test-Path $configPath) {
    Get-ChildItem $configPath -Recurse -File | Remove-Item -Force
}

# Step 5: Re-onboard using NEW tenant's onboarding script
# Download from correct tenant's portal: Settings → Endpoints → Onboarding
# Run: WindowsDefenderATPOnboardingScript.cmd

# Step 6: Restart SENSE and verify
Start-Service Sense
Start-Sleep -Seconds 60
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" |
    Select-Object OnboardingState, OrgId, SenseIsRunning
```

**Rollback:** Re-run original tenant's onboarding script.

</details>

<details><summary>Playbook 3 — Fix Intune MDE policy not applying</summary>

```powershell
# Step 1: Verify IME is running
Get-Service IntuneManagementExtension | Select-Object Status

# Step 2: Force IME sync
Restart-Service IntuneManagementExtension -Force
Start-Sleep -Seconds 60

# Step 3: Check Intune logs for MDE policy processing
$imeLog = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Get-Content $imeLog | Select-String "ATP|ATPOnboarding|DefenderATP|WindowsDefender" |
    Select-Object -Last 30

# Step 4: Check if Endpoint Detection & Response profile exists in Intune
# Portal: Endpoint Security → Endpoint Detection & Response
# Profile must be assigned to device or user group

# Step 5: Check for policy conflicts
# Portal: Devices → [Device] → Device configuration → each profile status
# Look for "Error" or "Conflict" on any security profile

# Step 6: Verify correct platform is selected in Intune policy
# Windows 10 and later vs. Windows 10 and later (ConfigMgr) — wrong platform = no delivery
```

**If IME delivers the policy but SENSE still doesn't start:** see Playbook 1.

</details>

<details><summary>Playbook 4 — Windows Server onboarding (Defender for Cloud method)</summary>

```powershell
# Step 1: Verify Azure Arc connectivity (required for Defender for Cloud method)
Get-Service himds -ErrorAction SilentlyContinue | Select-Object Status
# himds = Hybrid Instance Metadata Service (Azure Arc agent)

# Step 2: Check Defender for Cloud extension
Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*Microsoft Defender*" }
# Or check via Azure portal: Arc machine → Extensions

# Step 3: For direct onboarding on Server 2019/2022 (SENSE is built in):
# Download server-specific onboarding script from portal
# Settings → Endpoints → Onboarding → Windows Server 2019 and 2022

# Step 4: For Server 2012 R2/2016 (requires MDE unified agent):
# Download: https://aka.ms/MDE-Unified-Agent
# Install the modern unified agent first, THEN run onboarding script

# Step 5: Verify SENSE on server
sc.exe query sense  # Check service exists
sc.exe start sense  # Start if stopped

# Step 6: Test cloud connectivity from server
Invoke-WebRequest -Uri "https://winatp-gw-eus.microsoft.com" -UseBasicParsing |
    Select-Object StatusCode
```

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect MDE onboarding diagnostic evidence for escalation
.NOTES     Run as Administrator
#>

$reportPath = "C:\Temp\MDE-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# System info
[PSCustomObject]@{
    ComputerName  = $env:COMPUTERNAME
    OS            = (Get-WmiObject Win32_OperatingSystem).Caption
    BuildNumber   = (Get-WmiObject Win32_OperatingSystem).BuildNumber
    CollectedAt   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
} | ConvertTo-Json | Out-File "$reportPath\00-SystemInfo.json"

# SENSE service
Get-Service Sense -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType |
    ConvertTo-Json | Out-File "$reportPath\01-SenseService.json"

# MDE registry status
$mdePath = "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"
if (Test-Path $mdePath) {
    Get-ItemProperty $mdePath | ConvertTo-Json | Out-File "$reportPath\02-MDERegistry.json"
} else {
    "MDE registry key not found" | Out-File "$reportPath\02-MDERegistry.txt"
}

# Defender AV status
Get-MpComputerStatus -ErrorAction SilentlyContinue |
    Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled,
        IsTamperProtected, TamperProtectionSource, AMProductVersion |
    ConvertTo-Json | Out-File "$reportPath\03-DefenderStatus.json"

# SENSE event log (last 50 events)
Get-WinEvent -LogName "Microsoft-Windows-SENSE/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    ConvertTo-Json | Out-File "$reportPath\04-SenseEvents.json"

# Network connectivity test
$endpoints = @(
    "winatp-gw-eus.microsoft.com",
    "winatp-gw-neu.microsoft.com",
    "us-v20.events.data.microsoft.com",
    "eu-v20.events.data.microsoft.com",
    "settings-win.data.microsoft.com",
    "ctldl.windowsupdate.com"
)
$netResults = foreach ($ep in $endpoints) {
    $r = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint = $ep; Reachable = $r.TcpTestSucceeded; PingSucceeded = $r.PingSucceeded }
}
$netResults | ConvertTo-Json | Out-File "$reportPath\05-NetworkConnectivity.json"

# WinHTTP proxy
$proxyOutput = netsh winhttp show proxy 2>&1
$proxyOutput | Out-File "$reportPath\06-WinHttpProxy.txt"

# IME log snippet (if available)
$imeLog = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $imeLog) {
    Get-Content $imeLog | Select-String "ATP|Defender|SENSE" | Select-Object -Last 50 |
        Out-File "$reportPath\07-IMELog-MDERelevant.txt"
}

# Package everything
$zipPath = "C:\Temp\MDE-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').zip"
Compress-Archive -Path $reportPath -DestinationPath $zipPath -Force

Write-Host "Evidence collected: $zipPath" -ForegroundColor Green
Write-Host "Attach to escalation ticket." -ForegroundColor Cyan
```

---
## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check SENSE service | `Get-Service Sense \| Select Name, Status, StartType` |
| Start SENSE | `Start-Service Sense` |
| Check onboarding state | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"` |
| Check AV mode | `Get-MpComputerStatus \| Select AMRunningMode, AntivirusEnabled` |
| SENSE event log | `Get-WinEvent -LogName "Microsoft-Windows-SENSE/Operational" -MaxEvents 20` |
| Test MDE endpoint | `Test-NetConnection winatp-gw-eus.microsoft.com -Port 443` |
| Show WinHTTP proxy | `netsh winhttp show proxy` |
| Set WinHTTP proxy | `netsh winhttp set proxy proxy-server="http=<proxy>:<port>"` |
| Check IME service | `Get-Service IntuneManagementExtension \| Select Status` |
| Force IME sync | `Restart-Service IntuneManagementExtension -Force` |
| Check passive mode | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender" -Name ForceDefenderPassiveMode` |
| Check Tamper Protection | `Get-MpComputerStatus \| Select IsTamperProtected, TamperProtectionSource` |
| SENSE service query (cmd) | `sc.exe query sense` |
| Check OrgId | `(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status").OrgId` |
| Offboard check | `(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status").OnboardingState` |

---
## 🎓 Learning Pointers

- **The SENSE service is not the same as Windows Defender Antivirus.** Defender AV (`WinDefend`) handles malware scanning. SENSE is the EDR telemetry sensor — they work together but can fail independently. A device can have Defender AV healthy but SENSE broken (and vice versa).
- **First appearance in portal takes up to 1 hour** — do not panic if the device doesn't appear immediately. SENSE needs to establish first communication. After first heartbeat, subsequent updates appear within minutes.
- **WinHTTP ≠ IE/WinINet proxy settings.** SENSE uses WinHTTP for outbound connections. If your org uses a proxy that's configured through IE/GPO (WinINet), SENSE won't use it automatically — you must set it via `netsh winhttp set proxy` or via Intune device proxy settings. [Proxy configuration for MDE](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/configure-proxy-internet).
- **Passive mode vs. active mode matters for onboarding.** On devices with a non-Microsoft AV as primary, Defender runs in passive mode. SENSE still works in passive mode for EDR telemetry, but real-time protection features are reduced. On servers joining an MDE tenant where Defender isn't the primary AV, this is often intentional.
- **MDE Client Analyzer is your best diagnostic tool** for complex issues. Download `MDEClientAnalyzer.zip` from the Microsoft Download Center, run `MDEClientAnalyzer.exe` as Administrator, and it produces a comprehensive HTML report covering every dependency. [MDEClientAnalyzer docs](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/overview-client-analyzer).
- **Server onboarding has a split path.** Windows Server 2019/2022 has SENSE built in (same as Windows 10/11 flow). Server 2012 R2 and 2016 require the **MDE Unified Agent** — a separate installer (`md4ws.msi`) that replaces the older MMA-based workspace approach. [Onboard Windows servers](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/configure-server-endpoints).
