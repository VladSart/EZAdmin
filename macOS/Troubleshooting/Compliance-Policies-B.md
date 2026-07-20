# macOS Compliance Policies (Intune) — Hotfix Runbook (Mode B: Ops)
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

Run these first — results tell you which fix path to follow.

```bash
# 1 — MDM enrollment and compliance status
profiles status -type enrollment
profiles -P   # list all installed profiles

# 2 — Device management status from Intune perspective
# Check in Intune Admin Center → Devices → macOS → [device] → Device compliance

# 3 — Last check-in time and compliance state
# Run on device:
profiles status -type enrollment | grep -E "(Enrolled|MDM|Server)"

# 4 — FileVault status (frequently a compliance requirement)
fdesetup status

# 5 — Firewall status (often required by compliance)
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate

# 6 — Gatekeeper status (often required)
spctl --status

# 7 — Secure Boot / SIP status (often required on Apple Silicon)
csrutil status  # run in Recovery or System Information
```

**Interpretation table:**

| Result | Meaning | Action |
|--------|---------|--------|
| Device shows "Not compliant" in Intune, all settings look correct | Grace period expired or check-in stale | Force sync (Fix 1) |
| "Not Enrolled" in profiles status | MDM enrollment dropped | Re-enroll (Fix 2) |
| FileVault: "FileVault is Off" | Encryption not enabled | Enable FileVault (Fix 3) |
| Firewall: "Disabled" | Application firewall off | Enable firewall (Fix 4) |
| Device not checking in (last check-in >24h) | Company Portal issue or MDM cert renewal needed | Fix 1, then Fix 5 |
| Gatekeeper: "disabled" | Compliance policy likely requiring "enabled" | Fix 4 |
| Compliance shows "In grace period" | Within configured grace period, not yet blocked | No action needed — alert user |

---

## Dependency Cascade

<details><summary>What must be true for macOS compliance to work</summary>

```
Intune Compliance Policy (assigned to user/device group)
        │
        ▼
Device enrolled in Intune (MDM profile present)
        │
        ├── Company Portal app installed and signed in
        ├── MDM push certificate valid (Apple MDM Push Cert in Intune)
        └── Device managed by correct MDM server URL
                │
                ▼
        macOS Compliance Check-in (every 8h by default, or on demand)
                │ evaluates:
                ├── OS version minimum
                ├── FileVault enabled
                ├── Firewall enabled
                ├── Gatekeeper enabled
                ├── SIP status (optional)
                ├── Password/passcode requirements
                └── Custom compliance scripts (if configured)
                        │
                        ▼
                Compliance state reported to Intune
                        │
                        ▼
                Conditional Access evaluates device compliance
                (if CA policy requires compliant device)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Verify MDM enrollment**
```bash
profiles status -type enrollment
```
Expected output includes: `MDM enrollment: Yes (User Approved)`
- `User Approved` = full MDM access including kernel extension management.
- `Device Enrollment` = ADE-enrolled (highest trust).
- `Not enrolled` → go to Fix 2.

**Step 2 — Check specific failing compliance settings**
In Intune Admin Center → Devices → macOS → [device name] → Device compliance:
- Note which settings are marked "Not compliant" specifically.
- This drives which fix to apply.

**Step 3 — Verify Company Portal is functioning**
```bash
# Check if Company Portal is installed
ls /Applications/ | grep -i "Company Portal"

# Check Company Portal version
mdls -name kMDItemVersion "/Applications/Company Portal.app" 2>/dev/null || echo "Not found"
```
- Company Portal must be installed and the user signed in for on-demand compliance sync.

**Step 4 — Force a compliance check-in**
```bash
# Trigger MDM check-in from the device (run in Terminal with admin):
sudo profiles -N   # nudge MDM to check in

# OR from Company Portal app:
# Open Company Portal → Devices → [This Mac] → Check Access / Sync Device
```

**Step 5 — Check for blocking Conditional Access**
- If the user reports being blocked from M365 apps: the compliance state has propagated to Entra.
- Entra sign-in logs: filter by user, look for "Device is not compliant" failure reason.
- Compliance state typically propagates within 5–15 minutes after device reports compliant.

---

## Common Fix Paths

<details><summary>Fix 1 — Force compliance sync and check-in</summary>

**Use when:** Device shows stale compliance state; user reports they've fixed the issue but Intune still shows non-compliant.

```bash
# On the device — Terminal (admin):

# Method 1: Nudge MDM profile
sudo profiles -N

# Method 2: Restart the mdmd daemon (force re-check-in)
sudo launchctl stop com.apple.mdmd
sudo launchctl start com.apple.mdmd

# Method 3: Via Company Portal app
# → Open Company Portal → Devices → [This Mac] → Sync
```

**From Intune Admin Center (engineer):**
- Devices → macOS → [device] → Sync (button at top)
- Devices → macOS → [device] → Check compliance (button)

**Timeline:** After sync, compliance state should update within 5–15 minutes.

</details>

<details><summary>Fix 2 — Re-enroll a device that lost MDM enrollment</summary>

**Use when:** `profiles status -type enrollment` shows not enrolled or MDM profile missing.

```bash
# Step 1 — Check if the MDM profile is just missing from System Preferences
profiles -P | grep -i MDM

# Step 2 — If ADE-enrolled device (check in Apple Business):
# - Device should re-enroll automatically on next Setup Assistant run
# - Wipe and re-enroll is the clean path for ADE: System Settings → General → Transfer or Reset → Erase All Content

# Step 3 — If user-enrolled (BYOD or Company Portal enrollment):
# Instruct user:
# 1. Open Company Portal
# 2. Sign in with corporate credentials
# 3. Follow "Set up device" flow
# 4. Approve MDM enrollment when prompted in System Settings → Privacy & Security → Profiles

# Step 4 — Verify after enrollment
profiles status -type enrollment
profiles -P
```

**Note:** If the device was previously enrolled and is now showing not enrolled, check Intune for whether the device was wiped or retired. A "Retire" action removes the MDM profile.

</details>

<details><summary>Fix 3 — Enable FileVault for compliance</summary>

**Use when:** Compliance policy requires FileVault; device showing non-compliant due to FileVault off.

```bash
# Check current status
fdesetup status
# Expected non-compliant result: "FileVault is Off."

# Enable FileVault (user-initiated — requires user to be logged in)
# System Settings → Privacy & Security → FileVault → Turn On FileVault

# Or command line (requires admin — will prompt for user credentials):
sudo fdesetup enable

# If Intune has a FileVault policy deployed, it should handle this automatically:
# Devices → macOS → Configuration → [FileVault profile] → verify it's assigned to the device
```

**Verify after enabling:**
```bash
fdesetup status
# Expected: "FileVault is On."
# Note: Encryption happens in background; compliance reports "On" immediately after enable.
```

**Escrow recovery key to Intune:**
- If FileVault was enabled manually (not via Intune policy), the personal recovery key won't be escrowed to Intune.
- To escrow: Intune must have FileVault policy with "Escrow location description" configured; the key is captured at next check-in when policy is applied.

</details>

<details><summary>Fix 4 — Enable macOS Application Firewall and Gatekeeper for compliance</summary>

**Use when:** Compliance policy requires firewall or Gatekeeper; device reporting non-compliant.

```bash
# Enable Application Firewall
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
# Verify:
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
# Expected: "Firewall is enabled. (State = 1)"

# Enable Gatekeeper
sudo spctl --master-enable
# Verify:
spctl --status
# Expected: "assessments enabled"

# Or via System Settings:
# Firewall: System Settings → Network → Firewall → Turn On
# Gatekeeper: System Settings → Privacy & Security → App Store and identified developers (or App Store only)
```

**Note:** If Intune has a configuration profile managing these settings, the profile wins. Manually enabling them is temporary if the Intune profile is pushing the opposite setting. Check the assigned configuration profiles in Intune first.

</details>

<details><summary>Fix 5 — Resolve stale or missing Company Portal / check-in issues</summary>

**Use when:** Device not checking in, Company Portal signing user out repeatedly, or compliance state stuck.

```bash
# Check Company Portal version (must be current)
mdls -name kMDItemVersion "/Applications/Company Portal.app"

# Update Company Portal from Mac App Store or via Intune app deployment
# Minimum version typically required: 5.2301 or later (check Intune release notes)

# Clear Company Portal cached credentials (if sign-in loop):
# 1. Quit Company Portal
# 2. In Terminal:
rm -rf ~/Library/Caches/com.microsoft.CompanyPortal
rm -rf ~/Library/Saved\ Application\ State/com.microsoft.CompanyPortal.savedState
# 3. Reopen Company Portal and sign in fresh

# If MDM push is not reaching the device (network issue):
# Check that outbound to these Apple endpoints is open:
# *.push.apple.com (APNs) — TCP 443 and 5223
# gateway.push.apple.com — TCP 2195
curl -v https://gateway.push.apple.com 2>&1 | grep -E "(Connected|SSL)"
```

</details>

---

## Escalation Evidence

```
=== macOS Compliance Escalation Pack ===
Date/Time:              ___________________
Technician:             ___________________
Affected Device:        ___________________
Intune Device ID:       ___________________  (Devices → [device] → Properties → Device ID)
Serial Number:          ___________________  (System Information → Hardware)
macOS Version:          ___________________
Company Portal Version: ___________________

--- Enrollment Status ---
profiles status -type enrollment output:
___________________
___________________

--- Compliance Failures (from Intune portal) ---
Failed settings:
1. ___________________
2. ___________________
3. ___________________

--- Local Setting States ---
FileVault:      ___________________  (fdesetup status)
Firewall:       ___________________  (socketfilterfw --getglobalstate)
Gatekeeper:     ___________________  (spctl --status)
OS Version:     ___________________  (sw_vers)

--- Last Check-in ---
Intune last check-in: ___________________  (from portal)
Last sync attempted:  ___________________

--- Actions Taken ---
1. ___________________
2. ___________________
3. ___________________

--- Outcome ---
[ ] Resolved — Root cause: ___________________
[ ] Escalating — Blocker: ___________________
```

---

## 🎓 Learning Pointers

- **Compliance ≠ Configuration:** Intune compliance policies read the state of a setting; they don't enforce it. A configuration profile enforces it. If FileVault is required by compliance but no configuration profile is pushing it, the device stays non-compliant until the user enables it manually. Always pair compliance requirements with the corresponding configuration profile.

- **Grace period is your friend:** Compliance policies can have a "grace period" (e.g. 3 days before blocking CA). This prevents a locked-out user the moment a new policy rolls out. If a device just went non-compliant and the user isn't blocked yet, the grace period is still running. Check it in Intune → Devices → [device] → Device compliance → the "grace period" column shows expiry.

- **APNs certificate expiry kills check-ins:** The Apple MDM Push Certificate in Intune renews annually. If it expires, no Apple device will check in. Check expiry at Intune Admin Center → Tenant Administration → Apple MDM Push Certificate. Renew before expiry — renewal must use the same Apple ID that created it. [APNs renewal](https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get)

- **User-approved MDM vs Device enrollment:** If the device is User-Approved (not ADE), Intune can read compliance settings but can't install kernel extensions or apply some security settings. For full management capabilities (including FileVault key escrow), ADE (Apple Business) enrollment is required. This matters when a compliance policy checks for things that require ADE-level permissions.

- **Compliance state propagation delay:** Even after a device reports compliant, Conditional Access can take 5–20 minutes to unblock access. This is a common user escalation: "I fixed the issue but still can't access email." Ask the user to wait 15 minutes and try again before further escalation.
