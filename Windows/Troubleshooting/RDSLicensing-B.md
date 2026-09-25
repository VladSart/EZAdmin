# RDS Licensing (RD Licensing / CALs / Grace Period) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.
> Covers: "No Remote Desktop license servers available to provide a license", "The remote session was disconnected because there are no Remote Desktop client access licenses available", "licensing mode for the Remote Desktop Session Host server is not configured", RDSH grace period expiry, per-device CAL exhaustion, client-side licensing protocol errors.
> Deep dive: `RDSLicensing-A.md` · Script: `../Scripts/Get-RDSLicensingDiagnostics.ps1` · Not a licensing problem? → `RDP-B.md` / `RDSDeadlockSept2026-B.md`

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run on the **RD Session Host** (elevated):

```powershell
$ts = Get-CimInstance -Namespace root/cimv2/TerminalServices -ClassName Win32_TerminalServiceSetting
"LicensingType: $($ts.LicensingType)   (2=Per Device, 4=Per User, other=not configured)"
(Invoke-CimMethod -InputObject $ts -MethodName GetSpecifiedLicenseServerList).SpecifiedLSList
(Invoke-CimMethod -InputObject $ts -MethodName GetGracePeriodDays).DaysLeft
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -ErrorAction SilentlyContinue | Select LicensingMode,LicenseServers
Test-NetConnection "<licenseserver>" -Port 135
```

| Result | Meaning | Go to |
|---|---|---|
| `LicensingType` not 2 or 4 | Licensing mode never set → grace period only, then refusal | Fix 1 |
| License server list empty | RDSH doesn't know where to get CALs | Fix 1 |
| `DaysLeft` = 0 and no working license server | Grace expired — sessions refused (admins can still use `mstsc /admin`) | Fix 1 → Fix 2 |
| GPO `LicensingMode`/`LicenseServers` differ from WMI values | GPO wins; Server Manager deployment settings are being overridden | Fix 1 (fix the GPO) |
| Port 135 fails | Firewall/RPC path to license server blocked | Fix 3 |
| All above fine, users still refused | License server side: not activated, no CALs of right type/version, pack exhausted | Fix 2 / Fix 4 |
| Only one client affected, error "licensing protocol" | Corrupt client-side MSLicensing store | Fix 5 |

> Admin sessions (`mstsc /admin`, max 2) do **not** consume CALs — use them to get in when users are locked out.

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
User session accepted by RDSH (beyond grace period)
└── RDSH licensing mode set (Per User 4 / Per Device 2) — via GPO, or Connection Broker deployment, or WMI
    └── RDSH has license server list
        └── RDSH → license server reachable (DNS, RPC 135 + dynamic ports, TermServLicensing running)
            └── License server ACTIVATED with Microsoft
                └── Installed CAL pack matches: mode (User vs Device) AND version ≥ RDSH OS version
                    ├── Per Device: available CALs > 0 (issued permanently, temp CALs expire)
                    └── Per User: license server in AD group "Terminal Server License Servers" (for tracking/reporting)
                        └── Domain-joined RDSH (Per User requires AD; workgroup = Per Device only)
└── Client: MSLicensing store not corrupt (Per Device only)
```
</details>

---
## Diagnosis & Validation Flow

1. **Mode and servers on the RDSH** — Triage block. Expected: `LicensingType 4` (or 2), license server FQDN listed, `DaysLeft` any value.
2. **Where is it configured?**
   ```powershell
   gpresult /scope computer /h "$env:TEMP\gp.html"; Start-Process "$env:TEMP\gp.html"
   ```
   Look under *Windows Components > Remote Desktop Services > Remote Desktop Session Host > Licensing*. If set, **GPO is authoritative** — changing Server Manager does nothing.
3. **Licensing Diagnoser** on the RDSH: run `lsdiag.msc`. Expected: no warnings, license server listed with "Activated", CALs available. It reports mode mismatch and version mismatch explicitly.
4. **License server inventory** (on license server):
   ```powershell
   Get-Service TermServLicensing
   Get-CimInstance Win32_TSLicenseKeyPack | Select KeyPackId,ProductVersion,TypeAndModel,TotalLicenses,AvailableLicenses,IssuedLicenses,ExpirationDate
   ```
   Expected: service Running; a pack whose `TypeAndModel` matches the mode (Per User/Per Device) and `ProductVersion` ≥ the RDSH OS (e.g. Windows Server 2025 RDSH needs 2025 CALs). Built-in/temporary packs don't count.
5. **RDSH event log**:
   ```powershell
   Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin" -MaxEvents 50 |
     ? Message -match 'licens' | Select TimeCreated,Id,Message | fl
   ```
   Messages about grace expiry, no license server, or mode not configured confirm the layer.

---
## Common Fix Paths

<details><summary>Fix 1 — Set licensing mode and license server on the RDSH</summary>

**Deployment with Connection Broker:** Server Manager → Remote Desktop Services → Overview → Tasks → *Edit Deployment Properties* → RD Licensing → choose mode + add server. Or:
```powershell
Set-RDLicenseConfiguration -LicenseServer "<ls.contoso.com>" -Mode PerUser -ConnectionBroker "<cb.contoso.com>" -Force
Get-RDLicenseConfiguration -ConnectionBroker "<cb.contoso.com>"
```
**Standalone RDSH (no broker) — GPO preferred:** Computer Config > Admin Templates > Windows Components > RDS > RDSH > Licensing:
- *Use the specified Remote Desktop license servers* = `<ls.contoso.com>`
- *Set the Remote Desktop licensing mode* = Per User (or Per Device)

WMI alternative (no GPO present):
```powershell
$ts = Get-CimInstance -Namespace root/cimv2/TerminalServices -ClassName Win32_TerminalServiceSetting
Invoke-CimMethod -InputObject $ts -MethodName ChangeMode -Arguments @{LicensingType=[uint32]4}
Invoke-CimMethod -InputObject $ts -MethodName SetSpecifiedLicenseServerList -Arguments @{Servers=[string[]]@("<ls.contoso.com>")}
```
Then `gpupdate /force` (if GPO) and have a user reconnect. No reboot normally needed. Rollback: set previous values (record them from Triage first).
</details>

<details><summary>Fix 2 — License server not activated / wrong or missing CALs</summary>

1. On license server: `licmgr.exe` → right-click server → *Review Configuration*. Should show green ticks for **Activated** and (Per User) **member of Terminal Server License Servers group**. Use *Add to Group* if prompted (needs Domain Admin).
2. Not activated → right-click → *Activate Server* (Automatic connection needs outbound HTTPS; otherwise web browser/telephone method).
3. Install CALs → right-click → *Install Licenses*. The CAL **type** must equal the RDSH mode and the **version** must be ≥ RDSH OS. A 2019 CAL pack on a 2022/2025 RDSH does not work.
4. Re-run `lsdiag.msc` on the RDSH.
</details>

<details><summary>Fix 3 — RDSH can't reach the license server</summary>

```powershell
Resolve-DnsName "<ls.contoso.com>"
Test-NetConnection "<ls.contoso.com>" -Port 135
Get-Service -ComputerName "<ls.contoso.com>" TermServLicensing
```
Allow RPC (135 + dynamic RPC range) from RDSH → license server; on the LS host firewall enable the *Remote Desktop Licensing Server* rule group. Ensure TermServLicensing is Automatic + Running.
</details>

<details><summary>Fix 4 — Per Device CAL pack exhausted</summary>

```powershell
Get-CimInstance Win32_TSLicenseKeyPack | ? TypeAndModel -match 'Device' | Select ProductVersion,TotalLicenses,AvailableLicenses,IssuedLicenses
Get-CimInstance Win32_TSIssuedLicense | Select sIssuedToComputer,sIssuedToUser,ExpirationDate,LicenseStatus | Sort ExpirationDate
```
Permanent Per Device CALs self-release after a random 52–89 days of non-use. For decommissioned PCs revoke immediately in `licmgr.exe` (right-click license → *Revoke License*; limited quota per OS version). Otherwise buy more, or move to Per User if devices are shared by few users.
</details>

<details><summary>Fix 5 — Single client: licensing protocol error (Per Device)</summary>

On the **client** PC (elevated), export then remove the cached license:
```powershell
reg export "HKLM\SOFTWARE\Microsoft\MSLicensing" "$env:TEMP\MSLicensing_backup.reg" /y
Remove-Item "HKLM:\SOFTWARE\Microsoft\MSLicensing" -Recurse -Force
```
Then launch `mstsc.exe` **once as administrator** (so it can recreate the key) and connect. Rollback: `reg import "$env:TEMP\MSLicensing_backup.reg"`.
</details>

<details><summary>Emergency (unsupported) — grace-period reset</summary>

Deleting `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod` (requires taking ownership) restarts the 120-day timer. **Not supported, licence-non-compliant, and not a fix.** Use `mstsc /admin` for access and do Fix 1/2 instead. Document the customer's decision in the ticket if they insist.
</details>

---
## Escalation Evidence

```
Ticket: RDS Licensing — <short description>
RDSH name / OS build:          <>
Deployment:                    <Broker-based / standalone RDSH>
LicensingType (WMI):           <2/4/other>     GPO LicensingMode: <>
License server list (WMI):     <>              GPO LicenseServers: <>
Grace DaysLeft:                <>
Port 135 RDSH→LS:              <pass/fail>
LS activated:                  <Y/N>   In "Terminal Server License Servers" group: <Y/N>
CAL packs (type/version/avail): <paste Win32_TSLicenseKeyPack>
lsdiag.msc findings:           <paste/screenshot>
Exact user error text:         <>
Fixes attempted:               <>
Get-RDSLicensingDiagnostics.ps1 CSV attached: <Y/N>
```

---
## 🎓 Learning Pointers
- The 120-day grace period is a one-time allowance from when the RDSH role is installed — a server that "suddenly broke" four months after build almost always never had its mode/server configured. — [Troubleshoot RDS licensing](https://learn.microsoft.com/troubleshoot/windows-server/remote/troubleshoot-rds-licensing-guidance)
- GPO beats Server Manager: if a Licensing GPO exists, the broker's deployment properties are silently ignored. — [Licensing mode not configured warning](https://learn.microsoft.com/en-us/troubleshoot/windows-server/remote/remote-desktop-licensing-mode-not-configured-warning)
- CAL version must be ≥ the RDSH OS version; upgrading the session hosts means buying/installing new CALs *and* the license server OS must be ≥ the CAL version.
- Per User CALs are not technically enforced (tracking only) but require AD; Per Device CALs are enforced and the only option for workgroup RDSH.
- `lsdiag.msc` (RD Licensing Diagnoser) is the fastest single view — learn to read it before touching registry. — [License your RDS deployment with CALs](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-client-access-license)
