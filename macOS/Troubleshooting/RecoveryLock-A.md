# macOS Recovery Lock — Reference Runbook (Mode A: Deep Dive)
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
- macOS Recovery Lock — the password that protects recoveryOS and the Startup Options screen on
  Apple Silicon Macs, configured and managed through Microsoft Intune's Settings Catalog
- Policy configuration, password storage/retrieval, rotation (scheduled and on-demand), and removal
- The RBAC model governing who can configure the policy vs. who can view/rotate the resulting passcode
- Device eligibility constraints (chip architecture, supervision) and their operational consequences

**Does not cover:**
- FileVault disk encryption, Secure Token, or Bootstrap Token — a related but architecturally
  separate credential system (disk *contents* encryption vs. recoveryOS *access* control). See
  `FileVault-A.md` / `FileVault-B.md`. The two features are often confused because both live "below"
  the normal login screen and both are check-in-gated, but they protect different things and are
  configured via different policy types.
- The legacy Intel-era EFI **firmware password** (`firmwarepasswd`) — a related concept from the
  Intel Mac era that Recovery Lock effectively replaces on Apple Silicon. Firmware passwords are not
  supported on Apple Silicon at all; Recovery Lock is the Apple-Silicon-native equivalent, with a
  materially different (and stricter) security model.
- Activation Lock (tied to Find My / iCloud, a separate anti-theft mechanism, not an Intune-managed
  MDM feature in the same sense)

**Assumptions:**
- Tenant is on a current Intune release (this feature reached general availability in stages during
  early-to-mid 2026 — see the Learning Pointers for the exact rollout timeline)
- Devices are enrolled via Apple Business / Automated Device Enrollment (ADE)
- You have at minimum Policy and Profile Manager (for policy configuration) and/or the two
  Recovery-Lock-specific "Remote tasks" permissions (for viewing/rotating the passcode) — these are
  separate grants, see the RBAC section below

---

## How It Works

<details><summary>Full architecture — Recovery Lock lifecycle</summary>

### What Recovery Lock actually protects

Every Apple Silicon Mac boots through a lightweight, always-present **recoveryOS** environment before
handing control to the main OS. From recoveryOS, a user with physical access can:
- Reinstall macOS from scratch (wiping the device)
- Change Startup Security Utility settings (which OSes are allowed to boot, external boot policy)
- Access Terminal-based recovery tools (`diskutil`, target disk mode configuration, etc.)

On an unmanaged consumer Mac, recoveryOS is unprotected by default (beyond the normal Apple ID/Find My
activation lock check on erase-and-reinstall). On a corporate fleet, that's a problem: anyone with
physical possession of a lost or stolen Mac could boot into recoveryOS and erase it, defeating MDM
management, compliance policies, and — if FileVault wasn't yet enabled — potentially accessing data.

**Recovery Lock closes this gap** by requiring a password before recoveryOS or Startup Options will
respond to anything beyond simply booting the installed OS normally.

### Policy configuration path

Recovery Lock is configured as a **Settings Catalog** profile (not a template-based profile, and not
part of the general Endpoint Security > Disk Encryption blade where FileVault lives):

```
Intune → Devices → Configuration → Create → New policy
  Platform: macOS
  Profile type: Settings catalog
  → Add settings → search "Recovery Lock" → category "Recovery Lock Password" → select all
      - Enable Recovery Lock Password: Enabled
      - Recovery Lock Password Rotation Schedule: 1–12 months
```

Once created and assigned, Intune:
1. Generates a strong, random password (the admin does not choose it)
2. Pushes it to the device via the standard MDM declarative/command channel
3. Stores the current value centrally — visible via the **Per setting status report** (Reports >
   Device management > Per setting status report > filter to Recovery Lock Password) or per-device
   under **Passwords and keys**
4. Automatically rotates it on the configured schedule (1–12 months), and can additionally be rotated
   on demand via a device action

### The two-permission RBAC split

This is the single most operationally important architectural detail of this feature. Two entirely
separate authorization surfaces exist:

| Capability | Required role/permission |
|---|---|
| Create/edit the Settings Catalog policy itself | **Policy and Profile Manager** built-in role, or a custom role with device configuration write permissions |
| **Rotate** the Recovery Lock passcode (device action) | **Intune Administrator**, or a custom role with `Remote tasks / Rotate macOS Recovery Lock password` |
| **View** the current Recovery Lock passcode | **Intune Administrator**, or a custom role with `Remote tasks / View macOS recovery lock password` |

An MSP tech with full rights to build and assign the policy can be completely unable to ever retrieve
the resulting passcode if their delegated custom role wasn't explicitly granted the two "Remote tasks"
permissions. This mirrors the RBAC design of other sensitive Intune remote actions (e.g., BitLocker
recovery key view rights on Windows), but it is easy to miss the first time because the *policy*
permission and the *secret retrieval* permission feel like they should be the same thing — they
are not.

### Check-in-gated rotation

Both scheduled and on-demand rotation follow the same mechanic as every other Apple declarative
management feature in this repo (see `SoftwareUpdates-A.md` for the DDM parallel): **Intune records
the intent to rotate immediately, but the device only actually receives and applies the new passcode
the next time it successfully checks in.** Until that check-in happens, the *previous* passcode
remains the only valid one. If a device is offline (in transit, powered off in storage, network-
restricted), the old passcode stays live — sometimes for a long time — and this is expected, not a
failure.

### Removal mechanics

Two distinct removal paths exist, with different reliability:

- **Unenroll/Retire the device** → Intune automatically clears the Recovery Lock password as part of
  the unenrollment sequence. This is the reliable path.
- **Unassign the policy** (device stays enrolled, just removed from the policy's scope) → Intune
  *attempts* to clear the password, but this is itself a check-in-gated operation like any other
  policy change. If the device never checks in again after being unassigned (common right before a
  wipe-and-retire), the password may never actually clear, and Intune's own visibility into that
  stale password can degrade once the device falls out of active management scope.

</details>

---

## Dependency Stack

```
Apple Silicon SoC (Secure Enclave present) — hardware gate, Intel Macs are permanently excluded
        │
macOS 11.5+
        │
Apple Business → Automated Device Enrollment (ADE) profile
        │
Device enrolls SUPERVISED (only possible via ADE — never via user-initiated Company Portal enrollment)
        │
Intune MDM enrollment + APNs push channel (device must be reachable to receive config AND to report status)
        │
Settings Catalog profile: "Recovery Lock Password" category, assigned + succeeded
        │
Intune backend generates/stores password → surfaces via Per setting status report / Passwords and keys
        │
Admin RBAC: "Remote tasks / View" + "Remote tasks / Rotate" permissions (separate from policy-authoring rights)
        │
recoveryOS / Startup Options password enforcement on the physical device
```

**Every layer must hold**, but two layers are irreversible/non-negotiable once you're past them:
chip architecture (cannot be changed) and supervision state (cannot be changed without wipe +
re-enrollment). Get eligibility checks wrong upfront and no amount of policy troubleshooting later
will fix it.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Policy assigned, device never shows a Recovery Lock password | Device is an Intel Mac | Intune → device → Hardware → chip/model |
| Policy assigned, status "Not applicable" | Device not supervised | Intune → device → Properties → Supervised |
| Policy status "Error" | Conflicting profile or stale group assignment | Device status tab → error code; check group membership |
| Policy "Succeeded" but no password value visible | Reporting lag between config-applied and password-reported | Wait/re-sync; re-check Per setting status report |
| Rotate action greyed out for a specific admin | Missing "Remote tasks / Rotate" custom-role permission | Tenant administration → Roles → check permissions |
| Rotate action succeeds in portal, old password still works on device | Device hasn't checked in since rotation | Force sync; check-in-gated by design |
| Device retired/wiped, Recovery Lock still enforced with unknown password | Unassignment/unenrollment happened before device's last check-in confirmed the clear | Escalate to Apple Support — no MSP-side recovery once the device record and password history are gone |
| Feature entirely missing from tenant's policy catalog | Tenant hasn't yet received the gradual rollout (should be fully available fleet-wide by ~April 2026; verify current Intune service release notes if still missing) | Check Intune "What's New" / message center |
| Password works but user reports it "looks wrong" / mistyped | Recovery Lock passwords are Intune-generated random strings, not user-memorable — always copy-paste from the portal, never dictate over the phone | Retrieve exact value from Passwords and keys, don't retype from memory |

---

## Validation Steps

**1. Confirm the device is eligible before evaluating anything else**
```
Intune → Devices → <device> → Hardware
```
Expected: Apple Silicon chip family listed. Bad: any Intel-based Mac model — stop, out of scope.

**2. Confirm supervision**
```
Intune → Devices → <device> → Properties → Supervised
```
Expected: `Yes`. Bad: `No` — policy will never take effect regardless of assignment correctness.

**3. Confirm the policy exists, is assigned, and targets this device**
```
Intune → Devices → Configuration → <Recovery Lock policy> → Assignments
Intune → Devices → Configuration → <Recovery Lock policy> → Device status
```
Expected: device listed in assignment scope (directly or via group) and status `Succeeded`.

**4. Confirm the password value is retrievable**
```
Intune → Reports → Device management → Per setting status report → filter Recovery Lock Password
```
or per-device:
```
Intune → Devices → <device> → Passwords and keys → View Recovery Lock Passcode
```
Expected: a value present with a recent timestamp. This requires the "View" RBAC permission — if the
option isn't visible at all (not just empty), that's an RBAC gap, not a policy gap (see step 6).

**5. Confirm rotation schedule and history**
```
Intune → Devices → Configuration → <policy> → check "Recovery Lock Password Rotation Schedule" value
Intune → Devices → <device> → device action history → filter "Rotate Recovery Lock Passcode"
```

**6. Confirm your own RBAC permissions if any action is unavailable**
```
Intune → Tenant administration → Roles → <your assigned role> → Permissions
```
Look for both `Remote tasks / Rotate macOS Recovery Lock password` and
`Remote tasks / View macOS recovery lock password` — these are independent grants from each other and
from the policy-authoring `Policy and Profile Manager` role.

**7. Confirm the on-device profile actually landed (the one thing you CAN check locally)**
```bash
sudo profiles -P | grep -i "recovery"
# Expected: a profile referencing Recovery Lock is present
# Note: this confirms the CONFIGURATION landed — it does NOT reveal the password itself, which is
# never stored in cleartext anywhere the local user or a technician at the keyboard can read it
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Eligibility (before touching the policy at all)

1. Pull chip architecture and supervision status for the device from the Intune Hardware/Properties
   blades.
2. If Intel → stop, document as out of scope, communicate this constraint to the customer if they
   asked for fleet-wide coverage (a mixed Intel/Apple Silicon fleet will only ever get partial
   coverage — this is worth flagging proactively during onboarding of the policy, not discovering
   ticket-by-ticket).
3. If not supervised → determine whether re-enrollment via ADE is feasible; this is a planning
   conversation, not a same-day fix.

### Phase 2: Policy delivery

1. Confirm the Settings Catalog policy assignment includes the device (directly or via group,
   including dynamic group rule evaluation lag — Entra ID dynamic groups can take up to a few hours
   to re-evaluate membership after a device attribute changes).
2. Force a device sync rather than waiting for the default check-in interval.
3. Re-check policy device status; `Error` rows should be opened for the specific failure reason
   (most commonly a conflicting profile targeting the same underlying `com.apple.` payload key).

### Phase 3: Password retrieval and RBAC

1. If policy status is `Succeeded` but no password appears, treat this as reporting lag first —
   re-check after a forced sync and after 15-30 minutes.
2. If the "View"/"Rotate" UI elements are entirely absent (not just empty), this is an RBAC issue —
   escalate internally to whoever manages custom role definitions, not to Apple or Microsoft support.

### Phase 4: Rotation behavior

1. Confirm any rotation (scheduled or on-demand) is check-in-gated — a device that appears to "still
   have the old password" almost always just hasn't checked in since the rotation was recorded.
2. Cross-reference device action history for the specific rotation event's timestamp against the
   device's last check-in timestamp to confirm this diagnosis rather than assuming rotation failed.

### Phase 5: Decommission safety

1. Before any wipe, retirement, or long-term offlining of a Recovery-Lock-enabled device, force a
   sync and confirm current passcode visibility one final time.
2. Prefer the "Unenroll/Retire" path (auto-clears) over "Unassign policy then wipe separately" — the
   latter has a real gap window where the device can be locked out permanently if it goes offline
   between unassignment and the next check-in.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Fleet-wide eligibility audit before enabling Recovery Lock as a new policy</summary>

**Scenario:** Before rolling out a new Recovery Lock policy to an entire macOS fleet, determine what
fraction of devices are actually eligible so expectations are set correctly.

```
1. Export the full macOS device list from Intune (Devices → All devices → filter macOS → Export)
2. Cross-reference each device's chip/model column against Apple's Apple-Silicon model list
3. Cross-reference each device's Supervised column
4. Segment into three buckets:
   - Eligible now (Apple Silicon + supervised) → assign policy
   - Ineligible permanently (Intel) → document as out of scope, no action possible
   - Ineligible but fixable (Apple Silicon, not supervised) → queue for wipe + ADE re-enrollment
5. Only assign the Settings Catalog policy to the "Eligible now" group — assigning it tenant-wide to
   a mixed-eligibility group creates noisy Not-applicable/Error rows that obscure genuine failures
```

**Rollback:** N/A — planning/inventory exercise, no changes made until step 5.

</details>

<details>
<summary>Playbook 2 — Safe decommission sequence for a Recovery-Lock-enabled Mac</summary>

**Scenario:** A managed, Recovery-Lock-enabled Mac needs to be retired, resold, or returned to a
leasing company, and must not end up in a permanently locked recoveryOS state.

```
1. Confirm device is online: Intune → device → last check-in time (should be recent)
2. Force a sync: Intune → device → Sync
3. Wait for sync confirmation, then retrieve and log the current passcode as a safety net:
   Intune → device → Passwords and keys → View Recovery Lock Passcode → record in asset/decommission
   ticket (treat with the same handling care as a BitLocker recovery key)
4. Initiate Retire or Wipe from Intune (NOT a local-only erase) so the unenrollment sequence runs and
   Intune's automatic Recovery Lock clear is triggered
5. Confirm device shows as unenrolled/retired in Intune before physically releasing the hardware
6. If a local-only erase already happened before this checklist was followed and the device is now
   locked: use the recorded passcode from step 3 if captured; if not captured, this requires Apple
   Support engagement with proof of purchase — there is no MSP-side bypass
```

**Rollback:** N/A — this is itself a safety procedure, not a reversible change.

</details>

<details>
<summary>Playbook 3 — RBAC remediation for delegated MSP admin roles</summary>

**Scenario:** A tier-2 tech has Policy and Profile Manager rights (can build the policy) but reports
being unable to view or rotate Recovery Lock passcodes for customers they support.

```
1. Identify the tech's assigned custom role: Intune → Tenant administration → Roles → find assignment
2. Open the custom role → Permissions → Remote tasks category
3. Confirm/add both, independently:
   - Rotate macOS Recovery Lock password
   - View macOS recovery lock password
4. Scope the role assignment to only the device/user groups this tech should have access to
   (standard least-privilege practice — do not grant tenant-wide if the tech only supports a subset
   of customers in an MSP multi-tenant model)
5. Have the tech sign out/in or wait for role propagation (typically near-immediate but can take a
   few minutes), then re-test
```

**Rollback:** Remove the two permissions from the custom role if granted in error.

</details>

---

## Evidence Pack

```powershell
# Run in a PowerShell session with the Microsoft Graph Beta module connected.
# Collects Recovery Lock policy + assignment + eligibility evidence for a specific device or fleet-wide.
# This mirrors the companion Get-RecoveryLockAudit.ps1 script in Scripts/ — use that script for the
# full fleet-wide report; this block is for a single-device deep-dive during an active escalation.

Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All" -NoWelcome

$deviceName = Read-Host "Enter device name"
$device = Get-MgBetaDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'"

if (-not $device) {
    Write-Host "Device not found." -ForegroundColor Red
} else {
    [PSCustomObject]@{
        DeviceName        = $device.DeviceName
        SerialNumber      = $device.SerialNumber
        Model             = $device.Model
        OSVersion         = $device.OsVersion
        IsSupervised      = $device.IsSupervised
        LastSyncDateTime  = $device.LastSyncDateTime
        EnrollmentType    = $device.DeviceEnrollmentType
        ManagementState   = $device.ManagementState
    } | Format-List
    Write-Host "NOTE: chip architecture (Apple Silicon vs Intel) is not reliably exposed as a" -ForegroundColor Yellow
    Write-Host "structured Graph property on managedDevice — cross-reference the Model value above" -ForegroundColor Yellow
    Write-Host "against Apple's model identifier list, or check the Hardware blade in the portal." -ForegroundColor Yellow
}
```

---

## Command Cheat Sheet

| Task | Where |
|---|---|
| Check device chip/model | Intune → device → Hardware |
| Check supervision status | Intune → device → Properties |
| Create/edit Recovery Lock policy | Intune → Devices → Configuration → Settings catalog → "Recovery Lock Password" category |
| Check policy assignment/status | Intune → Devices → Configuration → <policy> → Device status |
| View current passcode | Intune → device → Passwords and keys → View Recovery Lock Passcode |
| Fleet-wide passcode report | Intune → Reports → Device management → Per setting status report |
| Rotate on demand | Intune → device → device actions → Rotate Recovery Lock Passcode |
| Check rotation history | Intune → device → device action history |
| Check own RBAC permissions | Intune → Tenant administration → Roles → <role> → Permissions |
| Confirm profile landed locally (device-side) | `sudo profiles -P \| grep -i recovery` |
| Force device check-in | Intune → device → Sync |
| Unenroll (auto-clears Recovery Lock) | Intune → device → Retire or Wipe |

---

## 🎓 Learning Pointers

- **This feature completed a gradual rollout during 2026** — Microsoft's own documentation for the
  Rotate device action explicitly notes it was "gradually rolling out" with "full availability
  expected by late April 2026." If a tenant still doesn't see the Recovery Lock category in the
  Settings Catalog or the Rotate action on a device, check the Intune message center / release notes
  before assuming misconfiguration. [Rotate Recovery Lock passcode device action](https://learn.microsoft.com/en-us/intune/device-management/actions/rotate-recovery-lock-passcode)

- **Recovery Lock and Bootstrap Token share a root dependency but solve different problems.** Both
  require ADE-based supervision and both are check-in-gated, which is why they get confused. But
  Bootstrap Token governs *who can be a FileVault user / grant Secure Tokens silently* (data
  encryption layer), while Recovery Lock governs *who can boot into recoveryOS at all* (pre-boot
  access control layer). A device can have one without the other depending on policy configuration,
  even though both ultimately depend on the same supervision prerequisite. See `FileVault-A.md`.

- **The two-permission RBAC split (policy-author vs. secret-viewer) is a deliberate security
  boundary, not an oversight** — treat it the same way you'd treat BitLocker recovery key view rights
  on the Windows side: the people who can *build* device management policy shouldn't automatically be
  the same people who can *read every device's unlock secret*. Model your MSP's custom roles
  accordingly rather than granting Intune Administrator broadly as a shortcut.

- **There is no local-side compensating control.** Every other topic in this `macOS/` domain has at
  least one local CLI command (`fdesetup`, `profiles`, `sysadminctl`) that lets a technician verify
  or partially work around a problem at the keyboard. Recovery Lock deliberately has none — that's
  the point of the feature, but it means your escalation path for a genuinely stuck device is Apple
  Support, not a script. Set customer expectations accordingly before enabling this policy.

- **Treat the Recovery Lock passcode with recovery-key-grade handling discipline.** It's a long,
  Intune-generated random string, not something to read aloud over the phone or write in a shared
  chat. Build it into whatever secure-secret-handling process your MSP already uses for BitLocker
  recovery keys and FileVault personal recovery keys. [Configure Recovery Lock on macOS devices](https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/configure-recovery-lock-macos)
