# Quick Machine Recovery (QMR) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why QMR behaves the way it does, not just what to click.

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
- Quick Machine Recovery's architecture: cloud remediation and auto remediation as two independently-gated layers built on top of Windows Recovery Environment (WinRE) and Startup Repair
- The management-state-dependent default behavior (unmanaged vs. Enterprise/Education/managed Pro) and its "sticky once explicit" override rule
- Governance via the `Recovery` configuration service provider (CSP), specifically the `QuickMachineRecovery` node, and its Intune Settings Catalog surface
- WinRE network connectivity constraints (wired / WPA-WPA2-password Wi-Fi only — no 802.1X/Enterprise Wi-Fi support) and the `NetworkSettings/Wifi` fallback-profile mechanism
- Verification (`reagentc.exe /getrecoverysettings`) and test-mode validation (Windows Insider Experimental channel only)

**Out of scope:**
- Startup Repair internals as a standalone topic (QMR builds on it, but classic non-QMR Startup Repair troubleshooting is not duplicated here)
- WinRE partition/image repair when `reagentc /enable` itself fails due to a missing or corrupted recovery image — that is a separate WinRE-health topic
- Windows Recall and other Copilot+/NPU-gated AI features — architecturally unrelated; QMR requires no special hardware
- The sibling `PointInTimeRestore` node under the same `Recovery` CSP (restore points for user-driven rollback, not boot-failure remediation) — noted below only as a disambiguation, not covered in depth

**Assumptions:**
- Windows 11, version 24H2 or 25H2 (exact minimum build is disputed between two Microsoft sources — see Dependency Stack)
- Reader has local admin on the device and Intune/CSP edit rights if a policy-level fix is needed
- PowerShell 5.1 baseline; most verification is via `reagentc.exe` (a native Windows tool, not a PowerShell module) since no dedicated `QuickMachineRecovery` PowerShell cmdlets exist as of this writing

---

## How It Works

<details><summary>Full architecture</summary>

### Origin and Rollout Timeline

Quick Machine Recovery was announced at Microsoft Ignite in November 2024 as a response to the operational lesson of large-scale boot-failure incidents (most notably the July 2024 CrowdStrike-driven outage), where organizations needed a way to remediate widespread, identical boot failures across a fleet without manual hands-on-keyboard recovery at every device. It began appearing in Beta/Dev Channel Windows Insider Preview builds in March 2025, entered gradual production rollout for Windows 11 24H2 in July 2025, and is current (GA) on 24H2 and 25H2 as of this writing.

### Building on Startup Repair, Not Replacing It

QMR does not replace Startup Repair — it wraps it with a cloud-connected remediation-lookup step:

```
Device fails to boot repeatedly (Windows detects the pattern automatically)
        │
        ▼
Boots into Windows Recovery Environment (WinRE)
        │
        ▼
   Is Cloud Remediation enabled?
        │
   ┌────┴────┐
   NO         YES
   │           │
   ▼           ▼
Startup    Attempts network connection (wired or WPA/WPA2-password Wi-Fi)
Repair          │
(local-only,    ▼
 no cloud   Scans Windows Update for a known remediation matching this
 lookup)    specific widespread failure signature
                │
           ┌────┴────┐
         Found      Not found
           │           │
           ▼           ▼
      Downloads    Falls back to ordinary recovery options
      and applies  (Startup Repair, Reset, Advanced options —
      the fix,     whatever the device would have shown anyway)
      reboots
```

This is why QMR is described by Microsoft as "best-effort": if no matching remediation exists in Windows Update for the specific failure signature, the device simply falls through to the recovery experience it would have had without QMR at all — there is no worse-case downside beyond the time spent attempting the network lookup.

### Two Independent Settings: Cloud Remediation and Auto Remediation

These are commonly conflated but are genuinely separate gates:

- **Cloud remediation** (`EnableQuickMachineRecovery`) — controls whether WinRE is *allowed* to reach out to Windows Update at all during a recovery scenario. This is the master switch.
- **Auto remediation** (`AutoRemediationSettings/EnableAutoRemediation`) — controls whether the remediation-lookup-and-retry cycle happens *automatically without user interaction*. If cloud remediation is on but auto remediation is off (or not configured), the device still connects and scans on the first pass, but if no fix is found the user is guided to other recovery options manually rather than having the device automatically retry on a timer.

Auto remediation, when enabled, has two further sub-settings that only take effect together:
- `SetRetryInterval` — minutes between retry attempts (0–4320; 0 means "scan once, no retries")
- `SetTimeToReboot` — total minutes the device will spend in WinRE attempting remediation before it gives up and returns control to the user (1–4320, max 72 hours)

Microsoft's own CSP documentation states the retry interval **must** be less than or equal to the time-to-reboot value for the setting to behave as documented — configuring it the other way around produces undefined/unreliable behavior rather than a clean validation error.

### The Management-State-Dependent Default — Why It Exists and Why It's Easy to Miss

QMR's default state is not a single fixed value; it is a fork based on whether the device is considered "managed":

| Device state | Default Cloud Remediation | Default Auto Remediation |
|---|---|---|
| Windows Home, or Pro not domain-joined/not MDM-enrolled ("unmanaged") | **ON** | One-time scan (not looped) |
| Windows Enterprise, Education, or Pro that IS domain-joined or MDM-enrolled ("managed") | **OFF** | N/A until Cloud Remediation is turned on |

The rationale is straightforward: an organization managing a fleet is assumed to want explicit control over an automated, network-connecting, Windows-Update-fetching recovery behavior rather than having it silently active by default — the same philosophy behind most other opt-in-for-managed-devices Windows features. The complication is the **transition behavior**: if an admin has never explicitly touched the setting, the device's effective default automatically re-evaluates whenever its management state changes (e.g., an unmanaged demo unit gets Autopilot-enrolled into production). But the moment ANY admin explicitly sets `EnableQuickMachineRecovery` to a specific value via CSP/GPO-equivalent management, that explicit value becomes sticky and will NOT be overridden by a later management-state transition. This asymmetry — implicit values follow state, explicit values don't — is the most common source of "why does this device behave differently than its peers" tickets in this topic.

### CSP Node Structure

QMR's settings live under the `Recovery` CSP, specifically the `QuickMachineRecovery` node:

```
./Vendor/MSFT/Recovery
  ├── NetworkSettings
  │     └── Wifi
  │           └── {SSID}
  │                 └── WlanXML          (WinRE-specific Wi-Fi profile, WPA/WPA2-password only)
  ├── PointInTimeRestore                  (SEPARATE feature — user-driven restore points,
  │     ├── EnablePointInTimeRestore       NOT boot-failure remediation; do not confuse the two
  │     ├── SetMaxDiskUsage                despite living under the same parent CSP node)
  │     ├── SetRestorePointFrequency
  │     └── SetRestorePointRetention
  └── QuickMachineRecovery                (THIS topic)
        ├── EnableQuickMachineRecovery     (bool — master switch)
        └── AutoRemediationSettings
              ├── EnableAutoRemediation    (bool — DependsOn EnableQuickMachineRecovery=true)
              ├── SetRetryInterval         (int, 0-4320 min — DependsOn EnableAutoRemediation=true)
              └── SetTimeToReboot          (int, 1-4320 min — DependsOn EnableAutoRemediation=true)
```

All nodes are Device-scope only (no per-user configuration), and all require Pro/Enterprise/Education/IoT Enterprise editions.

### WinRE Network Connectivity — The Real-World Adoption Blocker

WinRE runs a minimal, pre-boot network stack that supports exactly two connectivity paths: wired Ethernet, and Wi-Fi using WPA or WPA2 with a **password** (pre-shared key). It does **not** support 802.1X/Enterprise Wi-Fi (RADIUS authentication, certificate-based EAP methods, etc.) — which is the connectivity model most mid-size-and-larger enterprises actually use for their production wireless networks. In practice, this means a laptop-heavy, Wi-Fi-only, 802.1X-secured estate gets essentially zero benefit from cloud remediation unless the organization is willing to provision and maintain a separate, purpose-built WPA2-PSK "recovery" SSID solely for WinRE's use, pushed via the `NetworkSettings/Wifi/{SSID}/WlanXML` node. This is a genuine architecture/security trade-off (a password-based fallback network is inherently weaker than 802.1X) that should be raised explicitly with a client rather than assumed away — many organizations will reasonably decide the trade-off isn't worth it and accept that QMR functionally only helps their wired desktops.

### Verification and Test Mode

`reagentc.exe /getrecoverysettings` is the sole documented on-device verification command and reads the effective, currently-applied configuration (regardless of whether it came from an explicit policy or a default) as XML, including cloud remediation state, auto remediation state and timers, and any configured WinRE Wi-Fi credential — **printed in plaintext**, which matters for anyone collecting this output for a ticket or screen-sharing.

A successfully applied remediation surfaces afterward in **Settings > Windows Update > Update history > Quality updates**, since remediation content is delivered and tracked the same way an ordinary quality update is.

Test mode — a simulated auto-remediation experience without a real boot failure — is documented as available only to devices enrolled in the **Windows Insider Program's Experimental channel**. There is no supported way to trigger a realistic end-to-end test on a standard production Windows 11 build, which constrains any pilot/validation plan to a genuinely disposable lab device rather than a representative pilot group of production hardware.

</details>

---

## Dependency Stack

```
Windows Recovery Environment (WinRE) — Enabled
   reagentc /info → "Windows RE status: Enabled"
   Hard prerequisite — Startup Repair AND QMR both depend on this
        │
        ▼
Windows 11, version 24H2 or 25H2, minimum build
   Support doc: 24H2 build 26100.4700+
   Recovery CSP reference: 24H2 build 26100.8737+ / 25H2 build 26200.8737+
   (documented discrepancy between Microsoft's own two pages — see Symptom
   → Cause Map; plan against the higher/more recent CSP figure)
        │
        ▼
Edition gate: Pro / Enterprise / Education / IoT Enterprise (+LTSC)
        │
        ▼
Management-state default fork (see How It Works table)
   Unmanaged → Cloud Remediation defaults ON (one-time scan)
   Managed   → Cloud Remediation defaults OFF
   Explicit admin configuration overrides and STICKS through any later
   management-state transition
        │
        ▼
EnableQuickMachineRecovery = true (via Recovery CSP / Intune Settings Catalog)
        │
   ┌────┴──────────────────────────────┐
   ▼                                    ▼
Auto Remediation (optional layer)   WinRE network path exists
EnableAutoRemediation = true        Wired Ethernet (always works), OR
   SetRetryInterval (0-4320m)       WPA/WPA2-password Wi-Fi (works), OR
   SetTimeToReboot (1-4320m)        802.1X Enterprise Wi-Fi (DOES NOT WORK —
   Retry interval MUST be <=          no workaround except a dedicated
   time to reboot                     WPA2-PSK fallback SSID via
   │                                  NetworkSettings/Wifi/{SSID}/WlanXML)
   └────────────────┬───────────────────┘
                     ▼
        Windows Update reachable from WinRE
        (remediation content delivery channel)
                     ▼
        Matching remediation found? (best-effort — not guaranteed)
           YES → downloaded, applied, device reboots
           NO  → falls through to ordinary recovery options
                     ▼
        Verify: Settings > Windows Update > Update history >
        Quality updates (post-recovery, in Windows)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| QMR/"Quick machine recovery" option doesn't appear in Settings > System > Recovery | WinRE disabled, OR OS build below minimum | `reagentc /info`, build number |
| Managed device shows Cloud Remediation Off and nobody configured it | **Expected default** for Enterprise/Education/domain-or-MDM-managed Pro — not a fault | Confirm intent with the org before "fixing" |
| Two seemingly-identical managed devices show different Cloud Remediation states | One almost certainly has an explicit legacy setting from before its current management state (sticky-explicit-value behavior) | `reagentc /getrecoverysettings` on both, compare against Intune assignment scope |
| Device stuck cycling through WinRE repeatedly | `SetRetryInterval` misconfigured greater than `SetTimeToReboot` | `reagentc /getrecoverysettings`, compare `waitinterval` vs. `totalwaittime` |
| Auto remediation enabled, device never seems to actually retry | `SetRetryInterval = 0` (explicitly means scan-once, not "use a short default") | Same command as above |
| Recovery attempted, device never got online in WinRE | Enterprise/802.1X Wi-Fi — WinRE cannot authenticate to it | Ask about the org's Wi-Fi security model; check for wired alternative |
| Wi-Fi SSID/password appears in plaintext during evidence collection | Expected — `reagentc /getrecoverysettings` prints the configured WinRE Wi-Fi credential in the clear | Redact before sharing/pasting into a ticket |
| Need to confirm a remediation fired during a past widespread outage | No tenant-wide report exists for this | Settings > Windows Update > Update history > Quality updates, per device |
| Want to test the auto-remediation UX before a rollout | Test mode requires Windows Insider Experimental channel | Use a disposable lab device, not production pilot hardware |
| `reagentc /enable` fails when trying to turn WinRE back on | Recovery partition/image missing or corrupted | Out of scope for this runbook — treat as a separate WinRE-repair task |

---

## Validation Steps

**1. Confirm WinRE is enabled:**
```powershell
reagentc.exe /info
```
Expected: `Windows RE status: Enabled`.

**2. Confirm OS build meets the (higher, CSP-referenced) minimum:**
```powershell
Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion, CurrentBuild, UBR
```
Expected: 24H2 with build/UBR at or above 26100.8737, or 25H2 at or above 26200.8737.

**3. Read the effective recovery configuration:**
```powershell
reagentc.exe /getrecoverysettings
```
Confirms `CloudRemediation`, `AutoRemediation` (with timer values), and any `WifiCredential` fallback profile.

**4. Confirm the retry/reboot timer relationship (if auto remediation is on):**
`waitinterval` (retry interval) must be ≤ `totalwaittime` (time to reboot). Anything else is a misconfiguration.

**5. Confirm management state to interpret whether the observed default is expected:**
```powershell
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined"
```

**6. Confirm WinRE network path availability for this specific device:**
Wired NIC present → will work automatically. Wi-Fi-only → confirm the production SSID's security type; 802.1X/Enterprise will not work without a dedicated fallback profile.

**7. Post-incident: confirm whether a remediation was actually applied:**
```
Settings > Windows Update > Update history > Quality updates
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Prerequisite Gate

1. Confirm WinRE is `Enabled` via `reagentc /info` — if not, this supersedes everything else.
2. Confirm OS build against the CSP reference's minimum (26100.8737 / 26200.8737), not just the lower Support-article figure.

### Phase 2: Policy and Default-State Confirmation

1. Determine management state (`dsregcmd /status`).
2. Read effective settings (`reagentc /getrecoverysettings`) and compare against the expected default for that management state.
3. If the observed state doesn't match the expected default, check for an explicit legacy configuration (sticky-value behavior) before assuming a policy delivery failure.
4. If a fleet policy should apply and doesn't, confirm Intune/MDM sync health for the device.

### Phase 3: Auto-Remediation Timer Health

1. If auto remediation is enabled, confirm `SetRetryInterval` ≤ `SetTimeToReboot`.
2. Correct via Intune/CSP if the relationship is violated; there is no on-device workaround.

### Phase 4: Network Path in WinRE

1. Identify whether the device has wired connectivity available during a boot failure.
2. If Wi-Fi-only, confirm the security type of the production SSID; 802.1X will not work.
3. If a fallback WPA2-PSK profile is required, provision and push it via `NetworkSettings/Wifi/{SSID}/WlanXML`, then re-test.

### Phase 5: Post-Incident Verification

1. Check Windows Update history for an applied quality update matching the incident window.
2. If nothing applied and cloud remediation was correctly enabled, this simply means no matching remediation existed in Windows Update at the time — expected best-effort behavior, not a fault.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide QMR enablement rollout</summary>

```
Devices > Configuration > Policies > Create > Windows 10 and later > Settings catalog
Category: Remote Remediation (community-documented Settings Catalog label —
verify the exact category name in your tenant, since Microsoft's own CSP
reference page does not itself name the Settings Catalog category)
  Enable Quick Machine Recovery: Enabled
  Enable Auto Remediation: Enabled
  Set Retry Interval: <e.g. 120 minutes>
  Set Time To Reboot: <e.g. 2400 minutes — must be >= Retry Interval>
Assign: pilot device group first, confirm via reagentc /getrecoverysettings
on a handful of devices post-sync, then expand to the full target population
```

**Rollback:** Remove the assignment or set `EnableQuickMachineRecovery` to `false` and re-sync. Confirm the change actually applied via `reagentc /getrecoverysettings` rather than assuming policy removal alone reverts the on-device state instantly.

</details>

<details><summary>Playbook 2 — WinRE network readiness for an 802.1X-only wireless estate</summary>

Use when an org's production Wi-Fi is entirely 802.1X/Enterprise and leadership wants QMR's benefit anyway.

1. Confirm which device population is wired vs. wireless-only — wired devices need no further action.
2. For wireless-only devices, evaluate whether a dedicated, isolated WPA2-PSK "recovery" SSID is an acceptable security trade-off (raise this explicitly — it is a real trade-off, not a free win).
3. If accepted, provision the fallback network and push it:
```
./Vendor/MSFT/Recovery/NetworkSettings/Wifi/{SSID}/WlanXML
```
4. Validate on a test device by confirming `reagentc /getrecoverysettings` shows the `WifiCredential` entry, then (lab device only, Insider Experimental channel) exercise test mode to confirm actual WinRE connectivity.

**Rollback:** Remove the `WlanXML` node/profile assignment if the fallback network is decommissioned; decommission the SSID itself on the wireless infrastructure side.

</details>

<details><summary>Playbook 3 — Recovering from a retry/reboot timer misconfiguration</summary>

Use when devices are reported looping in WinRE longer than expected, or auto-remediation behavior seems erratic.

1. Pull current settings: `reagentc.exe /getrecoverysettings` on an affected device.
2. Compare `waitinterval` (retry) against `totalwaittime` (time to reboot) in the `AutoRemediation` element.
3. If `waitinterval > totalwaittime`, correct the Intune/CSP policy values so the relationship holds, then re-sync.
4. Re-verify on the same device once the policy has applied.

**Rollback:** N/A — this is a corrective fix, not a feature toggle.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Quick Machine Recovery evidence for escalation or fleet-rollout review
.NOTES     Run elevated. Read-only — makes no configuration changes.
           WARNING: reagentc /getrecoverysettings prints any configured WinRE
           Wi-Fi SSID/password in PLAINTEXT — this script redacts it before export.
#>

$OutputDir = "C:\Temp\QMR-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. WinRE status (hard prerequisite)
reagentc.exe /info | Out-File "$OutputDir\WinRE-Info.txt"

# 2. Effective recovery settings (redact any Wi-Fi password before saving)
$raw = reagentc.exe /getrecoverysettings
$redacted = $raw -replace '(password=")[^"]*(")', '$1[REDACTED]$2'
$redacted | Out-File "$OutputDir\RecoverySettings-Redacted.txt"

# 3. Management state signal
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined" |
    Out-File "$OutputDir\ManagementState.txt"

# 4. OS build
Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion, CurrentBuild, UBR |
    Out-File "$OutputDir\OSBuild.txt"

# 5. Recent MDM/CSP policy delivery activity
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" -MaxEvents 30 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Out-File "$OutputDir\MDM-PolicyActivity.txt"

# 6. Network adapter summary (wired vs. wireless-only signal)
Get-NetAdapter | Select-Object Name, InterfaceDescription, MediaType, Status |
    Out-File "$OutputDir\NetworkAdapters.txt"

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# WinRE status (hard prerequisite)
reagentc.exe /info
reagentc.exe /enable
reagentc.exe /disable

# Effective recovery settings (CloudRemediation, AutoRemediation, WifiCredential)
reagentc.exe /getrecoverysettings

# Test mode (Windows Insider Experimental channel devices ONLY)
reagentc.exe /SetRecoveryTestmode
reagentc.exe /BootToRe

# Management state signal
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined"

# OS build check
Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion, CurrentBuild, UBR

# Force an Intune/MDM policy sync
Get-ScheduledTask -TaskName "PushLaunch" -ErrorAction SilentlyContinue | Start-ScheduledTask

# Relevant Recovery CSP OMA-URI paths (for direct/custom profile use)
# ./Vendor/MSFT/Recovery/QuickMachineRecovery/EnableQuickMachineRecovery
# ./Vendor/MSFT/Recovery/QuickMachineRecovery/AutoRemediationSettings/EnableAutoRemediation
# ./Vendor/MSFT/Recovery/QuickMachineRecovery/AutoRemediationSettings/SetRetryInterval
# ./Vendor/MSFT/Recovery/QuickMachineRecovery/AutoRemediationSettings/SetTimeToReboot
# ./Vendor/MSFT/Recovery/NetworkSettings/Wifi/{SSID}/WlanXML

# Post-recovery verification (GUI path — no CLI equivalent documented)
# Settings > Windows Update > Update history > Quality updates
```

---

## 🎓 Learning Pointers

- **QMR's default is a fork on management state, and the fork is easy to get backwards in your head.** Managed fleets default OFF; unmanaged/consumer devices default ON. Say it out loud before advising a client either way. [Quick machine recovery — Microsoft Learn](https://learn.microsoft.com/en-us/windows/configuration/quick-machine-recovery/)

- **"Sticky explicit configuration" is a pattern worth recognizing generally, not just here.** Several Windows management features (this one included) treat an admin-set value as permanent once set, decoupled from whatever the "current" default would otherwise be — always read the actual effective state rather than inferring it from join-type alone.

- **WinRE's network stack is more limited than most engineers assume.** No 802.1X support is a hard architectural constraint, not a missing feature waiting on a future update — factor this into any QMR value proposition conversation with a client whose Wi-Fi is Enterprise-secured.

- **Microsoft's own documentation has an unresolved build-number discrepancy between the consumer Support article and the CSP reference.** This repo flags rather than silently resolves such conflicts — plan against the higher, more recently-updated figure (the CSP reference) until Microsoft reconciles the two pages.

- **`reagentc.exe /getrecoverysettings` prints a configured WinRE Wi-Fi password in plaintext.** Build this redaction step into any evidence-collection habit for this topic — it's an easy accidental credential leak into a ticketing system or screen-share recording.

- **Test mode's Insider-Experimental-channel restriction means there is no safe way to pilot the real recovery experience on production hardware.** Plan validation around a dedicated lab device, and communicate this limitation clearly if a client wants a "test run" before a fleet rollout — the honest answer is that a full end-to-end test isn't available outside Insider builds as of this writing.
