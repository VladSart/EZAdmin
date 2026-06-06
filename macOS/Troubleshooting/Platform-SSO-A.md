# macOS Platform SSO — Reference Runbook (Mode A: Deep Dive)
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

Covers **macOS Platform SSO (PSSO)** via the Microsoft Enterprise SSO Extension delivered through Intune, targeting macOS 13 Ventura and later. Assumes:

- macOS 13.0+ (Platform SSO requires macOS 13; password SSO works on 12+; secure enclave key requires macOS 13+)
- Microsoft Intune MDM enrollment (ADE or user-enrolled)
- Microsoft Authenticator or Company Portal app installed (required for the SSO extension broker)
- Entra ID (Azure AD) tenant with Conditional Access in use
- Devices are Entra ID registered or hybrid-joined via Entra Connect

Does **not** cover:
- Kerberos SSO extension (separate profile, separate flow)
- JAMF-managed PSSO deployment (configuration keys differ)
- Third-party IdP federation (Okta, Ping) — Microsoft SSO extension is Entra-specific

---

## How It Works

<details><summary>Full architecture</summary>

### What Platform SSO Is

Platform SSO is an Apple-native framework (introduced with macOS 13) that integrates the macOS login window and keychain directly with an IdP. Unlike the previous Enterprise SSO Extension (which only handled in-app browser token acquisition), Platform SSO enables:

1. **Login window authentication against Entra ID** — user logs in with their Entra ID password (or secure enclave hardware key) at the macOS lock screen
2. **Automatic Entra ID token acquisition** — once logged in, tokens are silently provisioned for all apps using Microsoft Authentication Library (MSAL)
3. **Device registration** — the device creates a hardware-bound key in the Secure Enclave and registers it with Entra ID, resulting in an Entra-registered device record

### Authentication Methods (three modes)

| Mode | macOS Min | How it works | User experience |
|------|-----------|-------------|-----------------|
| **Password** | 12.0 | macOS account password synced with Entra ID password | User must keep passwords in sync; SSO tokens issued after sync |
| **UserSecureEnclaveKey** | 13.0 | Hardware key in Secure Enclave bound to user; no password involved | User authenticates with Touch ID or device PIN; no password sync required |
| **SmartCard** | 13.3 | PIV certificate on smartcard used for macOS login | Requires YubiKey or compatible smartcard |

**Enterprise recommendation: UserSecureEnclaveKey** — strongest security posture, passwordless, no sync issues.

### Token Flow (UserSecureEnclaveKey mode)

```
macOS Login Window           Platform SSO Plugin          Entra ID
       |                            |                          |
       |-- User enters PIN/Touch ID->|                         |
       |                            |-- KeyPair generated      |
       |                            |   (Secure Enclave)       |
       |                            |                          |
       |                            |-- Registration request ->|
       |                            |   (public key + device   |
       |                            |    attestation)          |
       |                            |<- Registration token ----|
       |                            |   (device registered)    |
       |<- Login granted ----------|                          |
       |                            |                          |
  App requests token               |                          |
       |------ MSAL token request ->|                         |
       |                            |-- Sign challenge w/ SE -->|
       |                            |   private key            |
       |                            |<- Access token ----------|
       |<-- Token returned ---------|                          |
```

### Key macOS Components

- **`/Library/Application Support/Microsoft/CloudSSOPlugin/`** — Platform SSO extension installation directory
- **`platformssoctl`** — CLI tool for inspecting PSSO state (macOS 13+)
- **Secure Enclave** — hardware module on Apple Silicon and T2/T3 chips; stores private keys that cannot be exported
- **System Extension** — the SSO extension runs as a privileged system extension, approved via MDM (`com.microsoft.CompanyPortalMac.ssoextension`)
- **Company Portal or Authenticator** — acts as the broker; must be installed and the system extension must be approved before PSSO can activate

### MDM Profile Delivered by Intune

Intune delivers a **Extensible SSO payload** (`com.apple.extensiblesso`) containing:
- `ExtensionIdentifier`: `com.microsoft.CompanyPortalMac.ssoextension`
- `TeamIdentifier`: `UBF8T346G9`
- `AuthenticationMethod`: `UserSecureEnclaveKey` (or `Password`)
- `RegistrationToken`: tenant-specific token used for device registration
- `Urls`: list of protected URLs that trigger SSO (e.g., `https://login.microsoftonline.com`, `https://*.microsoft.com`)
- `AdditionalConfiguration`: Platform SSO-specific keys (`platform_sso_enable_create_user_at_login`, `use_shared_device_keys_with_microsoft_entra_id`, etc.)

</details>

---

## Dependency Stack

```
[Platform SSO active — user gets seamless SSO to Entra ID apps]
                    |
                    ▼
[User registration completed (platformssoctl show-registration)]
                    |
                    ▼
[SSO extension active and system extension approved]
                    |
                    ▼
[Company Portal or Authenticator installed + opened at least once]
                    |
                    ▼
[Extensible SSO MDM profile delivered (Intune config profile)]
                    |
                    ├── Device enrolled in Intune
                    ├── macOS 13.0+ (for UserSecureEnclaveKey)
                    ├── Apple Silicon or T2 chip (for Secure Enclave)
                    └── Device can reach login.microsoftonline.com on TCP/443
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| SSO prompt on every app login despite PSSO profile | Registration not completed | `platformssoctl show-registration` — look for "Not Registered" |
| "Your organization requires Platform SSO registration" banner | User has not completed registration flow | User needs to open Company Portal and complete registration |
| SSO profile installed but extension not active | System extension not approved via MDM | `systemextensionsctl list` — check for `com.microsoft.CompanyPortalMac.ssoextension` |
| `platformssoctl` not found | macOS < 13 | `sw_vers -productVersion` — upgrade required |
| Registration button grayed out in Company Portal | Device not meeting Conditional Access requirements | Check CA sign-in logs; often missing Compliant or Registered status |
| macOS 13+ but PSSO keys show "Password" mode instead of "UserSecureEnclaveKey" | Profile sent AuthenticationMethod = Password or old profile | Check MDM profile in System Settings → Privacy & Security → Profiles |
| User can't log in to macOS after PSSO enabled | PSSO login window enabled but user Entra credentials differ from local account | Local account password != Entra password and mode = Password |
| Tokens expire quickly / frequent re-auth | PSSO registration token stale or revoked | Re-register: `platformssoctl register -u <UPN>` |
| PSSO works for Microsoft apps but not third-party | Third-party app doesn't use MSAL or the URLs list is incomplete | Add app's auth URLs to `Urls` array in SSO extension profile |
| Company Portal shows "Managed but not registered" | PSSO registration never triggered | Open Company Portal → tap "Register device" or sign in with work account |

---

## Validation Steps

**Step 1 — Check macOS version and chip**
```bash
sw_vers -productVersion      # must be 13.0+ for UserSecureEnclaveKey
system_profiler SPHardwareDataType | grep "Chip\|Processor"
```
Expected: macOS 13.0 or later; Apple M-series chip or Intel with T2 chip (for Secure Enclave support).

**Step 2 — Verify MDM profile delivered**
```bash
# List all MDM profiles — look for ExtensibleSSO type
profiles list -type configuration 2>/dev/null | grep -A2 "Extensib\|SSO\|Microsoft"
```
Expected: An extensible SSO profile from your Intune MDM server. If absent, check Intune assignment.

**Step 3 — Check system extension status**
```bash
systemextensionsctl list 2>/dev/null | grep -i "microsoft\|company\|sso"
```
Expected: `[activated enabled]` next to `com.microsoft.CompanyPortalMac.ssoextension`. If showing `[activated waiting for user]` — user must approve in System Settings. If blank — Company Portal not installed.

**Step 4 — Check PSSO registration state**
```bash
app_sso -i 2>/dev/null
# or on macOS 13+:
platformssoctl show-registration 2>/dev/null
```
Expected for `app_sso -i`: JSON output showing `"sso_registered": true` and device keys.
Expected for `platformssoctl show-registration`: Registration details including UPN, device ID, and key type.

**Step 5 — Check SSO tokens are being issued**
```bash
# Check if SSO extension is handling auth requests
log show --predicate 'subsystem == "com.apple.AuthenticationServices.AuthorizationPlugin"' \
    --style syslog --last 30m 2>/dev/null | tail -50
```
Look for entries showing successful token issuance. Errors show `error` level with descriptions.

**Step 6 — Verify network access to Entra ID endpoints**
```bash
curl -sv --max-time 10 https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration 2>&1 | \
    grep -E "HTTP|Connected|failed|timeout" | head -5
```
Expected: `HTTP/1.1 200 OK` or `HTTP/2 200`. If timeout or connection refused, check proxy/firewall.

---

## Troubleshooting Steps (by phase)

### Phase 1: Profile not delivered

1. In Intune portal: **Devices → macOS → [device] → Device configuration**
2. Locate the Extensible SSO profile — check status (Succeeded / Failed / Pending)
3. If **Pending**: device hasn't checked in recently. Run `sudo profiles renew -type enrollment` on device
4. If **Failed**: click the profile → review error message. Common: profile validation failure (AuthenticationMethod typo, missing RegistrationToken)
5. Verify the profile is assigned to a group that includes this device — use **Devices → Filters** to check group membership

### Phase 2: System extension not approved

1. On device: **System Settings → Privacy & Security → Security** → look for "System software from application 'Microsoft Company Portal' was blocked"
2. If blocked: this must be unblocked via MDM — it cannot be user-approved for Platform SSO
3. In Intune, verify a **System Extensions** configuration profile exists with:
   - Allowed System Extensions: `com.microsoft.CompanyPortalMac.ssoextension`
   - Team Identifier: `UBF8T346G9`
4. After profile delivery, run `systemextensionsctl list` to confirm `[activated enabled]`

### Phase 3: Registration not completing

1. Open **Company Portal** on the affected Mac
2. Navigate to **Devices** → select the device → look for "Register" or "Complete setup" prompt
3. If the registration button is missing: sign out and sign back in to Company Portal with the user's Entra ID account
4. If registration fails with an error: collect the error code and check Entra ID sign-in logs (portal.azure.com → Entra ID → Sign-in logs → filter by Device = macOS, Status = Failure)
5. Common registration failure: **Conditional Access policy blocking unregistered devices** — create a CA exclusion for the registration endpoint (`https://enterpriseregistration.windows.net`) or use "Report-only" mode temporarily

### Phase 4: SSO not working after registration

1. After registration, test with: open Safari → navigate to `https://myapps.microsoft.com`
2. Should sign in without credential prompt. If prompted: SSO extension may not be handling the URL
3. In Intune SSO profile, verify `Urls` array includes `https://login.microsoftonline.com` and `https://*.microsoft.com`
4. For third-party apps: add their authentication URLs to the `AdditionalURLs` or `Urls` array in the SSO profile
5. Check `log show --predicate 'subsystem contains "sso"' --last 5m` for token issuance events

### Phase 5: Password mode sync issues

If using **Password** mode (not recommended for new deployments):

1. Local macOS account password must exactly match Entra ID password
2. If passwords diverge (e.g., Entra password changed remotely), user must manually update local password:
   - **System Settings → Users & Groups → [account] → Change Password**
   - Enter old local password and new Entra password
3. After sync, test: lock screen → unlock → should seamlessly acquire tokens
4. Consider migrating to **UserSecureEnclaveKey** mode to eliminate this problem permanently

---

## Remediation Playbooks

<details><summary>Playbook 1 — Re-register PSSO for a User</summary>

**When:** Registration is stale, tokens are expired, or user changed Entra ID credentials and PSSO stopped working.

```bash
# Run as the affected user (not root)

# Step 1: Check current registration state
platformssoctl show-registration 2>/dev/null || app_sso -i

# Step 2: Clear existing registration (removes stale keys)
# WARNING: This removes the user's SSO state — they will need to re-authenticate to all apps
platformssoctl logout 2>/dev/null
app_sso -c 2>/dev/null  # clear SSO tokens (older macOS)

# Step 3: Trigger re-registration
# Option A: via Company Portal (preferred — user-friendly)
# Open Company Portal → Devices → Register device

# Option B: via CLI (admin-initiated)
platformssoctl register -u <UserUPN@domain.com>
# This opens a browser window for the user to authenticate
```

**Rollback:** N/A — this does not affect local account or Intune enrollment. If registration fails, the user falls back to standard browser-based authentication.

</details>

<details><summary>Playbook 2 — Deploy System Extension Approval Profile</summary>

**When:** `systemextensionsctl list` shows Company Portal extension not activated, and macOS is blocking it.

Create and assign this Intune profile (Device configuration → Templates → Extensions):

```
Profile type: Extensions
Extension type: System Extensions

Allowed system extensions:
  Bundle ID: com.microsoft.CompanyPortalMac.ssoextension
  Team ID: UBF8T346G9

Allowed system extension types:
  Team ID: UBF8T346G9
  Allowed types: Network extensions, System extensions
```

```bash
# After profile delivers, verify on device:
systemextensionsctl list | grep -i microsoft
# Expected output contains: [activated enabled] com.microsoft.CompanyPortalMac.ssoextension

# If still showing waiting:
# User needs to approve once in System Settings → Privacy & Security
# (only required if System Extension profile was not delivered via MDM)
```

</details>

<details><summary>Playbook 3 — Migrate from Password Mode to UserSecureEnclaveKey</summary>

**When:** Organization wants to move from password-sync PSSO to passwordless hardware key PSSO.

```bash
# Step 1: Verify device has Secure Enclave (Apple Silicon or T2)
system_profiler SPHardwareDataType | grep -E "Chip|Processor|Model"
# Apple M1/M2/M3/M4 = Secure Enclave present
# Intel without T2 = UserSecureEnclaveKey NOT supported — must stay on Password mode

# Step 2: Update Intune SSO Extension profile
# Change AuthenticationMethod from "Password" to "UserSecureEnclaveKey"
# Assign to a pilot group first

# Step 3: After profile update delivers, verify on device:
profiles list -type configuration | grep -i SSO
# Check profile shows new AuthenticationMethod value

# Step 4: User must re-register after mode change
# Old registration keys are incompatible with new mode
platformssoctl logout
# Then re-register via Company Portal
```

**Rollback:** Revert Intune profile `AuthenticationMethod` to `Password` and reassign. Users must re-register.

</details>

<details><summary>Playbook 4 — Fix PSSO Blocking macOS Login</summary>

**When:** After enabling PSSO login window (`EnableCreateUserAtLogin = true`), users cannot log in to macOS.

This is critical — perform from an admin account that is not affected, or via Recovery Mode.

```bash
# Option 1: Disable PSSO login window via MDM (preferred)
# In Intune, update the SSO Extension profile:
# Set platform_sso_enable_create_user_at_login to false (or remove the key)
# Assign to affected devices — they will apply on next MDM check-in

# Option 2: Emergency local fix (requires admin account or Recovery Mode)
# Boot into Recovery Mode (hold Power on Apple Silicon, Cmd+R on Intel)
# Open Terminal in Recovery Mode:
sudo defaults write /var/db/dslocal/nodes/Default/config/com.apple.platform_sso_configuration \
    PSSOEnableCreateUserAtLogin -bool false 2>/dev/null || true

# Option 3: Remove PSSO profiles entirely (nuclear option)
# In Intune, remove the SSO Extension profile assignment for affected devices
# Device will revert to standard local auth after next MDM sync
# Requires device to be online — if locked out, must use Recovery Mode
```

**Prevention:** Always test `EnableCreateUserAtLogin` with a pilot group before broad deployment. Ensure at least one local admin account exists that bypasses PSSO.

</details>

---

## Evidence Pack

Run on the affected Mac as the affected user, or as admin:

```bash
#!/bin/bash
# Platform SSO Evidence Collection
# Run as admin or affected user

OUTPUT_DIR="/tmp/PSSO_Evidence_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/psso_evidence.txt"

log_section() {
    echo "" >> "$OUT"
    echo "========================================" >> "$OUT"
    echo "  $1" >> "$OUT"
    echo "========================================" >> "$OUT"
}

echo "Platform SSO Evidence Report" > "$OUT"
echo "Collected: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$OUT"
echo "Device: $(hostname)" >> "$OUT"
echo "User: $(whoami)" >> "$OUT"

log_section "macOS Version"
sw_vers >> "$OUT" 2>&1

log_section "Hardware (chip type)"
system_profiler SPHardwareDataType 2>/dev/null | grep -E "Chip|Processor|Model Identifier" >> "$OUT"

log_section "MDM Enrollment State"
profiles status -type enrollment 2>/dev/null >> "$OUT"

log_section "Installed Configuration Profiles (SSO-related)"
profiles list -type configuration 2>/dev/null | grep -E "SSO|Microsoft|Extensib|Company" >> "$OUT"

log_section "System Extensions"
systemextensionsctl list 2>/dev/null >> "$OUT"

log_section "PSSO Registration State"
platformssoctl show-registration 2>/dev/null >> "$OUT" || \
    (app_sso -i 2>/dev/null >> "$OUT" || echo "platformssoctl not available (macOS < 13?)" >> "$OUT")

log_section "Keychain: Entra ID entries"
security list-keychains 2>/dev/null >> "$OUT"
security dump-keychain 2>/dev/null | grep -i "microsoft\|azure\|entra\|login.windows" >> "$OUT" || \
    echo "No Microsoft keychain entries found or permission denied" >> "$OUT"

log_section "Network: Entra ID endpoint reachability"
curl -sv --max-time 10 https://login.microsoftonline.com/common/discovery/instance \
    2>&1 | grep -E "HTTP|Connected|failed|Resolved" >> "$OUT"

log_section "SSO Extension Logs (last 20 min)"
log show --predicate 'subsystem contains "sso" OR subsystem contains "AuthenticationServices"' \
    --style syslog --last 20m 2>/dev/null | tail -100 >> "$OUT"

log_section "Company Portal / Intune App Logs"
find ~/Library/Logs -name "*IntuneCompanyPortal*" -o -name "*MicrosoftAuthenticator*" 2>/dev/null \
    -exec echo "Found log: {}" \; >> "$OUT"

tar -czf "$OUTPUT_DIR.tar.gz" -C "$OUTPUT_DIR" .
echo ""
echo "Evidence collected at: $OUTPUT_DIR.tar.gz"
echo "Attach this file to the escalation ticket."
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check PSSO registration | `platformssoctl show-registration` |
| Check SSO token state (older) | `app_sso -i` |
| List system extensions | `systemextensionsctl list` |
| List MDM profiles | `profiles list -type configuration` |
| macOS version | `sw_vers -productVersion` |
| Chip type | `system_profiler SPHardwareDataType \| grep Chip` |
| Force MDM check-in | `sudo profiles renew -type enrollment` |
| Logout PSSO (clear keys) | `platformssoctl logout` |
| Re-register PSSO | `platformssoctl register -u <UPN>` |
| View SSO logs (live) | `log stream --predicate 'subsystem contains "sso"'` |
| View SSO logs (last 30m) | `log show --predicate 'subsystem contains "sso"' --last 30m` |
| Test Entra ID reachability | `curl -I https://login.microsoftonline.com` |
| Clear all SSO tokens (older) | `app_sso -c` |
| View current user's keychains | `security list-keychains` |
| Check proxy settings | `scutil --proxy` |
| Check DNS resolution | `dscacheutil -q host -a name login.microsoftonline.com` |

---

## 🎓 Learning Pointers

- **Platform SSO and the Enterprise SSO Extension are different things — and both may be deployed simultaneously.** The Enterprise SSO Extension (delivered since 2020 via Intune) handles in-app MSAL token acquisition for apps that already have a token. Platform SSO goes further by wiring into the macOS login window and Keychain. If you only deploy the Enterprise SSO Extension without Platform SSO, users still get seamless app sign-in but no login window integration. [Platform SSO overview — Microsoft Docs](https://learn.microsoft.com/en-us/mem/intune/configuration/platform-sso-macos)

- **`EnableCreateUserAtLogin` creates a new macOS local account mapped to the Entra ID user.** This is powerful for zero-touch provisioning (ADE + Platform SSO = user logs in with Entra credentials and a local account is auto-created) but dangerous if misconfigured — local accounts can be orphaned if the Entra account is deleted or renamed. Always plan account lifecycle management before enabling this. [Configure login window with PSSO](https://learn.microsoft.com/en-us/mem/intune/configuration/platform-sso-macos)

- **Platform SSO device registration creates an Entra ID device record — but it is distinct from Intune enrollment.** A device can be Intune-enrolled (MDM) and PSSO-registered in Entra ID as separate states. Conditional Access policies checking "Entra Registered" or "Compliant" may behave differently depending on which state is satisfied. Use `platformssoctl show-registration` to verify the Entra device ID matches what's in the Entra portal. [Device identities in Entra ID — Microsoft Docs](https://learn.microsoft.com/en-us/entra/identity/devices/concept-device-registration)

- **The Secure Enclave private key created during PSSO registration cannot be exported.** This is by design — it provides phishing-resistant authentication. However, if a user's Mac is lost or the device is erased, the key is gone. Entra ID will show the old device registration as "stale" — clean these up with `Get-MgDevice` in Microsoft Graph PowerShell. [Manage stale devices — Microsoft Docs](https://learn.microsoft.com/en-us/entra/identity/devices/manage-stale-devices)

- **Proxy servers that perform TLS inspection will break Platform SSO.** The SSO extension pins certificates for `login.microsoftonline.com` and related endpoints. If your proxy intercepts these with a re-signed cert, registration and token acquisition fail silently. Bypass list must include `*.microsoftonline.com`, `*.microsoft.com`, `*.live.com`, `enterpriseregistration.windows.net`. [Microsoft 365 network endpoints — Microsoft Docs](https://learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges)

- **Platform SSO is the foundation for Passkey support on macOS.** Starting macOS 14 Sonoma, devices with PSSO registration can use hardware-bound passkeys (WebAuthn) for phishing-resistant MFA to web apps. Organizations deploying PSSO today are building the infrastructure for a passwordless future. [FIDO2 and Passkeys with Entra ID — Microsoft Docs](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-passwordless)
