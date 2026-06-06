# VBS & Credential Guard — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these immediately to understand what's enabled and what's blocking:

```powershell
# 1 — VBS / Credential Guard state
Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard |
    Select-Object VirtualizationBasedSecurityStatus,
                  CredentialGuardRunning,
                  SecurityServicesRunning,
                  SecurityServicesConfigured

# 2 — Hyper-V / VT-x presence
Get-ComputerInfo -Property HyperVisorPresent, HyperVRequirementVirtualizationFirmwareEnabled,
                             HyperVRequirementVMMonitorModeExtensions

# 3 — HVCI (Memory Integrity) state
reg query "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled 2>$null

# 4 — LSA PPL / Credential Isolation mode
reg query "HKLM\SYSTEM\CurrentControlSet\Control\LSA" /v LsaCfgFlags
reg query "HKLM\SYSTEM\CurrentControlSet\Control\LSA" /v RunAsPPL

# 5 — Incompatible drivers flagged by HVCI
& "$env:SystemRoot\System32\driverquery.exe" /FO CSV /NH |
    ConvertFrom-Csv -Header "Name","DisplayName","Type","State" |
    Where-Object { $_.State -ne "Running" } | Select-Object -First 20
```

### Interpretation
| Result | Meaning | Action |
|--------|---------|--------|
| `VirtualizationBasedSecurityStatus = 2` | VBS running | Proceed to specific symptom |
| `VirtualizationBasedSecurityStatus = 0` | VBS not running | Check Secure Boot + TPM + BIOS VT-x |
| `CredentialGuardRunning = 1` | CG active; LSA is isolated | Expected on hybrid-joined devices |
| `HyperVisorPresent = False` | Hypervisor not loaded | BIOS VT-x/AMD-V disabled or nested virt not enabled |
| `LsaCfgFlags = 0x2` | Credential Guard on (UEFI locked) | Requires UEFI var clear to disable |
| `LsaCfgFlags = 0x1` | Credential Guard on (GPO/registry) | Can disable via GPO |
| `RunAsPPL = 1` | LSA PPL only (not full CG) | Softer isolation — easier to disable |

---
## Dependency Cascade

<details><summary>What must be true for VBS/Credential Guard to function</summary>

```
Hardware Layer
├── CPU with VT-x / AMD-V enabled in firmware
├── SLAT (EPT / NPT) support
├── TPM 2.0 (required for full UEFI lock)
└── Secure Boot enabled
        │
        ▼
Firmware / UEFI Layer
├── Secure Boot policy active
├── VT-x / AMD-V enabled
└── Platform Security Level ≥ 3 (for HVCI)
        │
        ▼
Windows Boot Layer
├── HVCI (HypervisorEnforcedCodeIntegrity) policy
├── Hypervisor Platform (HV) loaded at boot
└── VBS policy flag set (registry + EFI variable)
        │
        ▼
Kernel / OS Layer
├── IUM (Isolated User Mode) process
├── SecureKernel.exe running in VSM
└── LsaIso.exe (Credential Guard) or LSA PPL
        │
        ▼
Application Layer
├── NTLM/Kerberos credentials isolated in VSM
├── Third-party AV / DLP drivers must be HVCI-compatible
└── Virtualization platforms (VMware, VirtualBox) blocked on host
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm VBS platform status**
```powershell
$dg = Get-CimInstance Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard
$dg | Format-List *
```
Expected: `VirtualizationBasedSecurityStatus = 2`, `SecurityServicesRunning` includes `{1}` (CG) or `{2}` (HVCI).  
Bad: `VirtualizationBasedSecurityStatus = 0` → VBS failed to load. Check event log next.

**Step 2 — Check System Event Log for VBS failures**
```powershell
Get-WinEvent -LogName System -MaxEvents 500 |
    Where-Object { $_.Id -in @(14, 15, 16, 17, 4096, 4097, 4098) -and
                   $_.ProviderName -match "Microsoft-Windows-DeviceGuard|Hyper-V" } |
    Select-Object TimeCreated, Id, Message | Format-List
```
Event 14/15 = VBS enable/disable. Event 4096–4098 = HVCI driver compat failures.

**Step 3 — Check for incompatible drivers blocking HVCI**
```powershell
# Drivers that fail HVCI signing check appear in this log
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 100 |
    Where-Object { $_.LevelDisplayName -eq "Warning" -or $_.LevelDisplayName -eq "Error" } |
    Select-Object TimeCreated, Id, Message | Format-List
```
If drivers are flagged: update or remove them before enabling HVCI.

**Step 4 — Validate UEFI lock status for Credential Guard**
```powershell
# Check if CG is UEFI-locked (requires more steps to disable)
$lsaFlags = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name LsaCfgFlags -EA SilentlyContinue).LsaCfgFlags
switch ($lsaFlags) {
    0 { "CG not configured" }
    1 { "CG enabled via registry/GPO — can disable with GPO rollback" }
    2 { "CG enabled and UEFI-locked — requires EFI variable clear procedure" }
    default { "Unknown value: $lsaFlags" }
}
```

**Step 5 — Check VMware/VirtualBox conflict (common on dev machines)**
```powershell
Get-Service -Name "VMware*","VBoxSup" -EA SilentlyContinue | Select-Object Name, Status, StartType
```
If VMware Workstation / VirtualBox services are running, they conflict with VBS on the same host.

---
## Common Fix Paths

<details><summary>Fix 1 — VBS not loading: enable VT-x in BIOS</summary>

**Symptom:** `HyperVisorPresent = False`, `VirtualizationBasedSecurityStatus = 0`  
**Cause:** CPU virtualisation disabled in UEFI firmware.

**Steps (cannot be scripted — requires physical/iLO access):**
1. Reboot into UEFI/BIOS setup
2. Enable: Intel VT-x (or AMD-V) + VT-d (IOMMU) + Secure Boot
3. Save and boot back to Windows
4. Verify:
```powershell
(Get-CimInstance Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard).VirtualizationBasedSecurityStatus
# Expected: 2
```

**Rollback:** Disable VT-x in BIOS again. No Windows changes made.
</details>

<details><summary>Fix 2 — Disable Credential Guard (GPO/registry-only, not UEFI-locked)</summary>

**Symptom:** CG is preventing a third-party app or driver from functioning. `LsaCfgFlags = 0x1`  
**Use when:** Confirmed `LsaCfgFlags = 1` (NOT 2).

```powershell
# Disable via registry (requires reboot)
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name LsaCfgFlags -Value 0
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name EnableVirtualizationBasedSecurity -Value 0
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name RequirePlatformSecurityFeatures -Value 0

Write-Host "Reboot required. Run validation after reboot."
```

**Rollback:**
```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" -Name LsaCfgFlags -Value 1
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name EnableVirtualizationBasedSecurity -Value 1
```

⚠️ If enforced by Intune/GPO, the policy will re-apply at next sync. Address the policy source.
</details>

<details><summary>Fix 3 — Disable Credential Guard (UEFI-locked, LsaCfgFlags = 2)</summary>

**Symptom:** `LsaCfgFlags = 0x2`. Registry changes alone won't work — EFI variable holds the lock.  
**Warning:** This is a destructive, multi-step procedure. Confirm with the customer before proceeding.

**Requirements:** Windows 10/11 Pro or Enterprise. Local admin.

```powershell
# Step 1 — Disable via registry (stage the removal)
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\LSA" `
    -Name LsaCfgFlags -Value 0 -PropertyType DWORD -Force
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" `
    -Name EnableVirtualizationBasedSecurity -Value 0 -PropertyType DWORD -Force

# Step 2 — Clear the EFI variable at next boot using the built-in tool
# Schedule mountvol and bcdedit to disable VBS on next boot
bcdedit /set hypervisorlaunchtype off
```

Then reboot **twice**:
- Reboot 1: Windows disengages CG and clears EFI variable  
- Reboot 2: Boot with VBS fully off

```powershell
# After second reboot — validate
(Get-CimInstance Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard).CredentialGuardRunning
# Expected: 0
```

**Rollback:** Re-enable via Intune Device Configuration profile (Device Guard settings) or GPO.
</details>

<details><summary>Fix 4 — HVCI blocking a driver (Memory Integrity incompatibility)</summary>

**Symptom:** Driver fails to load after HVCI enabled. Code Integrity log shows warning/error for driver.  
**Common culprits:** Older VPN clients, legacy AV, USB filter drivers, VMware VMCI.

```powershell
# Identify the flagged driver
$events = Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 200 |
    Where-Object { $_.Id -in @(3033,3063,3065,3066,3077,3089) }
$events | Select-Object TimeCreated, @{N="Message";E={$_.Message -replace '\s+',' '}} | Format-List

# Find which package owns the driver
$driverName = "<DriverFileName>.sys"  # from event above
Get-WindowsDriver -Online | Where-Object { $_.OriginalFileName -like "*$driverName*" } |
    Select-Object Driver, ProviderName, Version, Date
```

**Fix:** Update the driver to HVCI-compatible version from vendor, or remove the driver/package.

```powershell
# Remove driver package (use with caution)
pnputil /delete-driver <oem##.inf> /uninstall /force
```

**Rollback (if removal breaks something):**  
```powershell
pnputil /add-driver "<path\to\original.inf>" /install
```
</details>

<details><summary>Fix 5 — VMware Workstation / VirtualBox conflict with VBS host</summary>

**Symptom:** Cannot start VMs after VBS/HVCI enabled, or VBS fails to enable because VMware is active.

```powershell
# Option A: Use Hyper-V compatible mode in VMware (requires VMware 15.5.5+)
# In VMware: VM Settings → Processors → Enable "Virtualize Intel VT-x/EPT or AMD-V/RVI"
# This runs VMware inside Hyper-V/VBS (slower but compatible)

# Option B: Disable VBS for VMware use-case (registry method)
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name EnableVirtualizationBasedSecurity -Value 0
bcdedit /set hypervisorlaunchtype off
# Reboot
```

**Note:** Microsoft recommends VMware 16+ with Hyper-V compatibility mode as the preferred path. Disabling VBS is a fallback for legacy environments only.
</details>

---
## Escalation Evidence

```
ESCALATION TICKET — VBS / Credential Guard Issue
================================================
Customer:         <CustomerName>
Engineer:         <EngineerName>
Date/Time:        <YYYY-MM-DD HH:MM>
Device:           <Hostname> | <OS Build> | <Hardware model>

VBS Status:       (paste VirtualizationBasedSecurityStatus value)
CG Running:       (paste CredentialGuardRunning value)
LsaCfgFlags:      (paste registry value: 0/1/2)
HyperVPresent:    (True/False)
Secure Boot:      (Enabled/Disabled)
TPM Version:      (1.2 / 2.0 / None)

Symptom observed: <describe what broke or what the user reported>
Steps already taken:
  1. <step>
  2. <step>

Code Integrity events (paste from step 3 above if applicable):
<paste events>

Relevant policy source (Intune/GPO): <policy name or N/A>

Blocking issue (tick one):
[ ] Driver incompatibility — driver name: <driver.sys>
[ ] UEFI-locked CG needs physical/OOB access
[ ] Hardware does not support VT-x
[ ] Policy conflict — need policy owner
[ ] Unknown — needs L3 escalation
```

---
## 🎓 Learning Pointers

- **VBS ≠ Credential Guard**: VBS is the hypervisor platform; Credential Guard is one service that runs on top of it. HVCI (Memory Integrity) is another. Both require VBS but are independently configurable. — [MS Docs: VBS overview](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/oem-vbs)
- **UEFI lock means two reboots minimum**: If `LsaCfgFlags = 2`, a single reboot won't clear the EFI variable. The system needs to enter a "disable" cycle across two reboots. This trips up engineers who check after one reboot and think it failed.
- **Intune will re-enable what you disable**: If CG is pushed via an Intune Device Configuration profile (Endpoint Security → Account Protection), disabling it at the registry level will be overwritten at next policy sync. Fix the policy, not just the device.
- **HVCI is the common VMware killer**: Memory Integrity (HVCI) blocks unsigned or WHQL-incompatible kernel drivers. VMware and VirtualBox historically ship drivers that fail this check. VMware 16+ added Hyper-V compatibility mode to resolve this. — [VMware KB: 76918](https://kb.vmware.com/s/article/76918)
- **`Win32_DeviceGuard` is the authoritative source**: `msinfo32.exe` System Summary → "Virtualization-based security" row is the user-friendly version of the same data. Both read from the same WMI provider. — [MS Docs: Win32_DeviceGuard](https://learn.microsoft.com/en-us/windows/win32/wmisdk/win32-deviceguard)
- **Nested virtualisation needs explicit flag**: If the device is a VM (Azure VM, Hyper-V guest), VBS inside it requires the host to pass through `ExposeVirtualizationExtensions = $true` on the VM configuration. — [MS Docs: Nested virtualisation](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization)
