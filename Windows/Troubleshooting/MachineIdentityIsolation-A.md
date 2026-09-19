# Machine Identity Isolation & Domain Trust (Sept 2026 CU) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why Credential Guard-protected machine accounts break domain trust after the September 2026 cumulative updates, not just what to click.

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

**In scope:**
- Machine Identity Isolation, a Virtualization-Based Security (VBS)/Credential Guard feature that moves a domain-joined machine account's secret into an isolated, hardware-protected environment
- Why the September 2026 cumulative updates (`KB5124008` for Windows 11 24H2/25H2, `KB5124012` for Windows 11 26H1) caused previously dormant configurations of this feature to start being enforced, breaking domain authentication on affected devices
- The Domain Functional Level (DFL) support boundary Microsoft has published for this feature
- The three provisioning paths (Intune policy CSP, Group Policy, direct registry) and why the removal method must match the provisioning method
- Recovery paths, including the documented risk that disabling the feature after enforcement can itself require a full domain unjoin/rejoin

**Out of scope:**
- Credential Guard fundamentals unrelated to machine accounts specifically (user credential isolation, LSA protection generally) — assumed baseline knowledge
- Delegated Managed Service Accounts (dMSA), which share some Windows Server 2025 AD infrastructure but are a distinct feature from machine account identity isolation
- Non-Windows (Entra-joined-only, Azure AD DS, hybrid Entra Connect) authentication models — this document covers on-premises AD domain-joined secure channel behavior only

**Assumptions:**
- Windows 11, version 24H2, 25H2, or 26H1, domain-joined to an on-premises Active Directory forest
- Reader has AD administration rights (to check/change Domain Functional Level context, though raising DFL itself is out of scope here) and either GPO or Intune policy administration rights
- **Source-confidence note:** this is an **actively unfolding issue** as of this writing (September 2026). Microsoft has confirmed the trigger and published a workaround (2026-09-17) but has *not* published a permanent fix, and has not fully confirmed every community-reported detail (e.g., some administrators report the feature is only meaningfully exposed in Windows Server 2025-introduced AD tooling, which the community has linked to Delegated Managed Service Account infrastructure). Treat root-cause specifics as the best available synthesis of Microsoft's own release-health statement plus corroborating field reports, and re-check the [Windows release health dashboard](https://learn.microsoft.com/en-us/windows/release-health/) before treating any workaround here as final.

---
## How It Works

<details><summary>Full architecture</summary>

### The classic machine-account secure channel model

Every domain-joined Windows computer has a machine account in Active Directory (`COMPUTERNAME$`) with its own password, rotated automatically on a schedule (default ~30 days). The device authenticates to a domain controller using this password to establish a "secure channel" — the trust relationship that lets the device validate user logons, apply Group Policy, and participate in Kerberos authentication generally. Historically, the device's copy of this secret lives in the Local Security Authority (LSA) process space on the machine, alongside other credential material.

### What Machine Identity Isolation changes

Machine Identity Isolation is a Virtualization-Based Security (VBS) feature, delivered as part of the Credential Guard family, that isolates the machine account secret from the normal LSA process space:

```
Classic model                          Machine Identity Isolation (enforcement)
──────────────                         ─────────────────────────────────────────
Machine secret lives in LSA            Machine secret moved INTO Credential Guard
(normal kernel-mode process             (VBS-isolated, hypervisor-protected
 space, same as other creds)            container — isolated even from the OS
                                         kernel itself)
        │                                       │
        ▼                                       ▼
Any process/attacker that              LSA copy of the secret is DELETED once
compromises LSA can potentially        enforcement completes — there is no
read/abuse the machine secret          fallback copy in the normal OS if
                                        Credential Guard cannot service it
```

This is the same architectural pattern Credential Guard already uses for user credentials (NTLM hashes, Kerberos TGTs) — extended here to cover the machine account's own secret. The isolation is a genuine security improvement: it removes a class of attack where malware running as SYSTEM reads the machine secret out of LSA to impersonate the device or forge machine-authenticated traffic.

### The three enforcement states

The feature is controlled by a `MachineIdentityIsolation` DWORD value, understood (per community and Microsoft documentation cross-referencing) to support at minimum:

| Value | State | Behavior |
|-------|-------|----------|
| `0` | Disabled | Classic LSA-resident machine secret; no isolation |
| (audit value not conclusively confirmed in current public documentation — treat as unconfirmed) | Audit | Reports readiness/compatibility without isolating the secret |
| `2` | Enforcement | Secret moved into Credential Guard; LSA copy deleted |

The setting can be provisioned through three independent mechanisms, which do **not** always agree with each other and must be removed through the same mechanism used to apply them:

1. **Group Policy** — Device Guard/Credential Guard policy settings under Computer Configuration.
2. **Intune policy CSP** — `DeviceGuard/MachineIdentityIsolation`, delivered via a Settings Catalog or custom OMA-URI profile, written to `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard\MachineIdentityIsolation` on the device.
3. **Direct registry** — `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\MachineIdentityIsolation`, typically only present when set locally/manually rather than through policy, or as the effective value the LSA subsystem reads once policy has been applied.

### Why the September 2026 CU is the trigger, not the cause

This is the detail most likely to confuse a first responder: **the September 2026 cumulative update does not itself turn Machine Identity Isolation on.** Per Microsoft's own release-health statement: *"the update does not directly enable Machine Identity Isolation enforcement, [but] it does cause Windows to begin honoring any existing or policy-provisioned settings that enabled Machine Identity Isolation enforcement."*

The timeline that makes this confusing in the field:

```
Some point before April 2026:  Org configures MachineIdentityIsolation = 2
                                (GPO, Intune, or registry) — feature works
                                as intended, or is silently misconfigured
                                     │
April 2026 (KB5055523):        Microsoft TEMPORARILY DISABLES Credential
                                Guard protected machine accounts tenant-
                                wide, due to an unrelated Kerberos machine-
                                password-rotation bug — the org's setting
                                is still "2" in the registry/policy, but
                                has NO EFFECT while this disablement is active
                                     │
                                (org sees no problems for ~5 months —
                                 the dormant setting is invisible)
                                     │
September 2026 (KB5124008/     Windows resumes honoring the dormant
KB5124012):                    setting. Any device with MachineIdentity-
                                Isolation = 2 in either registry location
                                begins enforcing on next reboot.
                                     │
                                     ▼
                                Devices with healthy VBS/Credential Guard
                                AND DCs at Server 2025 DFL: works as
                                designed, no visible problem
                                     │
                                Devices below Server 2025 DFL, or with
                                any VBS/Credential Guard health issue:
                                secure channel fails after reboot
```

This is why an organization can report "we never touched this setting recently" and be entirely correct — the actual configuration decision may be many months old.

### The DFL support boundary

Microsoft's official statement (via the release-health dashboard, quoted in [Microsoft's 2026-09-17 guidance](https://www.bleepingcomputer.com/news/microsoft/microsoft-releases-workaround-for-windows-domain-login-authentication-issues/)):

> "this feature is only supported for environments connected to domain controllers running at a Windows Server 2025 Domain Functional Level (DFL) and above. The feature should be disabled elsewhere."

Raising a production domain's functional level to Windows Server 2025 is a significant, deliberate AD change most organizations have not made (it requires every DC in the domain/forest to be running Windows Server 2025 first). In practice, this means **most MSP-managed domains are currently in the unsupported bucket** and should have this feature disabled outright rather than worked around per-device, unless the client has already modernized their DC estate.

</details>

---
## Dependency Stack

```
Windows Server 2025 Domain Functional Level (REQUIRED for supported operation)
        ▲
        │ (most production domains are currently BELOW this line)
        │
Domain Controllers reachable, Kerberos/Netlogon healthy
        ▲
Machine account object present, enabled, password in sync in AD
        ▲
VBS (Virtualization-Based Security) + Credential Guard functional on the device
  (requires: UEFI, Secure Boot, virtualization extensions enabled in firmware,
   HVCI compatible drivers — same prerequisites as any Credential Guard feature)
        ▲
MachineIdentityIsolation policy value = 2 (enforcement), from ONE of:
  Group Policy | Intune policy CSP | direct registry
        ▲
September 2026 CU (KB5124008 / KB5124012 or later) installed — the trigger
that makes Windows begin honoring the value above
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "The trust relationship between this workstation and the primary domain failed" after a September 2026 patch Tuesday reboot | Machine Identity Isolation enforcement activated on an unsupported (sub-2025-DFL) domain | `Get-ItemProperty` on both registry paths (Command Cheat Sheet) |
| Valid domain credentials rejected, but the same account logs in fine via cached/offline credentials | Secure channel broken specifically, not a real password problem — consistent with this issue | Attempt an offline logon; compare to online logon failure |
| Kerberos authentication failures in the event log, followed by NTLM/Netlogon fallback attempts | Machine secret unavailable to the normal auth stack because it now lives only in Credential Guard, which failed to service the request | `Get-WinEvent` filtered to Netlogon/Kerberos provider |
| Problem reproducible: uninstalling the September CU restores access, reinstalling it breaks access again | Confirms the CU is the proximate trigger (not a coincidental unrelated AD problem) | Compare `Get-HotFix` history against symptom onset timestamp |
| Disabling Machine Identity Isolation made things *worse*, not better | Feature was already in enforcement mode and the LSA-resident secret had already been deleted; toggling to disabled without a secure-channel repair can leave the device with no usable copy of its own secret at all | Follow the [Post-Disable Break](#post-disable-domain-unjoinrejoin) remediation playbook, not a plain policy flip |
| Only a subset of devices in the same OU/policy scope are affected | Uneven Credential Guard/VBS health across the fleet (firmware settings, HVCI driver compatibility) rather than the policy itself | Compare `DG_ReadinessTool` or `msinfo32` Device Guard output across affected vs. unaffected devices |
| Fleet was fine for ~5 months, broke suddenly in September with no recent policy change | Dormant setting from before April 2026's temporary tenant-wide disablement (`KB5055523`) resumed being honored | Check GPO/Intune policy **version history**, not just recent edits |

---
## Validation Steps

1. **Confirm the trigger CU is installed.**
   ```powershell
   Get-HotFix -Id KB5124008,KB5124012 -ErrorAction SilentlyContinue
   ```
   Good: one of these IDs present with `InstalledOn` matching the symptom onset date. Bad/inapplicable: neither present — this is a different trust-failure cause.

2. **Read both possible registry locations for the enforcement value.**
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' -Name MachineIdentityIsolation -ErrorAction SilentlyContinue
   Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name MachineIdentityIsolation -ErrorAction SilentlyContinue
   ```
   Good (explains the symptom): either returns `2`. Bad (rules this out): both absent or `0` — the device was never configured for enforcement.

3. **Confirm the domain's functional level.**
   ```powershell
   Get-ADDomain | Select-Object Name, DomainMode
   ```
   Good (feature is supported here, just needs a secure-channel repair): `Windows2025Domain` or higher. Bad (feature must be disabled, not repaired around): anything lower — this is the common case.

4. **Confirm VBS/Credential Guard health on the device itself**, since a healthy-but-unsupported-DFL device and an unhealthy-VBS device need different remediation:
   ```powershell
   Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard |
       Select-Object SecurityServicesRunning, VirtualizationBasedSecurityStatus
   ```
   Good: `VirtualizationBasedSecurityStatus = 2` (running) and Credential Guard listed in `SecurityServicesRunning`. Bad: VBS not running — the isolation feature cannot function correctly regardless of DFL, and the fix is a VBS/firmware health issue, not a policy toggle.

5. **After remediation, confirm the secure channel is genuinely restored** (not just that the repair command returned success):
   ```powershell
   Test-ComputerSecureChannel
   nltest /sc_verify:<domainname>
   ```
   Good: both report a healthy, verified secure channel. Bad: `Test-ComputerSecureChannel` returns `False` or `nltest` reports an error code — proceed to the unjoin/rejoin playbook.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm scope.** Is this one device or fleet-wide? Check whether the affected devices share a common GPO/Intune policy scope, OU, or deployment ring. A fleet-wide break from a single patch ring is a strong signal to **pause the update rollout ring** before touching individual machines — see Remediation Playbook 3.

**Phase 2 — Classify: supported-but-broken vs. unsupported-and-enforcing.** Run Validation Steps 3 and 4. This single fork decides whether the correct fix is "repair the channel" (supported DFL, just needs `Test-ComputerSecureChannel -Repair`) or "disable the feature" (unsupported DFL, per Microsoft's own guidance).

**Phase 3 — Identify the provisioning source before changing anything.** A value under `HKLM:\SOFTWARE\Policies\...` came from GPO or Intune; editing the registry directly will not survive the next policy refresh. Check `gpresult /h` or the Intune device configuration profile assignment for the device to find the actual source policy to edit.

**Phase 4 — Remediate via the source mechanism**, then reboot, then repair the secure channel (Remediation Playbook 1). Do not skip the explicit repair step — disabling the setting alone does not retroactively restore a machine secret that Credential Guard has already deleted from LSA.

**Phase 5 — If repair fails, escalate to unjoin/rejoin** (Remediation Playbook 2) rather than repeatedly retrying the repair command — Microsoft's own documentation states this outcome is expected in some cases once enforcement has already taken effect, not a sign the repair command was used incorrectly.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Disable Machine Identity Isolation and Repair (single device, unsupported DFL)</summary>

```powershell
# Only if the value is provisioned DIRECTLY in the registry (no GPO/Intune managing it —
# confirmed via gpresult/Intune profile check in Phase 3). If policy-managed, edit the
# SOURCE policy instead and let it sync — do not hand-edit a policy-managed device.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name MachineIdentityIsolation -Value 0 -Type DWord
Restart-Computer -Wait -For PowerShell -Timeout 300

# After reboot:
Test-ComputerSecureChannel -Repair -Credential (Get-Credential)
```

**Rollback:** re-enabling the setting afterward (`MachineIdentityIsolation = 2`) is safe only once the domain is confirmed at Windows Server 2025 DFL — do not re-enable purely to "undo" this playbook on an unsupported domain, as that reintroduces the original failure.

</details>

<details><summary>Playbook 2 — Post-Enforcement Unjoin/Rejoin (repair command failed)</summary>

```powershell
# 1. Confirm a working local administrator account exists on the device first
Get-LocalGroupMember -Group 'Administrators'

# 2. Unjoin from the domain
Remove-Computer -UnjoinDomainCredential (Get-Credential) -PassThru -Verbose -Restart

# 3. After reboot to workgroup mode, rejoin
Add-Computer -DomainName '<yourdomain.com>' -Credential (Get-Credential) -Restart

# 4. Post-rejoin validation
Test-ComputerSecureChannel
```

**Rollback:** none applicable — this playbook IS the recovery path. If no local admin account is reachable and remote management is also broken (common on a device that just lost domain trust), the device may need physical/KVM access, a break-glass local admin credential (LAPS, if deployed), or re-imaging/Autopilot re-enrollment as a last resort.

</details>

<details><summary>Playbook 3 — Fleet-Wide: Pause Rollout Ring and Bulk-Remediate via Policy</summary>

```powershell
# Identify all devices in the affected policy scope with the September CU installed
# (run against a CMPivot/Intune-managed reporting source or a domain-wide script sweep;
# shown here as a single-device pattern to run at scale via your RMM/Intune Remediation)
Get-HotFix -Id KB5124008,KB5124012 -ErrorAction SilentlyContinue |
    Select-Object @{n='Device';e={$env:COMPUTERNAME}}, HotFixID, InstalledOn
```

Then:
1. Pause further rollout of the September CU to unaffected rings if the domain is confirmed below Windows Server 2025 DFL and Machine Identity Isolation is configured anywhere in scope.
2. Push the policy-level disable (GPO or Intune Settings Catalog/OMA-URI) to the affected scope — this remediates future check-ins automatically rather than requiring a per-device touch.
3. For already-broken devices, use Playbook 1 or 2 per device — the policy push alone does not repair an already-broken secure channel.

**Rollback:** resuming the paused rollout ring is safe once the policy-level disable has been confirmed applied fleet-wide, or once the domain has been raised to Windows Server 2025 DFL.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only evidence collector for Machine Identity Isolation domain trust failures
    (September 2026 CU known issue). Gathers everything needed for an escalation
    package or a fleet-wide impact assessment in a single pass.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\Temp\MII-Evidence'
)

if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

$evidence = [ordered]@{
    ComputerName        = $env:COMPUTERNAME
    OSVersion           = (Get-ComputerInfo).OsVersion
    OSBuild              = (Get-ComputerInfo).OsBuildNumber
    TriggerCU           = (Get-HotFix -Id KB5124008,KB5124012 -ErrorAction SilentlyContinue |
                                Select-Object HotFixID, InstalledOn)
    PolicyValue         = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' `
                                -Name MachineIdentityIsolation -ErrorAction SilentlyContinue).MachineIdentityIsolation
    LocalValue          = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
                                -Name MachineIdentityIsolation -ErrorAction SilentlyContinue).MachineIdentityIsolation
    DomainFunctionalLvl = $(try { (Get-ADDomain).DomainMode } catch { 'Unable to query - RSAT/AD module unavailable' })
    VBSStatus           = (Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard `
                                -ErrorAction SilentlyContinue |
                                Select-Object SecurityServicesRunning, VirtualizationBasedSecurityStatus)
    SecureChannelHealthy = $(try { Test-ComputerSecureChannel } catch { 'Error running check' })
    RecentNetlogonEvents = (Get-WinEvent -LogName System -MaxEvents 100 -ErrorAction SilentlyContinue |
                                Where-Object { $_.ProviderName -eq 'Netlogon' } |
                                Select-Object TimeCreated, Id, LevelDisplayName, Message)
}

$evidence | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutputPath "MII-Evidence-$($env:COMPUTERNAME)-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
Write-Host "Evidence written to $OutputPath" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-HotFix -Id KB5124008,KB5124012` | Confirm the triggering CU is installed |
| `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' -Name MachineIdentityIsolation` | Read policy-provisioned enforcement value |
| `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name MachineIdentityIsolation` | Read local/effective enforcement value |
| `(Get-ADDomain).DomainMode` | Confirm Domain Functional Level (support boundary is Windows Server 2025) |
| `Get-CimInstance Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard` | Check VBS/Credential Guard runtime health |
| `Test-ComputerSecureChannel` | Read-only secure channel health check |
| `Test-ComputerSecureChannel -Repair -Credential (Get-Credential)` | Attempt in-place secure channel repair |
| `nltest /sc_verify:<domain>` | Verify secure channel status against a specific domain |
| `gpresult /h C:\Temp\gpresult.html` | Identify whether the setting is GPO-provisioned |
| `gpupdate /force` | Force policy refresh after a GPO-side fix |
| `Remove-Computer -UnjoinDomainCredential (Get-Credential) -PassThru -Restart` | Unjoin domain (last-resort recovery) |
| `Add-Computer -DomainName '<domain>' -Credential (Get-Credential) -Restart` | Rejoin domain after unjoin |
| `Get-WinEvent -LogName System \| Where-Object ProviderName -eq 'Netlogon'` | Review Netlogon failure detail |
| `Get-ADComputer $env:COMPUTERNAME -Properties Enabled` | Confirm the computer object itself is intact in AD |

---
## 🎓 Learning Pointers

- Machine Identity Isolation is the machine-account equivalent of a pattern Credential Guard already applies to user credentials — understanding the user-credential isolation model (already covered elsewhere in this repo's Credential Guard-adjacent content) transfers directly to reasoning about this feature.
- The single most important fact for triage speed: **this CU did not turn the feature on — it made Windows start honoring a setting that may have been configured months earlier.** Always check policy *history*, not just recent changes, when a client insists "nothing changed."
- Microsoft's DFL support boundary (Windows Server 2025 DFL and above) means most MSP-managed domains are currently unsupported for this feature by design — treat "disable it" as the default correct answer for typical clients, and "repair the channel" as the exception reserved for organizations that have already modernized their DC estate.
- This is a live, still-evolving Microsoft known issue as of this writing — re-check the [Windows release health dashboard](https://learn.microsoft.com/en-us/windows/release-health/) before treating the registry workaround as a permanent configuration decision; Microsoft has stated a future update will address it directly.
- The September 2026 CU wave also shipped emergency out-of-band fixes for unrelated issues (Remote Desktop Services failures, Hyper-V Linux VM folder shares, USB audio) — do not assume every post-patch ticket this month is this issue; confirm via the specific symptom (trust-relationship error, not audio/RDS/Hyper-V) before applying this runbook.
- Source: [Microsoft Learn — Credential Guard protected machine accounts](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/delegated-managed-service-accounts/credential-guard-protected-machine-accounts); [BleepingComputer — Windows 11 KB5124008 update breaks domain trust for some users](https://www.bleepingcomputer.com/news/microsoft/windows-11-kb5124008-update-breaks-domain-trust-for-some-users/); [BleepingComputer — Microsoft shares workaround for Windows domain login issues](https://www.bleepingcomputer.com/news/microsoft/microsoft-releases-workaround-for-windows-domain-login-authentication-issues/).
