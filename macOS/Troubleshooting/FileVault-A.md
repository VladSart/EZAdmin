# macOS FileVault — Reference Runbook (Mode A: Deep Dive)
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
- FileVault 2 (APFS and HFS+ volumes on Intel and Apple Silicon Macs)
- Intune-enforced FileVault with Personal Recovery Key (PRK) escrow
- PRK rotation, escrow validation, and retrieval
- Encryption stalls, deferred enablement, and bypass scenarios
- FileVault interaction with Secure Token, Bootstrap Token, and MDM unlock

**Does not cover:**
- Legacy FileVault 1 (pre-Lion, HFS+ home folder encryption)
- eDrive / hardware encryption on non-Apple storage
- Third-party encryption solutions (VeraCrypt, etc.)

**Assumptions:**
- Devices are enrolled in Intune (Microsoft Endpoint Manager)
- macOS 12 (Monterey) or later — some behaviour differs on older releases
- You have Intune admin access and/or local admin on the Mac
- Apple Silicon Macs use Secure Boot with Full Security unless changed

---

## How It Works

<details><summary>Full FileVault architecture</summary>

### FileVault 2 Encryption Model

FileVault 2 uses **XTS-AES-128** encryption on the full volume. On APFS volumes (macOS 10.13+), encryption is handled at the APFS container level, not the partition level.

```
Physical Disk
└── APFS Container (encrypted with Volume Encryption Key)
    ├── Macintosh HD (System volume — read-only sealed snapshot)
    └── Macintosh HD - Data (Data volume — user files, encrypted)
```

The **Volume Encryption Key (VEK)** is protected by a **Key Encryption Key (KEK)**, which is itself derived from:
1. The user's login password (hashed via PBKDF2)
2. The Recovery Key (PRK or institutional recovery key)

### Secure Token — The Gatekeeper

FileVault enablement requires the enabling user to hold a **Secure Token**. Without it, the user's password cannot unlock FileVault.

Secure Token is automatically granted to:
- The first local admin user created during Setup Assistant
- Any user authenticated by an existing Secure Token holder via `sysadminctl`
- Users created by MDM (Intune) when Bootstrap Token is configured correctly

On **Apple Silicon**, Secure Token is also required to create a LocalPolicy — the per-user policy that governs Secure Boot behaviour. This creates a hard dependency: no Secure Token = no LocalPolicy = no FileVault.

### Bootstrap Token — MDM's Master Key

The **Bootstrap Token** is a cryptographic escrow mechanism that allows MDM to grant Secure Token to users automatically, without requiring an interactive admin session.

```
Device Setup Flow (Automated Device Enrollment):
  1. Device enrolls in Intune via ADE
  2. Bootstrap Token is generated on device
  3. Device escrowed Bootstrap Token → Apple Business Manager / Intune
  4. When new user logs in: MDM presents Bootstrap Token → grants Secure Token to user
  5. User can now enable or receive FileVault
```

If Bootstrap Token escrow fails (e.g., ADE not configured, Intune MDM cert issue), Secure Token cannot be auto-granted and FileVault deferred enablement will fail silently.

### Intune FileVault Flow

```
[Intune FileVault Policy] → Deploy to device
        │
        ▼
[Company Portal / MDM agent receives policy]
        │
        ▼
[Checks: Is user Secure Token holder? Is Bootstrap Token escrowed?]
        │
        ├── YES → Enable FileVault at next login
        │          Generate PRK → Escrow PRK to Intune
        │
        └── NO  → Deferred enablement queued
                   Wait for admin or Secure Token holder to log in
```

### Personal Recovery Key (PRK) Escrow

After FileVault is enabled, the PRK is:
1. Generated as a 24-character alphanumeric key (e.g., `AAAA-BBBB-CCCC-DDDD-EEEE-FFFF`)
2. Encrypted with the MDM's public key
3. Uploaded to Intune over HTTPS
4. Stored in Intune → Device → Recovery Keys

Admins can retrieve the PRK from Intune portal or via Graph API. The PRK is single-use — once rotated or retrieved, the old key is invalidated.

### Apple Silicon Differences

On M-series Macs, FileVault is tightly coupled with **Secure Boot**:

```
Apple Silicon Boot Chain:
  iBoot → LocalPolicy (per-user, requires Secure Token) → OS Load

FileVault on Apple Silicon:
  - Each user who can unlock FileVault is listed in the LocalPolicy
  - Adding a FileVault user = updating LocalPolicy = requires Secure Token
  - Cannot enable FileVault without an active Secure Token holder
```

This means deferred MDM enablement on Apple Silicon is more complex than Intel and **requires Bootstrap Token escrow to work reliably**.

</details>

---

## Dependency Stack

```
[Physical Disk — APFS Container]
        │ (protected by)
        ▼
[Volume Encryption Key (VEK)]
        │ (wrapped by)
        ▼
[Key Encryption Key (KEK)]
        │ (derived from)
        ├── User Password + Secure Token
        └── Personal Recovery Key (PRK)
                │ (escrowed to)
                ▼
        [Intune — Recovery Keys]
                │ (escrow requires)
                ▼
        [Bootstrap Token — escrowed to Apple/Intune via ADE]
                │ (requires)
                ▼
        [MDM Enrollment (ADE preferred)]
                │ (requires)
                ▼
        [Apple Business Manager + Intune ADE profile]
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| FileVault shows "Off" in System Settings after policy applied | User lacks Secure Token; deferred enablement queued | `sysadminctl -secureTokenStatus <username>` |
| FileVault enabled but PRK not in Intune | Bootstrap Token not escrowed; escrow failed silently | Intune → Device → Recovery Keys tab; check MDM log |
| "Waiting for next login" shown in Intune FileVault status | Deferred enablement — policy deployed but not yet activated | User must log out and back in; or admin logs in first |
| FileVault encryption stuck at X% for >24h | Disk I/O contention; low battery; device asleep during encryption | `diskutil apfs list` — check encryption progress |
| PRK retrieved but does not work | PRK was rotated after retrieval; or PRK was already used | Check Intune for newer PRK; use Apple ID recovery as fallback |
| FileVault re-prompts after PRK rotation | Normal — rotation policy generates new PRK and escrows it | Verify new PRK in Intune Recovery Keys tab |
| User cannot log in after FileVault enabled | Secure Token not granted; password mismatch at pre-boot | Boot to Recovery → use PRK; check Secure Token holders |
| Bootstrap Token not escrowed | Device not enrolled via ADE; or ADE profile missing Bootstrap Token escrow setting | Intune → ADE profile → Bootstrap Token: Allow |
| Intel Mac: "FileVault is on but this account cannot unlock" | Account added after FileVault was enabled and not granted FV unlock | `fdesetup add -usertoadd <username>` |

---

## Validation Steps

**Step 1 — Check FileVault status**
```bash
fdesetup status
```
Expected (good): `FileVault is On.`  
Bad: `FileVault is Off.` or `Encryption in progress: X% complete`

**Step 2 — Check Secure Token status for all users**
```bash
sysadminctl -secureTokenStatus <username>
# Or list all users:
dscl . -list /Users UniqueID | awk '$2 >= 500' | awk '{print $1}' | \
  while read u; do echo -n "$u: "; sysadminctl -secureTokenStatus "$u"; done
```
Expected (good): `Secure token is ENABLED for user <username>`  
Bad: `Secure token is DISABLED` — this user cannot enable or unlock FileVault

**Step 3 — Check Bootstrap Token escrow status**
```bash
profiles status -type bootstraptoken
```
Expected (good): `Bootstrap Token escrowed to server: YES`  
Bad: `Bootstrap Token escrowed to server: NO` — MDM cannot auto-grant Secure Token

**Step 4 — Check FileVault-enabled users**
```bash
fdesetup list
```
Expected: lists all users who can unlock FileVault at pre-boot  
Bad: list is empty or missing expected users

**Step 5 — Check encryption progress (if in progress)**
```bash
diskutil apfs list | grep -A5 "Encryption Progress"
```
Expected (good): shows `100%` or not shown (complete)  
Bad: stuck at a percentage for extended period

**Step 6 — Verify PRK escrow in Intune**
```
Intune portal → Devices → [Device name] → Recovery Keys
```
Expected: shows a valid recovery key with a timestamp  
Bad: blank, or "No recovery key" — escrow failed

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify the problem
1. Run `fdesetup status` — is FileVault on, off, or encrypting?
2. Check Intune device record → Overview → `Encryption status` field.
3. Check Intune → Device → Recovery Keys — is a PRK stored?
4. Run `sysadminctl -secureTokenStatus <user>` for the primary user.

### Phase 2 — Secure Token problems
1. Identify a user who **does** have Secure Token (typically the first local admin).
2. Log in as that user.
3. Grant Secure Token to the target user:
```bash
sudo sysadminctl -secureTokenOn <targetuser> -password <targetpassword> \
  -adminUser <adminuser> -adminPassword <adminpassword>
```
4. Verify: `sysadminctl -secureTokenStatus <targetuser>`

### Phase 3 — Bootstrap Token not escrowed
1. Confirm the device was enrolled via ADE (not manual/bulk enrollment).
2. In Intune → ADE profile, confirm **Bootstrap Token** is set to **Allow**.
3. Re-push MDM commands: Intune → Device → Sync.
4. Have the user log out and back in — this triggers Bootstrap Token escrow.
5. Verify with `profiles status -type bootstraptoken`.

### Phase 4 — Deferred enablement not completing
1. Confirm the Intune FileVault configuration profile is assigned to the device.
2. Check if the user has logged out and back in since policy was applied.
3. Run `sudo profiles show -type configuration` to verify policy is installed.
4. If Bootstrap Token is escrowed and Secure Token is valid, trigger manually:
```bash
sudo fdesetup enable -defer /tmp/fv_deferral.plist -forceatlogin 1
```
5. User will be prompted at next login.

### Phase 5 — PRK escrow failure
1. Check MDM log for escrow errors:
```bash
log show --predicate 'process == "mdmclient"' --last 1h | grep -i "filevault\|recovery\|escrow"
```
2. If escrow failed, rotate the PRK to trigger a fresh escrow attempt:
   - Intune → Device → Rotate FileVault recovery key
3. Verify new PRK appears in Intune within 15 minutes.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Enable FileVault manually when MDM policy isn't firing</summary>

Use when: FileVault policy deployed, deferred enablement stuck, and you need to enable immediately.

```bash
# Enable FileVault with deferred prompt at login
sudo fdesetup enable -defer /tmp/fv_setup.plist -forceatlogin 0 -dontaskatlogout

# Or enable immediately (requires user password):
sudo fdesetup enable -outputplist /tmp/fv_key.plist
# PRK is written to /tmp/fv_key.plist — retrieve and store it immediately
cat /tmp/fv_key.plist
# Manually escrow to Intune via Graph API or enter in device recovery keys
```

**Rollback:** `sudo fdesetup disable` — requires admin + FileVault unlock. Do not disable without ensuring PRK is stored.

</details>

<details><summary>Playbook 2 — Grant Secure Token to a user</summary>

Requires: another user on the device who already holds Secure Token (usually the local admin).

```bash
# Check who has Secure Token
dscl . list /Users | grep -v "^_" | while read u; do
  status=$(sysadminctl -secureTokenStatus "$u" 2>&1)
  echo "$u: $status"
done

# Grant Secure Token (interactive — will prompt for passwords)
sudo sysadminctl -secureTokenOn <targetUsername> -password -

# Or non-interactive (for scripted use):
sudo sysadminctl -secureTokenOn <targetUsername> -password "<targetPass>" \
  -adminUser <adminUsername> -adminPassword "<adminPass>"

# Verify
sysadminctl -secureTokenStatus <targetUsername>
```

**Apple Silicon note:** on M-series Macs, granting Secure Token also updates the LocalPolicy. A restart may be required for the new user to appear in FileVault's pre-boot user list.

**Rollback:** `sudo sysadminctl -secureTokenOff <targetUsername>` — removes the token. Use with caution on the last Secure Token holder; this can lock you out of FileVault management.

</details>

<details><summary>Playbook 3 — Retrieve PRK from Intune and unlock a Mac</summary>

```
1. Intune portal → Devices → [Device Name] → Recovery Keys
2. Click "Show recovery key" — confirm your identity if prompted
3. Copy the 24-character PRK (format: XXXX-XXXX-XXXX-XXXX-XXXX-XXXX)
4. At the Mac pre-boot screen: enter the PRK as the password
5. macOS will boot and prompt you to reset the user's password
```

Via Graph API (for scripted retrieval):
```powershell
# Requires: DeviceManagementManagedDevices.Read.All permission
$deviceId = "<IntuneDeviceId>"
$uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$deviceId/getFileVaultKey"
$response = Invoke-MgGraphRequest -Method GET -Uri $uri
$response.value  # Returns the PRK
```

**After use:** the PRK is consumed. Intune will automatically rotate and re-escrow a new PRK on the next MDM check-in. Confirm the new PRK appears in Intune within 30 minutes.

</details>

<details><summary>Playbook 4 — Force PRK rotation via Intune</summary>

Use when: existing PRK is stale, escrow is missing, or PRK was compromised.

```
Intune portal → Devices → [Device Name] → … → Rotate FileVault recovery key
```

Or via Graph API:
```powershell
$deviceId = "<IntuneDeviceId>"
$uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$deviceId/rotateFileVaultKey"
Invoke-MgGraphRequest -Method POST -Uri $uri
```

Device must be online and MDM channel active. Check-in can be forced: Intune → Device → Sync.

New PRK will appear in Intune Recovery Keys within 15–30 minutes of device check-in.

**Rollback:** not directly reversible — the old PRK is invalidated. Ensure the new PRK escrows successfully before considering this complete.

</details>

---

## Evidence Pack

```bash
#!/bin/bash
# FileVault Evidence Collection Script
# Run as: sudo bash collect-fv-evidence.sh
# Output: /tmp/fv-evidence-<hostname>-<date>.txt

HOSTNAME=$(hostname)
DATE=$(date +%Y-%m-%d_%H%M)
OUT="/tmp/fv-evidence-${HOSTNAME}-${DATE}.txt"

echo "=== FileVault Evidence Pack ===" > "$OUT"
echo "Host: $HOSTNAME  |  Date: $(date)" >> "$OUT"
echo "macOS: $(sw_vers -productVersion)  |  Build: $(sw_vers -buildVersion)" >> "$OUT"
echo "" >> "$OUT"

echo "=== FileVault Status ===" >> "$OUT"
fdesetup status >> "$OUT" 2>&1
echo "" >> "$OUT"

echo "=== FileVault Enabled Users ===" >> "$OUT"
fdesetup list >> "$OUT" 2>&1
echo "" >> "$OUT"

echo "=== Secure Token Status (all users) ===" >> "$OUT"
dscl . list /Users UniqueID 2>/dev/null | awk '$2 >= 500 {print $1}' | while read u; do
  echo -n "  $u: " >> "$OUT"
  sysadminctl -secureTokenStatus "$u" 2>&1 >> "$OUT"
done
echo "" >> "$OUT"

echo "=== Bootstrap Token Status ===" >> "$OUT"
profiles status -type bootstraptoken >> "$OUT" 2>&1
echo "" >> "$OUT"

echo "=== MDM Enrollment Status ===" >> "$OUT"
profiles status -type enrollment >> "$OUT" 2>&1
echo "" >> "$OUT"

echo "=== Installed Configuration Profiles (FileVault-related) ===" >> "$OUT"
sudo profiles show -type configuration 2>/dev/null | grep -A5 -i "filevault\|encryption\|recovery" >> "$OUT"
echo "" >> "$OUT"

echo "=== Disk Encryption State ===" >> "$OUT"
diskutil apfs list 2>/dev/null | grep -E "Container|Volume|Encryption" >> "$OUT"
echo "" >> "$OUT"

echo "=== Recent MDM FileVault Log Entries (last 2h) ===" >> "$OUT"
log show --predicate 'process == "mdmclient"' --last 2h 2>/dev/null | \
  grep -i "filevault\|recovery\|escrow\|token" | tail -50 >> "$OUT"
echo "" >> "$OUT"

echo "Evidence saved to: $OUT"
echo "Upload this file to the support ticket."
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check FileVault status | `fdesetup status` |
| List FileVault-enabled users | `fdesetup list` |
| Check Secure Token for a user | `sysadminctl -secureTokenStatus <username>` |
| Grant Secure Token | `sudo sysadminctl -secureTokenOn <user> -password -` |
| Check Bootstrap Token escrow | `profiles status -type bootstraptoken` |
| Enable FileVault (deferred) | `sudo fdesetup enable -defer /tmp/fv.plist` |
| Enable FileVault (immediate) | `sudo fdesetup enable -outputplist /tmp/key.plist` |
| Disable FileVault | `sudo fdesetup disable` |
| Add existing user to FileVault | `sudo fdesetup add -usertoadd <username>` |
| Remove user from FileVault | `sudo fdesetup remove -user <username>` |
| Check encryption progress | `diskutil apfs list \| grep -A5 "Encryption"` |
| View MDM FileVault logs | `log show --predicate 'process=="mdmclient"' --last 2h \| grep -i filevault` |
| Retrieve PRK (Intune portal) | Devices → [Device] → Recovery Keys → Show recovery key |
| Rotate PRK (Intune portal) | Devices → [Device] → … → Rotate FileVault recovery key |
| Force MDM sync | `sudo profiles renew -type enrollment` |

---

## 🎓 Learning Pointers

- **Secure Token is the root dependency — everything else flows from it.** Before troubleshooting any FileVault issue, always verify Secure Token status first. If the user doesn't have it, FileVault enablement, rotation, and even MDM-granted recovery are all blocked. [Secure Token overview](https://support.apple.com/guide/deployment/secure-token-and-bootstrap-token-depa7f3e0b3d/web)

- **Bootstrap Token escrow only works with ADE-enrolled devices.** Manually enrolled Macs (corporate-owned but not in ABM/ASM, or user-enrolled BYOD) cannot escrow Bootstrap Token. This means MDM-deferred FileVault works reliably only on ABM-provisioned devices. For non-ADE Macs, plan for a manual Secure Token grant workflow. [Bootstrap Token and MDM](https://support.apple.com/en-gb/guide/deployment/dep24dbdcf9e/web)

- **On Apple Silicon, each FileVault user requires a LocalPolicy update, which requires a restart.** This means adding a new user to FileVault (or MDM-enabling FileVault) on an M-series Mac may not take effect until the device restarts. Don't assume the change is applied until after reboot. [Apple Silicon security guide](https://support.apple.com/guide/security/welcome/web)

- **The PRK is single-use and rotates automatically.** Once used at the pre-boot screen, the old PRK is invalidated and macOS generates a new one on next boot. Intune will automatically escrow the new key, but there's a ~15–30 minute window where no valid PRK exists in Intune. Always verify the new key appears before closing an incident. [FileVault and Intune](https://learn.microsoft.com/en-us/mem/intune/protect/encrypt-devices-filevault)

- **FileVault deferred enablement on Intel Macs can silently fail if the Intune MDM profile installs before the user logs in for the first time.** The profile queues enablement for "next login," but if no eligible Secure Token user logs in, nothing happens. Schedule a reminder or use a nudge tool (e.g., Nudge or Company Portal prompt) to ensure users log out and back in after enrollment. [Intune FileVault deferred enablement](https://learn.microsoft.com/en-us/mem/intune/protect/encrypt-devices-filevault#how-filevault-works-with-intune)

- **`fdesetup` and `diskutil apfs` show different views of the same truth.** `fdesetup status` reflects the OS-level FileVault policy state; `diskutil apfs list` shows the actual volume encryption state. They can diverge briefly during enablement or if a volume was encrypted outside of FileVault. Always check both when the status is ambiguous.
