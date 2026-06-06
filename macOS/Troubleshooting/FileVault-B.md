# FileVault — Hotfix Runbook (Mode B: Ops)
> Fix or escalate FileVault encryption issues in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these first — results tell you which fix path to follow:

```bash
# 1. FileVault status and encryption progress
fdesetup status
# Expected (healthy): "FileVault is On."
# Bad: "FileVault is Off.", "Encryption in progress (N% complete)", or error

# 2. Check if device is Intune-managed and escrow is required
profiles show -type enrollment | grep -E "MDM|Intune"
# Expected: Shows MDM enrollment profile

# 3. Verify recovery key escrow to Intune
fdesetup showrecovery
# Note: This may require admin auth; output shows if a personal key exists

# 4. Check FileVault users (who can unlock)
fdesetup list
# Expected: Lists UPN/username of enabled FileVault users
# Bad: Empty list = no one can unlock after reboot

# 5. Secure Token status (required for FileVault on Apple Silicon)
sysadminctl -secureTokenStatus <username>
# Expected: "Secure token is ENABLED for user <username>"
```

**Interpretation table:**

| `fdesetup status` output | Action |
|--------------------------|--------|
| `FileVault is On.` | Check escrow status → Fix 1 if key not escrowed |
| `FileVault is Off.` | Enable FileVault → Fix 2 |
| `Encryption in progress` | Wait; verify % is progressing → Fix 3 if stuck |
| `FileVault is On (Encrypting)` | Normal post-enable state; let it finish |
| Error: `Unable to communicate with the fdekeystore` | FileVault daemon issue → Fix 4 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Apple Secure Enclave (T2 / Apple Silicon chip)
        │
        ▼
Secure Token granted to at least one admin user
        │
        ▼
FileVault enabled (fdesetup enable or MDM command)
        │
        ├── Local admin (Bootstrap Token holder) OR user account enabled for FV
        │
        ├── Recovery Key generated and stored
        │         └── Personal recovery key escrowed to Intune MDM
        │                   └── Bootstrap Token issued to MDM
        │
        └── fdesetup agent running (com.apple.security.FDERecoveryAgent)
                  └── Network connectivity to push.apple.com (for MDM escrow)
```

**Key concepts:**
- **Secure Token** — a cryptographic token granted to user accounts that allows them to be FileVault-enabled. Without it, a user can log in but cannot unlock the disk at boot.
- **Bootstrap Token** — a volume-level token that allows the MDM (Intune) to escrow a recovery key and unlock the disk without user interaction (e.g. after remote wipe or password reset). Issued when the device enrolls via ADE with a supervised profile.
- On **Apple Silicon (M1+)**, all of this flows through the Secure Enclave — the process is more tightly controlled than T2-era Macs.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm FileVault is actually on**
```bash
fdesetup status
```
- `FileVault is On.` → proceed to Step 2
- `FileVault is Off.` → go to Fix 2

**Step 2 — Check who can unlock the disk**
```bash
fdesetup list
```
- Expected: At least one user listed (the primary user's account)
- If empty or missing the primary user → go to Fix 5

**Step 3 — Check if recovery key is escrowed to Intune**

In the Intune admin center:
- **Devices → macOS → select device → Recovery keys**
- Key should be present with a recent timestamp
- If missing → go to Fix 1

**Step 4 — Verify Secure Token (Apple Silicon and T2 Macs)**
```bash
sysadminctl -secureTokenStatus <primaryUsername>
# Also check admin account:
sysadminctl -secureTokenStatus <adminUsername>
```
- If user lacks Secure Token → they cannot be a FileVault user → go to Fix 6

**Step 5 — Check Bootstrap Token status**
```bash
profiles show -type bootstraptoken
# If Bootstrap Token is escrowed: shows token details
# If not: "Bootstrap Token is not escrowed"
```
- Missing Bootstrap Token means MDM cannot silently rotate the recovery key → go to Fix 7

---

## Common Fix Paths

<details><summary>Fix 1 — Recovery key not escrowed to Intune</summary>

**Cause:** FileVault is on but the personal recovery key was never sent to Intune (common if FV was enabled before MDM enrollment, or the escrow MDM profile wasn't present).

**Fix — rotate and re-escrow the key:**
```bash
# On the Mac (as admin):
# Step 1: Rotate the personal recovery key
sudo fdesetup changerecovery -personal
# You'll be prompted for the current recovery key or admin credentials
# A new key is generated

# Step 2: The Intune MDM profile should automatically capture the new key
# If not, nudge with a manual Intune sync:
sudo profiles renew -type enrollment

# Step 3: Confirm in Intune portal (allow 15 min for sync):
# Devices → macOS → device → Recovery keys
```

**If the key still doesn't appear in Intune:**
```bash
# Check if the FileVault MDM profile is installed:
profiles show -all | grep -A5 "FileVault"
# Look for a payload with type "com.apple.MCX.FileVault2"
# If missing, the Intune FileVault policy isn't targeting this device
```

**Rollback:** N/A — key rotation is non-destructive; the new key replaces the old one.

</details>

<details><summary>Fix 2 — FileVault is off, need to enable via Intune</summary>

**Cause:** FileVault was never enabled. In an Intune-managed environment, this is handled by an Endpoint Security → Disk Encryption policy.

**Via Intune (preferred):**
1. Verify an Intune FileVault policy exists and targets this device:
   - **Intune → Endpoint security → Disk encryption → [your policy]**
   - Check that the device's group is in scope
2. Force a device sync:
   - **Intune → Devices → macOS → select device → Sync**
3. On the device, check if FileVault is now prompting the user:
   - macOS will show a notification asking the user to log in to enable FileVault
   - The user **must log in** to grant their Secure Token to FileVault

**Manual enable (break-glass):**
```bash
sudo fdesetup enable -user <username>
# User must be logged in or you must supply credentials
# A personal recovery key is displayed — copy it immediately
# Then escrow it manually via Intune if automatic escrow fails
```

**Rollback:** `sudo fdesetup disable` — disables FileVault and decrypts the volume. Requires admin auth. **Decryption takes hours on large drives.**

</details>

<details><summary>Fix 3 — Encryption stuck or paused</summary>

**Cause:** Encryption progress stalled. Common causes: laptop not plugged in (FileVault pauses on battery), low disk space, or a system sleep interrupting the process.

**Diagnostics:**
```bash
# Check encryption progress
fdesetup status
# If showing % — note the percentage, wait 5 min, check again

# Check disk space (need at least 10% free)
df -h /
```

**Fix:**
```bash
# 1. Connect to power — FileVault WILL pause on battery on some models
# 2. Keep the Mac awake (disable sleep during encryption):
sudo pmset -b sleep 0 disksleep 0
# Restore after encryption completes:
sudo pmset -b sleep 10 disksleep 10

# 3. If encryption appears completely stuck (same % for >2h):
# Restart the Mac — encryption resumes from where it left off on next boot
sudo reboot
```

**Rollback:** N/A — cannot roll back encryption in progress without disabling FileVault.

</details>

<details><summary>Fix 4 — fdesetup daemon error / FileVault unresponsive</summary>

**Cause:** The `com.apple.security.FDERecoveryAgent` launch daemon has crashed or is in a bad state.

```bash
# Check daemon status:
sudo launchctl list | grep -i fde

# Restart the daemon:
sudo launchctl kickstart -k system/com.apple.security.FDERecoveryAgent

# If that fails, try a full service restart sequence:
sudo launchctl unload /System/Library/LaunchDaemons/com.apple.security.FDERecoveryAgent.plist
sudo launchctl load /System/Library/LaunchDaemons/com.apple.security.FDERecoveryAgent.plist

# Verify fdesetup responds after restart:
fdesetup status
```

If the daemon cannot be restarted: **reboot the Mac** and test again. If the issue persists after reboot, escalate — may indicate an OS corruption issue or disk hardware problem.

</details>

<details><summary>Fix 5 — User not in FileVault enabled users list</summary>

**Cause:** A new user was added to the Mac after FileVault was enabled. New users don't automatically get FileVault access — they must be added explicitly.

```bash
# Add a user to FileVault (they must log in interactively):
sudo fdesetup add -usertoadd <newUsername>
# Prompts for an existing FV-enabled user's credentials, then the new user's password

# Verify the user was added:
fdesetup list
```

**For managed accounts (Intune/NoMAD):**
- The Bootstrap Token (if escrowed) allows the MDM to add users silently
- If Bootstrap Token is present, an Intune device action or script can handle this
- If Bootstrap Token is missing, the physical user or an admin must do this locally

</details>

<details><summary>Fix 6 — User lacks Secure Token (Apple Silicon / T2)</summary>

**Cause:** The user account was created in a way that didn't grant a Secure Token (e.g. created via LDAP/AD binding, or by a script that didn't go through the normal account creation flow).

```bash
# Check which users have Secure Token:
sysadminctl -secureTokenStatus <username>

# Grant Secure Token (requires an existing Secure Token admin):
sysadminctl -secureTokenOn <targetUsername> -password <targetPassword> \
  -adminUser <adminWithToken> -adminPassword <adminPassword>

# Verify:
sysadminctl -secureTokenStatus <targetUsername>
# Expected: "Secure token is ENABLED for user <targetUsername>"
```

**If no local admin has a Secure Token** (common after re-imaging):
- Use the Bootstrap Token (if escrowed to Intune) to recover
- In Intune: **Devices → macOS → device → Rotate recovery key** or run a custom script
- If Bootstrap Token is also missing: this requires physical access and macOS Recovery Mode to reset

</details>

<details><summary>Fix 7 — Bootstrap Token not escrowed to MDM</summary>

**Cause:** The device was enrolled via user-initiated enrollment (not ADE/supervised), or ADE enrollment completed before the Bootstrap Token feature was enabled in the MDM.

**Check if Bootstrap Token can now be escrowed:**
```bash
# This command will attempt to escrow the Bootstrap Token to the MDM:
sudo profiles install -type bootstraptoken
# If the MDM supports it and device is supervised, this will escrow the token
# Confirm with: profiles show -type bootstraptoken
```

**If the device is not supervised** (non-ADE enrollment):
- Bootstrap Token cannot be escrowed for unsupervised devices — this is an Apple limitation
- Remediation: re-enroll the device via ADE if Bootstrap Token escrow is required (e.g. for FileVault key rotation without user interaction)

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — FileVault Issue
=====================================
Device Name:          [hostname]
Serial Number:        [serial — system_profiler SPHardwareDataType | grep Serial]
macOS Version:        [sw_vers -productVersion]
Chip Type:            [Apple Silicon / Intel T2 / Intel non-T2]
Intune Device ID:     [from Intune portal → device properties]
Enrollment Type:      [ADE/supervised | User-enrolled/unsupervised]

fdesetup status:      [paste output]
fdesetup list:        [paste output]
Secure Token (user):  [sysadminctl -secureTokenStatus <user> output]
Bootstrap Token:      [profiles show -type bootstraptoken output]
Recovery key in Intune: [Yes | No | Last updated: date]

FileVault MDM Profile installed: [Yes | No]
Intune FileVault policy name:    [policy name from Intune]
Intune last sync:     [timestamp from Intune device properties]

Error messages observed:
[paste any errors from fdesetup, system logs, or Intune]

Steps already attempted:
[ ] Forced Intune sync
[ ] Rebooted device
[ ] Checked power/battery
[ ] Verified Secure Token status
[ ] Attempted key rotation
```

---

## 🎓 Learning Pointers

- **Secure Token is the foundation** — without it, an account cannot be a FileVault user, period. On Apple Silicon Macs, the Secure Enclave enforces this at hardware level. Always verify Secure Token status first when FileVault enablement fails. [Apple Platform Security Guide](https://support.apple.com/guide/security/welcome/web)

- **Bootstrap Token is the MSP superpower** — once escrowed to Intune, the Bootstrap Token allows the MDM to rotate FileVault recovery keys, grant Secure Tokens to new users, and unlock the disk after a remote wipe — all without physical presence. Verify it's escrowed on every ADE-enrolled device. [Bootstrap Token overview](https://support.apple.com/en-gb/guide/deployment/dep24dbdcf9e/web)

- **User-initiated enrollment can't get a Bootstrap Token** — this is why ADE (Automated Device Enrollment) matters for corporate Macs. If a device is enrolled via the Company Portal app by a user (not ADE), it won't get Bootstrap Token support, which limits MDM FileVault management capabilities. [Intune ADE for macOS](https://learn.microsoft.com/en-us/mem/intune/enrollment/device-enrollment-program-enroll-macos)

- **FileVault pauses on battery** — this catches engineers off guard when a laptop appears stuck at 47% for hours. Apple pauses encryption on battery to protect against corruption during a power loss. Always plug in before enabling or troubleshooting stalled FileVault encryption.

- **fdesetup is your friend** — it's the local CLI for all FileVault operations. `fdesetup help` shows all subcommands. Key ones: `status`, `list`, `add`, `remove`, `changerecovery`, `showrecovery`, `enable`, `disable`. Use `man fdesetup` for full documentation. All MDM FileVault commands ultimately call this tool.

- **Jamf vs. Intune recovery key escrow differs** — if you're in a mixed environment or migrating from Jamf to Intune, note that Jamf escrows the institutional recovery key while Intune escrows the personal recovery key. After migration, the old Jamf key won't appear in Intune. Rotate the recovery key post-migration to ensure Intune has a current key. [Intune FileVault policy](https://learn.microsoft.com/en-us/mem/intune/protect/encrypt-devices-filevault)
