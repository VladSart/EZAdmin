# RD Gateway (Remote Desktop Gateway / TSGateway) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.
> Covers: "Remote Desktop can't connect to the remote computer because the Remote Desktop Gateway server address is unreachable or incorrect", "...because the Remote Desktop Gateway server's certificate has expired or has been revoked", "...your user account is not authorized to access the RD Gateway" (RD CAP), "...your user account is not listed in the RD Gateway's permission list / can't connect to the remote computer" (RD RAP), Event 201/301/304 failures, NPS/MFA-extension timeouts, UDP 3391 black screens and freezes.
> Deep dive: `RDGateway-A.md` · Script: `../Scripts/Get-RDGatewayDiagnostics.ps1` · Not a gateway problem? → `RDP-B.md` / `RDSLicensing-B.md` / `NPS-RADIUS-B.md`

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run on the **RD Gateway server** (elevated):

```powershell
Get-Service TSGateway, IAS, W3SVC | Select Name, Status, StartType
Import-Module RemoteDesktopServices
Get-Item RDS:\GatewayServer\SSLCertificate\Thumbprint | Select CurrentValue
Get-ChildItem Cert:\LocalMachine\My | Where Thumbprint -eq (Get-Item RDS:\GatewayServer\SSLCertificate\Thumbprint).CurrentValue | Select Subject, NotAfter, @{n='SAN';e={$_.DnsNameList -join ','}}
Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-Gateway/Operational' -MaxEvents 30 | Where Id -in 200,201,300,301,302,303,304,305,306,307,312 | Select TimeCreated, Id, @{n='Msg';e={$_.Message.Substring(0,[Math]::Min(180,$_.Message.Length))}} | Format-Table -Wrap
```

From the **client**: `Test-NetConnection <gateway.fqdn> -Port 443` and browse `https://<gateway.fqdn>/rpc` (expect a credential prompt / 401 — that proves TLS + IIS path are up).

| Result | Meaning | Go to |
|---|---|---|
| `TSGateway` stopped / won't start | Service or IIS/HTTP.sys binding broken | Fix 1 |
| Cert `NotAfter` in past, or SAN doesn't include the FQDN users type | Client refuses TLS → "certificate expired/revoked" or "name mismatch" | Fix 2 |
| Client 443 test fails | Firewall/NAT/WAF/DNS — gateway never reached | Fix 3 |
| No events at all for the user's attempt | Traffic not reaching this server (wrong DNS/LB node) | Fix 3 |
| Event **201** (CAP failure, often error 23003) | User not in any RD CAP group, or NPS denied (incl. MFA-extension reject/timeout) | Fix 4 / Fix 5 |
| Event **301** (RAP failure) | Target host not in any RD RAP computer group, or user typed an alias/IP not in the RAP | Fix 6 |
| Event **304** (CAP+RAP passed but can't reach resource) | Gateway → target TCP 3389 blocked, RDP disabled, or user not in Remote Desktop Users on target | Fix 7 |
| **302** then drops / black screen / frozen after a few seconds | UDP 3391 transport broken (NAT/firewall/MTU) | Fix 8 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
User session on internal RDSH/workstation via RD Gateway
└── Client resolves gateway FQDN (public DNS) and reaches TCP 443 (UDP 3391 optional)
    └── TLS: gateway cert valid, trusted chain, SAN = FQDN typed in client/RDP file, CRL reachable
        └── IIS / HTTP.sys listener + TSGateway service running (RPC-over-HTTP & HTTP transport)
            └── Authentication (NTLM/Kerberos over HTTP; smart card if CAP requires)
                └── RD CAP evaluated by NPS (local or central) → user in allowed group, device redirection rules
                    │   └── [optional] NPS Extension for Entra MFA → RADIUS timeout ≥ 60 s
                    └── RD RAP → target name (exactly as typed) in allowed computer group / "any resource"
                        └── Gateway → target TCP 3389 reachable, DNS resolves internal name
                            └── Target: RDP enabled, user in Remote Desktop Users, NLA OK, licensing OK
```
</details>

---
## Diagnosis & Validation Flow

1. **Is the gateway healthy?**
   `Get-Service TSGateway` → `Running`. `netsh http show sslcert ipport=0.0.0.0:443` → cert hash matches `RDS:\GatewayServer\SSLCertificate\Thumbprint`.
   Mismatch = someone rebound 443 in IIS with a different cert (or renewal updated IIS only) → Fix 2.

2. **Did the attempt reach the gateway?**
   Filter Operational log for the user: `Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-Gateway/Operational'; StartTime=(Get-Date).AddMinutes(-30)} | Where Message -match '<user>'`
   No hits → network/DNS/load-balancer path → Fix 3.

3. **CAP stage.** 200 = authenticated to gateway. 201 = CAP denied. Read the error code in the 201 text.
   For central NPS: check the NPS server's `Security` log for **6273** (denied) and the reason code → `NPS-RADIUS-B.md`.

4. **RAP stage.** 301 = RAP denied. Compare the resource name in the event with RAP group members: `Get-ChildItem RDS:\GatewayServer\RAP` then `Get-Item RDS:\GatewayServer\RAP\<rap>\ComputerGroup`.
   FQDN vs NetBIOS vs IP each need to be permitted if users use them.

5. **Resource stage.** 302 = connected to resource (good). 304 = couldn't. From the gateway: `Test-NetConnection <target> -Port 3389`.

6. **Session stage.** 302 present, user sees black screen/drops → test with UDP disabled on client (Fix 8). 303 = disconnect record (includes bytes & duration — tiny byte counts = session never really rendered).

---
## Common Fix Paths

<details><summary>Fix 1 — TSGateway service / listener broken</summary>

```powershell
Get-Service TSGateway, W3SVC, IAS | Restart-Service -Force
Get-WinEvent -LogName System -MaxEvents 50 | Where ProviderName -match 'TSGateway|HttpEvent|Service Control' | Select TimeCreated, Id, Message -First 10
netsh http show urlacl | Select-String -Pattern 'rpc|remoteDesktopGateway' -Context 0,3
```
If the RPC/HTTP virtual directories were removed (someone "cleaned up" IIS), remove and re-add the role service — config (CAP/RAP) survives if exported first:
```powershell
# Export policies first (RD Gateway Manager > server > Export policy and settings) — GUI only
Uninstall-WindowsFeature RDS-Gateway ; Restart-Computer
Install-WindowsFeature RDS-Gateway -IncludeManagementTools
```
Rollback: re-import the exported XML via RD Gateway Manager > Import policy and settings.
</details>

<details><summary>Fix 2 — Certificate expired / wrong / name mismatch</summary>

```powershell
Import-Module RemoteDesktopServices
$new = Get-ChildItem Cert:\LocalMachine\My | Where { $_.DnsNameList.Unicode -contains '<gateway.fqdn>' -and $_.NotAfter -gt (Get-Date) -and $_.HasPrivateKey } | Sort NotAfter -Desc | Select -First 1
Set-Item RDS:\GatewayServer\SSLCertificate\Thumbprint -Value $new.Thumbprint
Restart-Service TSGateway
```
In a Connection Broker deployment set it centrally instead (keeps RDWeb/Broker/Gateway consistent):
```powershell
Set-RDCertificate -Role RDGateway -Thumbprint $new.Thumbprint -ConnectionBroker <broker.fqdn> -Force
```
Check: SAN must equal what users type **and** what's in the RDP file (`gatewayhostname:s:`). Public CA strongly preferred for unmanaged clients. Rollback: set the old thumbprint back.
</details>

<details><summary>Fix 3 — Gateway unreachable (DNS / firewall / LB)</summary>

- Public DNS A record → correct public IP; `Resolve-DnsName <gateway.fqdn> -Server 8.8.8.8`.
- Perimeter: TCP 443 (+ UDP 3391 if UDP transport used) NAT'd to the gateway (or LB VIP).
- WAF/reverse proxy: must pass `RDG_OUT_DATA` / `RDG_IN_DATA` HTTP methods and long-lived connections — many WAFs block them. Bypass WAF to prove it.
- LB: needs affinity (source IP) — HTTP transport uses two channels that must land on the same node.
</details>

<details><summary>Fix 4 — RD CAP denies user (Event 201)</summary>

```powershell
Import-Module RemoteDesktopServices
Get-ChildItem RDS:\GatewayServer\CAP | ForEach-Object {
  [pscustomobject]@{ CAP=$_.Name; Status=(Get-Item "$($_.PSPath)\Status").CurrentValue;
    Groups=(Get-ChildItem "$($_.PSPath)\UserGroups" | Select -Expand Name) -join ';';
    AuthMethod=(Get-Item "$($_.PSPath)\AuthMethod").CurrentValue } }
Get-ADUser <user> -Properties MemberOf | Select -Expand MemberOf
```
AuthMethod: 1 = password, 2 = smart card, 3 = both. User with password on a smart-card-only CAP = 201.
Add the user to an allowed group (then **log off/on** for token refresh), or add the group:
```powershell
New-Item -Path RDS:\GatewayServer\CAP\<CAPName>\UserGroups -Name '<Group>@<DOMAIN>'
```
If CAPs are stored on **central NPS** (`Get-Item RDS:\GatewayServer\CentralCAPEnabled` = 1), local CAPs are ignored — fix the policy on the NPS server.
</details>

<details><summary>Fix 5 — NPS Extension for Entra MFA: timeouts / denies</summary>

Symptom: 201 after ~30 s, user never got MFA prompt, or got it and still failed.
- Gateway → remote RADIUS server group → **timeout ≥ 60 s** (default 3 s is far too short for phone approval). NPS console > Remote RADIUS Server Groups > server > Load Balancing tab.
- Also RD Gateway **Connection Request Policy** on the gateway must forward to the central NPS (not authenticate locally).
- On the NPS/MFA server: `Get-WinEvent -LogName 'AuthNOptCh' -MaxEvents 20` (Application and Services Logs > Microsoft > AzureMfa > AuthN/AuthZ) for the extension's verdict.
- User must be MFA-registered in Entra; UPN on-prem must match Entra UPN (or configure `LDAP_ALTERNATE_LOGINID_ATTRIBUTE`).
- Cert used by the extension expires after 2 years — rerun `AzureMfaNpsExtnConfigSetup.ps1` to renew.
See `NPS-RADIUS-B.md` for NPS-side reason codes.
</details>

<details><summary>Fix 6 — RD RAP denies resource (Event 301)</summary>

```powershell
Get-ChildItem RDS:\GatewayServer\RAP | ForEach-Object {
  [pscustomobject]@{ RAP=$_.Name; Status=(Get-Item "$($_.PSPath)\Status").CurrentValue;
    ComputerGroupType=(Get-Item "$($_.PSPath)\ComputerGroupType").CurrentValue;
    ComputerGroup=(Get-Item "$($_.PSPath)\ComputerGroup").CurrentValue;
    Port=(Get-Item "$($_.PSPath)\PortNumbers").CurrentValue } }
```
ComputerGroupType: 0 = RD Gateway-managed group, 1 = AD group, 2 = any network resource.
- AD computer group → target computer account must be a member (reboot not needed on gateway, but group changes take a few minutes to replicate).
- Gateway-managed group → add **every alias** users type (FQDN, NetBIOS, IP) in RD Gateway Manager > Resource Authorization Policies > Manage Local Computer Groups.
- Port list must include the target port (default 3389).
</details>

<details><summary>Fix 7 — Passed CAP+RAP, can't reach target (Event 304)</summary>

On the gateway:
```powershell
Test-NetConnection <target.fqdn> -Port 3389
Resolve-DnsName <target.fqdn>
```
On the target:
```powershell
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections   # 0 = enabled
Get-LocalGroupMember 'Remote Desktop Users'
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Select DisplayName, Enabled, Profile
```
Enable if needed: `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0; Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'`. Beyond this it's a target-side problem → `RDP-B.md`.
</details>

<details><summary>Fix 8 — Black screen / freeze / drops (UDP 3391)</summary>

Prove it: on one client, disable UDP transport and retest:
```powershell
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client' -Name fClientDisableUDP -Value 1 -Type DWord
```
If fixed: either open/NAT UDP 3391 properly end-to-end, or disable UDP on the gateway (RD Gateway Manager > Properties > Transport Settings > uncheck "Enable UDP transport") and restart TSGateway.
Rollback (client): `Remove-ItemProperty ... -Name fClientDisableUDP`.
</details>

---
## Escalation Evidence

```
RD GATEWAY ESCALATION
Gateway server(s) / OS build:           ____________
Gateway FQDN users connect to:          ____________
Connection Broker deployment? (Y/N):    ____   Central NPS? (Y/N): ____   Entra MFA NPS ext? (Y/N): ____
Affected user(s) / UPN:                 ____________
Target resource name as typed:          ____________
Client error text (exact):              ____________
Gateway Operational events (ID + time + error code): ____________
NPS Security 6272/6273 (reason code):   ____________
Cert thumbprint / NotAfter / SAN:       ____________
TCP 443 from client: pass/fail  | UDP 3391 open: Y/N/unknown
Gateway -> target 3389: pass/fail
Changes in last 7 days (cert renew, patches, firewall, WAF):   ____________
Attached: Get-RDGatewayDiagnostics.ps1 CSV output
```

---
## 🎓 Learning Pointers
- The event IDs are the whole story: 200→201 = CAP, 301 = RAP, 302/304 = resource, 303 = disconnect. Learn to read the chain before touching config. [RD Gateway Server Connections events](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-r2-and-2008/ee890982(v=ws.10))
- RAP matching is on the **string the user typed**, not the resolved host — "works by FQDN, fails by IP" is almost always RAP, not networking.
- Central NPS makes local CAPs inert. If policy edits on the gateway "do nothing", check `CentralCAPEnabled`. `NPS-RADIUS-A.md` covers the NPS side.
- The 60-second RADIUS timeout is the #1 MFA-on-RDG mistake. [Integrate RD Gateway with NPS extension for Entra MFA](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-mfa-nps-extension-rdg)
- WAFs and "SSL inspection" appliances routinely break the custom `RDG_OUT_DATA` HTTP method — bypass first, then argue with the network team.
- For a modern alternative (no inbound 443 to on-prem), compare Entra Private Access (`GlobalSecureAccess-Windows-A.md`) or AVD RDP Shortpath (`../../Azure/AVD/`).
