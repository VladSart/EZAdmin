# macOS ADE Local Admin Account with LAPS (Intune) — Reference Runbook (Mode A: Deep Dive)
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

**Covers:** Intune's *macOS local account configuration with LAPS* — local admin and local standard user
account creation during ADE Setup Assistant, Intune-escrowed randomized admin password, automatic and manual
rotation, RBAC, auditing, and the secure-token / password-policy interactions that cause most tickets.

**Does not cover:** Windows LAPS (`Intune/Troubleshooting/LAPS-A/B.md`), Recovery Lock passcodes
(`RecoveryLock-A/B.md`), FileVault key escrow (`FileVault-A/B.md`), Platform SSO account creation
(`Platform-SSO-A/B.md`), third-party macOS LAPS tools (e.g. community `macOSLAPS`, Jamf LAPS).

**Assumptions:** Macs purchased through ABM/ASM, an Intune ADE token in place, macOS 12+.

---
## How It Works

<details><summary>Full architecture</summary>

### Where the feature lives

It isn't a separate policy type. It's an optional block on the **macOS ADE enrollment profile**
(**Account settings** tab, configured during step 12 of profile creation). Both *Local administrator
account* and *Local user account* default to **No**. The options work with and without user device
affinity profiles.

```
ABM/ASM ──assign serial──► Intune ADE token ──► macOS ADE profile
                                                   ├─ Account settings
                                                   │   ├─ Local administrator account (LAPS)
                                                   │   └─ Local user account (standard)
                                                   └─ Await final configuration = Yes (forced by backend)
                         Device erase → Setup Assistant → ADE check-in
                                   │
                                   ▼
             AccountConfiguration commands during Setup Assistant
             ├─ create admin  (username/fullname from template, optional hidden)
             │    password = 15 chars (upper/lower/digits/symbols), escrowed + encrypted in Intune
             └─ create/prefill local user (Standard by default)
                                   │
                                   ▼
             First sign-in (local user) → receives SECURE TOKEN
             LAPS admin → never receives a secure token
```

Because accounts are created while Setup Assistant is held, the backend always sets **Await final
configuration = Yes** whenever any account option is on.

### Eligibility rules (the reason most "no password" tickets exist)

- Only **new** ADE enrollments that occur as part of **initial device setup** after a factory reset.
- Re-initiating ADE from a running install (`profiles renew -type enrollment`) is **unsupported**.
- Existing enrolled Macs must be wiped and re-enrolled with a LAPS-enabled profile.
- macOS 12 or later; device must be synced from ABM/ASM to Intune.

A quick eligibility test from the portal: if **Passwords and keys** shows a *Local administrator account
password*, the device is Intune-LAPS-managed. If not, it isn't — regardless of what the profile now says.

### Account templates

| Field | Default | Variables |
|---|---|---|
| Admin account username | `Admin` | `{{serialNumber}}`, `{{partialupn}}`, `{{managedDeviceName}}`, `{{onPremisesSamAccountName}}` |
| Admin account full name | `Admin` | `{{username}}`, `{{serialNumber}}`, `{{onPremisesSamAccountName}}` |
| Hide in Users & Groups | Not configured | — |
| Admin password rotation period | (180-day auto rotation always applies) | 1–180 days, additional to the 180-day cycle |
| Local user account type | Standard | Becomes **Administrator** if no local admin account is configured (a macOS setup requirement) |
| Prefill account info / Restrict editing | Not configured | Primary account name defaults to `{{partialupn}}`, full name to `{{username}}` |

For **userless** profiles Microsoft recommends `{{serialNumber}}-admin` so each device has a unique admin name.
Note `{{partialupn}}` and `{{onPremisesSamAccountName}}` need a user context — plan templates accordingly.

### Secure token consequence

The LAPS admin **does not receive a secure token** (platform limitation). The first account to sign in —
which will be the local user — gets it. Implications:
- The LAPS admin can't unlock FileVault at the pre-boot screen or grant secure tokens to others.
- Rely on the Intune-escrowed FileVault **personal recovery key** and an escrowed **Bootstrap Token** for
  recovery and MDM-driven secure-token operations.
- The LAPS admin is still a full local administrator in the OS (sudo, System Settings admin prompts).

### Password policy interaction

For LAPS devices, deliver password policy **only through Settings catalog** with **Change at next
authentication** disabled. Password settings in **compliance policies** or **device restriction** templates
enable *Change at next authentication* by default and can break sign-in for the new accounts.

Separate known issue: on **macOS earlier than 26.4**, ADE + local admin + a targeted passcode profile prompts
an **admin** password reset even with *Change at next auth* off or Max Age set. Workaround: after the reset,
rotate from Intune to resync. Fixed by upgrading to 26.4.

### Rotation & viewing

- Automatic rotation every **six months (180 days)**, plus the optional configured period (1–180 days).
- Manual: device action **Rotate local admin password** (Devices → macOS → device → Overview).
- Both land on the device at **check-in**; the portal shows *last rotated* time in **Passwords and keys**.
- Viewing and rotating each create **Intune audit events**:
  - `Get AdminAccountDto` — password viewed
  - `rotateLocalAdminPassword ManagedDevice` — password rotated

### RBAC

Category **Enrollment programs**: *View macOS admin password*, *Rotate macOS admin password*. Neither is in
any built-in Intune role nor granted through the Entra **Intune Administrator** role — a **custom Intune
role** is required. Profile authoring itself needs the ADE profile permissions described in the ADE setup
article.

</details>

---
## Dependency Stack

```
[8] Helpdesk retrieves/rotates password  ← custom role (Enrollment programs: View/Rotate macOS admin password)
[7] Rotation lands on device             ← device check-in
[6] Admin sign-in works                  ← no "change at next auth" (Settings catalog policy); macOS ≥ 26.4 or resync after reset
[5] Local user holds secure token        ← first to sign in; admin never gets one
[4] Accounts created in Setup Assistant  ← Await final configuration (forced Yes)
[3] ADE enrollment at initial setup      ← factory reset; NOT profiles renew
[2] LAPS-enabled macOS ADE profile       ← Account settings: Local administrator account = Yes
[1] Serial assigned to token + profile   ← ABM/ASM → Intune sync
[0] macOS 12+, Apple Silicon or Intel, network to Apple + Intune during Setup Assistant
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No password in Passwords and keys | Device enrolled before LAPS was enabled on profile / not ADE / re-enrolled via `profiles renew` | `profiles status -type enrollment`; enrollment date vs. profile change date |
| Helpdesk can't see password or rotate button | Missing custom RBAC permissions or scope tags | Role assignments; `Get-MacLAPSAudit.ps1` roles report |
| Admin forced to reset password at first use | macOS < 26.4 + passcode profile (known issue) | `sw_vers`; profile list |
| Admin/user forced to change password on new devices | Compliance/device-restriction password settings (Change at next auth default on) | Policy inventory in script output |
| Portal password fails on device | Not yet checked in after rotation; local change; pre-26.4 reset | Last check-in vs. last rotated |
| Admin can't unlock FileVault | No secure token by design | `sysadminctl -secureTokenStatus` |
| Standard user unexpectedly an admin | No local admin configured → user account becomes admin (macOS requirement) | Profile Account settings |
| Admin account missing from login window | *Hide in Users & Groups* | `dscl . -read /Users/<admin> IsHidden` |
| Admin username identical across userless Macs | Static template | Use `{{serialNumber}}-admin` |
| Setup Assistant pauses longer than before | Await final configuration forced Yes while accounts are provisioned | Expected |

---
## Validation Steps

1. **ADE path** — `profiles status -type enrollment` → Good: `Enrolled via DEP: Yes`, `MDM enrollment: Yes (User Approved)`.
2. **Admin account** — `dscl . -read /Users/<admin> UniqueID RealName` → Good: record exists. Bad: `eDSRecordNotFound`.
3. **Admin group** — `dseditgroup -o checkmember -m <admin> admin` → Good: `yes … is a member of admin`.
4. **Secure token** — `sysadminctl -secureTokenStatus <admin>` → Good (expected): `DISABLED`; local user `ENABLED`.
5. **Bootstrap token** — `sudo profiles status -type bootstraptoken` → Good: `escrowed to server: YES`.
6. **Password policy** — `sudo profiles show -type configuration | grep -i changeAtNextAuth` → Good: no match or `0`.
7. **Portal** — Passwords and keys shows the password and a recent *last rotated*; Audit logs show expected events.
8. **Fleet** — run `macOS/Scripts/Get-MacLAPSAudit.ps1` → devices flagged `NOT_ADE`, `NO_LAPS_PROFILE`,
   `OS_BELOW_26_4`, and password-policy conflicts.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Profile design:** Is *Local administrator account* = Yes on the profile the serial is actually
assigned to (check the device's profile in the token's device list, not just the default profile)?

**Phase 2 — Enrollment:** Was the device erased and enrolled in Setup Assistant *after* LAPS was enabled?
`profiles renew` and manual enrollments never qualify.

**Phase 3 — Account creation:** Did the admin account get created (dscl)? If not, capture Setup Assistant
logs: `log show --predicate 'subsystem == "com.apple.ManagedClient"' --last 1d`.

**Phase 4 — First sign-in:** Password-change prompts → Fix password-policy source; pre-26.4 known issue.

**Phase 5 — Operations:** RBAC for viewing/rotating; check-in for rotation; audit trail for accountability.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Enable LAPS on an existing ADE profile (new enrollments only)</summary>

1. **Devices → Enrollment → Apple → Enrollment program tokens → <token> → Profiles → <macOS profile> → Properties → Account settings → Edit**.
2. Local administrator account = **Yes**; username `{{serialNumber}}-admin` for userless, or an agreed
   name; optional Hide; optional rotation period.
3. Decide on Local user account (Standard; prefill `{{partialupn}}`; restrict editing if required).
4. Save. Only devices that **newly** enroll with this profile get the accounts.
5. Replace compliance/device-restriction password settings with a Settings catalog passcode policy with
   *Change at next authentication* disabled **before** enrolling LAPS devices.
</details>

<details><summary>Playbook 2 — Bring existing Macs under LAPS (wipe + re-enroll)</summary>

1. Confirm serial → LAPS-enabled profile assignment.
2. Ensure FileVault recovery key and Bootstrap Token are escrowed; user data backed up (OneDrive KFM etc.).
3. Issue **Wipe** (or Erase All Content and Settings).
4. Device runs Setup Assistant online → ADE → accounts created.
5. Validate (Validation Steps 1–7).
**Destructive.** Rollback = restore from backup; the device re-enrolls either way.
</details>

<details><summary>Playbook 3 — Custom helpdesk role for macOS LAPS</summary>

1. **Tenant administration → Roles → All roles → Create**.
2. Permissions → **Enrollment programs** → *View macOS admin password* = Yes; *Rotate macOS admin password* = Yes.
3. Add read permissions the helpdesk needs to locate devices (Managed devices → Read).
4. Scope tags → Assignments (admin group + scope groups).
5. Test with a helpdesk account on one Mac; confirm the `Get AdminAccountDto` audit event appears.
</details>

<details><summary>Playbook 4 — Resync after the pre-26.4 forced reset</summary>

1. Let the user/tech complete the forced admin reset on the device.
2. In Intune: device → **Rotate local admin password**; then **Sync**.
3. After check-in, confirm *last rotated* updated and the new portal password works.
4. Schedule the Mac for macOS 26.4+ (DDM software update enforcement).
</details>

---
## Evidence Pack

```powershell
<# Collect tenant-side macOS LAPS evidence (read-only). Run on an admin workstation. #>
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All","DeviceManagementManagedDevices.Read.All",
                        "DeviceManagementConfiguration.Read.All","DeviceManagementApps.Read.All",
                        "DeviceManagementRBAC.Read.All"
$out = Join-Path $env:TEMP "MacLAPSEvidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null
# Fleet + profile + policy + audit reports
& "<repoPath>\macOS\Scripts\Get-MacLAPSAudit.ps1" -OutputPath (Join-Path $out "MacLAPSAudit") -AuditDays 30
# Single device detail
$serial = "<serialNumber>"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=serialNumber eq '$serial'" |
    ConvertTo-Json -Depth 6 | Out-File (Join-Path $out "device-$serial.json")
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```
Device side (run on the Mac and attach):
```bash
{ sw_vers; profiles status -type enrollment; sudo profiles status -type bootstraptoken;
  dscl . -list /Users UniqueID | awk '$2>=500'; dscl . -read /Groups/admin GroupMembership;
  for u in $(dscl . -list /Users UniqueID | awk '$2>=500{print $1}'); do sysadminctl -secureTokenStatus "$u" 2>&1; done;
  fdesetup list; sudo profiles show -type configuration | grep -iE "changeAtNextAuth|passwordpolicy"; } > /tmp/MacLAPS_device.txt 2>&1
```

---
## Command Cheat Sheet

| Task | Command / Location |
|---|---|
| ADE enrollment status | `profiles status -type enrollment` |
| Local accounts | `dscl . -list /Users UniqueID \| awk '$2>=500'` |
| Admin group members | `dscl . -read /Groups/admin GroupMembership` |
| Is account admin | `dseditgroup -o checkmember -m <user> admin` |
| Hidden flag | `dscl . -read /Users/<admin> IsHidden` |
| Secure token | `sysadminctl -secureTokenStatus <user>` |
| FileVault users | `fdesetup list` |
| Bootstrap token | `sudo profiles status -type bootstraptoken` |
| Password-policy payloads | `sudo profiles show -type configuration \| grep -i changeAtNextAuth` |
| Serial | `ioreg -l \| awk -F'"' '/IOPlatformSerialNumber/{print $4}'` |
| View password | Intune: Devices → macOS → device → Monitor → Passwords and keys |
| Rotate password | Intune: device → Overview → Rotate local admin password |
| Audit | Tenant administration → Audit logs: `Get AdminAccountDto`, `rotateLocalAdminPassword ManagedDevice` |
| Fleet audit | `.\Get-MacLAPSAudit.ps1` |

---
## 🎓 Learning Pointers
- Primary reference for every setting, variable and known issue above: [Configure macOS ADE local account configuration with LAPS](https://learn.microsoft.com/en-us/intune/device-security/laps/setup-macos)
- Profile creation steps (the Account settings tab is step 12): [Set up automated device enrollment (ADE) for macOS](https://learn.microsoft.com/en-us/intune/device-enrollment/apple/setup-automated-macos)
- Rotation device action and its prerequisites: [Rotate local admin password](https://learn.microsoft.com/en-us/intune/device-management/actions/rotate-local-admin-password)
- Why the admin has no secure token and what bootstrap token solves: Apple Platform Deployment — [Use secure token, bootstrap token and volume ownership](https://support.apple.com/guide/deployment/use-secure-and-bootstrap-tokens-dep24dbdcf9e/web)
- Where the macOS enrollment path fits overall: [Deployment guide to manage macOS devices](https://learn.microsoft.com/en-us/intune/fundamentals/platform-guide-macos)
- Repo cross-references: `ADEEnrollmentPolicies-A.md` (profile types / user affinity), `FileVault-A.md` (recovery keys), `DDM-A.md` (enforcing macOS 26.4+).
