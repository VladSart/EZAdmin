# VBS & Credential Guard — Reference Runbook (Mode A: Deep Dive)
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
| **OS** | Windows 10 21H2+ / Windows 11 / Server 2016+ |
| **Hardware** | TPM 2.0, UEFI Secure Boot capable, 64-bit SLAT CPU (Intel VT-x/EPT or AMD-V/RVI) |
| **Scope** | VBS enablement, Credential Guard (LSASS isolation), HVCI (Memory Integrity), UEFI lock scenarios, Intune policy conflicts |
| **Out of scope** | Hyper-V VM configuration, Application Guard, WDAG |
| **Assumed role** | L2/L3 engineer with local or remote admin access |

---

## How It Works

<details><summary>Full architecture — VBS, Credential Guard, and HVCI</summary>

### Virtualization-Based Security (VBS)

VBS uses the hypervisor (Hyper-V type-1) to create a **Secure Kernel** (VSM — Virtual Secure Mode) that runs in a separate, isolated memory region from the normal OS kernel. The normal Windows kernel runs in **VTL 0** (Virtual Trust Level 0); the Secure Kernel runs in **VTL 1**.

```
┌──────────────────────────────────────────────────────────┐
│                      Hardware                            │
│  CPU (VT-x/AMD-V + SLAT)  |  TPM 2.0  |  UEFI Secure   │
│                            |           │  Boot           │
└────────────────────┬───────────────────┴────────────────┘
                     │
┌────────────────────▼───────────────────────────────────┐
│                   Hypervisor (Hyper-V)                 │
│  - Type-1, loaded before Windows kernel                │
│  - Enforces memory isolation between VTLs              │
└──────────────┬──────────────────────┬──────────────────┘
               │                      │
    ┌──────────▼──────┐    ┌──────────▼──────────┐
    │   VTL 0 (Normal │    │  VTL 1 (Secure Mode)│
    │   Windows OS)   │    │  Secure Kernel       │
    │                 │    │                      │
    │  Kernel         │    │  Credential Guard    │
    │  Drivers        │    │  (isolated LSASS)    │
    │  LSASS stub     │    │                      │
    └─────────────────┘    └──────────────────────┘
```

### Credential Guard
Credential Guard isolates **NTLM hashes, Kerberos TGTs, and derived credentials** in the VTL 1 Secure Kernel via the **LsaIso.exe** process. Even if an attacker compromises VTL 0 (the normal OS), they cannot extract credentials from VTL 1.

Without Credential Guard:
- `lsass.exe` holds secrets in VTL 0 memory → mimikatz/Pass-the-Hash works

With Credential Guard:
- `lsass.exe` stub in VTL 0 communicates with `lsaiso.exe` in VTL 1
- Secrets never touch VTL 0 memory
- Pass-the-Hash and Pass-the-Ticket are blocked

### HVCI (Hypervisor-Protected Code Integrity / Memory Integrity)
HVCI uses VTL 1 to enforce Kernel Mode Code Integrity (KMCI). The Secure Kernel validates every kernel driver before it's allowed to execute. Unsigned or tampered drivers are blocked even if they get into memory — the hypervisor won't execute them.

### UEFI Lock
When enabled with UEFI lock, VBS settings are written to UEFI firmware variables and **cannot be disabled via Windows software** — a full UEFI reset (drain UEFI variables on the device) is required. This is intentional for preventing admin-level rootkits from disabling VBS.

</details>

---

## Dependency Stack

```
Application (e.g., credential use, code execution)
        │
        ▼
Windows OS (VTL 0) — lsass.exe stub, kernel, drivers
        │
        ▼
Hypervisor (Hyper-V) — loaded by UEFI before Windows
        │  ┌──────────────────────────────┐
        │  │  VTL 1 — Secure Kernel       │
        │  │  lsaiso.exe (Cred Guard)     │
        │  │  KMCI enforcement (HVCI)     │
        │  └──────────────────────────────┘
        ▼
UEFI Secure Boot (validates hypervisor signature)
        │
        ▼
TPM 2.0 (seals VBS state, PCR measurements)
        │
        ▼
CPU: 64-bit, SLAT (Intel EPT / AMD RVI), VT-x or AMD-V
```

**Every layer must be present and healthy.** A failure at any level cascades upward.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| VBS shows "Not enabled" in `msinfo32` despite policy | SLAT/VT-x disabled in BIOS/UEFI | `Get-WmiObject -Class Win32_ComputerSystem` + BIOS check |
| `lsaiso.exe` not running in Task Manager | Credential Guard not active (policy not applied, or DG not enabled) | `Get-MPComputerStatus` + registry check |
| Device Guard policy conflict in Intune | HVCI conflicts with a 3rd-party driver | Event Log: Microsoft-Windows-CodeIntegrity/Operational |
| BSOD on boot after enabling VBS | Incompatible driver blocked by HVCI | Boot to Safe Mode, check CodeIntegrity event log |
| Cannot disable VBS after enabling | UEFI lock applied | Must clear UEFI variables — hardware procedure |
| RDP "Network Level Auth" fails after Credential Guard | Expected: CG blocks NTLMv1 delegation | Enforce NTLMv2 / Kerberos on RDP target |
| Some apps fail after Credential Guard | App using NTLM in a way blocked by CG | Check Security event log for NTLM failures |
| "Credential Guard is configured but the secure process could not be started" | `lsaiso.exe` failed to launch; typically driver incompatibility | CodeIntegrity + System event logs |
| VBS enabled but `VirtualizationBasedSecurity` registry shows 0 | Hyper-V role conflict on Server SKU | Check if Hyper-V role enabled on server |

---

## Validation Steps

### 1. Confirm Hardware Prerequisites

```powershell
# Check SLAT support
(Get-WmiObject -Class Win32_Processor).SecondLevelAddressTranslationExtensions
# Expected: True

# Check Hyper-V support
(Get-WmiObject -Class Win32_ComputerSystem).HypervisorPresent
# Expected: True (after VBS enabled)

# Check Secure Boot
Confirm-SecureBootUEFI
# Expected: True (no error)

# Check TPM
Get-Tpm
# Good: TpmPresent=True, TpmReady=True, TpmEnabled=True, ManufacturerId present

# Check TPM version (must be 2.0 for full Credential Guard support)
(Get-Tpm).ManufacturerVersionFull20
```

### 2. Check VBS Status

```powershell
# The gold standard for VBS status
msinfo32  # GUI — look for "Virtualization-based security" section

# PowerShell equivalent
Get-WmiObject -Namespace root\Microsoft\Windows\DeviceGuard -Class Win32_DeviceGuard |
    Select-Object VirtualizationBasedSecurityStatus, AvailableSecurityProperties,
                  SecurityServicesConfigured, SecurityServicesRunning |
    Format-List

# Status codes:
# VirtualizationBasedSecurityStatus: 0=Off, 1=Configured but not running, 2=Running
# SecurityServicesRunning values: 1=Credential Guard, 2=HVCI, 4=UEFI Lock
```

**Good output (fully running):**
```
VirtualizationBasedSecurityStatus : 2
SecurityServicesConfigured        : {1, 2}
SecurityServicesRunning           : {1, 2}
```

**Bad output (configured but not running):**
```
VirtualizationBasedSecurityStatus : 1
SecurityServicesConfigured        : {1, 2}
SecurityServicesRunning           : {}
```

### 3. Confirm Credential Guard Active

```powershell
# Check lsaiso.exe is running
Get-Process -Name lsaiso -ErrorAction SilentlyContinue
# Good: Returns process. Bad: No output = Credential Guard not active

# Check LSA protection mode
(Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Lsa).RunAsPPL
# 0 = not protected, 1 = protected light, 2 = protected (for Cred Guard: must also have lsaiso running)
```

### 4. Check HVCI (Memory Integrity) Status

```powershell
# Registry check
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity').Enabled
# 1 = enabled

# Or check via DeviceGuard WMI (SecurityServicesRunning: 2 = HVCI running)
```

### 5. Verify Intune Policy is Applying

```powershell
# Check MDM policy channel
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceGuard' |
    Get-ItemProperty | Select-Object PSChildName, EnableVirtualizationBasedSecurity,
    RequirePlatformSecurityFeatures, HypervisorEnforcedCodeIntegrity

# MDM bridge — effective policy
Get-ChildItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' -ErrorAction SilentlyContinue |
    Get-ItemProperty
```

### 6. Check for Driver Compatibility Issues

```powershell
# CodeIntegrity events — look for blocked drivers
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 50 |
    Where-Object { $_.Id -in @(3001, 3002, 3003, 3010, 3023) } |
    Select-Object TimeCreated, Id, Message | Format-List

# Event 3001 = driver blocked (signature issue)
# Event 3002 = driver blocked (HVCI incompatible)
# Event 3023 = warning (driver will be blocked after reboot)
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Policy Not Reaching Device

1. Confirm device is Entra-joined or Hybrid-joined and MDM-enrolled
2. Run `dsregcmd /status` — check `MDMUrl` and `IsDeviceMDMEnrolled`
3. Force Intune sync: `Start-Process ms-settings:workplace`
4. Check registry path: `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceGuard`
5. If path is empty, policy has not reached device — check Intune assignment scope

### Phase 2: Policy Applied but VBS Not Running

1. Confirm hardware prerequisites (Step 1 above)
2. Check BIOS/UEFI for Virtualization Technology (VT-x/AMD-V) — must be **enabled**
3. Check if device has been rebooted since policy applied (VBS requires reboot to activate)
4. On Hyper-V host machines: VBS is not supported inside a VM unless the VM has Hyper-V exposed (nested virtualization)
5. Check for conflicting Group Policy: `gpresult /h c:\gpreport.html` — look for DeviceGuard settings

### Phase 3: HVCI Blocking Drivers (BSOD or Driver Failure)

1. Boot to **Safe Mode** (F8 or `bcdedit /set safeboot minimal`)
2. Check CodeIntegrity operational log for blocked driver names
3. Update or remove the incompatible driver
4. If driver is a required 3rd party (AV, VPN, DLP), check vendor for HVCI-compatible version
5. Re-enable HVCI and reboot to test

### Phase 4: Cannot Disable VBS (UEFI Lock)

1. Confirm UEFI lock is set: `SecurityServicesRunning` includes `4` (UEFI lock active)
2. Software methods to disable will fail — this is by design
3. Must clear UEFI variables on the device (typically via BIOS reset or manufacturer tool)
4. **Caution**: This process varies by OEM. For Surface: use SEMM/UEFI Configurator. For HP: HP BIOS Config Utility. For Dell: Dell Command Configure.
5. After UEFI variables cleared, policy can be reapplied without lock

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Enable VBS + Credential Guard via Registry (non-Intune)</summary>

```powershell
# WARNING: Requires reboot. Creates UEFI-locked config by default.
# Run as Administrator

# Enable VBS
$dvPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
If (!(Test-Path $dvPath)) { New-Item -Path $dvPath -Force }
Set-ItemProperty -Path $dvPath -Name 'EnableVirtualizationBasedSecurity' -Value 1 -Type DWord
Set-ItemProperty -Path $dvPath -Name 'RequirePlatformSecurityFeatures' -Value 1 -Type DWord
# 1 = Secure Boot only; 3 = Secure Boot + DMA Protection (preferred on capable hardware)

# Enable Credential Guard (with UEFI lock)
Set-ItemProperty -Path $dvPath -Name 'LsaCfgFlags' -Value 1 -Type DWord
# 0 = Disabled, 1 = Enabled with UEFI lock, 2 = Enabled without lock

# Enable HVCI
$hvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
If (!(Test-Path $hvciPath)) { New-Item -Path $hvciPath -Force }
Set-ItemProperty -Path $hvciPath -Name 'Enabled' -Value 1 -Type DWord

Write-Host "VBS/CG configured. Reboot required." -ForegroundColor Yellow

# Rollback (if UEFI lock NOT set):
# Set-ItemProperty -Path $dvPath -Name 'EnableVirtualizationBasedSecurity' -Value 0
# Set-ItemProperty -Path $dvPath -Name 'LsaCfgFlags' -Value 0
# Set-ItemProperty -Path $hvciPath -Name 'Enabled' -Value 0
# Reboot
```

**Rollback note:** If UEFI lock was applied (LsaCfgFlags = 1), software rollback will NOT work. Must clear UEFI variables via OEM tool.

</details>

<details>
<summary>Playbook 2 — Disable HVCI to fix driver BSOD (Safe Mode)</summary>

```powershell
# Run from Safe Mode as Administrator
# This disables HVCI only — leaves Credential Guard intact

$hvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
Set-ItemProperty -Path $hvciPath -Name 'Enabled' -Value 0 -Type DWord
Set-ItemProperty -Path $hvciPath -Name 'WasEnabledBy' -Value 0 -Type DWord -ErrorAction SilentlyContinue

# Exit safe mode
bcdedit /deletevalue safeboot

Write-Host "HVCI disabled. Reboot into normal mode and update the problematic driver." -ForegroundColor Yellow
```

</details>

<details>
<summary>Playbook 3 — Identify HVCI-incompatible drivers before enabling</summary>

```powershell
# Run Device Guard Readiness Tool or check locally:
# Download: https://aka.ms/dgreadiness

# Quick local check — look for WHQL-failing drivers
$drivers = Get-WindowsDriver -Online -All | Where-Object { $_.DriverSignature -ne 'Signed' }
$drivers | Select-Object Driver, OriginalFileName, DriverSignature, BootCritical

# Check 3rd party kernel drivers
Get-WmiObject Win32_SystemDriver |
    Where-Object { $_.PathName -notlike '*\Windows\*' } |
    Select-Object Name, PathName, State, StartMode |
    Sort-Object PathName
```

</details>

<details>
<summary>Playbook 4 — Validate Credential Guard blocks Pass-the-Hash</summary>

```powershell
# Confirm lsaiso.exe is running
$lsaiso = Get-Process lsaiso -ErrorAction SilentlyContinue
If ($lsaiso) {
    Write-Host "[OK] lsaiso.exe running (PID: $($lsaiso.Id)) — Credential Guard active" -ForegroundColor Green
} Else {
    Write-Host "[WARN] lsaiso.exe NOT running — Credential Guard not active" -ForegroundColor Yellow
}

# Check if NTLM is being blocked as expected
# Look for Event 4624 with LogonType=3 (network) and AuthenticationPackage=NTLM
# If CG is active, these should be Kerberos, not NTLM, for domain resources
Get-WinEvent -LogName Security -MaxEvents 200 |
    Where-Object { $_.Id -eq 4624 } |
    ForEach-Object {
        $xml = [xml]$_.ToXml()
        $logonType = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'LogonType' }).'#text'
        $authPkg = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'AuthenticationPackageName' }).'#text'
        If ($logonType -eq '3' -and $authPkg -eq 'NTLM') {
            [PSCustomObject]@{ Time = $_.TimeCreated; LogonType = $logonType; Auth = $authPkg }
        }
    } | Select-Object -First 20
```

</details>

---

## Evidence Pack

```powershell
# Run as Administrator — collects all VBS/CG evidence for escalation ticket

$report = @()
$report += "=== VBS/CREDENTIAL GUARD EVIDENCE PACK ==="
$report += "Date: $(Get-Date)"
$report += "Computer: $env:COMPUTERNAME"
$report += ""

# Device Guard WMI
$report += "--- Device Guard WMI Status ---"
$dg = Get-WmiObject -Namespace root\Microsoft\Windows\DeviceGuard -Class Win32_DeviceGuard
$report += "VBS Status: $($dg.VirtualizationBasedSecurityStatus) (0=Off,1=Configured,2=Running)"
$report += "Services Configured: $($dg.SecurityServicesConfigured -join ',')"
$report += "Services Running: $($dg.SecurityServicesRunning -join ',')"
$report += "Available Properties: $($dg.AvailableSecurityProperties -join ',')"
$report += ""

# Hardware
$report += "--- Hardware ---"
$cpu = Get-WmiObject Win32_Processor | Select-Object -First 1
$report += "CPU: $($cpu.Name)"
$report += "SLAT Support: $($cpu.SecondLevelAddressTranslationExtensions)"
Try { $report += "Secure Boot: $(Confirm-SecureBootUEFI)" } Catch { $report += "Secure Boot: Error checking" }
$tpm = Get-Tpm
$report += "TPM Present: $($tpm.TpmPresent), Ready: $($tpm.TpmReady), Enabled: $($tpm.TpmEnabled)"
$report += ""

# Registry
$report += "--- Registry ---"
$dvReg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -ErrorAction SilentlyContinue
$report += "EnableVBS: $($dvReg.EnableVirtualizationBasedSecurity)"
$report += "RequirePlatformSecurity: $($dvReg.RequirePlatformSecurityFeatures)"
$report += "LsaCfgFlags: $($dvReg.LsaCfgFlags)"
$hvciReg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction SilentlyContinue
$report += "HVCI Enabled: $($hvciReg.Enabled)"
$report += ""

# lsaiso
$report += "--- Credential Guard Process ---"
$lsaiso = Get-Process lsaiso -ErrorAction SilentlyContinue
$report += "lsaiso.exe running: $($null -ne $lsaiso)"
$report += ""

# CodeIntegrity events
$report += "--- Recent CodeIntegrity Events ---"
Try {
    Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 20 -ErrorAction Stop |
        Where-Object { $_.Id -in @(3001,3002,3003,3010,3023) } |
        ForEach-Object { $report += "Event $($_.Id) at $($_.TimeCreated): $($_.Message.Substring(0,[Math]::Min(200,$_.Message.Length)))" }
} Catch { $report += "No CodeIntegrity events found or log empty" }

$outputPath = "C:\Temp\VBS-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
$report | Out-File -FilePath $outputPath -Encoding UTF8
Write-Host "Evidence saved to: $outputPath" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check VBS status (WMI) | `Get-WmiObject -Namespace root\Microsoft\Windows\DeviceGuard -Class Win32_DeviceGuard \| Select VirtualizationBasedSecurityStatus,SecurityServicesRunning` |
| Check lsaiso (Cred Guard active?) | `Get-Process lsaiso -ErrorAction SilentlyContinue` |
| Check Secure Boot | `Confirm-SecureBootUEFI` |
| Check TPM | `Get-Tpm` |
| Check SLAT | `(Get-WmiObject Win32_Processor).SecondLevelAddressTranslationExtensions` |
| CodeIntegrity events (HVCI blocks) | `Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 50` |
| Check HVCI registry | `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'` |
| Check DeviceGuard registry | `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'` |
| Check Intune DeviceGuard policy | `Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceGuard' \| Get-ItemProperty` |
| List 3rd-party kernel drivers | `Get-WmiObject Win32_SystemDriver \| Where-Object { $_.PathName -notlike '*\Windows\*' }` |
| Boot to Safe Mode | `bcdedit /set safeboot minimal` |
| Remove Safe Mode flag | `bcdedit /deletevalue safeboot` |
| Enable VBS (no UEFI lock) | `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name LsaCfgFlags -Value 2` |
| Force Intune sync | `Start-Service IntuneManagementExtension; Invoke-Command { & "$env:ProgramFiles\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe" }` |

---

## 🎓 Learning Pointers

- **Why UEFI lock matters**: VBS with UEFI lock (LsaCfgFlags=1) writes to UEFI firmware variables, making VBS settings tamper-proof against admin-level attackers. This is the correct MSP deployment choice for high-security clients — but understand that removing it requires physical/OEM tooling. See: [Credential Guard deployment guide](https://learn.microsoft.com/en-us/windows/security/identity-protection/credential-guard/configure)

- **HVCI driver compatibility is the #1 real-world pain point**: Many legacy and 3rd-party drivers (older AV, VPN clients, DLP agents) are not HVCI-compatible. Run the [Device Guard and Credential Guard hardware readiness tool](https://aka.ms/dgreadiness) **before** enforcing HVCI at scale. Event IDs 3001/3002 in the CodeIntegrity/Operational log are your friends.

- **Credential Guard does NOT protect everything**: CG protects domain credentials (Kerberos TGTs, NTLM hashes) from memory dump attacks. It does NOT protect cached credentials on disk, passwords in clear text in config files, or credentials typed into a compromised browser. Pair CG with Microsoft Defender Credential Theft protection and Controlled Folder Access.

- **VBS vs. VBS + HVCI**: You can run Credential Guard (VBS) without HVCI, but HVCI without VBS is not possible — HVCI *requires* VBS as its foundation. Intune's "Memory Integrity" toggle maps directly to HVCI.

- **Server 2016+ supports Credential Guard**: Credential Guard works on Windows Server with Desktop Experience. It is NOT supported in Server Core. On Hyper-V hosts, enabling Credential Guard impacts VM performance slightly — benchmark before rollout on high-density hosts.

- **Intune "Device Guard" profile location**: Security > Endpoint Security > Account Protection > Windows Defender Credential Guard. The older Device Compliance > Device Security path still exists but Microsoft recommends the Endpoint Security profile path for new deployments. See: [Intune Credential Guard settings](https://learn.microsoft.com/en-us/mem/intune/protect/endpoint-protection-windows-10#windows-defender-credential-guard)
