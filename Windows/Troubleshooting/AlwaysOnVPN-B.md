# Always On VPN — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these first — they tell you which path to take:

```powershell
# 1. Check VPN adapter and connection state
Get-VpnConnection -AllUserConnection | Select-Object Name, ConnectionStatus, TunnelType, AuthenticationMethod

# 2. Check IKEv2/SSTP tunnel status
Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*WAN Miniport*" -or $_.InterfaceDescription -like "*Miniport*" } |
    Select-Object Name, Status, InterfaceDescription

# 3. Check AOVPN Device Tunnel (if deployed)
Get-VpnConnection -AllUserConnection | Where-Object { $_.Name -like "*Device*" } |
    Select-Object Name, ConnectionStatus, ServerAddress

# 4. Check recent VPN connection errors in event log
Get-WinEvent -LogName "Microsoft-Windows-VPN-Client/Operational" -MaxEvents 20 |
    Select-Object TimeCreated, Id, Message | Format-List

# 5. Check RasMan service state
Get-Service RasMan, RasAuto, IKEEXT | Select-Object Name, Status, StartType
```

| Result | Next Step |
|--------|-----------|
| RasMan/IKEEXT Stopped | → [Fix 1 — Restart VPN Services](#fix-1--restart-vpn-services) |
| Error 13868 / IKEv2 auth failure | → [Fix 2 — Certificate/Auth Issues](#fix-2--certificateauth-issues) |
| Error 809 / firewall block | → [Fix 3 — Network/Firewall Path](#fix-3--networkfirewall-path) |
| Adapter present, status "Disconnected" repeatedly | → [Fix 4 — DNS Resolution or Split Tunneling](#fix-4--dns-resolution-or-split-tunneling) |
| Device tunnel connected, user tunnel not | → [Fix 5 — User Tunnel Profile Issues](#fix-5--user-tunnel-profile-issues) |
| ProfileXML mismatch after Intune push | → [Fix 6 — Reprovisioning the Profile](#fix-6--reprovisioning-the-profile) |

---
## Dependency Cascade

<details><summary>What must be true for Always On VPN to connect</summary>

```
Physical/Wireless Network
        │
        ▼
Internet Connectivity (DNS resolves, UDP 500/4500 or TCP 443 reachable)
        │
        ▼
RRAS/VPN Gateway (reachable, certificate valid, IKEv2/SSTP enabled)
        │
        ▼
Windows Services (RasMan, IKEEXT, RasAuto running)
        │
        ▼
VPN Adapter (WAN Miniport IKEv2 / SSTP present, not in error state)
        │
        ▼
Machine Certificate (Device Tunnel) / User Certificate or EAP (User Tunnel)
        │
        ▼
ProfileXML (valid, deployed via Intune/PowerShell, WMI Bridge intact)
        │
        ▼
NPS/RADIUS (if used — reachable, correct shared secret, policy matches)
        │
        ▼
VPN Connected — routes/DNS pushed to client
```
</details>

---
## Diagnosis & Validation Flow

**1. Confirm VPN profile exists on the device**
```powershell
Get-VpnConnection -AllUserConnection
# Or for user-tunnel:
Get-VpnConnection
```
Expected: profile listed with correct `ServerAddress`.
Bad: empty or wrong server — profile not deployed or was removed.

**2. Check machine certificate (Device Tunnel / IKEv2)**
```powershell
Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.EnhancedKeyUsageList -match "Client Authentication"
} | Select-Object Subject, Thumbprint, NotAfter
```
Expected: at least one valid cert from your internal CA, not expired.
Bad: no cert, or expired cert → re-enroll via SCEP/NDES or Intune cert profile.

**3. Check user certificate (User Tunnel with EAP-TLS)**
```powershell
Get-ChildItem Cert:\CurrentUser\My | Where-Object {
    $_.EnhancedKeyUsageList -match "Client Authentication"
} | Select-Object Subject, Thumbprint, NotAfter
```
Expected: cert present, not expired, issued by trusted CA.

**4. Test reachability of VPN gateway**
```powershell
# Replace <vpn-gateway-fqdn> with actual FQDN
Test-NetConnection -ComputerName <vpn-gateway-fqdn> -Port 443
Test-NetConnection -ComputerName <vpn-gateway-fqdn> -Port 500
# IKEv2 uses UDP 500 / 4500 — TCP test won't confirm UDP but DNS confirms resolution
Resolve-DnsName <vpn-gateway-fqdn>
```
Expected: TcpTestSucceeded = True (SSTP), or DNS resolves correctly.

**5. Check WMI bridge for ProfileXML integrity**
```powershell
$session = New-CimSession
$vpnProfile = Get-CimInstance -Namespace root\cimv2\mdm\dmmap `
    -ClassName MDM_VPNv2_01 -CimSession $session
$vpnProfile | Select-Object InstanceID, ProfileXML
```
Expected: ProfileXML contains valid XML with correct `<ServerURL>`, `<NativeProfile>`, auth method.
Bad: blank or malformed XML — re-push profile.

**6. Check IKEEXT and IKEv2 errors**
```powershell
Get-WinEvent -LogName "System" -MaxEvents 100 |
    Where-Object { $_.ProviderName -in "IKEEXT","RasClient","RasMan" } |
    Select-Object TimeCreated, Id, Message | Format-List
```
Common IDs: 20227 (RasClient connection failed), 13868 (IKEv2 auth error), 809 (blocked by firewall).

---
## Common Fix Paths

<details><summary>Fix 1 — Restart VPN Services</summary>

**When:** RasMan, IKEEXT, or RasAuto are stopped or in a failed state.

```powershell
# Restart dependent services in correct order
Stop-Service -Name RasAuto -Force -ErrorAction SilentlyContinue
Stop-Service -Name RasMan -Force
Stop-Service -Name IKEEXT -Force

Start-Sleep -Seconds 3

Start-Service IKEEXT
Start-Service RasMan
Start-Service RasAuto

# Verify
Get-Service RasMan, RasAuto, IKEEXT | Select-Object Name, Status
```

**Rollback:** No rollback needed — restarting these services is non-destructive.
If IKEEXT fails to start, check for KB conflicts or run: `sfc /scannow`
</details>

<details><summary>Fix 2 — Certificate / Auth Issues</summary>

**When:** Error 13868 (IKEv2 auth), error 812 (NPS policy), or EAP failure.

**Step 1: Verify cert chain**
```powershell
# Check root/intermediate CAs are trusted
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*<your-CA-name>*" }
Get-ChildItem Cert:\LocalMachine\CA   | Where-Object { $_.Subject -like "*<your-CA-name>*" }
```

**Step 2: Force re-enroll machine cert via Intune (if SCEP/PKCS)**
```powershell
# Trigger Intune sync to re-push cert profile
Start-Process "ms-settings:workplace"
# Or via MDM diagnostic
Start-Process "intunemanagementextension://"
```

**Step 3: Manually request cert (test only)**
```powershell
# From elevated prompt — replace <CA-name> and <template>
certreq -enroll -machine <template-name>
```

**Rollback:** Cert operations are additive; existing certs unaffected unless revoked.
</details>

<details><summary>Fix 3 — Network / Firewall Path</summary>

**When:** Error 809 (IKEv2 blocked), SSTP handshake fails, gateway unreachable.

```powershell
# Test UDP 500 and 4500 (IKEv2) — requires PSping or custom UDP test
# Test TCP 443 (SSTP)
Test-NetConnection -ComputerName <vpn-gateway-fqdn> -Port 443

# Check local Windows Firewall isn't blocking outbound
Get-NetFirewallRule -Direction Outbound -Enabled True |
    Where-Object { $_.Action -eq "Block" } |
    Select-Object DisplayName, Profile

# Check proxy interference (SSTP uses HTTPS — proxy can block)
netsh winhttp show proxy
```

**If behind NAT with IKEv2:** Ensure NAT-T is enabled on both client and gateway (UDP 4500).
```powershell
# Enable NAT-T on client
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent" `
    -Name "AssumeUDPEncapsulationContextOnSendRule" -Value 2 -Type DWord
# Restart IKEEXT after change
Restart-Service IKEEXT
```

**Rollback:** Revert registry value to 0 (default) if connectivity issues arise elsewhere.
</details>

<details><summary>Fix 4 — DNS Resolution or Split Tunneling</summary>

**When:** VPN connects but internal resources unreachable, or DNS lookups fail for internal FQDNs.

```powershell
# Check current DNS servers while VPN is connected
Get-DnsClientServerAddress | Select-Object InterfaceAlias, ServerAddresses

# Check routing table — ensure internal subnets route through VPN
Get-NetRoute | Where-Object { $_.InterfaceAlias -like "*VPN*" -or $_.InterfaceAlias -like "*Miniport*" } |
    Select-Object DestinationPrefix, NextHop, InterfaceAlias

# Test DNS resolution of internal resource
Resolve-DnsName <internal-server.domain.local> -Server <internal-dns-server-ip>
```

**If internal DNS not pushed:** The ProfileXML `<DnsSuffix>` or `<DomainNameInformationList>` may be missing/wrong.
Re-export the VPN profile XML, verify `<DomainNameInformationList>` contains your internal domains with correct DNS server IPs, then re-push via Intune or PowerShell.

**Rollback:** N/A — diagnostic only. Profile changes require re-push (see Fix 6).
</details>

<details><summary>Fix 5 — User Tunnel Profile Issues</summary>

**When:** Device tunnel connects fine, user tunnel fails after login; or user tunnel not triggering automatically.

```powershell
# Check if user-tunnel profile is present for current user
Get-VpnConnection | Select-Object Name, ConnectionStatus, TunnelType

# Check auto-trigger is set
Get-VpnConnectionTrigger -ConnectionName "<User-Tunnel-Profile-Name>"

# Force connect for testing
rasdial "<User-Tunnel-Profile-Name>"
```

**If auto-trigger missing:** Re-apply the profile with correct `<AlwaysOn>true</AlwaysOn>` in ProfileXML.

**If rasdial fails with error 691:** Credentials issue. Check:
- EAP configuration in ProfileXML matches NPS policy
- User's certificate or password is valid
- NPS logs: `Event Viewer → Custom Views → Network Policy and Access Services`
</details>

<details><summary>Fix 6 — Reprovisioning the Profile</summary>

**When:** ProfileXML is corrupt, missing, or out of date after an Intune config change.

```powershell
# Step 1: Remove existing profile
$profileName = "<YourVPNProfileName>"
Remove-VpnConnection -Name $profileName -AllUserConnection -Force -ErrorAction SilentlyContinue
Remove-VpnConnection -Name $profileName -Force -ErrorAction SilentlyContinue

# Step 2: Force Intune sync to re-push profile
Invoke-CimMethod -Namespace root\cimv2\mdm\dmmap `
    -ClassName MDM_DMClient -MethodName TriggerSync `
    -Arguments @{ commandID = 1 } -ErrorAction SilentlyContinue

# Or via IME
Get-Service IntuneManagementExtension | Restart-Service

# Step 3: Verify profile re-appears (may take 5-15 min)
Start-Sleep -Seconds 30
Get-VpnConnection -AllUserConnection
```

**Rollback:** If reprovisioning makes things worse, check Intune device config profile assignment and check-in status in MEM portal.
</details>

---
## Escalation Evidence

```
=== Always On VPN Escalation Package ===
Date/Time        : 
Device Name      : 
Azure AD Join    : 
Intune Enrolled  : 
Windows Version  : 
VPN Profile Name : 
Tunnel Type      : [ ] Device  [ ] User  [ ] Both
Error Code       : 
Error Description: 

--- Service State ---
RasMan    : 
IKEEXT    : 
RasAuto   : 

--- Connection Test ---
Gateway FQDN     : 
TCP 443 reachable: 
DNS resolves     : 

--- Certificate ---
Machine cert present : 
Issuer               : 
Expiry               : 

--- Event Log Snippet ---
(paste last 5 VPN-Client/Operational events)

--- ProfileXML MD5 (to confirm profile integrity) ---
# Run: Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_VPNv2_01 |
#       Select-Object InstanceID | Format-List

--- Actions Taken ---
1. 
2. 
3. 
```

---
## 🎓 Learning Pointers

- **Always On VPN uses two tunnels:** Device Tunnel (machine cert, connects pre-login, IKEv2 only) and User Tunnel (user cert/EAP, connects at login). They are separate profiles — check both independently.
- **Error 809** almost always means UDP 500/4500 is blocked between client and gateway. A common culprit is hotel/corporate guest Wi-Fi. Switching to SSTP (TCP 443) sidesteps this but requires an SSTP-enabled gateway.
- **ProfileXML is king.** The entire VPN config lives in WMI via the MDM bridge. If behaviour is unexpected after an Intune change, always validate the live ProfileXML on the device matches what Intune intended: [ProfileXML reference](https://learn.microsoft.com/en-us/windows-server/remote/remote-access/vpn/always-on-vpn/deploy/vpn-deploy-client-vpn-connections)
- **NPS is the silent killer.** Most auth failures (691, 812) trace back to NPS policy order, expired RADIUS shared secrets, or a missing user/computer in the correct AD group. Check NPS event log on the server, not just the client.
- **Certificate auto-enrolment must be working.** Device Tunnel requires a machine cert; if SCEP/PKCS profile in Intune fails silently, the tunnel never connects. Always correlate Intune cert profile status with the VPN profile status.
- **MS Docs — Always On VPN deployment overview:** https://learn.microsoft.com/en-us/windows-server/remote/remote-access/vpn/always-on-vpn/always-on-vpn-technology-overview
