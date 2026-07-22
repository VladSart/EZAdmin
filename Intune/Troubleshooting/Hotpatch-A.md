# Windows 11 Hotpatch (via Windows Autopatch) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Windows 11 Enterprise (24H2+) hotpatch updates as delivered exclusively through **Windows Autopatch**
- Eligibility prerequisites (license, OS build, baseline currency, VBS, Arm64 CHPE), enrollment via Windows quality update policy, and the tenant-wide default that flipped to Allow in May 2026
- The quarterly baseline/hotpatch release calendar and its interaction with feature-update timing
- Rollback, monitoring, and self-healing (automatic LCU fallback) behavior

**Out of scope:**
- **Windows Server 2025 hotpatch** — an architecturally separate product surface managed via Azure Update Manager and an optional Azure Arc subscription, with its own licensing model (free as of May 2026 for Arc-connected Server 2025 Standard/Datacenter). Shares terminology and general mechanics with this topic but a different admin plane entirely — see `Azure/UpdateManager/ServerHotpatch-A.md`.
- General Windows Autopatch deployment ring / update orchestration mechanics not specific to hotpatch — see `Intune/Troubleshooting/Autopatch-A.md`
- Windows Update for Business policy mechanics underlying quality/feature update deferral in general — see `Intune/Troubleshooting/WUfB-A.md` and `Intune/Troubleshooting/FeatureUpdates-A.md`
- Virtualization-based Security's own deployment/hardware-readiness troubleshooting beyond the "is it Running" check hotpatch depends on — see `Windows/Troubleshooting/LSA-Protection-A.md` for adjacent VBS-dependent feature context

**Assumptions:**
- Tenant has Windows Autopatch enabled and devices are already Autopatch-managed (see `Autopatch-A.md` if not)
- Devices in question are Windows 11, version 24H2 or later
- You have Intune admin center access to Windows updates policy blades and Windows Autopatch tenant administration

---
## How It Works

<details><summary>Full architecture — hotpatch mechanics on Windows 11</summary>

### What a Hotpatch Actually Is

A hotpatch is a **Monthly B-release security update** that installs and takes effect **without requiring a device restart**. It is not a lighter-weight or partial substitute for the standard cumulative update — it's the same class of monthly security content, delivered via a smaller-footprint package (significantly smaller than a standard cumulative update, which also means faster installs and less network/bandwidth consumption at scale) using an in-memory patching technique that avoids the file-replacement operations that normally force a restart.

Critically, **hotpatch has no existence outside Windows Autopatch.** There is no standalone Windows Update, WSUS, or Configuration Manager path to hotpatch a Windows 11 client — Autopatch is the orchestration layer that creates and deploys hotpatches, full stop. This is a hard architectural dependency, not a licensing convenience.

### The Baseline / Hotpatch Quarterly Cycle

Every calendar year splits into four **baseline months** (January, April, July, October) and eight **hotpatch months** (the remaining months):

| Quarter | Baseline (restart required) | Hotpatch (no restart) |
|---|---|---|
| Q1 | January | February, March |
| Q2 | April | May, June |
| Q3 | July | August, September |
| Q4 | October | November, December |

A **baseline** release is a full standard cumulative update — new features, cumulative fixes, and the foundation the quarter's hotpatches apply against — and always requires a restart. A device must be on the **current** baseline to receive that quarter's hotpatches; a device that's fallen behind (offline, deferred too aggressively, missed a deployment window) silently loses hotpatch eligibility until it catches up, with no explicit error surfaced to the admin — it simply receives the standard LCU instead, restart and all.

**A subtle timing interaction with OS version upgrades:** upgrading a hotpatch-enrolled device to a new Windows version (e.g., 24H2 → 25H2) *during a baseline month* keeps the device on the hotpatch cycle uninterrupted. Upgrading *during a hotpatch month*, however, switches the device onto the standard update path for that cycle — it requires a restart to apply the update and doesn't rejoin the hotpatch cycle until the next baseline. Teams coordinating feature-update rollout timing against hotpatch adoption need to account for this, or risk an unplanned restart wave.

### Eligibility — A Layered Gate, Not a Single Switch

Hotpatch eligibility is the intersection of several independent conditions, evaluated per-device, every cycle:

1. **License:** Windows 11 Enterprise E3 or E5, Microsoft 365 F3, Windows 11 Education A3 or A5, Microsoft 365 Business Premium, or Windows 365 Enterprise (Cloud PC)
2. **OS version:** Windows 11, version 24H2 or later
3. **Baseline currency:** the device must already be on the current quarter's baseline release
4. **Virtualization-based Security (VBS): must be actually *Running*, not merely policy-enabled.** VBS is a hard requirement for the hotpatch installer's in-memory patching mechanism to function at all. A device can have every VBS policy correctly pushed and still fail this gate if the underlying hardware/firmware never brought VBS up (Secure Boot state, TPM, driver HVCI compatibility). This is, in practice, the single most common real-world cause of "eligible on paper, never gets hotpatch."
5. **(Arm64 only) CHPE explicitly disabled:** Compiled Hybrid PE binaries — used to run 32-bit x86 applications on Arm64 hardware — live in a folder hotpatch cannot service. Arm64 devices require a one-time registry/CSP flag (`HotPatchRestrictions=1`) before hotpatch will apply at all. This flag persists across updates once set, but disabling CHPE can break any remaining 32-bit x86 app (including 32-bit Office/VBA/COM add-ins) still running via CHPE emulation — a real trade-off, not a formality, especially given 32-bit Microsoft 365 Apps on Arm64 stopped receiving feature updates in October 2025 and lose security updates entirely in December 2026.
6. **Intune enrollment:** a Windows quality update policy targeting the device must have "When available, apply updates without restarting the device (Hotpatch)" set to **Allow**

A device failing *any* of these conditions is not blocked or flagged — it is simply and silently offered the standard Latest Cumulative Update (LCU) instead, with all of its other configured update-ring/deferral settings unchanged. This "fail quiet, fail safe" design means the device stays fully patched (via the LCU path) even when hotpatch itself can't apply — but it also means an admin investigating "why does this device keep rebooting when others don't" gets no direct signal pointing at which of the six conditions is the blocker; each has to be checked explicitly.

### The May 2026 Default-On Change

Prior to the May 2026 security update cycle, hotpatch enrollment required deliberate opt-in via a Windows quality update policy. **Starting with the May 2026 update, Windows Autopatch enables hotpatch by default for every eligible device, tenant-wide**, unless an admin has explicitly configured the tenant-level setting to Block. Microsoft introduced the opt-out control itself on April 1, 2026 — giving organizations a roughly six-week window to evaluate and decide before the default took effect.

The practical consequence for any client whose Intune tenant nobody actively administers on a monthly cadence: their eligible Windows 11 24H2+ devices may already be receiving hotpatch updates as of this cycle, with zero explicit action taken by anyone. This is worth checking proactively during any Windows 11 fleet health review from mid-2026 onward — "we haven't touched Autopatch hotpatch settings" is no longer synonymous with "hotpatch is off for us."

### Enrollment Mechanics — a Separate Policy Object, Not a Ring Setting

Hotpatch is enabled via a dedicated setting inside a **Windows quality update policy** ("When available, apply updates without restarting the device (Hotpatch)" = Allow) — it is not a property of an Autopatch deployment ring itself, and turning it on does **not** alter any existing deferral or active-hours configuration on the targeted devices; both apply in parallel. Organizations using **Autopatch groups** specifically must create and assign a *separate, dedicated* Hotpatch-enabled quality update policy — an existing non-Hotpatch policy covering a group does not retroactively gain hotpatch behavior when the feature is turned on elsewhere.

### Rollback and Self-Healing

There is **no automatic rollback** for a hotpatch update — if a hotpatch causes a regression, the remediation path is a manual uninstall (`wusa /uninstall`) followed by installing the standard LCU and restarting, which is itself a restart-requiring operation. This is a meaningful operational difference from how most teams are used to reasoning about a bad standard cumulative update, where built-in uninstall/rollback tooling is more commonly reached for automatically or via known runbooks.

Separately, hotpatch ships with an **inbox monitor service** that watches for update-health errors on the device itself. If it detects a critical error, it logs to the Windows Application log and **automatically falls back the device to the standard LCU** to guarantee the device remains fully secure — a self-healing safety net distinct from, and faster-acting than, any admin-initiated rollback.

</details>

---
## Dependency Stack

```
Windows 11, version 24H2+ with an eligible license SKU
  └── Device on the CURRENT quarterly baseline release (Jan/Apr/Jul/Oct — a
      device behind on baseline silently loses hotpatch eligibility)
        └── Virtualization-based Security actually RUNNING (policy-enabled
            alone is insufficient — hardware/firmware must have brought it up)
              ├── (Arm64 only) CHPE explicitly disabled (one-time,
              │   persistent, potentially app-breaking registry/CSP flag)
              └── Windows Autopatch manages enrollment — no standalone
                  Windows Update/WSUS hotpatch path exists for Windows 11
                    └── Windows quality update policy assigned to the
                        device with Hotpatch = Allow (a separate setting
                        object from ring/deferral configuration, which
                        remains independently in effect)
                          └── (tenant-wide, since May 2026) DEFAULT = Allow
                              unless explicitly set to Block at the tenant
                              level (opt-out control available since 1 Apr 2026)
                                └── Hotpatch month (8/12): monthly B-release
                                    installs, NO restart
                                └── Baseline month (4/12): cumulative update
                                    installs, restart REQUIRED regardless
                                    of hotpatch enrollment
                                      └── Inbox monitor service watches
                                          post-install health — critical
                                          error auto-falls-back device to
                                          standard LCU (self-healing)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device restarted this month despite hotpatch being "on" | This is a baseline month (Jan/Apr/Jul/Oct) — expected for every hotpatch-enrolled device | Compare current month against the baseline calendar |
| Device never receives hotpatch, always gets the restart-requiring LCU | One or more of the six eligibility conditions is failing silently — most commonly VBS not actually Running | Check `VirtualizationBasedSecurityStatus` directly, not just policy state |
| Device was hotpatch-eligible last quarter, isn't this quarter | Device fell behind on the current baseline release (missed deployment window, extended offline period, aggressive deferral) | `Get-HotFix` — compare most recent install date against the current baseline month |
| Arm64 device never gets hotpatch despite meeting every other prerequisite | CHPE not yet disabled — hotpatch cannot service `SyChpe32` content | Check `HotPatchRestrictions` registry value |
| Org "never configured hotpatch" but devices are receiving it anyway | Tenant-wide default flipped to Allow starting the May 2026 update cycle | Check Tenant administration > Windows Autopatch > Tenant management > Tenant settings |
| Device enrolled and eligible but still gets the LCU some months | Device upgraded to a new Windows version during a hotpatch month, temporarily switching it to the standard update path until the next baseline | Check OS upgrade history against the baseline/hotpatch calendar |
| A hotpatch update caused an application/driver regression | No automatic rollback exists for hotpatch — this requires a manual, restart-requiring remediation | `wusa /uninstall /kb:<KB>` then install LCU and restart |
| Devices unexpectedly all fell back to LCU/restart behavior on the same day | Inbox hotpatch monitor service detected a critical health error and self-triggered fallback to LCU across the fleet | Application log — search for "hotpatch" critical events |
| Autopatch group's devices don't receive hotpatch even though "hotpatch is enabled somewhere in the tenant" | Autopatch groups require a *separate, dedicated* Hotpatch-enabled quality update policy — it doesn't inherit from a regular policy | Confirm a distinct Hotpatch policy exists and targets the group |

---
## Validation Steps

**Step 1 — Confirm OS build and license eligibility**
```powershell
Get-ComputerInfo | Select-Object WindowsProductName, OsBuildNumber
```
Expected: build 26100 (24H2) or later; cross-check license SKU in Entra ID against the eligible list.

**Step 2 — Confirm baseline currency**
```powershell
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5
```
Expected: the most recent cumulative update install date falls within the current baseline quarter.

**Step 3 — Confirm VBS is Running, not just enabled**
```powershell
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
    Select-Object VirtualizationBasedSecurityStatus, AvailableSecurityProperties, SecurityServicesRunning
```
Expected: `VirtualizationBasedSecurityStatus = 2` (Running).

**Step 4 — (Arm64 only) Confirm CHPE disable state**
```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name HotPatchRestrictions -ErrorAction SilentlyContinue
```
Expected: `HotPatchRestrictions = 1` if hotpatch eligibility is required on this Arm64 device.

**Step 5 — Confirm Intune policy assignment and setting**
Intune admin center: **Devices > Windows updates > Quality updates** — confirm a policy targeting the device has Hotpatch = Allow.

**Step 6 — Confirm tenant-wide default**
Intune admin center: **Tenant administration > Windows Autopatch > Tenant management > Tenant settings** — confirm current Allow/Block state and whether it was ever deliberately set.

**Step 7 — Confirm local enrollment flag and recent event history**
```
Start > Settings > Windows Update > Advanced options > Configured update policies >
"Enable hotpatching when available"
```
```powershell
Get-WinEvent -LogName "Application" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object Message -match "hotpatch"
```
Expected: enrollment flag present; no critical hotpatch errors in Application log.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Eligibility Layer
1. Confirm OS build, license SKU, and baseline currency
2. Confirm VBS status directly via CIM, not by trusting policy presence alone
3. (Arm64 only) Confirm CHPE disable state and evaluate legacy 32-bit app impact before changing it

### Phase 2 — Enrollment/Policy Layer
1. Confirm a Windows quality update policy with Hotpatch = Allow targets the device (or its Autopatch group, via a dedicated Hotpatch policy)
2. Confirm the tenant-wide default setting and whether it was deliberately configured
3. Confirm existing ring/deferral settings are unaffected (they run in parallel, not replaced)

### Phase 3 — Calendar/Timing Layer
1. Confirm whether the current month is a baseline month (restart expected) or a hotpatch month
2. Check OS upgrade history for a mid-hotpatch-month version upgrade that would have temporarily reverted the device to standard updates
3. Confirm the device hasn't drifted behind the current baseline

### Phase 4 — Post-Install Health Layer
1. Check Application log for hotpatch monitor service critical errors
2. Determine whether an automatic self-healing fallback to LCU already occurred
3. If a regression is confirmed, plan the manual uninstall-and-restart remediation rather than expecting automatic rollback

### Phase 5 — Recovery Verification
1. Re-run the eligibility check sequence (Steps 1-4 above) and confirm all conditions pass
2. Confirm the device receives the next hotpatch cycle without a restart
3. If Arm64 CHPE was disabled, confirm no legacy 32-bit application regressions were introduced

---
## Remediation Playbooks

<details><summary>Playbook 1 — Roll out hotpatch deliberately across a fleet (pre- or post-May-2026-default)</summary>

**Scenario:** A client wants controlled, deliberate hotpatch adoption rather than relying on (or being surprised by) the tenant-wide default.

**Step 1 — Decide the tenant-level posture explicitly**
```
Tenant administration > Windows Autopatch > Tenant management > Tenant settings >
"When available, apply updates without restarting the device (Hotpatch)"
```
Set to Block if the client wants to opt out entirely and manage rollout purely via per-group policies instead; leave Allow (the default since May 2026) if fleet-wide adoption is acceptable.

**Step 2 — Create a pilot Hotpatch-enabled quality update policy**
Target a small pilot device group first — a Windows quality update policy with Hotpatch = Allow, scoped narrowly.

**Step 3 — Validate eligibility across the pilot group before wider rollout**
Run the eligibility validation steps (OS build, VBS Running, baseline currency, Arm64 CHPE if relevant) against every pilot device — don't assume uniform readiness across a fleet with mixed hardware.

**Step 4 — Expand to broader Autopatch groups with dedicated Hotpatch policies**
Remember: existing non-Hotpatch quality update policies don't gain hotpatch behavior automatically — each targeted group needs its own explicit Hotpatch-enabled policy.

**Rollback note:** Setting the tenant or per-policy setting to Block is immediate and safe — affected devices revert to standard LCU behavior with no other configuration impact.

</details>

<details><summary>Playbook 2 — Enable hotpatch on an Arm64 fleet with legacy 32-bit application dependencies</summary>

**Scenario:** An Arm64 device fleet is otherwise hotpatch-eligible, but some devices run legacy 32-bit x86 applications via CHPE emulation.

**Step 1 — Inventory which devices actually depend on CHPE-emulated 32-bit apps**
Audit installed applications for 32-bit x86 binaries, particularly 32-bit Microsoft 365 Apps/Office, VBA macros using `Declare` statements, and 32-bit COM add-ins with no 64-bit alternative.

**Step 2 — Prioritize migrating those apps to 64-bit where possible**
Given 32-bit Microsoft 365 Apps on Arm64 stopped receiving feature updates in October 2025 and lose security updates in December 2026, this is a forcing function independent of hotpatch — treat CHPE disablement planning as part of that broader migration, not a standalone hotpatch task.

**Step 3 — For devices confirmed safe, disable CHPE and enroll in hotpatch**
```powershell
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name HotPatchRestrictions -Value 1 -Type DWord
Restart-Computer -Force
```

**Step 4 — Exclude devices still requiring CHPE from hotpatch policies**
Scope those devices out of the Hotpatch-enabled quality update policy — they'll continue receiving the standard LCU with restarts, which is the correct trade-off until the underlying app dependency is resolved.

**Rollback note:** CHPE can be re-enabled (`HotPatchRestrictions=0` + restart) at any time if a disablement turns out to have broken an app — treat this as a per-device decision, not an irreversible one.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Windows 11 Hotpatch Evidence Collector
.NOTES     Run locally on the affected device
#>

$reportPath = "C:\Temp\HotpatchEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== OS Build / License Context ===" | Out-File "$reportPath\01_OSInfo.txt"
Get-ComputerInfo | Select-Object WindowsProductName, OsBuildNumber, CsSystemType |
    Out-File "$reportPath\01_OSInfo.txt" -Append

"=== VBS Status ===" | Out-File "$reportPath\02_VBS.txt"
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
    Out-File "$reportPath\02_VBS.txt" -Append

"=== Recent Hotfix / Baseline Currency ===" | Out-File "$reportPath\03_HotFix.txt"
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 |
    Out-File "$reportPath\03_HotFix.txt" -Append

"=== CHPE State (Arm64 only) ===" | Out-File "$reportPath\04_CHPE.txt"
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name HotPatchRestrictions -ErrorAction SilentlyContinue |
    Out-File "$reportPath\04_CHPE.txt" -Append

"=== Hotpatch-Related Application Log Events ===" | Out-File "$reportPath\05_AppLog.txt"
Get-WinEvent -LogName "Application" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object Message -match "hotpatch" |
    Out-File "$reportPath\05_AppLog.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check OS build | `Get-ComputerInfo \| Select WindowsProductName, OsBuildNumber` |
| Check VBS running state | `Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard` |
| Check recent hotfix/baseline currency | `Get-HotFix \| Sort InstalledOn -Descending` |
| Check Arm64 CHPE disable state | `Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name HotPatchRestrictions` |
| Disable CHPE (Arm64, one-time, requires restart) | `Set-ItemProperty ... -Name HotPatchRestrictions -Value 1 -Type DWord` |
| Uninstall a problematic hotpatch | `wusa /uninstall /kb:<KBNumber> /quiet /norestart` |
| Check hotpatch-related Application log events | `Get-WinEvent -LogName Application \| Where Message -match "hotpatch"` |
| Intune: policy blade | Devices > Windows updates > Quality updates |
| Intune: tenant-wide default | Tenant administration > Windows Autopatch > Tenant management > Tenant settings |
| Local enrollment flag (UI) | Settings > Windows Update > Advanced options > Configured update policies |

---
## 🎓 Learning Pointers

- **This topic's headline finding is the May 2026 default-on flip — it's a live, current change, not background theory.** Every other Windows 11 hotpatch mechanic (baseline calendar, VBS gate, CHPE) has existed since the feature's earlier rollout; the tenant-wide default becoming Allow is what makes this worth checking proactively across a client fleet right now, not just when a ticket comes in. [Securing devices faster with hotpatch updates on by default](https://techcommunity.microsoft.com/blog/windows-itpro-blog/securing-devices-faster-with-hotpatch-updates-on-by-default/4500066)
- **Eligibility is a six-condition AND, evaluated silently, every cycle — and the failure mode is always "fall back to LCU," never an error.** This repo has seen this "fail quiet, fail safe" pattern before (Autopatch Reset's WinRE preflight gate, Cloud PKI's degraded-but-functional trial-key model) — it's a recurring Microsoft design philosophy worth recognizing rather than re-learning each time. [Hotpatch updates](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/manage/windows-autopatch-hotpatch-updates)
- **VBS "policy enabled" vs. "actually Running" is the single highest-yield check for "why doesn't this device get hotpatch."** Don't stop at confirming the CSP/GPO pushed correctly — always confirm the runtime state directly via `Win32_DeviceGuard`.
- **Windows 11 client hotpatch and Windows Server 2025 hotpatch are two different products wearing the same name.** One is Autopatch/Intune-managed for clients, the other is Azure Update Manager/Arc-managed for servers, with entirely separate admin surfaces, licensing, and troubleshooting paths — don't let a client's Windows Server hotpatch documentation search lead to applying server-side fixes to a client-side ticket, or vice versa. [Hotpatch for Windows Server Azure Edition](https://learn.microsoft.com/en-us/windows-server/get-started/enable-hotpatch-azure-edition)
- **There is no automatic rollback for a bad hotpatch — this is a genuine operational gap worth flagging to clients proactively**, especially ones used to reaching for built-in update-rollback tooling. Budget for a manual, restart-requiring remediation path if hotpatch adoption is being rolled out at scale.
- Community discussion (Windows Forum, 4sysops, Petri, BleepingComputer) has been closely tracking the May 2026 default-on rollout since Microsoft's own announcement — worth a quick current-events check before assuming a client's "hotpatch just started happening" ticket is a misconfiguration rather than the expected platform-wide behavior change.
