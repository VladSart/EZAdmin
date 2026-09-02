# Windows 11, version 26H2 — Hotfix Runbook (Mode B: Ops)
> Fix or plan a 26H2 rollout ticket in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these first — results tell you which fix path to follow:

```powershell
# 1. What version is the device actually on right now?
Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion, CurrentBuild, UBR

# 2. Is this device even eligible for the eKB fast path? (must already be 24H2 or 25H2)
#    Anything below 24H2 (e.g. 23H2, 22H2) is NOT eligible for the enablement package --
#    it needs a full feature update first, a materially longer/riskier operation
(Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion) -in @('24H2','25H2')

# 3. Has the 26H2-enabling quality update (LCU) actually installed?
#    The enablement package (eKB) will NOT show as applicable/offered until this prerequisite is present --
#    this is the #1 source of "26H2 never shows up" tickets
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, InstalledOn

# 4. Is the device management-scoped by an Intune Feature Update policy / WUfB target version / WSUS approval
#    that could be blocking or holding it back?
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -ErrorAction SilentlyContinue |
    Select-Object TargetReleaseVersion, ProductVersion, DeferFeatureUpdatesPeriodInDays

# 5. Any safeguard hold or compat block currently applied to this device?
Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 30 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "safeguard|compat|blocked" } | Select-Object TimeCreated, Message
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Device is on 24H2 or 25H2, prerequisite LCU installed, 26H2 still not offered | Likely a policy hold (Intune/WUfB/WSUS target version) or a safeguard hold -> Fix 1 / Fix 3 |
| Device is on 23H2 or earlier | Not eligible for the eKB fast path at all -- this is a full feature-update project, not a 26H2 ticket specifically -> Fix 5 |
| `TargetReleaseVersion`/`ProductVersion` policy is pinned to `25H2` or an older value | Expected, deliberate hold -- confirm with the change owner before touching it -> Fix 1 |
| Prerequisite LCU missing | Install current cumulative update first; the eKB has a hard dependency on it -> Fix 2 |
| User/admin reports a feature "just appeared" after a routine patch cycle with no separate upgrade prompt | Expected eKB behavior -- this is the fast path working as designed, not a rogue upgrade -> close as informational |
| Settings Backup, taskbar, or File Explorer behavior changed unexpectedly right after patching | 26H2 flips several previously-latent features to **default-on** for commercial devices -- see Fix 4 and cross-reference `WindowsBackup-B.md` if the Settings Backup toggle specifically is the concern |
| Client asks "how long do we have on our current edition" | Support-window split by edition -- see Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Device currently on Windows 11 24H2 or 25H2
  (23H2 and earlier: NOT eligible for the eKB -- requires a full
   feature-update upgrade instead, a separate, longer-running project)
        |
Shared servicing branch: 24H2 / 25H2 / 26H2 are the SAME underlying
build family -- 26H2's features are already latent in the OS, delivered
gradually through prior monthly Cumulative Updates (LCUs)
        |
Prerequisite Latest Cumulative Update (LCU) installed
  (the eKB will not be offered/applicable until this is present --
   this is the single most common "why won't it upgrade" root cause)
        |
Enablement package (eKB) applies
  ~174 KB payload, flips version/build/UBR flags, ONE restart required
  (fundamentally different mechanism from a media-based feature update --
   no multi-hour "Working on updates" screen, no rollback partition build)
        |
   +----+------------------------------------+
   |                                          |
Deployment/servicing channel gate       Policy targeting (if managed)
Windows Update client policy,           Intune Feature Update policy +
WSUS approval, or Windows               Update Rings, WUfB
Autopatch release management            TargetReleaseVersion/ProductVersion
determines WHEN the eKB is              determines WHICH version a managed
offered to this device                  device is allowed to reach
   |                                          |
   +-------------------+----------------------+
                        v
        Device reboots once, version flips to 26H2
                        v
   Previously-latent, now-default-on commercial features activate
   (Windows Settings Backup, app-specific taskbar actions, File
   Explorer enhancements) -- NOT a separate deployment step, happens
   automatically as part of the version flip
```

**Key concepts:**
- **This is not a normal feature update.** Because 24H2/25H2/26H2 share one servicing branch, going from 25H2 (or 24H2) to 26H2 is a small enablement-package flip, not a full OS image swap. Don't apply full-feature-update risk assumptions (multi-hour downtime, driver reinstall risk) to this specific transition -- they don't apply here.
- **Anything below 24H2 is a different, bigger project.** A device on 23H2 or earlier has to go through a full feature update to reach the shared 24H2/25H2/26H2 branch first; the eKB fast path simply does not exist for that device yet.
- **The prerequisite LCU gate is the most common false "it's stuck" report.** If the current cumulative update hasn't installed yet, the enablement package won't even be offered -- this looks identical to a policy block from the help-desk's point of view but has a completely different fix.

</details>

---

## Diagnosis & Validation Flow

**Step 1 -- Confirm current version and build:**
```powershell
Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion, CurrentBuild, UBR
```

**Step 2 -- Confirm eKB eligibility (must be 24H2 or 25H2):**
- If `DisplayVersion` is `23H2` or older, stop here -- this is a full-feature-update conversation, not a 26H2-specific one. Route to `Troubleshooting/Windows Update/Update to Latest A.md`/`B.md` first.

**Step 3 -- Confirm the prerequisite cumulative update is installed:**
```powershell
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5
```
- Compare the most recent LCU's install date against the current month's Patch Tuesday; if it's missing, that's the fix.

**Step 4 -- If managed, confirm what version policy is actually targeting:**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -ErrorAction SilentlyContinue |
    Select-Object TargetReleaseVersion, ProductVersion, DeferFeatureUpdatesPeriodInDays
```
- A pinned `TargetReleaseVersion` of `25H2` (or blank, defaulting to the servicing branch's current default) will hold the device back from 26H2 by design until changed.

**Step 5 -- If the report is "something changed after patching," identify which newly-default-on feature is involved:**
- Settings Backup toggle state, taskbar layout, or File Explorer behavior are the three documented commercial-device default flips that ship with 26H2 -- confirm which one before treating it as a bug.

---

## Common Fix Paths

<details><summary>Fix 1 -- Managed device isn't offered 26H2 (policy is holding it back, as designed)</summary>

**Cause:** An Intune Feature Update policy, WUfB `TargetReleaseVersion`/`ProductVersion` setting, or WSUS approval is deliberately pinning the device to 25H2 (or earlier) until the org is ready to move the ring forward.

**Confirm intent, don't assume malfunction:**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -ErrorAction SilentlyContinue |
    Select-Object TargetReleaseVersion, ProductVersion
```

**To move a ring to 26H2 (Intune Feature Update policy):**
```
Devices > Windows > Feature updates for Windows 10 and later
Create/Edit profile -> Feature update to deploy: Windows 11, version 26H2
Assign to the target ring's device group -> confirm rollout (offer date, install/deadline)
```
Pause/Resume/Rollback remain available from the same policy blade if the ring needs to be halted mid-rollout.

**WSUS path:** approve the 26H2 enablement package in the relevant WSUS update view/group and confirm the client's target group membership.

**Rollback:** Re-pin `TargetReleaseVersion`/`ProductVersion` to the prior value, or remove the assignment, and force a policy sync. This does not roll back devices that already upgraded -- see Fix 6 for the (time-limited) uninstall path.

</details>

<details><summary>Fix 2 -- Prerequisite cumulative update missing, eKB never gets offered</summary>

**Cause:** The enablement package has a hard dependency on the current LCU already being installed. If a device is behind on quality updates for any reason (deferred updates, a stuck update, connectivity gap), 26H2 will silently never appear as applicable -- it will not show an error, it will simply not be offered.

**Remediation:**
```powershell
# Force a scan and install of pending quality updates first
UsoClient StartScan
UsoClient StartDownload
UsoClient StartInstall
```
Verify the LCU installed, then re-check eKB availability. If quality updates themselves are stuck, that's a separate `Windows Update/Update to Latest` ticket -- resolve that first.

**Rollback:** N/A -- installing the prerequisite quality update is a normal patch, not a risky operation.

</details>

<details><summary>Fix 3 -- Safeguard hold or compatibility block preventing offer</summary>

**Cause:** Microsoft applies safeguard holds against specific driver/hardware/software compatibility issues discovered during rollout, the same mechanism used for every feature update, including eKB-delivered ones.

**Check:**
```
Settings > Windows Update > Windows Update history
```
Look for compatibility-hold messaging. There is no reliable PowerShell-only read of the specific safeguard ID from the client side; the authoritative view is the Windows release health dashboard cross-referenced against the device's installed driver/app inventory.

**Remediation:** Do not attempt to force past a safeguard hold via registry bypass (`DataCol`/`AllowExperimentation`) on production/managed fleets -- this defeats the specific protection Microsoft applied for a reason. Wait for the fix to ship, or evaluate whether the flagged driver/app can be updated/removed to clear the hold.

**Rollback:** N/A -- this is a protective block, not something to roll back.

</details>

<details><summary>Fix 4 -- Newly-default-on feature changed behavior unexpectedly after patching</summary>

**Cause:** 26H2 flips several previously opt-in or hidden features to default-on for commercial (managed) devices, without a separate visible "upgrade" prompt: Windows Settings Backup, app-specific taskbar actions, and File Explorer enhancements. A device that silently goes from 25H2 to 26H2 via the eKB will pick these up automatically.

**Most common real case -- Settings Backup toggled on unexpectedly:**
- This is a data-residency-relevant behavior change, not a bug. Cross-reference `Troubleshooting/WindowsBackup-B.md` for the full policy surface (`EnableActivityFeed`/`PublishUserActivities`/`UploadUserActivities`/`EnableCDP`/`AllowConnectedDevices` and the backup-specific CSP nodes) if the org needs to explicitly disable it rather than merely being surprised by it.

**Remediation (if the org wants the old default back):** Set the relevant policy explicitly via Intune/GPO rather than relying on the pre-26H2 default -- once a device is on 26H2, the default itself has changed, so "leave it unconfigured" no longer produces the old behavior.

**Rollback:** Set the specific feature's policy to the desired state; there is no single "revert all 26H2 defaults" switch.

</details>

<details><summary>Fix 5 -- Device is on 23H2 or earlier and needs to reach 26H2</summary>

**Cause:** The eKB fast path only exists between versions already on the shared 24H2/25H2/26H2 servicing branch. A device on 23H2 or earlier must go through a full, media-based feature update first.

**This is out of scope for this runbook** -- route to `Troubleshooting/Windows Update/Update to Latest A.md`/`B.md` for the full feature-update process, then this device becomes eligible for the eKB path described here on a future update cycle.

**Rollback:** N/A -- not applicable to this fix path.

</details>

<details><summary>Fix 6 -- Client asking about support timelines / edition planning</summary>

**Cause:** Support end dates for the 24H2/25H2/26H2 shared branch split by edition, and this is commonly asked when planning refresh/replacement budgets.

**Answer directly (verify against the current Windows lifecycle page before quoting a client, as these dates are Microsoft-published and can be revised):**
- Home, Pro, Pro Education, Pro for Workstations: supported through **October 2028**
- Enterprise, Education, IoT Enterprise: supported through **October 2029**

**If a device recently moved to 26H2 and the org wants to uninstall it (time-limited window):**
```powershell
# Uninstall via DISM (only valid for a limited post-upgrade window, same mechanism as any enablement package)
DISM /Online /Get-Packages | findstr /i "26H2"
DISM /Online /Remove-Package /PackageName:<exact package name from above>
```
Confirm the uninstall window hasn't already closed before promising a client this is possible -- Microsoft does not guarantee an indefinite rollback period for enablement packages.

**Rollback:** This fix path IS the rollback path for Fix scenarios above; there is no further rollback beyond it.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET -- Windows 11 26H2 Rollout Issue
=====================================
Device Name:                [hostname]
Current Version/Build:      [DisplayVersion / CurrentBuild.UBR]
eKB-eligible (24H2/25H2)?:  [Yes/No]
Prerequisite LCU installed: [KB____, installed date]
Management state:           [Unmanaged | Intune-managed | WSUS-managed | Autopatch]
TargetReleaseVersion/ProductVersion policy: [value, if managed]
Safeguard hold observed:    [Yes/No -- from Update history]
Newly-default-on feature involved: [Settings Backup | Taskbar | File Explorer | N/A]

Symptom description:
[what the user/admin reported]

Steps already attempted:
[ ] Confirmed current version/build
[ ] Confirmed eKB eligibility (24H2/25H2, not 23H2 or earlier)
[ ] Confirmed prerequisite LCU is installed
[ ] Checked Intune/WUfB/WSUS target-version policy
[ ] Checked Windows Update history for a safeguard/compat hold
[ ] Identified whether a newly-default-on feature explains the reported change
```

---

## Learning Pointers

- **26H2 is an enablement package, not a full feature update -- treat it accordingly.** Because 24H2, 25H2, and 26H2 share one servicing branch, most of "26H2's features" were already shipped quietly through prior monthly Cumulative Updates; the eKB itself is a ~174 KB flip-the-flags payload requiring one restart, not a multi-hour media-based upgrade. Don't schedule 26H2 like a traditional feature update project. [Windows 11, version 26H2 release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)

- **The eKB has a hard, easy-to-miss prerequisite: the current cumulative update must already be installed.** This is the single most common "why hasn't this device gotten 26H2" root cause and produces no error message -- the eKB simply never appears as applicable.

- **23H2-and-earlier devices don't get the fast path at all.** If a device isn't already on 24H2 or 25H2, this entire eKB mechanism doesn't apply to it yet -- it needs a conventional feature update first. Confirm current version before promising a quick turnaround.

- **Several features flip from opt-in/latent to default-on for commercial devices specifically.** Windows Settings Backup, app-specific taskbar actions, and File Explorer enhancements activate automatically on the version flip with no separate deployment step -- this is the most likely source of "something changed after a routine patch" tickets and should be checked before assuming a fault. [Releasing Windows 11, version 26H2 to the Release Preview Channel](https://blogs.windows.com/windows-insider/2026/08/27/releasing-windows-11-version-26h2-to-the-release-preview-channel/)

- **Support timelines split by edition, not by device age.** Home/Pro/Pro EDU/Pro Workstations get roughly one year less support runway (October 2028) than Enterprise/Education/IoT Enterprise (October 2029) on the same shared branch -- relevant for refresh-cycle budgeting conversations, and worth re-verifying against Microsoft's own lifecycle page before quoting a client, since these dates are subject to revision.

- **Three deployment tools all support staged rollout of 26H2 today: Windows Autopatch, Intune Feature Update policies + Update Rings, and WSUS.** Pause/Resume/Rollback remain available from Intune if a ring needs to be halted -- use a real ring/pilot strategy rather than a single all-at-once policy assignment, the same discipline as any other feature update.
