# Windows 11, version 26H2 — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom -> Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#learning-pointers)

---

## Scope & Assumptions

**Covers:**
- The enablement-package (eKB) servicing model shared by Windows 11 24H2/25H2/26H2
- Deployment mechanics via Windows Update client policy, Intune Feature Update policies + Update Rings, WSUS, and Windows Autopatch
- Commercial-device default-behavior changes shipped as part of the 26H2 flip (Settings Backup, taskbar, File Explorer)
- Edition-split support lifecycle planning

**Does not cover:**
- General feature-update mechanics for devices below the 24H2/25H2/26H2 shared branch (23H2 and earlier) — see `Windows Update/Update to Latest A.md`/`B.md`
- WSUS server-role maintenance itself — see `Windows Update/WSUS-Server-A.md`/`B.md`
- The specific Windows Settings Backup capability's own full policy surface — see `WindowsBackup-A.md`/`B.md` (this runbook only covers that 26H2 flips its default state, not the feature's full architecture)
- Windows 10 ESU — an entirely separate program for an EOL predecessor OS, see `ESU-A.md`/`B.md`

**Build context (subject to Microsoft revision — reconfirm before treating any date below as final):**
- Windows 11, version 26H2, build 26300.9278, entered the Release Preview Insider channel **August 27, 2026**
- General availability is expected late September/early October 2026, following the same enablement-package cadence Microsoft used for 24H2 -> 25H2
- Microsoft has stated devices can be deployed/validated ahead of broad GA using Windows Update client policy and WSUS, with Windows Autopatch and Azure Marketplace availability following the same timeframe

---

## How It Works

<details><summary>Full architecture</summary>

**The shared servicing branch model.** Windows 11 24H2, 25H2, and 26H2 are not three separate operating system images the way, say, 21H2 and 22H2 were. They are the same underlying build family. New features that will eventually "belong" to 25H2 or 26H2 are actually shipped, dormant, inside ordinary monthly Cumulative Updates (LCUs) well before their nominal release — a practice Microsoft calls "continuous innovation." The version-number flip itself (24H2 -> 25H2, or 25H2 -> 26H2) is delivered by a tiny **enablement package (eKB)**, roughly 174 KB, whose only job is to toggle the feature flags that were already sitting dormant in the OS and update the reported version/build/UBR values. This is why an eKB-delivered version bump requires exactly one restart and none of the mechanics of a traditional feature update (no new WinRE image staging, no multi-hour "Working on updates" phase, no `$WINDOWS.~BT` download of a full OS image).

**Why the eKB won't apply without the prerequisite LCU.** Because the eKB's entire job is to flip flags for code that must already be physically present on the device, it has a hard dependency on the specific Cumulative Update that shipped that dormant code. If a device is behind on quality updates — deferred by policy, stuck, or simply not yet synced — the eKB is not offered at all. There is no error state for this; from the servicing stack's perspective, the eKB genuinely is not yet applicable, which is functionally indistinguishable from a policy hold unless you specifically check LCU currency.

**Deployment surfaces available today.** Microsoft has enabled three parallel deployment paths for organizations that want to begin validating or rolling out 26H2 ahead of full consumer GA: Windows Update for Business client policy (the `TargetReleaseVersion`/`ProductVersion` CSP pair), WSUS (approve the eKB update object in the relevant update view/group), and Windows Autopatch (release-management-driven, ring-based). Microsoft Intune's Feature Update policy blade is the practical management surface most MSPs will use, layering staged rings and Pause/Resume/Rollback controls on top of the underlying WUfB policy mechanism.

**Why several features flip to default-on specifically on 26H2.** Because the shared-branch model ships code dormant ahead of its "release," Microsoft can choose to activate a feature by default for one nominal version and not an earlier one, even though the code has been present since an earlier LCU. For 26H2, three commercial-device-relevant defaults change with the version flip itself, with no separate opt-in step: Windows Settings Backup, app-specific taskbar actions, and several File Explorer enhancements. This is the architectural reason "nothing was deployed, but behavior changed" is a legitimate, expected symptom on this topic rather than evidence of an unauthorized change.

**Uninstall/rollback mechanics.** Because an eKB is a lightweight flag-flip rather than a full image swap, its removal path is also lighter — a `DISM /Online /Remove-Package` operation against the specific eKB package, valid only for a limited post-installation window (the same general time-boxed-uninstall behavior Windows applies to any enablement package, not a 26H2-specific policy). There is no guarantee of an indefinite rollback window; if in doubt, check package presence and any documented removal deadline before committing to an uninstall plan for a client.

</details>

---

## Dependency Stack

```
Layer 0 -- Device must already be on the 24H2/25H2/26H2 shared servicing branch
           (23H2 and earlier: eKB path does not exist; full feature update required first)

Layer 1 -- Prerequisite Cumulative Update (LCU) currency
           The specific monthly LCU that shipped the dormant 26H2 code must be installed
           No LCU present = eKB never offered, no error surfaced

Layer 2 -- Enablement package (eKB) itself
           ~174 KB, flips version/build/UBR + feature flags, one restart

Layer 3 -- Deployment/servicing-channel gate (WHEN it's offered)
           Windows Update client policy | WSUS approval | Windows Autopatch release ring

Layer 4 -- Policy targeting (WHICH version a managed device may reach)
           Intune Feature Update policy + Update Rings, or WUfB TargetReleaseVersion/ProductVersion

Layer 5 -- Safeguard holds / compatibility blocks
           Applied per-device against known driver/hardware/software incompatibilities,
           same mechanism used for every feature update

Layer 6 -- Post-flip default-behavior changes (commercial devices)
           Windows Settings Backup, app-specific taskbar actions, File Explorer enhancements
           activate automatically -- not a separate deployment step
```

---

## Symptom -> Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| 26H2 never appears as available on an eligible (24H2/25H2) device | Prerequisite LCU not yet installed | `Get-HotFix` most recent install date vs. current Patch Tuesday |
| 26H2 never appears on a managed device even with LCU current | Deliberate policy hold (`TargetReleaseVersion` pinned) | `PolicyManager\current\device\Update` registry read |
| Device shows a compatibility/safeguard message in Update history | Known driver/app/hardware incompatibility flagged by Microsoft | Settings > Windows Update > Update history |
| Device is on 23H2 or earlier and "can't get 26H2" | Not eligible for the eKB path at all | `DisplayVersion` check; route to full-feature-update runbook |
| Settings Backup, taskbar, or File Explorer behavior changed with no visible upgrade prompt | Expected eKB-driven default-on flip for commercial devices | Confirm version is now 26H2; cross-reference `WindowsBackup-A.md` if Backup specifically |
| Upgrade took multiple hours / behaved like a full feature update | Device was NOT on the shared branch (was actually 23H2 or earlier), or a full feature update was applied instead of the eKB | Confirm pre-upgrade `DisplayVersion`; if it was already 24H2/25H2, this needs deeper investigation as atypical |
| Uninstall/rollback attempt fails | Post-install removal window has closed | `DISM /Online /Get-Packages` presence check; there is no indefinite rollback guarantee |

---

## Validation Steps

**1. Confirm eligibility and current state:**
```powershell
Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion, CurrentBuild, UBR
```
Expected good output: `DisplayVersion` of `24H2` or `25H2` prior to upgrade, `26H2` after. Anything below `24H2` means this device is out of scope for the eKB path.

**2. Confirm prerequisite LCU currency:**
```powershell
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, InstalledOn
```
Bad sign: most recent LCU is more than one Patch Tuesday cycle old with no clear deferral policy explanation.

**3. Confirm policy targeting for managed devices:**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -ErrorAction SilentlyContinue |
    Select-Object TargetReleaseVersion, ProductVersion, DeferFeatureUpdatesPeriodInDays
```
Expected: a value consistent with the ring the device is supposed to belong to. Unexpected: a stale value left over from a prior campaign with no corresponding active policy.

**4. Confirm no unresolved safeguard hold:**
```
Settings > Windows Update > Windows Update history
```
Bad sign: any message referencing a compatibility hold with no corresponding remediation plan on file.

**5. Post-upgrade default-behavior confirmation (commercial devices):**
Check Settings Backup toggle state, taskbar configuration, and File Explorer behavior against what the org expects/wants documented as the post-26H2 baseline, rather than assuming the pre-upgrade defaults persisted.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Pre-rollout planning:**
- Inventory current version distribution across the fleet (`DisplayVersion` sweep) to identify which devices are eKB-eligible today vs. which need a full feature update first.
- Confirm LCU currency fleet-wide before targeting any ring for 26H2 — a fleet behind on quality updates will show artificially low eKB uptake that looks like a policy problem but isn't.
- Decide the Update Ring / Feature Update policy structure (pilot -> broad -> full) before assigning anything.

**Phase 2 — Pilot ring rollout:**
- Assign a small pilot device group via Intune Feature Update policy or WUfB `TargetReleaseVersion`.
- Monitor Windows Update history across the pilot group for safeguard holds.
- Explicitly verify the three known default-behavior changes (Settings Backup, taskbar, File Explorer) against what the org wants, and pre-stage any policy overrides needed before broad rollout.

**Phase 3 — Broad rollout:**
- Expand ring assignment; keep Pause/Resume/Rollback available and monitored.
- Track LCU currency continuously — devices that fall behind mid-rollout will silently stop being offered the eKB, which can look like a partial-rollout failure if not understood.

**Phase 4 — Post-rollout verification and cleanup:**
- Confirm fleet-wide `DisplayVersion` convergence to `26H2` for the targeted ring.
- Document the new commercial-device defaults (especially Settings Backup) in the org's own configuration baseline so future audits don't flag them as unexplained drift.
- Retire any temporary safeguard-hold workaround policies once Microsoft resolves the underlying compatibility issue.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full staged fleet rollout (pilot -> broad -> full)</summary>

1. Inventory: sweep `DisplayVersion` and most-recent-LCU-install-date across the fleet.
2. Exclude/queue-separately any device on 23H2 or earlier for a full-feature-update project instead.
3. Create an Intune Feature Update policy targeting Windows 11, version 26H2, assigned first to a small pilot group.
4. Monitor pilot group for 5-10 business days: safeguard holds, Settings Backup/taskbar/File Explorer behavior against org expectations, any help-desk tickets.
5. Expand assignment to a broad ring, then full fleet, keeping Pause/Resume available throughout.
6. Post-rollout: confirm convergence, update configuration baselines to reflect new 26H2 defaults, and close out any temporary compatibility workarounds.

**Rollback:** Pause the Feature Update policy ring immediately if a systemic issue appears; for already-upgraded devices within the removal window, `DISM /Online /Remove-Package` against the specific eKB package name.

</details>

<details><summary>Playbook 2 — Emergency/expedited path ahead of a support-timeline deadline</summary>

1. Confirm which devices are already eKB-eligible (24H2/25H2) vs. need a full feature update first (23H2 or earlier) — these are two different projects with two different timelines; don't treat them as one task.
2. For eKB-eligible devices, force LCU currency first (`UsoClient StartScan/StartDownload/StartInstall`), since this is the most common silent blocker under time pressure.
3. Assign the Feature Update policy to all eligible devices in a single ring if the timeline doesn't allow for a full pilot phase — accept the added risk explicitly with the client rather than skipping the eKB-eligibility/LCU-currency checks, which are cheap and catch most real failures.
4. For 23H2-and-earlier devices that cannot make the deadline via the eKB path, scope a separate, explicitly-flagged full-feature-update project with its own timeline — do not promise these devices will reach 26H2 on the same schedule as eKB-eligible ones.

**Rollback:** Same DISM removal path as Playbook 1, subject to the same time-boxed availability caveat.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
  Collects Windows 11 26H2 rollout-readiness evidence for a single device, for pasting into
  an escalation ticket or a pre-rollout inventory sweep.
#>
$evidence = [ordered]@{
    ComputerName        = $env:COMPUTERNAME
    DisplayVersion      = (Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion -ErrorAction SilentlyContinue)
    CurrentBuild        = (Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name CurrentBuild -ErrorAction SilentlyContinue)
    UBR                 = (Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name UBR -ErrorAction SilentlyContinue)
    EkbEligible         = $false
    MostRecentLCU       = (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1)
    TargetReleaseVersion = $null
    ProductVersion       = $null
}
if ($evidence.DisplayVersion -in @('24H2','25H2')) { $evidence.EkbEligible = $true }
$policy = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -ErrorAction SilentlyContinue
if ($policy) {
    $evidence.TargetReleaseVersion = $policy.TargetReleaseVersion
    $evidence.ProductVersion       = $policy.ProductVersion
}
$evidence | Format-List
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-ItemPropertyValue ...CurrentVersion -Name DisplayVersion` | Current OS version |
| `Get-HotFix \| Sort-Object InstalledOn -Descending` | Most recent LCU install date (prerequisite check) |
| `Get-ItemProperty ...PolicyManager\current\device\Update` | Managed device's target-version policy |
| `UsoClient StartScan/StartDownload/StartInstall` | Force a pending-update cycle (clears the LCU-missing blocker) |
| `Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational"` | Safeguard/compat event scan |
| `DISM /Online /Get-Packages` | List installed packages, incl. the 26H2 eKB, for removal-eligibility check |
| `DISM /Online /Remove-Package /PackageName:<name>` | Uninstall the eKB within its supported window |
| Intune: `Devices > Windows > Feature updates for Windows 10 and later` | Create/manage staged 26H2 rollout policy |

---

## Learning Pointers

- **The enablement-package model is the single most important architectural fact for this topic.** 24H2, 25H2, and 26H2 are the same underlying build with features shipped dormant ahead of activation — this changes both the risk profile (much lower than a traditional feature update) and the troubleshooting approach (LCU currency matters more than almost anything else). [Windows 11, version 26H2 release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)

- **A silent LCU-currency gap is functionally indistinguishable from a policy hold without checking both.** Build the habit of checking `Get-HotFix` currency before assuming a managed-device rollout gap is policy-driven.

- **Commercial-device default-behavior changes ship with the version flip, not as a separate deployment.** Document the Settings Backup/taskbar/File Explorer defaults as part of any 26H2 rollout plan so they don't get misreported as unauthorized configuration drift later.

- **Devices below the shared servicing branch (23H2 and earlier) are a structurally different project.** Scope and timeline these separately from eKB-eligible rollout work; conflating the two produces unreliable rollout estimates.

- **Support lifecycle splits by edition on an otherwise-shared build family** — Home/Pro/Pro EDU/Pro Workstations end in October 2028, Enterprise/Education/IoT Enterprise end in October 2029. Re-verify against Microsoft's current lifecycle page before using these dates in client-facing planning, since they are subject to revision. [Releasing Windows 11, version 26H2 to the Release Preview Channel](https://blogs.windows.com/windows-insider/2026/08/27/releasing-windows-11-version-26h2-to-the-release-preview-channel/)
