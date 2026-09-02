# Passwordless Teams Resource Accounts — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Password-less Teams Shared Space device Resource Accounts** — a feature that reached general availability worldwide between early and late August 2026 (Microsoft 365 Roadmap ID 558853, Message Center ID MC1435786). It converts the sign-in credential used by a Teams shared device (Teams Rooms on Windows, Teams Rooms on Android, Teams panels, Teams phones/common-area phones) from a stored username+password to a secure, device-bound token — the same underlying trust model as Windows Hello for Business, but applied to an unattended shared-device identity instead of an individual user.

**This is explicitly scoped separately from, and does not replace:**
- **Initial resource-account provisioning** — creating the Exchange room mailbox and Entra ID account, licensing it, and doing the first device sign-in with a password remains completely unchanged and is still a **hard prerequisite**. See [Teams-Rooms-A.md](Teams-Rooms-A.md) Playbook 1 and `M365/Exchange/RoomMailbox-A.md` for that process.
- **`Set as Resource`** — a separate, simpler PMP capability (Planning > Resource Accounts, "Set as Resource") that marks an account with a resource-account attribute in Entra ID for governance/security purposes. It is **not required** before running a passwordless migration — the migration process applies it automatically as one of its background steps — but it is a valid standalone action for organizations not yet ready to adopt passwordless authentication.
- **Ongoing device/policy management** (`Device-Policies-A.md`/`-B.md`) and general Teams Rooms troubleshooting (`Teams-Rooms-A.md`/`-B.md`) — this topic covers the authentication-method transition specifically, not day-to-day room operation once migrated.

**Assumption:** the reader is already comfortable with the existing Teams resource-account model documented in `Teams-Rooms-A.md` (Exchange room mailbox + Entra ID account + Teams Rooms/Shared Space license). This runbook does not re-explain that foundation.

**Tooling caveat, stated up front:** as of this writing, Microsoft's own documentation for this feature is **entirely Teams Rooms Pro Management Portal (PMP)-driven**. No PowerShell cmdlet or Graph API endpoint is documented anywhere to trigger, query, or manage the migration itself. This runbook uses Microsoft Graph (`Get-MgUser`, `Get-MgUserLicenseDetail`, etc. — all standard, long-stable typed cmdlets) only for the parts of this problem that genuinely live in Entra ID (licensing, account state, hybrid-sync status) and defers to the PMP UI for everything migration-specific, rather than guessing at unconfirmed cmdlet names.

---
## How It Works

<details><summary>Full architecture</summary>

**The credential model.** Prior to this feature, every Teams shared device authenticated to Microsoft 365 (Teams, Intune, PMP) using a stored username and password on the resource account — identical in kind to a human user's password, just entered once and cached. This is a well-understood liability: the password can be phished, guessed, or simply forgotten/rotated by another admin and silently break the room. Passwordless resource accounts replace this with a **device-bound credential**: a secure token cryptographically tied to that specific physical device, generated and validated against Entra ID, and never transmitted as a reusable secret the way a password is. Conceptually this is the same trust model as Windows Hello for Business — the credential cannot be copied to another device, cannot be phished in the traditional sense, and re-authentication happens silently using the bound key rather than a stored secret.

**What happens during migration (background sequence):**
```
1. Admin schedules migration in PMP (Planning > Resource Accounts > Migration tab)
2. PMP applies "Set as Resource" to the account (if not already applied)
3. [Teams Rooms on Windows only] The Teams Rooms app migrates from signing Windows
   in as the local 'Skype' user account to signing in AS the resource account itself.
   All existing TRW app settings are carried over during this step.
4. The device contacts Entra ID and requests its device-bound token
5. The device signs in using the new token; the sign-in is validated end-to-end
   -> SUCCESS: migration completes, PMP status updates to "Migrated"
   -> FAILURE: automatic rollback to password authentication — no admin action required,
      no manual cleanup needed on a failed attempt
6. PMP reflects final migration status per device/account
```

**Why the old password still works after migration.** The password is **not deleted** by the migration — it remains a valid credential on the account until an admin explicitly removes it (cloud-only accounts, via the PMP "Cleanup password" wizard) or rotates/scrambles it (all accounts, including hybrid-synced ones where the password literally cannot be deleted, only obfuscated). This is a deliberate design choice documented by Microsoft, not an oversight — but it means a "migrated" room is not automatically a room with no exploitable password until that second step is taken. Track this as a distinct completion criterion in any migration project, not an automatic side effect.

**Why Teams Rooms on Windows behaves differently from the other three device types on revert.** On Windows, the resource-account sign-in **replaces** the local `Skype` Windows user account context that the TRW app previously ran under (step 3 above) — the local password-based account context is gone once migrated, not just the Teams sign-in. Reverting therefore requires a full device reset (OEM recovery tool/image), because there's no longer a local Windows credential path to fall back to. Android-based devices (Teams Rooms on Android, panels, phones) never had this local-OS-account layer — the device-bound token exists purely at the app/Entra layer, so a simple account sign-out (locally or via PMP remote sign-out) is sufficient to drop back to password auth on those platforms.

**Why the credential is non-transferable.** The token is cryptographically bound to the specific device hardware/OS install it was issued to. A factory reset, re-image, or hardware replacement destroys that binding — there is no supported way to move a device-bound token to a new or reset device. The recovery path is always: reset the account password → set up the new/reset device with that password (standard provisioning) → re-run the passwordless migration from scratch.

</details>

---
## Dependency Stack

```
Entra ID tenant                                                    (top-of-stack authority)
    └── Resource account (Entra ID user object, licensed)
        └── Teams Rooms Basic/Pro license (Rooms Win/Android)
            OR Teams Shared Space license (standalone panels/phones)
            [panel sharing a Room account's identity inherits that Room's license —
             do not double-license]
        └── Account is Entra-ID-only OR AD-synced (Entra Cloud Sync/Connect)
            [governs whether password can later be fully removed, or only scrambled]
    └── Device already provisioned and signed in WITH A PASSWORD
        (this feature has no "day-zero passwordless" path — it is a post-deployment
        conversion only)
        └── Device onboarded and visible in Teams Rooms Pro Management Portal (PMP)
            └── Device meets platform-specific minimum version bar
                ├── Teams Rooms on Windows: Win11 24H2 build 26100.8655+,
                │   TRW app 5.6.135.0+, Entra-ID-JOINED ONLY (hybrid join unsupported)
                ├── Teams Rooms on Android: Android 10+, current TRA app,
                │   Authenticator app, Teams Admin Agent app
                ├── Teams panel: Android 10+, current panel app + same companion apps
                └── Teams phone: Android 10+, current phone app + same companion apps
                    └── Network connectivity present at device boot
                        (STP delay / portfast-disabled switches can strand a device
                        on the sign-in screen post-migration — a timing issue, not
                        a credential failure)
                        └── Admin with Teams Administrator role (PMP migration action)
                            └── MIGRATION SCHEDULED AND EXECUTED
                                └── Admin with User/Exchange/Global Administrator role
                                    completes password cleanup or scramble
                                    (separate step — NOT automatic)
                                        └── FULLY PASSWORDLESS, NO RESIDUAL SECRET
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Migration option doesn't appear for an account in PMP | Account not licensed with a qualifying SKU | `Get-MgUserLicenseDetail -UserId <id>` — expect Teams Rooms or Teams Shared Space SKU |
| Migration fails with an app/OS version reason | Device below the platform-specific minimum bar | Check device app version + OS build against the Dependency Stack table above |
| Teams Rooms on Windows migration fails outright | Device is hybrid-joined, not Entra-ID-joined | `dsregcmd /status` on the device — `DomainJoined` must be `NO` |
| Device stuck on sign-in screen after an apparently successful migration | Boot-time network delay prevented the token handshake | Check switch port STP/portfast config; manually sign in once connectivity is present |
| Room shows healthy but the old password still authenticates elsewhere | Cleanup/scramble step was never run — this is expected, not a bug | Run the PMP Cleanup Password wizard (cloud-only) or scramble the password (hybrid) |
| Migrated device suddenly needs a password again after a technician visit | Device was reset, re-imaged, or manually signed out | Expected — re-provision with a (new) password, then re-migrate |
| Crestron TRW room migrated and is now broken | Crestron devices are explicitly unsupported for this feature (as of Aug 2026 GA) | Factory reset via Crestron recovery media; keep on password auth until Microsoft ships support |
| TRW room behind a corporate web proxy fails PMP operations after migration | Known issue — the Pro Management agent may read the signed-in resource-account user's (rather than system-wide) proxy settings | Configure matching proxy settings for the resource-account user profile; do **not** use `bitsadmin /Util /SetIEProxy LOCALSYSTEM` |
| Panel migration behaved differently than its paired Room device | Panels sharing a Room account's identity migrate together automatically; a standalone panel with its own account migrates independently | Confirm whether the panel uses its own resource account or shares the Room's |

---
## Validation Steps

1. **License eligibility** — `Get-MgUserLicenseDetail -UserId <resource-account-id>`. Expect: a Teams Rooms Basic/Pro SKU string for Rooms Windows/Android, or a Teams Shared Space SKU for a standalone panel/phone. Bad: no matching SKU present — migration will silently not be offered, with zero error surfaced in PMP.
2. **Join type (Windows only)** — `dsregcmd /status` on the device. Good: `AzureAdJoined : YES`, `DomainJoined : NO`. Bad: `DomainJoined : YES` — hybrid join is an unconditional blocker for this feature on Windows, with no override or exception path documented.
3. **Platform/app version** — device Settings/About screen (Windows) or Teams Admin Agent app reporting (Android-based). Good: meets or exceeds the minimum build/version listed in the Dependency Stack. Bad: below minimum — PMP will report a version-specific failure reason in the migration detail panel; don't retry blind, fix the version gap first.
4. **Migration execution** — PMP > Planning > Resource Accounts > Migration tab. Good: status transitions to "Migrated" with no manual intervention. Bad: "Failed" — always has a specific reason in the account's detail panel; read it before retrying.
5. **Post-migration sign-in behavior** — device signs in automatically with no repeated prompts, and a password change on the account (tested deliberately, e.g. during Playbook 2 below) does **not** sign the device out. Bad: device gets signed out by a password change post-migration — this indicates migration did not actually complete despite PMP showing "Migrated"; escalate to Microsoft support with the account UPN and timestamp.
6. **Residual-password cleanup** — after migration, confirm via the PMP Cleanup Password wizard status or a manual Entra ID sign-in attempt with the old password (in a controlled test) whether the password has actually been removed/scrambled. Bad: password still valid and undocumented — flag as an open finding in any migration project, not a false negative.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-migration readiness**
- Confirm license SKU present and correct for device type.
- Confirm device already provisioned and signed in with a password (this is not a first-time deployment path).
- Confirm device meets platform version minimums.
- Confirm join type (Windows: Entra-ID-joined only).
- Confirm the device is not a Crestron TRW unit or a proxy-configured TRW unit (both currently unsupported).

**Phase 2 — Migration execution**
- Schedule via PMP with an account holding the Teams Administrator role (the only role currently supported for this action; Global Administrator support is planned but not yet available per Microsoft's own documentation).
- Prefer scheduling during a maintenance window for production rooms — migration briefly re-authenticates the device.
- If migration fails, read the specific failure reason in the PMP detail panel before retrying; do not blind-retry more than once without addressing the stated cause.

**Phase 3 — Post-migration validation**
- Confirm the room reports healthy in PMP and signs in without repeated prompts.
- Run a real meeting-join test if this is a production room, not just a status check.
- If the device is stuck on the sign-in screen despite a "Migrated" status, investigate network timing at boot (switch STP/portfast) before assuming the migration itself failed.

**Phase 4 — Password lifecycle closeout**
- Cloud-only accounts: run the Cleanup Password wizard in PMP.
- Hybrid-synced accounts: scramble the password using Microsoft's documented password-scramble guidance — do not attempt to delete it, that operation is not supported for AD-synced accounts.
- Document which accounts have completed this step separately from which accounts have completed migration — they are not the same milestone.

**Phase 5 — Ongoing lifecycle events**
- Device replacement/reset: re-provision with a password first, then re-run migration from Phase 2. There is no in-place recovery of a lost device-bound token.
- Credential/device swap: same as above — always re-provision with a password before attempting passwordless again.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Pilot a batch migration for a customer's Teams Rooms fleet</summary>

**Goal:** Migrate a small, representative pilot group before a full-fleet rollout, per Microsoft's own explicit recommendation.

1. Select 3-5 rooms spanning the device types actually deployed (e.g. a mix of Teams Rooms on Windows and any panels/phones in use).
2. Confirm each pilot device against the Validation Steps above (license, join type, version, not Crestron/proxied).
3. In PMP, select the pilot accounts on the Migration tab and choose **Schedule migration** — either immediate or next maintenance window.
4. After migration, run the full Post-migration validation phase (Phase 3) on every pilot device, including a real meeting-join test.
5. Only after the pilot group is stable for a reasonable observation period (recommend at least one full business week, covering multiple restart/reconnect cycles) should the migration be expanded to the rest of the fleet in phased batches.
6. Run the password cleanup/scramble step (Phase 4) for the pilot group before declaring the pilot complete — an incomplete pilot with unresolved leftover passwords understates the real rollout effort for the full fleet.

Rollback: for Teams Rooms on Windows, revert via full device reset (OEM recovery tool/image) if a pilot device needs to go back to password auth. For Android-based device types, a full account sign-out (local or PMP remote sign-out) reverts cleanly without a factory reset.

</details>

<details><summary>Playbook 2 — Migrate a hybrid-synced resource account (password cannot be fully removed)</summary>

**Goal:** Complete the passwordless transition for a customer whose Teams Rooms resource accounts are synced from on-premises Active Directory, and set correct expectations about residual password state.

1. Confirm `OnPremisesSyncEnabled = True` on the account via Graph before starting — this determines the Phase 4 approach.
2. Run the migration exactly as documented in Playbook 1 — hybrid sync does not block the migration itself, only the later password-removal step.
3. After successful migration and validation, do **not** attempt the Cleanup Password wizard's delete path — instead follow Microsoft's documented password-scramble guidance to rotate the password to an unknown value without disrupting the already-issued device-bound token.
4. Document explicitly for the customer that this account's password is scrambled, not removed, and why (AD sync boundary) — this avoids a false "fully passwordless" claim in any compliance-facing documentation.

Rollback: identical to Playbook 1 — device-type-specific revert procedure; hybrid sync has no bearing on the revert path itself.

</details>

<details><summary>Playbook 3 — Recover a device after reset, re-image, or hardware replacement</summary>

**Goal:** Restore passwordless operation after a device-bound token is lost due to a reset, re-image, or physical device swap — the expected, documented recovery path, not an incident.

```powershell
# Step 1: Reset the resource account password (requires User Administrator, Exchange
# Administrator, or Global Administrator role) — record the new password, you need it
# for provisioning.
Connect-MgGraph -Scopes "User-PasswordProfile.ReadWrite.All"
$acct = Get-MgUser -Filter "userPrincipalName eq '<room@domain.com>'"
$newPw = -join ((48..57)+(65..90)+(97..122)+(33,35,36,37) | Get-Random -Count 24 | ForEach-Object {[char]$_})
Update-MgUser -UserId $acct.Id -PasswordProfile @{ Password = $newPw; ForceChangePasswordNextSignIn = $false }
Write-Host "New password for $($acct.UserPrincipalName): $newPw" -ForegroundColor Yellow
```
2. Set up the reset/replacement device using this username and password — standard provisioning, identical to a brand-new room (see `Teams-Rooms-A.md` Playbook 1).
3. Once signed in successfully with the password, return to PMP and re-run the passwordless migration (Phase 2 above) to convert the device again.
4. Re-run the Phase 4 password cleanup/scramble step once migration is confirmed stable.

Rollback: not applicable — this playbook IS the recovery/rollback path for a lost credential.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Passwordless Teams resource account evidence collector
.DESCRIPTION Gathers Entra ID-side state for a Teams shared-device resource account to
             support a passwordless-migration ticket or escalation. Does NOT query PMP
             migration status directly — no documented API exists for that; capture the
             PMP detail-panel screenshot separately per the Escalation Evidence template
             in PasswordlessResourceAccounts-B.md.
.NOTES       Read-only. Requires Microsoft.Graph.Users, Microsoft.Graph.Users.Actions.
#>
param(
    [Parameter(Mandatory)]
    [string]$ResourceAccountUpn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Connect-MgGraph -Scopes "User.Read.All" -NoWelcome

$acct = Get-MgUser -Filter "userPrincipalName eq '$ResourceAccountUpn'" `
    -Property Id,DisplayName,UserPrincipalName,AccountEnabled,OnPremisesSyncEnabled,PasswordPolicies,CreatedDateTime

if (-not $acct) {
    Write-Host "[ERROR] No account found for $ResourceAccountUpn" -ForegroundColor Red
    return
}

$licenses = Get-MgUserLicenseDetail -UserId $acct.Id | Select-Object SkuPartNumber, SkuId

$evidence = [PSCustomObject]@{
    DisplayName            = $acct.DisplayName
    UserPrincipalName      = $acct.UserPrincipalName
    AccountEnabled          = $acct.AccountEnabled
    OnPremisesSyncEnabled   = $acct.OnPremisesSyncEnabled
    PasswordCleanupPath     = if ($acct.OnPremisesSyncEnabled) { "Scramble only (hybrid-synced)" } else { "Cleanup wizard (cloud-only)" }
    PasswordPolicies        = ($acct.PasswordPolicies -join ", ")
    AssignedLicenses        = ($licenses.SkuPartNumber -join ", ")
    CreatedDateTime          = $acct.CreatedDateTime
    CollectedAtUtc           = (Get-Date).ToUniversalTime().ToString("o")
}

$evidence | Format-List
$exportPath = ".\PasswordlessResourceAccount-Evidence-$($acct.UserPrincipalName -replace '[^a-zA-Z0-9]','_').csv"
$evidence | Export-Csv -Path $exportPath -NoTypeInformation
Write-Host "`nEvidence exported to $exportPath" -ForegroundColor Cyan
Write-Host "Remember to attach separately: PMP Migration tab status/detail-panel screenshot," -ForegroundColor Yellow
Write-Host "Entra sign-in log export for this account, and (Windows only) 'dsregcmd /status'." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-MgUser -Filter "displayName eq '<name>'" -Property DisplayName,UserPrincipalName,AccountEnabled,OnPremisesSyncEnabled` | Confirm resource account identity + hybrid-sync status |
| `Get-MgUserLicenseDetail -UserId <id>` | Confirm Teams Rooms / Teams Shared Space license assigned |
| `dsregcmd /status` (on the Windows device) | Confirm Entra-ID-joined (not hybrid-joined) — hard prerequisite for TRW |
| `Update-MgUser -UserId <id> -PasswordProfile @{Password=<pw>}` | Reset/scramble the resource account password |
| PMP: **Planning > Resource Accounts > Migration tab** | Schedule, monitor, and read failure reasons for migration — the only source of truth for migration state |
| PMP: **Cleanup password** (Migration tab) | Remove the residual password on a cloud-only account post-migration |
| PMP: **Planning > Resource Accounts > Set as Resource** | Mark an account as a resource account without doing a passwordless migration |
| Entra sign-in logs (portal) filtered by resource account UPN | Diagnose authentication failures during or after migration |
| Recovery tool / OEM recovery image (Teams Rooms on Windows) | Only supported way to revert a migrated TRW device back to password auth |
| On-device sign-out or PMP remote sign-out (Android/panel/phone) | Reverts those device types back to password auth — no factory reset needed |

---
## 🎓 Learning Pointers

- **This is a post-deployment conversion, not a new deployment method.** Every device must already be provisioned and signed in with a password before it can be migrated — there is no "deploy straight to passwordless" path yet. Plan migrations as a fleet-wide follow-up project, not part of new-room deployment checklists (yet). [MS Docs: Transition to Password-less Teams Shared Device Resource Accounts](https://learn.microsoft.com/en-us/microsoftteams/rooms/passwordlessentraresourceaccounts)
- **The credential model mirrors Windows Hello for Business** — device-bound, non-transferable, resilient to password rotation. If you already understand WHfB's trust model from `EntraID/Troubleshooting/WHfB-A.md`, that mental model transfers directly here, just applied to a shared-device identity instead of a human one.
- **Teams Rooms on Windows and the other three device types have genuinely different revert mechanics** — because Windows migration replaces the local OS-level Skype account context, while Android-based devices never had that layer. Don't apply Windows recovery steps to a panel or vice versa.
- **The two-step password lifecycle (migrate, then separately clean up/scramble) is easy to under-scope in a migration project.** A "100% migrated" fleet can still have every original password sitting valid and unused unless the cleanup step is tracked as its own milestone — this is the single most likely gap an MSP will find when auditing a customer's "we already did this" claim.
- **No PowerShell or Graph endpoint exists for the migration action itself as of this writing** — plan any at-scale migration workflow around the PMP UI (bulk select + schedule), not automation. If a future SDK update adds typed cmdlets for this, this runbook's Evidence Pack script should be revisited to incorporate direct migration-status queries.
- **Hybrid-joined Teams Rooms on Windows and Crestron TRW hardware are both hard blockers today**, not degraded-mode exceptions — set customer expectations accordingly rather than troubleshooting a migration attempt on either as if it should eventually succeed. [MS Docs: Set as a Resource Accounts for Shared Devices in Teams Rooms Pro Management](https://learn.microsoft.com/en-us/microsoftteams/rooms/set-as-resource-account-for-shared-teams-devices)
