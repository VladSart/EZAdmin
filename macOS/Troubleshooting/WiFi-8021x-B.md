# macOS Wi-Fi / 802.1X Enterprise — Hotfix Runbook (Mode B: Ops)
> Fix or escalate enterprise Wi-Fi (and wired 802.1X) authentication failures on managed Macs in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Enterprise Wi-Fi (WPA/WPA2-Enterprise with EAP) and wired 802.1X on macOS both fail for the **same
small set of reasons** — almost always a certificate dependency problem, not a Wi-Fi problem. Run
these first, in this order:

```
# 1. Confirm the profile actually landed on the device (device-side, works even if not connected)
sudo profiles -P | grep -i -E "wifi|8021x|wired"
# Expected: a profile referencing your Wi-Fi/wired network name is listed
# Bad: nothing listed → profile never delivered — check assignment/scope in Intune, not the network

# 2. Confirm all THREE dependent profiles exist and target the SAME device/user group
Intune admin center → Devices → Configuration → filter macOS → look for:
   a) Wi-Fi (or Wired network) profile — the one with the SSID/network name
   b) Trusted certificate profile — the Root/Intermediate CA that signs your RADIUS server cert
   c) SCEP or PKCS certificate profile — the client identity cert presented to the RADIUS server
# Bad: any one missing, or assigned to a DIFFERENT group than the others → Fix 1

# 3. Confirm the client certificate actually landed and is valid
sudo profiles -P | grep -i -A3 "certificate"
security find-identity -v -p ssl-client
# Expected: a valid, non-expired identity is listed
# Bad: no identity, or expired → Fix 2 (SCEP issuance failure) or Fix 3 (expired, needs renewal)

# 4. Confirm the deployment channel (user vs. device) matches the certificate type
Intune admin center → <Wi-Fi/Wired profile> → Configuration settings → Deployment channel
# Expected: User channel + a USER certificate profile, OR Device channel + a DEVICE certificate profile
# Bad: mismatched (e.g. Device channel selected but only a user cert profile assigned) → Fix 4
#      NOTE: deployment channel CANNOT be edited after the profile is created — a mismatch requires
#      building a brand-new profile, not editing the existing one.

# 5. Check the actual join/auth failure on the Mac itself
log show --predicate 'subsystem == "com.apple.eapolclient" OR process == "eapolclient"' --last 30m
# Look for the specific EAP failure reason (cert not trusted, identity mismatch, timeout to RADIUS)
```

**Interpretation table:**

| Finding | Action |
|---|---|
| No profile shows on device at all | Assignment/scope problem — check group membership and profile status in Intune first |
| Profile present, but no client certificate present/valid | Fix 2 (SCEP/PKCS issuance failure) |
| Profile + valid cert present, but connection still fails | Fix 1 (root/trust chain) or Fix 5 (RADIUS server name / wildcard mismatch) |
| Deployment channel doesn't match certificate type | Fix 4 — requires a new profile, not an edit |
| Certificate present but expired or expiring soon | Fix 3 (renewal / SCEP re-issuance) |
| Works over Wi-Fi in one location but not another (same SSID) | Check for a second RADIUS server/NPS instance with a different or missing CA trust — Fix 1 |
| Was working, broke after a CA renewal at the RADIUS/NPS server | Fix 1 — Trusted certificate profile is now stale, must be updated with the new root/intermediate |
| Wired (802.1X) only, Wi-Fi fine (or vice versa) | Confirm you have a SEPARATE profile per platform/interface — a Wi-Fi profile does not cover wired 802.1X and vice versa |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Trusted Root/Intermediate CA of the RADIUS/NPS server
   (delivered via a Trusted certificate profile, assigned to the SAME group)
        │
        ▼
Client identity certificate
   (delivered via SCEP or PKCS certificate profile — User cert if User channel,
    Device cert if Device channel — must match the Wi-Fi/Wired profile's channel)
        │
        ▼
Wi-Fi (Enterprise) or Wired (802.1X) configuration profile
   ├── Deployment channel: User or Device (FIXED at creation — cannot be edited later)
   ├── EAP type: EAP-TLS (cert-only) / PEAP / EAP-TTLS (cert + user/pass) / EAP-FAST
   ├── Certificate server name(s) — RADIUS server CN(s), supports wildcard suffix
   └── Root certificate for server validation — points at the Trusted certificate profile above
        │
        ▼
All three profiles assigned to the SAME device/user group, device checks in and applies all three
        │
        ▼
On connect: device presents client cert → RADIUS validates against its own CA →
   RADIUS cert validated by device against the Trusted root profile → EAP tunnel established
        │
        ▼
Network access granted (Wi-Fi association completes / wired port authorizes)
```

**Key concept:** this is a three-legged stool. A Wi-Fi/Wired profile with no matching certificate
profiles does nothing useful for Enterprise/802.1X security types (only Personal/PSK works without
certs). All three legs must be assigned to identical scope — a common failure is updating the
certificate profile's target group but forgetting to update the Wi-Fi profile's group, or vice versa.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the network profile delivered to the device**
```bash
sudo profiles -P | grep -i -E "wifi|8021x|wired"
```
Nothing found → stop diagnosing the network layer, go check Intune assignment/device status first.

**Step 2 — Confirm the certificate chain landed**
```bash
security find-identity -v -p ssl-client
sudo profiles -P | grep -i -B2 -A5 "certificate"
```
No identity, or the identity's issuer doesn't match your internal CA → SCEP/PKCS issuance failed
(Step 3) or the Trusted certificate profile for the root CA never delivered (Fix 1).

**Step 3 — Confirm SCEP/PKCS issuance succeeded in Intune**
```
Intune admin center → Devices → Configuration → <SCEP or PKCS profile> → Device status
```
Look at this device's row: `Succeeded`, `Pending`, or `Error`. SCEP errors here almost always trace
back to NDES (Network Device Enrollment Service) health on-prem — see `Windows/Troubleshooting/`
certificate services content for NDES-side diagnosis; this repo's macOS scope covers only the
client-side symptom.

**Step 4 — Confirm deployment channel / certificate type match**
```
Intune admin center → <Wi-Fi/Wired profile> → Configuration settings → Deployment channel
Intune admin center → <cert profile> → check it is scoped as User or Device
```
Mismatch → Fix 4 (new profile required, cannot edit existing).

**Step 5 — Confirm the actual EAP negotiation failure reason**
```bash
log show --predicate 'subsystem == "com.apple.eapolclient" OR process == "eapolclient"' --last 30m
```
Common strings to look for: `Trust evaluation failed` (root cert issue), `no client certificate`
(identity/SCEP issue), `PEER did not provide a certificate` (deployment channel/cert type mismatch),
or a timeout with no EAP response at all (network/switch-side 802.1X config, outside Intune's scope).

**Step 6 — Confirm RADIUS server name / wildcard scoping**
```
Intune admin center → <Wi-Fi/Wired profile> → Certificate server names
```
If you have multiple RADIUS/NPS servers behind a load balancer or in multiple sites with different
hostnames but a shared DNS suffix, confirm a wildcard (e.g. `*.contoso.com`) was used rather than a
single hardcoded hostname — a hardcoded name only matches one server and fails silently at others.

---
## Common Fix Paths

<details><summary>Fix 1 — Root/trust chain broken or stale (RADIUS CA renewed, trust profile not updated)</summary>

**Cause:** The Trusted certificate profile on the Mac still contains an old root/intermediate CA cert,
but the RADIUS/NPS server started presenting a certificate signed by a renewed or replaced CA.

```
# 1. Confirm which CA actually signed the current RADIUS server certificate (ask your PKI/NPS admin,
#    or pull it from the NPS server's bound certificate)
# 2. Compare against the CA cert(s) in your Intune Trusted certificate profile
Intune admin center → Devices → Configuration → <Trusted certificate profile> → confirm cert content
# 3. If mismatched, upload the current root/intermediate CA cert(s) to the Trusted certificate profile
#    (edit in place is supported for Trusted certificate profiles, unlike the Wi-Fi/Wired profile itself)
# 4. Re-sync affected devices
Intune admin center → device → Sync
```

**Rollback:** Keep the previous CA cert in the profile alongside the new one during a transition window
if the RADIUS server is mid-rollover and may still present the old cert to some clients; remove once
rollover is fully complete.

</details>

<details><summary>Fix 2 — No client certificate present (SCEP/PKCS issuance failure)</summary>

**Cause:** The certificate profile never successfully issued a client identity certificate to the
device — most commonly an NDES/SCEP server reachability or template-permission issue on-prem, or an
expired SCEP profile challenge validity period.

```
# 1. Check the certificate profile's own device status in Intune
Intune admin center → Devices → Configuration → <SCEP/PKCS profile> → Device status → this device
# 2. If Error, open the row for the specific failure code
# 3. Common root causes (verify with your PKI/NDES admin, not fixable from the Mac):
#    - NDES server unreachable or its service certificate expired
#    - Certificate template permissions missing for the device/user object
#    - SCEP challenge validity period (default short window) expired before device processed it
# 4. Force a device sync to retry issuance after the underlying NDES/template issue is fixed
Intune admin center → device → Sync
```

**Rollback:** N/A — reissuance retry, not destructive.

</details>

<details><summary>Fix 3 — Client certificate present but expired or expiring imminently</summary>

**Cause:** SCEP/PKCS certificates have a defined validity period and Intune's automatic renewal window
(typically triggers renewal at ~20% of validity remaining) either hasn't fired yet or failed silently.

```
# 1. Check current expiry
security find-identity -v -p ssl-client
# 2. Confirm Intune sees the same expiry and whether a renewal attempt is logged
Intune admin center → Devices → Configuration → <SCEP/PKCS profile> → Device status
# 3. Force a sync to trigger a renewal check
Intune admin center → device → Sync
# 4. If renewal doesn't occur well before expiry, treat as a Fix 2-style issuance problem and escalate
#    to PKI/NDES team
```

**Rollback:** N/A — no destructive action; renewal replaces the cert in place.

</details>

<details><summary>Fix 4 — Deployment channel / certificate type mismatch</summary>

**Cause:** The Wi-Fi/Wired profile was created with, e.g., Device channel selected, but only a User
certificate profile is assigned (or vice versa). This is NOT editable after profile creation.

```
# There is no in-place fix — deployment channel is locked at creation. Remediation:
# 1. Create a NEW Wi-Fi/Wired profile with the correct deployment channel matching your available
#    certificate type
# 2. Assign the new profile (and confirm the matching cert profile scope) to the same group
# 3. Once devices confirm the new profile succeeded, delete/unassign the old mismatched profile
```

**Rollback:** Keep the old profile assigned until the new one is confirmed working fleet-wide, then
remove — do not delete the old profile first, or devices lose network connectivity in the gap.

</details>

<details><summary>Fix 5 — RADIUS server name / wildcard mismatch</summary>

**Cause:** The "Certificate server names" field lists a single hardcoded RADIUS hostname, but the
environment has multiple RADIUS/NPS servers with different hostnames (load-balanced or multi-site).

```
# 1. Identify the actual common name(s) used across all RADIUS/NPS servers in scope
# 2. Update the Wi-Fi/Wired profile's Certificate server names to either:
#    - List every server name individually, or
#    - Use a wildcard suffix if all servers share a DNS suffix, e.g. *.contoso.com
Intune admin center → <Wi-Fi/Wired profile> → Configuration settings → Certificate server names
# 3. Re-sync affected devices
```

**Rollback:** Revert to the previous server name list if the wildcard is scoped too broadly and
unexpectedly trusts an unintended server (rare, but worth a sanity check in shared-suffix environments).

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — macOS Wi-Fi/802.1X Enterprise Authentication Issue
=====================================
Device Name:                 [hostname]
Serial Number:                [Intune → device → Hardware → Serial number]
macOS Version:                [sw_vers -productVersion]
Interface:                    [Wi-Fi | Wired (802.1X)]
Network/SSID name:            [network name]

Profile present on device (sudo profiles -P):        [Yes/No]
Client certificate present (security find-identity):  [Yes/No + expiry date]
SCEP/PKCS profile device status:                       [Succeeded | Pending | Error]
Trusted certificate profile device status:             [Succeeded | Pending | Error]
Deployment channel configured:                         [User | Device]
Certificate profile type assigned:                     [User cert | Device cert]
EAP type:                                              [EAP-TLS | PEAP | EAP-TTLS | EAP-FAST | LEAP]

eapolclient log excerpt (log show --predicate 'process == "eapolclient"' --last 30m):
[paste relevant failure line]

Steps already attempted:
[ ] Confirmed profile delivered to device
[ ] Confirmed client certificate present and valid
[ ] Confirmed all three profiles (network, trust, client cert) target the same group
[ ] Confirmed deployment channel matches certificate type
[ ] Checked eapolclient log for specific EAP failure reason
[ ] Verified RADIUS server name/wildcard scoping
```

---
## 🎓 Learning Pointers

- **It's almost never the Wi-Fi/Wired profile itself — it's the certificate chain underneath it.**
  Enterprise/802.1X security types on macOS depend on a Trusted certificate profile (server trust) and
  a SCEP/PKCS certificate profile (client identity), both deployed to the same group as the network
  profile. Triage the certificates first; the network profile is usually fine. [Configure Wi-Fi settings for Apple devices](https://learn.microsoft.com/en-us/intune/device-configuration/templates/ref-wifi-settings-apple)

- **Deployment channel is a one-way door.** Unlike almost every other Intune profile setting, the
  User vs. Device channel choice on a Wi-Fi/Wired profile cannot be edited after creation — a wrong
  choice means building a new profile, not fixing the old one. Get this right before first deployment,
  especially when migrating from a device-cert to a user-cert PKI design later. [Configure 802.1X wired network settings](https://learn.microsoft.com/en-us/intune/device-configuration/templates/configure-wired-networks)

- **Wi-Fi and wired 802.1X are two separate profile types on macOS**, even though they share the same
  EAP/certificate concepts underneath. A device failing wired but succeeding over Wi-Fi (or vice versa)
  is not evidence the certificate chain is broken — check whether a profile actually exists for the
  interface that's failing.

- **`eapolclient` is the single most useful local diagnostic surface** on macOS for any 802.1X-family
  auth failure — it reports the specific EAP failure reason (trust failure vs. missing identity vs.
  timeout) that the Intune portal alone won't show you.

- **A working profile can break silently after a RADIUS/NPS certificate renewal** if nobody updates
  the Trusted certificate profile with the new CA — this is one of the most common "it worked
  yesterday" tickets in this domain and has nothing to do with the Mac or Intune configuration itself.
