# RDS Licensing (RD Licensing / CALs / Grace Period) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.
> Hotfix: `RDSLicensing-B.md` · Script: `../Scripts/Get-RDSLicensingDiagnostics.ps1`

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
- **In scope:** on-prem / IaaS Remote Desktop Services with the RD Session Host role (Windows Server 2016–2025): licensing mode, RD Licensing server, CAL packs, grace period, CAL issuance/revocation, client license store.
- **Out of scope:** Azure Virtual Desktop and Windows 365 (licensed by user subscription, no RDS CALs for Windows client multi-session — see `Azure/` folders), plain admin RDP (Remote Desktop for Administration: 2 concurrent sessions, no CALs), RDS connectivity failures (`RDP-A.md`), the Sept 2026 LSM deadlock (`RDSDeadlockSept2026-A.md`).
- Engineer has local admin on RDSH and license server, Domain Admin for the AD group step.

---
## How It Works

<details><summary>Full architecture</summary>

### Components
```
 Client (mstsc / RD Web / RemoteApp)
      │  RDP 3389 (or via RD Gateway 443)
      ▼
 RD Session Host ──(RPC)──► RD Licensing server (TermServLicensing service, CAL database)
      ▲                              │  activation (HTTPS to Microsoft Clearinghouse / web / phone)
      │  deployment config           ▼
 RD Connection Broker          Installed CAL packs (type: Per User | Per Device, version: 2016/2019/2022/2025)
```

### Licensing mode
Every RDSH runs in exactly one mode:
- **Per Device (2):** each client device receives a CAL. First connection → temporary CAL (90 days); second connection → permanent CAL if available. Enforced — pack exhaustion refuses sessions. Permanent CALs expire after a random 52–89 days and are silently renewed if the device keeps connecting; unused ones return to the pool.
- **Per User (4):** the license server records CAL use against the AD user object. **Not enforced** — users are not refused when the pack is "exceeded"; compliance is on reporting. Requires domain membership (RDSH and LS) and the LS to be in the domain-local group **Terminal Server License Servers** so it can write the licensing attributes to user objects.

Mode sources, in precedence order:
1. **Group Policy** — `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services` → `LicensingMode` (2/4), `LicenseServers` (comma-separated).
2. **Deployment config** pushed by Connection Broker (`Set-RDLicenseConfiguration`) — written to each RDSH.
3. **Local WMI** (`Win32_TerminalServiceSetting.ChangeMode` / `SetSpecifiedLicenseServerList`).

If GPO is set, 2 and 3 appear to succeed but have no effect — the #1 source of "I set it in Server Manager and it still says not configured".

### Grace period
When the RDSH role is installed, a one-time **120-day** grace period starts. During it, no license server is contacted. At expiry, if mode + license server aren't working, non-admin sessions are refused with "no Remote Desktop license servers available". The timer is stored under `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod` (ACL-protected). Remaining days: `Win32_TerminalServiceSetting.GetGracePeriodDays()`. Configuring licensing early doesn't shorten or extend anything — once a working LS is found, the grace value simply stops mattering.

### License server discovery
Explicit list (GPO/WMI) only on modern Windows Server — auto-discovery via AD SCP is legacy and should not be relied on. The RDSH caches LS reachability; after fixing, a user reconnect is enough, but a `TermService` restart (disconnects everyone) forces a re-query.

### CAL version compatibility
- CAL version ≥ RDSH OS version (2022 RDSH accepts 2022 and 2025 CALs, not 2019).
- License server OS ≥ CAL version it hosts (a 2019 LS can't host 2025 CALs).
- Practical rule: upgrade the license server first, install new CALs, then upgrade session hosts.

### Activation
The LS must be activated (links it to a Microsoft-issued certificate) before it can issue permanent CALs. Unactivated LS issues only temporary Per Device CALs, and Per User tracking doesn't work properly. Re-activation is needed after certain hardware changes or if the LS certificate becomes invalid.

### Client side
For Per Device, the client stores its CAL in `HKLM\SOFTWARE\Microsoft\MSLicensing` (`HardwareID`, `Store\License000`). Corruption produces "licensing protocol" disconnects; deleting the key and running `mstsc` elevated once regenerates it.
</details>

---
## Dependency Stack

```
[8] User session accepted beyond grace period
[7] CAL available and matching (type == mode, version >= RDSH OS); Per User: LS in "Terminal Server License Servers"
[6] License server activated
[5] TermServLicensing running on LS
[4] Network: DNS + RPC 135/dynamic RDSH → LS; firewall rule group "Remote Desktop Licensing Server"
[3] RDSH knows LS (GPO LicenseServers or deployment/WMI list)
[2] RDSH licensing mode set (GPO LicensingMode or deployment/WMI) — GPO wins
[1] RDSH role installed; domain-joined (required for Per User)
[0] Correct product: RDS CALs are for Windows Server RDSH, not AVD/W365
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "No Remote Desktop license servers available to provide a license" ~120 days after build | Mode/LS never configured, grace expired | WMI `LicensingType`, `GetSpecifiedLicenseServerList` |
| Notification "Remote Desktop licensing mode is not configured" | Mode not set (or GPO absent on standalone RDSH) | GPO + WMI |
| Server Manager shows correct settings, lsdiag disagrees | GPO overriding deployment config | `gpresult`, policy registry |
| "No RD client access licenses available" (Per Device) | Pack exhausted or wrong-version pack | `Win32_TSLicenseKeyPack` AvailableLicenses / ProductVersion |
| Works for some RDSH, not others | Newer OS hosts with older CALs | ProductVersion vs RDSH OS |
| lsdiag: "license server is not a member of the Terminal Server License Servers group" | Per User tracking can't write to AD | AD group membership |
| lsdiag: LS not activated | Never activated or activation lost | `licmgr.exe` → Review Configuration |
| lsdiag can't contact LS | Firewall/RPC/DNS/service stopped | `Test-NetConnection -Port 135`, service state |
| Single client: "licensing protocol" error | Corrupt MSLicensing store | Client registry |
| Workgroup RDSH, Per User set, users refused after grace | Per User needs AD | Switch to Per Device |
| Azure VM RDP fails with licensing error | RDSH role installed on a VM used only for admin RDP | Remove role or license it |

---
## Validation Steps

1. **Mode & LS list (RDSH)**
   ```powershell
   $ts = Get-CimInstance -Namespace root/cimv2/TerminalServices -ClassName Win32_TerminalServiceSetting
   $ts.LicensingType; (Invoke-CimMethod -InputObject $ts -MethodName GetSpecifiedLicenseServerList).SpecifiedLSList
   ```
   Good: `4` or `2`; FQDN(s). Bad: other value / empty.
2. **Policy source**
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -EA SilentlyContinue | Select LicensingMode,LicenseServers
   ```
   Good: absent (deployment manages) or matching. Bad: present and different from intent.
3. **Grace days**
   ```powershell
   (Invoke-CimMethod -InputObject $ts -MethodName GetGracePeriodDays).DaysLeft
   ```
   Informational — 0 is fine *if* steps 4–6 pass.
4. **Reachability** — `Test-NetConnection <ls> -Port 135` → `TcpTestSucceeded : True`.
5. **LS service & packs** (on LS)
   ```powershell
   Get-Service TermServLicensing
   Get-CimInstance Win32_TSLicenseKeyPack | ft KeyPackId,ProductVersion,TypeAndModel,TotalLicenses,AvailableLicenses,IssuedLicenses
   ```
   Good: Running; pack with right type/version; Available > 0 (Per Device).
6. **AD group (Per User)**
   ```powershell
   Get-ADGroupMember "Terminal Server License Servers" | Select Name
   ```
   Good: LS computer account present.
7. **lsdiag.msc** on RDSH — no warnings.

---
## Troubleshooting Steps (by phase)

**Phase 1 — RDSH configuration:** Validation 1–3. Decide single source of truth (GPO for standalone/mixed estates; deployment config when a broker manages all hosts and no GPO exists). Remove conflicts.

**Phase 2 — Path to LS:** Validation 4. DNS name resolution, RPC, service. If multiple LS listed, the first reachable is used; a dead first entry slows logons.

**Phase 3 — LS state:** Validation 5–6, `licmgr.exe` Review Configuration. Activation, packs, AD group.

**Phase 4 — Issuance:** Per Device — watch `Win32_TSIssuedLicense` grow when a new device connects. Per User — use `licmgr.exe` → *Create Report* → Per User CAL Usage.

**Phase 5 — Client:** only if a single device fails — MSLicensing store.

---
## Remediation Playbooks

<details><summary>Playbook A — Standardise licensing via GPO (multi-host estate)</summary>

1. Create GPO "RDS – Licensing" linked to the RDSH OU.
2. Set *Use the specified Remote Desktop license servers* = `ls1.contoso.com,ls2.contoso.com`, *Set the Remote Desktop licensing mode* = Per User.
3. On each RDSH: `gpupdate /force`; verify with Validation 1–2; run `lsdiag.msc`.
4. If a broker exists, set the same values with `Set-RDLicenseConfiguration` so Server Manager doesn't show contradictory data.
Rollback: unlink GPO, `gpupdate /force`; hosts revert to deployment/WMI values.
</details>

<details><summary>Playbook B — Build/replace the license server</summary>

1. On a domain-joined server with OS ≥ target CAL version: `Install-WindowsFeature RDS-Licensing -IncludeManagementTools`.
2. `licmgr.exe` → Activate Server → Install Licenses (agreement number / retail keys; type & version must match).
3. Review Configuration → Add to Group (Per User).
4. Point RDSH at it (Playbook A). Keep the old LS online until issued Per Device CALs migrate/expire, or use *Manage Licenses* to migrate packs (requires Microsoft Clearinghouse).
Rollback: re-point GPO to old LS.
</details>

<details><summary>Playbook C — Switch Per Device → Per User (or reverse)</summary>

Confirm the customer owns CALs of the new type first (it's a licensing decision, not just technical). Change GPO/deployment mode, `gpupdate`, verify. Per Device CALs already issued remain in the LS database until expiry; they don't transfer. Rollback: restore previous mode.
</details>

<details><summary>Playbook D — Client MSLicensing reset (single device, Per Device)</summary>

Export `HKLM\SOFTWARE\Microsoft\MSLicensing`, delete it, run `mstsc.exe` elevated once, connect. For thin clients, follow the vendor's procedure (licence stored in firmware/profile). Rollback: import the `.reg`.
</details>

<details><summary>Playbook E — Lock-out recovery after grace expiry</summary>

1. `mstsc /admin /v:<rdsh>` (uses admin sessions, no CAL).
2. Execute Playbook A (or B if no LS exists). Temporary CALs issue immediately once mode + LS + activation are correct, even before purchasing permanent CALs (Per Device) — this buys 90 days for procurement.
3. Grace-period registry reset: **unsupported**, only record it if the customer explicitly accepts the compliance risk.
</details>

---
## Evidence Pack

```powershell
# Run elevated on the RDSH. Optional -LS to also query the license server remotely (needs WinRM/DCOM + admin).
param([string]$LS, [string]$Out = "$env:TEMP\RDSLic_$(Get-Date -f yyyyMMddHHmm)")
New-Item $Out -ItemType Directory -Force | Out-Null
$ts = Get-CimInstance -Namespace root/cimv2/TerminalServices -ClassName Win32_TerminalServiceSetting
[pscustomobject]@{
  Host        = $env:COMPUTERNAME
  OS          = (Get-CimInstance Win32_OperatingSystem).Caption
  Build       = [Environment]::OSVersion.Version.ToString()
  LicType     = $ts.LicensingType
  LSList      = ((Invoke-CimMethod -InputObject $ts -MethodName GetSpecifiedLicenseServerList).SpecifiedLSList -join ',')
  GraceDays   = (Invoke-CimMethod -InputObject $ts -MethodName GetGracePeriodDays).DaysLeft
} | Export-Csv "$Out\RDSH.csv" -NoTypeInformation
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -EA SilentlyContinue | Out-File "$Out\Policy.txt"
gpresult /scope computer /h "$Out\gpresult.html" /f | Out-Null
Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin" -MaxEvents 300 -EA SilentlyContinue |
  Select TimeCreated,Id,LevelDisplayName,Message | Export-Csv "$Out\RCM_Admin.csv" -NoTypeInformation
if ($LS) {
  Test-NetConnection $LS -Port 135 | Out-File "$Out\LS_Port135.txt"
  Get-CimInstance -ComputerName $LS Win32_TSLicenseKeyPack -EA SilentlyContinue | Export-Csv "$Out\LS_KeyPacks.csv" -NoTypeInformation
}
Compress-Archive "$Out\*" "$Out.zip" -Force; "Evidence: $Out.zip"
```
Add a screenshot of `lsdiag.msc` and `licmgr.exe` → Review Configuration.

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Mode | `(Get-CimInstance -Namespace root/cimv2/TerminalServices Win32_TerminalServiceSetting).LicensingType` |
| LS list | `Invoke-CimMethod -InputObject $ts -MethodName GetSpecifiedLicenseServerList` |
| Grace days | `Invoke-CimMethod -InputObject $ts -MethodName GetGracePeriodDays` |
| Set mode (WMI) | `Invoke-CimMethod -InputObject $ts -MethodName ChangeMode -Arguments @{LicensingType=[uint32]4}` |
| Set LS (WMI) | `Invoke-CimMethod -InputObject $ts -MethodName SetSpecifiedLicenseServerList -Arguments @{Servers=[string[]]@('<ls>')}` |
| Broker config | `Get-RDLicenseConfiguration -ConnectionBroker <cb>` / `Set-RDLicenseConfiguration ...` |
| Policy values | `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'` |
| CAL packs | `Get-CimInstance Win32_TSLicenseKeyPack` (on LS) |
| Issued CALs | `Get-CimInstance Win32_TSIssuedLicense` (on LS) |
| LS service | `Get-Service TermServLicensing` |
| AD group | `Get-ADGroupMember 'Terminal Server License Servers'` |
| Diagnoser | `lsdiag.msc` |
| Manager | `licmgr.exe` |
| Install LS role | `Install-WindowsFeature RDS-Licensing -IncludeManagementTools` |
| Admin bypass | `mstsc /admin /v:<rdsh>` |

---
## 🎓 Learning Pointers
- Microsoft's structured RDS licensing troubleshooting guide — the source for the WMI checks used here. — [Troubleshoot RDS licensing](https://learn.microsoft.com/troubleshoot/windows-server/remote/troubleshoot-rds-licensing-guidance)
- CAL types, version compatibility and the 120-day grace period explained. — [License your RDS deployment with client access licenses](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-client-access-license)
- Why the "licensing mode not configured" balloon appears even when Server Manager looks right. — [Licensing mode not configured warning](https://learn.microsoft.com/en-us/troubleshoot/windows-server/remote/remote-desktop-licensing-mode-not-configured-warning)
- CAL tracking and the Per User reporting model. — [Track your RDS CALs](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-track-cals)
- If you're sizing a replacement: AVD/Windows 365 use per-user subscription licensing instead of RDS CALs for Windows client — see `Azure/` runbooks before renewing CALs on an ageing RDS farm.
