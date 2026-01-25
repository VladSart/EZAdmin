<file name=Troubleshooting.md path=/Users/vladimirsartini/Documents/GitHub/EZAdmin/LLM/Prompt>
# MODE A — Reference / Verbose

## Required section order (must match exactly)

1) Skim Index (jump links)
2) Scope + Assumptions
3) How it works (in this environment)
4) Dependency stack (layered: hardware → OS → policy → network → external services)
5) Symptom → Likely cause map (fast triage)
6) Validation steps (top-to-bottom, commands + expected “good/bad”)
7) Troubleshooting steps (top-to-bottom, minimal risk first)
8) Remediation playbooks (by root cause; include rollback notes)
9) Evidence pack (what to collect for escalation)
10) Appendix: command cheat sheet

## Detail rules

- Always include a **Skim Index** at the top with jump links to every major section.
- Use clear section headings with numbering.
- Provide detailed commands and expected outputs.
- Include rollback notes in remediation playbooks.
- Use collapsible details for optional reading.
- Use code blocks for commands.
- Maintain consistent formatting and style.

</file>

<file name=Update to Latest.md path=/Users/vladimirsartini/Documents/GitHub/EZAdmin/Windows/Troubleshooting/Windows Update>
# Windows Update — Not Retrieving Latest Feature Update (25H2)

> **Audience:** L2/L3 IT Support  
> **Scope:** Windows 11 **24H2**, **Entra ID joined**, **Intune/MDM managed**, on **corp LAN**  
> **Constraint:** Admin OK, **no reboot** (note: some remediations normally expect a reboot)

---

## Skim Index

- [Scope + Assumptions](#1-scope--assumptions)
- [How it works](#2-how-it-works-in-this-environment)
- [Dependency stack](#3-dependency-stack)
- [Symptom → Likely cause map](#4-symptom--likely-cause-map)
- [Validation steps](#5-validation-steps-top-to-bottom)
- [Troubleshooting steps](#6-troubleshooting-steps-top-to-bottom)
- [Remediation playbooks](#7-remediation-playbooks-by-root-cause)
- [Evidence pack](#8-evidence-pack-what-to-collect-for-escalation)
- [Appendix: command cheat sheet](#9-appendix-command-cheat-sheet)

---

## 1) Scope + Assumptions

This runbook is for cases where:
- Windows Update reports **“You’re up to date”** on **24H2**
- But the **25H2 feature update** never appears (Settings / Windows Update)

Assumptions:
- The device is eligible for 25H2 (hardware + compatibility)
- The org intends devices to receive feature updates via **Windows Update for Business (WUfB)** using **Intune** (not WSUS-only)

Non-goals:
- Full Autopatch design or ring strategy (this is incident troubleshooting)

---

## 2) How it works (in this environment)

In an Intune-managed Windows 11 device, feature update availability depends on:
- **Policy** (Intune update rings / feature update policy / target version controls)
- **Safeguard holds** (Microsoft blocks the update for known issues on certain hardware/driver combos)
- **Update scan source** (WUfB vs WSUS, proxy/TLS inspection, or stale policy)
- **Health of update components** (WaaSMedic, WU services, update DB/cache)

Key reality:
- If policy says “stay on 24H2” or “defer feature updates X days”, **Windows will not show 25H2**.
- If a safeguard hold exists, **it may never show**, even with correct policy.

---

## 3) Dependency stack

Work top → down. A break at any layer blocks 25H2.

<details>
<summary><strong>Layer 0 — Eligibility</strong> (hardware + compatibility)</summary>

- Supported CPU / TPM / Secure Boot
- Storage headroom (feature update requires free space)
- Compatibility / safeguard hold

</details>

<details>
<summary><strong>Layer 1 — Policy intent</strong> (Intune controls what versions are offered)</summary>

- Update ring deferrals
- Feature Update policy (target version)
- Any legacy “TargetReleaseVersion” controls

</details>

<details>
<summary><strong>Layer 2 — Update scan source</strong> (WUfB vs WSUS/proxy)</summary>

- WUfB must be allowed to talk to Microsoft endpoints
- WSUS policies can block feature updates
- TLS inspection / proxy can break metadata downloads

</details>

<details>
<summary><strong>Layer 3 — Windows Update health</strong> (services, cache, component health)</summary>

- Windows Update services running
- Update stack not corrupted
- WaaSMedic can repair components

</details>

---

## 4) Symptom → Likely cause map

<details>
<summary><strong>Symptom: “You’re up to date” on 24H2, no 25H2 offered</strong></summary>

**Likely causes**
- Feature update is **deferred** by update ring policy
- Feature Update policy **targets 24H2** (or older) / target version is pinned
- Device is under a **safeguard hold**
- Device is scanning against **WSUS** (or dual-scan misconfig)
- Proxy/TLS inspection blocks WU metadata endpoints

</details>

<details>
<summary><strong>Symptom: Feature update offered on some devices, not this model</strong></summary>

**Likely causes**
- Safeguard hold for this hardware/driver
- Driver/BIOS versions differ
- Different ring/group assignments (overlap)

</details>

<details>
<summary><strong>Symptom: Quality updates install fine, feature updates never appear</strong></summary>

**Likely causes**
- Feature deferral/target policy
- WSUS policy blocks feature upgrades
- Insufficient storage / compatibility hold

</details>

<details>
<summary><strong>Symptom: Update scan errors in UI / logs</strong></summary>

**Likely causes**
- WU components/caches broken
- Proxy/DNS issues
- Service disabled by policy

</details>

---

## 5) Validation steps (top-to-bottom)

> Goal: produce evidence for **(a) policy**, **(b) source**, **(c) holds**, **(d) health**.

### 5.1 Confirm join/MDM state

[powershell]
```
dsregcmd /status
```

Expected “good”:
- AzureAdJoined = YES
- MDM URLs present (Intune-managed)

If not:
- The device may not be receiving Intune update policy → troubleshoot enrollment first.

---

### 5.2 Confirm policy isn’t pinning the version

Check Windows Update policy registry keys.

[powershell]
```
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ProductVersion
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /s
```

Interpretation:
- If `TargetReleaseVersion=1` and `TargetReleaseVersionInfo=24H2` → **device is pinned** to 24H2.
- If `ProductVersion=Windows 11` + `TargetReleaseVersionInfo` set → Target Version policy is active.

Also check Windows Update for Business deferrals:

[powershell]
```
reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update" /s
reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update\DeferFeatureUpdatesPeriodInDays" /v value
```

Expected “good”:
- No target version pin to 24H2
- Deferral values align with your ring intent

---

### 5.3 Confirm scan source (WUfB vs WSUS)

Look for WSUS keys:

[powershell]
```
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer
```

Interpretation:
- If `UseWUServer=1` and WUServer is set → the device is pointed at **WSUS**.
- Some orgs allow quality updates via WSUS but block feature updates (common).

Also check effective Windows Update policy state:

[powershell]
```
Get-WindowsUpdateLog
```

Expected “good”:
- Device not forced to WSUS unless intended

---

### 5.4 Check if the device is under a safeguard hold

This is the most common “why doesn’t it show?” in real life.

Quick indicator (UI):
- Settings → Windows Update may show a message like “This update is on its way…” (not always)

Evidence approach:
- Check Windows Update related event logs for compatibility/hold hints.

[powershell]
```
wevtutil qe Microsoft-Windows-WindowsUpdateClient/Operational /c:80 /f:text
```

Interpretation:
- If you see compatibility blocks or repeated “not applicable” patterns, suspect a hold.

---

### 5.5 Check storage + basic health

[powershell]
```
wmic logicaldisk get size,freespace,caption
DISM /Online /Cleanup-Image /CheckHealth
sfc /scannow
```

Expected “good”:
- Reasonable free space (feature updates want breathing room)
- DISM reports healthy

Constraint note:
- `sfc /scannow` can take time but does not require immediate reboot.

---

### 5.6 Force a scan (non-destructive)

[powershell]
```
usoclient StartScan
usoclient StartDownload
usoclient StartInstall
```

Re-check:
- Settings → Windows Update

If nothing changes:
- Move to troubleshooting steps (policy/source/holds).

---

## 6) Troubleshooting steps (top-to-bottom)

### 6.1 Verify Intune assignment overlaps / wrong ring

Common failure:
- Device is in multiple groups and gets conflicting policies (ring overlap).

What to check:
- Intune: device is in the correct update ring
- Intune: Feature update policy is not targeting a different release

Local proof (what the device actually received):

[powershell]
```
mdmdiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning;Policy -cab C:\MDMDiag.cab
```

Review the CAB for applied Update policies.

---

### 6.2 If Target Version is pinning to 24H2

Reality:
- Local changes won’t stick if Intune keeps reapplying.

Actions:
- In Intune, locate policies that set “TargetReleaseVersion” / Feature Update target.
- Either:
  - Update target to **25H2**, or
  - Remove the target version policy for that ring.

Local-only test (only for validation, not final fix):

[powershell]
```
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo
```

If values come back after you remove them, policy is reapplying.

---

### 6.3 If WSUS settings are present but you expect WUfB

Actions:
- Identify the source of WSUS policy (GPO vs MDM).
- Remove/disable WSUS policy for this device/ring, or ensure feature updates are permitted via your update strategy.

Local proof:

[powershell]
```
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer
```

---

### 6.4 If proxy/TLS inspection blocks metadata

Even on corp LAN, proxies can block feature update metadata/download while letting small quality updates through.

Checks:
- Confirm the device can reach Microsoft update endpoints (org-specific allow list).
- Check for SSL inspection on Windows Update traffic.

Local evidence (high level):
- WindowsUpdateClient Operational log shows repeated download failures or connection errors.

[powershell]
```
wevtutil qe Microsoft-Windows-WindowsUpdateClient/Operational /c:200 /f:text
```

---

### 6.5 Repair Windows Update components (no reboot-first approach)

Start with service restarts + cache cleanup (may disrupt active update downloads).

[powershell]
```
net stop wuauserv
net stop bits
net stop cryptsvc
net stop msiserver

ren C:\Windows\SoftwareDistribution SoftwareDistribution.old
ren C:\Windows\System32\catroot2 catroot2.old

net start cryptsvc
net start bits
net start msiserver
net start wuauserv

usoclient StartScan
```

Notes:
- This is a common reset pattern.
- A reboot is often recommended after this, but you can still re-scan without reboot.

---

### 6.6 Last-mile: ensure update health services aren’t disabled

[powershell]
```
sc query wuauserv
sc query usosvc
sc query WaaSMedicSvc
Get-Service wuauserv, usosvc, WaaSMedicSvc
```

If any are disabled by policy:
- Fix the policy source. Local enabling will revert.

---

## 7) Remediation playbooks (by root cause)

<details>
<summary><strong>Playbook A — Feature update is deferred / ring policy delaying 25H2</strong></summary>

**When**
- Deferral days are set high
- Device is “up to date” but feature update is not offered

**Fix**
- Reduce feature deferral (for test device first)
- Verify device membership in correct ring/group

**Rollback**
- Return deferrals to standard after validation

</details>

<details>
<summary><strong>Playbook B — Target version policy pins device to 24H2</strong></summary>

**When**
- `TargetReleaseVersion=1` and `TargetReleaseVersionInfo=24H2`

**Fix**
- Update Intune Feature Update target to 25H2 (or remove target version policy)

**Rollback**
- Re-apply target pin if required for staged rollout

</details>

<details>
<summary><strong>Playbook C — Device is scanning WSUS (feature updates blocked)</strong></summary>

**When**
- `UseWUServer=1` and WUServer set

**Fix**
- Remove WSUS policy for this population or ensure your WSUS strategy supports feature upgrades

**Rollback**
- Restore WSUS policy if the device must remain WSUS-managed

</details>

<details>
<summary><strong>Playbook D — Safeguard hold (compatibility block)</strong></summary>

**When**
- Some models get 25H2, this model doesn’t
- Logs show “not applicable” / compatibility patterns

**Fix**
- Update BIOS/firmware/drivers to latest (vendor guidance)
- Remove problematic drivers/apps (if known)
- Wait for Microsoft hold to lift (sometimes the only correct answer)

**Rollback**
- N/A (holds are server-side)

</details>

<details>
<summary><strong>Playbook E — Windows Update components/caches are broken</strong></summary>

**When**
- WU logs show repeated failures
- Scan/download loops

**Fix**
- Reset SoftwareDistribution + catroot2
- DISM restore health if needed

[powershell]
```
DISM /Online /Cleanup-Image /RestoreHealth
```

**Rollback**
- None (cache folders were renamed)

</details>

---

## 8) Evidence pack (what to collect for escalation)

> Copy/paste this whole section into your ticket.

[powershell]
```
# Version + join
winver
systeminfo | findstr /B /C:"OS Name" /C:"OS Version"
dsregcmd /status

# WU policy (target version + WSUS)
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /s
reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update" /s

# Service health
sc query wuauserv
sc query usosvc
sc query WaaSMedicSvc

# Storage + image health
wmic logicaldisk get size,freespace,caption
DISM /Online /Cleanup-Image /CheckHealth

# Logs (last ~200)
wevtutil qe Microsoft-Windows-WindowsUpdateClient/Operational /c:200 /f:text

# MDM policy capture
mdmdiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning;Policy -cab C:\MDMDiag.cab
```

---

## 9) Appendix: command cheat sheet

[powershell]
```
# Quick state
w32tm /query /status
usoclient StartScan

# Target version / WUfB
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo

# WSUS
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer

# Reset WU (cache)
net stop wuauserv & net stop bits & net stop cryptsvc & net stop msiserver
ren C:\Windows\SoftwareDistribution SoftwareDistribution.old
ren C:\Windows\System32\catroot2 catroot2.old
net start cryptsvc & net start bits & net start msiserver & net start wuauserv

# Logs
wevtutil qe Microsoft-Windows-WindowsUpdateClient/Operational /c:80 /f:text
```
</file>
