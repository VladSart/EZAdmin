# macOS Platform SSO — Hotfix Runbook (Mode B: Ops)
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

Run these immediately to classify the issue:

```bash
# 1. Check Platform SSO registration status
app-sso platform -s

# 2. Check Intune Company Portal registration state
profiles status -verbose 2>/dev/null | grep -i "sso\|platform\|entra"

# 3. Check SSO extension is active
profiles -P | grep -i "sso"

# 4. Check if device is enrolled in MDM
profiles status -type enrollment

# 5. Check Kerberos SSO extension (if hybrid)
app-sso kerberos -s 2>/dev/null || echo "No Kerberos SSO"
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `app-sso platform -s` shows `Registered: Yes` | Platform SSO working | Move to app-specific debugging |
| `Registered: No` or `Not registered` | Registration failed or not yet completed | → Fix 1 or Fix 2 |
| `profiles -P` shows no SSO extension profile | MDM profile not delivered | → Fix 3 |
| `Registration state: UserRegistrationRequired` | User hasn't completed registration flow | → Fix 4 |
| `profiles status` shows no MDM enrollment | Device not Intune enrolled | → Re-enroll before anything else |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
User opens an M365 app or browser and gets SSO
        │
        ▼
Platform SSO extension active (Extensible SSO profile in MDM)
        │
        ▼
User completed Platform SSO registration
(signed into macOS with Entra credentials, or Company Portal registration)
        │
        ▼
Device is Entra-registered (via Platform SSO registration flow)
        │
        ▼
Intune MDM — PSSO configuration profile delivered
        │
        ▼
macOS 13.0+ (Ventura) for Platform SSO; macOS 14.0+ for improved phishing-resistant flows
        │
        ▼
Network access: login.microsoftonline.com, login.microsoft.com
        │
        ▼
Microsoft Enterprise SSO plugin (bundled in Company Portal / Intune app)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm Platform SSO profile is on the device**

```bash
profiles -P | grep -A5 -i "SSO\|ExtensibleSSO\|com.apple.extensiblesso"
```

Expected output: a profile containing `com.apple.extensiblesso` with `AuthenticationMethod` set (password, UserSecureEnclaveKey, or SmartCard).

Bad: No output → MDM profile not delivered. Check Intune assignment.

---

**Step 2 — Check Platform SSO registration state**

```bash
app-sso platform -s
```

Good output:
```
Platform SSO status:
Registration: Registered
Authentication method: Password
Registration date: 2024-01-15
User: user@contoso.com
```

Bad output:
```
Platform SSO status:
Registration: Not registered
```
→ User needs to complete registration (see Fix 4).

---

**Step 3 — Check the SSO extension is responding**

```bash
app-sso extension -p com.microsoft.CompanyPortalMac.ssoextension
```

Expected: Shows extension status, no errors.  
Bad: `Error` or `not found` → Company Portal not installed or extension bundle ID changed.

---

**Step 4 — Verify Entra device registration via Platform SSO**

```bash
# Check if device shows as registered in local keychain/state
app-sso platform -d 2>/dev/null
```

Look for `DeviceId` — if present, device is Entra-registered. If missing, registration hasn't completed.

---

**Step 5 — Check for token acquisition errors**

```bash
# Check Console.app or log for SSO errors (run in Terminal)
log show --predicate 'subsystem == "com.apple.AuthenticationServices.AuthorizationPlugin"' --last 1h 2>/dev/null | tail -50

# Or for Microsoft-specific SSO logs:
log show --predicate 'process == "CompanyPortal" OR process == "SSOExtensionProcess"' --last 2h 2>/dev/null | grep -i "error\|fail\|sso" | tail -30
```

---

## Common Fix Paths

<details>
<summary>Fix 1 — Re-trigger Platform SSO registration for the user</summary>

**When:** `app-sso platform -s` shows "Not registered" and the profile IS present.

Ask the user to:
1. Open **System Settings → Privacy & Security → Profiles** — verify the SSO profile is listed
2. Look for a **notification** from Company Portal asking to complete registration — it often appears in Notification Centre
3. If no notification: open **Company Portal** → click **"Register This Device"** or look for a banner prompting registration

Or trigger via Terminal (if you have admin access):
```bash
# Refresh MDM profile delivery (forces re-evaluation)
sudo profiles renew -type enrollment

# Then wait ~60 seconds and check again
sleep 60
app-sso platform -s
```

</details>

<details>
<summary>Fix 2 — Sign the user out and back into Platform SSO</summary>

**When:** Registration is stuck or shows wrong account.

```bash
# Check current registered account
app-sso platform -s

# Sign out of Platform SSO (user must re-register after this)
app-sso platform --logout
# User will be prompted to re-authenticate next login

# Verify cleared
app-sso platform -s
# Should show: Not registered
```

**After sign-out:** user must log back in to macOS (or open Company Portal) and complete registration with their Entra credentials. This will re-register the device.

**Rollback note:** Sign-out removes the Entra device registration token — the device stays in MDM but the Entra registration is dropped. It will re-register on next successful authentication.

</details>

<details>
<summary>Fix 3 — MDM Profile not delivered — Intune side fix</summary>

**When:** `profiles -P` shows no SSO extension profile on the device.

On **Intune portal**:
1. Navigate to Devices → macOS → Configuration profiles
2. Confirm the **Extensible SSO** profile assignment includes this device/group
3. Check the profile **status** for this device — look for deployment errors
4. If status shows "Error": review the profile XML for typos in bundle ID or extension identifier

```bash
# Force Intune MDM sync on device (Terminal on macOS)
sudo profiles renew -type enrollment
sudo profiles -N  # Installs pending profiles
```

Correct bundle ID for Microsoft Enterprise SSO Plugin:
- **Extension Identifier:** `com.microsoft.CompanyPortalMac.ssoextension`  
- **Team Identifier:** `UBF8T346G9`  
- **Type:** Redirect (not Credential)  
- **URLs:** `https://login.microsoftonline.com`, `https://login.microsoft.com`, `https://sts.windows.net`

</details>

<details>
<summary>Fix 4 — User hasn't completed registration (first-time setup)</summary>

**When:** Device is newly enrolled, profile delivered, but user never finished the Platform SSO registration flow.

The registration prompt should appear automatically. If it didn't:

1. Ask the user to **lock and unlock their Mac** (screensaver → enter password). Registration is often triggered at login.
2. Or: open **Company Portal** app → should show a prompt to sign in with work account
3. User enters their **Entra UPN and password** (or uses FIDO2 key if configured)
4. macOS will then:
   - Register the device with Entra ID
   - Create a Secure Enclave key bound to this device (if using `UserSecureEnclaveKey` auth method)
   - Enable SSO for all apps using the extension

After completion:
```bash
app-sso platform -s
# Should show: Registered: Yes
```

</details>

<details>
<summary>Fix 5 — Company Portal missing or wrong version</summary>

**When:** SSO extension not found or `app-sso extension` errors.

```bash
# Check Company Portal version
defaults read /Applications/Company\ Portal.app/Contents/Info.plist CFBundleShortVersionString
# Need: 5.2312.0 or higher for full Platform SSO support

# Check if SSO extension bundle is present
ls /Applications/Company\ Portal.app/Contents/Library/SystemExtensions/ 2>/dev/null
```

If Company Portal is missing or outdated:
- Re-deploy via Intune → Apps → macOS → Company Portal (ensure VPP or latest version assigned)
- Or download from Mac App Store while MDM profile is active (it will auto-activate the SSO extension)

After update, the SSO extension activates automatically — no re-enrollment needed.

</details>

<details>
<summary>Fix 6 — Browser not picking up SSO (Edge/Chrome/Safari)</summary>

**When:** Platform SSO shows registered but browser still prompts for Entra credentials.

```bash
# Check if browser SSO redirect URLs are configured
profiles -P | grep -A10 "URLs\|Redirect\|ExtensibleSSO" | head -40
```

If URLs are missing from the SSO profile, add these to the Redirect URLs in Intune:
```
https://login.microsoftonline.com
https://login.microsoft.com
https://sts.windows.net
https://autologon.microsoftazuread-sso.com
```

For **Safari**: SSO extension works natively — no extra config.  
For **Chrome/Edge**: ensure the browser is managed (Intune config profile) so it respects the SSO extension. Unmanaged browsers may not honour the extension.

**Quick test:** open `https://myapps.microsoft.com` in Safari. If it signs in without prompting → SSO working. If it prompts → URL list issue.

</details>

---

## Escalation Evidence

```
=== Platform SSO Escalation Package ===
Date/Time:          ___________
Device Name:        ___________
macOS Version:      ___________  (System Settings → General → About)
Company Portal Ver: ___________  (About Company Portal)
User UPN:           ___________
Intune Device ID:   ___________  (Company Portal → Device Details)
MDM Enrolled:       Yes / No

=== Commands Output (paste results) ===

app-sso platform -s:
[PASTE]

profiles -P (SSO-related entries):
[PASTE]

profiles status -type enrollment:
[PASTE]

app-sso extension -p com.microsoft.CompanyPortalMac.ssoextension:
[PASTE]

=== Error Description ===
- User reports: ___________
- Started occurring: ___________
- Affects all apps / specific apps: ___________
- Any recent changes (macOS update, re-enrollment, password change): ___________

=== Steps Already Tried ===
[ ] app-sso platform --logout and re-register
[ ] profiles renew -type enrollment
[ ] Re-installed Company Portal
[ ] Other: ___________
```

---

## 🎓 Learning Pointers

- **Platform SSO vs. Kerberos SSO extension**: macOS has two SSO extension types. **Platform SSO** (macOS 13+) handles Entra ID authentication and device registration — this is what most MSPs configure for cloud-only and hybrid orgs. **Kerberos SSO** handles on-prem Kerberos ticket acquisition. You can run both simultaneously. Platform SSO is the modern path for Entra-joined workflows. See: [Platform SSO for macOS](https://learn.microsoft.com/en-us/mem/intune/configuration/platform-sso-macos)

- **Authentication method choice matters**: Intune's Platform SSO profile lets you choose `Password`, `UserSecureEnclaveKey` (hardware-bound, phishing-resistant), or `SmartCard`. `UserSecureEnclaveKey` (macOS 14+) is the most secure — the key never leaves the device's Secure Enclave. For MSPs standardising on phishing-resistant MFA, this is the path to push.

- **Company Portal is required**: Unlike Windows (where the SSO plugin is part of Office), on macOS the Microsoft Enterprise SSO plugin is bundled inside Company Portal. Company Portal must be installed and at a supported version. Without it, the SSO extension doesn't exist on the device.

- **Device registration via Platform SSO creates an Entra device object**: When a user completes Platform SSO registration, the macOS device appears in Entra ID → Devices (as registered, not joined). This enables Conditional Access policies that require "device compliance" or "Entra registered device." If the device is missing from Entra, Platform SSO registration hasn't completed.

- **Phased rollout recommendation**: Enable Platform SSO with `Password` auth first, validate SSO works, then migrate to `UserSecureEnclaveKey` for higher security. Changing auth method requires users to re-register — plan the communication.
