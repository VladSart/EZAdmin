# macOS ADE Local Admin Account with LAPS (Intune) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "no LAPS password shown for this Mac / the admin password doesn't work / Mac demands a password reset at first login" in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Intune's macOS LAPS is **not** the Windows LAPS CSP. It's a set of options on the **macOS ADE enrollment
profile** (Account Settings tab) that create a local admin account with a 15-character random password
during Setup Assistant, escrow it in Intune, and rotate it every 180 days (plus an optional shorter period).
It only applies to devices that go through **ADE after a factory reset** with that profile.

**In the Intune admin center (60 seconds):**
1. **Devices → macOS → <device> → Monitor → Passwords and keys** — is a *Local administrator account
   password* shown? If yes, Intune manages it.
2. **Devices → macOS → <device> → Hardware** — enrollment type / enrollment profile name.
3. **Devices → Enrollment → Apple → Enrollment program tokens → <token> → Profiles → <profile> → Account settings**
   — is *Local administrator account* = Yes?

**On the Mac (Terminal, as any admin):**
```bash
# 1. Was this Mac enrolled through ADE?
profiles status -type enrollment
# Good: "Enrolled via DEP: Yes" and "MDM enrollment: Yes (User Approved)"

# 2. Which local accounts exist, and which are admins?
dscl . -list /Users UniqueID | awk '$2>=500'
dscl . -read /Groups/admin GroupMembership

# 3. Secure token holders (FileVault unlock rights)
for u in $(dscl . -list /Users UniqueID | awk '$2>=500{print $1}'); do sysadminctl -secureTokenStatus "$u" 2>&1 | sed "s/^/$u: /"; done

# 4. macOS version (known issue below 26.4)
sw_vers -productVersion
```

**Interpretation table:**

| Finding | Action |
|---|---|
| No password in *Passwords and keys*; device enrolled before the profile had LAPS, or via `profiles renew` | Fix 1 — not supported; device must be wiped and re-enrolled via ADE with the LAPS profile |
| Admin can't see the password / *Rotate local admin password* missing | Fix 2 — RBAC: needs a **custom** role with *Enrollment programs → View/Rotate macOS admin password* |
| macOS < 26.4 and user was forced to reset the **admin** password at first auth | Fix 3 — known issue; rotate from Intune afterwards to resync; upgrade to 26.4+ |
| Admin or user prompted "change password at next login" on new LAPS devices | Fix 4 — password policy from compliance/device-restriction template enables *Change at next authentication*; move to Settings catalog with it disabled |
| Password from Intune rejected at the login window | Fix 5 — out-of-sync (manual change on device, pre-26.4 issue); rotate and wait for check-in |
| LAPS admin can't unlock FileVault / isn't a secure-token holder | Expected — platform limitation; the admin account never gets a secure token (Fix 6) |
| Admin account not visible at login window | Expected if *Hide in Users & Groups* was set; use "Other…" at login window |
| `Enrolled via DEP: No` | Fix 1 — manual/UI enrollment can never be LAPS-managed |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Device assigned to Intune in Apple Business/School Manager (ABM/ASM) and synced to the ADE token
 └─ macOS ADE enrollment profile assigned to the device serial
     └─ Account settings: Local administrator account = Yes (optionally Local user account)
         └─ "Await final configuration" forced to Yes by the backend (accounts created in Setup Assistant)
             └─ Device factory-reset → Setup Assistant → ADE enrollment (macOS 12+)
                 │   (profiles renew -type enrollment on an existing install = NOT supported)
                 └─ Intune creates admin account, 15-char random password, escrows it
                     ├─ First interactive account to sign in (the local user) gets the SECURE TOKEN
                     │   └─ LAPS admin never gets a secure token (platform limitation)
                     ├─ Password policy: Settings catalog only, "Change at next authentication" = disabled
                     │   └─ macOS < 26.4 + passcode profile → admin forced reset (known issue)
                     └─ Rotation: automatic every 180 days + optional 1–180 day period + manual device action
                         └─ Device must check in for rotation to land on the Mac
                             └─ Viewing/rotating: custom Intune role — Enrollment programs → View / Rotate macOS admin password
```
</details>

---
## Diagnosis & Validation Flow

1. **Enrollment path**
   ```bash
   profiles status -type enrollment
   ```
   Expected: `Enrolled via DEP: Yes`. `No` → device isn't LAPS-eligible without wipe + ADE.

2. **Admin account exists and is an admin**
   ```bash
   dscl . -read /Users/<adminAccountName> RealName UniqueID IsHidden 2>&1
   dseditgroup -o checkmember -m <adminAccountName> admin
   ```
   Expected: record returned; `yes <adminAccountName> is a member of admin`. `IsHidden: 1` when *Hide in
   Users & Groups* was configured. If the account name used a variable (`{{serialNumber}}-admin` etc.),
   resolve it first: `ioreg -l | awk -F'"' '/IOPlatformSerialNumber/{print $4}'`.

3. **Secure token placement**
   ```bash
   sysadminctl -secureTokenStatus <adminAccountName>
   sysadminctl -secureTokenStatus <localUserName>
   fdesetup list
   ```
   Expected: admin **DISABLED**, local user **ENABLED** and listed by `fdesetup list`. This is by design.

4. **Password policy conflict**
   ```bash
   sudo profiles show -type configuration | grep -iE "changeAtNextAuth|maxPINAgeInDays|passwordpolicy"
   ```
   Expected: no `changeAtNextAuth = 1`. Present → Fix 4.

5. **Intune-side password state** — *Passwords and keys* shows the password and **last rotation time**.
   A rotation that shows in the portal but not on the device = device hasn't checked in.

6. **Audit trail** — **Tenant administration → Audit logs**: `Get AdminAccountDto` (someone viewed the
   password) and `rotateLocalAdminPassword ManagedDevice` (rotation). Use this to prove who viewed/rotated.

---
## Common Fix Paths

<details><summary>Fix 1 — Device isn't LAPS-managed (enrolled before LAPS, or not via ADE)</summary>

Account configuration only applies to **new** ADE enrollments during initial device setup. There's no
in-place conversion; re-running ADE with `sudo profiles renew -type enrollment` is explicitly unsupported.

1. Confirm the serial is assigned to the LAPS-enabled profile (Enrollment program tokens → Devices).
2. Back up user data; confirm Activation Lock / FileVault recovery key escrow first.
3. Wipe (Intune **Wipe**, or Erase All Content and Settings), then let the Mac run Setup Assistant online.
4. Validate with Diagnosis steps 1–3.

**Destructive:** full device erase. Rollback = restore from backup.
</details>

<details><summary>Fix 2 — Admin can't view or rotate the password (RBAC)</summary>

The two permissions are **not in any built-in role** — not even Intune Administrator (Entra role) grants
them via the Intune RBAC model. Create a custom role:

**Tenant administration → Roles → All roles → Create** (Intune role) →
Permissions → **Enrollment programs**: *View macOS admin password* = Yes, *Rotate macOS admin password* = Yes →
scope tags → assignments (helpdesk group + the device groups it may act on).

```powershell
# List custom Intune roles that grant any Enrollment-programs action, then inspect the action names
Connect-MgGraph -Scopes "DeviceManagementRBAC.Read.All"
$defs = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/roleDefinitions").value
foreach ($d in $defs | Where-Object { -not $_.isBuiltIn }) {
    $acts = @($d.rolePermissions.resourceActions.allowedResourceActions) | Where-Object { $_ -match 'EnrollmentProgram' }
    if ($acts) { [pscustomobject]@{ Role = $d.displayName; Actions = ($acts -join '; ') } }
}
```
Confirm the macOS-admin-password actions appear in the output (exact action names are Graph-internal; match
them against what the portal shows for the role).
</details>

<details><summary>Fix 3 — Pre-macOS 26.4 forced admin password reset</summary>

Known issue: on macOS earlier than 26.4, ADE with a local admin account **plus** a targeted passcode profile
prompts for an **admin** password reset even when *Change at next auth* is off or Max Age is set. The standard
account isn't affected.

1. After the on-device reset, **manually rotate** from Intune (*Rotate local admin password*) so Intune and
   the device agree again.
2. Upgrade the Mac to **macOS 26.4 or later** (see `SoftwareUpdates-A/B.md` / DDM update enforcement).
</details>

<details><summary>Fix 4 — "Change password at next login" on new LAPS devices</summary>

Password settings in **compliance policies** and **device restriction** templates enable *Change at next
authentication* by default and can break sign-in for new LAPS accounts.

1. Remove password settings from macOS compliance / device-restriction policies targeting LAPS devices
   (or exclude those devices).
2. Recreate the passcode policy in **Settings catalog** with *Change at next authentication* disabled.
3. On already-affected Macs, rotate the admin password from Intune after the user resets.
</details>

<details><summary>Fix 5 — Intune password doesn't work on the Mac</summary>

1. Check *Passwords and keys → last rotated*. If recent, check device **last check-in** — rotation reaches
   the Mac only on check-in. Trigger a sync (device action **Sync**, or Company Portal → Check settings).
2. If someone changed the password locally, or the pre-26.4 issue hit, run **Rotate local admin password**,
   sync, then retry.
3. Still failing and the device is otherwise healthy → escalate with evidence (below).
</details>

<details><summary>Fix 6 — LAPS admin can't unlock FileVault / do secure-token tasks</summary>

By design the LAPS admin has **no secure token**; the first account to sign in (the local user) receives it.
For FileVault recovery use the **personal recovery key** escrowed in Intune (see `FileVault-A/B.md`), and
make sure a **Bootstrap Token** is escrowed so MDM can manage secure-token-dependent operations.
```bash
sudo profiles status -type bootstraptoken
```
Expected: `Bootstrap Token escrowed to server: YES`.
</details>

---
## Escalation Evidence

```
Ticket: ____________    Device serial: ______________   Intune device ID: ______________________
macOS version: ________  ADE enrollment profile name: ______________________
profiles status -type enrollment → Enrolled via DEP: [ ] Yes [ ] No
Profile Account settings: Local admin = [ ] Yes [ ] No   Username template: ______________
                          Hide in Users & Groups: [ ] Yes [ ] No   Rotation period (days): ____
Passwords and keys pane shows password?  [ ] Yes  [ ] No    Last rotated: ________________
Device last check-in: ________________
Admin account on device (dscl): [ ] present [ ] missing    Admin group member: [ ] Yes [ ] No
Secure token: admin ______  local user ______   Bootstrap token escrowed: [ ] Yes [ ] No
Password policy source: [ ] Settings catalog  [ ] Compliance  [ ] Device restrictions
Symptom / exact error: ____________________________________________
Audit log entries (Get AdminAccountDto / rotateLocalAdminPassword) with timestamps: __________
Get-MacLAPSAudit.ps1 CSVs attached: [ ]
```

---
## 🎓 Learning Pointers
- The whole feature lives on the **ADE profile's Account settings tab** — it's an enrollment-time construct, which is why existing Macs can't be "switched on". [Configure macOS ADE local account configuration with LAPS](https://learn.microsoft.com/en-us/intune/device-security/laps/setup-macos)
- The View/Rotate permissions sit under **Enrollment programs**, not Remote tasks — and no built-in role has them. [Create a custom role in Intune](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/create-custom-role)
- Manual rotation is a standard device action with its own audit event. [Device action: Rotate local admin password](https://learn.microsoft.com/en-us/intune/device-management/actions/rotate-local-admin-password)
- Secure token and bootstrap token behaviour explains why the LAPS admin can't unlock FileVault — see `macOS/Troubleshooting/FileVault-A.md` and Apple's [Use secure token, bootstrap token and volume ownership in deployments](https://support.apple.com/guide/deployment/use-secure-and-bootstrap-tokens-dep24dbdcf9e/web).
- Windows LAPS is a different product with different mechanics — don't reuse its runbook: `Intune/Troubleshooting/LAPS-A/B.md`.
- Userless (no user affinity) Macs: use `{{serialNumber}}-admin` as the admin username so each device's account is unique. `ADEEnrollmentPolicies-A.md` covers the profile types.
