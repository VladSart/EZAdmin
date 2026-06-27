# macOS System Extensions & Kernel Extensions — Hotfix Runbook (Mode B: Ops)
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

Run these first on the affected Mac. Identifies 80% of issues in under 2 minutes.

```bash
# 1. List all System Extensions and their state
systemextensionsctl list

# 2. Check if SIP (System Integrity Protection) is enabled — must be ON for MDM-managed extensions
csrutil status

# 3. Show kernel extensions currently loaded
kextstat | grep -v "com.apple"

# 4. Check Intune extension payload (requires MDM enrolment)
profiles show -all | grep -A5 -i "systemextension\|kernelextension"

# 5. Check for extension approval prompts pending in System Settings
# (No CLI equivalent — must be done in System Settings → Privacy & Security → Security)
```

**Interpretation table:**

| Output | What it means | Action |
|--------|--------------|--------|
| Extension shows `[activated waiting for user]` | User approval pending | Approve in System Settings → Privacy & Security |
| Extension shows `[terminated waiting for user]` | Extension was blocked by user | Re-approve; check if MDM policy allows bypass |
| SIP disabled | MDM-managed extension allow-list won't work correctly | Re-enable SIP unless this is a test machine |
| kextstat shows vendor kext not loaded | Kernel extension blocked or not installed | Check MDM kext policy and kext bundle ID |
| `profiles show` returns no SystemExtension payload | MDM policy not delivered | Force Intune sync; check profile assignment |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
macOS SIP (System Integrity Protection) — ENABLED
    │
    └── MDM enrolment (Intune / Jamf)
            │
            ├── System Extension Allow Policy
            │       delivered via MDM configuration profile
            │       (PayloadType: com.apple.system-extension-policy)
            │
            ├── Kernel Extension Allow Policy (macOS < 12 or legacy kexts)
            │       (PayloadType: com.apple.syspolicy.kernel-extension-policy)
            │
            └── App delivering the extension must be installed
                    │
                    └── Extension must be approved (auto via MDM policy, or manual)
                            │
                            └── Extension activates and runs in userspace
                                    (System Extensions — sandboxed, no kernel access)
                                    OR in kernel space (KexT — legacy, avoid)
```

**Key distinction: System Extensions vs Kernel Extensions**

| | System Extension | Kernel Extension (kext) |
|--|-----------------|------------------------|
| macOS version | 10.15+ (Catalina) | Legacy; deprecated in macOS 11+ |
| Runs in | User space (sandboxed) | Kernel space (full access) |
| Stability impact | Low — crashes don't affect kernel | High — crash = kernel panic |
| MDM policy type | `com.apple.system-extension-policy` | `com.apple.syspolicy.kernel-extension-policy` |
| SIP bypass needed | No | No (but required for kext on Apple Silicon) |
| Common users | Endpoint security, VPN, content filters | Legacy AV, legacy VPN, old peripherals |

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Check current extension state**

```bash
systemextensionsctl list
```

Expected good output:
```
2 extension(s)
--- com.example.app.extension
platform: macOS
bundleID: com.example.app.extension
state: [activated enabled]
identifier: <UUID>
```

Bad states to look for:
- `[activated waiting for user]` — user must approve
- `[terminated waiting for user]` — user denied; needs re-approval
- `[activated waiting for user approval]` — MDM policy not delivered or blocked

---

**Step 2 — Verify MDM policy was delivered**

```bash
# List all installed MDM profiles
profiles show -all 2>/dev/null | grep -E "PayloadType|SystemExtension|KernelExtension|TeamIdentifier"
```

Expected: You should see a profile with:
- `PayloadType = com.apple.system-extension-policy`
- `AllowedSystemExtensions` or `AllowedSystemExtensionTypes` containing your vendor's bundle ID

If missing → MDM profile not installed on this device. Check Intune/Jamf assignment.

---

**Step 3 — Check for user-visible security prompt**

```bash
# There's no CLI to see pending approval; check via notification or:
sudo log show --predicate 'subsystem == "com.apple.SystemExtensions"' --last 30m | tail -20
```

Look for: `Requesting activation` or `blocked by user`

---

**Step 4 — Check for conflicting security software**

```bash
# Multiple endpoint security extensions can conflict (e.g. two EDR tools)
systemextensionsctl list | grep -E "EndpointSecurity|NetworkExtension|ContentFilter"
```

If two competing extensions of the same type are present → one will be blocked. macOS allows only one active endpoint security extension of each type from non-Apple vendors.

---

**Step 5 — Check Intune profile delivery status (from admin portal)**

```
Intune portal → Devices → [Mac device] → Device configuration
Look for the profile containing System Extension Allow Policy:
  Status should be: Succeeded
  If "Pending" → device hasn't checked in recently
  If "Error" → check error code; likely bundle ID or team ID mismatch
```

---

## Common Fix Paths

<details><summary>Fix 1 — Extension Blocked Waiting for User Approval (BYOD or non-supervised)</summary>

**When:** Device is NOT MDM-supervised (i.e. user-enrolled via Company Portal, not ADE/DEP). MDM cannot auto-approve extensions on non-supervised devices. The user must manually approve.

**Steps for the user:**
1. Click the notification "System Extension Blocked" or open:
   **System Settings → Privacy & Security → Security** (scroll to bottom)
2. Click **Allow** next to the blocked extension.
3. Authenticate with Touch ID or password.
4. Restart may be required (prompted automatically).

**If no notification appeared:**

```bash
# Tell user to go here directly:
open "x-apple.systempreferences:com.apple.preference.security"
```

**Admin note:** For supervised devices (ADE/Jamf), extensions should be auto-approved by MDM policy. If still prompting, check Step 3 below.

</details>

<details><summary>Fix 2 — MDM System Extension Profile Missing / Not Delivered</summary>

**When:** `profiles show` doesn't show a `com.apple.system-extension-policy` payload.

**From Intune admin portal:**
1. Navigate to **Devices → Configuration profiles**.
2. Find the profile containing the System Extension policy.
3. Check **Assignment** — confirm the device/user is in the assigned group.
4. Navigate to **Devices → [Mac device] → Device configuration** → check profile status.
5. If "Pending": force a sync.

**Force sync from the Mac:**

```bash
# Option 1 — via Intune Company Portal (GUI: tap "Sync")

# Option 2 — CLI trigger MDM check-in
sudo profiles renew -type enrollment
```

**Then wait 5-10 minutes and re-check:**

```bash
profiles show -all | grep -i systemextension
```

</details>

<details><summary>Fix 3 — System Extension Profile Delivered but Extension Still Blocked</summary>

**When:** Profile is present, but `systemextensionsctl list` shows extension still in blocked/waiting state.

**Most common cause:** Bundle ID or Team ID mismatch in the MDM profile.

```bash
# Get the exact bundle ID and team ID from the installed extension
codesign -dvvv /Applications/<AppName>.app/Contents/Library/SystemExtensions/<ExtensionName>.appex 2>&1 | \
    grep -E "TeamIdentifier|Identifier"
```

Compare the output to what's in your MDM profile:
- `TeamIdentifier` → must match `AllowedTeamIdentifiers` or per-extension team ID in the MDM policy
- `Identifier` → must match `AllowedSystemExtensions` bundle ID entry

**If mismatch:**
1. Update the MDM profile with the correct bundle ID / team ID.
2. Re-push profile.
3. Force sync on device.
4. Re-check extension state after 5-10 minutes.

</details>

<details><summary>Fix 4 — Kernel Extension Blocked on Apple Silicon Mac</summary>

**When:** Legacy kext required (old VPN client, legacy peripheral driver) on an Apple Silicon (M1/M2/M3) Mac.

**Important:** Apple Silicon Macs require **reduced security mode** to load third-party kernel extensions. This is a deliberate security restriction. Best practice is to move to a System Extension–based alternative.

**Temporary workaround (test machines only — NOT production):**

1. Shut down the Mac.
2. Hold power button until "Loading startup options" appears.
3. Select the startup volume, then hold `Cmd+R` (or just hold power) to enter Recovery.
4. In Recovery: **Utilities → Startup Security Utility → Security Policy**.
5. Select **Reduced Security** and tick "Allow user management of kernel extensions from identified developers".
6. Restart.

```bash
# After reboot — load the kext manually for testing
sudo kextload /Library/Extensions/<vendor.kext>
kextstat | grep <vendor>
```

**Permanent fix:** Replace the kernel extension–based product with its System Extension equivalent. All major vendors (CrowdStrike, SentinelOne, Cisco AnyConnect, Palo Alto) now offer SE-based versions.

</details>

<details><summary>Fix 5 — Two Conflicting Endpoint Security Extensions</summary>

**When:** Two EDR/AV products are deployed simultaneously. macOS only allows one vendor's endpoint security extension of each type to be active.

```bash
# Find all endpoint security type extensions
systemextensionsctl list | grep -i endpointsecurity
```

**Resolution:**
1. Identify which product is the intended deployment.
2. Uninstall the conflicting product from **Intune → Apps → [conflicting app] → assign Uninstall intent**.
3. Or remove manually on affected device:

```bash
# Uninstall via vendor uninstaller (product-specific)
# Example for CrowdStrike Falcon:
sudo /Applications/Falcon.app/Contents/Resources/falconctl uninstall --maintenance-token <token>
```

4. After removal, the remaining extension should activate:

```bash
systemextensionsctl list
# Should show only one endpoint security extension in [activated enabled] state
```

</details>

---

## Escalation Evidence

Copy and paste this into your ticket before escalating to L3 or vendor support.

```
## Escalation: macOS System Extension Issue

**Device:**
  - Hostname:
  - Model:
  - macOS version:
  - Apple Silicon or Intel:
  - Supervised (ADE): Yes / No
  - MDM: Intune / Jamf / Other

**Extension details:**
  - Affected extension bundle ID:
  - Vendor / product name:
  - Extension type: System Extension / Kernel Extension

**systemextensionsctl list output:**
  [paste here]

**profiles show -all (filtered) output:**
  [paste here — PayloadType, AllowedSystemExtensions, TeamIdentifiers]

**SIP status:**
  [paste: csrutil status]

**Intune profile delivery status:**
  [paste from portal: Devices → [device] → Device configuration]

**Timeline:**
  - When did this start?
  - Any recent macOS update?
  - Any recent MDM profile push?
  - Any new software installed?

**Steps already tried:**
  [ ] User approved in System Settings → Privacy & Security
  [ ] MDM profile verified as delivered
  [ ] Bundle ID / Team ID verified against installed extension
  [ ] Device re-enrolled
  [ ] Device rebooted

**Logs (optional but helpful):**
  sudo log show --predicate 'subsystem == "com.apple.SystemExtensions"' --last 1h
  [paste last 30 lines]
```

---

## 🎓 Learning Pointers

- **System Extensions replaced Kernel Extensions:** Starting macOS 10.15 (Catalina), Apple began deprecating kexts in favour of System Extensions, which run in user space and can't crash the kernel. As of macOS 12 (Monterey), all new security/network software must use System Extensions. If a vendor still ships a kext, that's a flag — look for a newer product version. See [System Extensions overview](https://developer.apple.com/system-extensions/).

- **MDM supervision is required for silent extension approval:** On supervised devices (enrolled via ADE/Apple Business Manager), an MDM profile can auto-approve System Extensions without any user prompt. On user-enrolled (non-supervised) devices, the user MUST manually approve in System Settings. This is a macOS security design, not a configuration error. See [MDM System Extension payload](https://developer.apple.com/documentation/devicemanagement/systemextensions).

- **Bundle ID and Team ID must be exact:** The most common cause of MDM extension policies not working is a typo in the bundle ID or team ID. Always extract these from the actual `.appex` bundle using `codesign -dvvv` rather than copying from vendor documentation, which may be out of date for the installed version.

- **Apple Silicon + legacy kexts = reduced security mode:** Apple Silicon Macs (M-series) enforce stricter boot security. Loading third-party kernel extensions on these machines requires reducing the startup security level, which weakens other protections. The correct fix is to update to a System Extension–based product version. See [Startup security for Apple Silicon](https://support.apple.com/en-gb/guide/security/sec9d2209d50/web).

- **One endpoint security extension wins, one loses:** macOS enforces single-vendor exclusivity per endpoint security extension type. If two security products (EDR/AV) both deploy network or endpoint security extensions, exactly one will be blocked. This is a common conflict during security product migrations where the old product isn't cleanly removed before the new one is deployed.
