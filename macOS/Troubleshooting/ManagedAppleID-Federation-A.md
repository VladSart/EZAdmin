# Managed Apple ID Federation with Entra ID — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index (with jump links)
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

This covers **federated authentication between Apple Business (formerly Apple Business Manager) and Microsoft Entra ID** — linking a verified domain in Apple Business to Entra ID via OpenID Connect (OIDC) so that a **Managed Apple Account** is backed by the user's Entra ID identity, plus the closely related but independently-toggled **directory sync** feature that imports Entra user records into Apple Business.

**Covers:**
- The OIDC trust relationship between Apple Business and the Entra ID **global** cloud (login.microsoftonline.com)
- The three-step setup process (Approve → Test → Turn on) and why the ordering and the one-way "test changes your default format" step matter
- Required Entra ID roles/permissions and how they can be safely downgraded after setup
- What data flows from Entra ID to Apple Business (and the hard guarantee that nothing flows back)
- Directory sync's separate consent, attribute mapping, and read-only-until-disconnected behavior
- Security-event-driven session termination (password change/reset)
- Account sync conflict detection and resolution
- Device/service scope: iPhone, iPad, Mac, Apple Vision Pro, Shared iPad, and iCloud on the web on a Mac

**Does not cover:**
- Platform SSO (`Platform-SSO-A.md`/`-B.md`) — a device-level, macOS-only authentication extension that is architecturally unrelated to this topic (see the disambiguation note in "How It Works")
- ABM/DEP device-enrollment tokens or VPP licensing tokens (`ABM-Token-Renewal-A.md`/`-B.md`) — those govern device sync and app licensing, not user sign-in identity
- Federation with Google Workspace or a generic OIDC/SCIM identity provider — mentioned only where the "one IdP at a time" constraint is relevant
- GCC, GCC High, or any other Entra ID national/sovereign cloud — federation with Apple Business is explicitly not supported against anything other than the Entra ID OIDC global service

**Assumed role:** An Apple Business role with permission to set up and configure federation (able to link identity providers), and, on the Microsoft side, a user who can act as Entra ID Global Administrator for the initial approval step.

**Prerequisites:**
- iOS 15.5, iPadOS 15.5, macOS 12.4, visionOS 1.1, or later on the devices affected
- A verified **and locked** domain in Apple Business
- No pre-existing Managed Apple Account conflicts on that domain
- Every in-scope user's Entra `userPrincipalName` exactly equal to their email address (no alias, no Alternate Login ID)

---

## How It Works

<details><summary>Full architecture</summary>

**The rebrand context.** Apple merged Apple Business Manager, Apple Business Essentials, and Apple Business Connect into a single console called **Apple Business** (business.apple.com). The underlying tenant, domains, users, and devices are unchanged — only the marketing name and unified console changed. This repo's other macOS files (`ABM-Token-Renewal-A.md`, `DeviceMigration-A.md`, etc.) still use "Apple Business Manager"/"ABM" — same product. This file uses "Apple Business" to match Apple's current documentation, but expect both names in the wild for a while.

**What federation actually is.** Federated authentication links one Apple Business domain to exactly **one** external identity provider — Google Workspace, Microsoft Entra ID, or a generic OIDC/SCIM IdP — never more than one at a time. Microsoft Entra ID is linked specifically as an **OpenID Connect (OIDC)** provider against the **global** service endpoint (`login.microsoftonline.com`). Once linked, Entra ID becomes the identity provider (IdP) that authenticates the user and issues authentication tokens for their **Managed Apple Account** — the same conceptual object that previously could only be created manually or via directory sync from an unfederated source.

```
┌─────────────────────────────┐        OIDC trust        ┌──────────────────────────┐
│   Microsoft Entra ID          │◄─────────────────────────►│   Apple Business          │
│   (login.microsoftonline.com  │   id_token + claims        │   (business.apple.com)    │
│    — global cloud only)       │   Graph API reads           │                          │
└─────────────────────────────┘                            └──────────────────────────┘
        │  authenticates user,                                       │
        │  issues auth tokens                                        │  issues
        │                                                             │  Managed Apple Account
        ▼                                                             ▼
   User's Entra credentials                                  iPhone / iPad / Mac /
   (cert auth + 2FA supported)                                Apple Vision Pro / Shared iPad
                                                                       │
                                                                       ▼
                                                        Also: iCloud on the web on a Mac
                                                        (iCloud for Windows NOT supported
                                                        for Managed Apple Accounts)
```

**What data actually moves, and in which direction.** Apple Business requests four Microsoft Entra ID administrator-consent scopes and reads only what those scopes allow:

| Consent | Attributes read | Why |
|---|---|---|
| Basic profile (`openid`, `profile`, `email`) | `iss`, `aud`, `sub`, `iat`, `exp`, `oid`, `tid`, `wids`, `upn` claims | Establish and validate the OIDC connection itself |
| Read audit log (`AuditLog.Read.All`) | `activityDisplayName`, `activityDateTime`, `targetResources.id`/`.userPrincipalName` | Detect `ChangePassword`/`ResetPassword` events so the Managed Apple Account session can be terminated immediately |
| Read domains (`Domain.Read.All`) | `id`, `isVerified` | Sync verified-domain state from Entra ID |
| Read directory data (`Directory.Read.All`) | `id`, `userPrincipalName`, `displayName`, `givenName`, `surname`, `department`, `costCenter`, `division` | Populate directory-synced user records (only if directory sync is separately enabled) |
| Maintain access (`offline_access`) | — | Issues the refresh token used to keep the above reads working without repeated interactive consent |

**At no point is anything written back to Entra ID.** This is a hard, explicitly documented guarantee — Apple Business is a pure consumer of Entra ID identity and directory data, never a source of truth Microsoft reads from.

**The role that sets it up can never use it.** Whichever Entra ID account performs the "Approve federated authentication" step, and whichever Apple Business role configures the connection, are permanently excluded from signing in to devices via that same federated connection. This is intentional separation-of-duties design, not a bug — plan for a dedicated non-federated administrative identity from the start rather than discovering this after setup.

**The three-step process, and why order matters.**
1. **Approve federated authentication** — establishes the OIDC trust relationship. Requires an Entra ID Global Administrator the first time. After success, that Microsoft account's role can be safely downgraded to **Global Reader**, **Application Administrator**, or **Cloud Application Administrator**, or alternatively split across **Directory Reader** + **Reports Reader** — any of these combinations retain exactly the access Apple Business actually needs (`domains/standard/read`, `users/standard/read`, `auditLogs/allProperties/read`) without leaving Global Administrator assigned indefinitely.
2. **Test federated authentication with a single Microsoft Entra ID user account** — this is not a no-op dry run. Completing this step **permanently changes the domain's Default Managed Apple Account Format** to match the federated identity model. There is no supported UI path to revert this by re-testing; treat Step 2 as the point of no return for that domain's account-format policy, not Step 3.
3. **Turn on federated authentication** — flips the domain-wide toggle. Only after this does federated sign-in work for every user on the domain rather than just the tested one.

**Federation vs. directory sync — two independently toggled features, commonly conflated.** Turning on federated authentication alone lets users who already have (or are manually given) an Apple Business account sign in using their Entra credentials. It does **not** by itself create new Apple Business users for every Entra account in the tenant. That requires separately connecting **directory sync**, which imports user records (and keeps them read-only) from Entra ID on a recurring schedule — the first sync cycle takes noticeably longer than subsequent ones. Disconnecting directory sync converts the previously read-only records into ordinary editable manual accounts; it does not delete them.

**Security-event-driven session termination.** Because Apple Business continuously reads the Entra ID audit log for `ChangePassword`/`ResetPassword` activity on federated users, a password reset in Entra ID propagates to an immediate, forced re-authentication requirement on every Apple device that user is signed into — with no admin override short of disconnecting federation entirely. This is a genuine security feature (near-real-time credential-revocation propagation), not a fault condition, and is the most common source of "why did this user suddenly get logged out everywhere" tickets once federation is live.

**Disambiguation from Platform SSO.** Platform SSO (see `Platform-SSO-A.md`) is a **device-level** macOS authentication extension (`com.apple.extensiblesso`) that lets local login and in-app SSO ride on Entra credentials — it operates entirely independently of what identity backs the user's actual Apple Account. Managed Apple ID federation operates one layer up: it determines what identity provider issues and validates the **Apple Account** itself, which is a service-wide Apple identity, not a macOS login mechanism. A tenant can run either without the other, or both simultaneously, and they fail independently — do not assume fixing one resolves symptoms in the other.

</details>

---

## Dependency Stack

```
Layer 5 — User experience
  Sign in to iPhone/iPad/Mac/Apple Vision Pro/Shared iPad with Entra credentials;
  optionally sign in to iCloud.com in a Mac browser afterward
        ▲
Layer 4 — Managed Apple Account
  Identity object in Apple Business, now backed by the federated Entra identity
        ▲
Layer 3 — Federation state (domain-scoped)
  Approved (Step 1) → Tested (Step 2, locks Default Managed Apple Account Format)
  → Turned on (Step 3)
        ▲
Layer 2 — Trust + data-flow prerequisites
  Domain verified + locked · UPN == email (no alias/Alternate ID) · no account conflicts
  · Entra ID OIDC GLOBAL cloud only (not GCC/GCC High/national clouds)
        ▲
Layer 1 — Underlying tenants
  Microsoft Entra ID tenant (source of truth for authentication)
  Apple Business tenant (business.apple.com, formerly Apple Business Manager)
```

**Independent, parallel layer (not a dependency of the above, but frequently confused with it):**
```
Directory sync (separately consented, separately toggled)
  → read-only Apple Business user records from Entra attributes
  → disconnect converts records to editable manual accounts (does not delete them)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User gets a generic sign-in failure on a new device | `userPrincipalName` ≠ email address, or user is using a UPN alias/Alternate Login ID | `Get-MgUser` — compare `UserPrincipalName` and `Mail` |
| The admin who set up federation can't sign in with it themselves | Expected — federation-management role is excluded from federated sign-in by design | Confirm role assignment in Apple Business → Roles |
| Users are randomly forced to reauthenticate on every device | Entra ID password change/reset detected via audit log; session terminated by design | `Get-MgAuditLogDirectoryAudit` filtered to `ChangePassword`/`ResetPassword` for that user |
| New Entra ID users never appear in Apple Business | Federation is on, but directory sync is not — these are separate features | Apple Business → Domains → [domain] → Directory Sync section |
| "Account Conflict" banner appears after enabling directory sync | Pre-existing manual Apple Business accounts share a UPN/email with synced Entra accounts | Domains → [domain] → Manage → Resolve → Download Conflicts |
| Can't edit a user's name/department in Apple Business | Directory sync keeps synced attributes read-only while connected | Confirm sync is active; disconnect only if editability is truly required (breaks sync) |
| Federation for the whole domain stops working suddenly | The Entra ID consent/connection expired or was revoked | Apple Business → Domains → [domain] → check connection status; reconnect |
| GCC/GCC High tenant cannot federate at all | National/sovereign clouds explicitly unsupported | Confirm tenant cloud; document as a hard product limitation, not a misconfiguration |
| Federated user can't access iCloud.com from a Windows PC | iCloud for Windows does not support Managed Apple Accounts at all | Confirm this is Windows, not macOS Safari — no fix exists, it's a platform gap |
| Adding a custom attribute to directory sync breaks the connection | Apple Business only processes the documented attribute list; unmapped attributes can cause token validation failures | Review attribute mapping table in "How It Works"; remove unmapped attributes from scope |
| Re-testing federation doesn't revert an unwanted account-format change | Expected — Step 2's format change is one-way, not reversible by re-running the test | Escalate to Apple support if the format genuinely must be reverted; do not attempt via re-testing |
| Federated auth works for Google Workspace-synced legacy users too | Not possible — only one IdP can be linked to a domain at a time | Confirm which IdP is actually linked; a domain cannot be dual-federated |
| Shared iPad sign-in behaves differently than a personally-assigned device | Expected — sign-in flow branches depending on whether the account pre-exists in Apple Business | See Apple's Shared iPad sign-in scenarios reference in Learning Pointers |

---

## Validation Steps

1. **Confirm domain federation state.** Apple Business → Settings → Domains → [domain]. Good: "Sign in with Microsoft Entra ID" toggle is On, no Account Conflict banner. Bad: toggle off, or a pending/incomplete state.

2. **Confirm the Entra-side app registration/consent is still valid.** In Entra ID admin center, check Enterprise Applications for the Apple Business federation app; confirm no expired certificate or revoked admin consent. Bad: consent revoked or certificate expired — federation and sync both stop silently until reconnected.

3. **Spot-check a UPN/email match for a sample of affected users.**
   ```
   Get-MgUser -Filter "startswith(displayName,'<sample>')" | Select-Object DisplayName, UserPrincipalName, Mail
   ```
   Good: identical values in both columns for every row. Bad: any mismatch — that user will fail federated sign-in.

4. **Confirm the Entra role assigned to the federation-management account is one of the supported post-setup roles**, not still Global Administrator indefinitely. Good: Global Reader, Application Administrator, Cloud Application Administrator, or the Directory Reader + Reports Reader combination. Acceptable but excessive: Global Administrator left in place long-term (works, but is an unnecessary standing privilege).

5. **Confirm directory sync state matches expectations.** If the org expects every new Entra hire to automatically appear as an Apple Business user, directory sync must show as connected and recently synced — not just federation being on.

6. **Confirm no stale Account Conflict banner remains.** A lingering, unresolved conflict silently blocks the affected user records from syncing correctly even while federation itself reports healthy.

7. **Confirm tenant cloud type.** Global Entra ID commercial cloud only. Any GCC/GCC High/sovereign-cloud tenant will never successfully federate — treat this as a hard stop in triage, not something to keep debugging.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Confirm what's actually broken**
Establish whether the report is about (a) a single user failing to sign in, (b) forced reauthentication happening unexpectedly, (c) new users not appearing, or (d) the whole domain's federation being down. Each has a distinct root-cause family (see Symptom → Cause Map) — don't start digging into Graph queries before narrowing this.

**Phase 2 — Identity-layer checks**
For single-user sign-in failures, verify UPN/email match and alias/Alternate-ID absence first — this single check resolves the majority of real-world tickets. Confirm the user isn't the federation-management account.

**Phase 3 — Connection-health checks**
For domain-wide failures, check the Entra ID Enterprise Application's consent and certificate status, and Apple Business's own domain federation state. A silently expired consent looks identical from the Apple side to "nothing changed" until you check the Entra side.

**Phase 4 — Sync-layer checks (only if the complaint is about missing/duplicate/read-only users)**
Confirm federation and directory sync are being evaluated as separate systems. Check for Account Conflict banners specifically — they block sync silently without necessarily surfacing as a federation failure.

**Phase 5 — Security-event correlation (only for unexpected forced sign-outs)**
Pull the Entra audit log for the affected user's recent password activity before assuming a fault — this is very often expected behavior working correctly.

**Phase 6 — Escalate**
If tenant cloud type, UPN/email mismatch, conflict resolution, and connection health are all ruled out and the issue persists, gather the Evidence Pack and escalate — likely an Apple-side or Microsoft-side transient service issue rather than a tenant misconfiguration.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Full federation setup (Approve → Test → Turn on), done safely</summary>

1. Verify the target domain is already **verified and locked** in Apple Business (Settings → Domains). Federation cannot begin on an unverified or unlocked domain.
2. Confirm zero pre-existing Managed Apple Account conflicts for users in that domain.
3. **Step 1 — Approve.** Sign in to Apple Business with a role permitted to configure federation. Settings → Domains → Get Started next to "User sign-in and directory sync" → select Microsoft Entra ID → sign in with an Entra ID **Global Administrator** account → consent on behalf of the organization.
4. Immediately after approval succeeds, **downgrade** that Microsoft account's role to Global Reader, Application Administrator, Cloud Application Administrator, or the Directory Reader + Reports Reader pairing — do not leave Global Administrator assigned to a service-style account longer than necessary.
5. **Step 2 — Test.** Select **Federate** next to the domain → sign in with **one** ordinary Entra user account that exists in that domain → confirm success. Understand before doing this that it permanently sets the domain's Default Managed Apple Account Format.
6. **Step 3 — Turn on.** Domains → [domain] → Manage → "Turn on Sign in with Microsoft Entra ID" → toggle on.
7. Communicate the "the federation-setup account itself cannot use federated sign-in" limitation to whoever will operate this day to day, before they discover it as a support ticket.

**Rollback note:** Turning the toggle back off (Step 3 in reverse) is straightforward and reverses federated sign-in for the domain. There is no supported rollback for the Default Managed Apple Account Format change from Step 2 — treat that specifically as irreversible.

</details>

<details>
<summary>Playbook 2 — Enable directory sync on top of existing federation</summary>

1. Confirm federation (Steps 1–3 above) is already fully on for the domain — directory sync is commonly, but not strictly, set up after federation.
2. Apple Business → Settings → Domains → [domain] → Directory Sync → **Set up**. This is a separate consent flow from federation's Step 1, even though both target the same Entra ID tenant.
3. Allow the initial sync to complete — it takes noticeably longer than later cycles. Do not judge failure purely from initial-sync duration.
4. Confirm attribute mapping matches expectations (see the attribute table in "How It Works"). Do not add custom, unmapped attributes to the sync scope — Apple Business only processes the documented set and unmapped attributes can break token validation for the whole connection.
5. For subsequent on-demand updates: Domains → [domain] → Directory Sync → **Sync Now**.
6. If Account Conflict appears at any point, resolve it before assuming sync itself is broken (see Playbook 3).

**Rollback note:** Disconnecting directory sync converts previously read-only synced records into ordinary editable manual accounts — it does not delete users or break federated sign-in, which continues to function independently.

</details>

<details>
<summary>Playbook 3 — Resolve an Account Conflict after connecting directory sync</summary>

1. Apple Business → Domains → [domain] → Manage → locate the Microsoft Entra ID section's conflict message → **Resolve**.
2. **Download Conflicts** and review the exported list carefully against both systems' user records.
3. Only where the conflicting accounts are genuinely the same person/identical in both Entra ID and Apple Business, select **Merge**. Auto Merge can optionally be left on for the initial connection and then disabled afterward to avoid unexpected future merges.
4. For any conflict that is not a clean, identical match, correct the underlying data in Entra ID or in the pre-existing manual Apple Business account first, then re-run the conflict check rather than force-merging.

**Rollback note:** Merges are one-directional. If a merge was performed in error, there is no supported UI-level undo — this must be corrected via manual account editing or Apple support, not by attempting to "un-merge."

</details>

---

## Evidence Pack

```powershell
<#
Collects the Entra-side evidence needed to triage a Managed Apple ID
federation issue. Does not touch Apple Business directly (no public
Apple Business API for this) — pair this with the manual Apple Business
console checks listed in Validation Steps 1 and 5.

Requires: Microsoft.Graph module, Connect-MgGraph -Scopes
"User.Read.All","AuditLog.Read.All","Domain.Read.All","Directory.Read.All"
#>

param(
    [Parameter(Mandatory)]
    [string]$UserPrincipalName
)

Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","Domain.Read.All","Directory.Read.All" -NoWelcome

Write-Host "=== User identity check ===" -ForegroundColor Cyan
$user = Get-MgUser -UserId $UserPrincipalName -Property UserPrincipalName,Mail,OtherMails,GivenName,Surname,Department
$user | Select-Object UserPrincipalName, Mail, OtherMails, GivenName, Surname, Department | Format-List

if ($user.UserPrincipalName -ne $user.Mail) {
    Write-Host "MISMATCH: UserPrincipalName does not equal Mail — this WILL break federated sign-in." -ForegroundColor Red
} else {
    Write-Host "OK: UserPrincipalName matches Mail." -ForegroundColor Green
}

Write-Host "`n=== Recent password events (last 20) ===" -ForegroundColor Cyan
Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Reset password' or activityDisplayName eq 'Change password'" -Top 50 |
    Where-Object { $_.TargetResources.UserPrincipalName -contains $user.UserPrincipalName } |
    Select-Object ActivityDisplayName, ActivityDateTime |
    Format-Table -AutoSize

Write-Host "`n=== Domain verification state ===" -ForegroundColor Cyan
$domainName = $UserPrincipalName.Split('@')[1]
Get-MgDomain -DomainId $domainName | Select-Object Id, IsVerified, AuthenticationType

Write-Host "`nManual checks still required in Apple Business console:" -ForegroundColor Yellow
Write-Host " - Settings > Domains > [domain] > Sign in with Microsoft Entra ID toggle state"
Write-Host " - Account Conflict banner presence"
Write-Host " - Directory Sync connection + last-sync timestamp"
Write-Host " - Role assigned to the account that configured federation"
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MgUser -UserId "<UPN>" \| Select-Object UserPrincipalName, Mail` | Confirm the UPN/email match required for federated sign-in |
| `Update-MgUser -UserId "<ObjectId>" -UserPrincipalName "<email>"` | Correct a mismatched UPN (verify no conflict first) |
| `Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Reset password'"` | Check for a recent password reset explaining a forced sign-out |
| `Get-MgDomain -DomainId "<domain>"` | Confirm domain verification state on the Entra side |
| `Get-MgUser -UserId "<UPN>" -Property OtherMails` | Check for aliases that could conflict with the primary UPN requirement |
| Apple Business → Settings → Domains → [domain] | Check federation toggle, directory sync state, Account Conflict banner |
| Apple Business → Domains → [domain] → Manage → Resolve → Download Conflicts | Pull the conflict list for manual review before merging |
| Apple Business → Roles → [role] | Confirm which role has federation-management permission (excluded from federated sign-in) |
| Entra admin center → Enterprise Applications → [Apple Business app] | Check consent/certificate validity for the federation connection itself |

---

## 🎓 Learning Pointers

- **Read the Apple documentation under its current name, "Apple Business," not "Apple Business Manager."** Apple merged Apple Business Manager, Apple Business Essentials, and Apple Business Connect into one console. Bookmark the current guide rather than an older ABM-specific one that may not reflect the unified navigation. See: [Apple Business User Guide — federated authentication with Microsoft Entra ID](https://support.apple.com/guide/business/federated-authentication-microsoft-entra-axm8c1cac980/web)

- **The UPN/email exact-match requirement is the single highest-value thing to check first**, and it has zero workaround short of correcting the UPN in Entra ID. Build this into any pre-federation-rollout checklist for every user in scope, not just a reactive troubleshooting step. See: [Intro to federated authentication with Apple Business](https://support.apple.com/guide/business/intro-to-federated-authentication-axmb19317543/web)

- **Directory sync's attribute list is a hard allow-list, not a suggestion.** Adding unmapped custom attributes to the sync scope can break token validation for the entire connection — resist the temptation to extend it ad hoc. See: [Sync user accounts from Microsoft Entra ID to Apple Business](https://support.apple.com/guide/business/sync-user-accounts-from-microsoft-entra-id-axm3ec7b95ad/web)

- **Plan the post-setup Entra role downgrade as part of the initial rollout, not an afterthought.** Global Administrator is only required for the one-time approval step; leaving it assigned to a service-style account indefinitely is unnecessary standing privilege that a security review will flag. See the roles table in: [Use federated authentication with Microsoft Entra ID](https://support.apple.com/guide/business/federated-authentication-microsoft-entra-axm8c1cac980/web)

- **Shared iPad sign-in behavior branches on whether the account already exists** — review Apple's specific Shared iPad sign-in scenarios before assuming a federated sign-in failure there matches the single-user-device flow. See: [Sign in to Shared iPad](https://support.apple.com/guide/business/sign-in-to-shared-ipad-axmcb8792453/web)

- **This is a different identity plane from Platform SSO — don't conflate the two when triaging.** See `Platform-SSO-A.md`/`-B.md` in this same folder for the device-level authentication-extension mechanism, which is architecturally unrelated to what backs the Managed Apple Account itself.
