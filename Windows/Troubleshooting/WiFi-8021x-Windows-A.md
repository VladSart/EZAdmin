# Windows 802.1X (Enterprise Wi-Fi & Wired, EAP-TLS / PEAP) — Reference Runbook (Mode A: Deep Dive)
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
- **Covers:** the Windows 10/11 *supplicant* side of 802.1X for Wi-Fi (WPA2/WPA3-Enterprise) and wired ports — WLAN AutoConfig and Wired AutoConfig services, profile sources (Intune Wi-Fi/Wired profiles, Group Policy, manual), EAP-TLS and PEAP-MSCHAPv2, server-validation settings, machine vs user authentication, certificate selection, Credential Guard interaction, strong certificate mapping, and the cloud-only Entra-joined device problem.
- **Does not cover:** NPS server internals (policies, RADIUS clients, NPS extension for MFA — `NPS-RADIUS-A.md`), certificate issuance infrastructure (NDES/SCEP/PKCS connector — `Intune/Troubleshooting/Certificates-A.md`, `CloudPKI-A.md`; AD CS — `CertificateServices-A.md`), VPN EAP (`AlwaysOnVPN-A.md`), macOS (`macOS/Troubleshooting/WiFi-8021x-A.md`), switch/AP vendor configuration.
- **Assumes:** Windows 10 22H2 or Windows 11; the RADIUS server is Microsoft NPS unless stated (behaviour for third-party RADIUS is noted where it differs); certificates issued by an enterprise PKI via Intune SCEP/PKCS or AD CS autoenrollment.

---
## How It Works
<details><summary>Full architecture</summary>

### Roles
```
 Supplicant (Windows)          Authenticator (AP/switch)          Authentication server (NPS)
 ┌──────────────────┐  EAPOL   ┌─────────────────────┐  RADIUS   ┌─────────────────────────┐
 │ WlanSvc/dot3svc  │◄────────►│ port blocked until  │◄─────────►│ CRP → Network Policy    │
 │ EapHost + EAP    │ (L2)     │ Access-Accept       │ UDP 1812  │ EAP method (TLS/PEAP)   │
 │ method DLLs      │          │ (+VLAN attributes)  │ /1813     │ AD lookup / cert mapping│
 └──────────────────┘          └─────────────────────┘           └─────────────────────────┘
```
The authenticator never sees credentials; it relays EAP inside RADIUS. The TLS tunnel (EAP-TLS or PEAP outer) is **end-to-end between Windows and NPS** — which is why TLS failures are logged mainly at the two endpoints, not on the AP.

### Services
- **WLAN AutoConfig (`WlanSvc`)** — owns Wi-Fi profiles, association, and invokes EapHost for 802.1X. Automatic by default.
- **Wired AutoConfig (`dot3svc`)** — the wired equivalent. **Manual by default**, so a wired 802.1X port simply never sees EAPOL-Start until something sets it to Automatic (Intune Wired network profile, GPO Wired Network Policies, or a script).
- **EapHost** — hosts EAP method plug-ins (EAP-TLS = type 13, PEAP = type 25, EAP-TTLS = 21, EAP-MSCHAPv2 = 26 as PEAP inner method).

### Profile sources and precedence
| Source | Where it shows | Editable locally | Notes |
|---|---|---|---|
| Group Policy (Wireless / Wired Network Policies) | `netsh wlan show profiles` → *Group policy profiles (read only)* | No | Wins over user profiles for same SSID; GPO also can deny SSIDs |
| MDM (Intune Wi-Fi / Wired profile via WiFi / WiredNetwork CSP) | Listed as policy-managed profile | No (re-applied on sync) | Profile XML is generated from the Intune UI or imported custom XML |
| Manual / user | *User profiles* | Yes | Survives until deleted; can shadow a broken policy profile's SSID in the UI |

Profiles are stored as XML under `C:\ProgramData\Microsoft\Wlansvc\Profiles\Interfaces\{InterfaceGUID}\`. `netsh wlan export profile` is the supported way to read them.

### Machine vs user authentication
- **Machine auth** uses the computer's credentials (computer account password for PEAP, or a cert in `LocalMachine\My` for EAP-TLS). It runs before sign-in, so it's needed for first logon of new users, GPO processing at boot, Autopilot pre-provisioning on corporate-only networks, and drive mappings.
- **User auth** uses the signed-in user's credentials/cert (`CurrentUser\My`). The port re-authenticates at sign-in.
- **Machine or user** (Intune "Machine or user"; XML `authMode = machineOrUser`) — machine before logon, user after. Switching identities mid-session can cause a brief drop and, if the NPS policy puts users and machines in different VLANs, an IP change.
- **Single Sign-On** (PEAP only, profile setting) lets user credentials be used before logon; it's also what Credential Guard breaks for MS-CHAPv2.

### Server validation — the most mis-configured piece
The client must decide whether the RADIUS server is legitimate. The profile holds:
- `ServerNames` — one or more names (or regex/suffix patterns) that must match the NPS certificate's subject/SAN DNS.
- `TrustedRootCA` — thumbprint(s) of roots the NPS cert must chain to.
- Whether to prompt the user if validation fails (Windows 11 no longer lets users "connect anyway" in the way Windows 7-era profiles did; unmanaged prompts are an evil-twin risk).
If NPS's certificate is renewed from a different CA, gains a different name, or its chain changes, **every client fails at once** — and NPS logs little, because the client aborts the handshake. Always pre-deploy the new root to clients and add the new server name before switching the NPS cert.

### EAP-TLS versus PEAP-MSCHAPv2
| | EAP-TLS | PEAP-MSCHAPv2 |
|---|---|---|
| Client credential | Certificate + private key | AD username/password inside TLS tunnel |
| Credential Guard | Unaffected | SSO and saved credentials **blocked** (MS-CHAPv2 is an NTLM-derived protocol Credential Guard refuses to expose) |
| Password changes | No effect | Stale cached password locks accounts / fails auth |
| Cloud-only devices | Possible with cert mapping design | Computer account doesn't exist → machine auth impossible |
| Deployment effort | PKI + cert profiles | Minimal |
Credential Guard became default-enabled on eligible Windows 11 22H2+ Enterprise/Education devices that meet hardware requirements and aren't domain controllers; that's why PEAP fleets that "worked for years" started prompting for credentials after a feature update.

### How NPS maps a certificate to an account
NPS calls into AD to map the presented certificate to a user or computer:
- Implicit mapping via UPN/DNS name in the SAN (user UPN, or computer `dNSHostName`) — considered **weak** unless combined with the SID extension.
- **Strong** mappings (since KB5014754 enforcement): the szOID_NTDS_CA_SECURITY_EXT SID extension (OID `1.3.6.1.4.1.311.25.2`) added by an enterprise CA for online-template requests, the Intune SAN URL tag `tag:microsoft.com,2022-09-14:sid:<SID>` (SCEP/PKCS, added by current Intune Certificate Connector for AD-synced users and hybrid-joined devices), or explicit `altSecurityIdentities` values of the strong types (`X509:<I>…<SR>…`, `X509:<SKI>…`, `X509:<SHA1-PUKEY>…`).
Windows DCs moved to Full Enforcement in 2025 (compatibility mode ended). Certificates without a strong mapping stop mapping — on NPS this surfaces as a rejection (commonly Reason Code 16, sometimes 8) even though the certificate is valid and trusted.

### The cloud-only Entra-joined device gap
A cloud-only (non-hybrid) Entra-joined device has no AD computer object and therefore no SID to put in the cert and no account for NPS to map to. There is no Microsoft-supported way to make on-prem NPS authenticate such a *device*. Options: user-based EAP-TLS for hybrid-identity users; pre-created "shadow" computer objects carrying strong `altSecurityIdentities` (community-automated, unsupported); or a cloud RADIUS service that validates Intune-issued certs and Entra device state.

### Intune delivery chain
Intune Wi-Fi (or Wired) profile → references a **Trusted certificate** profile (root(s) for server validation) and, for EAP-TLS, a **SCEP or PKCS** profile (client cert). The Wi-Fi profile won't apply until its referenced profiles have applied; mixing user-group and device-group assignments across the three is the top cause of a Wi-Fi profile stuck in *Pending*. Autopilot pre-provisioning/ESP on a corporate-only SSID needs **device-context** certs and machine auth.
</details>

---
## Dependency Stack
```
L7  User experience: connects at boot (machine) → re-auths at sign-in (user)
L6  RADIUS decision: NPS CRP → Network Policy (groups, NAS port type, EAP type) → Access-Accept (+VLAN)
L5  Account mapping in AD: user/computer exists; cert strongly mapped (SID ext / SAN tag / altSecIds)
L4  TLS: client trusts NPS cert (root + server name); NPS trusts client cert (root, NTAuth for AD CS, CRL reachable)
L3  Credentials on device: client cert in right store w/ private key & Client Auth EKU  |  PEAP: creds not blocked by Credential Guard
L2  Profile: correct SSID, WPA2/3-Enterprise, EAP type, auth mode, server validation (from Intune/GPO)
L1  Supplicant services: WlanSvc running; dot3svc Automatic+running for wired
L0  Radio/link: adapter driver, band/WPA3 support, switch port 802.1X enabled, AP RADIUS client registered on NPS
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Everyone fails at once after a date/change | NPS cert renewed/changed issuer; or client-cert CA chain/CRL expired | NPS cert issuer vs profile `TrustedRootCA`; CRL `NextUpdate` |
| Only new/reimaged devices fail | Cert profile not yet applied / device-group vs user-group mismatch | Intune device status of Trusted cert + SCEP/PKCS + Wi-Fi profiles |
| Works after sign-in, not at boot | Profile auth mode = user, or cert is user-context only | Profile `authMode`; `LocalMachine\My` contents |
| Credentials prompt repeatedly on PEAP | Credential Guard blocking MS-CHAPv2 SSO / saved creds | `Win32_DeviceGuard.SecurityServicesRunning` contains 1 |
| Wired port stuck in "unauthenticated"/guest VLAN | `dot3svc` not running | `Get-Service dot3svc` |
| NPS 6273 Reason 8 for `host/<name>` | Cloud-only device, or computer object deleted/renamed | `dsregcmd /status`; AD `Get-ADComputer` |
| NPS 6273 Reason 16 on EAP-TLS | Weak cert mapping under enforcement | Cert SID extension / SAN tag present? |
| NPS 6273 Reason 22 | EAP type mismatch between profile and Network Policy | Profile `<Type>` vs NPS policy Authentication Methods |
| NPS 6273 Reason 23 / 265 | Client cert chain not trusted by NPS / revocation | NPS `LocalMachine\Root`, `NTAuth`, CDP reachability |
| Client event 12013 citing server cert | Client-side server validation failure | Profile `ServerNames` + root thumbprint present locally |
| Two identical SSIDs in list, one fails | Manual profile shadowing policy profile or GPO + Intune both pushing | `netsh wlan show profiles` sections |
| WPA3-Enterprise SSID not visible/joinable | Adapter/driver lacks WPA3 or 192-bit mode support | `netsh wlan show drivers` → Authentication and cipher supported |

---
## Validation Steps
1. **Services**
   `Get-Service WlanSvc,dot3svc` → Good: WlanSvc Running; dot3svc Running/Automatic where wired 802.1X is used. Bad: dot3svc Stopped → wired auth never starts.
2. **Driver capability**
   `netsh wlan show drivers` → Good: lists `WPA2-Enterprise` (and `WPA3-Enterprise` if the SSID uses it). Bad: missing → driver update before anything else.
3. **Profile present and from the expected source**
   `netsh wlan show profiles` → Good: corporate SSID under the policy section. Bad: only under *User profiles* → Intune/GPO didn't deliver.
4. **Profile EAP settings**
   Export XML; Good: `<Type>13</Type>` (TLS) or `25` (PEAP), `authMode` as designed, non-empty `ServerNames` and `TrustedRootCA`.
5. **Root trust**
   Thumbprints from `TrustedRootCA` exist in `Cert:\LocalMachine\Root`. Bad: missing → Trusted certificate profile not applied.
6. **Client certificate**
   `LocalMachine\My` (machine) or `CurrentUser\My` (user): Client Auth EKU, private key, not expired, issuer = expected CA, SID extension or SAN SID tag present.
7. **Credential Guard (PEAP only)**
   `(Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).SecurityServicesRunning` → contains `1` = CG running → PEAP-MSCHAPv2 SSO won't work.
8. **Client event outcome**
   WLAN Operational: 12011 (802.1X started) → 12012 (succeeded) → 8001 (connected). Bad: 12013 (failed) with reason text, or 8002.
9. **Server outcome**
   NPS Security log: 6272 (granted) good; 6273 (denied) with Reason Code.

---
## Troubleshooting Steps (by phase)
### Phase 1 — Is the supplicant even trying?
Services, driver, adapter up, SSID visible (`netsh wlan show networks mode=bssid`). For wired, `netsh lan show interfaces` should show an authentication state; if it says the service isn't running, stop here and fix `dot3svc`.

### Phase 2 — Is the right profile there?
Compare `netsh wlan show profile name="<SSID>"` with the Intune profile. Check for duplicates from GPO. If the profile is missing, trace Intune: Wi-Fi profile status → referenced Trusted cert profile → SCEP/PKCS profile. Assignment group types must line up.

### Phase 3 — Does the client trust the server?
Take a packet-free route first: WLAN event 12013 text and the wlanreport. If it references the server certificate, compare the NPS cert (issuer, SAN) against profile XML. If available, run a trace: `netsh trace start scenario=wlan capture=no tracefile=C:\Temp\wlan.etl` → reproduce → `netsh trace stop` (use `scenario=lan` for wired).

### Phase 4 — Does the server accept the client?
Read NPS 6273. Map Reason Code (Mode B Fix 5 table). For EAP-TLS, confirm the client cert chain is trusted on NPS, the CRL is reachable from NPS, and the cert has a strong mapping to an existing AD object.

### Phase 5 — Does the right Network Policy match?
Reason 48/65 or wrong VLAN: check group membership conditions (computer vs user groups), NAS Port Type (Wireless - IEEE 802.11 vs Ethernet), and policy ordering. See `NPS-RADIUS-A.md`.

### Phase 6 — Identity-model problems
Cloud-only devices, Credential Guard with PEAP, or reimaged hybrid devices whose AD object was recreated (new SID → old cert's SID tag no longer matches → reissue cert).

---
## Remediation Playbooks
<details><summary>Playbook 1 — NPS certificate rollover without an outage</summary>

1. Issue the new NPS server cert (Server Authentication EKU, SAN DNS = NPS FQDN).
2. **Before** binding it: add the new issuing root to the Intune Trusted certificate profile (keep the old one) and, if the name changes, add the new name to *Certificate server names* in the Wi-Fi/Wired profiles (semicolon-separated).
3. Wait for deployment coverage (Intune device status ≥ your threshold, e.g. 95%).
4. Bind the new cert in each NPS Network Policy's EAP properties.
5. Monitor 6272/6273 counts for an hour. Rollback: re-select the old cert in the EAP properties (keep it until the old one expires).
</details>

<details><summary>Playbook 2 — Migrate PEAP-MSCHAPv2 to EAP-TLS (Credential Guard-safe)</summary>

1. Deploy Trusted certificate profile (root for NPS + root/intermediate for client certs) to device groups.
2. Deploy SCEP (or PKCS) device certificate profile: Key usage Digital signature + Key encipherment, EKU Client Authentication, Subject `CN={{AAD_Device_ID}}` or `CN={{DeviceName}}`, SAN DNS `{{FullyQualifiedDomainName}}` for hybrid-joined devices (so NPS can map by dNSHostName + SID tag).
3. Create a new NPS Network Policy (or add EAP-TLS as a method) with conditions matching the machine group.
4. Deploy a **new** Wi-Fi profile (EAP-TLS, machine or user auth, same SSID or a new SSID) to a pilot group; exclude the pilot from the PEAP profile.
5. Validate with 12012 events and 6272 on NPS; expand in rings.
6. Rollback: re-include pilot in PEAP profile assignment; the PEAP NPS policy is unchanged.
</details>

<details><summary>Playbook 3 — Reissue certificates lacking strong mapping</summary>

```powershell
# Identify machine certs from the Intune-issuing CA without SID extension or SAN SID tag
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Issuer -like '*<IssuingCA>*' } | ForEach-Object {
  $san = ($_.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })
  [pscustomobject]@{
    Thumbprint = $_.Thumbprint; NotAfter = $_.NotAfter
    SidExt  = [bool]($_.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.25.2' })
    SidTag  = [bool]($san -and $san.Format($false) -match 'tag:microsoft.com,2022-09-14:sid:')
  } }
```
1. Update the Intune Certificate Connector to current (Certificates-A.md).
2. Trigger renewal: change the SCEP/PKCS profile (e.g., renewal threshold or validity) so Intune reissues, or target a new profile to the group and remove the old after coverage.
3. For AD CS autoenrolled machine certs, ensure the template is online (subject built from AD) so the CA adds the SID extension; then `certutil -pulse` on clients or wait for autoenrollment.
4. Rollback: none needed — old certs remain until expiry/removal; don't revoke them until the new ones are verified.
</details>

<details><summary>Playbook 4 — Shadow AD objects for cloud-only devices (unsupported pattern — document risk)</summary>

For each Entra-joined device with an Intune-issued cert:
```powershell
# Example for ONE device — automate only after design sign-off
$name   = '<ShortDeviceName>'            # ≤15 chars for sAMAccountName
$issuer = 'DC=com,DC=contoso,CN=Contoso Issuing CA'   # issuer DN in X509 <I> reversed-component form
$serialReversed = '<SerialBytesReversedHex>'
New-ADComputer -Name $name -Path 'OU=EntraDevices,DC=contoso,DC=com' -Enabled $true
Set-ADComputer $name -Replace @{altSecurityIdentities = "X509:<I>$issuer<SR>$serialReversed"}
```
- The object is only a mapping target: no password, no GPO. Add it to the NPS policy group.
- Mapping must be updated on every cert renewal (serial changes) — use SKI-based mapping if your issuance keeps key pairs, or automate from Intune/Graph cert inventory.
- Removal/rollback: `Remove-ADComputer $name` and remove from the NPS group.
</details>

<details><summary>Playbook 5 — Reset the local Wi-Fi stack on one device</summary>

```powershell
netsh wlan show profiles                       # record what's there
netsh wlan export profile folder=C:\Temp\wlan-backup   # backup all (no key=clear needed for EAP)
netsh wlan delete profile name="<SSID>"        # manual/user profiles only
Restart-Service WlanSvc -Force
# then force Intune sync so the policy profile re-applies
```
Rollback: `netsh wlan add profile filename="C:\Temp\wlan-backup\<file>.xml"`.
</details>

---
## Evidence Pack
```powershell
<# Collect Windows 802.1X evidence to C:\Temp\8021x-<computer>-<time> (run elevated) #>
$out = "C:\Temp\8021x-$env:COMPUTERNAME-$(Get-Date -f yyyyMMdd-HHmm)"
New-Item $out -ItemType Directory -Force | Out-Null
netsh wlan show interfaces   > "$out\wlan-interfaces.txt"
netsh wlan show drivers      > "$out\wlan-drivers.txt"
netsh wlan show profiles     > "$out\wlan-profiles.txt"
netsh lan show interfaces    > "$out\lan-interfaces.txt" 2>&1
netsh lan show profiles      > "$out\lan-profiles.txt"  2>&1
netsh wlan export profile folder="$out"                  | Out-Null
netsh wlan show wlanreport                               | Out-Null
Copy-Item "$env:ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html" $out -ErrorAction SilentlyContinue
dsregcmd /status > "$out\dsregcmd.txt"
Get-Service WlanSvc,dot3svc | Export-Csv "$out\services.csv" -NoTypeInformation
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject,Issuer,NotBefore,NotAfter,HasPrivateKey,Thumbprint,
  @{n='EKU';e={$_.EnhancedKeyUsageList.ObjectId -join ';'}} | Export-Csv "$out\machine-certs.csv" -NoTypeInformation
foreach ($log in 'Microsoft-Windows-WLAN-AutoConfig/Operational','Microsoft-Windows-Wired-AutoConfig/Operational') {
  $safe = ($log -replace '[/\\ ]','_')
  wevtutil epl $log "$out\$safe.evtx" 2>$null
}
(Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard) |
  Select-Object SecurityServicesConfigured,SecurityServicesRunning | Out-File "$out\deviceguard.txt"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```
Pair with NPS: `wevtutil epl Security C:\Temp\nps-security.evtx "/q:*[System[(EventID=6272 or EventID=6273)]]"` and `C:\Windows\System32\LogFiles\IN*.log` accounting logs.
For richer automation use `Windows/Scripts/Get-Windows8021xDiagnostics.ps1`.

---
## Command Cheat Sheet
| Command | Purpose |
|---|---|
| `netsh wlan show interfaces` | Current SSID, BSSID, auth, signal, radio type |
| `netsh wlan show profiles` / `show profile name="X"` | Profile list by source / details |
| `netsh wlan export profile name="X" folder=C:\Temp` | Get profile XML (EAP config, server validation) |
| `netsh wlan show wlanreport` | 3-day HTML connection report |
| `netsh wlan show drivers` | WPA2/WPA3-Enterprise capability |
| `netsh wlan show networks mode=bssid` | Visible SSIDs/APs and security |
| `netsh lan show interfaces` / `show profiles` | Wired 802.1X state and profiles |
| `Set-Service dot3svc -StartupType Automatic; Start-Service dot3svc` | Enable wired supplicant |
| `netsh trace start scenario=wlan capture=no tracefile=C:\Temp\wlan.etl` / `netsh trace stop` | Supplicant ETW trace (`scenario=lan` for wired) |
| `Get-WinEvent -LogName 'Microsoft-Windows-WLAN-AutoConfig/Operational' -MaxEvents 50` | Client auth events (12011/12012/12013, 8001/8002) |
| `Get-WinEvent -LogName 'Microsoft-Windows-Wired-AutoConfig/Operational' -MaxEvents 50` | Wired auth events |
| `dsregcmd /status` | Hybrid vs cloud-only join (drives NPS mapping design) |
| `Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard` | Credential Guard running? |
| `certutil -store My` / `certutil -verify -urlfetch <cert.cer>` | Cert details / chain + revocation check |
| NPS: `Get-WinEvent -FilterHashtable @{LogName='Security';Id=6273}` | Server-side reject reasons |

---
## 🎓 Learning Pointers
- The EAP handshake is end-to-end between supplicant and NPS, so the AP/switch logs rarely explain a TLS failure — look at WLAN event 12013 and NPS 6273 together. Background: [802.1X authenticated wireless access overview](https://learn.microsoft.com/windows-server/networking/technologies/extensible-authentication-protocol/network-access).
- Credential Guard's refusal of MS-CHAPv2 is by design; see [Credential Guard considerations and known issues](https://learn.microsoft.com/windows/security/identity-protection/credential-guard/considerations-known-issues). Plan EAP-TLS rather than weakening CG.
- Strong mapping: [KB5014754](https://support.microsoft.com/topic/kb5014754-certificate-based-authentication-changes-on-windows-domain-controllers-ad2c23b0-15d8-4340-a468-4d4f3b188f16) explains the SID extension and `altSecurityIdentities` strong forms; Intune's SAN SID tag is described in [Configure and use SCEP certificates with Intune](https://learn.microsoft.com/intune/intune-service/protect/certificates-profile-scep).
- Profile settings: [Windows Wi-Fi settings in Intune](https://learn.microsoft.com/intune/intune-service/configuration/wi-fi-settings-windows) and [Wired network settings for Windows](https://learn.microsoft.com/intune/intune-service/configuration/wired-network-settings-windows) — note the server-trust fields map directly to `ServerNames`/`TrustedRootCA` in the XML you exported.
- The cloud-only device gap is a design problem, not a bug; community write-ups (e.g. "Cloud Native PCs Need a Modern Approach to Authentication", mobile-jon.com, Feb 2025) compare shadow-object and cloud-RADIUS approaches.
- Server side of every reject code in this runbook: `Windows/Troubleshooting/NPS-RADIUS-A.md`.
