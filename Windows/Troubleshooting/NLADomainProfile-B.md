# NLA Domain Network Detection (Public/Private Profile on Domain LAN) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Typical tickets:** "Firewall suddenly blocking RDP/WinRM/SMB after reboot", "server shows *Public network*", "DC firewall profile is Public", "GPO firewall rules not applying", "second NIC is Unidentified network", "domain profile only after I disable/enable the adapter".

> Scope: why a **domain-joined** Windows device / server / DC does **not** get `DomainAuthenticated` on its LAN interface. For "No Internet" globe/yellow triangle see `NCSI-B.md`. For firewall rule logic itself see `Firewall-B.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run elevated on the affected machine (~60 s):

```powershell
# 1. What category does each interface have, and which firewall profile is active?
Get-NetConnectionProfile | Select-Object InterfaceAlias, Name, NetworkCategory, IPv4Connectivity
(Get-NetFirewallSetting -PolicyStore ActiveStore).ActiveProfile

# 2. Is the machine domain-joined, and is it a DC? (DomainRole 4/5 = DC)
Get-CimInstance Win32_ComputerSystem | Select-Object Domain, PartOfDomain, DomainRole

# 3. Can the DC locator find a DC right now? (uses DNS SRV + LDAP ping UDP 389 — same path NLA uses)
nltest /dsgetdc:$((Get-CimInstance Win32_ComputerSystem).Domain) /force

# 4. Network-identification services
Get-Service NlaSvc, netprofm | Select-Object Name, Status, StartType

# 5. OS build (Server 2025 DCs need June 2025 CU or later)
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($cv.CurrentBuild).$($cv.UBR)"
```

| Result | Meaning | Go to |
|---|---|---|
| `nltest` succeeds **now**, but interface is Public/Private | Detection failed at boot/connect time and was never retried (timing / negative cache) | Fix 1, then Fix 2 (servers) or Fix 3 (DCs) |
| `nltest` fails: `ERROR_NO_SUCH_DOMAIN` (1355) | DNS can't find DC SRV records or DC unreachable | Fix 4 |
| DomainRole 4/5, build `26100.x` with UBR < 4349 | Known Server 2025 DC bug (fixed in KB5060842, June 2025) | Fix 3 |
| One NIC DomainAuthenticated, another Public/"Unidentified network" | Multi-homed — the second NIC has no path to a DC (iSCSI/backup/cluster heartbeat/Hyper-V internal) | Fix 5 |
| Correct after VPN connects only sometimes / Public until adapter bounce on laptops | Detection ran before tunnel/802.1X was up | Fix 1, Fix 6 |
| `NlaSvc`/`netprofm` Stopped or Disabled | Hardening script or debloater broke network identification | Fix 1 (start + set Automatic) |
| `PartOfDomain = False` | Not a domain-joined issue — a workgroup/Entra-only device cannot be DomainAuthenticated | Use Private via policy (Fix 5) |

> ⚠️ `Set-NetConnectionProfile -NetworkCategory DomainAuthenticated` is **not valid** — the cmdlet only accepts `Public` or `Private`. Domain category can only be *detected*, never set.

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
DomainAuthenticated on interface X
└── NLA domain detection succeeds over interface X (at connect/boot, or on retry)
    ├── Network identification service running
    │   ├── NlaSvc (Network Location Awareness)
    │   └── netprofm (Network List Service) — hosts more of the logic on Win 11 / Server 2022+
    ├── Machine is domain-joined (PartOfDomain = True)
    ├── DC locator (Netlogon / DsGetDcName) returns a DC
    │   ├── Interface X has DNS servers that hold _ldap._tcp.dc._msdcs.<domain> SRV records
    │   │   └── (DC itself: DNS Server service started + zones loaded — not just "running")
    │   ├── No cached negative result in Netlogon (ERROR_NO_SUCH_DOMAIN from an earlier attempt)
    │   └── LDAP ping to DC over UDP 389 reachable via interface X's routes
    ├── Timing: the above is true WHEN NLA evaluates
    │   ├── Boot: NIC, DHCP, 802.1X, and (on DCs) AD DS + DNS must be ready
    │   └── VPN: tunnel interface up and routes/DNS pushed before detection
    └── Known OS defect absent (Server 2025 DC: KB5060842 / 26100.4349+)
          ↓
Windows Firewall applies the Domain profile to interface X
          ↓
GPO/Intune firewall rules scoped to Domain profile take effect (RDP, WinRM, SMB, monitoring agents)
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm per-interface category**
   `Get-NetConnectionProfile | Format-Table InterfaceAlias, Name, NetworkCategory`
   *Good:* LAN interface `DomainAuthenticated`, `Name` = domain FQDN. *Bad:* `Public`/`Private` with name `Network`, `Network 2` or `Unidentified network` → detection failed on that interface.

2. **Confirm the firewall consequence**
   `Get-NetFirewallSetting -PolicyStore ActiveStore | Select-Object ActiveProfile`
   *Good:* `Domain`. *Bad:* `Public` (or `Domain, Public` on multi-homed — each interface gets its own profile).

3. **Test the exact discovery path NLA uses**
   `nltest /dsgetdc:<domainFQDN> /force`
   *Good:* `DC: \\<DCName>` + `The command completed successfully`. *Bad:* `ERROR_NO_SUCH_DOMAIN` → go to step 4.

4. **DNS SRV lookup through this interface's resolvers**
   ```powershell
   Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses
   Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.<domainFQDN>"
   ```
   *Good:* one SRV record per DC. *Bad:* `DNS name does not exist` → wrong DNS server (public resolver, router, ISP) on the NIC.

5. **Reach the DC**
   `Test-NetConnection <DCName> -Port 389` (TCP) — and on firewalled segments confirm **UDP 389** is permitted (LDAP ping is UDP; TCP passing alone is not proof).
   *Good:* `TcpTestSucceeded : True`. *Bad:* route/ACL/VLAN issue → network team.

6. **Check the event trail**
   ```powershell
   Get-WinEvent -LogName 'Microsoft-Windows-NetworkProfile/Operational' -MaxEvents 20 |
     Select-Object TimeCreated, Id, Message | Format-List
   ```
   *Look for:* 10000 (network connected — shows Name + Category assigned) and 10001 (disconnected). A 10000 with `Category: Public` at boot followed by nothing = no retry happened.

7. **Re-test after Fix** — repeat step 1. Category must flip to `DomainAuthenticated` without a reboot after Fix 1; if it reverts on next reboot, apply Fix 2/3.

---
## Common Fix Paths

<details><summary>Fix 1 — Force re-detection now (non-destructive)</summary>

```powershell
# Clear Netlogon's cached DC-locator failure, then make NLA re-evaluate
nltest /dsgetdc:<domainFQDN> /force
Set-Service NlaSvc -StartupType Automatic
Restart-Service NlaSvc -Force          # -Force also restarts dependent services (e.g. netprofm on older builds)
Start-Sleep 10
Get-NetConnectionProfile | Format-Table InterfaceAlias, NetworkCategory
```
If NLA restart is refused or hangs (seen on Server 2022), bounce the adapter instead — **this drops connectivity on that NIC for a few seconds; don't run it over an RDP session on the same NIC without console/iLO/iDRAC access**:
```powershell
Restart-NetAdapter -Name "<InterfaceAlias>"
```
</details>

<details><summary>Fix 2 — Member servers that come up Public after every reboot (delay NLA)</summary>

Typical causes: slow NIC teaming/LACP, 802.1X, or a hypervisor vNIC that gets an address after NLA's first look.
```powershell
sc.exe config NlaSvc start= delayed-auto
New-Item 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters' -Force | Out-Null
New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters' `
  -Name AlwaysExpectDomainController -PropertyType DWord -Value 1 -Force
Restart-Service NlaSvc -Force
```
`AlwaysExpectDomainController` is a **community/Microsoft Q&A workaround, not a documented Learn setting** — it makes NLA keep retrying domain detection instead of settling on a negative result. Test on one server first.

**Rollback:**
```powershell
sc.exe config NlaSvc start= auto
Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters' -Name AlwaysExpectDomainController
```
Fallback if still reverting: a startup Scheduled Task (SYSTEM, 2-min delay) running `Restart-Service NlaSvc -Force`.
</details>

<details><summary>Fix 3 — Domain controllers showing Public/Private</summary>

1. **Server 2025 DC:** install the latest cumulative update (fix shipped in **KB5060842**, June 2025, build 26100.4349). Until then: `Restart-NetAdapter *` after each boot (scheduled task at startup).
2. **DNS client order on the DC:** primary = a *partner* DC, secondary = its own IP, loopback (`127.0.0.1`) last. A DC pointing only at itself resolves nothing until its own DNS zones load — after NLA has already looked.
   ```powershell
   Set-DnsClientServerAddress -InterfaceAlias "<InterfaceAlias>" -ServerAddresses <partnerDC_IP>,<thisDC_IP>,127.0.0.1
   ```
   Rollback: re-run with the previous list (capture first: `Get-DnsClientServerAddress -InterfaceAlias "<InterfaceAlias>"`).
3. Apply Fix 2 (delayed-auto + `AlwaysExpectDomainController`) — most common working pattern on 2016–2022 DCs.
4. Single-DC sites/labs: expect this on every reboot without step 2+3 — there is no partner to answer early.
</details>

<details><summary>Fix 4 — DC locator fails (DNS / reachability)</summary>

```powershell
# Point the NIC at internal DNS only (no 8.8.8.8 / router as secondary — Windows doesn't fail over "logically")
Set-DnsClientServerAddress -InterfaceAlias "<InterfaceAlias>" -ServerAddresses <DC1_IP>,<DC2_IP>
Clear-DnsClientCache
ipconfig /registerdns
nltest /dsgetdc:<domainFQDN> /force
Restart-Service NlaSvc -Force
```
DHCP-assigned? Fix scope option 006 instead of the client. If SRV records are missing on the DC: `Restart-Service Netlogon` on the DC (re-registers), then `dcdiag /test:dns /v` → `ActiveDirectory/Troubleshooting/DNS/AD-DNS-B.md` and `DNS-Client-B.md`.
</details>

<details><summary>Fix 5 — Multi-homed server: secondary NIC Public / Unidentified</summary>

A storage/backup/heartbeat NIC with no DC path will **never** be DomainAuthenticated — that's by design. Options:
- Leave it Public (most restrictive) and make sure required rules (iSCSI, cluster, backup agent) are scoped to Public **on that interface** only.
- Or classify unidentified networks as Private via GPO: *Computer Configuration → Windows Settings → Security Settings → Network List Manager Policies → Unidentified Networks → Location type: Private*.
- Per-machine (persists for that network signature):
  ```powershell
  Set-NetConnectionProfile -InterfaceAlias "<InterfaceAlias>" -NetworkCategory Private
  ```
  Rollback: same command with `-NetworkCategory Public`.
- **Do not** add a default gateway to the storage NIC to "fix" it — breaks routing.
</details>

<details><summary>Fix 6 — Laptops on VPN / 802.1X</summary>

- Always On VPN **device tunnel** (or any pre-logon tunnel) gives NLA a DC path before user logon; user-tunnel-only devices stay Public/Private until the tunnel is up and NLA re-evaluates.
- Confirm VPN pushes internal DNS servers and the domain suffix, then `Restart-Service NlaSvc -Force` after connect to test.
- 802.1X wired: if auth completes after NLA's first look, use Fix 2. See `AlwaysOnVPN-B.md` and `WiFi-8021x-Windows-B.md`.
</details>

---
## Escalation Evidence
```
Ticket #: <ticket>
Hostname / role: <host> / <member server | DC | workstation>   OS build: <build.UBR>
Domain: <domainFQDN>    PartOfDomain: <True/False>   DomainRole: <0-5>
Interfaces (Alias | Name | NetworkCategory): <paste Get-NetConnectionProfile>
Active firewall profile: <Domain/Private/Public>
nltest /dsgetdc /force result: <DC name or error code>
SRV lookup _ldap._tcp.dc._msdcs.<domain>: <records / NXDOMAIN>
DNS servers per NIC: <paste>
TCP 389 to DC: <True/False>   UDP 389 permitted on path: <Yes/No/Unknown>
NlaSvc / netprofm status + StartType: <paste>
AlwaysExpectDomainController set: <Yes/No>
NetworkProfile/Operational 10000 events at last boot: <paste category>
Fixes attempted: <Fix #s + outcome>
Reverts after reboot: <Yes/No>
Script output: Get-NLADomainDetection.ps1 CSV attached: <path>
```

---
## 🎓 Learning Pointers
- NLA assigns a category **per interface**, and Windows Firewall applies a profile **per interface** — "server is Public" usually means "*one* NIC is Public". Firewall profiles overview: https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/
- Domain detection rides the DC locator (DNS SRV + LDAP ping). If `nltest /dsgetdc` fails, NLA will too — fix DNS first. DC locator: https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/dc-locator
- The Server 2025 DC "standard profile after restart" bug was fixed in KB5060842 (June 2025) — check Windows release health before applying registry workarounds: https://learn.microsoft.com/en-us/windows/release-health/status-windows-server-2025
- DC DNS client ordering (partner first, loopback last) is Microsoft guidance, not preference: https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/best-practices-for-dns-client-settings
- `AlwaysExpectDomainController` comes from Microsoft Q&A/community threads, not Learn — document it in the change record as a workaround.
- Deep dive and boot-timing model: `NLADomainProfile-A.md`; collector: `Scripts/Get-NLADomainDetection.ps1`.
