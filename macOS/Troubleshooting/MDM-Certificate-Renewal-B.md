# macOS MDM Certificate Renewal — Hotfix Runbook (Mode B: Ops)
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

Run these first on the affected Mac (Terminal, as admin user):

```bash
# 1. Check MDM enrollment status
profiles status -type enrollment

# 2. Check MDM certificate expiry
security find-certificate -a -c "APNS" /Library/Keychains/System.keychain 2>/dev/null | grep -A2 "not after"

# 3. Check Intune Company Portal status
/usr/local/bin/intune_dbutil dump | grep -i "certificate\|expir\|enroll" 2>/dev/null || \
  mdmclient QueryDeviceInformation 2>&1 | grep -i "enroll\|certif"

# 4. Check system keychain for MDM identity cert
security find-identity -v -p ssl /Library/Keychains/System.keychain | head -20

# 5. Recent MDM errors in logs
log show --last 1h --predicate 'subsystem == "com.apple.mdmclient"' | grep -i "error\|fail\|expired" | tail -30
```

**Interpretation:**

| Result | Meaning | Action |
|--------|---------|--------|
| `profiles status` shows `Not enrolled` | MDM profile removed or cert expired | Fix Path 1 or 2 |
| Certificate "not after" date is in the past | MDM Identity cert expired | Fix Path 2 |
| `mdmclient` returns auth errors | Push cert or identity cert issue | Fix Path 3 |
| `log show` shows "expired" repeatedly | Active cert expiry, re-enrol required | Fix Path 1 |
| `profiles status` shows enrolled, no errors | MDM is healthy — check Intune portal | Fix Path 4 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Apple Push Notification Service (APNs)
        │  valid APNs certificate on Intune tenant (renewed annually)
        ▼
Intune MDM Service (manage.microsoft.com)
        │  sends push payload via APNs
        ▼
MDM Push Notification → Mac device
        │
        ▼
MDM Client (mdmclient) on macOS
        │  uses MDM Identity Certificate to authenticate
        ▼
MDM Identity Certificate (in System.keychain)
        │  issued to device at enrollment; has expiry (~1 year for SCEP/manual, longer for ADE)
        ▼
Device Management Profile (in /Library/Managed Preferences)
        │  contains MDM server URL, topic (APNs bundle ID)
        ▼
Policy Delivery (Intune policies, profiles, apps, scripts)
```

**Three certificates to track:**
1. **APNs Certificate** — held by Intune tenant, renewed in Intune admin center (not on device)
2. **MDM Identity Certificate** — device-specific, lives in System.keychain, renewed automatically if device can reach MDM
3. **SCEP/PKCS Client Certificate** — for Wi-Fi/VPN auth; managed by Intune SCEP profile separately

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm enrollment state**
```bash
profiles status -type enrollment
```
Expected: `Enrolled via MDM: Yes`  
If `No`: skip to Fix Path 1.

**Step 2 — Check for MDM Identity Certificate in keychain**
```bash
security find-identity -v /Library/Keychains/System.keychain | grep -i "mdm\|management\|intune"
```
Expected: At least one valid identity listed.  
If empty or expired: Fix Path 2.

**Step 3 — Test connectivity to MDM endpoint**
```bash
curl -v --max-time 10 https://enrollment.manage.microsoft.com/ 2>&1 | grep -E "connected|SSL|error|failed"
```
Expected: TLS handshake succeeds (`SSL connection using TLS...`).  
If failed: network/proxy issue — Fix Path 5.

**Step 4 — Trigger MDM check-in manually**
```bash
sudo mdmclient MDMStatus
# Or for a full re-check:
sudo mdmclient CheckIn
```
Expected: `MDM response: Acknowledged`  
If errors: note the error code and proceed to fix paths.

**Step 5 — Verify APNs reachability**
```bash
# APNs uses port 443 and 2195/2196 (legacy); test port 443
nc -zv gateway.push.apple.com 443
nc -zv feedback.push.apple.com 443
```
Expected: `Connection to ... succeeded`  
If failed: APNs blocked by firewall/proxy — Fix Path 5.

**Step 6 — Check Intune portal (parallel — do this from admin workstation)**
- Intune > Devices > macOS > [device] > check **Last check-in** and **Compliance state**
- Intune > Tenant Administration > Connectors and tokens > Apple MDM Push Certificate — check expiry

---

## Common Fix Paths

<details><summary>Fix 1 — Re-enrol device (MDM profile missing or expired)</summary>

**When to use:** `profiles status` shows `Not enrolled`; device needs to be brought back under management.

**Prerequisites:** User has Intune Company Portal app installed, or admin has device in ADE/DEP.

**Option A — Company Portal re-enrolment (non-ADE)**
1. Open **Company Portal** app on Mac
2. Sign in with user's Entra ID account
3. Follow on-screen enrolment steps
4. After completing: `profiles status -type enrollment` should show enrolled

**Option B — Manual profile install**
1. Admin: Download the MDM enrolment profile from Intune (Devices > Enrolment > Apple > Enrolment Program Tokens, or use the BYOD enrolment URL)
2. Transfer to device, double-click `.mobileconfig` to install
3. Go to System Settings > Privacy & Security > Profiles — approve the MDM profile
4. Confirm: `profiles status -type enrollment`

**Option C — ADE/DEP device — remote wipe and re-provision**
```bash
# Only if device is ADE-assigned and wiping is acceptable
# This must be triggered from Intune portal, not terminal
# Intune > Devices > [device] > Wipe
```
⚠️ This erases user data. Confirm backup before proceeding.

</details>

<details><summary>Fix 2 — Renew MDM Identity Certificate (expired, device still enrolled)</summary>

**When to use:** Device shows as enrolled but Intune reports stale check-in; keychain shows expired MDM cert.

**Option A — Force automatic renewal via mdmclient (preferred)**
```bash
sudo mdmclient RenewDeviceCertificate
# Wait 30-60 seconds then check:
security find-identity -v /Library/Keychains/System.keychain | grep -i mdm
```
If successful: new cert appears with future expiry.

**Option B — Remove and re-add MDM profile**
```bash
# Step 1: List management profile UUID
profiles show -type enrollment

# Step 2: Remove (requires admin auth)
sudo profiles remove -identifier <ProfileIdentifier>

# Step 3: Re-enrol via Company Portal or BYOD URL
# Then verify:
profiles status -type enrollment
```
⚠️ Removing MDM profile will temporarily remove all managed preferences. Policies re-apply within minutes of re-enrolment.

**Rollback:** If removal causes problems, re-enrol immediately via Company Portal.

</details>

<details><summary>Fix 3 — APNs Certificate expired on Intune tenant (tenant-wide impact)</summary>

**When to use:** Multiple Macs simultaneously lose MDM connectivity; Intune shows "APNs certificate expired" warning.

⚠️ This is a **tenant-level operation** — affects ALL managed iOS and macOS devices. Perform with change control.

**Identify:**
- Intune portal > Tenant administration > Connectors and tokens > Apple MDM Push certificate
- Check expiry date — if expired, this is the cause

**Renew (must be done by Global Admin or Intune Administrator):**
1. Go to Intune portal > Tenant administration > Connectors and tokens > Apple MDM Push certificate
2. Click **Renew**
3. Download the CSR file Intune generates
4. Go to [Apple Push Certificates Portal](https://identity.apple.com/pushcert) — log in with the **same Apple ID** used originally (critical — different Apple ID = different certificate = all devices lose management)
5. Find the existing certificate, click **Renew** (not Create)
6. Upload the CSR from step 3
7. Download the `.pem` file Apple provides
8. Back in Intune, upload the `.pem` file
9. Confirm new expiry date shows ~1 year out

**After renewal:** devices receive MDM push within 15-30 minutes. If devices don't reconnect, trigger manual check-in:
```bash
sudo mdmclient CheckIn
```

**If wrong Apple ID was used:** All devices must be re-enrolled. This is a major incident. Escalate to Intune support.

</details>

<details><summary>Fix 4 — MDM enrolled but policies not applying</summary>

**When to use:** `profiles status` shows enrolled, Intune shows checked-in, but specific profiles/policies missing.

```bash
# Check what profiles are currently installed
profiles show -type configuration

# Check managed preferences
ls /Library/Managed\ Preferences/

# Force an MDM policy refresh
sudo mdmclient CheckIn
sleep 30
profiles show -type configuration
```

Also check in Intune portal:
- Device > Configuration profiles — all profiles should show "Succeeded"
- If any show "Error" — click the profile to see which setting failed

**Common cause:** Profile targeting wrong group, or a compliance-blocking policy preventing profile delivery.

</details>

<details><summary>Fix 5 — Network/proxy blocking MDM or APNs</summary>

**When to use:** mdmclient returns network errors; APNs port test fails; corporate proxy intercepting traffic.

**Required endpoints (must be allowed through proxy/firewall):**
```
*.manage.microsoft.com          443/TCP
enrollment.manage.microsoft.com 443/TCP
gateway.push.apple.com          443/TCP (or 2195, legacy)
feedback.push.apple.com         443/TCP (or 2196, legacy)
*.apple.com                     443/TCP
deviceenrollment.apple.com      443/TCP
```

**Check proxy settings on Mac:**
```bash
scutil --proxy
networksetup -getwebproxy "Wi-Fi"
networksetup -getsecurewebproxy "Wi-Fi"
```

**If proxy is intercepting APNs TLS:** APNs uses certificate pinning — proxy SSL inspection WILL break this. APNs traffic must be excluded from SSL inspection in the proxy/firewall policy.

**Test without proxy:**
```bash
# Temporarily unset proxy and test
networksetup -setwebproxystate "Wi-Fi" off
sudo mdmclient CheckIn
# Re-enable after test
networksetup -setwebproxystate "Wi-Fi" on
```

</details>

---

## Escalation Evidence

```
TICKET: macOS MDM Certificate / Enrolment Issue
========================================================
Date/Time:        _______________
Raised by:        _______________
Device name:      _______________
macOS version:    _______________
Serial number:    _______________
User:             _______________
Tenant:           _______________

Enrollment status (profiles status -type enrollment):
_______________________________________________

Last Intune check-in (from portal):
_______________________________________________

MDM identity cert status (security find-identity output):
_______________________________________________

APNs cert expiry in Intune portal:
_______________________________________________

mdmclient CheckIn output:
_______________________________________________

Connectivity test results (APNs ports, enrollment URL):
_______________________________________________

Number of affected devices (isolated or widespread):
_______________________________________________

Fix paths attempted:
[ ] Fix 1 - Re-enrol
[ ] Fix 2 - RenewDeviceCertificate
[ ] Fix 3 - APNs tenant cert renewal
[ ] Fix 4 - Policy refresh
[ ] Fix 5 - Network/proxy

Result of each:
_______________________________________________

Log extract (last 1h from mdmclient subsystem):
_______________________________________________
========================================================
```

---

## 🎓 Learning Pointers

- **APNs cert renewal is annual and must use the same Apple ID.** Many organisations lose track of which Apple ID was used to create the original APNs cert. Store this in your password manager and IT documentation immediately after setup. If the wrong Apple ID renews it, you get a new cert with a new topic — and every managed device requires re-enrolment. [Renew Apple MDM Push Certificate](https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get)

- **Set an Intune APNs expiry alert.** The Intune portal shows APNs expiry, but there's no native email alert by default. Use a Power Automate flow or Azure Monitor alert on the `intune_device_compliance` feed, or just calendar a reminder 60 days before the known expiry date.

- **mdmclient is your Mac-side MDM debug tool.** `sudo mdmclient MDMStatus` and `sudo mdmclient CheckIn` give you immediate insight into whether the device can communicate with the MDM server. The `log show --predicate 'subsystem == "com.apple.mdmclient"'` stream is the deep audit trail. [Apple mdmclient man page](https://ss64.com/osx/mdmclient.html)

- **ADE (formerly DEP) devices behave differently.** An ADE device that's been wiped and re-provisioned re-enrols automatically from Setup Assistant — the MDM profile is restored from Apple's servers. BYOD/manual enrolment requires user action. Knowing your fleet split matters for incident scoping.

- **MDM identity cert renewal is automatic when the device is healthy.** The MDM server pushes a `CertificateRenewal` command before the cert expires. This silently works when the device is online and can reach the MDM server. The cert only expires without renewal when the device is offline for a long period (e.g., locked in a drawer). Returning these devices to the network usually triggers automatic renewal.

- **SSL inspection breaks APNs.** Apple certificate-pins the APNs connection. Any proxy that performs SSL/TLS inspection on APNs traffic will break push notifications entirely — MDM commands will queue but never arrive at the device. This is the most common enterprise MDM failure mode that takes hours to diagnose. Always exclude `*.push.apple.com` from SSL inspection. [Apple's network requirements](https://support.apple.com/en-gb/101555)
