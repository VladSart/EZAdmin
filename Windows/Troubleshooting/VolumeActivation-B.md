# Windows Volume Activation (KMS / ADBA / Subscription Activation) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers `0xC004F074`, `0xC004F038`, `0x8007232B`, `0xC004F06C`, `0xC004F042`, `0xC004C003`, "Windows isn't activated" watermarks on volume-licensed fleets, and Pro→Enterprise subscription step-up that never happens.
> Scope: Windows client + Windows Server OS activation. **Not** Office/M365 Apps (`ospp.vbs`, shared computer activation) and **not** Windows 10 ESU MAK activation (see `ESU-B.md`).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Elevated PowerShell on the **client** that won't activate. Under 60 seconds.

```powershell
# 1. What channel is this box on, and what state is it in?
cscript //nologo $env:windir\system32\slmgr.vbs /dlv | Select-String 'Name|Description|License Status|Error code|KMS machine|registered KMS|Activation interval|Remaining'

# 2. Edition + (for subscription step-up) join state
(Get-CimInstance Win32_OperatingSystem).Caption
dsregcmd /status | Select-String 'AzureAdJoined|DomainJoined|TenantName'

# 3. Can DNS find a KMS host? (domain clients auto-discover via SRV)
Resolve-DnsName -Type SRV "_vlmcs._tcp.$((Get-CimInstance Win32_ComputerSystem).Domain)" -ErrorAction SilentlyContinue |
  Select-Object NameTarget, Port, Priority

# 4. Can we reach it on 1688?
Test-NetConnection <kms-host-fqdn> -Port 1688 | Select-Object ComputerName, TcpTestSucceeded

# 5. Last activation attempts (Application log, source Security-SPP)
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Microsoft-Windows-Security-SPP'; Id=12288,12289,8198} -MaxEvents 10 |
  Format-Table TimeCreated, Id, Message -Wrap
```

| Result | Meaning | Go to |
|---|---|---|
| Description says `RETAIL` or `OEM_DM` channel | Not a volume client at all — KMS/ADBA will never apply | Fix 5 (install GVLK) or treat as retail/OEM |
| Description says `VOLUME_MAK` | MAK-activated; KMS host irrelevant | Re-activate MAK (`slmgr /ato`), or Fix 5 to convert to KMS |
| `VOLUME_KMSCLIENT` + error `0xC004F074` | No KMS host reachable / responded | Fix 1 (DNS) → Fix 2 (port/host) |
| `0x8007232B` "DNS name does not exist" | No `_vlmcs._tcp` SRV record found | Fix 1 |
| `0xC004F038` | Host reached, count below threshold (25 clients / 5 servers) | Fix 3 |
| `0xC004F06C` | Client/host clock skew (> ~4 h) | Fix 2 step time-sync |
| `0xC004F042` | Host key can't activate this product (old CSVLK, e.g. 2016 host vs Win 11/Server 2025 client) | Fix 4 |
| `0xC004C003` | Key blocked/invalid at Microsoft (usually a leaked MAK or wrong host key) | Escalate — licensing |
| Caption says **Pro**, user has E3/E5, no step-up | Subscription Activation path broken | Fix 6 |
| `Remaining Windows grace` counting down on a device that *was* activated | KMS client hasn't renewed within 180 days | Fix 1/2, then `slmgr /ato` |
| Activation ID on host shows `ADBA` / `AD Activation` text in `/dlv` | Activated by Active Directory-Based Activation | Fix 7 if failing |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
KMS path
  Microsoft activation (one-time, by KMS host)
  └── KMS host: CSVLK installed + activated, sppsvc running, Volume Activation Services role (optional)
      ├── CSVLK version >= newest client OS (Server 2025 host key covers Win 10/11 + Server 2025 and older)
      ├── Port TCP 1688 open inbound (firewall rule "Key Management Service")
      ├── SRV _vlmcs._tcp.<domain> published (auto via dynamic DNS, or manual)
      └── Count >= threshold (25 client OS / 5 server OS) — count expires after 30 days of no renewal
          └── KMS client: GVLK installed (channel VOLUME_KMSCLIENT)
              ├── DNS resolves SRV (or /skms / KeyManagementServiceName set)
              ├── Clock within ~4 h of host
              └── Renews every 7 days; must reach host at least once per 180 days

ADBA path (Win 8+/Server 2012+ clients, domain-joined)
  Forest schema >= Server 2012
  └── Activation object in CN=Activation Objects,CN=Microsoft SPP,CN=Services,CN=Configuration,<forest DN>
      └── Client: GVLK + domain-joined + LDAP to DC → activates, re-validates every 180 days (no count threshold)

Subscription Activation (Pro → Enterprise step-up)
  Pro is already genuinely activated (firmware OEM key or retail/MAK)
  └── Device Entra-joined or hybrid-joined (NOT registered/workgroup)
      └── User signed in with Entra account holding Windows Enterprise E3/E5 (per-user)
          └── CA does not block the Store licensing app (Universal Store Service APIs and Web Application)
              └── ClipSVC / licensing token refresh → edition flips to Enterprise
```
</details>

---
## Diagnosis & Validation Flow
1. **Identify the channel.** `slmgr /dlv` → `Description:` line.
   Expected for KMS: `Windows(R) Operating System, VOLUME_KMSCLIENT channel`. Anything else → you're on the wrong runbook branch (see triage table).
2. **Find what host the client is using.** In `/dlv`: `Registered KMS machine name` (manual pin) vs `KMS machine name from DNS`.
   A pinned name pointing to a decommissioned server is the #1 cause of fleet-wide `0xC004F074` after a migration.
3. **Validate DNS.** `Resolve-DnsName -Type SRV _vlmcs._tcp.<domain>` → expected one or more targets on port 1688.
   Bad: nothing (→ `0x8007232B`), or stale targets for old servers.
4. **Validate network.** `Test-NetConnection <host> -Port 1688` → `TcpTestSucceeded : True`.
5. **Validate the host** (on the KMS host):
   ```powershell
   cscript //nologo $env:windir\system32\slmgr.vbs /dlv all | Select-String 'Name|Description|License Status|Current count|Listening on Port|DNS publishing'
   Get-Service sppsvc | Select-Object Status, StartType
   Get-NetFirewallRule -DisplayGroup 'Key Management Service' | Select-Object DisplayName, Enabled, Profile
   ```
   Expected: `VOLUME_KMS_<version>` channel, `Licensed`, `Current count: >= 25` (for clients) or `>= 5` (servers only), port 1688, DNS publishing enabled. `sppsvc` is trigger-start, so `Stopped` alone is normal — it should start on demand.
6. **Validate time.** `w32tm /stripchart /computer:<kms-host> /samples:3 /dataonly` → offsets should be seconds, not hours.
7. **Retry and read the result.** `slmgr /ato` then re-read event 12288 (request sent) / 12289 (response, with the error code) on the client, and 12290 on the host.

---
## Common Fix Paths

<details><summary>Fix 1 — No/stale SRV record (0x8007232B, 0xC004F074)</summary>

```powershell
# On the KMS host: confirm it publishes itself
cscript //nologo $env:windir\system32\slmgr.vbs /cdns       # re-enable DNS publishing if it was turned off

# On a DNS server: inspect and clean stale records
Get-DnsServerResourceRecord -ZoneName <domain> -Name _vlmcs._tcp -RRType Srv
# Remove a record pointing at a decommissioned host
Get-DnsServerResourceRecord -ZoneName <domain> -Name _vlmcs._tcp -RRType Srv |
  Where-Object { $_.RecordData.DomainName -like '<old-host>*' } |
  Remove-DnsServerResourceRecord -ZoneName <domain> -Force
# Add manually if dynamic registration is blocked (secure-only zones, host in a different domain)
Add-DnsServerResourceRecord -Srv -ZoneName <domain> -Name _vlmcs._tcp -DomainName <kms-host-fqdn> -Priority 0 -Weight 0 -Port 1688

# Client: clear any pinned host so DNS auto-discovery is used, then activate
cscript //nologo $env:windir\system32\slmgr.vbs /ckms
cscript //nologo $env:windir\system32\slmgr.vbs /ato
```
Workaround for a single client or a non-domain network: `slmgr /skms <kms-host-fqdn>:1688` then `/ato`.
Rollback: removing an SRV record is safe to re-add with the `Add-DnsServerResourceRecord` line above.
</details>

<details><summary>Fix 2 — Host unreachable / service / clock (0xC004F074, 0xC004F06C)</summary>

```powershell
# On the KMS host
Enable-NetFirewallRule -DisplayGroup 'Key Management Service'
Start-Service sppsvc
cscript //nologo $env:windir\system32\slmgr.vbs /dlv | Select-String 'Listening on Port|License Status'

# Clock skew — on the client (domain member)
w32tm /resync /force
w32tm /query /status | Select-String 'Source|Last Successful'
```
If the client's time source is broken see `Time/TimeSync B.md`. Check the network path for firewalls between VLANs/sites (1688 is often missing from branch/DMZ rules).
</details>

<details><summary>Fix 3 — Count below threshold (0xC004F038)</summary>

KMS only activates once it has seen **25 distinct client OS** machines (or **5 server OS** machines for servers) within 30 days. Small MSP tenants routinely sit under 25.
```powershell
# On the host: current count
cscript //nologo $env:windir\system32\slmgr.vbs /dlv | Select-String 'Current count'
```
Options (pick one):
- Below threshold permanently → **use ADBA** (no threshold, Fix 7) or **MAK** keys for that population.
- Temporarily low (new site build) → the count fills as clients retry; VMs from the same image need unique CMIDs — images must be generalized with `sysprep /generalize` (cloned-without-sysprep VMs share a CMID and count as one).
```powershell
# Check client machine ID (CMID) — duplicates across clients = image not generalized
cscript //nologo $env:windir\system32\slmgr.vbs /dlv | Select-String 'Client Machine ID'
```
</details>

<details><summary>Fix 4 — Host key too old for client (0xC004F042)</summary>

A KMS host's CSVLK only activates OS versions up to its own generation. A host running a **Server 2016/2019 CSVLK** cannot activate Windows Server 2025; Windows 11 needs a host updated with a current CSVLK.
```powershell
# On the host — which CSVLK is installed?
cscript //nologo $env:windir\system32\slmgr.vbs /dlv | Select-String 'Name|Description'
```
Fix: get the newest **Windows Server KMS host key** (e.g. "Windows Srv 2025 DataCtr/Std KMS") from the Microsoft 365 Admin Center → Volume Licensing (or VLSC for legacy agreements), then:
```powershell
cscript //nologo $env:windir\system32\slmgr.vbs /ipk <CSVLK>
cscript //nologo $env:windir\system32\slmgr.vbs /ato
```
The host OS itself must also be recent enough to accept the newer CSVLK (install the CSVLK on a Server 2022/2025 host; older host OS versions may need servicing updates). Rollback: re-`/ipk` the previous CSVLK — keep it recorded.
</details>

<details><summary>Fix 5 — Client has wrong key type (RETAIL/MAK/no key) → convert to KMS client</summary>

```powershell
# Install the edition-matching GVLK (public, from Microsoft's "KMS client activation keys" page), e.g.:
#   Windows 10/11 Enterprise     NPPR9-FWDCX-D2C8J-H872K-2YT43
#   Windows 10/11 Pro            W269N-WFGWX-YVC9B-4J6C9-T83GX
#   Windows Server 2025 Standard TVRH6-WHNXV-R9WG3-9XRFY-MY832
#   Windows Server 2025 DC       D764K-2NDRG-47T6Q-P8T8W-YP6DF
cscript //nologo $env:windir\system32\slmgr.vbs /ipk <GVLK>
cscript //nologo $env:windir\system32\slmgr.vbs /ato
```
Verify GVLKs against the Microsoft page before mass deployment. Rollback: `/ipk` the original retail/MAK key (record it first with `/dlv`; only the last 5 characters are displayed, so you need the source record). Retail **Server** evaluation editions must be converted with `DISM /Online /Set-Edition` first — a GVLK won't install on Eval.
</details>

<details><summary>Fix 6 — Subscription Activation (Pro → Enterprise) not stepping up</summary>

```powershell
# 1. Pro must be genuinely activated first
cscript //nologo $env:windir\system32\slmgr.vbs /dli | Select-String 'Name|License Status'
# 2. Join state must be AzureAdJoined : YES (or hybrid). "WorkplaceJoined" (registered) is not enough
dsregcmd /status | Select-String 'AzureAdJoined|DomainJoined|WorkplaceJoined|AzureAdPrt'
# 3. Licensing event channel
Get-WinEvent -LogName 'Microsoft-Windows-Store/Operational' -MaxEvents 20 -ErrorAction SilentlyContinue |
  Format-Table TimeCreated, Id, Message -Wrap
```
Checklist:
- User (not device) has **Windows Enterprise E3/E5** (directly or via M365 E3/E5). Per-device licensing does **not** drive Subscription Activation.
- Conditional Access: a policy requiring MFA/compliant device on *All cloud apps* blocks the licensing token. Exclude **Universal Store Service APIs and Web Application** (AppId `45a330b1-b1ec-4cc1-9161-9f03992aa49f`) — see `Security/ConditionalAccess`.
- `AzureAdPrt : NO` → fix PRT first (see `EntraID` PRT runbooks); no PRT = no license token.
- Force a refresh: sign out/in, or `Start-Process -FilePath "$env:windir\System32\ClipRenew.exe"` (not present on all builds) and wait up to ~1 h; a reboot is not required for the edition flip.
- If the device was **Enterprise GVLK'd** by a KMS image, it doesn't need step-up — check `/dlv` channel first.
</details>

<details><summary>Fix 7 — ADBA not activating</summary>

```powershell
# Is there an activation object in the forest?
$cfg = (Get-ADRootDSE).configurationNamingContext
Get-ADObject -SearchBase "CN=Activation Objects,CN=Microsoft SPP,CN=Services,$cfg" -Filter * -Properties * |
  Select-Object Name, DisplayName, whenCreated
```
- Empty → create one from a host with the Volume Activation Services role: `Install-WindowsFeature VolumeActivation -IncludeManagementTools`, then Volume Activation Tools → Active Directory-Based Activation → enter the CSVLK. (Or `slmgr /ad-activation-online <CSVLK>` from an elevated prompt as Enterprise Admin.)
- Object exists but older than the client OS → add the newer CSVLK as an additional activation object.
- Client must be domain-joined, Win 8+/Server 2012+, with a GVLK. ADBA falls back to KMS DNS discovery if no object matches.
- Requires **Enterprise Admins** to create (writes to the Configuration partition). Rollback: delete the activation object in ADSI Edit / Volume Activation Tools; clients already activated keep activation until their 180-day revalidation.
</details>

---
## Escalation Evidence
```
Ticket: ______  Client: ______  Site/VLAN: ______
Client OS / build: ______        Edition (Caption): ______
slmgr /dlv Description (channel): ______
License Status: ______           Error code: ______
KMS machine (registered / DNS): ______ / ______
SRV _vlmcs._tcp result: ______
Test-NetConnection <host>:1688: ______
Clock offset vs host (w32tm): ______
Host: CSVLK name ______  Current count ______  License Status ______
ADBA activation objects present: Y/N  (names: ______)
Subscription activation: join state ______  PRT ______  user license ______  CA exclusion present Y/N
Event 12288/12289 excerpt: ______
Get-VolumeActivationHealth.ps1 CSV attached: Y/N
```

---
## 🎓 Learning Pointers
- `slmgr /dlv` is the single most useful command here — the **channel** in the Description line tells you which of three totally different activation systems you're debugging. Docs: https://learn.microsoft.com/windows-server/get-started/activation-slmgr-vbs-options
- Error codes map cleanly to layers (DNS → network → count → key generation); Microsoft's table: https://learn.microsoft.com/windows-server/get-started/activation-error-codes and the dedicated 0xC004F074 article: https://learn.microsoft.com/troubleshoot/windows-server/licensing-and-activation/error-0xc004f074-activate-windows
- Small MSP clients rarely hit the 25-client KMS threshold — ADBA has no threshold and needs no extra server. Overview: https://learn.microsoft.com/windows/deployment/volume-activation/activate-using-active-directory-based-activation-client
- GVLKs are public and edition-specific; the key on the box decides which channel it uses: https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys
- Subscription Activation is a licensing-token flow, not KMS — it fails on identity (join state, PRT, CA), not on network ports: https://learn.microsoft.com/windows/deployment/windows-subscription-activation
- Companion deep dive: `VolumeActivation-A.md`; fleet audit: `Scripts/Get-VolumeActivationHealth.ps1`.
