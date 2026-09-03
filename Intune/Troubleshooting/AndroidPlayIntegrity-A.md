# Android Play Integrity / Strong Integrity — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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
- Applies to **Android Enterprise** managed devices only — fully managed, dedicated, corporate-owned work profile (COPE), and personally owned work profile (BYOD). Device administrator legacy enrollment is out of scope (Play Integrity settings aren't exposed there).
- Assumes devices already enroll successfully and evaluate compliance/app-protection policy normally. This runbook covers the **Play Integrity Verdict / strong integrity** evaluation specifically, not general enrollment or MAM conditional-launch failures.
- The triggering event: Google redefined "Strong Integrity" for Android 13+ in a May 2025 rollout, adding a hardware-backed-security-signal **and** a rolling 12-month security-patch-recency requirement. Microsoft has run a backward-compatibility grace period since, and will begin enforcing the stricter definition in Intune app protection and compliance policy evaluation on **October 31, 2026**. Primary source: [Support tip: Changes to Google Play strong integrity for Android 13 or above](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-changes-to-google-play-strong-integrity-for-android-13-or-above/4435130) (Microsoft Intune Customer Success blog).
- Settings reference throughout is [Android Enterprise compliance settings in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-android-enterprise-settings) (ms.date 2026-06-18, updated_at 2026-07-01).

---
## How It Works
<details><summary>Full architecture</summary>

**Google Play Integrity API** is a Google-operated attestation service. When a Play-Integrity-aware app (Company Portal, or the Intune Managed Home Screen / MAM SDK for protected apps) requests an integrity token, Google's servers evaluate the device and return one of three escalating verdict tiers:

1. **Basic integrity** — the app is running on a real Android device (not an emulator), hasn't been obviously tampered with, and the OS hasn't been altered in ways Play can detect.
2. **Device integrity** — basic integrity, plus the device is a genuine, Play-Protect-certified device running an unmodified, licensed version of Android with Google Play services.
3. **Strong integrity (MEETS_STRONG_INTEGRITY)** — device integrity, plus the app's integrity token is backed by **hardware-level key attestation** — a hardware root of trust the OS itself can't forge. As of the May 2025 Google change, for Android 13+, MEETS_STRONG_INTEGRITY additionally requires the device to have installed a security patch within the trailing 12 months. A device that previously earned strong integrity can lose it purely by going stale on patches, with zero configuration change on either the admin or the Google side.

Intune surfaces this as two related, layered settings under **Google Play Protect** in an Android Enterprise compliance policy (and an analogous conditional-launch condition in app protection policies):

- **Play Integrity Verdict**: `Not configured` / `Check basic integrity` / `Check basic integrity & device integrity`.
- **Check strong integrity using hardware-backed security features**: only selectable once the above requires at least basic integrity; adds the strong-tier requirement on top.

Intune's compliance service periodically requests a fresh Play Integrity token via the Company Portal / MAM SDK, evaluates the returned verdict against the configured requirement, and marks the device Compliant/Noncompliant (or blocks the MAM conditional launch) accordingly. **Devices that aren't Play-Protect certified, or that operate without Google Mobile Services (GMS) in market, cannot pass Play Integrity checks at any tier** — a structural limitation independent of the 2026 patch-recency change.

Microsoft's own rollout sequencing: rather than flipping strict enforcement instantly when Google changed the criteria, Microsoft adjusted Intune's evaluation logic to align with Google's documented backward-compatibility guidance — effectively holding older behavior in place for a transition window — before committing to the October 31, 2026 enforcement date. This is a policy-evaluation-timing decision on Microsoft's side layered on top of a criteria change that is entirely Google's.
</details>

---
## Dependency Stack
```
Layer 5  Intune compliance / MAM conditional-launch evaluation
              (marks device Compliant/Noncompliant or blocks app access)
Layer 4  Intune Android Enterprise compliance policy settings
              "Play Integrity Verdict" + "Check strong integrity" toggle
              (admin-configured; the only layer you can directly change)
Layer 3  Google Play Integrity API verdict (MEETS_BASIC / MEETS_DEVICE / MEETS_STRONG_INTEGRITY)
              — evaluated server-side by Google, not Microsoft
Layer 2  Device eligibility signals Google evaluates:
              - Play Protect certification + Google Mobile Services presence
              - Hardware-backed key attestation capability
              - (Android 13+, since May 2025) security patch date within trailing 12 months
Layer 1  Physical device: OEM hardware attestation support, OEM patch cadence,
              on-device Android/security patch level, Play Services build
```
A failure at Layer 1 or 2 cannot be fixed at Layer 4 — no compliance-policy setting change makes Google return a verdict the device doesn't actually earn. The only real levers at Layer 4 are *which tier to require*, not *how the tier is computed*.

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device was compliant, becomes noncompliant with no admin change, on/after 2026-10-31 | Security patch aged past 12 months on an Android 13+ device — Google's redefined strong-integrity bar now fails it | `AndroidSecurityPatchLevel` vs. 12-month window |
| Device fails strong integrity but passes basic/device integrity | Either patch-recency (Android 13+) or hardware lacks attestation capability | Compare OS version + patch date; cross-check OEM attestation support |
| Device fails **all** integrity tiers, including basic | No Google Mobile Services in market, non-certified/custom ROM, or rooted device | Region/market GMS availability; `Rooted devices` compliance setting state |
| App protection (MAM) blocks access with an integrity-related conditional-launch message, but device compliance in the portal shows Compliant | Two separate policy surfaces (compliance policy vs. app protection policy) can require different integrity tiers independently | Inspect app protection policy conditional-launch settings, not just the device compliance policy |
| Entire fleet of one OEM/model fails strong integrity uniformly | Hardware-level attestation ceiling on that model | Vendor spec sheet; compare against a different model in the same fleet |
| Personally owned work profile (BYOD) device fails, corporate fully-managed device with same OS/patch passes | Different compliance policy scoping BYOD vs. corporate-owned; the settings exist independently per ownership type in the same policy object | Confirm which section (fully managed vs. personally owned) actually applies the strong-integrity requirement |

---
## Validation Steps
1. **Confirm Android major version.** Only 13+ is affected by the patch-recency addition to strong integrity.
   ```powershell
   Get-MgUserManagedDevice -ManagedDeviceUserId <userId> |
       Where-Object OperatingSystem -eq 'Android' |
       Select-Object DeviceName, OSVersion
   ```
   Good: any check proceeds regardless of version, but Android 12- devices ruling this cause out is itself useful signal.

2. **Pull the on-device security patch date and compare against a rolling 12-month window.**
   ```powershell
   $device.AndroidSecurityPatchLevel
   ```
   Bad: date is more than 12 months before today → strong integrity will fail (or already is failing) under the new criteria regardless of anything else.

3. **Confirm which compliance policy tier is actually required.** Don't assume — many tenants only require basic or device integrity and are entirely unaffected.
   ```powershell
   Get-MgDeviceManagementDeviceCompliancePolicy -Filter "platform eq 'android'" |
       ForEach-Object {
           $_ | Select-Object DisplayName, Id
       }
   ```
   Inspect the raw policy body (Graph Explorer or `Invoke-MgGraphRequest`) for the `playIntegrity`/strong-integrity property values, since cmdlet-typed properties vary by SDK version.

4. **Check app protection policy conditional launch separately.** MAM and MDM integrity requirements are independently configured.
   Portal: **Apps → App protection policies → [policy] → Conditional launch** — look for a "Device integrity" or "Min Play Integrity" action row.

5. **Cross-reference hardware capability.** If Layer 1/2 (physical hardware) can't do key attestation, no amount of patching fixes it. Check the OEM's published Android Enterprise/Play Integrity support documentation for that exact model.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Scope the blast radius.**
Run `Get-AndroidPlayIntegrityAudit.ps1` (in `Intune/Scripts/`) against the full Android fleet. It buckets devices by OS major version and patch-age, flagging Android 13+ devices already outside the 12-month window ahead of the October 31, 2026 enforcement date — turning a reactive per-ticket fire drill into a proactive, one-time remediation list.

**Phase 2 — Separate "won't ever pass" from "hasn't patched yet."**
For each flagged device, determine whether the gap is patchable (device just needs an update pushed/accepted) or structural (EOL hardware, no vendor security updates forthcoming, or hardware lacking attestation entirely). This determines whether Fix 1 (patch) or a policy-scope exception (Fix 2/3 in the Mode B runbook) is the right long-term answer — patch-chasing a device that will never receive another OEM update is a wasted cycle.

**Phase 3 — Decide the corporate-owned vs. BYOD remediation split.**
Corporate-owned devices: push updates centrally via the Android Enterprise system update policy (or physically manage devices needing manual OTA acceptance). BYOD/personally owned work profile: Intune cannot force an update on personal hardware — plan a notification/grace-period campaign (non-compliance actions: email at day 0, block access at a defined day N) well before the enforcement date so users aren't surprised by a hard cutover.

**Phase 4 — Decide whether a policy-scope exception is warranted at all.**
If a meaningful population of otherwise-managed, otherwise-secure devices will never pass strong integrity (older/budget hardware without attestation), weigh a scoped compliance-policy exception (drop to device integrity only for that group) against the security posture tradeoff of accepting weaker device attestation for that population. This is a risk decision for the security/compliance owner, not a pure technical fix — document it explicitly rather than silently loosening a global policy.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide proactive patch push ahead of enforcement</summary>

1. Run the audit script to identify all Android 13+ devices with patch age > 10 months (build in a 2-month buffer before the actual 12-month/Oct-31 cutover).
2. For corporate-owned devices, target them with an Android Enterprise system update policy requiring installation within a defined deadline.
3. For BYOD devices, launch a Company Portal push notification campaign referencing the specific compliance policy and deadline.
4. Re-run the audit weekly; track the flagged count trending toward zero.
5. Rollback: none required — this playbook only pushes standard OS updates, no policy or data changes.
</details>

<details><summary>Playbook 2 — Scoped compliance-policy exception for attestation-incapable hardware</summary>

1. Identify the specific OEM/model population via the audit script's device list plus OEM spec confirmation.
2. Create a new compliance policy (do not edit the org-wide one) scoped via an Entra ID dynamic or assigned group containing only the affected devices.
3. In the new policy, set **Play Integrity Verdict** to `Check basic integrity & device integrity` and leave **Check strong integrity** unset — dropping only the strong-tier requirement for this population.
4. Document the business/security justification and expiry review date (e.g., "review at next device refresh cycle") directly in the policy description field.
5. Rollback: delete the scoped policy once the device population is refreshed to attestation-capable hardware; devices then fall back to the org-wide policy's stricter requirement automatically.
</details>

<details><summary>Playbook 3 — GMS-unavailable market exception</summary>

Per Microsoft's own guidance for [managing Android devices where Google Mobile Services isn't available](https://techcommunity.microsoft.com/t5/intune-customer-success/intune-customer-success-managing-android-devices-where-google/ba-p/1628793):

1. Identify the affected market/region device population.
2. Create a compliance policy scoped to that population with **Play Integrity Verdict** set to `Not configured` (Play Integrity cannot evaluate at all without GMS — requiring it guarantees permanent noncompliance).
3. Substitute alternative compliance signals for that population where possible (rooted-device block, minimum OS version, encryption requirement) since Play Integrity itself is unavailable as a signal.
4. Rollback: not applicable — this reflects a genuine, permanent device/market constraint, not a temporary state.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Play Integrity / strong integrity evidence for a single device, for escalation.
.NOTES     Requires Microsoft.Graph.DeviceManagement, connected with DeviceManagementManagedDevices.Read.All.
#>
param([Parameter(Mandatory)][string]$UserPrincipalName)

$user   = Get-MgUser -UserId $UserPrincipalName
$device = Get-MgUserManagedDevice -ManagedDeviceUserId $user.Id | Where-Object OperatingSystem -eq 'Android'

$evidence = [ordered]@{
    DeviceName            = $device.DeviceName
    OSVersion             = $device.OSVersion
    ManagementAgent       = $device.ManagementAgent
    SecurityPatchLevel    = $device.AndroidSecurityPatchLevel
    MonthsSincePatch      = [math]::Round(((Get-Date) - [datetime]$device.AndroidSecurityPatchLevel).Days / 30, 1)
    ComplianceState       = $device.ComplianceState
    EnrolledDateTime      = $device.EnrolledDateTime
}

$policyStates = Get-MgDeviceManagementManagedDeviceDeviceCompliancePolicyState -ManagedDeviceId $device.Id
$settingStates = Get-MgDeviceManagementManagedDeviceDeviceComplianceSettingState -ManagedDeviceId $device.Id |
    Where-Object { $_.Setting -match 'Integrity|Threat|Rooted' }

[pscustomobject]$evidence | Format-List
"--- Compliance Policy States ---"; $policyStates | Format-Table DisplayName, State, Platform -AutoSize
"--- Relevant Setting States ---"; $settingStates | Format-Table SettingName, State, CurrentValue -AutoSize
```

---
## Command Cheat Sheet
```powershell
# Device + patch level
Get-MgUserManagedDevice -ManagedDeviceUserId <userId> | Where-Object OperatingSystem -eq 'Android' |
    Select-Object DeviceName, OSVersion, AndroidSecurityPatchLevel, ComplianceState

# All Android Enterprise compliance policies
Get-MgDeviceManagementDeviceCompliancePolicy -Filter "platform eq 'android'"

# Raw policy body (see actual Play Integrity setting values)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/<policyId>"

# Compliance policy state per device
Get-MgDeviceManagementManagedDeviceDeviceCompliancePolicyState -ManagedDeviceId <deviceId>

# Per-setting compliance state (filter to integrity-related settings)
Get-MgDeviceManagementManagedDeviceDeviceComplianceSettingState -ManagedDeviceId <deviceId> |
    Where-Object { $_.Setting -match 'Integrity' }

# App protection policies (MAM) — inspect conditional launch separately from device compliance
Get-MgDeviceAppManagementAndroidManagedAppProtection

# Fleet-wide audit (this repo)
./Intune/Scripts/Get-AndroidPlayIntegrityAudit.ps1 -OutputPath ./audit.csv
```

---
## 🎓 Learning Pointers
- The Play Integrity verdict is computed **by Google**, on Google's servers, from signals Microsoft doesn't control and can't override. Intune's role is purely "require tier X, evaluate the returned verdict, act on it." Any troubleshooting that assumes an Intune-side bug when the actual verdict fails is starting from the wrong layer of the [Dependency Stack](#dependency-stack).
- Google's May 2025 redefinition of Strong Integrity for Android 13+ means a device's compliance state can now silently degrade over time purely from **patch age**, with zero configuration drift on either side. This breaks the usual "nothing changed, why did it break" troubleshooting assumption — the fix is to proactively track patch-age as its own fleet health metric, not just react to noncompliance alerts. Learn more: [Support tip: Changes to Google Play strong integrity for Android 13 or above](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-changes-to-google-play-strong-integrity-for-android-13-or-above/4435130).
- Compliance policy and app protection policy integrity requirements are **independently configured** — a device can be Compliant in the portal while a MAM conditional-launch check still blocks access to a specific app, because that policy has its own, separately-set integrity bar.
- Strong integrity is architecturally a superset requirement, not a parallel one — Intune only exposes the toggle once basic/device integrity is already required, mirroring Google's own verdict hierarchy documented in [Integrity verdicts](https://developer.android.com/google/play/integrity/setup#configure-api).
- Hardware-backed key attestation is a **silicon-level capability**, not a software feature that can be patched in — budget/older Android hardware without a secure element or equivalent TEE can never pass strong integrity, no matter how current its OS patch is. Fleet standardization on attestation-capable hardware is the only durable fix for that population.
