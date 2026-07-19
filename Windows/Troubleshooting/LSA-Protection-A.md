# LSA Protection (RunAsPPL) — Reference Runbook (Mode A: Deep Dive)
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
| **OS** | Windows 8.1+ / Server 2012 R2+ (this feature predates VBS by years); auto-enablement specifics apply to Windows 11 22H2+ |
| **Hardware** | None required for the base feature (PPL is a code-integrity/kernel construct, not a virtualization one) |
| **Scope** | LSA Protection / `RunAsPPL` (Protected Process Light for `lsass.exe`), plug-in signing requirements, audit vs. enforcement mode, UEFI-locked configuration, interaction with (but independence from) Credential Guard |
| **Out of scope** | Virtualization-Based Security, Credential Guard, HVCI — see `Windows/Troubleshooting/VBS-CredentialGuard-A.md` for those (complementary, separately-gated features) |
| **Assumed role** | L2/L3 engineer with local or remote admin access; some remediation paths (UEFI-locked opt-out) require physical/OEM tooling |

---

## How It Works

<details><summary>Full architecture — PPL, signing enforcement, and the auto-enablement trap</summary>

### Protected Process Light (PPL) — not virtualization

LSA Protection predates Credential Guard by years and uses a completely different mechanism: **Protected Process Light (PPL)**, a Windows kernel construct introduced in Windows 8.1 / Server 2012 R2. When `RunAsPPL` is active, `lsass.exe` is launched as a PPL process at a specific **protection level**. The kernel then restricts which other processes may open handles to it with rights like `PROCESS_VM_READ` or `PROCESS_VM_WRITE` — the exact rights a credential-dumping tool (Mimikatz, etc.) needs.

```
┌──────────────────────────────────────────────────────────┐
│                    Normal (non-PPL) world                │
│  Any admin-level process can OpenProcess(lsass.exe,       │
│  PROCESS_VM_READ) and read credential material directly   │
└──────────────────────────────────────────────────────────┘
                          vs.
┌──────────────────────────────────────────────────────────┐
│              LSA Protection (RunAsPPL) active             │
│                                                             │
│  lsass.exe runs as a Protected Process Light (level 4,     │
│  "WinTcb-Light" equivalent for LSA)                        │
│                                                             │
│  Kernel enforces: only OTHER signed protected processes   │
│  at an equal-or-higher protection level may open lsass.exe │
│  with memory-read/write rights. Standard admin tools —     │
│  even running as SYSTEM — are denied by the kernel itself, │
│  not by an ACL that could be reconfigured.                 │
└──────────────────────────────────────────────────────────┘
```

This is orthogonal to Credential Guard. Credential Guard (VBS) moves the *secrets themselves* into a hypervisor-isolated VTL 1 container reachable only via `lsaiso.exe`. LSA Protection (PPL) instead restricts *who can even touch the lsass.exe process* in the first place, at the normal VTL 0 kernel level — no hypervisor, no SLAT, no TPM needed. A 10-year-old non-SLAT machine can run LSA Protection; it cannot run Credential Guard.

### Signing enforcement for LSA plug-ins

Anything that loads *into* `lsass.exe` as a plug-in — smart card mini-drivers, cryptographic CSPs/KSPs, password filter DLLs (`PasswordFilter`/`PasswordChangeNotify` exports), some VPN client authentication modules, legacy AV credential-scanning hooks — must, once PPL is active:

1. Be digitally signed with a **Microsoft signature** (WHQL certification for kernel drivers; the [file-signing service for LSA](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/file-signing-manage) for user-mode plug-ins that aren't drivers), **and**
2. Conform to Microsoft Security Development Lifecycle (SDL) process guidance — a properly-signed plug-in can still be refused if it doesn't meet SDL requirements.

Neither requirement is configurable by an administrator. There is no policy exception list — the only fix for a non-compliant plug-in is a compliant build from the vendor, or living without that integration.

### Audit mode vs. enforcement mode

Two independent logging layers exist, both under **Applications and Services Logs → Microsoft → Windows → CodeIntegrity → Operational**:

| Mode | Trigger | Event IDs | Behavior |
|------|---------|-----------|----------|
| **Audit** (pre-flight) | On by default on Windows 11 22H2+; can be forced on any supported OS via `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\LSASS.exe\AuditLevel = 8` | 3065 (shared-section violation), 3066 (signing-level violation) | Logs what *would* be blocked. Does not block anything. |
| **Enforcement** (live) | `RunAsPPL` set to 1 or 2, or auto-enabled | 3033 (signing-level violation, blocked), 3063 (shared-section violation, blocked) | Actually prevents the plug-in/driver from loading into LSASS. |

Critically: **audit mode does not require `RunAsPPL` to be set at all.** A device can be silently logging 3065/3066 events today, telling you exactly what will break the day enforcement turns on — most engineers never look until after the break.

### The auto-enablement trap

Starting with Windows 11 version 22H2, LSA Protection enables **automatically**, with no registry write, no GPO, no Intune profile, when all three conditions are met:

1. Clean install of Windows 11 22H2+ (not an in-place upgrade from an earlier release)
2. Enterprise-joined: AD domain-joined, Microsoft Entra-joined, or hybrid Entra-joined
3. Hardware capable of HVCI (`AvailableSecurityProperties` includes value 2 in the `Win32_DeviceGuard` WMI class) — note this is a *capability* check, not a requirement that HVCI is actually turned on

When auto-enabled this way, **no UEFI variable is set** and, per Microsoft's own documentation, the feature activates without the administrator explicitly configuring `RunAsPPL`. In practice this means `Get-ItemProperty ... RunAsPPL` can return nothing at all on a device that is, in fact, actively enforcing LSA Protection — the only reliable ground truth is the WinInit Event ID 12 at boot (see Validation Steps). This single fact accounts for a large share of "is it on or not" confusion in community forums and support tickets.

### UEFI lock semantics

`RunAsPPL = 1` writes the configuration into a UEFI firmware variable in addition to the registry. Once locked:
- The registry value can be changed freely by an admin, but it has **no effect** — the firmware variable wins.
- Removal requires the [LSA Protected Process Opt-out tool](https://www.microsoft.com/download/details.aspx?id=40897) (`LsaPplConfig.efi`, x86 and x64 builds available) run in a pre-boot/EFI context, or a full Secure Boot reset (which wipes *all* Secure Boot state, not just this one variable — a last resort).
- `RunAsPPL = 2` is the non-locked equivalent, **only enforced on Windows 11 22H2 and later** — on earlier OS versions a value of 2 has no effect (falls back to disabled).

</details>

---

## Dependency Stack

```
Client symptom (auth failure, LSASS crash, smart card/VPN broken)
        │
        ▼
LSA plug-in / driver attempting to load into lsass.exe
        │  (smart card mini-driver, crypto CSP/KSP, password filter DLL,
        │   some VPN auth modules, legacy AV credential hooks)
        ▼
Code Integrity signing check
        │  requires: Microsoft signature (WHQL for drivers /
        │  file-signing service for non-drivers) + SDL compliance
        ▼
PPL enforcement gate (kernel-level, VTL 0 — no hypervisor involved)
        │  requires: RunAsPPL = 1 or 2 (explicit) OR auto-enablement
        │  criteria met (Win11 22H2+, clean install, enterprise-joined,
        │  HVCI-capable hardware)
        ▼
lsass.exe launched as Protected Process Light, level 4
        │  confirmed only by WinInit Event ID 12 at boot — NOT the registry
        ▼
(Independent, optional layer — do not conflate)
Credential Guard / VBS — isolates secrets in VTL 1 via lsaiso.exe
        │  requires: SLAT CPU, TPM 2.0, Secure Boot, Hyper-V —
        │  see VBS-CredentialGuard-A.md
```

**LSA Protection and Credential Guard are independently gated.** A device can have LSA Protection active with Credential Guard absent (most common on older/non-SLAT hardware), both active (typical Windows 11 22H2+ enterprise-joined default), or neither. Never assume one implies the other.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Registry `RunAsPPL` empty/0 but engineer insists protection is "definitely on" | Auto-enablement (Win11 22H2+, clean install, enterprise-joined, HVCI-capable) — registry was never written | WinInit Event ID 12 at boot |
| Smart card login suddenly fails after a feature update | Smart card mini-driver isn't Microsoft-signed for LSA loading; auto-enablement newly applies post-upgrade-to-clean-install refresh | CodeIntegrity Operational log, Event 3033 |
| VPN client "authentication module failed to load" | VPN vendor's LSA auth plug-in unsigned or SDL-noncompliant | Event 3033/3063; check vendor release notes for "LSA Protection compatible" build |
| Custom password complexity filter (pwdfltr-style DLL) silently stops enforcing | Password filter DLL blocked from loading into LSASS, fails silently (no user-facing error) | Event 3033; confirm via `reg query HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Notification Packages` still lists it, but it's not actually loaded |
| Repeated BSOD / LSASS crash loop right after enabling `RunAsPPL` explicitly | A poorly-written legacy kernel driver doesn't handle PPL access denial gracefully and crashes instead of failing cleanly | Boot to Safe Mode, check CodeIntegrity + System event logs pre-crash |
| No audit or enforcement events at all, but client insists a smart card should be blocked | Smart App Control is enabled, suppressing 3065/3066 audit events entirely | Windows Security → App & browser control → Smart App Control status |
| Explicit `RunAsPPL=1` set, engineer can't undo it | UEFI lock active — software rollback impossible | Confirm via `SecurityServicesRunning`/firmware variable presence; requires opt-out EFI tool |
| Debugger can't attach to `lsass.exe` for a vendor-requested diagnostic | Expected — protected processes cannot be debugged by any supported method once PPL is active | No workaround; vendor must diagnose via their own signed instrumentation or you temporarily disable protection (with client sign-off) |

---

## Validation Steps

### 1. Confirm true runtime state (not just configuration intent)

```powershell
# Registry — configuration intent only, can be misleading (see auto-enablement)
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue).RunAsPPL

# GROUND TRUTH — did LSASS actually start as a protected process this boot?
Get-WinEvent -LogName System -MaxEvents 500 |
    Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Wininit' -and $_.Id -eq 12 } |
    Select-Object -First 1 TimeCreated, Message
```

**Good output:** message text contains `LSASS.exe was started as a protected process with level: 4`.
**Bad/absent:** no Event ID 12 from Wininit this boot session — LSA Protection did not activate, regardless of registry contents.

### 2. Determine why (explicit vs. auto vs. not at all)

```powershell
$os = Get-ComputerInfo
$dsreg = dsregcmd /status
$hvciCapable = ((Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).AvailableSecurityProperties) -contains 2

[PSCustomObject]@{
    Build               = $os.OsBuildNumber
    Win11_22H2Plus      = [int]$os.OsBuildNumber -ge 22621
    CleanInstall        = $null  # not queryable directly; cross-reference deployment records (Autopilot/imaging date vs. OS install date)
    DomainOrEntraJoined = ($dsreg -match 'AzureAdJoined\s*:\s*YES' -or $dsreg -match 'DomainJoined\s*:\s*YES')
    HVCICapable         = $hvciCapable
    RegistryRunAsPPL    = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -EA SilentlyContinue).RunAsPPL
}
```

If `RegistryRunAsPPL` is null/0 but all auto-enable criteria are true and Event ID 12 confirms level 4 — this is expected auto-enablement, not a misconfiguration.

### 3. Check for plug-in/driver compatibility issues (audit and enforcement)

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 500 |
    Where-Object { $_.Id -in 3033,3063,3065,3066 } |
    Select-Object TimeCreated, Id, @{N='Type';E={ if ($_.Id -in 3033,3063) {'BLOCKED'} else {'AUDIT-ONLY'} }}, Message |
    Sort-Object TimeCreated -Descending
```

### 4. Check Smart App Control status (suppresses audit events)

```powershell
# Smart App Control state — GUI check is authoritative, but this registry read is a fast proxy
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue
# 0 = Off, 1 = On (Enforce), 2 = Evaluation
```

### 5. Confirm UEFI lock state before attempting any rollback

```powershell
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
    Select-Object SecurityServicesConfigured, SecurityServicesRunning
# Presence of value 4 in either array indicates UEFI lock is in play for VBS-adjacent settings;
# RunAsPPL's own UEFI variable is separate and only reliably confirmed by attempting a registry
# change and rebooting to see if it reverted, or by vendor tooling
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Establishing Ground Truth

1. Never trust the registry alone — run the WinInit Event ID 12 check first
2. Cross-reference auto-enablement criteria (build, join type, HVCI capability, clean-install history)
3. Determine explicit vs. auto vs. inactive before touching anything

### Phase 2: Identifying the Blocked Component

1. Pull CodeIntegrity Operational log for events 3033/3063 (blocked) and 3065/3066 (audit-only)
2. Match the DLL/driver path in the event message to a known plug-in category (smart card, CSP/KSP, password filter, VPN auth module)
3. Confirm Smart App Control isn't hiding audit-mode evidence
4. Check the vendor's current release for a signed, LSA-Protection-compatible build

### Phase 3: Stabilizing a Crash Loop

1. Boot to Safe Mode (`bcdedit /set safeboot minimal` from WinRE, or interrupt boot 3x to reach Advanced Startup)
2. From Safe Mode, disable `RunAsPPL` (registry, value 0) if not UEFI-locked
3. If UEFI-locked, use the opt-out EFI tool — Safe Mode registry edits will not override a locked firmware variable
4. Exit Safe Mode (`bcdedit /deletevalue safeboot`), reboot, confirm stability
5. Only then move to root-cause (Phase 2) before re-enabling

### Phase 4: Rolling Out Explicit Enforcement Safely

1. Force audit mode fleet-wide first if not already default (`AuditLevel=8` under the LSASS.exe Image File Execution Options key) — see Remediation Playbook 3
2. Collect 3065/3066 events for at least one full patch/reboot cycle across a representative device sample
3. Remediate or accept-risk on every flagged plug-in
4. Roll out `RunAsPPL=2` (no UEFI lock) via Intune to a pilot ring
5. Only apply UEFI lock (`RunAsPPL=1`) to devices where the client has explicitly signed off on the reduced recoverability

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Enable LSA Protection fleet-wide via Intune (no UEFI lock)</summary>

```
Intune admin center → Devices → Windows → Configuration profiles → Create
  Platform: Windows 10 and later
  Profile type: Templates → Custom

OMA-URI:    ./Device/Vendor/MSFT/Policy/Config/LocalSecurityAuthority/ConfigureLsaProtectedProcess
Data type:  Integer
Value:      2   (no UEFI lock; use 1 only with explicit client sign-off on recovery trade-off)
```

Registry equivalent for scripted deployment or a single machine:
```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 2 -Type DWord
Restart-Computer -Force
```

**Rollback:**
```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 0 -Type DWord
Restart-Computer -Force
```
Only works if the device was configured with value `2` (no lock). Value `1` deployments cannot be rolled back this way — see Playbook 4.

</details>

<details>
<summary>Playbook 2 — Force audit mode across a fleet before enforcing (pre-flight)</summary>

```powershell
# Deploy via Intune PowerShell script or GPO Registry Preference item
$path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\LSASS.exe'
If (!(Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
Set-ItemProperty -Path $path -Name 'AuditLevel' -Value 8 -Type DWord
Restart-Computer -Force
```

Note: this is redundant (but harmless) on Windows 11 22H2+, where audit mode is on by default. It's essential on earlier supported OS versions where you want visibility before ever setting `RunAsPPL`.

</details>

<details>
<summary>Playbook 3 — Collect and triage audit events across a device sample before rollout</summary>

```powershell
# Run against each pilot-ring device, or wrap in Invoke-Command for remote collection
$events = Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 1000 |
    Where-Object { $_.Id -in 3065,3066 }

$events | Group-Object { ($_.Message -split "`n")[0] } |
    Select-Object Count, Name |
    Sort-Object Count -Descending
```

Aggregate results across the pilot ring before deciding whether a flagged driver is a blocker for the whole rollout or an isolated device issue.

</details>

<details>
<summary>Playbook 4 — Remove a UEFI-locked configuration (requires local/physical access)</summary>

```
1. Download the LSA Protected Process Opt-out tool:
   https://www.microsoft.com/download/details.aspx?id=40897
   (two files named LsaPplConfig.efi — smaller = x86, larger = x64; pick the
   one matching the device architecture, not the OS "bitness" label alone)

2. Follow the tool's documented pre-boot/EFI execution steps on the target
   device — this cannot be scripted for remote/unattended execution across
   a fleet; it requires local or KVM/remote-hands access per device.

3. Reboot. Confirm removal:
   Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
     -ClassName Win32_DeviceGuard | Select SecurityServicesRunning

4. Reapply desired configuration (typically RunAsPPL=2, no lock) once clear.
```

**Caution:** the nuclear alternative — disabling Secure Boot entirely — resets *all* Secure Boot and UEFI-related configuration on the device, not just this one variable. Reserve this for devices already scheduled for a full rebuild.

</details>

---

## Evidence Pack

```powershell
# Run as Administrator — collects LSA Protection evidence for escalation ticket

$report = @()
$report += "=== LSA PROTECTION (RunAsPPL) EVIDENCE PACK ==="
$report += "Date: $(Get-Date)"
$report += "Computer: $env:COMPUTERNAME"
$report += ""

$os = Get-ComputerInfo
$report += "--- OS ---"
$report += "Build: $($os.OsBuildNumber)  ($($os.WindowsProductName))"
$report += ""

$report += "--- Registry (configuration intent) ---"
$reg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
$report += "RunAsPPL: $($reg.RunAsPPL)"
$report += ""

$report += "--- Ground truth: WinInit Event ID 12 (this boot) ---"
$evt12 = Get-WinEvent -LogName System -MaxEvents 500 -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Wininit' -and $_.Id -eq 12 } |
    Select-Object -First 1
$report += If ($evt12) { "Found: $($evt12.Message)" } Else { "NOT FOUND — LSA Protection not active this boot" }
$report += ""

$report += "--- Join type / auto-enablement criteria ---"
$dsreg = dsregcmd /status
$report += ($dsreg | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined") -join "`n"
$hvci = (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue)
$report += "HVCI-capable (AvailableSecurityProperties contains 2): $($hvci.AvailableSecurityProperties -contains 2)"
$report += ""

$report += "--- CodeIntegrity events (last 200, blocked + audit) ---"
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in 3033,3063,3065,3066 } |
    ForEach-Object {
        $type = if ($_.Id -in 3033,3063) { 'BLOCKED' } else { 'AUDIT' }
        $report += "[$type] Event $($_.Id) at $($_.TimeCreated): $($_.Message.Substring(0,[Math]::Min(200,$_.Message.Length)))"
    }
$report += ""

$report += "--- Smart App Control state ---"
$sac = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue
$report += "VerifiedAndReputablePolicyState: $($sac.VerifiedAndReputablePolicyState)  (0=Off,1=On,2=Evaluation)"

$outputPath = "C:\Temp\LSAProtection-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
$report | Out-File -FilePath $outputPath -Encoding UTF8
Write-Host "Evidence saved to: $outputPath" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Registry configuration intent | `(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa').RunAsPPL` |
| Ground-truth runtime state | `Get-WinEvent -LogName System \| Where-Object { $_.Id -eq 12 -and $_.ProviderName -like '*Wininit*' } \| Select -First 1` |
| Blocked plug-in events | `Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' \| Where-Object { $_.Id -in 3033,3063 }` |
| Audit-only (pre-flight) events | `Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' \| Where-Object { $_.Id -in 3065,3066 }` |
| Force audit mode | `Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\LSASS.exe' -Name AuditLevel -Value 8` |
| Enable, no UEFI lock | `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL -Value 2` |
| Enable, UEFI lock (hard to reverse) | `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL -Value 1` |
| Disable (unlocked config only) | `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL -Value 0` |
| Check HVCI capability (auto-enable gate) | `(Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).AvailableSecurityProperties` |
| Check join type | `dsregcmd /status` |
| Intune CSP for fleet rollout | OMA-URI `./Device/Vendor/MSFT/Policy/Config/LocalSecurityAuthority/ConfigureLsaProtectedProcess` (Integer, 1 or 2) |
| Smart App Control state | `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState` |
| UEFI-locked opt-out tool | [LsaPplConfig.efi download](https://www.microsoft.com/download/details.aspx?id=40897) |

---

## 🎓 Learning Pointers

- **PPL predates and is independent of VBS.** LSA Protection is a kernel-level Protected Process Light mechanism from Windows 8.1/Server 2012 R2 — no hypervisor, SLAT, TPM, or Secure Boot required. This is *why* it can auto-enable on hardware that could never run Credential Guard. See: [Configure added LSA protection](https://learn.microsoft.com/en-us/windows-server/security/credentials-protection-and-management/configuring-additional-lsa-protection)

- **The single most important fact for MSP triage: auto-enablement writes no registry key.** A clean-install, enterprise-joined, HVCI-capable Windows 11 22H2+ device silently protects LSASS with nothing to show in `HKLM\SYSTEM\CurrentControlSet\Control\Lsa`. Anyone diagnosing "is LSA Protection on" purely from the registry will get it wrong on a large share of modern fleets. Always confirm via WinInit Event ID 12.

- **Audit mode is a free pre-flight check most engineers never use.** Windows 11 22H2+ logs 3065/3066 audit events by default before you ever touch enforcement — review them proactively during any fleet-wide security hardening pass, not reactively after a break.

- **UEFI lock trades tamper-resistance for remote recoverability.** For MSP fleets managed primarily via Intune with no guaranteed local-hands access, default new deployments to `RunAsPPL=2` (no lock). Reserve `1` for clients with an explicit, documented security requirement and an accepted recovery process.

- **Smart App Control and LSA Protection audit logging interact in a non-obvious way.** Smart App Control suppresses the very audit events (3065/3066) you'd use to test LSA Protection safely — always check its state first when an audit-mode investigation turns up nothing.

- **Debugging is a dead end once protection is active — plan around it, don't fight it.** No supported debugger can attach to a PPL-protected `lsass.exe`. When a vendor asks you to attach a debugger for LSASS-related diagnostics, the options are: get their signed diagnostic tooling, or temporarily and explicitly disable protection with documented client sign-off.
