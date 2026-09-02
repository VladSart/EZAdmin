# Intune macOS 15 Minimum Version Requirement (Golden Gate 27) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Source confidence:** built from a live fetch of Microsoft's Message Center archive record [MC1403402 — Plan for Change: Intune moving to support macOS 15 and higher later this year](https://mc.merill.net/message/MC1403402) (published 2026-06-24, referenced by a follow-up post MC1454370), cross-checked against WebSearch summaries of Microsoft's Intune "What's new"/in-development documentation. This is explicitly a **Plan for Change** advisory, not a shipped, GA feature as of this writing — no exact cutover date has been published; Microsoft states only "later this year," tied to Apple's own unannounced macOS Golden Gate 27 release date. Treat all timing statements below as provisional and re-verify against the live Intune "in development" page and your tenant's Message Center before communicating a firm deadline to users.

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

This runbook covers Intune's upcoming minimum supported macOS version change — from macOS 14.x to macOS 15 (Sequoia) and later — for Intune itself, the Company Portal app, and the Intune MDM agent on macOS. It does not cover general macOS software update management via Intune (see `SoftwareUpdates-A.md`/`-B.md` for that), nor does it cover the underlying Apple OS compatibility question for specific Mac hardware models (Apple's own published compatibility list is authoritative for that).

This is a fleet-readiness and forward-planning topic more than a reactive-incident one: the change has not shipped as of this writing, and the practical work is identifying at-risk devices and driving upgrades ahead of the (currently unannounced) cutover date.

---
## How It Works

<details><summary>Full architecture</summary>

The change is driven by Apple's release cadence, not Microsoft's own roadmap independently. Apple is expected to release macOS "Golden Gate 27" — the next annual macOS version — later in 2026. Because the Company Portal app is a **single, unified codebase shared between iOS and macOS**, Microsoft cannot bump the macOS-side minimum version in isolation from the iOS-side app lifecycle; the practical effect is that Intune, Company Portal, and the Intune MDM agent for macOS move their minimum supported version to macOS 15 (Sequoia) and later shortly after Apple's release ships, rather than on an independently-scheduled date Microsoft controls end-to-end.

The change has two cleanly separated effects:

1. **Already-enrolled devices on macOS 14.x or below are not touched.** They remain enrolled and continue to be managed after the change ships. This is explicitly called out by Microsoft — the change does not affect existing enrolled devices.
2. **New enrollment attempts on macOS 14.x or below are blocked.** A device attempting to enroll for the first time (or presumably re-enroll after being fully unenrolled) after the change ships must be running macOS 15 or later.

A documented nuance sits on top of this two-effect model: devices enrolled **without user affinity** — either via Automated Device Enrollment (ADE) without user affinity, or Direct Enrollment — have a "slightly nuanced support statement due to their shared usage" pattern (kiosk Macs, lab machines, shared workstations where no single user account owns the device). Microsoft points to a dedicated reference (`aka.ms/Intune/macOS/ADE-DE-support`) for the precise rule rather than folding it into the general announcement, which signals the shared-device case does not follow the simple "14.x blocked, 15+ allowed" rule identically to user-affinity enrollments. Verify current guidance at that link directly when planning for shared/kiosk macOS fleets — this runbook does not restate unconfirmed specifics for that carve-out.

</details>

---
## Dependency Stack

```
Layer 3: Fleet-readiness reporting & communication (proactive, org-owned)
         Identify devices on macOS 14.x or below via Intune inventory
         Communicate upgrade deadlines ahead of the (TBD) cutover date
Layer 2: Enrollment-type-specific nuance
         Standard (user-affinity) enrollment — simple 14.x blocked / 15+ allowed rule
         ADE without user affinity / Direct Enrollment (shared/kiosk) — separately
         documented nuance at aka.ms/Intune/macOS/ADE-DE-support, not identical
         to the standard rule
Layer 1: Intune/Company Portal/MDM-agent minimum-version enforcement
         Enforced at NEW enrollment time only — no retroactive effect on
         already-enrolled devices
Layer 0: Apple's macOS Golden Gate 27 release (external dependency, unannounced
         date, entirely outside Microsoft's control)
         └── Company Portal's unified iOS+macOS codebase is why Microsoft's
                 change is timed to follow this release rather than landing
                 independently
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| New Mac enrollment fails, device is on macOS 14.x or below | Minimum-version enforcement (once shipped) | `sw_vers -productVersion` on the device; confirm this is a NEW enrollment, not an existing managed device |
| Existing managed Mac on macOS 14.x suddenly reported as "unsupported" or failing management tasks | NOT this change — already-enrolled devices are explicitly unaffected; investigate as a separate issue | Confirm enrollment date predates the cutover; check for unrelated compliance policy or agent-health causes |
| Shared/kiosk Mac (no user affinity) behaves differently than expected under the new floor | The documented ADE-without-affinity/Direct-Enrollment nuance applies | Review `aka.ms/Intune/macOS/ADE-DE-support` directly — do not assume the standard rule |
| Fleet has a large number of Macs on 14.x with no upgrade plan | Proactive readiness gap, not yet a live failure | Run the fleet-wide OS version query; start upgrade communication now, ahead of any confirmed date |
| Mac hardware can't run macOS 15 even after attempting to update | Apple hardware compatibility limit, unrelated to Intune | Cross-check model against Apple's macOS Sequoia compatibility list; plan hardware refresh |

---
## Validation Steps

1. **Confirm current OS version distribution across the macOS fleet.**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
       Group-Object { $_.OSVersion -replace '^(\d+)\..*','$1' } |
       Select-Object Name, Count
   ```
   Good: an accurate current-state baseline to plan against. This is a planning input, not a pass/fail check — there's no "expected good" value yet since the change hasn't shipped.

2. **Identify devices below the coming floor specifically.**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
       Where-Object { [version]($_.OSVersion -replace '^(\d+\.\d+).*','$1') -lt [version]"15.0" } |
       Select-Object DeviceName, OSVersion, UserPrincipalName, ManagedDeviceOwnerType
   ```
   Good: a manageable, shrinking list over time as upgrades land. Bad: a large, static population with no upgrade cadence — flag for a dedicated upgrade campaign.

3. **Cross-check affected devices against Apple's hardware compatibility list before assuming a simple software upgrade fixes everything.**
   Reference: [macOS Sequoia is compatible with these computers](https://support.apple.com/120282). Devices that fail this check need hardware refresh planning, not just an upgrade nudge.

4. **For shared/kiosk devices specifically, confirm enrollment type before applying the standard remediation.**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
       Where-Object { -not $_.UserPrincipalName } |
       Select-Object DeviceName, OSVersion, ManagedDeviceOwnerType, EnrollmentType
   ```
   Devices with no associated user principal name are candidates for the ADE-without-affinity/Direct-Enrollment nuance — verify against current Microsoft guidance before communicating a deadline to whoever manages those devices.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Establish whether this is a live block or a readiness question.** As of this writing the change has not shipped; most work under this topic is proactive fleet-readiness reporting, not reactive troubleshooting. Confirm the Intune "in development" page or your tenant's Message Center before treating any specific failure as this change actually being live.

**Phase 2 — If a live enrollment failure is reported, confirm it's genuinely a new-enrollment block, not something else.** Already-enrolled devices are explicitly unaffected; an existing managed Mac failing for any reason is a different troubleshooting path.

**Phase 3 — Distinguish standard user-affinity enrollment from shared/kiosk enrollment types.** The documented nuance for ADE-without-affinity and Direct Enrollment means the simple two-effect model (block new enrollment / leave existing alone) may not apply identically — check the dedicated reference before guaranteeing behavior to a team managing shared devices.

**Phase 4 — Separate a software-upgrade-fixable case from a hardware-refresh case.** Not every Mac on macOS 14 can run macOS 15; running the device's model against Apple's compatibility list early avoids promising users a fix that isn't available on their hardware.

**Phase 5 — Build and maintain a readiness report, not a one-time check.** Because the exact cutover date is externally driven by Apple and not yet published, the fleet-readiness query should be re-run periodically (e.g. monthly) rather than once, so the affected-device count is tracked down to zero (or a known, accepted residual) by the time the change actually ships.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Proactive fleet-readiness campaign ahead of the (unannounced) cutover</summary>

1. Run the fleet-wide macOS-14.x-or-below query (Validation step 2) to establish a baseline.
2. Cross-reference against Apple's hardware compatibility list to split the population into "software-upgrade-eligible" vs. "needs hardware refresh."
3. For upgrade-eligible devices, communicate a clear internal deadline ahead of Microsoft's expected timing, and consider a managed/scripted OS update push via Intune's Software Updates feature (see `SoftwareUpdates-A.md`) rather than relying solely on user self-service.
4. For hardware-refresh-required devices, route into your standard device lifecycle/refresh process with enough lead time — hardware procurement timelines are typically longer than a software upgrade window.
5. Re-run the readiness query on a recurring cadence and report the shrinking affected-device count until the change actually ships.

No rollback needed — this is a proactive planning and communication playbook.

</details>

<details><summary>Playbook 2 — Shared/kiosk macOS fleet (ADE without user affinity, Direct Enrollment)</summary>

1. Identify all shared/kiosk Macs via the no-user-principal-name query (Validation step 4).
2. Do NOT assume the standard "14.x blocked at new enrollment, existing devices unaffected" rule applies identically — retrieve and review the current guidance at `aka.ms/Intune/macOS/ADE-DE-support` directly.
3. Plan upgrade or re-provisioning timing for this population separately from the general fleet, since shared-device provisioning workflows (imaging, ADE profile reassignment) often have longer lead times than a single-user device upgrade.
4. Revisit this playbook once Microsoft publishes the confirmed cutover date, since the shared-device nuance may interact with timing differently than the standard case.

Rollback: not applicable — planning playbook.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects a macOS fleet-readiness snapshot for the upcoming Intune macOS 15
    minimum-version change (Golden Gate 27), for planning or escalation use.
#>
$allMac = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All

$belowFloor = $allMac | Where-Object { [version]($_.OSVersion -replace '^(\d+\.\d+).*','$1') -lt [version]"15.0" }
$noUserAffinity = $belowFloor | Where-Object { -not $_.UserPrincipalName }

[PSCustomObject]@{
    SnapshotDateUtc              = (Get-Date).ToUniversalTime()
    TotalMacOSDevices             = $allMac.Count
    DevicesBelowMacOS15           = $belowFloor.Count
    DevicesBelowMacOS15_Percent   = if ($allMac.Count -gt 0) { [math]::Round(($belowFloor.Count / $allMac.Count) * 100, 1) } else { 0 }
    NoUserAffinityBelowFloor      = $noUserAffinity.Count
    NoUserAffinityNote            = "These devices may follow a different support statement — verify against aka.ms/Intune/macOS/ADE-DE-support before applying standard remediation."
    DeviceList                    = $belowFloor | Select-Object DeviceName, OSVersion, UserPrincipalName, ManagedDeviceOwnerType
} | ConvertTo-Json -Depth 6
```

---
## Command Cheat Sheet

```powershell
# Full macOS OS-version distribution
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All | Group-Object { $_.OSVersion -replace '^(\d+)\..*','$1' } | Select-Object Name, Count

# Devices below the coming macOS 15 floor
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All | Where-Object { [version]($_.OSVersion -replace '^(\d+\.\d+).*','$1') -lt [version]"15.0" }

# Shared/kiosk candidates (no user principal name) below the floor
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All | Where-Object { -not $_.UserPrincipalName -and [version]($_.OSVersion -replace '^(\d+\.\d+).*','$1') -lt [version]"15.0" }

# Single device OS version check (on-device)
sw_vers -productVersion

# Single device model check for Apple hardware-compatibility cross-referencing (on-device)
sysctl -n hw.model
```

---
## 🎓 Learning Pointers

- This is a **Plan for Change** (Message Center MC1403402, published 2026-06-24), not a shipped feature — no confirmed cutover date exists as of this writing. Re-verify timing via the [Intune in-development page](https://learn.microsoft.com/en-us/intune/whats-new/in-development) and your own tenant's Message Center before setting a firm internal deadline.
- The change is deliberately timed to Apple's own macOS Golden Gate 27 release, not an independent Microsoft schedule, because Company Portal is a single unified app across iOS and macOS.
- **Already-enrolled devices are never retroactively affected** — this is the single most important fact to get right when communicating with stakeholders, since the natural (incorrect) assumption is that existing managed Macs will stop being managed.
- The ADE-without-user-affinity/Direct-Enrollment carve-out is real and documented separately (`aka.ms/Intune/macOS/ADE-DE-support`) — don't apply the simple two-effect model uniformly to shared/kiosk Mac fleets without checking it.
- Not every Mac running macOS 14 supports macOS 15 — always cross-check Apple's own compatibility list before treating this as a pure software-upgrade problem.
- Related: `macOS/Troubleshooting/SoftwareUpdates-A.md`/`-B.md` (the mechanism for pushing the actual OS upgrade at scale via Intune), `macOS/Troubleshooting/ADE-Enrollment-A.md`/`-B.md` (general ADE enrollment mechanics this version floor gates).
