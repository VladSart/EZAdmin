# Controlled Configuration — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Controlled Configuration** in Microsoft Defender for Endpoint — a
Preview configuration-enforcement model that makes cloud-managed policy (Intune or
Defender for Endpoint security settings management) the single source of truth for the
entire Microsoft Defender Antivirus configuration surface, overriding Group Policy,
Configuration Manager, local scripts, and local admin changes. Source: Microsoft Learn,
last updated 2026-07-30. The feature is explicitly labeled Preview, not available in all
organizations, and subject to change.

Assumes: an MDE-onboarded Windows fleet managed via Intune and/or Defender for Endpoint
security settings management, considering adoption of Controlled Configuration in place of
(or as a superset of) classic Tamper Protection. Does **not** cover: classic Tamper
Protection troubleshooting on a device that has not adopted Controlled Configuration (see
`Tamper-Protection-A.md`/`-B.md`), Microsoft Defender Device Control, EDR settings, or
Windows Firewall/OS-level settings — none of which are covered by this feature regardless
of its state on a device.

**Why this exists:** Tamper Protection has always protected a small, fixed set of critical
security toggles (roughly 10-13 settings) against being disabled by anyone other than
Microsoft's own defaults. That narrow scope leaves a large surface — scan schedules,
exclusions, ASR rule assignments, update behavior — still reachable by GPO, Configuration
Manager, third-party RMM scripts, and local admins, any of which can silently diverge from
the policy an organization actually intends. Controlled Configuration closes that gap by
extending tamper-protection-style, cloud-policy-wins enforcement to the *entire* Defender
Antivirus configuration surface, eliminating configuration drift rather than just blocking
a short list of high-value toggles.

---
## How It Works

<details><summary>Full architecture</summary>

**Relationship to Tamper Protection** — Controlled Configuration is a strict superset,
not a parallel feature:

| Aspect | Tamper Protection | Controlled Configuration |
|---|---|---|
| Scope | ~10-13 fixed security settings | Entire Defender Antivirus configuration surface |
| Configuration source | Microsoft-defined defaults only | Organization-defined cloud policy (Intune/MDE-SSM) |
| Customization | None | Full policy-driven control |
| Enforcement | Prevents disabling critical protections | Overrides *all* non-cloud configuration channels |

Both can technically be enabled simultaneously, but Microsoft explicitly recommends
choosing one or the other for a given device — because they share the same underlying
policy setting slot (see below), running both as separately authored policies invites the
exact conflict-reporting confusion this runbook's Mode B addresses.

**Policy delivery model** — Controlled Configuration is configured through the *same*
policy surface as Tamper Protection: the Windows Security Experience profile. Once a
tenant has access to the feature, Intune renames the Tamper Protection setting to
**Controlled Configuration (Device)**. Setting this to **Controlled Configuration (On)**
supersedes any Tamper Protection value already applied to that device — organizations do
not deploy separate Tamper Protection and Controlled Configuration policies targeting the
same setting. Controlled Configuration is **not** configurable via the Settings Catalog or
the legacy Device Control v1 (DCv1) template.

**Migration note:** to move an existing Tamper-Protection-managed fleet to Controlled
Configuration, create a *new* Windows Security Experience policy with **Controlled
Configuration (On)**, then remove the Tamper Protection setting from the old DCv1 policies
to avoid the two colliding on the same device.

**Enforcement mechanics — three layers:**

1. **Single-source enforcement.** Only Intune and Defender for Endpoint security settings
   management policies are honored for Defender Antivirus settings once Controlled
   Configuration is On; Group Policy, scripts, Configuration Manager, and local admin
   changes are all ignored. Local exclusions specifically are not honored by default —
   organizations can opt back in per-policy via a **local administrator merge** setting,
   which causes locally defined exclusions to merge with (not replace) centrally managed
   ones.
2. **Secure defaults.** Any setting not explicitly configured in policy falls back to a
   Microsoft-defined default rather than an undefined/ignored state — this keeps devices
   at a strong baseline even when an admin hasn't touched every available setting.
3. **Conflict resolution — value-based precedence, not last-write-wins.** If multiple
   policies assign different values for the same setting, **On always wins over Off** —
   the feature stays enabled on the device even in a genuine authoring conflict, and the
   conflict is still surfaced for visibility. If multiple policies assign the *same*
   value, the result is simply Success, no conflict. Critically, **Not configured is not
   the same as Off** — disabling the feature requires a policy that explicitly sets the
   value to Off; leaving it unconfigured elsewhere never disables it.

**Coverage boundary** — Controlled Configuration currently covers Antivirus configuration
(scan settings, exclusions, updates), ASR policies, the Defender CSP/Policy CSP antivirus
surface, and local-admin-merge behavior. It explicitly does **not** cover Microsoft
Defender Device Control, EDR settings, or Windows OS-level settings such as Firewall —
those remain under their existing, separate management/enforcement models no matter what
Controlled Configuration's state is.

</details>

---
## Dependency Stack

```
Layer 6:  Windows Security Experience policy setting = Controlled Configuration (On)
              ↑ requires (shares the same setting slot — do not deploy both)
Layer 5:  NOT set via legacy Tamper Protection (DCv1) policy for the same setting
              ↑ requires
Layer 4:  Management channel = Intune MDM  OR  Defender for Endpoint security settings
          management (NOT supported: ConfigMgr+Intune co-management; NOT supported: GCC High)
              ↑ requires
Layer 3:  Microsoft Defender Antivirus platform >= 4.18.26060.3004 (June 2026)
              ↑ requires
Layer 2:  Sense EDR sensor build > 10.8804 (September 2025)
              ↑ requires
Layer 1:  Device onboarded to Microsoft Defender for Endpoint, running Windows 10,
          Windows 11, or Windows Server 2019
```

Reading this stack top-down: a symptom at Layer 6 (device reports Off or reverts to
legacy Tamper Protection behavior) traces down through Layer 5 first (check for a
colliding DCv1 policy) before assuming a version-floor problem at Layers 2-3. A symptom
where Intune reports Success but the device silently behaves as if nothing changed is
almost always a Layer 2/3 version-floor miss — Microsoft documents this explicit
degradation mode (see Symptom → Cause Map).

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Intune reports Controlled Configuration (On) delivered, but device behaves as neither Controlled Configuration nor Tamper Protection | Device below the AM platform (4.18.26060.3004) or Sense build (10.8804) floor — documented silent-degradation behavior | `Get-MpComputerStatus \| Select AMProductVersion` |
| `ControlledConfigurationState` present but local exclusions still apply | Local administrator merge deliberately enabled in policy | Windows Security Experience profile — local admin merge setting |
| Reported "Conflict" status in Intune | Two policies assign different values for the same setting; On still wins at the device | Cross-reference every WSE/Antivirus policy target |
| Feature has no effect on a co-managed (ConfigMgr+Intune) device | Co-management not currently supported | Check for a live ConfigMgr client |
| No data for a device in Intune reports | Device is managed via Defender for Endpoint security settings management, not Intune MDM — those devices aren't visible in Intune reporting | Check the Microsoft Defender portal instead |
| Tamper Protection secure score dropped after enabling Controlled Configuration | Turning on Controlled Configuration via Intune/MDE-SSM turns Tamper Protection off unless another policy explicitly re-enables it — a currently acknowledged Microsoft gap | Confirm intent; expect a lower TP-based score until Microsoft resolves this |
| Device unenrolled from Defender for Endpoint but Controlled Configuration still shows On | Not cleaned up automatically on MDE unenrollment (documented lifecycle behavior) — distinct from full device offboarding, which does reset to Off | Confirm via `MpCmdRun.exe -Config -ResetControlledConfiguration` in troubleshooting mode if needed |

---
## Validation Steps

1. **Confirm prerequisites are met before enabling anything at scale.**
   - MDE onboarding: `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"`
   - OS: Windows 10/11 or Windows Server 2019 only.
   - AV platform: `Get-MpComputerStatus | Select AMProductVersion` >= 4.18.26060.3004.
   - Sense build: registry `SenseVersion` value > 10.8804.
   - Management model: confirm no active ConfigMgr co-management client, and confirm the
     tenant is not GCC High.

2. **Author the Windows Security Experience policy correctly.**
   Set **Controlled Configuration (Device)** to **Controlled Configuration (On)** — do
   not also leave a separate DCv1/Tamper Protection policy asserting a value for the same
   setting on the same device.

3. **Pilot before fleet-wide rollout.** Assign to a small device group first and allow
   normal policy delivery latency before validating.

4. **Validate on-device state.**
   ```powershell
   Get-MpComputerStatus | Select-Object ControlledConfigurationState, IsTamperProtected, TamperProtectionSource
   ```
   Good output: `ControlledConfigurationState` reflects the intended state; `IsTamperProtected = True` (Controlled Configuration is built on the Tamper Protection foundation).
   Bad output: `ControlledConfigurationState` blank/absent on a device Intune reports as
   Success — almost always a version-floor miss (see Symptom → Cause Map).

5. **Validate portal-side reporting matches the management channel.** Intune-enrolled
   (MDM) devices report into the Intune admin center (policy status + device-level
   state). Devices managed only through Defender for Endpoint security settings
   management report into the Microsoft Defender portal instead and are **not** visible in
   Intune's own reporting.

6. **Confirm conflict handling behaves as documented**, if a genuine multi-policy overlap
   exists: the device should still enforce On even when a Conflict is reported, since the
   feature uses value-based (On-wins) precedence rather than last-write-wins.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-rollout readiness**
- Inventory the fleet's AV platform and Sense build versions before authoring any
  Controlled Configuration policy — the silent degrade-to-neither-feature failure mode on
  down-level devices is the single most common source of "it says Success but nothing
  changed" tickets for this feature.
- Identify and exclude co-managed (ConfigMgr+Intune) and GCC High devices/tenants from the
  initial rollout scope — Controlled Configuration currently has no effect there.

**Phase 2 — Migration from existing Tamper Protection**
- Treat this as a genuine policy migration, not an additive change: build the new WSE
  policy with Controlled Configuration (On) first, validate on a pilot group, *then*
  remove the Tamper Protection setting from legacy DCv1 policies for the same devices —
  never run both simultaneously against the same setting on the same device.

**Phase 3 — Pilot validation**
- Confirm `ControlledConfigurationState` on-device for every pilot device individually —
  do not rely solely on the Intune policy-status column, since it can report Success even
  when the device applies only a degraded subset of the intended behavior.
- Deliberately test a local exclusion attempt and a GPO-based Defender setting change on a
  pilot device to confirm both are correctly ignored (unless local admin merge is
  intentionally enabled).

**Phase 4 — Fleet-wide rollout**
- Roll out in cohorts, re-running Validation Steps 4-5 against a sample of each cohort
  before proceeding to the next — this repo's standing practice for any tamper-adjacent,
  hard-to-reverse-without-a-maintenance-window Defender feature.

**Phase 5 — Ongoing operations**
- Any RMM/backup/third-party tool that previously relied on local exclusions or
  script-based Defender config changes will silently stop having effect once Controlled
  Configuration is On (unless local admin merge is explicitly enabled) — proactively audit
  and re-platform those tools onto Intune/MDE-SSM-delivered exclusions rather than waiting
  for a break/fix ticket.
- Expect a lower Tamper Protection secure-score contribution while Controlled
  Configuration is On and classic Tamper Protection is consequently Off — this is a
  currently acknowledged Microsoft gap, not a genuine security regression, and should be
  documented for anyone tracking Secure Score trend lines (see `SecureScore-A.md`).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrating a fleet from Tamper Protection to Controlled Configuration</summary>

1. Inventory AV platform + Sense build versions fleet-wide; remediate any device below the
   4.18.26060.3004 / 10.8804 floors before scoping this device into the rollout.
2. Exclude co-managed and GCC High devices from scope (not currently supported).
3. Create a new Windows Security Experience policy with **Controlled Configuration
   (Device) = On**. Do not edit the existing Tamper Protection policy in place yet.
4. Assign to a small pilot group only.
5. Validate per Validation Steps 4-6 above on every pilot device.
6. Once validated, remove the Tamper Protection setting from the legacy DCv1 policy for
   the pilot group's devices (or retarget the legacy policy away from them) to avoid a
   same-setting collision.
7. Expand assignment cohort-by-cohort, repeating validation on a sample each time.
8. Retire the legacy Tamper Protection policy once all in-scope devices have migrated.

**Rollback (per device or cohort):** change the Windows Security Experience policy value
back to **Tamper Protection (On)**, redeploy, sync affected devices, and verify
`IsTamperProtected = True` via `Get-MpComputerStatus`. Normal policy delivery latency
applies — this is not instantaneous.

</details>

<details><summary>Playbook 2 — Resolving a device stuck in a degraded/neither-feature state</summary>

1. Confirm the AV platform and Sense build versions on the affected device — this is the
   most common root cause.
2. If below floor, update via normal Defender platform/sensor update mechanisms and allow
   the update to complete before re-checking.
3. Re-sync the device against Intune/MDE-SSM policy.
4. Re-validate with `Get-MpComputerStatus`.
5. If still degraded after confirming version floors are met, use the local reset command
   (requires troubleshooting mode) to clear device-side state and force a clean
   re-application:
   ```dos
   MpCmdRun.exe -Config -ResetControlledConfiguration
   ```
6. Re-sync and re-validate once more.

**Rollback:** not applicable — this playbook restores intended state rather than reversing
a change.

</details>

---
## Evidence Pack

```powershell
# Controlled Configuration — Evidence Pack (run on-device, elevated)

$status = Get-MpComputerStatus
[PSCustomObject]@{
    ControlledConfigurationState = $status.ControlledConfigurationState
    IsTamperProtected            = $status.IsTamperProtected
    TamperProtectionSource       = $status.TamperProtectionSource
    AMProductVersion             = $status.AMProductVersion
    AMEngineVersion               = $status.AMEngineVersion
} | Format-List

Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection" -Name SenseVersion -EA SilentlyContinue
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -EA SilentlyContinue |
    Select-Object OnboardingState, OrgId
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM" -EA SilentlyContinue | Select-Object -ExpandProperty PSPath -EA SilentlyContinue
```

For tenant/fleet-wide evidence collection, use
`Scripts/Get-ControlledConfigurationAudit.ps1` — it is explicit about what it can and
cannot confirm remotely (see the script's own header).

---
## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Check enforcement + Tamper Protection foundation state | `Get-MpComputerStatus \| Select ControlledConfigurationState, IsTamperProtected, TamperProtectionSource` |
| Check AV platform version (floor: 4.18.26060.3004) | `Get-MpComputerStatus \| Select AMProductVersion` |
| Check Sense sensor build (floor: > 10.8804) | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection" -Name SenseVersion` |
| Enable via Intune | Endpoint security > Antivirus / Windows Security Experience > **Controlled Configuration (Device)** = On |
| Enable via Defender for Endpoint security settings management | Same underlying policy surface, non-Intune-enrolled devices |
| Local reset (requires troubleshooting mode) | `MpCmdRun.exe -Config -ResetControlledConfiguration` |
| Check reporting for MDM-enrolled devices | Intune admin center — policy status + device-level state |
| Check reporting for MDE-SSM-only devices | Microsoft Defender portal — effective configuration state |
| Enable local exclusion merge | Windows Security Experience policy — local administrator merge setting |
| Migrate from Tamper Protection | New WSE policy w/ Controlled Configuration (On) → validate → remove old DCv1 Tamper Protection setting |

---
## 🎓 Learning Pointers

- **This is a Preview feature with two hard, currently-undocumented-workaround gaps**:
  no co-management support, no GCC High support. Confirm both before scoping any rollout,
  since a policy can report Success against an excluded device without actually doing
  anything. [Controlled configuration in Microsoft Defender for Endpoint](https://learn.microsoft.com/en-us/defender-endpoint/secure-controlled-configuration)
- **The version-floor degradation mode is silent by design**, not a bug to report to
  Microsoft — a down-level device receiving `Controlled Configuration (On)` may apply only
  the Tamper Protection half of the setting, or neither, depending on platform/sensor
  version. Always validate on-device state, never trust Intune's Success status alone for
  this feature during initial rollout.
- **Value-based conflict resolution (On beats Off) is a deliberate security-first design
  choice** — it means a "Conflict" status is a policy-hygiene signal to clean up, not
  evidence the device is currently unprotected. Don't over-escalate a Conflict report as
  an active security gap without checking actual on-device state first.
- **"Not configured" never means "Off."** Disabling Controlled Configuration always
  requires an explicit Off value in policy — a common trap when someone tries to "turn it
  off" simply by deleting or unassigning a policy that set it to On, only to find secure
  defaults keep most protections active anyway.
- **Reporting visibility depends entirely on management channel** — Intune admin center
  only shows MDM-enrolled devices; Defender for Endpoint security settings
  management-only devices require checking the Microsoft Defender portal instead. This
  split is a very easy source of "we have no data for this device" false alarms.
- **This feature and Tamper Protection are not meant to be run in parallel on the same
  setting** — they share a policy slot by design. Any migration should be a deliberate
  cutover with pilot validation, not an additive rollout, per this runbook's Playbook 1.
