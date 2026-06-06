# Tamper Protection — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Defender for Endpoint (MDE) Tamper Protection — prevents unauthorized modification of Defender security settings
- Tamper Protection managed via Intune (cloud-managed devices)
- Tamper Protection managed via MDE Security Settings Management
- Tamper Protection on standalone (non-Intune) devices via registry and local security center
- Tamper Protection state reporting and audit events
- Interaction with WDAC, ASR rules, and Credential Guard

**Out of Scope:**
- Third-party AV coexistence tamper conflicts (see MDE passive mode docs)
- Tamper Protection on non-Windows platforms (macOS MDE tamper is handled separately)
- Microsoft 365 Defender tenant-wide attack surface policies

**Assumed Prerequisites:**
- Microsoft Defender for Endpoint Plan 1 or Plan 2
- Windows 10 1903+ or Windows 11 (for full cloud-managed Tamper Protection)
- Devices enrolled in Intune OR onboarded to MDE Security Settings Management
- Defender antivirus in active mode (not passive)

---

## How It Works

<details><summary>Full architecture</summary>

### What Tamper Protection Does

Tamper Protection is a kernel-level protection layer that locks down critical Defender security settings, preventing:
- Disabling real-time protection
- Disabling cloud-delivered protection
- Disabling behavior monitoring
- Disabling IOAV (Input/Output Anti-Virus)
- Modifying threat action settings (e.g., `ThreatSeverityDefaultAction`)
- Adding exclusions that bypass scanning
- Clearing the threat definition update source

When Tamper Protection is **on**, these settings become read-only regardless of:
- Registry edits (even by SYSTEM)
- Group Policy Object (GPO) pushes that would normally override them
- PowerShell `Set-MpPreference` commands
- WMI calls
- Third-party software writing to Defender registry keys

### Management Authority Hierarchy

Tamper Protection obeys a strict management authority hierarchy:

```
Priority 1 (highest): Intune (MDM) policy via CSP
         │  → If Intune sets TP=ON, cannot be disabled by anything below
         ▼
Priority 2: MDE Security Settings Management
         │  → If MDE portal manages TP, Intune must explicitly yield
         ▼
Priority 3: Microsoft Endpoint Configuration Manager (MECM/SCCM)
         │  → If tenant-attach is configured, MECM policies may manage TP
         ▼
Priority 4: Group Policy (GPO)
         │  → GPO settings are BLOCKED by Tamper Protection if higher-priority
         │    management has TP enabled — this is the most common admin surprise
         ▼
Priority 5: Local Security Center / Windows Security App
         │  → User toggle — available only if no management policy is set
         ▼
Priority 6 (lowest): Registry / PowerShell / WMI (direct)
         └  → Blocked by TP regardless of user privilege level
```

### Cloud vs. Local Enforcement

**Cloud-managed Tamper Protection (recommended):**
- Device is Intune-enrolled or MDE-onboarded
- TP state is enforced by the Defender Health Attestation Service
- Cloud periodically validates local TP state and re-enforces if tampered
- Provides audit trail in MDE portal under `DeviceEvents` table

**Locally-managed Tamper Protection (legacy):**
- Device not managed by Intune/MDE
- TP state held in `HKLM\SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection`
- No cloud re-enforcement — local admin can toggle via Security Center
- No centralized reporting

### Registry Internals

The TamperProtection registry value is NOT directly writable even by SYSTEM when TP is active:

```
HKLM\SOFTWARE\Microsoft\Windows Defender\Features
  TamperProtection    REG_DWORD
    0 = Disabled
    1 = Not configured  
    4 = Enabled
    5 = Enabled (cloud-managed, read-only enforced by cloud)
```

Value `5` is the cloud-managed state. Attempts to write any other value while in state `5` will be silently blocked and the value reset by the Defender service.

### Audit Events

When Tamper Protection blocks a change, the following events are written:

| Event ID | Source | Meaning |
|----------|--------|---------|
| 5013 | Microsoft-Windows-Windows Defender/Operational | TP blocked a registry change |
| 1127 | Microsoft-Windows-Windows Defender/Operational | TP state changed |
| DeviceEvents (KQL) | MDE | `ActionType = "TamperProtectionTriggered"` |

</details>

---

## Dependency Stack

```
┌────────────────────────────────────────────────────────────┐
│     Tamper Protection (kernel enforcement layer)           │
│   Locks: MpPreference, Registry keys, Threat actions       │
└─────────────────┬──────────────────────────────────────────┘
                  │ managed by (one authority wins)
        ┌─────────┴──────────────────┐
        │                            │
┌───────▼──────────┐      ┌─────────▼──────────────┐
│  Intune / MDM    │      │  MDE Security Settings  │
│  (WindowsDefender│      │  Management (MDE portal)│
│   CSP Profile)   │      └─────────────────────────┘
└───────┬──────────┘
        │ delivered via
┌───────▼──────────────────────────────────────────────┐
│  Windows Defender Antivirus Service (WinDefend)      │
│  must be: Running, Active Mode (not Passive/EDR-only)│
└───────┬──────────────────────────────────────────────┘
        │ depends on
┌───────▼──────────────────────────────────────────────┐
│  Microsoft Defender for Endpoint Onboarding          │
│  (MDE License: Plan 1 / Plan 2)                      │
│  Onboarding blob applied to device                   │
└───────┬──────────────────────────────────────────────┘
        │ requires
┌───────▼──────────────────────────────────────────────┐
│  Device: Windows 10 1903+ or Windows 11              │
│  WinDefend service not disabled by GPO               │
│  No conflicting third-party AV in active mode        │
└──────────────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `Set-MpPreference` fails silently or settings revert | Tamper Protection is active and blocking | `Get-MpComputerStatus \| Select IsTamperProtected` |
| GPO Defender policy not applying | TP blocks GPO overrides when cloud-managed | Verify TP state; Intune wins over GPO when TP is ON |
| Intune profile shows TP=ON but device shows disabled | Management conflict — multiple authorities | Check `MdeAttachSense` enrollment; review conflicting policies |
| TP shows "on" in Security Center but MDE portal shows "off" | Reporting lag or enrollment gap | Check device onboarding status in MDE; wait 15 min |
| Cannot disable TP to install legacy security software | Cloud-managed TP enforced — local toggle blocked | Must disable via Intune policy or MDE portal |
| Event ID 5013 flooding device logs | Something is repeatedly attempting to change Defender settings | Check which process is triggering — likely a GPO or script |
| TP toggle grayed out in Windows Security app | Intune or MDE is managing TP — expected behavior | Correct — management authority owns the setting |
| After MDE offboarding, TP stuck on | TP can persist after offboarding if managed via Intune | Remove Intune profile; TP reverts to local control |
| WDAC policy blocked by TP | TP prevents modification of Defender CSP during WDAC deployment | Deploy WDAC via signed policy to avoid TP conflict |

---

## Validation Steps

**1. Check Tamper Protection state (local)**
```powershell
$status = Get-MpComputerStatus
[PSCustomObject]@{
    IsTamperProtected   = $status.IsTamperProtected
    AntivirusEnabled    = $status.AntivirusEnabled
    AMRunningMode       = $status.AMRunningMode
    RealTimeProtection  = $status.RealTimeProtectionEnabled
    ManagedBy           = if ($status.IsTamperProtected) { "Check registry for cloud vs local" } else { "Not enforced" }
} | Format-List
```
*Expected:* `IsTamperProtected = True`, `AMRunningMode = Normal` (not `Passive`).
*Bad:* `False` on a device that should be protected, or `AMRunningMode = Passive` (third-party AV conflict).

**2. Check registry state (management authority)**
```powershell
$tpValue = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features" -Name "TamperProtection" -ErrorAction SilentlyContinue
switch ($tpValue) {
    0 { "Disabled" }
    1 { "Not Configured" }
    4 { "Enabled (locally managed)" }
    5 { "Enabled (cloud-managed — Intune/MDE)" }
    default { "Unknown value: $tpValue" }
}
```
*Expected:* `5` for cloud-managed endpoints.
*Bad:* `0` or `1` on a device that should be protected.

**3. Check Intune policy assignment**
```powershell
# On device — check MDM enrollment and applied policies
Get-Item "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender" -ErrorAction SilentlyContinue |
    Get-ItemProperty | Select-Object TamperProtection, *

# Also check: Settings > System > About > "Managed by <your org>"
```

**4. Check MDE onboarding state**
```powershell
# Verify MDE onboarding blob is applied
$senseKey = "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"
Get-ItemProperty -Path $senseKey -ErrorAction SilentlyContinue | Select-Object OnboardingState, OrgId
```
*Expected:* `OnboardingState = 1`.
*Bad:* Key missing or `OnboardingState = 0` — device not onboarded to MDE.

**5. Check for Event ID 5013 (TP blocking events)**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 |
    Where-Object { $_.Id -eq 5013 } |
    Select-Object TimeCreated, Message |
    Format-List
```
*Expected:* No recent events (TP is not actively blocking anything).
*Bad:* Repeated events — something is repeatedly trying to change Defender settings.

---

## Troubleshooting Steps (by phase)

### Phase 1 — TP Not Enabled on a Managed Device

1. Verify the Intune Endpoint Security profile for Antivirus includes `TamperProtection = Enabled`.
2. Check device sync status in Intune portal — force sync if stale.
3. Verify device is MDE-onboarded (required for cloud enforcement):
   ```powershell
   sc.exe query sense | Select-String "STATE"
   ```
   Expected: `STATE: 4 RUNNING`.
4. Check WinDefend service is running in normal (not passive) mode.
5. If device is not in Intune but in MDE: enable Tamper Protection via MDE Security Settings Management (Security Center → Settings → Endpoints → Advanced features → Enable Security Settings Management).

---

### Phase 2 — TP Blocking a Legitimate Admin Operation

**Scenario:** You need to change a Defender setting (e.g., add an exclusion, change a scan schedule) on a cloud-managed device.

**Correct approach: modify via Intune, not locally.**

Tamper Protection is designed so that all Defender config changes flow through the management authority (Intune/MDE portal). Local `Set-MpPreference` commands are intentionally blocked.

If you must temporarily disable TP (e.g., for a migration):
1. In Intune: Go to Endpoint Security → Antivirus → Your profile → Set TamperProtection = Disabled
2. Wait for device sync (up to 15 min, or use "Sync" from device blade)
3. Perform your operation
4. Re-enable via Intune immediately

**Never leave TP disabled after operations are complete.**

---

### Phase 3 — Conflict Between Intune and MDE Security Settings Management

This is a common MSP pitfall — devices may be managed by BOTH Intune and MDE, leading to conflicting TP states.

```powershell
# Check if MDE Security Settings Management is enrolled
$mdeSSMKey = "HKLM:\SOFTWARE\Microsoft\SenseCM"
Get-ItemProperty -Path $mdeSSMKey -ErrorAction SilentlyContinue | Select-Object DeviceChannelId, PolicyStatus
```

**Resolution:**
- If Intune is the primary MDM: Ensure MDE Security Settings Management is scoped to exclude Intune-managed devices (MDE portal → Settings → Endpoints → Configuration Management → Scoping)
- If MDE SSM is primary: Remove conflicting Intune Defender profiles from the device scope

---

### Phase 4 — GPO Overrides Being Blocked by TP

When Tamper Protection is active, GPO Defender policies (under `Computer Configuration\Administrative Templates\Windows Components\Microsoft Defender Antivirus`) are silently ignored for the settings TP protects.

**Diagnostic:**
```powershell
# Check for GPO Defender settings vs. actual runtime values
$gpoSettings = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -ErrorAction SilentlyContinue
$runtimeSettings = Get-MpPreference
Write-Host "GPO DisableAntiSpyware: $($gpoSettings.DisableAntiSpyware)"
Write-Host "Runtime: AntivirusEnabled = $((Get-MpComputerStatus).AntivirusEnabled)"
```

If GPO shows `DisableAntiSpyware = 1` but TP is on, the GPO has no effect — Defender remains active. This is correct and expected behavior. Remove conflicting GPOs from the OU to avoid confusion.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Enable Tamper Protection via Intune at Scale</summary>

**Goal:** Enable cloud-managed Tamper Protection across all Windows endpoints.

**Risk:** Medium — will prevent any local Defender changes. Ensure all Defender config is managed via Intune before enabling.

**Intune Steps:**
1. Intune portal → Endpoint Security → Antivirus → Create policy
2. Platform: Windows 10 and later / Template: Microsoft Defender Antivirus
3. Set: `Tamper Protection = Enabled`
4. Assign to: All Devices (or a pilot group first)

**Validation after deployment:**
```powershell
# Run on target device after sync
Get-MpComputerStatus | Select-Object IsTamperProtected, AMRunningMode, RealTimeProtectionEnabled
```

**Rollback:** Set `Tamper Protection = Not Configured` in Intune profile and sync devices.

</details>

<details><summary>Playbook 2 — Audit Tamper Protection State Across Tenant (MDE KQL)</summary>

**Goal:** Identify all devices where Tamper Protection is not active.

**Run in Microsoft Defender XDR → Advanced Hunting:**
```kql
// Devices where Tamper Protection is OFF
DeviceTvmSecureConfigurationAssessment
| where ConfigurationId == "scid-91"
| where IsCompliant == 0
| project DeviceName, OSPlatform, IsCompliant, ConfigurationSubcategory, Timestamp
| sort by Timestamp desc

// Alternative: Check via DeviceInfo
DeviceInfo
| summarize arg_max(Timestamp, *) by DeviceId
| where OnboardingStatus == "Onboarded"
| join kind=leftouter (
    DeviceTvmSecureConfigurationAssessment
    | where ConfigurationId == "scid-91"
    | project DeviceId, IsTamperProtected = IsCompliant
) on DeviceId
| where IsTamperProtected == 0 or isempty(IsTamperProtected)
| project DeviceName, DeviceId, OSPlatform, IsTamperProtected
```

</details>

<details><summary>Playbook 3 — Temporarily Disable TP for Maintenance (Break-Glass)</summary>

**Goal:** Safely disable Tamper Protection for a scheduled maintenance window, then re-enable.

**Risk:** High — device is unprotected during the window. Minimize window duration.

```powershell
<#
.SYNOPSIS  Break-glass Tamper Protection disable/enable via Graph API
.NOTES     Requires: DeviceManagementConfiguration.ReadWrite.All graph permission
           This modifies the Intune policy directly — affects all devices in scope
#>

# Step 1: Find the policy
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"
$policies = Get-MgDeviceManagementConfigurationPolicy | Where-Object { $_.Name -match "Antivirus|Defender|Tamper" }
$policies | Select-Object Id, Name | Format-Table

# Step 2: Record current TP setting and set to Disabled
# (Modify via Intune portal recommended for audit trail — use portal for this step)
Write-Host "Modify TamperProtection setting in Intune portal → Endpoint Security → Antivirus" -ForegroundColor Yellow
Write-Host "Set to: Disabled"
Write-Host "Wait for device sync. Perform maintenance. Then set back to: Enabled" -ForegroundColor Yellow

# Step 3: Verify disabled on device
Start-Sleep -Seconds 900  # 15 min for policy sync
$state = Get-MpComputerStatus
Write-Host "IsTamperProtected: $($state.IsTamperProtected)"  # Should be False
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Tamper Protection evidence collector for escalation
.NOTES       Run locally on the affected device as Administrator
             Output: C:\Temp\TamperProtection-Evidence-<timestamp>.txt
#>

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = "C:\Temp\TamperProtection-Evidence-$timestamp.txt"

"=== Tamper Protection Evidence Pack - $timestamp ===" | Out-File $outFile
"Hostname: $env:COMPUTERNAME" | Out-File $outFile -Append
"User: $env:USERNAME" | Out-File $outFile -Append

"--- MpComputerStatus ---" | Out-File $outFile -Append
Get-MpComputerStatus | Select-Object IsTamperProtected, AMRunningMode, AntivirusEnabled,
    RealTimeProtectionEnabled, BehaviorMonitorEnabled, IoavProtectionEnabled |
    Format-List | Out-File $outFile -Append

"--- Registry TamperProtection Value ---" | Out-File $outFile -Append
$tpReg = Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features" -Name "TamperProtection" -EA SilentlyContinue
"TamperProtection registry value: $tpReg (5=cloud-managed, 4=local, 0=disabled)" | Out-File $outFile -Append

"--- MDE Onboarding State ---" | Out-File $outFile -Append
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -EA SilentlyContinue |
    Select-Object OnboardingState, OrgId | Out-File $outFile -Append

"--- WinDefend Service Status ---" | Out-File $outFile -Append
Get-Service -Name "WinDefend","Sense","MsSense" | Select-Object Name, Status, StartType | Out-File $outFile -Append

"--- Recent Event ID 5013 (TP blocking events) ---" | Out-File $outFile -Append
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 500 -EA SilentlyContinue |
    Where-Object { $_.Id -eq 5013 } |
    Select-Object TimeCreated, Message | Format-List | Out-File $outFile -Append

"--- MDM Enrollment Status ---" | Out-File $outFile -Append
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" -EA SilentlyContinue |
    Select-Object EnrollmentType, ProviderID, UPN | Out-File $outFile -Append

"--- Applied Defender MDM CSP Values ---" | Out-File $outFile -Append
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender" -EA SilentlyContinue |
    Out-File $outFile -Append

Write-Host "Evidence written to: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check TP state | `Get-MpComputerStatus \| Select IsTamperProtected, AMRunningMode` |
| Check TP registry value | `Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features" -Name TamperProtection` |
| Check MDE onboarding | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"` |
| Check WinDefend + Sense services | `Get-Service WinDefend, Sense \| Select Name, Status` |
| Check for TP blocking events | `Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" \| Where-Object {$_.Id -eq 5013}` |
| Check MDM enrollment | `dsregcmd /status` (look for `MDMEnrolled = YES`) |
| Force Intune sync (device) | `Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/c /AutoEnrollMDM"` |
| Verify GPO Defender settings | `Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"` |
| MDE KQL — non-TP devices | See Playbook 2 above |
| Check MDE SSM enrollment | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\SenseCM"` |

---

## 🎓 Learning Pointers

- **Tamper Protection vs. GPO: a common MSP misconception.** Many engineers expect that Group Policy always wins on domain-joined machines. When cloud-managed Tamper Protection (value `5`) is active, GPO Defender settings are silently ignored. This is intentional — the cloud management authority overrides GPO. If you're seeing GPO Defender policies not applying, TP is likely the reason. Reference: [Protect security settings with Tamper Protection](https://learn.microsoft.com/en-us/defender-endpoint/prevent-changes-to-security-settings-with-tamper-protection)

- **The management authority must be singular.** If a device is managed by both Intune AND MDE Security Settings Management, conflicts arise and TP may flip between states. Scope MDE SSM to exclude Intune-managed devices using the MDE scoping policy. This is the root cause of most "TP flapping" reports in MSP environments.

- **Cloud enforcement re-arms TP after tampering.** A device in cloud-managed state (`TamperProtection = 5`) that gets its registry value changed will have it restored by the Defender Health Attestation Service within minutes. This is the cloud re-enforcement mechanism. It means attempts to disable TP via a malware script will be automatically undone — which is exactly the point.

- **Passive mode breaks Tamper Protection.** If Microsoft Defender Antivirus is in Passive mode (because a third-party AV is active), Tamper Protection cannot fully enforce. The `IsTamperProtected` flag will reflect the limitation. Before enabling TP at scale, audit `AMRunningMode` across the fleet using MDE Advanced Hunting: `DeviceInfo | where AntispywareIsEnabled == false`.

- **Windows Security app toggle grayed out = correct.** When TP is managed by Intune or MDE, the toggle in the Windows Security app is intentionally read-only. End users and helpdesk agents frequently raise this as a "bug" — it is a feature. The only way to change TP state is through the managing authority.

- **Audit all TP change events via MDE.** Any change to Tamper Protection state generates a `DeviceEvents` record with `ActionType = "TamperProtectionTriggered"`. Build a KQL alert rule in Microsoft Sentinel or Defender for Identity to page on unexpected TP disable events — these may indicate a compromise attempt. Reference: [Review events and errors using Event Viewer](https://learn.microsoft.com/en-us/defender-endpoint/troubleshoot-microsoft-defender-antivirus)
