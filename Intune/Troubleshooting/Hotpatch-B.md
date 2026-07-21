# Windows 11 Hotpatch (via Windows Autopatch) — Hotfix Runbook (Mode B: Ops)
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

Run these first, on the affected device unless noted otherwise:

```powershell
# 1. Is this device even eligible? (Windows 11 24H2+, check build)
[System.Environment]::OSVersion.Version
Get-ComputerInfo | Select-Object WindowsProductName, OsBuildNumber, OsHardwareAbstractionLayer

# 2. Is Virtualization-based Security actually RUNNING (not just enabled)?
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
    Select-Object VirtualizationBasedSecurityStatus

# 3. Is the device enrolled in hotpatch, per the local policy state?
# Event Viewer > search filter for "AllowRebootlessUpdates" — look for isEnrolled:1, vbsState:2
Get-WinEvent -LogName "Microsoft-Windows-WaaSMedic/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object Message -match "AllowRebootlessUpdates"

# 4. Is the TENANT-level default currently Allow or Block? (Intune admin center — no CLI equivalent)
# Tenant administration > Windows Autopatch > Tenant management > Tenant settings >
#   "When available, apply updates without restarting the device (Hotpatch)"

# 5. Recent hotpatch-specific errors?
Get-WinEvent -LogName "Application" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Where-Object Message -match "hotpatch"
```

| What you see | What it means |
|---|---|
| OS build below 24H2, or a non-eligible license (no E3/E5/M365 F3/A3/A5/Business Premium/Windows 365 Enterprise) | Device is permanently ineligible for hotpatch — it will always receive the standard Latest Cumulative Update (LCU) with a restart. Not a fault. |
| `VirtualizationBasedSecurityStatus` not `Running` | VBS is the hard, silent gate — device is "temporarily ineligible" until VBS is actually running, not just policy-enabled. Go to Fix 1. |
| `AllowRebootlessUpdates` payload shows `isEnrolled:0` | Device isn't enrolled in a Hotpatch-enabled quality update policy — check Intune policy assignment. Go to Fix 2. |
| Device rebooted this month even though "hotpatch is on" | This is likely a **baseline month** (Jan/Apr/Jul/Oct) — baseline releases always require a restart, hotpatch only applies in the 8 non-baseline months. Not a fault — check the calendar first. |
| Tenant hasn't touched the Hotpatch tenant setting since before May 2026 | As of the May 2026 rollout, hotpatch is **default-Allow tenant-wide** for every eligible device unless someone explicitly set it to Block — a client who "never configured this" may already be running it. Go to Fix 3 if this is unexpected. |
| A hotpatch update caused a regression | No automatic rollback exists for hotpatch — go to Fix 4 (manual uninstall + LCU + restart). |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows 11, version 24H2 or later, with an eligible license (E3/E5, M365 F3,
Education A3/A5, Business Premium, or Windows 365 Enterprise)
  └── Device is on the current HOTPATCH BASELINE (quarterly: Jan/Apr/Jul/Oct
      cumulative update, restart required) — hotpatch cannot apply to a
      device that has drifted off the current baseline
        └── Virtualization-based Security (VBS) actually RUNNING on the
            device (not merely policy-enabled — the installer hard-requires it)
              ├── (Arm64 CPUs only) Compiled Hybrid PE (CHPE) explicitly
              │   disabled via CSP/registry — required once, persists
              │   across updates, but can break legacy 32-bit x86 apps
              │   still relied on via CHPE emulation
              └── Windows Autopatch manages the enrollment — hotpatch does
                  NOT exist outside Autopatch; there is no standalone
                  Windows Update/WSUS hotpatch path for Windows 11
                    └── A Windows quality update policy with "apply without
                        restarting the device (Hotpatch)" = Allow is
                        assigned to the device (existing ring/deferral
                        settings are honored unchanged alongside it)
                          └── (tenant-wide, since May 2026) DEFAULT = Allow
                              unless an admin explicitly set the tenant
                              setting to Block before/after the April 2026
                              opt-out control became available
                                └── During a hotpatch month (8 of 12): the
                                    monthly B-release installs with NO
                                    restart
                                └── During a baseline month (4 of 12): a
                                    restart-required cumulative update
                                    installs regardless of hotpatch status
```

Key failure points:
- VBS "enabled in policy" is not the same as VBS "Running" — this is the single most common reason an otherwise-eligible device keeps getting the restart-requiring LCU
- A device that misses a baseline update (offline, deferred too long) silently falls off hotpatch eligibility until it catches up — no error, just quietly reverts to LCU behavior
- Ineligible devices are never blocked or flagged loudly — they're just quietly offered the LCU instead, with existing ring settings otherwise unchanged
- The May 2026 tenant-wide default flip means "we never configured hotpatch" no longer means "hotpatch is off" — it now means "hotpatch is on, by default, for every eligible device"
- Arm64 CHPE disablement is a one-time, persistent, and potentially app-breaking change — never toggle it blanket-wide without checking for 32-bit x86 legacy app dependencies first

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm hardware/license eligibility**
```powershell
Get-ComputerInfo | Select-Object WindowsProductName, OsBuildNumber
```
Expected: build 26100 (24H2) or later. Cross-check the device's assigned license against the eligible list (E3/E5, M365 F3, Education A3/A5, Business Premium, Windows 365 Enterprise) in Entra ID/Intune.

**Step 2 — Confirm the device is on the current hotpatch baseline**
```powershell
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5
```
Compare the most recent cumulative update's release month against the baseline calendar (Jan/Apr/Jul/Oct). A device more than one baseline cycle behind is not hotpatch-eligible until it catches up.

**Step 3 — Confirm VBS is actually running, not just enabled**
```powershell
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
    Select-Object VirtualizationBasedSecurityStatus, AvailableSecurityProperties
```
Expected: `VirtualizationBasedSecurityStatus = 2` (Running). `0`/`1` means not running — this is a hard gate, not a soft warning.

**Step 4 — Confirm the device-local hotpatch enrollment flag**
```
Start > Settings > Windows Update > Advanced options > Configured update policies >
"Enable hotpatching when available"
```
Expected: present and enabled if the device is meant to be enrolled.

**Step 5 — Confirm the Intune-side policy and tenant default**
In the Intune admin center: **Devices > Windows updates > Quality updates**, open the relevant policy, confirm "When available, apply without restarting the device (Hotpatch)" = **Allow**. Then check **Tenant administration > Windows Autopatch > Tenant management > Tenant settings** for the tenant-wide default (Allow since May 2026 unless explicitly overridden).

**Step 6 — Check for hotpatch-specific errors in Application logs**
```powershell
Get-WinEvent -LogName "Application" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object Message -match "hotpatch"
```
Expected: no critical errors. A critical error here means the inbox hotpatch monitor service already fell back to the standard LCU on its own — the device will restart-install as a self-healing measure.

---
## Common Fix Paths

<details><summary>Fix 1 — VBS is enabled but not actually Running</summary>

**Cause:** VBS policy is configured, but the underlying hardware/firmware state (Secure Boot, virtualization extensions, driver compatibility) is preventing it from actually starting.

```powershell
# Confirm current state
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard

# Confirm the CSP-driven policy is applied
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceGuard" -ErrorAction SilentlyContinue
```
Investigate hardware readiness (Secure Boot status, TPM state, driver compatibility with HVCI) — this is a platform prerequisite issue, not something hotpatch policy itself can fix. Cross-reference `Windows/Troubleshooting/LSA-Protection-A.md` for related VBS-dependent feature diagnostics.

**Rollback note:** N/A — investigation only, no destructive change made by this fix path itself.

</details>

<details><summary>Fix 2 — Device not enrolled in a Hotpatch-enabled quality update policy</summary>

**Cause:** No Windows quality update policy with the Hotpatch setting = Allow is assigned to this device, or the device isn't in an Autopatch group with a dedicated Hotpatch policy.

**In Intune admin center:**
1. **Devices > Windows updates > Quality updates** — confirm a policy exists and is assigned to this device's group
2. Edit the policy, confirm **"When available, apply without restarting the device (Hotpatch)"** = **Allow**
3. If using **Autopatch groups**, confirm a *separate, dedicated* Hotpatch policy was created and assigned — turning on Hotpatch does not retroactively apply to devices only covered by a regular (non-Hotpatch) quality update policy

**Rollback note:** Setting the policy to Block is safe and immediate — device falls back to standard LCU behavior with a restart, existing ring/deferral settings unaffected.

</details>

<details><summary>Fix 3 — Hotpatch is unexpectedly active tenant-wide (nobody explicitly enabled it)</summary>

**Cause:** As of the May 2026 rollout, hotpatch defaults to **Allow** tenant-wide for every eligible device unless an admin explicitly set the tenant setting to Block. A tenant that never touched this setting is not "off by default" anymore.

```
Intune admin center > Tenant administration > Windows Autopatch > Tenant management >
Tenant settings > "When available, apply updates without restarting the device (Hotpatch)"
```
Set to **Block** at the tenant level if the client wants to opt out entirely, or leave **Allow** and manage exposure per-group via individual quality update policies instead.

**Rollback note:** Reversible at any time — toggling the tenant setting takes effect on the next applicable update cycle, no immediate device impact.

</details>

<details><summary>Fix 4 — A hotpatch update caused a regression and needs to come off</summary>

**Cause:** No automatic rollback exists for a hotpatch update — unlike a standard update, there's no built-in "uninstall and revert" safety net triggered automatically.

```powershell
# List recently installed hotfixes to identify the specific hotpatch KB
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10

# Uninstall the specific hotpatch (replace with actual KB number)
wusa /uninstall /kb:<KBNumber> /quiet /norestart

# Then install the latest standard cumulative update (LCU) and restart
# — via Windows Update UI, or push the equivalent quality update policy without Hotpatch
Restart-Computer -Force
```

**Rollback note:** This is itself the rollback path — expect a mandatory restart. There is no "undo the uninstall"; if the regression persists after moving to the LCU, escalate as a standard update-quality issue, not a hotpatch-specific one.

</details>

<details><summary>Fix 5 — Arm64 device not receiving hotpatch despite meeting all other prerequisites</summary>

**Cause:** Compiled Hybrid PE (CHPE) binaries are still active — hotpatch cannot service `%SystemRoot%\SyChpe32` content, so it's blocked entirely on Arm64 until CHPE is explicitly disabled.

```powershell
# Check current CHPE registry state
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name HotPatchRestrictions -ErrorAction SilentlyContinue

# Set the disable flag (one-time, persists across updates) — then RESTART the device
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name HotPatchRestrictions -Value 1 -Type DWord
```
⚠️ Before applying: confirm no 32-bit x86 legacy apps (including 32-bit Office or VBA/32-bit COM add-ins) are relied on via CHPE emulation — disabling it can break them. Check with the client if uncertain.

**Rollback note:** Reversible — set `HotPatchRestrictions=0` and restart to re-enable CHPE (and lose hotpatch eligibility on that device again).

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Windows 11 Hotpatch (Windows Autopatch) Issue

Device name: ______________________
OS build: __________________________
License SKU: _______________________
VBS status (Get-CimInstance Win32_DeviceGuard): ___________

Symptom: (device won't stop rebooting / device never gets hotpatch / regression
          after a hotpatch / Arm64 CHPE issue / unexpected tenant-wide default)

Current hotpatch baseline month vs. this month: ___________

Quality update policy assignment + Hotpatch setting (Intune):
---
[paste here]
---

Tenant-level Hotpatch default (Tenant administration > Windows Autopatch):
---
[paste here]
---

Event Viewer AllowRebootlessUpdates payload:
---
[paste here]
---

Application log hotpatch-related errors, if any:
---
[paste here]
---

Steps already attempted:
[ ] Confirmed device is on the current hotpatch baseline
[ ] Confirmed VBS status is Running (not just enabled)
[ ] Confirmed Intune quality update policy Hotpatch setting
[ ] Confirmed tenant-level default setting
[ ] Confirmed this isn't simply a baseline month (Jan/Apr/Jul/Oct)
[ ] (Arm64 only) Checked CHPE disable state and legacy-app impact
```

---
## 🎓 Learning Pointers

- **"We never configured hotpatch" stopped meaning "hotpatch is off" in May 2026.** Windows Autopatch flipped the tenant-wide default to Allow for every eligible device starting with the May 2026 security update — a client's fleet may already be running hotpatch behavior even if nobody on their side (or the MSP's) ever touched the setting. Check the tenant setting explicitly rather than assuming based on "we didn't set this up." [Securing devices faster with hotpatch updates on by default](https://techcommunity.microsoft.com/blog/windows-itpro-blog/securing-devices-faster-with-hotpatch-updates-on-by-default/4500066)
- **VBS "enabled" and VBS "Running" are different states, and only "Running" satisfies the hotpatch prerequisite.** A device can look fully compliant on paper (policy pushed, feature flag set) and still silently fall back to the restart-requiring LCU because the underlying platform never actually brought VBS up. Always check `VirtualizationBasedSecurityStatus` directly, not just policy presence. [Hotpatch updates — prerequisites](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/manage/windows-autopatch-hotpatch-updates)
- **The quarterly baseline calendar (Jan/Apr/Jul/Oct) is the first thing to check whenever "hotpatch isn't working" turns out to mean "the device restarted this month."** Restarting during a baseline month is expected behavior for every hotpatch-enrolled device, not a sign anything is broken.
- **This is architecturally a different product from Windows Server 2025 hotpatch**, despite the shared name and similar mechanics. Windows 11 client hotpatch is Windows Autopatch/Intune-managed; Windows Server 2025 hotpatch is Azure Update Manager + Azure Arc-managed, with its own separate licensing/eligibility model. Don't assume a fix or setting from one applies to the other.
- **No automatic rollback exists for a bad hotpatch — plan for a manual uninstall-and-restart path, not a one-click revert.** This is a meaningful operational difference from how most orgs are used to handling a bad standard cumulative update.
