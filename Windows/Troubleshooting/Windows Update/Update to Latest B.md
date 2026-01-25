# Windows Update — Not Retrieving Latest Feature Update (25H2)

> **Output:** Mode B (Ops/Triage)
> **Audience:** L2/L3 IT Support
> **Environment:** Windows 11 24H2 • Entra ID joined • Intune/MDM • Corp LAN
> **Constraints:** Admin OK • No reboot

---

## Skim Index

- [Triage (30–60 seconds)](#1-triage-3060-seconds)
- [Dependency Cascade](#2-dependency-cascade)
- [Diagnosis & Validation Flow](#3-diagnosis--validation-flow)
- [Common Fix Paths](#4-common-fix-paths)
- [Escalation Evidence](#5-escalation-evidence)

---

## 1) Triage (30–60 seconds)

[powershell]
```
# 1) Policy pinning (most common)
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo

# 2) Scan source (WSUS vs WUfB)
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v UseWUServer
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer

# 3) Pause status
reg query "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v PauseUpdatesExpiryTime

# 4) Update health
Get-Service wuauserv,usosvc,bits,cryptsvc
```

Interpretation:
- If **TargetReleaseVersion=1** and **TargetReleaseVersionInfo=24H2**, policy is pinning → 25H2 will not show.
- If **UseWUServer=1**, device scans WSUS → feature update may be blocked.
- If **PauseUpdatesExpiryTime** is in the future → updates are paused.
- If any service is **Disabled**, WU health is broken.

---

## 2) Dependency Cascade

<details>
<summary><strong>What must be true for 25H2 to appear</strong></summary>

1) Device eligible (hardware + storage + no safeguard hold)
2) Intune policy allows 25H2 (no pinning/deferral)
3) Scan source is WUfB (not WSUS-only)
4) WU services + cache healthy
5) Microsoft offer not blocked by safeguard hold

</details>

---

## 3) Diagnosis & Validation Flow

Follow top-to-bottom. Stop when break is found.

1) **Policy pinning**  
   - If `TargetReleaseVersionInfo` ≠ `25H2` and `TargetReleaseVersion=1` → fix policy in Intune.

2) **Update ring deferral/pause**  
   - If PauseExpiry exists and is in the future → clear pause in Intune ring.

3) **Scan source**  
   - If `UseWUServer=1` → remove WSUS policy or exclude device so it can scan WUfB.

4) **Safeguard hold**  
   - Generate log and search for hold.
   [powershell]
```
Get-WindowsUpdateLog
```
   - If log shows hold → update driver/BIOS or wait for hold removal.

5) **WU health**  
   - If services are disabled or failing → repair WU services/cache.

6) **Force scan after fixes**  
   [powershell]
```
usoClient StartScan
usoClient StartDownload
```

---

## 4) Common Fix Paths

<details>
<summary><strong>Fix: Policy pinning to 24H2</strong></summary>

- Update Intune Feature Update policy to target **25H2** or remove pinning.
- Sync device from **Access work or school → Sync**.

</details>

<details>
<summary><strong>Fix: WSUS / dual-scan blocking feature updates</strong></summary>

[powershell]
```
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /t REG_DWORD /d 0 /f
```
- Ensure WUfB endpoints are reachable from corp LAN.

</details>

<details>
<summary><strong>Fix: Update pause/deferral</strong></summary>

- Clear pause in Update Ring policy.
- Reduce feature deferral days if set high.

</details>

<details>
<summary><strong>Fix: WU cache corruption (no reboot)</strong></summary>

[powershell]
```
Stop-Service wuauserv,bits,cryptsvc
Remove-Item -Recurse -Force C:\Windows\SoftwareDistribution\Download\*
Start-Service cryptsvc,bits,wuauserv
```

</details>

---

## 5) Escalation Evidence

Copy/paste into ticket:

```text
Device: <name>
OS: Windows 11 24H2
Join: Entra ID joined
Mgmt: Intune/MDM
Constraint: No reboot

Policy pinning:
- TargetReleaseVersion = <value>
- TargetReleaseVersionInfo = <value>

Scan source:
- UseWUServer = <value>
- WUServer = <value>

Pause:
- PauseUpdatesExpiryTime = <value>

Services:
- wuauserv/usosvc/bits/cryptsvc status = <values>

WU log:
- Safeguard hold present? <yes/no>
- Evidence snippet: <paste>

Intune assignments:
- Update Ring: <name>
- Feature Update policy: <name>
```
