# Controlled Configuration — Hotfix Runbook (Mode B: Ops)
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

Run on the affected device (elevated PowerShell):

```powershell
# 1 — Current Controlled Configuration / Tamper Protection state
Get-MpComputerStatus | Select-Object ControlledConfigurationState, IsTamperProtected, TamperProtectionSource

# 2 — AV platform version (must be 4.18.26060.3004+ / June 2026 or later)
Get-MpComputerStatus | Select-Object AMProductVersion, AMEngineVersion

# 3 — Sense sensor build (must be later than 10.8804 / Sept 2025)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection" -Name SenseVersion -EA SilentlyContinue

# 4 — MDE onboarding + management channel
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -EA SilentlyContinue |
    Select-Object OnboardingState, OrgId
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender" -EA SilentlyContinue |
    Select-Object *Tamper*, *Controlled*

# 5 — Co-management check (Controlled Configuration does NOT support ConfigMgr+Intune co-management)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM" -EA SilentlyContinue | Select-Object -ExpandProperty PSPath -EA SilentlyContinue
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `ControlledConfigurationState` absent/blank on an otherwise healthy device | AV platform or Sense build below the floor — feature can't activate | Fix 1 |
| `IsTamperProtected = True` but `ControlledConfigurationState` shows Off | Policy still set to legacy **Tamper Protection (On)**, not migrated | Fix 2 |
| Device is co-managed (ConfigMgr + Intune) | Not supported — Controlled Configuration has no effect here | Fix 3 |
| Intune shows Success but GPO/local exclusion still visibly applies | Local admin merge is enabled in policy — expected, not a bug | Fix 4 |
| Intune reports "Conflict" for Controlled Configuration | Two Windows Security Experience policies target the device with different values | Fix 5 |
| Need to fully undo Controlled Configuration on one device (troubleshooting) | Local reset via MpCmdRun, requires troubleshooting mode | Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
[Controlled Configuration (Device) — On]
    ├── Device onboarded to Microsoft Defender for Endpoint
    ├── Managed via Intune  OR  Defender for Endpoint security settings management
    │       └── NOT supported: ConfigMgr + Intune co-management
    │       └── NOT supported: GCC High
    ├── Windows 10 / Windows 11 / Windows Server 2019
    ├── Sense EDR sensor build > 10.8804 (September 2025)
    ├── Microsoft Defender Antivirus platform >= 4.18.26060.3004 (June 2026)
    └── Windows Security Experience policy: same setting slot as Tamper Protection
            └── Setting renamed "Controlled Configuration (Device)" once available
            └── Setting to On SUPERSEDES any Tamper Protection value on that device
                    — do not deploy both as separate policies for the same setting
```

**Controlled Configuration covers:** Defender Antivirus config (scan settings, exclusions,
updates), Attack Surface Reduction (ASR) policies, the Defender CSP/Policy CSP antivirus
surface, and local-admin-merge behavior for exclusions.

**Controlled Configuration does NOT cover:** Microsoft Defender Device Control, EDR
settings, or Windows OS settings such as Firewall — those remain governed by their own,
separate management channels regardless of this feature's state.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the device meets the version floor**
```powershell
Get-MpComputerStatus | Select-Object AMProductVersion
# Must be 4.18.26060.3004 or later
```
Below the floor: Intune may report **Controlled Configuration (On)** delivered while the
device actually only applies the legacy Tamper Protection value — leaving BOTH controlled
configuration and tamper protection effectively off. This is a documented behavior, not a
delivery failure.

**Step 2 — Confirm the enforcement state on-device**
```powershell
Get-MpComputerStatus | Select-Object ControlledConfigurationState, IsTamperProtected, TamperProtectionSource
```

**Step 3 — Confirm which portal to trust for this device**
- Enrolled directly via Intune MDM → check the **Intune admin center** (policy status: Success/Conflict/Error, device-level state).
- Managed via **Defender for Endpoint security settings management** (not Intune-enrolled) → these devices are **not visible in Intune reports** — check the **Microsoft Defender portal** for effective configuration state instead.

**Step 4 — Check for a false conflict**
```powershell
# Look for BOTH a Tamper Protection policy and a Controlled Configuration policy
# targeting the same device — this is a known source of a reported "Conflict"
# even when the intended value (On) is still correctly enforced (On beats Off).
```
Controlled Configuration uses **value-based precedence**, not last-write-wins: if multiple
policies disagree, **On always wins** over Off, and a conflict is still logged for
visibility even though enforcement is correct.

**Step 5 — Confirm local-admin-merge behavior is intentional**
If local exclusions still appear to apply, check whether the Windows Security Experience
policy has **local administrator merge** enabled — Controlled Configuration blocks local
exclusions by default, but an admin can explicitly opt to merge locally defined exclusions
with centrally managed ones.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Device below the AV platform / Sense build floor</summary>

Controlled Configuration silently degrades to a broken half-state (both Controlled
Configuration and Tamper Protection effectively off) on down-level devices rather than
failing loudly.

1. Update the Defender Antivirus platform:
   ```powershell
   & "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -SignatureUpdate
   # Platform updates ride security intelligence updates; confirm current version:
   Get-MpComputerStatus | Select-Object AMProductVersion
   ```
2. Confirm Sense sensor build via Windows Update / Intune-delivered sensor update.
3. Re-sync the device and re-check `ControlledConfigurationState`.

**Do not roll Controlled Configuration out tenant-wide until a pilot group confirms every
device meets both floors** — see `-A.md` Remediation Playbooks for a staged rollout.
</details>

<details>
<summary>Fix 2 — Policy still set to legacy Tamper Protection (On), not migrated</summary>

Controlled Configuration and Tamper Protection **share the same policy setting slot**.
Setting Controlled Configuration to On on a Windows Security Experience profile
automatically supersedes a Tamper Protection value for that device — but if the profile
still literally says **Tamper Protection (On)**, the device only gets classic Tamper
Protection, not the expanded Controlled Configuration surface.

1. Intune admin center > **Endpoint security** > **Antivirus** (or **Attack surface
   reduction** > Windows Security Experience profile).
2. Open the profile targeting this device.
3. Locate **Controlled Configuration (Device)** (this is the renamed Tamper Protection
   setting once Controlled Configuration is available in the tenant).
4. Set to **Controlled Configuration (On)**.
5. Remove/retire any separate legacy DCv1 (Tamper Protection) policy setting this same
   value for the same device — do not run both.
6. Assign, sync, and re-verify with `Get-MpComputerStatus`.

**Rollback:** change the value back to **Tamper Protection (On)**, redeploy, sync, and
confirm `IsTamperProtected = True` with normal delivery latency.
</details>

<details>
<summary>Fix 3 — Device is co-managed (ConfigMgr + Intune)</summary>

Controlled Configuration explicitly **does not currently support co-management**
environments. A policy that reports Success in Intune may still have no real effect on a
co-managed device.

- Do not treat this as a bug or a delivery failure — it is a documented product gap.
- Use classic **Tamper Protection** on co-managed devices instead until Microsoft extends
  Controlled Configuration support to co-management (check the Learn page for updates
  before re-attempting).
- If the workload authority for Endpoint Protection has already been shifted to Intune,
  confirm that shift didn't create the false impression that the device is Intune-only —
  check `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM"` for a live ConfigMgr client.
</details>

<details>
<summary>Fix 4 — Local exclusions still applying (local admin merge)</summary>

This is expected behavior when the policy author explicitly enabled it — not a
Controlled Configuration failure.

1. Confirm intent: Intune > Windows Security Experience profile > check the **local
   administrator merge** setting for exclusions.
2. If merge was enabled unintentionally, disable it in the profile — locally defined
   exclusions will then be ignored again, matching default Controlled Configuration
   behavior (no local exclusions honored).
3. If merge is intentional (e.g., a pilot group still needs a local exclusion for a
   legacy tool), document it — this is a supported, deliberate exception path, not a
   security regression to "fix."
</details>

<details>
<summary>Fix 5 — Intune reports "Conflict" for Controlled Configuration</summary>

1. Identify every Windows Security Experience / Endpoint Security Antivirus policy
   targeting this device or its groups.
2. Look for **two policies asserting different values** (On vs. Off, or On vs. Not
   configured) for the same setting.
3. Remember: **On always wins** at the device regardless of the conflict report — the
   conflict flag is a visibility signal, not evidence of a broken device.
4. Consolidate to a single authoritative policy per device/group to clear the reported
   conflict cleanly, rather than relying on precedence to mask overlapping assignments.

> **Note:** Not configured is not the same as Off. If the goal is to actually disable
> Controlled Configuration, a policy must explicitly set the value to **Off** — leaving it
> Not configured elsewhere does not accomplish that.
</details>

<details>
<summary>Fix 6 — Local reset (troubleshooting only)</summary>

Requires the device to have Tamper Protection turned on and be in **troubleshooting
mode** first — see [Get started with troubleshooting mode](https://learn.microsoft.com/en-us/defender-endpoint/enable-troubleshooting-mode).

Elevated Command Prompt:
```dos
(set "_done=" & if exist "%ProgramData%\Microsoft\Windows Defender\Platform\" (for /f "delims=" %d in ('dir "%ProgramData%\Microsoft\Windows Defender\Platform" /ad /b /o:-n 2^>nul') do if not defined _done (cd /d "%ProgramData%\Microsoft\Windows Defender\Platform\%d" & set _done=1)) else (cd /d "%ProgramFiles%\Windows Defender")) >nul 2>&1

MpCmdRun.exe -Config -ResetControlledConfiguration
```

**Rollback / re-establish:** re-sync the device against its Intune/Defender-managed
policy — Controlled Configuration re-applies automatically on next policy evaluation.

> ⚠️ This is a local, device-scoped reset. It does not change the tenant policy — if the
> policy still says On, expect the device to re-enable Controlled Configuration shortly
> after reset unless troubleshooting mode is still active.
</details>

---

## Escalation Evidence

```
=== CONTROLLED CONFIGURATION ESCALATION ===
Date/Time      :
Engineer       :
Ticket         :

Device Name        :
OS Version          :
MDE Onboarded        : (Yes/No — OnboardingState reg value)
Management channel   : (Intune MDM / Defender for Endpoint security settings mgmt / Co-managed)

AMProductVersion (AV platform)  : (must be >= 4.18.26060.3004)
Sense sensor build (SenseVersion): (must be > 10.8804)

ControlledConfigurationState : (from Get-MpComputerStatus)
IsTamperProtected            :
TamperProtectionSource       :

Intune policy name             :
Intune-reported status         : (Success / Conflict / Error)
Defender portal effective state (if DfE-SSM managed):

Local admin merge enabled?     : (Yes/No — from policy)
Co-management present?         : (Yes/No — CCM client check)

Steps Attempted:
1.
2.
3.

Expected behaviour : [describe intended configuration]
Actual behaviour   : [describe what is blocked, missing, or conflicting]
```

---

## 🎓 Learning Pointers

- **Controlled Configuration is a superset of Tamper Protection, not a separate add-on
  policy** — they share the same setting slot, and Intune literally renames the field
  once the tenant has access to the feature. Deploying both as distinct policy objects for
  the same device is a modeling mistake, not a supported layered configuration. [Controlled configuration in Microsoft Defender for Endpoint](https://learn.microsoft.com/en-us/defender-endpoint/secure-controlled-configuration)
- **"Not configured" is not "Off."** To actually disable Controlled Configuration, deploy
  a policy that explicitly sets the value to Off — an absent setting elsewhere does not
  achieve that, since secure defaults fill any unconfigured setting.
- **The value-based conflict model favors On over Off by design.** A "Conflict" status in
  Intune does not necessarily mean the device is unprotected — it means visibility into a
  policy authoring problem that should still be cleaned up, even though enforcement itself
  is already correct.
- **Co-management and GCC High are explicit, current gaps**, not misconfigurations to
  troubleshoot around. Confirm the device's management model before spending time on this
  feature at all.
- **Down-level AV platform/Sense builds fail silently into a worse state** — both
  Controlled Configuration and Tamper Protection end up off, which is worse than doing
  nothing. Always gate rollout on the version floor first (see `-A.md` for a phased
  rollout playbook and `Get-ControlledConfigurationAudit.ps1` for a fleet-wide readiness
  check).
- **Reporting lives in two different places depending on management channel** — Intune
  admin center for MDM-enrolled devices, the Microsoft Defender portal for
  Defender-for-Endpoint-security-settings-management-only devices. Checking the wrong
  portal for a given device is a very easy false "no data" dead end.
