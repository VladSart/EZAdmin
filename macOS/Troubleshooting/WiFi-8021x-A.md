# macOS Wi-Fi / 802.1X Enterprise — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Enterprise Wi-Fi (WPA/WPA2-Enterprise, WPA3-Enterprise) profile deployment to macOS via Intune
- Wired 802.1X network profile deployment to macOS via Intune (a separate profile type from Wi-Fi,
  same underlying EAP concepts)
- EAP types supported for Apple platforms: EAP-TLS, PEAP, EAP-TTLS, EAP-FAST, LEAP, EAP-SIM
- The certificate dependency chain (Trusted certificate profile + SCEP/PKCS certificate profile) that
  Enterprise/802.1X security types require underneath the network profile itself
- Deployment channel (User vs. Device) architecture and its keychain implications

**Does not cover:**
- Basic/Personal Wi-Fi profiles (WPA/WPA2/WPA3-Personal, pre-shared key) — these have no certificate
  dependency and are out of scope for this cert-focused runbook
- RADIUS/NPS server-side configuration, on-prem NDES health, or certificate template/CA administration
  — this repo's macOS scope covers the client-side symptom only; see `Windows/Troubleshooting/`
  certificate services content and `Windows/Troubleshooting/NPS-RADIUS-A.md`/`-B.md` for RADIUS
  server-side administration and troubleshooting
- Switch/access-point-side 802.1X port configuration (RADIUS client definitions, VLAN assignment on
  authorization) — outside Intune's control entirely
- Per-app VPN and IKEv2 VPN profiles — a related but architecturally distinct network profile type;
  Apple's native VPN client does not support per-app VPN over IKEv2 at all (only third-party VPN
  clients with a Network Extension support per-app VPN on macOS)

**Assumptions:**
- Devices are Intune-enrolled (any supported enrollment type — Enterprise/802.1X profiles are not
  restricted to supervised/ADE-enrolled devices, unlike Recovery Lock)
- An existing PKI (internal CA via NDES/SCEP, or a third-party PKCS-capable CA connector) is already
  issuing certificates successfully to other platforms; this runbook assumes that infrastructure exists
  and focuses on the macOS-side profile/certificate delivery and consumption

---
## How It Works

<details><summary>Full architecture — the three-profile dependency and why it exists</summary>

### Why Enterprise/802.1X needs three separate profiles, not one

Unlike a Personal/PSK Wi-Fi network (a single shared password, no certificates involved), an
Enterprise or 802.1X network authenticates using **EAP (Extensible Authentication Protocol)**, which
in most real deployments (EAP-TLS, and the certificate-based paths of PEAP/EAP-TTLS) requires mutual
certificate trust: the device must trust the RADIUS server's certificate, AND the RADIUS server must
be able to validate an identity certificate presented by the device. Apple's device management
protocol represents this as three independent payload types that must all land on the device and
target the same scope:

1. **Wi-Fi (or Wired network) configuration profile** — the SSID/network name, security type, EAP
   type, and pointers to the other two profiles (by reference, not by embedding)
2. **Trusted certificate profile** — the Root/Intermediate CA certificate(s) of your internal or
   third-party CA that signed the RADIUS server's certificate. This is what lets the Mac trust the
   RADIUS server during the EAP handshake.
3. **SCEP or PKCS certificate profile** — issues a per-device or per-user client identity certificate
   that the Mac presents to the RADIUS server as proof of identity.

Intune profiles reference each other by pointer (the Wi-Fi profile's "Root certificate for server
validation" field points at a specific Trusted certificate profile object; its "Certificates" field
under EAP-TLS/PEAP/EAP-TTLS points at a specific SCEP/PKCS profile object) rather than embedding
certificate content directly. If any referenced profile isn't assigned to the same device/user group
as the Wi-Fi/Wired profile, the reference resolves to nothing on that particular device, and
authentication fails with no obvious error in the Intune portal itself — the failure only surfaces in
the local `eapolclient` log on the Mac.

### Deployment channel: User vs. Device, and why it's locked

The **deployment channel** setting on the Wi-Fi/Wired profile determines two things simultaneously:
which keychain (login/user keychain vs. System keychain) the resolved client certificate is expected
to live in, and which type of certificate profile (User-scoped vs. Device-scoped) can satisfy that
EAP-TLS/PEAP/EAP-TTLS "Certificates" field.

- **User channel**: certificates stored in the user's login keychain. Required when your client
  certificate profile is a **user-scoped** SCEP/PKCS profile (certificate subject built from user
  attributes, e.g. UPN). Appropriate for BYOD-adjacent or shared-device scenarios where identity
  should follow the logged-in user, not the hardware.
- **Device channel**: certificates stored in the System keychain. Required when your client
  certificate profile is a **device-scoped** SCEP/PKCS profile (subject built from device attributes,
  e.g. serial number or device ID). Appropriate for corporate-owned, single-user-per-device fleets
  where network access should not depend on who's logged in.

Microsoft's own guidance is explicit that this is a security-relevant choice, not just a convenience
setting: storing a user certificate in the System keychain (which a Device-channel misconfiguration
would effectively require) increases security risk, because the System keychain is accessible to more
processes/contexts than a specific user's login keychain. **The deployment channel cannot be edited
after the profile is created** — Intune enforces this because changing it retroactively would require
re-provisioning where the certificate is stored, which isn't a supported in-place migration. The only
remediation for a wrong initial choice is creating a new profile.

### EAP type selection and Apple-specific quirks

Apple platforms support EAP-TLS, EAP-TTLS, PEAP, EAP-FAST, LEAP, and EAP-SIM for Wi-Fi; wired 802.1X
supports the same EAP type set. In practice, the overwhelming majority of MSP-managed Mac fleets use
one of:

- **EAP-TLS** — certificate-only, no username/password at all. Simplest to reason about for triage:
  if the client cert is valid and trusted, it works; no separate credential to go stale.
- **PEAP** or **EAP-TTLS** with username/password (inner method MS-CHAPv2 typically) — adds an
  Active-Directory-or-Entra-backed credential on top of (optionally) a certificate. More moving parts,
  more failure surfaces (password expiry independent of certificate expiry).

For all cert-based EAP types, the **"Certificate server names"** field lets you pre-declare the
RADIUS/NPS server's certificate common name(s) so the device skips the interactive trust-decision
prompt a user would otherwise see on first connection — critical for a managed fleet where you don't
want end users making trust decisions. Wildcard suffixes (`*.contoso.com`) are supported for
multi-server/load-balanced RADIUS deployments sharing a DNS suffix.

### Wi-Fi vs. Wired (802.1X) as separate Apple profile types

Although both ultimately configure 802.1X-family EAP authentication, Apple's MDM protocol (and
therefore Intune's UI) treats Wi-Fi and Wired network profiles as **entirely separate payload types**.
A Mac with only a Wi-Fi Enterprise profile assigned has no wired 802.1X configuration at all, and vice
versa — there is no shared or inherited configuration between the two, even though the underlying
certificate profiles (Trusted cert, SCEP/PKCS) can be, and usually are, reused across both.

</details>

---
## Dependency Stack

```
Internal or third-party PKI issuing certificates
   (NDES/SCEP server on-prem, or a PKCS-capable CA connector) — server-side, outside Intune's control
        │
Trusted certificate profile (Root/Intermediate CA of the RADIUS/NPS server)
        │
SCEP or PKCS certificate profile (client identity — User-scoped or Device-scoped)
        │
Deployment channel selection on the Wi-Fi/Wired profile
   (User channel ↔ user-scoped cert / login keychain,
    Device channel ↔ device-scoped cert / System keychain — FIXED at profile creation)
        │
Wi-Fi (Enterprise) or Wired (802.1X) network configuration profile
   ├── EAP type (EAP-TLS / PEAP / EAP-TTLS / EAP-FAST / LEAP / EAP-SIM)
   ├── Certificate server name(s) / wildcard suffix
   └── References to the Trusted cert profile + SCEP/PKCS profile above
        │
All profiles assigned to the SAME device/user group scope, device checks in
        │
eapolclient (macOS 802.1X supplicant) performs EAP negotiation with RADIUS/NPS
        │
Network access granted (Wi-Fi association / wired port authorization)
```

Three independently-assignable profiles must resolve to the same device for authentication to
succeed. Because Intune does not warn you if the referenced profiles are out of scope, a group
membership change to any ONE of the three (without updating the others) is the single most common
root cause of "it stopped working after we changed our groups" tickets in this domain.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No network profile appears on device at all | Assignment/scope gap for the Wi-Fi/Wired profile itself | `sudo profiles -P`, then Intune assignment |
| Profile present, no client certificate in keychain | SCEP/PKCS profile not assigned to same group, or issuance failed | `security find-identity -v -p ssl-client`; SCEP/PKCS profile device status |
| Client cert present but trust evaluation fails (`Trust evaluation failed` in eapolclient log) | Trusted certificate profile missing, wrong CA, or stale after RADIUS cert renewal | Compare CA in Trusted cert profile vs. current RADIUS server cert |
| `no client certificate` / `PEER did not provide a certificate` in eapolclient log | Deployment channel / certificate scope (User vs. Device) mismatch | Compare Wi-Fi profile's channel vs. cert profile's scope |
| Works on Wi-Fi, fails on wired (or vice versa) | Only one of the two profile types (Wi-Fi vs. Wired) was ever created/assigned | Confirm a profile exists for the specific interface failing |
| Works at one site, fails at another (same SSID/network name) | Multiple RADIUS/NPS servers, only one covered by Certificate server names field | Check for wildcard suffix vs. hardcoded single hostname |
| Certificate present, was working, suddenly fails everywhere | Client cert expired and renewal didn't complete in time | `security find-identity` expiry date; SCEP profile device status/renewal log |
| Works for some users/devices in the same group, not others | Dynamic group membership evaluation lag, or template/permission gap for only some object types | Entra ID dynamic group rule evaluation; certificate template permissions |
| No error anywhere, connection just times out | Switch/AP-side 802.1X or RADIUS reachability issue — outside Intune scope entirely | Escalate to network team with the eapolclient timeout evidence |

---
## Validation Steps

**1. Confirm the network profile delivered**
```bash
sudo profiles -P | grep -i -E "wifi|8021x|wired"
```
Expected: profile referencing your network name present. Bad: nothing → assignment/scope issue, stop
here and fix that first.

**2. Confirm client certificate identity and expiry**
```bash
security find-identity -v -p ssl-client
```
Expected: a valid identity with an expiry date well in the future. Bad: none, or expired.

**3. Confirm the certificate profile's own device-status in Intune**
```
Intune → Devices → Configuration → <SCEP/PKCS profile> → Device status → this device
```
Expected: `Succeeded`. Bad: `Error`/`Pending` — trace to NDES/template issue server-side.

**4. Confirm the Trusted certificate profile content matches the current RADIUS server cert**
```
Intune → Devices → Configuration → <Trusted certificate profile> → confirm CA cert content
```
Compare against the CA that actually signed the RADIUS/NPS server's current certificate (obtain from
your PKI/network team if not directly visible).

**5. Confirm deployment channel and certificate scope agree**
```
Intune → <Wi-Fi/Wired profile> → Configuration settings → Deployment channel
Intune → <SCEP/PKCS profile> → confirm User-scoped or Device-scoped
```
Expected: User+User or Device+Device. Bad: any mismatch — requires a new profile (see Fix 4 in the
companion B-runbook).

**6. Confirm the actual EAP negotiation outcome locally**
```bash
log show --predicate 'subsystem == "com.apple.eapolclient" OR process == "eapolclient"' --last 30m
```
This is the single most information-dense diagnostic surface available — it reports the specific EAP
failure reason rather than a generic "couldn't join network" message.

**7. Confirm certificate server name / wildcard scoping if multi-RADIUS**
```
Intune → <Wi-Fi/Wired profile> → Certificate server names field
```
Confirm this covers every RADIUS/NPS server hostname in your environment, via explicit listing or a
shared-suffix wildcard.

---
## Troubleshooting Steps (by phase)

### Phase 1: Profile delivery
1. Confirm the Wi-Fi/Wired profile itself reached the device (`sudo profiles -P`).
2. If absent, resolve assignment/group-scope/device-status issues in Intune before assuming anything
   about certificates or EAP.

### Phase 2: Certificate chain integrity
1. Confirm a client identity certificate is present and unexpired
   (`security find-identity -v -p ssl-client`).
2. Cross-check the SCEP/PKCS profile's own device status for issuance errors.
3. Confirm the Trusted certificate profile contains the CA that actually signed the current RADIUS
   server certificate — this drifts silently after any RADIUS-side certificate renewal.

### Phase 3: Configuration coherence
1. Confirm deployment channel (User/Device) matches the certificate profile's scope (User-scoped/
   Device-scoped) — this is a design-time decision that cannot be patched, only replaced.
2. Confirm EAP type configured matches what the RADIUS/NPS server actually expects (EAP-TLS vs. PEAP
   vs. EAP-TTLS) — a mismatch here produces failures that look identical to a certificate problem in
   the eapolclient log unless read carefully.

### Phase 4: Live negotiation diagnosis
1. Capture `eapolclient` logs during a live connection attempt to isolate the exact failure stage
   (trust evaluation vs. missing identity vs. timeout vs. explicit RADIUS reject).
2. A bare timeout with no EAP response at all indicates the problem is on the network/switch/RADIUS
   reachability side, not on the Mac or Intune configuration — escalate accordingly rather than
   continuing to iterate on Intune profiles.

### Phase 5: Multi-site / multi-server considerations
1. For fleets spanning multiple physical sites or RADIUS server pairs, confirm certificate server
   name/wildcard coverage and confirm the Trusted certificate profile includes every relevant CA if
   different sites use different issuing CAs under a shared root.

---
## Remediation Playbooks

<details>
<summary>Playbook 1 — Migrating from PSK/Personal Wi-Fi to Enterprise/802.1X fleet-wide</summary>

**Scenario:** An organization is moving an existing macOS fleet from a shared WPA2-Personal password
to certificate-based Enterprise authentication.

```
1. Confirm PKI issuance capacity and RADIUS/NPS server readiness with the network/PKI team first —
   this is a prerequisite, not something Intune profiles can compensate for
2. Build the Trusted certificate profile (upload current root/intermediate CA)
3. Build the SCEP or PKCS certificate profile, choosing User-scoped or Device-scoped deliberately
   based on whether identity should follow the user or the hardware
4. Build the Wi-Fi Enterprise profile, matching deployment channel to the certificate scope from
   step 3, referencing the Trusted cert profile and SCEP/PKCS profile from steps 2-3
5. Assign all three profiles to a SMALL pilot group first, validate via the Validation Steps above
6. Only after pilot validation, expand assignment to the full fleet — keep the old PSK network
   available in parallel until Enterprise auth is confirmed working, to avoid a connectivity gap
7. Remove the PSK network profile once migration is confirmed complete
```

**Rollback:** Keep the PSK/Personal profile assigned in parallel until Enterprise is fully validated;
removing it prematurely risks a fleet-wide connectivity gap if the certificate chain has an
undiscovered issue.

</details>

<details>
<summary>Playbook 2 — Recovering from a RADIUS/NPS certificate renewal that broke trust fleet-wide</summary>

**Scenario:** The RADIUS/NPS server's certificate was renewed (or its issuing CA rotated), and devices
across the fleet suddenly fail Enterprise/802.1X authentication simultaneously.

```
1. Confirm the failure is fleet-wide and coincides with a known RADIUS-side certificate change
   (check with network/PKI team for renewal timing)
2. Obtain the new RADIUS server certificate's issuing CA chain
3. Update the Trusted certificate profile in Intune with the new root/intermediate CA — this profile
   type supports in-place edits (unlike the Wi-Fi/Wired profile itself)
4. Force a sync across affected devices, or wait for next check-in cycle
5. Validate via eapolclient logs and successful connection on a sample of devices before considering
   the incident resolved fleet-wide
```

**Rollback:** If the new CA upload is incorrect, revert to the previous CA content in the Trusted
certificate profile while the correct chain is obtained — do not leave devices without ANY valid trust
anchor during troubleshooting, as this locks out the entire fleet from the network.

</details>

<details>
<summary>Playbook 3 — Correcting a deployment-channel/certificate-scope mismatch across a fleet</summary>

**Scenario:** A Wi-Fi Enterprise profile was originally built with Device channel selected, but the
organization's PKI only issues user-scoped certificates (or the reverse) — authentication has never
worked correctly for a subset of devices/users.

```
1. Confirm the mismatch via Validation Step 5 above
2. Since deployment channel cannot be edited, create a new Wi-Fi/Wired profile with the CORRECT
   deployment channel matching your actual certificate scope
3. Ensure the certificate profile (User-scoped or Device-scoped, matching) is assigned to the same
   group as the new network profile
4. Assign the new profile to the same group as the old one (both can coexist briefly)
5. Validate connectivity on a pilot subset using the new profile
6. Remove/unassign the old, mismatched profile only after the new one is confirmed working
```

**Rollback:** Keep the old (broken) profile assigned until the new one is validated — removing it
first with no working replacement leaves devices with no Enterprise Wi-Fi/802.1X profile at all.

</details>

---
## Evidence Pack

```powershell
# Run in a PowerShell session with the Microsoft Graph module connected.
# Collects Wi-Fi/Wired (802.1X) profile, certificate profile, and assignment evidence for a
# specific device. Read-only. Use Get-WiFiProfileAudit.ps1 in Scripts/ for the full fleet-wide sweep.

Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All" -NoWelcome

$deviceName = Read-Host "Enter device name"
$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'"

if (-not $device) {
    Write-Host "Device not found." -ForegroundColor Red
} else {
    [PSCustomObject]@{
        DeviceName       = $device.DeviceName
        SerialNumber     = $device.SerialNumber
        OSVersion        = $device.OperatingSystem, $device.OsVersion -join " "
        LastSyncDateTime = $device.LastSyncDateTime
        ManagementState  = $device.ManagementState
    } | Format-List
    Write-Host "Cross-reference this device's group memberships against the Wi-Fi/Wired profile," -ForegroundColor Yellow
    Write-Host "Trusted certificate profile, and SCEP/PKCS profile assignments in the Intune portal" -ForegroundColor Yellow
    Write-Host "to confirm all three resolve to this device. Certificate presence/expiry is only" -ForegroundColor Yellow
    Write-Host "reliably checked locally via 'security find-identity -v -p ssl-client' on the Mac." -ForegroundColor Yellow
}
```

---
## Command Cheat Sheet

| Task | Where |
|---|---|
| Check delivered Wi-Fi/Wired profile on device | `sudo profiles -P \| grep -i -E "wifi\|8021x\|wired"` |
| Check client certificate identity + expiry | `security find-identity -v -p ssl-client` |
| Live EAP negotiation log | `log show --predicate 'process == "eapolclient"' --last 30m` |
| Build Wi-Fi profile | Intune → Devices → Configuration → macOS → Templates → Wi-Fi |
| Build Wired network profile | Intune → Devices → Configuration → macOS → Templates → Wired network |
| Build Trusted certificate profile | Intune → Devices → Configuration → macOS → Trusted certificate |
| Build SCEP/PKCS certificate profile | Intune → Devices → Configuration → macOS → SCEP or PKCS certificate |
| Check any profile's device status | Intune → <profile> → Device status |
| Check deployment channel | Intune → <Wi-Fi/Wired profile> → Configuration settings |
| Check certificate server names/wildcard | Intune → <Wi-Fi/Wired profile> → Certificate server names |
| Force device check-in | Intune → device → Sync |
| Check group/dynamic membership | Entra ID → Groups → <group> → Members / Dynamic membership rules |

---
## 🎓 Learning Pointers

- **Three profiles, one scope — this is the load-bearing architectural fact of this entire topic.**
  The Wi-Fi/Wired network profile, the Trusted certificate profile, and the SCEP/PKCS certificate
  profile must all be assigned to the same device/user group, and Intune does not warn you if they
  drift apart. Most "it just stopped working" tickets trace back to exactly this. [Add Wi-Fi settings to Apple devices](https://learn.microsoft.com/en-us/intune/device-configuration/templates/ref-wifi-settings-apple)

- **Deployment channel is a one-way door, by design.** Microsoft's own guidance frames storing a user
  certificate in the System keychain as an active security risk, which is why the channel can't be
  edited after creation — treat this as a design decision to get right before first deployment, not
  something to patch later. [Configure 802.1X wired network settings for Apple and Windows devices](https://learn.microsoft.com/en-us/intune/intune-service/configuration/wired-networks-configure)

- **`eapolclient` is macOS's 802.1X supplicant and your best local diagnostic tool** — its log output
  distinguishes trust failures from missing-identity failures from RADIUS-side rejects, which the
  Intune portal alone cannot tell you. Learn its log strings; they're the fastest path to a correct
  diagnosis on this topic.

- **Wi-Fi and Wired (802.1X) are separate Apple profile payloads with no shared configuration** — do
  not assume a working Wi-Fi Enterprise profile means wired 802.1X is also configured, or the reverse.
  This repo treats them as one runbook because the certificate architecture is identical, but the
  actual profile objects in Intune are distinct and both must be built if both interfaces are in use.

- **A RADIUS/NPS certificate renewal on the server side is invisible to Intune** and will silently
  break every device's trust evaluation unless someone remembers to update the Trusted certificate
  profile with the new CA — this is worth flagging to any customer's PKI/network team as a required
  step in their own certificate renewal runbook, not just an Intune-side concern.

- **Per-app VPN is a different topic entirely and doesn't apply here.** Apple's native VPN client does
  not support per-app VPN over IKEv2 at all — only third-party VPN clients with a Network Extension
  support per-app VPN on macOS. Don't conflate a Wi-Fi/802.1X certificate issue with a VPN profile
  issue; they use overlapping certificate concepts but are configured as entirely separate Intune
  profile types. [Configure VPN settings for Apple devices](https://learn.microsoft.com/en-us/intune/device-configuration/templates/ref-vpn-settings-apple)
