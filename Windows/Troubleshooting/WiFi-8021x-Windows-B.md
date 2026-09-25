# Windows 802.1X (Enterprise Wi-Fi & Wired, EAP-TLS / PEAP) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Use when:** a Windows 10/11 device won't join the corporate SSID or authenticate on a wired 802.1X port, especially after an Intune Wi-Fi/Wired profile rollout, a certificate change, a Windows feature update, or an NPS/RADIUS change. Deep dive: `WiFi-8021x-Windows-A.md`. Server side: `NPS-RADIUS-B.md`. macOS equivalent: `macOS/Troubleshooting/WiFi-8021x-B.md`.

**Four facts that settle most tickets:**
1. **The client and the RADIUS server fail differently.** If the client doesn't trust the RADIUS server certificate, the NPS log often shows *nothing* useful — the client quits the TLS handshake. Always read **both** sides.
2. **PEAP-MSCHAPv2 + Credential Guard = broken SSO.** Credential Guard (on by default on eligible Windows 11 22H2+ Enterprise/Education devices) blocks MS-CHAPv2 single sign-on and saved credentials. The fix is EAP-TLS, not disabling Credential Guard.
3. **Cloud-only Entra-joined devices have no AD computer object.** NPS maps a *device* certificate to an AD account. No object = reason code 8/16 on NPS. Use user certs for synced users, pre-created AD objects with strong mapping, or a cloud RADIUS.
4. **Strong certificate mapping (KB5014754) is enforced.** Device/user certs used against NPS need the SID extension/SAN tag or an explicit strong `altSecurityIdentities` mapping. Certs issued before the Intune Certificate Connector added the SID won't work.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
```powershell
# 1. Are the supplicant services running? (WlanSvc = Wi-Fi, dot3svc = wired 802.1X, Manual by default)
Get-Service WlanSvc, dot3svc | Select-Object Name, Status, StartType

# 2. Which Wi-Fi profiles exist, and where did they come from? (User / Group policy / MDM)
netsh wlan show profiles

# 3. Last 20 WLAN 802.1X / connection events (12011 start, 12012 success, 12013 failure, 8002 connect failed)
Get-WinEvent -LogName 'Microsoft-Windows-WLAN-AutoConfig/Operational' -MaxEvents 200 |
  Where-Object Id -in 8001,8002,8003,11006,12011,12012,12013 |
  Select-Object -First 20 TimeCreated, Id, @{n='Msg';e={($_.Message -split "`n")[0..6] -join ' | '}} | Format-List

# 4. Machine certs usable for client auth (EKU 1.3.6.1.5.5.7.3.2) with a private key
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.HasPrivateKey -and $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.2' } |
  Select-Object Subject, Issuer, NotAfter, Thumbprint

# 5. Join state + Credential Guard (1 in SecurityServicesRunning = CG running)
dsregcmd /status | Select-String 'AzureAdJoined|DomainJoined|EnterpriseJoined'
(Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).SecurityServicesRunning
```

| Result | Meaning | Do |
|---|---|---|
| `dot3svc` Stopped/Manual, wired port auth fails | Wired supplicant not running → no EAPOL | Fix 1 |
| Corporate SSID missing from #2 | Intune/GPO profile never landed | Fix 2 |
| 12013 "The certificate is not trusted" / "server certificate … validation failed" | Client doesn't trust the NPS cert, or server name mismatch | Fix 3 |
| #4 empty (EAP-TLS machine auth) | No client-auth cert in the machine store | Fix 4 |
| 12013 with "explicit EAP failure received" | RADIUS rejected — go read NPS event 6273 | Fix 5 / Fix 6 |
| PEAP profile + CG running (`1` in #5) + "credentials" prompts loop | Credential Guard blocking MS-CHAPv2 | Fix 7 |
| `AzureAdJoined : YES`, `DomainJoined : NO`, device cert auth | Cloud-only device vs AD-based NPS | Fix 6 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Device authenticates on 802.1X network
└── Switch/AP (authenticator) forwards EAPOL ↔ RADIUS
    └── NPS: Connection Request Policy + Network Policy match (NAS IP registered as RADIUS client, shared secret)
        └── NPS maps credential to an AD account
            ├── EAP-TLS: cert → AD user/computer (strong mapping: SID ext / SAN tag / altSecurityIdentities)
            └── PEAP-MSCHAPv2: username/password → AD account (blocked for SSO by Credential Guard)
        └── NPS server cert: Server Auth EKU, not expired, chain trusted by CLIENT
└── Windows supplicant
    ├── WlanSvc (Wi-Fi) / dot3svc (wired, Automatic) running
    ├── Profile present (Intune Wi-Fi/Wired profile, GPO, or manual) with:
    │   ├── EAP type (13 = EAP-TLS, 25 = PEAP)
    │   ├── Auth mode: machine / user / machine-or-user
    │   ├── Server validation: trusted root(s) + server name(s) that match NPS cert
    │   └── Client cert selection (issuer / EKU filter)
    ├── Trusted root for NPS cert in LocalMachine\Root (Intune Trusted certificate profile)
    └── Client cert (SCEP/PKCS) in LocalMachine\My (machine) or CurrentUser\My (user), private key present
└── Intune delivery: device check-in, profile + cert profiles assigned to the SAME group type (device vs user)
```
</details>

---
## Diagnosis & Validation Flow
1. **Profile content** — `netsh wlan show profile name="<SSID>"`
   Expected: `Authentication: WPA2-Enterprise` (or WPA3-Enterprise), `Cipher: CCMP`, `802.1X` enabled, `EAP type: Microsoft: Smart Card or other certificate` (EAP-TLS) or `Microsoft: Protected EAP (PEAP)`.
   Bad: WPA2-Personal / wrong SSID case → profile wrong at source (Intune).
2. **Server validation settings** — export the profile and inspect:
   ```powershell
   New-Item C:\Temp\wlan -ItemType Directory -Force | Out-Null
   netsh wlan export profile name="<SSID>" folder=C:\Temp\wlan
   Select-String -Path C:\Temp\wlan\*.xml -Pattern 'ServerNames|TrustedRootCA|PerformServerValidation|AuthMode|<Type>'
   ```
   Expected: `ServerNames` matches the NPS cert CN/SAN (e.g. `nps01.contoso.com`), `TrustedRootCA` holds the thumbprint of a root that's actually in `Cert:\LocalMachine\Root`.
   Bad: empty `TrustedRootCA` or a thumbprint not present on the device → Fix 3.
3. **Root present?**
   ```powershell
   Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq '<ThumbprintFromXml>'
   ```
   Nothing returned = the Trusted certificate profile didn't deploy.
4. **Client cert strong-mapping tag** (Intune SCEP/PKCS certs)
   ```powershell
   $c = Get-Item Cert:\LocalMachine\My\<Thumbprint>
   ($c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }).Format($true)   # SAN — look for URL=tag:microsoft.com,2022-09-14:sid:S-1-5-21-…
   $c.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.25.2' }        # NTDS_CA_SECURITY_EXT (SID extension)
   ```
   Neither present → cert predates strong mapping → Fix 4 (reissue).
5. **NPS side** — on the NPS server: `Get-WinEvent -FilterHashtable @{LogName='Security'; Id=6273} -MaxEvents 10` and read *Reason Code*. See Fix 5 table.

---
## Common Fix Paths

<details><summary>Fix 1 — Wired 802.1X: start Wired AutoConfig</summary>

```powershell
Set-Service dot3svc -StartupType Automatic
Start-Service dot3svc
netsh lan show interfaces     # should now show "Authentication state"
netsh lan show profiles
```
Deploy at scale via Intune **Wired network** profile (it sets the service) or a remediation script. Rollback: `Set-Service dot3svc -StartupType Manual`.
</details>

<details><summary>Fix 2 — Profile missing: force Intune sync and check profile status</summary>

```powershell
# Trigger MDM sync (same as Settings > Accounts > Access work or school > Sync)
Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -TaskName 'Schedule #3 created by enrollment client' -ErrorAction SilentlyContinue | Start-ScheduledTask
# MDM-delivered Wi-Fi profiles show as policy profiles in:
netsh wlan show profiles
```
In Intune: Devices > Configuration > <Wi-Fi profile> > Device status. A Wi-Fi profile stuck **Pending** (or erroring) while the device otherwise checks in usually means a dependency (Trusted cert or SCEP/PKCS profile) hasn't applied — the Wi-Fi profile references them and waits. Assign Wi-Fi, trusted cert and client cert profiles to the **same** group type (all device groups for machine auth).
</details>

<details><summary>Fix 3 — Client doesn't trust the RADIUS server certificate</summary>

1. On NPS, find the cert in use: NPS console > Network Policies > <policy> > Constraints > Authentication Methods > EAP type > Edit — note the issuer.
2. Deploy that issuing chain's **root** to devices via an Intune *Trusted certificate* profile (device context).
3. In the Wi-Fi/Wired profile, set **Certificate server names** to the exact CN/SAN DNS of the NPS cert(s) and select that root under **Root certificates for server validation**.
4. Quick local test only (never as the fix): import the root manually.
```powershell
Import-Certificate -FilePath C:\Temp\<Root>.cer -CertStoreLocation Cert:\LocalMachine\Root
```
Rollback of manual import: `Remove-Item Cert:\LocalMachine\Root\<Thumbprint>`.
**Do not** turn off server validation — that exposes users to evil-twin credential capture.
</details>

<details><summary>Fix 4 — No usable client certificate / cert lacks strong mapping</summary>

```powershell
# Show all machine certs with EKUs to see what's actually there
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, NotAfter, HasPrivateKey,
  @{n='EKU';e={$_.EnhancedKeyUsageList.FriendlyName -join ','}}, Issuer
```
- Missing → SCEP/PKCS profile not applied: check its device status in Intune; for SCEP check NDES/Intune Certificate Connector (`Intune/Troubleshooting/Certificates-B.md`).
- Present but no SID tag/extension → confirm Intune Certificate Connector is current, then **reissue**: in the SCEP profile, bump a trivial setting (e.g. validity) or remove/re-add assignment so certs renew. Deleting the cert locally is *not* enough; Intune re-requests on next policy evaluation only if the profile state changes.
- Machine auth needs the cert in **LocalMachine\My** (device-context profile). A user-context cert in CurrentUser\My can't be used before sign-in.
</details>

<details><summary>Fix 5 — RADIUS rejects: read NPS reason code</summary>

On the NPS server:
```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=6273} -MaxEvents 20 |
  ForEach-Object { $x=[xml]$_.ToXml(); [pscustomobject]@{
    Time=$_.TimeCreated
    User=($x.Event.EventData.Data | ? Name -eq 'SubjectUserName').'#text'
    Policy=($x.Event.EventData.Data | ? Name -eq 'NetworkPolicyName').'#text'
    Reason=($x.Event.EventData.Data | ? Name -eq 'Reason').'#text'
    Code=($x.Event.EventData.Data | ? Name -eq 'ReasonCode').'#text' } } | Format-Table -Auto
```
| Code | Meaning | Action |
|---|---|---|
| 8 | Account doesn't exist | Cloud-only device / wrong identity → Fix 6 |
| 16 | Credentials mismatch | PEAP: bad password; EAP-TLS: frequently a failed (weak) cert mapping → Fix 4 / Fix 6 |
| 22 | EAP type not processed | Client and NPS policy EAP types differ (PEAP vs TLS) — align |
| 23 | Error in EAP session | TLS failure — client/server cert chain, revocation, or client cert rejected |
| 48 | No matching network policy | Conditions (group, NAS port type) don't match — check computer/user is in the policy group |
| 49 | No matching connection request policy | CRP conditions — see `NPS-RADIUS-B.md` |
| 265 | Cert chain to untrusted root | Client cert's issuing root not in NPS `LocalMachine\Root` / NTAuth |
| 262 / revocation | CRL unreachable from NPS | Publish/refresh CRL, check CDP reachability from NPS |
</details>

<details><summary>Fix 6 — Cloud-only Entra-joined devices against on-prem NPS</summary>

NPS authenticates against AD. Pick one (decision, not a quick toggle — record it on the ticket):
1. **User-based EAP-TLS** (users synced from AD): profile Auth mode = *User*; user SCEP/PKCS cert in CurrentUser\My with the SID tag. Trade-off: no network before sign-in.
2. **Pre-created AD computer objects** (dummy objects, name = Entra device ID or hostname) with strong `altSecurityIdentities` mapping (`X509:<I>IssuerDN<SR>SerialReversed` or `X509:<SKI>…`). Requires automation to keep in sync; community tooling exists but it's unsupported by Microsoft.
3. **Cloud RADIUS** that trusts Intune/Entra device identity natively.
Escalate to the network/identity owner — this is an architecture choice.
</details>

<details><summary>Fix 7 — PEAP-MSCHAPv2 broken by Credential Guard</summary>

Confirm: CG running (`SecurityServicesRunning` contains `1`) and profile EAP type = PEAP with MSCHAPv2 inner method.
- **Right fix:** move the SSID to EAP-TLS (Intune SCEP/PKCS + new Wi-Fi profile), run both SSIDs in parallel during migration.
- **Stop-gap:** users enter credentials each connection (no saved creds), or the profile uses PEAP-TLS.
- Disabling Credential Guard to rescue MSCHAPv2 weakens credential theft protection — only with documented risk acceptance (`VBS-CredentialGuard-B.md`).
</details>

<details><summary>Fix 8 — Remove a stale/conflicting local profile</summary>

```powershell
netsh wlan show profiles
netsh wlan delete profile name="<SSID>" interface="<Wi-Fi>"   # only user/manual profiles; GPO/MDM ones are read-only
```
Group Policy profiles show as *read only* and win over manual ones — fix at the GPO (Computer Configuration > Policies > Windows Settings > Security Settings > Wireless Network (IEEE 802.11) Policies). If both GPO and Intune push the same SSID, pick one source. Rollback: recreate the manual profile with `netsh wlan add profile filename=<exported.xml>`.
</details>

---
## Escalation Evidence
```
Ticket: __________   Device: __________   User: __________
Join state (dsregcmd): AzureAdJoined __ / DomainJoined __
Medium: Wi-Fi / Wired     SSID or switch port: __________
Profile source (User / GPO / MDM): __________   EAP type: __________   Auth mode: __________
Client cert thumbprint / issuer / NotAfter: __________   SID tag present: Y / N
NPS server name(s) in profile: __________   Trusted root thumbprint present locally: Y / N
Credential Guard running: Y / N
Client event (12013/8002) time + text: __________
NPS 6273 Reason Code + Network Policy name: __________
Recent change (cert rollover, feature update, NPS cert renewal, profile edit): __________
Attached: wlan-report-latest.html, exported profile XML, Get-Windows8021xDiagnostics CSV, NPS 6273 export
```

---
## 🎓 Learning Pointers
- If NPS logged nothing at all, the failure was almost certainly **client-side server validation**; renewing the NPS certificate from a different CA is the classic trigger. Read: [Configure certificate templates for PEAP and EAP requirements](https://learn.microsoft.com/windows-server/networking/technologies/extensible-authentication-protocol/network-access).
- `netsh wlan show wlanreport` builds `C:\ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html` with three days of connection sessions and reason codes — attach it to every Wi-Fi escalation.
- Credential Guard and MS-CHAPv2: [Credential Guard considerations and known issues](https://learn.microsoft.com/windows/security/identity-protection/credential-guard/considerations-known-issues) — the reason PEAP-MSCHAPv2 fleets quietly broke after Windows 11 22H2.
- Strong mapping and Intune certs: [KB5014754 certificate-based authentication changes](https://support.microsoft.com/topic/kb5014754-certificate-based-authentication-changes-on-windows-domain-controllers-ad2c23b0-15d8-4340-a468-4d4f3b188f16) and the Intune SCEP/PKCS docs on the SID SAN tag.
- Intune profile settings reference: [Windows Wi-Fi settings in Intune](https://learn.microsoft.com/intune/intune-service/configuration/wi-fi-settings-windows) and [Wired network settings for Windows](https://learn.microsoft.com/intune/intune-service/configuration/wired-network-settings-windows).
