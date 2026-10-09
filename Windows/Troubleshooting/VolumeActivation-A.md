# Windows Volume Activation (KMS / ADBA / Subscription Activation) — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** Windows client (10/11) and Windows Server (2016–2025) OS activation through the three organisational mechanisms MSPs actually meet: **Key Management Service (KMS)**, **Active Directory-Based Activation (ADBA)**, and **Windows Enterprise Subscription Activation** (Pro → Enterprise step-up via E3/E5). MAK is covered where it intersects (conversion, fallback).
- **Out of scope:** Office/M365 Apps activation (`ospp.vbs`, shared computer activation, Office KMS host packs), Windows 10 ESU MAK add-on activation (`ESU-A.md`), RDS CAL activation (`RDSLicensing-A.md`), Azure VM activation against Azure's KMS (`azkms.core.windows.net`) beyond a pointer.
- Commands assume elevated PowerShell. `slmgr.vbs` is still the authoritative tool; there is no first-party PowerShell module for client licensing — the WMI classes `SoftwareLicensingProduct` and `SoftwareLicensingService` back it and are used in the script.
- **VBScript note:** `slmgr.vbs` is a VBScript. On builds where the VBScript Feature-on-Demand has been removed (see `VBScriptDeprecation-A.md`), `slmgr.vbs` won't run — query the CIM classes directly instead (cheat sheet shows equivalents).

---
## How It Works
<details><summary>Full architecture</summary>

### The licensing stack on every Windows box
```
slmgr.vbs / Settings > Activation / CIM (SoftwareLicensingProduct)
            │
   Software Protection Platform service (sppsvc, trigger-start)
            │
   Licensing store: %windir%\System32\spp\store\2.0\tokens.dat  (+ data.dat, cache)
            │
   Product key installed  ──► determines CHANNEL
        RETAIL / OEM_DM / OEM_COA_* / VOLUME_MAK / VOLUME_KMSCLIENT / VOLUME_KMS_<ver> (host)
```
The **channel** is fixed by the key you install, not by what infrastructure exists. A device shipped with a retail or OEM key will ignore your KMS host forever. The single most common MSP misdiagnosis is "KMS is broken" for a machine that was never a KMS client.

### KMS
- A **KMS host** is any Windows Server (or client, for client-only activation) with a **Customer Specific Volume License Key (CSVLK)** installed and activated once against Microsoft. After that it never talks to Microsoft again for client activations.
- Clients use a **Generic Volume License Key (GVLK)** — public, edition-specific. Volume-licensed media installs it by default.
- **Discovery:** client queries DNS for `_vlmcs._tcp.<primary DNS suffix>` SRV (plus suffix search list). Hosts publish this record via dynamic DNS unless publishing is disabled (`slmgr /cdns` re-enables, `/cdns` vs `/ddns` toggles). Manual override per client: `slmgr /skms host[:port]` (registry `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\KeyManagementServiceName`).
- **Protocol:** RPC over TCP **1688** (default). Client sends an activation request containing its **Client Machine ID (CMID)**; host responds with its current count.
- **Thresholds:** host activates client OS only when its count of distinct CMIDs is **≥ 25**, and server OS when **≥ 5**. Servers count towards both. The host remembers CMIDs for **30 days**; machines that stop renewing fall out of the count.
- **Lifetimes:** successful activation is valid **180 days**. Clients attempt renewal every **7 days**; on failure they retry every **2 hours**. A KMS client that can't reach a host for 180 days drops to notification state.
- **CSVLK generations:** a host key activates its own generation and all earlier ones. A newer client OS needs a host with an equal-or-newer CSVLK — otherwise `0xC004F042`. The Server 2025 CSVLK covers Windows 10/11 and Server 2025 and earlier.
- **Duplicate CMIDs:** images captured without `sysprep /generalize` share a CMID — the host counts them once, so a fleet of 40 cloned VMs can still sit at count 1 → `0xC004F038`.

### ADBA
- Introduced with Windows 8 / Server 2012. Requires the forest schema at **Server 2012 or later**.
- An **activation object** (`msSPP-ActivationObject`) holding the CSVLK-derived data is written under `CN=Activation Objects,CN=Microsoft SPP,CN=Services,CN=Configuration,<forest root>`. Creation needs **Enterprise Admins** (Configuration partition) and is done via Volume Activation Tools (`VolumeActivation` role tools) or `slmgr /ad-activation-online <CSVLK>`.
- Domain-joined GVLK clients read the object over **LDAP** from a DC during activation. **No count threshold, no port 1688, no KMS server to run.** Revalidation every 180 days — a machine off-domain for longer reverts to unactivated.
- Lookup order: ADBA first; if no matching object, fall back to KMS DNS discovery. Running both side-by-side during migration is supported.
- Forest-scoped: one object serves every domain in the forest. It does nothing for workgroup or Entra-only devices.

### Subscription Activation (Windows Enterprise E3/E5)
- Not a key exchange at all — a **licensing token** flow. Device runs **Windows Pro** (genuinely activated, typically via firmware-embedded OEM key). An Entra user with a **Windows Enterprise E3/E5** entitlement (standalone or via M365 E3/E5/A3/A5) signs in; the device obtains a licence from Microsoft's Store licensing service and the edition flips from Pro to Enterprise **in place, without reboot**.
- Requirements: device **Entra joined or hybrid joined** (not registered, not workgroup); a valid **PRT**; **per-user** licensing (per-device licensing doesn't drive this); the licensing cloud app not blocked by Conditional Access.
- Licence lapse (user unassigned, 90-day grace aside) → device steps back down to Pro. No data loss, but Enterprise-only features (Credential Guard on some SKUs historically, AppLocker enforcement on older builds, DirectAccess) stop.
- Step-up sits *on top of* Pro activation. If Pro isn't activated, step-up won't happen.

### How the three interact
```
           Key installed?
   ┌───────────┼──────────────┐
 RETAIL/OEM   MAK           GVLK (KMSCLIENT)
   │           │               │
   │      activates once       ├─ domain-joined & ADBA object match? → ADBA
   │      with Microsoft       └─ else DNS SRV/pinned host → KMS
   │
   └─ Pro + Entra-joined + E3/E5 user → Subscription Activation step-up to Enterprise
```
Autopilot/Intune fleets: normally Pro OEM + Subscription Activation. On-prem domain fleets: GVLK + ADBA (or KMS). Mixed MSP estates frequently end up with a GVLK installed on a Pro OEM device by an old imaging task — the device then tries KMS, never finds it, and the firmware key is ignored.
</details>

---
## Dependency Stack
```
L0  Microsoft licensing backend (one-time CSVLK activation; Store licensing service for E3/E5)
L1  Time sync (Kerberos-grade within ~4 h for KMS; PRT for Subscription Activation)
L2  Name resolution — DNS SRV _vlmcs._tcp (KMS) / DC locator (ADBA)
L3  Network — TCP 1688 (KMS) / LDAP 389 to DCs (ADBA) / HTTPS to licensing endpoints (Subscription)
L4  Activation authority — KMS host (CSVLK, count) / AD activation object / Entra licence + CA allow
L5  Client licensing stack — sppsvc, tokens.dat, correct key/channel, unique CMID
L6  Edition/state visible to user (watermark, Settings > Activation, Enterprise features)
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Whole site shows `0xC004F074` after server refresh | Pinned `/skms` or stale SRV pointing at old host | `slmgr /dlv` registered KMS name; SRV query |
| `0x8007232B` | No SRV record; host not publishing (secure DNS zone, different domain) | `Resolve-DnsName -Type SRV _vlmcs._tcp.<domain>` |
| `0xC004F038` on new small client | Below 25 count; or cloned images with duplicate CMID | Host `Current count`; compare CMIDs |
| `0xC004F042` on Win 11 / Server 2025 only | Host CSVLK generation older than client | Host `/dlv` Name line |
| `0xC004F06C` | Clock skew between client and host | `w32tm /stripchart` |
| `0xC004C003` | Blocked/invalid key at Microsoft | Verify key from admin centre; escalate to licensing |
| `0xC004F050` on `/ipk` | Key doesn't match edition (e.g. Enterprise GVLK on Pro) | Caption vs key edition |
| Watermark returns after ~6 months on remote laptops | KMS/ADBA clients never reach corporate network (no VPN before 180 days) | `/dlv` remaining interval; VPN/AOVPN status |
| Pro stays Pro with E3 assigned | Device only Entra *registered*; no PRT; CA blocks licensing app; Pro not activated | `dsregcmd /status`; CA sign-in logs |
| Enterprise drops to Pro | User licence removed / changed to a SKU without Windows Enterprise | M365 licence assignment |
| `slmgr.vbs` "Windows Script Host access disabled" or not found | VBScript FoD removed or WSH disabled by policy | Use CIM equivalents |
| Server Eval refuses GVLK | Evaluation edition | `DISM /Online /Get-CurrentEdition`, convert first |

---
## Validation Steps
1. **Channel and state (client).**
   ```powershell
   Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" |
     Select-Object Name, Description, LicenseStatus, GracePeriodRemaining, KeyManagementServiceMachine, DiscoveredKeyManagementServiceMachineName
   ```
   Good: `LicenseStatus = 1` (Licensed), Description contains the expected channel. Bad: `0` Unlicensed, `2` OOB grace, `3` OOT grace, `4` non-genuine grace, `5` Notification, `6` extended grace.
2. **KMS discovery.** `Resolve-DnsName -Type SRV _vlmcs._tcp.<domain>` → each target port 1688, all targets live hosts.
3. **Port.** `Test-NetConnection <host> -Port 1688` → True.
4. **Host health.**
   ```powershell
   Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Description LIKE '%VOLUME_KMS_%'" |
     Select-Object Name, Description, LicenseStatus, KeyManagementServiceCurrentCount, KeyManagementServiceTotalRequests, KeyManagementServiceFailedRequests
   Get-CimInstance SoftwareLicensingService | Select-Object KeyManagementServiceListeningPort, KeyManagementServiceDnsPublishing
   ```
   Good: Licensed, count ≥ 25 (or ≥ 5 for server-only), DnsPublishing True. Rising `FailedRequests` with low `TotalRequests` → clients reaching it but being refused (count/key generation).
5. **ADBA objects.** LDAP query of `CN=Activation Objects,...` — at least one object whose name corresponds to the current CSVLK generation.
6. **Subscription Activation.** `dsregcmd /status` → `AzureAdJoined : YES`, `AzureAdPrt : YES`; Caption shows Enterprise; Entra sign-in logs for the user show successful sign-ins to *Universal Store Service APIs and Web Application*.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Classify.** Read the channel. RETAIL/OEM → not a volume problem (or Subscription Activation if the goal is Enterprise). MAK → MAK problem (count of remaining MAK activations, proxy). KMSCLIENT → continue.

**Phase 2 — Locate the authority.** Domain-joined Win 8+ and ADBA object present? ADBA should be winning — if `/dlv` shows a KMS machine instead, the object generation doesn't match this OS. Otherwise find the KMS host via pinned name or SRV.

**Phase 3 — Reach the authority.** DNS, 1688, time. Use event 12288 (client request) / 12289 (client result with HRESULT) and host event 12290 (request received, includes client CMID and returned code). No 12290 on host for a client's attempt = never arrived (network/DNS). 12290 with error = host refused (count/key).

**Phase 4 — Authority can't help.** Count too low → ADBA or MAK. Key generation too old → upgrade CSVLK. Key blocked → licensing escalation.

**Phase 5 — Persistence.** Remote/hybrid workers on KMS/ADBA must reach the network within 180 days. For Intune-managed remote fleets, prefer Pro OEM + Subscription Activation over GVLK-based activation.

**Phase 6 — Subscription Activation path.** Pro activated? Joined (not registered)? PRT? User licence per-user? CA exclusion? Then wait for token refresh (sign-out/in).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate KMS host to a new server (no outage)</summary>

1. Build the new host (Server 2022/2025). Install the newest CSVLK: `slmgr /ipk <CSVLK>`, `slmgr /ato`. Confirm `Licensed`.
2. Enable firewall group *Key Management Service*. Confirm SRV publishing (`slmgr /cdns`).
3. Both hosts now advertise via SRV — clients pick either. Count on the new host builds as clients renew (up to 7 days).
4. Once new host count ≥ threshold, on the old host: `slmgr /upk` (uninstall CSVLK) and `slmgr /cpky`, then install the Server GVLK so it becomes a normal client. Remove its SRV record (Fix 1 in B runbook).
5. Search for pinned clients: run `Get-VolumeActivationHealth.ps1` across the fleet, filter `KmsPinnedHost` = old host, run `slmgr /ckms` on them (Intune remediation or GPO startup script).
Rollback: old host's CSVLK can be re-installed — record it before `/upk`.
</details>

<details><summary>Playbook 2 — Replace KMS with ADBA (small/medium forests)</summary>

1. Confirm schema ≥ Server 2012: `(Get-ADObject (Get-ADRootDSE).schemaNamingContext -Properties objectVersion).objectVersion` ≥ 56.
2. As Enterprise Admin on a server: `Install-WindowsFeature VolumeActivation -IncludeManagementTools`. Volume Activation Tools → ADBA → enter CSVLK → activate online → name the object.
3. On a test client: `slmgr /ato` then `slmgr /dlv` — description should reference AD activation; event 12288 should not show a KMS host.
4. Leave the KMS host running ≥ 30 days for pre-Win 8 and non-ADBA-matching clients, then retire it (Playbook 1 step 4).
Rollback: delete the activation object (ADSI Edit, Configuration partition). Clients fall back to KMS discovery at next activation attempt.
</details>

<details><summary>Playbook 3 — Fix a cloned-image fleet with duplicate CMIDs</summary>

1. Identify duplicates: collect `Client Machine ID` from `/dlv` (script column `ClientMachineId`) and group.
2. Correct the image: generalize with `sysprep /generalize /oobe` and re-capture. For already-deployed machines, the supported reset is `slmgr /rearm` (limited rearm count — check `RemainingWindowsReArmCount` via CIM first) followed by reboot and `/ato`.
3. Verify CMIDs are unique and host count rises.
Caution: `/rearm` resets the grace timer and consumes a rearm; out-of-rearms machines need re-imaging.
</details>

<details><summary>Playbook 4 — Pro devices not stepping up to Enterprise (Intune/Autopilot fleet)</summary>

1. Pull an affected device's `dsregcmd /status`. If `WorkplaceJoined : YES` and `AzureAdJoined : NO`, it's only registered — re-provision via Autopilot/Entra join.
2. Confirm Pro activation: `slmgr /dli` → Licensed, channel OEM_DM or RETAIL. If Pro shows Unlicensed and channel is KMSCLIENT, an imaging task injected a GVLK — reinstall the firmware key: `$k=(Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey; slmgr /ipk $k; slmgr /ato`.
3. Entra admin centre → Sign-in logs → filter application *Universal Store Service APIs and Web Application*: failures with CA reasons → add exclusion for AppId `45a330b1-b1ec-4cc1-9161-9f03992aa49f` to the blocking policy (document compensating control).
4. Licence check: user has a SKU containing *Windows 10/11 Enterprise E3/E5* service plan enabled (`WIN10_PRO_ENT_SUB` / `WIN10_VDA_E5` service plans — confirm in the user's licence details; disabled service plans block it).
5. Sign out/in. Edition flips without reboot; check `(Get-CimInstance Win32_OperatingSystem).Caption`.
Rollback: CA exclusion is the only tenant-wide change — scope it narrowly and remove if Microsoft changes the requirement.
</details>

<details><summary>Playbook 5 — Remote KMS/ADBA clients falling out of activation</summary>

- Short term: on VPN, `slmgr /ato`.
- Structural: move those devices to MAK (`slmgr /ipk <MAK>` + `/ato`, count consumed once) or, if Entra-joined Pro, to Subscription Activation. KMS/ADBA assume periodic corporate connectivity; Always On VPN device tunnel (`AlwaysOnVPN-A.md`) also satisfies it for KMS if 1688 is routed.
</details>

---
## Evidence Pack
```powershell
# Collect-VolumeActivationEvidence.ps1 — run elevated on the affected client (and again on the KMS host)
$out = Join-Path $env:TEMP "ActivationEvidence_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd_HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber |
  Export-Csv "$out\os.csv" -NoTypeInformation
Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" |
  Select-Object Name, Description, LicenseStatus, GracePeriodRemaining, PartialProductKey,
    KeyManagementServiceMachine, DiscoveredKeyManagementServiceMachineName,
    KeyManagementServiceCurrentCount, VLActivationTypeEnabled, LicenseStatusReason |
  Export-Csv "$out\licensing-products.csv" -NoTypeInformation
Get-CimInstance SoftwareLicensingService |
  Select-Object Version, ClientMachineID, KeyManagementServiceListeningPort, KeyManagementServiceDnsPublishing,
    OA3xOriginalProductKeyDescription, RemainingWindowsReArmCount |
  Export-Csv "$out\licensing-service.csv" -NoTypeInformation
$dom = (Get-CimInstance Win32_ComputerSystem).Domain
Resolve-DnsName -Type SRV "_vlmcs._tcp.$dom" -ErrorAction SilentlyContinue | Out-File "$out\srv.txt"
dsregcmd /status > "$out\dsregcmd.txt"
w32tm /query /status > "$out\w32tm.txt"
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Microsoft-Windows-Security-SPP'} -MaxEvents 200 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\spp-events.csv" -NoTypeInformation
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```
Note: `OA3xOriginalProductKey` is deliberately **not** exported — only its description — so the pack is safe to attach to tickets.

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Detailed licence info | `slmgr /dlv` (`/dlv all` on host) |
| Expiry date | `slmgr /xpr` |
| Install key | `slmgr /ipk <key>` |
| Activate now | `slmgr /ato` |
| Pin / clear KMS host | `slmgr /skms <host>:1688` / `slmgr /ckms` |
| Host DNS publishing on/off | `slmgr /cdns` / `slmgr /ddns` |
| ADBA object online | `slmgr /ad-activation-online <CSVLK> [name]` |
| List ADBA objects | `slmgr /ao-list` |
| Firmware (OA3) key | `(Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey` |
| CIM status (no VBScript) | `Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL"` |
| Trigger activation via CIM | `Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" \| Invoke-CimMethod -MethodName Activate` |
| SRV lookup | `Resolve-DnsName -Type SRV _vlmcs._tcp.<domain>` |
| Port check | `Test-NetConnection <host> -Port 1688` |
| Server edition convert | `DISM /Online /Get-TargetEditions` then `/Set-Edition:<ed> /ProductKey:<key> /AcceptEula` |
| Join/PRT state | `dsregcmd /status` |

---
## 🎓 Learning Pointers
- Microsoft's volume activation planning overview explains why KMS has thresholds and ADBA doesn't — read it before choosing for a new client: https://learn.microsoft.com/windows/deployment/volume-activation/plan-for-volume-activation-client
- ADBA walkthrough (role install, activation object creation): https://learn.microsoft.com/windows/deployment/volume-activation/activate-using-active-directory-based-activation-client
- KMS host setup and the SRV/1688/count mechanics: https://learn.microsoft.com/windows/deployment/volume-activation/activate-using-key-management-service-vamt
- Error-code reference you'll keep coming back to: https://learn.microsoft.com/windows-server/get-started/activation-error-codes
- Subscription Activation requirements (join state, per-user licensing, firmware key): https://learn.microsoft.com/windows/deployment/windows-subscription-activation
- Related EZAdmin: `ESU-A.md` (MAK add-on activation), `VBScriptDeprecation-A.md` (slmgr is VBScript), `Time/TimeSync A.md` (clock skew), `Security/ConditionalAccess` (CA exclusions).
