

# Windows Update — Detect and Change WSUS to WUfB

> **Output:** Mode B (Ops/Triage)
> **Audience:** L2/L3 IT Support
> **Environment:** Windows 11 24H2 • Entra ID joined • Intune/MDM • Corp LAN
> **Constraints:** Admin OK • No reboot

---

## Skim Index

- [Triage](#1-triage-3060-seconds)
- [Dependency Cascade](#2-dependency-cascade)
- [Diagnosis & Validation Flow](#3-diagnosis--validation-flow)
- [Common Fix Paths](#4-common-fix-paths)
- [Escalation Evidence](#5-escalation-evidence)

---

## 1) Triage (30–60 seconds)

Goal: Prove whether the box is pinned to **WSUS** and whether policy is blocking **Windows Update for Business (WUfB)**.

[powershell]
```
# A) WSUS vs WUfB policy
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v UseWUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer

# B) Feature update pins (can block upgrade paths)
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo

# C) Quick health
Get-Service wuauserv,usosvc,bits,cryptsvc | Select Name,Status,StartType
```

Interpretation:
- **WSUS is “active”** if `UseWUServer=0x1` (either key) and `WUServer` has a URL.
- **Pinned feature update** if `TargetReleaseVersion=1` and `TargetReleaseVersionInfo` is set.
- If services are stopped/disabled → fix services first.

---

## 2) Dependency Cascade

<details>
<summary><strong>Layer 1 — Policy source of truth (Intune/GPO)</strong></summary>

- If the device is Intune managed, local registry edits may be reverted.
- You must confirm whether the setting is coming from:
  - Intune update rings / feature update policy / update settings catalog
  - Domain GPO (even if Entra joined, hybrid scenarios exist)

Fast proofs:

[powershell]
```
# Group Policy summary (if device processes GPO)
gpresult /r

# MDM enrollment status hint
dsregcmd /status | findstr /i "MDMUrl MDM"
```
</details>

<details>
<summary><strong>Layer 2 — Update scan source</strong></summary>

- WSUS (internal) vs Microsoft Update/WUfB (internet)
- “Dual scan” edge cases can occur if WSUS is set but the device also tries MU for some categories.

</details>

<details>
<summary><strong>Layer 3 — Services + crypto + BITS</strong></summary>

- `wuauserv`, `usosvc`, `bits`, `cryptsvc` must be running.
- If these are broken you’ll chase ghosts.

</details>

<details>
<summary><strong>Layer 4 — Network</strong></summary>

- Corp proxy/firewall must allow Windows Update endpoints for WUfB.
- WSUS must be reachable if still configured.

</details>

---

## 3) Diagnosis & Validation Flow

Follow in order. Stop when you find the first proven break.

### Step 1 — Confirm whether WSUS is enforced

[powershell]
```
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v UseWUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer
```

- If `UseWUServer=1` + `WUServer` exists → you’re WSUS.
- If values keep reappearing after you change them → policy is enforcing (Intune/GPO).

### Step 2 — Prove policy origin (so you don’t fight the wrong layer)

[powershell]
```
# If domain GPO is in play this will show it
gpresult /h "$env:TEMP\gp.html" & start "$env:TEMP\gp.html"
```

- If GPO shows Windows Update/WSUS settings → fix in GPO (local is temporary).
- If no GPO but still reverting → likely Intune policy.

### Step 3 — If still WSUS, validate WSUS reachability (don’t switch blindly)

If `WUServer` is set, test it:

[powershell]
```
$wu = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue)
$wsus = $wu.WUServer
"WSUS=$wsus"
if ($wsus) {
  try { iwr -Uri $wsus -UseBasicParsing -TimeoutSec 10 | Out-Null; "OK: reachable" }
  catch { "FAIL: not reachable" }
}
```

- If WSUS is unreachable and policy is forcing it → that’s your root cause (escalate to policy owner).

### Step 4 — Check for feature pins that would block WUfB upgrade behaviour

[powershell]
```
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo
```

- If pinned → switching to WUfB may still not move feature version until policy is corrected.

### Step 5 — After changing policy, force a clean scan

[powershell]
```
Get-Service wuauserv,usosvc,bits,cryptsvc | Select Name,Status
usoclient StartScan
```

If `usoclient` doesn’t do anything obvious, use Settings UI:
- Settings → Windows Update → “Check for updates”

---

## 4) Common Fix Paths

### A) Correct fix (preferred): change the policy at source (Intune/GPO)

<details>
<summary><strong>Fix: Intune — remove WSUS/Update source policies and use WUfB</strong></summary>

Do this in Intune (conceptually):
- Remove or disable any setting that configures:
  - **Specify intranet Microsoft update service location** (WSUS URL)
  - `UseWUServer`
- Ensure WUfB settings exist (Update rings / Feature updates / Quality updates) and aren’t pinned incorrectly.

Validation on device (after policy sync):

[powershell]
```
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer
```

Expected:
- `WUServer` missing or empty
- `UseWUServer` = 0 (or not present)

</details>

<details>
<summary><strong>Fix: GPO — switch from WSUS to WUfB</strong></summary>

In GPO:
- Disable/Not Configured:
  - “Specify intranet Microsoft update service location”
- Review:
  - “Do not connect to any Windows Update Internet locations” (must not block WUfB)
  - Feature update target version policies

Then on device:

[powershell]
```
gpupdate /force
```

</details>

### B) Temporary local workaround (only if you’re allowed to override locally)

This is a stop-gap. Intune/GPO may revert it.

<details>
<summary><strong>Fix: locally disable WSUS (no reboot)</strong></summary>

[powershell]
```
# Disable WSUS usage
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /t REG_DWORD /d 0 /f

# Optionally remove WSUS server URLs (only if you are allowed)
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /f
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /f

# Restart update stack (no reboot)
Stop-Service wuauserv,bits -Force
Start-Service bits,wuauserv

# Trigger scan
usoclient StartScan
```

Rollback:

[powershell]
```
# If you need to re-enable WSUS quickly (set correct URL from your environment)
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /t REG_SZ /d "http://YOUR-WSUS:8530" /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /t REG_SZ /d "http://YOUR-WSUS:8530" /f
Stop-Service wuauserv,bits -Force
Start-Service bits,wuauserv
```

</details>

### C) If the goal is “get to 25H2” specifically

Reality: switching to WUfB doesn’t guarantee 25H2 shows up immediately.
- If there’s a safeguard hold or staged rollout, you can’t brute-force it with a local toggle.
- If there’s a feature pin (`TargetReleaseVersionInfo`), you must fix that at policy source.

---

## 5) Escalation Evidence

Copy/paste this into the ticket (fill in the blanks where needed):

[powershell]
```
# Identity + management hints
hostname
whoami
dsregcmd /status | findstr /i "AzureAdJoined DomainJoined MDMUrl"

# WSUS / WUfB policy
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v UseWUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer

# Feature pins
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo

# Update services
Get-Service wuauserv,usosvc,bits,cryptsvc | Select Name,Status,StartType

# GPO proof (if applicable)
gpresult /r

# Quick OS version
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
```