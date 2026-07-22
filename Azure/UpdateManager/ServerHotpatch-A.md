# Windows Server 2025 Hotpatch (Azure Arc) — Reference Runbook (Mode A: Deep Dive)
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
- Hotpatch for **Windows Server 2025 Standard and Datacenter**, enabled via **Azure Arc** and managed through **Azure Update Manager (AUM)**
- Eligibility prerequisites (OS build, edition, VBS/VSM, Arc connectivity), the enrollment/license lifecycle, and the quarterly baseline/hotpatch release cadence
- The May 2026 billing change (hotpatch now free for eligible Arc-connected machines) and the October 2025 feature-licensing bug that stalled enrollments
- Windows Server 2025 Datacenter: Azure Edition's built-in (no-Arc-required) hotpatch behavior, where it diverges from the Arc-enabled path

**Out of scope:**
- **Windows 11 client hotpatch via Windows Autopatch** — a separate product surface with its own admin plane, licensing, and enrollment mechanics. See `Intune/Troubleshooting/Hotpatch-A.md`.
- **Azure Update Manager's general assessment/scheduling/maintenance-configuration mechanics** for non-hotpatch updates — see `Azure/UpdateManager/UpdateManager-A.md`.
- **Azure Arc onboarding and Connected Machine agent deployment/connectivity troubleshooting** in general — see `Azure/Arc/AzureArc-A.md`. This runbook assumes the machine is already Arc-connected and healthy, and only covers Arc-related checks specific to unblocking hotpatch.
- **Automatic VM Guest Patching** (`patchMode: AutomaticByPlatform`) for standard Azure VMs — a different, non-Arc feature; only referenced where it intersects hotpatch terminology.
- **On-premises WSUS** and legacy Azure Automation Update Management (retired 31 Aug 2024) — not relevant to Arc-enabled hotpatch, which is fully cloud-orchestrated via AUM.

**Assumptions:**
- Target machines are Windows Server 2025 Standard or Datacenter (or Datacenter: Azure Edition), not Server 2022 or earlier — hotpatch for Server 2025 shares terminology but not architecture with any prior "on-demand hotpatch" preview program.
- You have Azure RBAC sufficient to view/manage Azure Update Manager and Azure Arc machine resources (`Azure Connected Machine Resource Administrator` or equivalent).
- The machine is already Arc-onboarded (Connected Machine agent installed, `Connected` status) unless using Datacenter: Azure Edition.

---
## How It Works

<details><summary>Full architecture — hotpatch mechanics on Arc-enabled Windows Server 2025</summary>

Hotpatch replaces the traditional monthly Latest Cumulative Update (LCU) + reboot cycle with **in-memory patching of running processes** for most months of the quarter, reserving the traditional full LCU + reboot for a single **baseline month** each quarter. The architecture has three cooperating layers:

**1. Eligibility gate (client-side, evaluated by the OS itself).** The machine must satisfy, simultaneously:
   - Windows Server 2025 Standard or Datacenter edition (Server Core or Desktop Experience — both supported), build 26100.1742 or later, non-preview/non-Insider
   - VBS/VSM actually **running** (`Win32_DeviceGuard.VirtualizationBasedSecurityStatus = 2`), which itself requires UEFI + Secure Boot at minimum, and Generation 2 on Hyper-V if virtualized
   - Connectivity to Azure via a healthy Azure Arc Connected Machine agent (`himds` service running, agent status `Connected`) — **or** the Datacenter: Azure Edition SKU, which has hotpatch built in without requiring Arc

   This mirrors the eligibility-gate pattern this repo has now documented across multiple Microsoft update surfaces (see `Intune/Troubleshooting/Hotpatch-A.md` for the client-side equivalent, and `Windows/Troubleshooting/Autopilot-Reset` for a similar silent-fail-safe gate) — the OS evaluates conditions quietly and simply falls back to standard update behavior if any one fails, with no single admin-visible error pointing at which condition is the blocker.

**2. License/enrollment plane (Azure control-plane state, separate from the update pipeline itself).** Hotpatch is not automatic just because a machine is eligible — it requires an explicit enrollment action, either per-machine (Azure Arc portal → Machines → Hotpatch → Confirm) or via Azure Update Manager (Recommended updates → Hotpatch → Change → Receive monthly Hotpatch updates → Enable). This produces one of five states surfaced in the **Hotpatch status** column: `Not enrolled`, `Pending`, `Enabled`, `Disabled`, `Canceled`. Enrollment changes take up to ~10 minutes to propagate. This plane is entirely separate from whether updates are actually being assessed/scheduled — a machine can be `Enabled` for hotpatch and still have broken assessment for unrelated reasons (see `UpdateManager-A.md`).

**3. Update delivery plane (Azure Update Manager assessment + install, same infrastructure as regular Windows updates).** Once enrolled, Windows Update on the machine begins offering hotpatches instead of full LCUs for non-baseline months. AUM's periodic or on-demand assessment surfaces the hotpatch as a recommended update; a scheduled (maintenance configuration) or one-time install applies it. AUM lets you scope installs to specific classifications or individual KB IDs — useful for controlling exactly which hotpatch is applied if multiple are outstanding.

**The baseline/hotpatch cadence.** Each quarter has one **baseline month** (a full LCU requiring a reboot, which resets the servicing stack the subsequent hotpatches build on) followed by two **hotpatch months** (in-memory patches, no reboot). A machine must be running the *exact* baseline build published for the current quarter to receive that quarter's subsequent hotpatches — any off-cycle, out-of-band, or superseding update installed outside this sequence knocks the machine off the hotpatch track until the next baseline ships, silently reverting it to regular reboot-requiring monthly updates in the interim. This exact mechanic caused real customer impact in October 2025 (see Symptom → Cause Map) when several out-of-band updates were offered outside the expected sequence.

</details>

---
## Dependency Stack

```
Azure subscription
    │
Azure Arc: Connected Machine agent installed + Connected
    │  (skipped for Windows Server 2025 Datacenter: Azure Edition — built in)
    │
OS: Windows Server 2025 Standard/Datacenter, build ≥ 26100.1742, non-preview
    │
Firmware: UEFI + Secure Boot (Gen2 VM if virtualized)
    │
VBS/VSM policy enabled AND actually Running (VirtualizationBasedSecurityStatus = 2)
    │
Hotpatch license ENROLLED (Arc portal or AUM "Change" flow) → status = Enabled
    │
Machine on the exact required baseline build for the current quarter
    │
AUM periodic/on-demand assessment detects the hotpatch as a recommended update
    │
Scheduled (maintenance configuration) or on-demand install applies it
    │
Result: patch applied in-memory, NO reboot (except during the quarterly baseline month)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Hotpatch" option doesn't appear for the machine at all | Wrong OS/edition/build, or Essentials edition, or preview build | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'` → `EditionID`, `CurrentBuild`, `UBR` |
| Enabling hotpatch fails outright in the portal | VSM/VBS not running on the target machine | `Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName Win32_DeviceGuard` |
| Hotpatch status stuck on **Pending** for far longer than the expected ~10 minutes | Arc agent connectivity issue, **or** the October 2025 feature-licensing bug on machines running KB5066835+ | `azcmagent show`; check installed KB against the affected list in Remediation Playbook 2 |
| Machine was **Enabled** and receiving hotpatches, then suddenly starts requiring a reboot every month | Machine drifted off the required baseline build (an out-of-band or non-hotpatch-track update was installed) | `Get-HotFix \| Sort-Object InstalledOn -Descending` vs. current-quarter baseline KB |
| Hotpatch status shows **Disabled** | Explicitly turned off via AUM Update settings blade (not an error state) | Machines → Settings → Update settings → check the Hotpatch column per machine |
| Hotpatch status shows **Canceled** | License was actively canceled (de-enrollment), not the same as "never enrolled" | Re-run the enrollment flow if hotpatch should be active again |
| Invoice shows a Hotpatch charge line after May 2026 | Stale/legacy billing data from before the 19 May 2026 free-tier change, or the machine is on a non-eligible edition/OS still being billed under a different meter | Confirm OS/edition eligibility; if genuinely eligible and still billed, escalate to Microsoft billing support — this is not a client-side config issue |
| Datacenter: Azure Edition machine behaves differently than Arc-enabled Standard/Datacenter | Expected — Azure Edition has hotpatch built-in and skips the Arc-enrollment step entirely, though VBS/build prerequisites still apply | Confirm `EditionID = ServerAzureEdition`; treat Arc-enrollment troubleshooting as not applicable |
| Hotpatch eligibility broke specifically after the October 2025 update window, but the machine shows no feature-licensing symptoms (enrollment isn't stuck Pending) | A **separate, distinct** October 2025 incident: an out-of-band WSUS update (KB5070881) was mistakenly offered to some Hotpatch-enrolled Server 2025 machines and broke their eligibility outright — not the same bug as the feature-licensing issue, and needs a different fix | Confirm whether KB5070881 was installed; if so, apply KB5070893 on top of the October baseline (KB5066835) per Microsoft's guidance rather than the feature-licensing workaround in Playbook 2 |
| Hotpatch applied but a specific optional/driver update was skipped that month | Hotpatch only carries security/quality fixes eligible for in-memory patching; some update types are baseline-month-only by design | Not a bug — check AUM Update history for what classification was actually installed vs. expected |

---
## Validation Steps

1. **OS/edition/build eligibility.**
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object ProductName, EditionID, CurrentBuild, UBR
   ```
   Good: `EditionID` in `{ServerStandard, ServerDatacenter, ServerAzureEdition}`, build ≥ `26100.1742`. Bad: `ServerEssentials`, older Windows Server versions, or any build below the floor.

2. **VBS/VSM running state.**
   ```powershell
   Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName 'Win32_DeviceGuard' | Select-Object -ExpandProperty VirtualizationBasedSecurityStatus
   ```
   Good: `2`. Bad: `1` (configured, not running — needs reboot or a hardware gap) or `0` (not configured).

3. **Arc agent health** (skip for Datacenter: Azure Edition).
   ```powershell
   & "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show
   ```
   Good: `Agent Status: Connected`, recent `Last Heartbeat`. Bad: `Disconnected`, `Error`, or stale heartbeat.

4. **Hotpatch enrollment status** — Azure portal, **Azure Update Manager → Machines → Edit columns → Hotpatch status**.
   Good: `Enabled`. Transitional/expected: `Pending` for a few minutes after a change. Bad: stuck `Pending`, or `Not enrolled`/`Disabled`/`Canceled` when hotpatch is expected to be active.

5. **Assessment freshness.** In **Recommended updates**, confirm a recent "Last assessed" timestamp. If stale, trigger an on-demand assessment ("Check for updates now") and re-check.

6. **Baseline currency.** Compare `Get-HotFix` output against the currently published baseline KB for the quarter (check the [Hotpatch release notes](https://support.microsoft.com/en-us/topic/release-notes-for-hotpatch-on-windows-server-2025-datacenter-azure-edition-c548437e-8c7a-4e27-99f4-e8746f97f8fa) — the specific KB number changes every baseline release, so always confirm against the live doc rather than hardcoding a KB number here).
   ```powershell
   Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 8 HotFixID, InstalledOn
   ```

7. **Update history.** In AUM, **Machines → \<machine\> → History** shows the past 30 days of deployments including reboot-required status per update — the fastest way to confirm whether a given install was hot (no reboot) or a baseline LCU.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Eligibility.** Run Validation Steps 1–3 in order. Any failure here means hotpatch cannot be enabled regardless of anything done in the Azure portal; fix the underlying gap (OS build, VBS, Arc connectivity) before touching enrollment.

**Phase 2 — Enrollment.** Confirm Validation Step 4. If `Not enrolled`, run the enrollment flow (Remediation Playbook 1). If stuck `Pending`, check the installed KB against the October 2025 affected list before assuming a generic Arc issue (Remediation Playbook 2).

**Phase 3 — Delivery.** Confirm Validation Steps 5–6. A healthy `Enabled` machine that isn't receiving hotpatches is usually either an assessment-freshness problem (trigger on-demand) or a baseline-drift problem (Remediation Playbook 3).

**Phase 4 — Confirm outcome.** Use Validation Step 7 (Update history) to confirm the most recent install was actually hot (no reboot flag) versus a baseline LCU, and that it matches the expected cadence for the current month.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Enable hotpatch enrollment (single machine or at scale)</summary>

**Single machine, portal:**
1. Azure Update Manager → Machines → select the machine
2. Recommended updates → Hotpatch → **Change**
3. Select **Receive monthly Hotpatch updates**
4. **Enable Hotpatching** → **Confirm**
5. Allow up to 10 minutes for propagation; re-check status

**At scale:**
1. Azure Update Manager → Machines → Settings → **Update settings**
2. **+ Add machine** → select target machines → **Add**
3. Set **Hotpatch** dropdown to **Enable** → **Save**

No rollback concerns — enrollment is reversible at any time via the same flow (**Disable**), and disabling does not retroactively affect already-applied hotpatches.

</details>

<details><summary>Playbook 2 — Remediate the October 2025 feature-licensing bug</summary>

**Applies to:** machines running KB5066835 (OS Build 26100.6899) or later October 2025 updates, exhibiting stuck `Pending` enrollment or unexpected reboot-requiring updates despite prior `Enabled` status. Does **not** affect Datacenter: Azure Edition.

**Registry/script method:**
```powershell
Stop-Service -Name 'HIMDS'
New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -Force
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -PropertyType 'dword' -Name '4264695439' -Value 1 -Force
try {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Subscriptions' -Name 'DeviceLicensingServiceCommandMutex' -ErrorAction Stop
} catch {
    Write-Host "DeviceLicensingServiceCommandMutex entry not present, skipping removal."
}
Restart-Computer -Confirm
```

**Group Policy method (better for fleet remediation):**
1. Install the `KB5062660 251028_18301 Feature Preview` MSI package (delivers the ADMX template)
2. `gpedit.msc` → **Computer Configuration\Administrative Templates\KB5062660 251028_18301 Feature Preview\Windows 11, version 24H2, 25H2\KB5062660 251028_18301 Feature Preview** → set to **Enabled**
3. Reboot
4. Remove the same `DeviceLicensingServiceCommandMutex` registry value as above (via script, Group Policy Preferences, or your management tool of choice) — do not delete the parent `Subscriptions` key, only this value

**Rollback:** the `FeatureManagement\Overrides` entry is additive and specific to this one feature ID; removing the key and rebooting reverts it. No other system state is altered by either method.

</details>

<details><summary>Playbook 3 — Recover from baseline drift</summary>

There is no supported way to force a mid-quarter machine back onto the hotpatch track once it has drifted off the required baseline. The correct remediation is to accept the next published quarterly baseline update (a full LCU + reboot) as a planned maintenance action — this re-synchronizes the machine and hotpatch resumes automatically the following month.

```powershell
# Confirm current position relative to baseline before scheduling the reboot window
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 8 HotFixID, InstalledOn
```
Communicate this as expected lifecycle behavior to stakeholders rather than an incident — no destructive action or rollback applies.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Windows Server 2025 hotpatch eligibility/state evidence for escalation.
.NOTES     Read-only. Run locally on the affected machine as Administrator.
            Does not query Azure Update Manager or Arc control-plane state directly —
            pair with a portal screenshot of the Hotpatch status column.
#>
$evidence = [ordered]@{
    Timestamp        = (Get-Date).ToString('u')
    ComputerName     = $env:COMPUTERNAME
    OSInfo           = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
                        Select-Object ProductName, EditionID, CurrentBuild, UBR
    VBSStatus        = (Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName 'Win32_DeviceGuard').VirtualizationBasedSecurityStatus
    ArcAgentInstalled= Test-Path "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    RecentHotfixes   = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, InstalledOn
    FeatureOverrides = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -ErrorAction SilentlyContinue
    LicensingMutex   = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Subscriptions' -Name 'DeviceLicensingServiceCommandMutex' -ErrorAction SilentlyContinue
}

if (Test-Path "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe") {
    $evidence.ArcAgentShow = & "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show
}

$evidence | ConvertTo-Json -Depth 4 | Out-File "$env:TEMP\HotpatchEvidence_$env:COMPUTERNAME.json"
Write-Host "Evidence written to $env:TEMP\HotpatchEvidence_$env:COMPUTERNAME.json" -ForegroundColor Green
```

Pair this output with: a portal screenshot of **Recommended updates** (Hotpatch row) and of **Machines → Edit columns → Hotpatch status**, plus the Arc resource ID and subscription ID.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'` | Check EditionID, CurrentBuild, UBR |
| `Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName Win32_DeviceGuard` | Check VBS/VSM running status |
| `New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\DeviceGuard' -Name EnableVirtualizationBasedSecurity -PropertyType Dword -Value 1 -Force` | Enable VBS policy (requires reboot) |
| `azcmagent show` | Arc agent connection status |
| `azcmagent logs` | Collect Arc agent logs for escalation |
| `Get-Service himds, GCArcService, ExtensionService` | Check core Arc services |
| `Get-HotFix \| Sort-Object InstalledOn -Descending` | Recent update/KB history, baseline comparison |
| `az connectedmachine extension list --machine-name <name> -g <rg>` | List Arc machine extensions via CLI |
| `Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Subscriptions' -Name DeviceLicensingServiceCommandMutex` | Clear stuck licensing mutex (Oct 2025 bug workaround) |
| `New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -Name 4264695439 -Value 1 -PropertyType dword -Force` | Force-enable the affected feature ID (Oct 2025 bug workaround) |
| `Restart-Computer -Confirm` | Apply VBS/registry changes requiring reboot |
| Portal: **Azure Update Manager → Machines → Recommended updates → Hotpatch** | Per-machine enrollment/status |
| Portal: **Azure Update Manager → Machines → Settings → Update settings** | At-scale enrollment |
| Portal: **Machines → History** | Past 30 days of update deployments, reboot status |

---
## 🎓 Learning Pointers

- The license/enrollment plane and the update-delivery plane are architecturally separate systems that happen to share one status column in the portal. A `Pending` or `Not enrolled` status is a control-plane problem to fix at the Arc/AUM level; a machine stuck requiring reboots despite `Enabled` status is almost always a baseline-drift problem to fix by accepting the next scheduled baseline, not by re-running enrollment. See [Hotpatching on Azure Arc-enabled Machines](https://learn.microsoft.com/en-us/azure/update-manager/manage-hot-patching-arc-machines).
- The October 2025 feature-licensing bug is a good case study in why "no known issues at this time" language in vendor docs doesn't retroactively fix machines that already drifted during the affected window — always check installed KB history against a documented affected-versions list before assuming current docs describe the state of every machine in a fleet. See [Enable Hotpatch for Azure Arc-enabled servers — Known issues](https://learn.microsoft.com/en-us/windows-server/get-started/enable-hotpatch-azure-arc-enabled-servers).
- Windows Server 2025 Datacenter: Azure Edition is the one SKU where the entire Arc-enrollment layer of this dependency stack simply doesn't apply — worth confirming edition first on any server-hotpatch ticket, since half the fix paths in this runbook are irrelevant to that SKU by design.
- The 19 May 2026 move to free hotpatch billing removed what had been a real adoption barrier ($1.50/core/month at GA in July 2025) — worth proactively flagging to clients who evaluated and passed on hotpatch under the old pricing, since the cost objection no longer applies. See [Simplified access to Hotpatching enabled by Azure Arc for Windows Server 2025](https://techcommunity.microsoft.com/blog/AzureArcBlog/simplified-access-to-hotpatching-enabled-by-azure-arc-for-windows-server-2025/4521251).
- This is the third Microsoft update surface this repo has documented with the identical "policy-enabled vs. actually-running VBS" distinction (Windows 11 client hotpatch, and now Server 2025 hotpatch) — worth treating as a standing diagnostic instinct on any VBS-dependent feature ticket, not something to re-derive each time.
- **October 2025 produced two separate, unrelated Server 2025 hotpatch incidents, not one** — the feature-licensing bug (Playbook 2) and a mistakenly-distributed out-of-band WSUS update (KB5070881, remediated by KB5070893 on top of the KB5066835 baseline) that broke eligibility outright. Don't assume every October-2025-era hotpatch ticket is the licensing bug; confirm which specific KB history is present before picking a fix path.
