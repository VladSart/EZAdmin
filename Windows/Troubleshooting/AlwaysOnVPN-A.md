# Always On VPN — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Always On VPN with IKEv2 and/or SSTP tunnels
- Device Tunnel (machine certificate, pre-logon) and User Tunnel (EAP or certificate, post-logon)
- Deployments managed via Microsoft Intune (ProfileXML via OMA-URI or VPN configuration profile)
- Windows 10 1607+ and Windows 11 clients
- RRAS-based gateways (Windows Server 2016/2019/2022)

**Out of scope:**
- DirectAccess (predecessor — separate runbook)
- Third-party VPN gateway appliances (Palo Alto, Cisco, Fortinet)
- Azure VPN Gateway (P2S scenarios)
- Per-App VPN (separate profile type, different debug path)
- NPS/RADIUS server administration and configuration in general (RADIUS client registration, connection
  request/network policy authoring, the NPS Extension for Entra MFA's own health) — this runbook covers
  NPS only as it appears from the VPN client/RRAS side; for the NPS server's own dedicated troubleshooting
  see `Windows/Troubleshooting/NPS-RADIUS-A.md`/`-B.md`

**Assumptions:**
- You have local admin or Intune remediation script access to the affected Windows client
- You have access to the RRAS server and NPS server logs
- Intune enrollment is confirmed before checking VPN-specific issues

---
## How It Works

<details><summary>Full architecture — tunnels, protocols, and authentication flow</summary>

### Always On VPN: Two Tunnels, Two Purposes

Always On VPN is fundamentally different from traditional VPN in that it maintains two separate, complementary tunnels:

```
Windows Client (Domain-Joined or Entra-Joined)
  │
  ├── Device Tunnel (pre-logon)
  │     Protocol: IKEv2 only
  │     Auth: Machine certificate (from PKCS/SCEP profile in Intune)
  │     When: Before user login — connects at Windows startup
  │     What it enables: DC connectivity, Group Policy, Intune MDM, remote management
  │     Configured as: AllUserConnection
  │     WMI Path: MDM_VPNv2_01 where InstanceID = "DeviceTunnel"
  │
  └── User Tunnel (post-logon)
        Protocol: IKEv2 or SSTP
        Auth: User certificate (EAP-TLS) or username/password (EAP-MSCHAPv2 / PEAP)
        When: After user login — auto-triggers via Always On trigger
        What it enables: User resource access, application access, internet (if full-tunnel)
        Configured as: Per-user connection (CurrentUser) or AllUserConnection
        WMI Path: MDM_VPNv2_01 where InstanceID = "UserTunnel"
```

### IKEv2 Connection Flow (step by step)

```
1. Client resolves VPN gateway FQDN → DNS lookup
2. Client sends IKE_SA_INIT → negotiate crypto (cipher suites, DH group)
3. Server responds with IKE_SA_INIT → crypto agreed
4. Client sends IKE_AUTH → includes certificate or EAP identity
5. Server validates client cert against its trusted CA list
6. Server (or NPS via RADIUS) validates client identity
7. CHILD_SA established → tunnel keys negotiated
8. IP address assigned to client (from RRAS IP pool or DHCP)
9. Routes pushed to client (split or full tunnel, per ProfileXML)
10. DNS suffix search list pushed to client
11. Tunnel marked "Connected"
```

### SSTP Connection Flow

SSTP runs over HTTPS (TCP 443), making it firewall-friendly:
```
1. TCP handshake to gateway on port 443
2. TLS session established (gateway cert validated by client)
3. SSTP handshake over TLS
4. PPP negotiation (LCP → authentication phase)
5. EAP or MSCHAPv2 authentication
6. IPCP → IP address assigned
7. Tunnel established over HTTPS
```

### ProfileXML: The Configuration Core

Every Always On VPN configuration lives in a single XML document called the **ProfileXML**. This XML is stored in WMI via the MDM (OMA-DM) bridge:

```
WMI Namespace: root\cimv2\mdm\dmmap
Class: MDM_VPNv2_01
Instance: <ProfileName>
Property: ProfileXML
```

Key ProfileXML sections:
```xml
<VPNProfile>
  <!-- Where to connect -->
  <NativeProfile>
    <Servers>vpn.contoso.com</Servers>
    <NativeProtocolType>IKEv2</NativeProtocolType>
    <Authentication>
      <MachineMethod>Certificate</MachineMethod>  <!-- Device Tunnel -->
      <!-- OR -->
      <UserMethod>Eap</UserMethod>  <!-- User Tunnel -->
    </Authentication>
  </NativeProfile>

  <!-- Always On behaviour -->
  <AlwaysOn>true</AlwaysOn>
  <RememberCredentials>true</RememberCredentials>
  <TrustedNetworkDetection>contoso.com</TrustedNetworkDetection>  <!-- Don't connect on corpnet -->

  <!-- DNS behaviour -->
  <DomainNameInformationList>
    <DomainNameInformation>
      <DomainName>.contoso.local</DomainName>
      <DnsServers>10.0.0.10,10.0.0.11</DnsServers>
    </DomainNameInformation>
  </DomainNameInformationList>

  <!-- Routing (split tunnel) -->
  <Route>
    <Address>10.0.0.0</Address>
    <PrefixSize>8</PrefixSize>
  </Route>

  <!-- Proxy, traffic filters, etc. -->
</VPNProfile>
```

### RasMan and IKEEXT: The Service Layer

- **RasMan (Remote Access Connection Manager):** Manages all dial-up/VPN connections. Owns the connection lifecycle — creation, authentication handoff, teardown.
- **IKEEXT (IKE and AuthIP IPsec Keying Modules):** Handles the IKEv2 key exchange and IPsec SA negotiation. Required for IKEv2 tunnels.
- **RasAuto (Remote Access Auto Connection Manager):** Handles automatic connection triggers (AlwaysOn, application-triggered).
- **BFE (Base Filtering Engine):** Windows kernel networking component. IKEEXT depends on it being running.

### NPS (RADIUS) Authentication Flow

When NPS/RADIUS is used for user tunnel authentication:
```
Client → RRAS Gateway (RADIUS client) → NPS Server (RADIUS server)
                                               │
                                               ├── Check Network Policy (conditions + constraints)
                                               ├── Check group membership
                                               ├── Validate client certificate (if EAP-TLS)
                                               └── Grant/Deny → RRAS relays result to client
```

NPS event IDs to know:
- **6272:** Access Granted
- **6273:** Access Denied (includes reason code — this is the key diagnostic event)
- **6274:** Discarded (client sent request but NPS policy ignored it)

</details>

---
## Dependency Stack

```
Physical/Wireless Network Layer
        │
        ▼
Internet Connectivity (client can reach external DNS, gateway FQDN resolves)
        │
        ▼
VPN Gateway (RRAS on Windows Server or equivalent)
  ├── IKEv2: UDP 500 (initial), UDP 4500 (NAT-T) reachable from client
  └── SSTP: TCP 443 reachable from client, gateway TLS cert valid
        │
        ▼
Windows Services (on client)
  ├── BFE (Base Filtering Engine) — must run first
  ├── IKEEXT — IKEv2 key exchange (depends on BFE)
  ├── RasMan — connection management (depends on IKEEXT)
  └── RasAuto — auto-trigger (depends on RasMan)
        │
        ▼
WAN Miniport Adapters (IKEv2, IP, IPv6, SSTP)
  [Must be present, not in error state in Device Manager]
        │
        ▼
Certificates
  ├── Device Tunnel: machine cert in LocalMachine\My, valid, issued by org CA
  ├── User Tunnel: user cert in CurrentUser\My (if EAP-TLS), valid
  └── Gateway cert: trusted by client (root CA in LocalMachine\Root)
        │
        ▼
ProfileXML (in WMI via MDM bridge)
  ├── Correct ServerURL / Servers value
  ├── Correct authentication method matching gateway config
  ├── AlwaysOn = true
  └── DomainNameInformationList with correct internal DNS servers
        │
        ▼
NPS/RADIUS (if deployed)
  ├── RRAS has correct RADIUS shared secret for NPS server
  ├── NPS Network Policy matches client (certificate conditions, group membership)
  └── NPS Connection Request Policy routes to correct server
        │
        ▼
Tunnel Connected → Routes and DNS pushed to client
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Key Check |
|---|---|---|
| VPN adapter missing from Device Manager | WAN Miniport driver issue; OS corruption | `Get-NetAdapter \| Where-Object { $_.InterfaceDescription -like "*Miniport*" }` |
| Error 13868 — IKEv2 auth failure | Machine/user cert missing or expired; CA not trusted on gateway; NPS policy mismatch | Check cert store; NPS event 6273 |
| Error 809 — IKEv2 blocked by firewall | UDP 500/4500 blocked between client and gateway; NAT-T not enabled | `Test-NetConnection <gw> -Port 500` (UDP unreachable via TCP test — check with PSping) |
| Error 691 — Auth failed (PPP layer) | Wrong credentials; NPS policy denies user; EAP method mismatch | NPS event 6273 on NPS server |
| Error 812 — NPS policy violation | Client cert not in expected AD group; certificate EKU mismatch | NPS event 6273, check policy conditions |
| Error 853 — IKEv2 negotiation failed | Cipher suite mismatch between client and gateway | Check RRAS IKEv2 cipher config; check client's `CustomCryptography` in ProfileXML |
| VPN connects but internal DNS fails | DomainNameInformationList missing or wrong DNS servers | Check ProfileXML DNS section; `Resolve-DnsName` via VPN interface |
| VPN connects but specific subnets unreachable | Split tunnel route missing in ProfileXML | Check `<Route>` entries in ProfileXML; `Get-NetRoute` while connected |
| Device tunnel connects, user tunnel doesn't | User cert missing; user tunnel profile not deployed to user context; trigger not firing | Check `Get-VpnConnection` (non -AllUserConnection); check cert in CurrentUser\My |
| Profile not appearing after Intune push | Intune policy not applied yet; OMA-URI error; WMI bridge issue | Check Intune device compliance; MDM diagnostic log |
| Profile appears but "Disconnected" repeatedly | TrustedNetworkDetection matches current network (intentional — on corpnet); or auth failing | Check TND config; check VPN-Client/Operational events |
| VPN connects on Wi-Fi but not Ethernet | Specific firewall or QoS rule on wired path; NAT-T asymmetry | Test both paths; check port 500/4500 on wired path |
| RasMan fails to start | Dependency service (BFE, IKEEXT) not started; WAN Miniport driver missing | Check service dependencies; `sfc /scannow` |

---
## Validation Steps

**Step 1 — Confirm VPN profile exists and is correctly configured**
```powershell
# AllUserConnection (Device Tunnel and some User Tunnels)
Get-VpnConnection -AllUserConnection | Select-Object Name, ServerAddress, TunnelType,
    AuthenticationMethod, ConnectionStatus, AllUserConnection

# Per-user (User Tunnel)
Get-VpnConnection | Select-Object Name, ServerAddress, TunnelType,
    AuthenticationMethod, ConnectionStatus
```
Expected: profile(s) present with correct `ServerAddress`, `TunnelType` (IKEv2 or Automatic), correct `AuthenticationMethod`.

**Step 2 — Confirm WAN Miniport adapters are present**
```powershell
Get-NetAdapter | Where-Object {
    $_.InterfaceDescription -like "*WAN Miniport*"
} | Select-Object Name, Status, InterfaceDescription
```
Expected: IKEv2, IP, IPv6, Network Monitor, PPPOE, PPTP, SSTP adapters — all with a status of `Disconnected` (normal when not connected) rather than `Not Present` or error.
Bad: Any adapter showing `Not Present` — reinstall WAN Miniport drivers.

**Step 3 — Confirm required services are running**
```powershell
Get-Service BFE, IKEEXT, RasMan, RasAuto | Select-Object Name, Status, StartType
```
Expected: All `Running`, `Automatic`.

**Step 4 — Validate machine certificate (Device Tunnel)**
```powershell
Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication" -and
    $_.NotAfter -gt (Get-Date)
} | Select-Object Subject, Issuer, Thumbprint, NotAfter
```
Expected: at least one valid cert issued by your internal CA with Client Authentication EKU, not expired.

**Step 5 — Validate user certificate (User Tunnel with EAP-TLS)**
```powershell
Get-ChildItem Cert:\CurrentUser\My | Where-Object {
    $_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication" -and
    $_.NotAfter -gt (Get-Date)
} | Select-Object Subject, Issuer, Thumbprint, NotAfter
```

**Step 6 — Validate gateway's CA is trusted by client**
```powershell
# The gateway cert must chain to a CA in the client's trusted root store
Get-ChildItem Cert:\LocalMachine\Root | Where-Object {
    $_.Subject -like "*<your-internal-CA>*"
} | Select-Object Subject, Thumbprint, NotAfter
```

**Step 7 — Test gateway reachability**
```powershell
$gatewayFQDN = "<vpn-gateway.contoso.com>"
# TCP 443 (SSTP)
Test-NetConnection -ComputerName $gatewayFQDN -Port 443 -WarningAction SilentlyContinue |
    Select-Object ComputerName, RemotePort, TcpTestSucceeded, PingSucceeded

# DNS resolution
Resolve-DnsName $gatewayFQDN | Select-Object Name, IPAddress, Type
```

**Step 8 — Read live ProfileXML from WMI**
```powershell
$profiles = Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_VPNv2_01
foreach ($p in $profiles) {
    Write-Host "`n=== Profile: $($p.InstanceID) ===" -ForegroundColor Cyan
    [xml]$xml = $p.ProfileXML
    Write-Host "Server: $($xml.VPNProfile.NativeProfile.Servers)"
    Write-Host "Protocol: $($xml.VPNProfile.NativeProfile.NativeProtocolType)"
    Write-Host "AlwaysOn: $($xml.VPNProfile.AlwaysOn)"
    Write-Host "TrustedNetworkDetection: $($xml.VPNProfile.TrustedNetworkDetection)"
}
```

**Step 9 — Check recent VPN connection events**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-VPN-Client/Operational" -MaxEvents 30 |
    Select-Object TimeCreated, Id, Message | Format-List
```
Key event IDs:
- **20221:** User tunnel authentication successful
- **20222:** Device tunnel connected
- **20225:** Tunnel disconnected (note reason code)
- **20227:** Connection failed (note error code)

---
## Troubleshooting Steps (by phase)

### Phase 1 — Profile Delivery (Intune)

Profile not arriving on device:
1. Check Intune device check-in: Settings → Accounts → Access work or school → Info → Sync
2. Check MDM enrollment status: `dsregcmd /status` → look for `MdmEnrollmentState`
3. Check Intune Management Extension logs: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\`
4. In Intune portal: Devices → [device] → Device configuration → verify VPN profile shows "Succeeded"
5. If OMA-URI: verify the URI matches exactly `./Device/Vendor/MSFT/VPNv2/<ProfileName>/ProfileXML` for Device Tunnel or `./User/Vendor/MSFT/VPNv2/<ProfileName>/ProfileXML` for User Tunnel
6. Check WMI bridge received the payload: `Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_VPNv2_01`

### Phase 2 — Service and Driver Layer

Profile exists but tunnel won't initiate:
1. Check service dependencies in order: BFE → IKEEXT → RasMan → RasAuto
2. If BFE fails: check Windows Firewall service; BFE is a core kernel component — failure suggests OS corruption → run `sfc /scannow` and `DISM /Online /Cleanup-Image /RestoreHealth`
3. If WAN Miniport adapters missing: Device Manager → View → Show hidden devices → Network adapters → look for WAN Miniport entries with error icons
4. Reinstall WAN Miniport if corrupted: `devmgmt.msc` → right-click failing miniport → Uninstall device → Scan for hardware changes (Windows reinstalls automatically)

### Phase 3 — Certificate Issues

Connection initiates but authentication fails (13868, 691, 812):
1. Verify cert is in the correct store (LocalMachine\My for Device Tunnel, CurrentUser\My for User Tunnel)
2. Check cert expiry: `Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.NotAfter -lt (Get-Date).AddDays(30) }`
3. Verify cert EKU includes Client Authentication (OID 1.3.6.1.5.5.7.3.2)
4. Verify the issuing CA's root cert is in LocalMachine\Root (trusted by both client and gateway)
5. Check cert revocation: `certutil -verify -urlfetch <path-to-cert.cer>` — CRL or OCSP must be reachable from both client AND gateway
6. On gateway/NPS: verify the gateway's own certificate has Server Authentication EKU and is not expired

### Phase 4 — Network Path Issues

Certificate valid but IKEv2 fails with error 809 or timeout:
1. UDP 500 and 4500 cannot be tested with `Test-NetConnection` (TCP only). Use PSping: `psping -u <gateway-fqdn>:500`
2. Check for NAT between client and gateway: if NAT exists, IKEv2 must use NAT-T (UDP 4500). Verify `AssumeUDPEncapsulationContextOnSendRule = 2` in registry
3. If UDP is blocked (hotel, restrictive corporate guest Wi-Fi): switch VPN profile to SSTP as protocol. SSTP uses TCP 443 and passes through most proxies
4. Check for HTTPS inspection breaking SSTP: some proxy/DPI solutions terminate and re-inspect HTTPS. SSTP requires end-to-end TLS to the gateway — SSL inspection on port 443 will break it
5. Verify gateway's external firewall allows inbound UDP 500/4500 from any source (if IKEv2) or TCP 443 (if SSTP)

### Phase 5 — NPS Authentication Failures

IKEv2 SA establishes but user auth fails (691, 812):
1. SSH/RDP to NPS server; check Event Viewer → Custom Views → Network Policy and Access Services
2. Event 6273 tells you exactly why access was denied — read the "Reason" field
3. Common 6273 reason codes:
   - **16 (Authentication Failed):** Wrong password, locked account, cert not trusted by NPS, or expired user cert
   - **48 (Group Membership Mismatch):** User not in the AD group specified in NPS network policy conditions
   - **65 (Certificate Not Accepted):** NPS doesn't trust the client cert's issuing CA
4. On NPS, verify the RADIUS shared secret matches what RRAS has configured for that NPS server
5. Verify NPS network policy conditions match the client (certificate subject, group membership, machine health)
6. If using EAP-TLS: NPS requires the issuing CA cert to be in NPS server's trusted root store (not just the client's)

---
## Remediation Playbooks

<details><summary>Playbook 1 — Rebuild ProfileXML and re-deploy via PowerShell (break-glass)</summary>

**Scenario:** ProfileXML is corrupt or malformed after a failed Intune push. Need to immediately restore VPN on a specific device without waiting for Intune policy cycle.

**Step 1 — Remove existing broken profile**
```powershell
$profileName = "<YourVPNProfileName>"

# Remove all-user variant
Remove-VpnConnection -Name $profileName -AllUserConnection -Force -ErrorAction SilentlyContinue
# Remove per-user variant
Remove-VpnConnection -Name $profileName -Force -ErrorAction SilentlyContinue

# Also clean WMI directly
$existingProfiles = Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_VPNv2_01 |
    Where-Object { $_.InstanceID -like "*$profileName*" }
foreach ($p in $existingProfiles) {
    Remove-CimInstance -InputObject $p
    Write-Host "Removed WMI profile: $($p.InstanceID)"
}
```

**Step 2 — Build a fresh ProfileXML**
```powershell
# Customize all <placeholder> values
$ProfileXML = @"
<VPNProfile>
  <NativeProfile>
    <Servers><VPNGatewayFQDN></Servers>
    <NativeProtocolType>IKEv2</NativeProtocolType>
    <Authentication>
      <UserMethod>Eap</UserMethod>
      <Eap>
        <Configuration>
          <!-- Your EAP XML here — export from an existing working device -->
        </Configuration>
      </Eap>
    </Authentication>
    <RoutingPolicyType>SplitTunnel</RoutingPolicyType>
  </NativeProfile>
  <AlwaysOn>true</AlwaysOn>
  <RememberCredentials>true</RememberCredentials>
  <TrustedNetworkDetection><InternalDNSSuffix></TrustedNetworkDetection>
  <DomainNameInformationList>
    <DomainNameInformation>
      <DomainName>.<InternalDNSSuffix></DomainName>
      <DnsServers><InternalDNS1>,<InternalDNS2></DnsServers>
    </DomainNameInformation>
  </DomainNameInformationList>
  <Route>
    <Address><InternalSubnet></Address>
    <PrefixSize><PrefixLength></PrefixSize>
  </Route>
</VPNProfile>
"@
```

**Step 3 — Push via WMI bridge**
```powershell
$ProfileXMLEncoded = [System.Net.WebUtility]::HtmlEncode($ProfileXML)

$nodeCSPUri = "./User/Vendor/MSFT/VPNv2/$profileName"

$newProfile = [PSCustomObject]@{
    ParentID = "."
    InstanceID = $profileName
    ProfileXML = $ProfileXMLEncoded
}

$session = New-CimSession
New-CimInstance -Namespace root\cimv2\mdm\dmmap `
    -ClassName MDM_VPNv2_01 `
    -Property @{
        ParentID   = "."
        InstanceID = $profileName
        ProfileXML = $ProfileXMLEncoded
    } -ClientOnly | New-CimInstance -CimSession $session
```

**Step 4 — Verify and trigger connection**
```powershell
Get-VpnConnection | Where-Object { $_.Name -eq $profileName }
rasdial $profileName
```

**Rollback:** `Remove-VpnConnection -Name $profileName -Force`; trigger Intune sync to re-push managed profile.

</details>

<details><summary>Playbook 2 — Diagnose and fix NAT-T for IKEv2 behind NAT</summary>

**Scenario:** VPN works from some networks but not others. Error 809 or timeout on IKEv2. Client is behind NAT (home router, hotel, etc.).

**Background:** IKEv2 uses UDP 500 for initial negotiation. When NAT is detected, it switches to UDP 4500 (NAT Traversal / NAT-T). Some NAT devices strip or block UDP 500/4500. Additionally, Windows has a registry setting that controls when it uses UDP encapsulation.

**Step 1 — Confirm NAT is present**
```powershell
# Check the client's external IP vs local IP
$localIP = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike "169.*" -and $_.PrefixOrigin -ne "WellKnown" } |
    Select-Object -First 1).IPAddress
Write-Host "Local IP: $localIP"

# Get external IP (requires internet)
(Invoke-RestMethod -Uri "https://api.ipify.org?format=json").ip
# If external IP != local IP subnet → client is behind NAT
```

**Step 2 — Check current NAT-T registry setting**
```powershell
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent"
$natT = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).AssumeUDPEncapsulationContextOnSendRule
Write-Host "NAT-T setting: $natT"
# 0 = default (Windows decides)
# 1 = assume server is behind NAT
# 2 = assume both client AND server are behind NAT (most permissive — use when behind NAT)
```

**Step 3 — Set NAT-T to value 2 and restart IKEEXT**
```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent" `
    -Name "AssumeUDPEncapsulationContextOnSendRule" `
    -Value 2 -Type DWord

Restart-Service IKEEXT
Get-Service IKEEXT | Select-Object Status
```

**Step 4 — Test VPN connection**
```powershell
rasdial "<VPNProfileName>"
Get-VpnConnection -AllUserConnection | Select-Object Name, ConnectionStatus
```

**Rollback:**
```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent" `
    -Name "AssumeUDPEncapsulationContextOnSendRule" -Value 0 -Type DWord
Restart-Service IKEEXT
```

</details>

<details><summary>Playbook 3 — Force certificate re-enrolment via Intune SCEP/PKCS</summary>

**Scenario:** Machine or user certificate expired or revoked. VPN fails with authentication error. Need to force re-enrolment without reprovisioning the entire device.

**Step 1 — Identify which certificate is needed and its current state**
```powershell
# Machine cert (Device Tunnel)
$machineCerts = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication"
} | Select-Object Subject, Issuer, NotAfter, Thumbprint

# User cert (User Tunnel)
$userCerts = Get-ChildItem Cert:\CurrentUser\My | Where-Object {
    $_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication"
} | Select-Object Subject, Issuer, NotAfter, Thumbprint

$machineCerts | Format-Table -AutoSize
$userCerts | Format-Table -AutoSize
```

**Step 2 — Remove expired/revoked cert (optional — Intune will add new one)**
```powershell
# Only remove if confirmed expired
$expiredThumbprint = "<thumbprint-from-above>"
Remove-Item -Path "Cert:\LocalMachine\My\$expiredThumbprint" -ErrorAction SilentlyContinue
```

**Step 3 — Force Intune sync to trigger certificate re-enrolment**
```powershell
# Method 1: Trigger via IME
Get-Service IntuneManagementExtension | Restart-Service
Start-Sleep -Seconds 30

# Method 2: Trigger via MDM client
Invoke-CimMethod -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DMClient `
    -MethodName TriggerSync -Arguments @{ commandID = 1 } -ErrorAction SilentlyContinue

# Method 3: Settings UI sync
Start-Process "ms-settings:workplace"
```

**Step 4 — Verify new cert appears (allow 5-15 minutes for Intune to process)**
```powershell
# Wait and poll
$timeout = (Get-Date).AddMinutes(15)
while ((Get-Date) -lt $timeout) {
    $validCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication" -and
        $_.NotAfter -gt (Get-Date).AddDays(1)
    }
    if ($validCert) {
        Write-Host "Certificate enrolled:" -ForegroundColor Green
        $validCert | Select-Object Subject, NotAfter | Format-Table
        break
    }
    Write-Host "Waiting for certificate... ($((Get-Date).ToString('HH:mm:ss')))"
    Start-Sleep -Seconds 30
}
```

**Step 5 — Test VPN**
```powershell
rasdial "<VPNProfileName>"
```

**Rollback:** Not applicable — cert enrolment is additive. Old cert already removed/expired.

</details>

<details><summary>Playbook 4 — Collect full NPS diagnostic for auth failures</summary>

**Scenario:** VPN IKEv2 SA establishes but auth is denied (error 691, 812). Need to pinpoint whether the failure is on the client, RRAS, or NPS.

**Step 1 — Enable verbose NPS logging (on NPS server)**
```powershell
# Enable detailed NPS logging to file
auditpol /set /subcategory:"Network Policy Server" /success:enable /failure:enable

# Location of NPS log files
$npsLogPath = "C:\Windows\System32\LogFiles"
Get-ChildItem $npsLogPath -Filter "IN*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

**Step 2 — Check NPS event log (on NPS server)**
```powershell
$since = (Get-Date).AddHours(-2)
Get-WinEvent -LogName "Security" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.TimeCreated -gt $since -and
        $_.Id -in @(6272, 6273, 6274, 6275, 6276)
    } |
    Select-Object TimeCreated, Id,
        @{N="User"; E={ ($_.Properties[0].Value) }},
        @{N="PolicyName"; E={ ($_.Properties[9].Value) }},
        @{N="Reason"; E={ ($_.Properties[6].Value) }} |
    Format-Table -AutoSize
```

**Step 3 — Check RRAS event log (on RRAS/gateway server)**
```powershell
Get-WinEvent -LogName "System" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.TimeCreated -gt $since -and
        $_.ProviderName -in @("RemoteAccess","RasMan","IKEEXT")
    } |
    Select-Object TimeCreated, Id, Message | Format-List
```

**Step 4 — Test RADIUS reachability from RRAS server**
```powershell
# Run on RRAS server
Test-NetConnection -ComputerName "<nps-server-ip>" -Port 1812
Test-NetConnection -ComputerName "<nps-server-ip>" -Port 1813
```

**Step 5 — Verify RADIUS shared secret matches (on both RRAS and NPS)**
On RRAS server: `Routing and Remote Access` → RRAS server → Properties → Security → RADIUS server settings — verify shared secret
On NPS server: Network Policy Server → RADIUS Clients → [RRAS client] → verify shared secret matches exactly

**Rollback:** Disable verbose NPS logging after diagnosis: `auditpol /set /subcategory:"Network Policy Server" /success:disable /failure:disable`

</details>

---
## Evidence Pack

Run this on the affected Windows client (requires admin). Captures everything needed for L3 escalation:

```powershell
<#
.SYNOPSIS  Always On VPN Evidence Collector
.NOTES     Run from an elevated PowerShell session on the affected client
#>

$reportPath = "C:\Temp\AOVPN_Evidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

Write-Host "Collecting Always On VPN evidence to $reportPath..." -ForegroundColor Cyan

# 1. System info
"=== System Info ===" | Out-File "$reportPath\01_System.txt"
[PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    WindowsVersion = (Get-WmiObject Win32_OperatingSystem).Caption
    Build = (Get-WmiObject Win32_OperatingSystem).BuildNumber
    Date = Get-Date
} | Format-List | Out-File "$reportPath\01_System.txt" -Append
dsregcmd /status | Out-File "$reportPath\01_System.txt" -Append

# 2. VPN profiles
"=== VPN Profiles ===" | Out-File "$reportPath\02_Profiles.txt"
Get-VpnConnection -AllUserConnection | Format-List | Out-File "$reportPath\02_Profiles.txt" -Append
Get-VpnConnection | Format-List | Out-File "$reportPath\02_Profiles.txt" -Append

# 3. ProfileXML from WMI
"=== ProfileXML (WMI) ===" | Out-File "$reportPath\03_ProfileXML.txt"
Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_VPNv2_01 -ErrorAction SilentlyContinue |
    ForEach-Object {
        "Profile: $($_.InstanceID)" | Out-File "$reportPath\03_ProfileXML.txt" -Append
        $_.ProfileXML | Out-File "$reportPath\03_ProfileXML.txt" -Append
    }

# 4. Services
"=== Services ===" | Out-File "$reportPath\04_Services.txt"
Get-Service BFE, IKEEXT, RasMan, RasAuto, IntuneManagementExtension -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Format-Table | Out-File "$reportPath\04_Services.txt" -Append

# 5. Network adapters
"=== Network Adapters ===" | Out-File "$reportPath\05_Adapters.txt"
Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*Miniport*" -or
    $_.InterfaceDescription -like "*VPN*" } |
    Select-Object Name, Status, InterfaceDescription | Format-Table |
    Out-File "$reportPath\05_Adapters.txt" -Append

# 6. Certificates
"=== Machine Certs (Client Auth) ===" | Out-File "$reportPath\06_Certs.txt"
Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication"
} | Select-Object Subject, Issuer, NotAfter, Thumbprint |
    Format-Table | Out-File "$reportPath\06_Certs.txt" -Append
"=== User Certs (Client Auth) ===" | Out-File "$reportPath\06_Certs.txt" -Append
Get-ChildItem Cert:\CurrentUser\My | Where-Object {
    $_.EnhancedKeyUsageList.FriendlyName -contains "Client Authentication"
} | Select-Object Subject, Issuer, NotAfter, Thumbprint |
    Format-Table | Out-File "$reportPath\06_Certs.txt" -Append

# 7. VPN event log
"=== VPN-Client/Operational Log ===" | Out-File "$reportPath\07_EventLog.txt"
Get-WinEvent -LogName "Microsoft-Windows-VPN-Client/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Format-List | Out-File "$reportPath\07_EventLog.txt" -Append

# 8. System event log (IKEEXT/RasMan)
"=== System Log (RAS/IKE) ===" | Out-File "$reportPath\08_SystemLog.txt"
Get-WinEvent -LogName "System" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -in @("IKEEXT","RasMan","RemoteAccess","RasClient") } |
    Select-Object TimeCreated, Id, ProviderName, Message | Format-List |
    Out-File "$reportPath\08_SystemLog.txt" -Append

# 9. Gateway reachability
$gwFQDN = (Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty ServerAddress)
if ($gwFQDN) {
    "=== Gateway Connectivity: $gwFQDN ===" | Out-File "$reportPath\09_Network.txt"
    Test-NetConnection -ComputerName $gwFQDN -Port 443 -WarningAction SilentlyContinue |
        Out-File "$reportPath\09_Network.txt" -Append
    Resolve-DnsName $gwFQDN -ErrorAction SilentlyContinue |
        Out-File "$reportPath\09_Network.txt" -Append
}

# 10. NAT-T registry
"=== NAT-T Registry ===" | Out-File "$reportPath\10_Registry.txt"
$natT = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent" -ErrorAction SilentlyContinue).AssumeUDPEncapsulationContextOnSendRule
"AssumeUDPEncapsulationContextOnSendRule: $natT" | Out-File "$reportPath\10_Registry.txt" -Append

# Compress
Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "`nEvidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List VPN profiles (all-user) | `Get-VpnConnection -AllUserConnection` |
| List VPN profiles (per-user) | `Get-VpnConnection` |
| Read live ProfileXML | `Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_VPNv2_01` |
| Force connect | `rasdial "<ProfileName>"` |
| Force disconnect | `rasdial "<ProfileName>" /disconnect` |
| Check service state | `Get-Service BFE, IKEEXT, RasMan, RasAuto \| Select-Object Name, Status` |
| Restart VPN services | `Restart-Service IKEEXT; Restart-Service RasMan` |
| Check machine certs | `Get-ChildItem Cert:\LocalMachine\My \| Where-Object { $_.EnhancedKeyUsageList -match "Client Auth" }` |
| Check user certs | `Get-ChildItem Cert:\CurrentUser\My \| Where-Object { $_.EnhancedKeyUsageList -match "Client Auth" }` |
| Test gateway TCP 443 | `Test-NetConnection -ComputerName <fqdn> -Port 443` |
| Check NAT-T registry | `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent` |
| Enable NAT-T | `Set-ItemProperty -Path HKLM:\...\PolicyAgent -Name AssumeUDPEncapsulationContextOnSendRule -Value 2` |
| Check VPN event log | `Get-WinEvent -LogName "Microsoft-Windows-VPN-Client/Operational" -MaxEvents 20` |
| Check auto-trigger | `Get-VpnConnectionTrigger -ConnectionName "<ProfileName>"` |
| Force Intune sync | `Invoke-CimMethod -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DMClient -MethodName TriggerSync -Arguments @{ commandID = 1 }` |
| Remove VPN profile | `Remove-VpnConnection -Name "<ProfileName>" -AllUserConnection -Force` |
| Restart IME | `Restart-Service IntuneManagementExtension` |

---
## 🎓 Learning Pointers

- **The two-tunnel architecture solves the chicken-and-egg problem.** Traditional VPN requires the user to manually connect before they can reach DCs. Device Tunnel (IKEv2 + machine cert) connects at startup before the logon screen, giving the client access to DCs for Kerberos, Group Policy, and Intune while the user is still typing their password. User Tunnel then provides the resource access the user actually needs. These two tunnels should be debugged independently — a failure in one has no bearing on the other. [Device tunnel deployment guide](https://learn.microsoft.com/en-us/windows-server/remote/remote-access/vpn/vpn-device-tunnel-config)

- **ProfileXML is the entire VPN configuration in one XML blob.** There is no equivalent of a GUI setting that lives "outside" the ProfileXML — everything, including split routes, DNS suffixes, cipher suites, EAP config, and always-on triggers, is in that XML. When behaviour is unexpected, always pull the live ProfileXML from WMI (`Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_VPNv2_01`) and compare it against what Intune shows. A mismatch here explains 80% of post-change failures. [ProfileXML schema reference](https://learn.microsoft.com/en-us/windows/client-management/mdm/vpnv2-profile-xsd)

- **Error codes are your fastest triage path.** Windows VPN errors are specific: 809 = UDP path blocked, 691 = auth rejected, 812 = NPS policy mismatch, 13868 = IKEv2 machine/cert auth failure, 853 = cipher mismatch. Always note the error code before touching anything. The VPN-Client/Operational event log records these with the profile name and timestamp. [Common VPN error codes](https://learn.microsoft.com/en-us/windows-server/remote/remote-access/vpn/always-on-vpn/deploy/always-on-vpn-deploy-troubleshooting)

- **NPS is where most User Tunnel auth failures live.** The client's IKEv2 connection attempt reaches RRAS fine — but RRAS asks NPS "is this user allowed?" and NPS says no. The client only sees "error 691" and nothing else. The detailed reason is in NPS event 6273 on the NPS server. Always check the NPS server logs before diving into client-side certificate or ProfileXML issues. The reason field in 6273 maps directly to a specific fix.

- **TrustedNetworkDetection prevents VPN on corpnet — by design.** If the VPN shows "Disconnected" on the corporate network but "Connected" from home, check the `<TrustedNetworkDetection>` element in the ProfileXML. This feature detects the corporate network (by DNS suffix) and suppresses the Always On tunnel. This is correct, expected behaviour. If users report VPN not connecting on-premise: that's the feature working. [TrustedNetworkDetection explained](https://learn.microsoft.com/en-us/windows-server/remote/remote-access/vpn/always-on-vpn/deploy/vpn-deploy-client-vpn-connections#configure-the-profilexml)

- **Certificate revocation checking can silently break everything.** By default, Windows checks the CRL or OCSP responder for every certificate in the chain during IKEv2 authentication. If the CRL endpoint is unreachable from the client (common when the client is off-network and the CRL URL is an internal address), the authentication fails with a timeout. The fix is to publish CRL distribution points on internet-accessible URLs, or explicitly configure the VPN to not require CRL checking via the `<DisableServerCertCheck>` element (only use in controlled environments).
