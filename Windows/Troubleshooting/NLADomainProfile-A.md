# NLA Domain Network Detection — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** domain-joined Windows 10/11 and Windows Server 2016–2025 (members and DCs) whose interfaces fail to reach the `DomainAuthenticated` network category, and the firewall-profile fallout.
- **Out of scope:** NCSI internet-connectivity verdicts (`NCSI-A.md`), firewall rule precedence/merge (`Firewall-A.md`), Entra-joined-only devices (no AD domain → cannot be DomainAuthenticated; Intune firewall rules should target Private/Public instead).
- Commands assume an elevated Windows PowerShell 5.1 session on the affected host. `<domainFQDN>`, `<DCName>`, `<InterfaceAlias>` are placeholders.

---
## How It Works
<details><summary>Full architecture</summary>

### Two jobs, one service family
Windows network identification answers two separate questions per interface:

| Question | Component | Result |
|---|---|---|
| *Which network is this?* | NLA network identification (NlaSvc, with netprofm / Network List Service) | Category: **DomainAuthenticated / Private / Public** |
| *Can it reach the internet?* | NCSI active/passive probing | Connectivity: Internet / LocalNetwork / NoTraffic |

Only the first drives the firewall profile. A device can be `DomainAuthenticated` with "No Internet", or `Public` with full internet.

On Windows 11 / Server 2022+ more of this logic lives in the Network List Service (`netprofm`); `NlaSvc` still exists and its `Parameters` registry key is still read. Always check both services.

### Domain detection sequence (per interface, on every connect event)
```
Interface gets IP config (DHCP/static, 802.1X done, VPN routes pushed)
        │
        ▼
NLA: is the machine domain-joined?  ── no ──► category = Public (or Private via user/policy)
        │ yes
        ▼
DsGetDcName(<domain/forest>)  ← Netlogon DC locator
   ├─ DNS SRV  _ldap._tcp.dc._msdcs.<domain>  (via this interface's resolvers)
   ├─ LDAP ping (CLDAP, UDP 389) to candidate DC
   └─ result cached by Netlogon — including NEGATIVE results (ERROR_NO_SUCH_DOMAIN)
        │
        ├─ DC reachable via this interface ──► category = DomainAuthenticated
        │                                      network name = domain FQDN
        │                                      signature stored under NetworkList\Signatures\Managed
        └─ fails ──► category = Public/Private, name "Network N" / "Unidentified network"
                     signature under NetworkList\Signatures\Unmanaged
                     NO guaranteed retry until next connect event / service restart
```

The last line is the whole problem in production: NLA evaluates **at connect time**. If the DC path isn't ready at that instant, the interface sits on Public until something triggers re-evaluation (link bounce, DHCP renew with change, service restart). A Netlogon negative-cache entry from the failed attempt can make a quick retry fail too — hence `nltest /dsgetdc:<domain> /force` before re-testing.

### Why domain controllers are the worst case
At boot a DC starts NIC → NLA → … → DNS Server → AD DS (NTDS) → Netlogon SRV registration. If the DC's DNS client points only at itself (or loopback), its own SRV query fails until DNS zones load from AD — by which time NLA has already classified the interface. With a **partner DC first** in the resolver list, the first lookup is answered by a DC that is already up.

Windows Server 2025 had a distinct defect where DCs loaded the standard (non-domain) profile after restart; fixed in **KB5060842** (June 2025 security update, build 26100.4349). On un-patched 2025 DCs the documented interim workaround was `Restart-NetAdapter *` after each boot (scheduled task).

### Multi-homing
Category and firewall profile are **per interface**. `Get-NetFirewallSetting -PolicyStore ActiveStore` can therefore report several active profiles (e.g. `Domain, Public`). A storage, backup, cluster-heartbeat, or Hyper-V internal NIC with no route to a DC will always be Public/Private — this is correct behaviour; scope rules for that interface accordingly.

### Persistence
```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\
├── Profiles\{GUID}         ProfileName, Category (0=Public, 1=Private, 2=Domain), DateLastConnected
└── Signatures\
    ├── Managed\<sig>       domain-identified networks
    └── Unmanaged\<sig>     everything else (gateway MAC + DNS suffix based)
```
`Set-NetConnectionProfile -NetworkCategory` writes Public/Private for an **Unmanaged** network; it cannot create Domain category. Deleting profiles is a blunt reset (see Playbook 6).

### Policy surfaces
- GPO: *Network List Manager Policies* (per-network-name, *Unidentified Networks*, *Identifying Networks*, *All Networks*) set location type and user-changeability for non-domain networks.
- Intune: Firewall policies target profiles (Domain/Private/Public) — a device that never reaches Domain will never get Domain-scoped rules, which is the usual root of "Intune firewall rule doesn't apply on some servers".
</details>

---
## Dependency Stack
```
[7] Business outcome: RDP / WinRM / SMB / agent ports allowed by Domain-profile rules
[6] Windows Firewall per-interface profile = Domain
[5] Interface category = DomainAuthenticated (NetworkList Managed signature)
[4] NLA evaluation succeeded at the connect event (or a later re-evaluation)
[3] DC locator success via THAT interface
      ├─ DNS SRV records resolvable from the interface's resolvers
      ├─ CLDAP UDP 389 + LDAP TCP 389 reachable
      └─ no stale Netlogon negative cache
[2] Timing: link + IP + 802.1X/VPN + (DC: DNS zones/AD DS) ready before evaluation
[1] Services: NlaSvc + netprofm running, Netlogon running; machine PartOfDomain; OS patched (2025: ≥ 26100.4349)
[0] Physical/virtual NIC, VLAN, routing to a DC
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Member server Public after every reboot, fine after adapter bounce | NLA evaluated before NIC team/LACP/802.1X/vNIC ready | NetworkProfile/Operational 10000 timestamps vs System log NIC events |
| DC Public after reboot | DNS client self-only; Server 2025 bug; single-DC site | `Get-DnsClientServerAddress`; build/UBR |
| All machines on one VLAN Public | DHCP hands out non-AD DNS (router/ISP); UDP 389 blocked on inter-VLAN ACL | `Resolve-DnsName -Type SRV _ldap._tcp.dc._msdcs.<domain>`; `nltest /dsgetdc` |
| Secondary NIC "Unidentified network" Public | Storage/heartbeat NIC with no DC path | `Get-NetConnectionProfile`; route table |
| Laptop Public on corporate Wi-Fi only | DNS from guest SSID / captive portal VLAN; 802.1X late | DNS servers on Wi-Fi interface |
| Laptop DomainAuthenticated in office, never on VPN | User tunnel only, no internal DNS pushed, or NLA not re-run after connect | VPN interface DNS; Always On VPN device tunnel |
| Category never changes, services Stopped | Debloat/hardening script disabled NlaSvc/netprofm | `Get-Service NlaSvc,netprofm` |
| `Set-NetConnectionProfile ... DomainAuthenticated` errors | Not a settable value | Use Public/Private only |
| Intune/GPO Domain-profile firewall rules missing on some servers | Those servers never reach Domain category | `Get-NetFirewallSetting -PolicyStore ActiveStore` |
| Firewall "Public" and SMB/RDP blocked right after a CU | NLA restart during servicing re-classified before DC path ready | Restart NlaSvc; check 10000 events at boot |

---
## Validation Steps
1. **Join state** — `Get-CimInstance Win32_ComputerSystem | Select Domain, PartOfDomain, DomainRole`
   Good: `PartOfDomain True`. Bad: `False` → domain category impossible; stop here.
2. **Services** — `Get-Service NlaSvc, netprofm, Netlogon | Select Name, Status, StartType`
   Good: all Running, Automatic (NlaSvc may be Automatic (Delayed) after remediation). Bad: Disabled/Stopped.
3. **Category per interface** — `Get-NetConnectionProfile`
   Good: LAN `NetworkCategory DomainAuthenticated`, `Name <domainFQDN>`. Bad: `Public`/`Private`.
4. **Firewall active profile** — `(Get-NetFirewallSetting -PolicyStore ActiveStore).ActiveProfile`
   Good: `Domain`. Bad: includes `Public` on an interface that should be domain.
5. **DC locator** — `nltest /dsgetdc:<domainFQDN> /force`
   Good: returns DC, `Flags: ... LDAP DS ...`. Bad: `ERROR_NO_SUCH_DOMAIN`.
6. **SRV records** — `Resolve-DnsName -Type SRV _ldap._tcp.dc._msdcs.<domainFQDN>`
   Good: SRV records for each DC. Bad: NXDOMAIN → wrong resolvers or missing registrations.
7. **Reachability** — `Test-NetConnection <DCName> -Port 389` Good: `True`. (Firewall team must confirm UDP 389 separately.)
8. **Boot timeline** — `Get-WinEvent -LogName 'Microsoft-Windows-NetworkProfile/Operational' -MaxEvents 30`
   Good: 10000 at boot with category Domain. Bad: 10000 with Public and no later Domain event.
9. **OS build** — `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion') | Select CurrentBuild, UBR`
   Server 2025 DC: build 26100 needs UBR ≥ 4349.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Is it really a domain-detection problem?
- Confirm `PartOfDomain`. Confirm the interface in question *should* reach a DC (not a storage/DMZ NIC).
- Distinguish from NCSI: "No Internet" with category DomainAuthenticated is an NCSI problem → `NCSI-A.md`.

### Phase 2 — Can the machine find a DC *now*?
- `nltest /dsgetdc /force`, SRV lookup, TCP 389. If these fail now, it's DNS/network, not timing. Fix resolvers (Playbook 4) or escalate network path (UDP/TCP 389, 53, 88).

### Phase 3 — It works now, but not at boot/connect (timing)
- Compare NetworkProfile 10000 timestamps with System-log NIC link-up, DHCP, 802.1X (Wired-AutoConfig/WLAN-AutoConfig) and, on DCs, DNS Server event 4 (zones loaded) and NTDS readiness.
- Members: Playbook 2. DCs: Playbook 3.

### Phase 4 — Multi-homed or VPN
- Map each interface to its expected category. Accept Public on non-DC-path NICs; scope rules (Playbook 5).
- VPN: verify tunnel pushes internal DNS + suffix; device tunnel for pre-logon domain category (`AlwaysOnVPN-A.md`).

### Phase 5 — Persistence / corruption
- If one specific network flips oddly or is stuck with a wrong name across reboots, inspect `NetworkList\Profiles` and consider Playbook 6.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Immediate re-detection</summary>

```powershell
nltest /dsgetdc:<domainFQDN> /force
Restart-Service NlaSvc -Force
Start-Sleep 10
Get-NetConnectionProfile | Format-Table InterfaceAlias, Name, NetworkCategory
```
If `Restart-Service` hangs (reported on Server 2022), use `Restart-NetAdapter -Name "<InterfaceAlias>"` from console/out-of-band only.
</details>

<details><summary>Playbook 2 — Member server timing (delayed start + retry)</summary>

```powershell
$p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters'
# Capture current state for rollback
$before = [pscustomobject]@{
  Start = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc').Start
  DelayedAutostart = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc' -ErrorAction SilentlyContinue).DelayedAutostart
  AEDC = (Get-ItemProperty $p -ErrorAction SilentlyContinue).AlwaysExpectDomainController
}
$before | Export-Clixml "$env:TEMP\nlasvc-before.xml"

sc.exe config NlaSvc start= delayed-auto
New-Item $p -Force | Out-Null
New-ItemProperty $p -Name AlwaysExpectDomainController -PropertyType DWord -Value 1 -Force | Out-Null
Restart-Service NlaSvc -Force
```
Status: `AlwaysExpectDomainController` is sourced from Microsoft Q&A and vendor KBs (e.g. Dell PowerEdge KB 000207835), **not** Microsoft Learn. Pilot first; record as a workaround.

**Rollback:**
```powershell
sc.exe config NlaSvc start= auto
Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters' -Name AlwaysExpectDomainController -ErrorAction SilentlyContinue
```
Last resort: startup scheduled task (SYSTEM, delay 2 min) → `powershell.exe -NoProfile -Command "Restart-Service NlaSvc -Force"`.
</details>

<details><summary>Playbook 3 — Domain controllers</summary>

1. Patch: Server 2025 → latest CU (≥ KB5060842).
2. DNS client order: partner DC → self IP → `127.0.0.1`.
   ```powershell
   Get-DnsClientServerAddress -InterfaceAlias "<InterfaceAlias>" -AddressFamily IPv4 | Export-Clixml "$env:TEMP\dc-dns-before.xml"
   Set-DnsClientServerAddress -InterfaceAlias "<InterfaceAlias>" -ServerAddresses <partnerDC_IP>,<thisDC_IP>,127.0.0.1
   ```
   Rollback: `Set-DnsClientServerAddress -InterfaceAlias "<InterfaceAlias>" -ServerAddresses (Import-Clixml "$env:TEMP\dc-dns-before.xml").ServerAddresses`
3. Apply Playbook 2.
4. Optional (community): add `DNS` to NlaSvc's `DependOnService` so NLA starts after the DNS Server service. This changes service start order — capture the existing value first (`(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc').DependOnService`), and prefer steps 1–3. Service "started" ≠ zones loaded, so this alone is not reliable.
</details>

<details><summary>Playbook 4 — DNS / DC-locator failures</summary>

```powershell
Set-DnsClientServerAddress -InterfaceAlias "<InterfaceAlias>" -ServerAddresses <DC1_IP>,<DC2_IP>
Clear-DnsClientCache
nltest /dsgetdc:<domainFQDN> /force
Restart-Service NlaSvc -Force
```
DHCP clients: correct scope option 006. Missing SRV: on a DC `Restart-Service Netlogon`, `dcdiag /test:dns /v`, see `ActiveDirectory/Troubleshooting/DNS/AD-DNS-A.md`. Also review `DNS-Client-A.md` for suffix/search-list issues.
</details>

<details><summary>Playbook 5 — Multi-homed classification</summary>

- GPO: *Network List Manager Policies → Unidentified Networks → Location type = Private*, *User permissions = User cannot change location*.
- Per-host: `Set-NetConnectionProfile -InterfaceAlias "<InterfaceAlias>" -NetworkCategory Private` (rollback: `-NetworkCategory Public`).
- Firewall: scope rules with `-InterfaceAlias` / `-InterfaceType` rather than widening Domain rules to Public globally.
- Cluster/heartbeat NICs: keep DNS registration off (`Set-DnsClient -InterfaceAlias "<InterfaceAlias>" -RegisterThisConnectionsAddress $false`).
</details>

<details><summary>Playbook 6 — Reset stored network profiles (destructive)</summary>

Use only when a specific network is mis-identified persistently and Playbooks 1–4 are proven not to apply. Removes **all** remembered networks on the host (names, categories); Wi-Fi profiles are separate and not touched.
```powershell
$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList'
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList" "$env:TEMP\NetworkList-backup.reg" /y
Get-ChildItem "$base\Profiles" | Remove-Item -Recurse -Force
Get-ChildItem "$base\Signatures\Managed","$base\Signatures\Unmanaged" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Restart-Service NlaSvc -Force
```
**Rollback:** `reg import "$env:TEMP\NetworkList-backup.reg"` then `Restart-Service NlaSvc -Force`. Do this from console/out-of-band — interfaces are re-identified and the firewall profile may change mid-session.
</details>

---
## Evidence Pack
```powershell
# Run elevated. Collects NLA/domain-detection evidence to a zip in %TEMP%.
$Out = Join-Path $env:TEMP ("NLA-Evidence-{0}-{1:yyyyMMdd-HHmm}" -f $env:COMPUTERNAME, (Get-Date))
New-Item -ItemType Directory -Path $Out -Force | Out-Null
$cs = Get-CimInstance Win32_ComputerSystem
$cs | Select-Object Name, Domain, PartOfDomain, DomainRole | Out-File "$Out\computersystem.txt"
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object ProductName, CurrentBuild, UBR | Out-File "$Out\os.txt"
Get-Service NlaSvc, netprofm, Netlogon, Dnscache | Select-Object Name, Status, StartType | Out-File "$Out\services.txt"
Get-NetConnectionProfile | Format-List * | Out-File "$Out\connectionprofiles.txt"
Get-NetFirewallSetting -PolicyStore ActiveStore | Format-List * | Out-File "$Out\firewall-active.txt"
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction | Out-File "$Out\firewall-profiles.txt"
Get-DnsClientServerAddress -AddressFamily IPv4 | Out-File "$Out\dns-servers.txt"
Get-DnsClient | Select-Object InterfaceAlias, ConnectionSpecificSuffix, RegisterThisConnectionsAddress | Out-File "$Out\dns-client.txt"
Get-NetIPConfiguration -Detailed | Out-File "$Out\ipconfig.txt"
Get-NetRoute -AddressFamily IPv4 | Out-File "$Out\routes.txt"
if ($cs.PartOfDomain) {
  & nltest.exe /dsgetdc:$($cs.Domain) /force *> "$Out\nltest-dsgetdc.txt"
  Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$($cs.Domain)" -ErrorAction SilentlyContinue | Out-File "$Out\srv.txt"
}
reg export "HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc" "$Out\nlasvc-service.reg" /y | Out-Null
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList" "$Out\networklist.reg" /y | Out-Null
Get-WinEvent -LogName 'Microsoft-Windows-NetworkProfile/Operational' -MaxEvents 100 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Export-Csv "$Out\networkprofile-events.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddDays(-2)} -MaxEvents 300 -ErrorAction SilentlyContinue |
  Where-Object { $_.ProviderName -match 'Tcpip|Dhcp|NETLOGON|e1|Ndis|Service Control Manager' } |
  Select-Object TimeCreated, ProviderName, Id, Message | Export-Csv "$Out\system-network-events.csv" -NoTypeInformation
Compress-Archive -Path "$Out\*" -DestinationPath "$Out.zip" -Force
Write-Host "Evidence: $Out.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Category per interface | `Get-NetConnectionProfile` |
| Active firewall profile(s) | `(Get-NetFirewallSetting -PolicyStore ActiveStore).ActiveProfile` |
| Join state / DC role | `Get-CimInstance Win32_ComputerSystem \| Select Domain,PartOfDomain,DomainRole` |
| DC locator (bypass cache) | `nltest /dsgetdc:<domainFQDN> /force` |
| SRV records | `Resolve-DnsName -Type SRV _ldap._tcp.dc._msdcs.<domainFQDN>` |
| TCP 389 to DC | `Test-NetConnection <DCName> -Port 389` |
| Resolvers per NIC | `Get-DnsClientServerAddress -AddressFamily IPv4` |
| Re-run detection | `Restart-Service NlaSvc -Force` |
| Bounce one NIC (console only) | `Restart-NetAdapter -Name "<InterfaceAlias>"` |
| Delayed start NLA | `sc.exe config NlaSvc start= delayed-auto` |
| Retry workaround flag | `New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters' -Name AlwaysExpectDomainController -PropertyType DWord -Value 1 -Force` |
| Set non-domain category | `Set-NetConnectionProfile -InterfaceAlias "<InterfaceAlias>" -NetworkCategory Private` |
| Boot classification events | `Get-WinEvent -LogName 'Microsoft-Windows-NetworkProfile/Operational' -MaxEvents 20` |
| Stored profiles | `Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles' \| Get-ItemProperty \| Select ProfileName,Category` |
| Full collector | `.\Get-NLADomainDetection.ps1 -OutputPath C:\Temp` |

---
## 🎓 Learning Pointers
- Domain detection is a DC-locator problem wearing a firewall costume — learn the locator flow (SRV → CLDAP ping → site) and most NLA tickets resolve themselves: https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/dc-locator
- Firewall profiles are per-interface; reading `ActiveProfile` as a single value hides multi-homed problems: https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules
- DC resolver ordering (partner first, loopback last) is the single most effective DC-side fix and is Microsoft guidance: https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/best-practices-for-dns-client-settings
- Check Windows release health before reaching for registry workarounds — the Server 2025 DC profile bug was a code defect fixed in KB5060842: https://learn.microsoft.com/en-us/windows/release-health/status-windows-server-2025
- `AlwaysExpectDomainController` and the `DependOnService` tweak are field workarounds (Microsoft Q&A, Dell KB 000207835) — keep them in change records so they can be removed once root cause is fixed.
- Related: `NCSI-A.md` (connectivity verdict, same service family), `Firewall-A.md` (what the profile then enables), `AlwaysOnVPN-A.md` (device tunnel for pre-logon domain category).
