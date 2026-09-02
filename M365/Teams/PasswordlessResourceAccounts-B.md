# Passwordless Teams Resource Accounts — Hotfix Runbook (Mode B: Ops)
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

This feature (GA worldwide, early-to-late August 2026) converts a Teams shared-device resource account (Teams Rooms on Windows/Android, Teams panels, Teams phones/common area phones) from stored username+password sign-in to a secure, device-bound credential — conceptually similar to Windows Hello for Business. Migration is **100% driven from the Teams Rooms Pro Management Portal (PMP)** — there is no documented PowerShell or Graph cmdlet to trigger or query migration state directly. Run these first:

```powershell
# 1. Confirm the resource account is licensed correctly for passwordless eligibility
Connect-MgGraph -Scopes "User.Read.All"
$acct = Get-MgUser -Filter "displayName eq '<ROOM-OR-DEVICE-DISPLAY-NAME>'" -Property DisplayName,UserPrincipalName,AccountEnabled,OnPremisesSyncEnabled,AssignedLicenses
$acct | Select-Object DisplayName, UserPrincipalName, AccountEnabled, OnPremisesSyncEnabled
Get-MgUserLicenseDetail -UserId $acct.Id | Select-Object SkuPartNumber

# 2. Check sign-in logs for the resource account for recent auth failures (portal migration failures surface here)
# Entra portal > Identity > Monitoring & health > Sign-in logs > filter by the resource account UPN

# 3. Confirm device platform/app versions meet the minimum bar (device-side; not Graph-visible)
#    Teams Rooms on Windows : Windows 11 24H2 build 26100.8655+, TRW app 5.6.135.0+, Entra-ID-joined (NOT hybrid-joined)
#    Teams Rooms on Android / panels / phones : Android 10+, current Teams device app + Authenticator + Teams Admin Agent app builds

# 4. Check PMP migration status directly (source of truth — Graph does not expose this)
# Portal: https://portal.rooms.teams.microsoft.com > Planning > Resource Accounts > Migration tab
# Select the failed account > open the detail panel > read the failure reason

# 5. If reverting to password auth was attempted, confirm whether the platform actually supports a soft revert
#    Teams Rooms on Windows  -> requires a full device RESET (recovery tool/image) — sign-out alone does NOT revert it
#    Android / panels / phones -> a full account sign-out on-device DOES revert it (or remote sign-out via PMP)
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `OnPremisesSyncEnabled = True` | Hybrid-synced account — password **cannot** be removed post-migration, only scrambled | → Fix 3 (scramble, not cleanup wizard) |
| No Teams Rooms / Teams Shared Space license on the account | Account is not eligible — migration will not be offered in PMP | → Fix 1 |
| Account not visible on the PMP Migration tab at all | Device/account not yet enrolled in Pro Management, or `Set as Resource` state not yet applied | → Fix 2 |
| Migration shows "Failed" with app/OS version reason | Device below minimum platform requirement | → Fix 4 |
| Teams Rooms on Windows stuck on sign-in screen after migration | Boot-time network delay (STP/portfast) prevented the device-bound token handshake | → Fix 5 |
| Device was reset, re-imaged, or replaced and now needs a password again | Expected — the device-bound credential is non-transferable and is destroyed on reset/replace | → Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for passwordless migration to succeed</summary>

```
Resource account exists, enabled, licensed (Teams Rooms lic. for Rooms Win/Android,
Teams Shared Space lic. for panels/phones — panels sharing a Room account inherit
that Room's license, no separate Shared Space license needed)
    └── Device already signed in to the resource account with a PASSWORD (prerequisite —
        passwordless is a POST-deployment transition, not an initial-deployment method)
            └── Device visible in Teams Rooms Pro Management Portal (PMP)
                └── Device meets minimum platform/app version bar for its type
                    └── Teams Rooms on Windows: Entra-ID-joined ONLY (hybrid join unsupported)
                        └── Network connectivity present at boot (no STP/portfast delay)
                            └── Admin with Teams Administrator role schedules migration in PMP
                                └── Device requests + receives device-bound token from Entra ID
                                    └── Device signs in with new token; validated
                                        ├── SUCCESS → PMP marks migrated; app settings preserved
                                        └── FAILURE → automatic rollback to password auth, no admin action needed
```

Note: the OLD password is **not removed** by a successful migration — it silently remains valid until an admin runs the Cleanup Password wizard (cloud-only accounts) or manually scrambles it (hybrid-synced accounts). This is a common audit-finding gap, not a bug.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm eligibility** — `Get-MgUserLicenseDetail` on the resource account. Expect a Teams Rooms Basic/Pro SKU (Rooms Windows/Android) or Teams Shared Space SKU (standalone panel/phone). No matching SKU = migration option will not appear in PMP at all, with no error surfaced anywhere else.
2. **Confirm platform prerequisites** — on Teams Rooms on Windows, check `Settings > About` on the device (or Intune device details) for OS build ≥ `26100.8655` and TRW app ≥ `5.6.135.0`. Below either bar = migration will fail with a version-reason in the PMP detail panel.
3. **Confirm join type (Windows only)** — `dsregcmd /status` on the device. Expect `AzureAdJoined : YES` and `DomainJoined : NO`. A hybrid-joined TRW device is **not supported** for this feature — no workaround exists yet.
4. **Schedule/re-check migration in PMP** — Planning > Resource Accounts > Migration tab. A "Failed" status always has a specific reason in the detail panel; read it before retrying blind.
5. **Post-migration validation** — device signs in with no repeated prompts, room shows healthy in PMP, and a test meeting join/room-experience check passes. If the device sits on the sign-in screen after a successful-looking migration, suspect boot-time network delay (Fix 5), not a credential problem.

---
## Common Fix Paths

<details><summary>Fix 1 — Account not licensed for passwordless eligibility</summary>

```powershell
Connect-MgGraph -Scopes "User.Read.All", "Organization.Read.All"
$acct = Get-MgUser -Filter "displayName eq '<ROOM-DISPLAY-NAME>'" -Property Id,DisplayName
$skus = Get-MgSubscribedSku | Select-Object SkuId, SkuPartNumber
# Assign the correct SKU via the M365 admin center (Users > Licenses) or:
# Set-MgUserLicense -UserId $acct.Id -AddLicenses @{SkuId = "<TeamsRooms-or-TeamsSharedSpace-SkuId>"} -RemoveLicenses @()
```
Teams Rooms on Windows/Android need a Teams Rooms Basic or Pro license. Teams panels and Teams phones need a Teams Shared Space license — **unless** the panel is signed into the same account as a Room device, in which case the Room license already covers it; do not double-license.

Rollback: none needed — this is an additive license assignment.

</details>

<details><summary>Fix 2 — Device/account not visible on the PMP Migration tab</summary>

1. Confirm the account has been onboarded to Teams Rooms Pro Management at all (Planning > Inventory).
2. `Set as Resource` is **not** a hard prerequisite for migration (the migration process applies it automatically) — but if the account is missing from PMP entirely, verify basic resource-account setup first via the standard [Teams-Rooms-A.md](Teams-Rooms-A.md) provisioning playbook before troubleshooting the passwordless-specific flow.
3. Re-sync the device/account inventory in PMP if it was recently deployed (allow up to a few hours for PMP visibility).

Rollback: none — this is a visibility/onboarding check, not a destructive action.

</details>

<details><summary>Fix 3 — Cleanup or rotate the resource account password after migration</summary>

```powershell
# Cloud-only account: use the PMP Cleanup Password wizard (Planning > Resource Accounts > Migration >
# select account(s) > Cleanup password). This fully removes the password.

# Hybrid-synced account: the password CANNOT be removed — it must be scrambled instead, without
# breaking the already-issued device-bound token:
# See: https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-plan-password-scramble-phishing-resistant-passwordless-authentication

# Manual scramble via M365 admin center also works for cloud-only accounts if the wizard is unavailable:
Connect-MgGraph -Scopes "User-PasswordProfile.ReadWrite.All"
$acct = Get-MgUser -Filter "userPrincipalName eq '<room@domain.com>'"
$newPw = -join ((48..57)+(65..90)+(97..122)+(33,35,36,37) | Get-Random -Count 24 | ForEach-Object {[char]$_})
Update-MgUser -UserId $acct.Id -PasswordProfile @{ Password = $newPw; ForceChangePasswordNextSignIn = $false }
```

The device remains signed in after either action — the password is no longer used for device sign-in once migrated, only for legacy/interactive access to that account.

Rollback: none required — the device-bound token is unaffected by password changes post-migration (this is one of the feature's stated benefits).

</details>

<details><summary>Fix 4 — Migration failed on app/OS version</summary>

1. Update the device to the minimum supported OS build and Teams device app version listed in the Dependency Cascade above (varies by device type — Windows/Android/panel/phone each has its own bar).
2. For Teams Rooms on Windows behind a system-wide proxy: **not yet supported** as of the August 2026 rollout ("coming weeks" per Microsoft) — do not attempt migration on proxied Windows rooms yet; track for a documentation update.
3. Retry the migration from PMP once the version gate is satisfied.

Rollback: not applicable — migration was never applied.

</details>

<details><summary>Fix 5 — Teams Rooms on Windows stuck on sign-in screen post-migration</summary>

Root cause: network/switch configuration delayed connectivity during boot (STP delay, portfast disabled on the switch port), so the device couldn't complete the device-bound-token handshake in time.

1. Manually sign in on the device once network connectivity is confirmed present.
2. If it recurs on every boot, fix the switch port configuration (enable portfast / reduce STP delay) so the device has connectivity at boot, not just after boot.
3. Optionally retry the Resource Account migration from PMP if the device is still showing as failed there.

Rollback: not applicable — this is a timing issue, not a failed migration requiring reversal.

</details>

<details><summary>Fix 6 — Device replaced, reimaged, or reset — password required again</summary>

The device-bound credential is **non-transferable** and is destroyed on reset, re-image, or replacement — this is expected behavior, not a bug.

```
1. Reset the resource account password (User Administrator, Exchange Administrator, or
   Global Administrator role required) — see Fix 3's manual scramble command, but note
   the password down this time since you need it for re-provisioning.
2. Set up the new/reset device using that username and password (standard provisioning —
   see Teams-Rooms-A.md Playbook 1).
3. Once signed in successfully with the password, re-run the passwordless migration from
   PMP (Step 1 in the Diagnosis flow above) to convert it again.
```

Rollback: not applicable — this IS the recovery path.

</details>

---
## Escalation Evidence

```
Resource account UPN            : [                    ]
Device type (Rooms Win/Android/Panel/Phone) : [                    ]
Device app version               : [                    ]
OS build (Windows only)          : [                    ]
Join type (Windows only)         : [ Entra-ID-joined / Hybrid-joined ]
License SKU assigned             : [                    ]
OnPremisesSyncEnabled            : [ True / False ]
PMP Migration tab status         : [ Not started / Scheduled / Failed / Migrated ]
PMP failure reason (if Failed)   : [                    ]
Sign-in log failures (last 24h)  : [ Yes / No — attach export ]
Steps already attempted          : [                    ]
```

Attach: PMP migration detail-panel screenshot, Entra sign-in log export for the resource account, and `dsregcmd /status` output (Windows devices only).

---
## 🎓 Learning Pointers

- **Migration is admin-initiated only — Microsoft never auto-migrates a device.** If a room unexpectedly shows passwordless sign-in behavior, someone on your team (or a delegated admin) scheduled it; check PMP's migration history before assuming a platform bug. [MS Docs: Transition to Password-less Teams Shared Device Resource Accounts](https://learn.microsoft.com/en-us/microsoftteams/rooms/passwordlessentraresourceaccounts)
- **The old password is not removed automatically.** A tenant that migrates devices but never runs the Cleanup Password wizard or scrambles hybrid passwords is left with valid-but-unused credentials sitting on resource accounts — flag this as a follow-up audit item on every migration, not an optional step.
- **Hybrid-synced resource accounts can never have their password fully removed** — only scrambled. If your MSP manages a customer with AD-synced room accounts, set expectations accordingly before promising a "passwordless" state.
- **Teams Rooms on Windows and Android/panels/phones revert differently.** Windows requires a full device reset via the OEM recovery tool/image to get back to password auth; the others just need an account sign-out. Don't apply the wrong revert procedure — a full reset is destructive for the room's local device state.
- **Hybrid-joined Teams Rooms on Windows is a hard blocker, not a degraded-mode fallback** — there is currently no supported path to passwordless for hybrid-joined TRW devices. If a customer's TRW fleet is hybrid-joined for on-prem reasons, this feature is off the table until Microsoft ships support (not yet dated).
- **Crestron Teams Rooms on Windows devices are explicitly unsupported** as of the August 2026 GA — do not migrate them; if one was migrated in error, it needs a factory reset via Crestron recovery media.
