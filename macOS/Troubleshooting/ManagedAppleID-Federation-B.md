# Managed Apple ID Federation with Entra ID — Hotfix Runbook (Mode B: Ops)
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

**Terminology note:** Apple rebranded **Apple Business Manager** to **Apple Business** (the same admin console at business.apple.com now covers what used to be ABM, Apple Business Essentials, and Apple Business Connect). This runbook uses "Apple Business" for the console and "Managed Apple Account" for the federated identity — both are the current Apple terms as of mid-2026. Existing repo content (`ABM-Token-Renewal-A.md`, etc.) now says "Apple Business" too, but keeps "ABM" as an established shorthand — same product, same tenant, different marketing name. This topic is unrelated to the DEP/VPP tokens covered there.

Run these first to classify the issue:

```
1. Confirm federation is actually turned ON for the domain
   Apple Business → Settings → Domains → [domain] → check "Sign in with Microsoft Entra ID" toggle

2. Confirm the affected user's Entra UPN matches their primary email/SMTP address exactly
   (Entra admin center → Users → [user] → check User principal name vs. Mail)

3. Check whether the user is trying to sign in with a UPN alias or Alternate Login ID
   — neither is supported for this federation

4. Check whether this is a NEW-Mac sign-in problem or an EXISTING-account problem
   (new: registration/UPN issue; existing: session/sync/conflict issue)

5. Check whether the account trying to sign in is the SAME account used to set up federation
   — that account's role can only manage federation, never sign in with it
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| Toggle is off / domain shows "Pending" | Federation never completed Step 3 (Turn on) | → Fix 1 |
| UPN ≠ Mail attribute | Apple Business requires `userPrincipalName` == email address; aliases/Alternate IDs aren't supported | → Fix 2 |
| Affected user is the federation setup/admin account | Expected — that role can configure federation but can't sign in through it | → Fix 3 |
| User signed in fine yesterday, now forced to reauthenticate on every device | Expected — a password change/reset in Entra ID terminates the Managed Apple Account session | → Fix 4 |
| New Entra users never appear as Apple Business users | Federation ≠ directory sync — these are two separately-enabled features | → Fix 5 |
| Tenant is GCC / GCC High / a national/sovereign cloud | Not supported — federation only works against the Entra ID OIDC **global** service | Document as out of scope, no workaround |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
User signs in to iPhone/iPad/Mac/Apple Vision Pro/Shared iPad
with a Microsoft Entra ID user name and password
        │
        ▼
Managed Apple Account backed by the federated identity
        │
        ▼
Federated authentication TURNED ON for the domain (Step 3 of 3)
        │
        ▼
Federated authentication TESTED successfully with one Entra user
(this step permanently changes the domain's Default Managed Apple
Account Format — cannot be un-done by re-testing)
        │
        ▼
Trust relationship APPROVED (Step 1 — required an Entra Global
Administrator to consent; can be downgraded afterward)
        │
        ▼
Domain VERIFIED and LOCKED in Apple Business
        │
        ▼
User's Entra userPrincipalName EXACTLY equals their email address
(no UPN alias, no Alternate Login ID — both silently unsupported)
        │
        ▼
Entra ID OIDC GLOBAL cloud only — login.microsoftonline.com
(GCC, GCC High, and other national/sovereign clouds are not supported)
```

**Separately, layered on top (optional, independently toggled):**
```
Directory sync (Sync user accounts from Microsoft Entra ID)
        │
        ▼
Read-only Apple Business user records populated from Entra attributes
(givenName, surname, userPrincipalName, department, employeeId, costCenter, division)
        │
        ▼
Records stay read-only until sync is disconnected — then they become
editable manual accounts
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the domain's federation state**

In Apple Business: **Settings → Domains → [domain]**. Look for the Microsoft Entra ID section and the "Sign in with Microsoft Entra ID" toggle.

Expected (working): Toggle **On**, no Account Conflict banner.
Bad: Toggle off, or a banner reading "Account Conflict" → conflicts were never resolved, sync/federation is effectively stalled for affected users.

---

**Step 2 — Confirm the user's UPN/email match**

```
# Entra admin center or Graph
Get-MgUser -UserId "<UPN>" | Select-Object UserPrincipalName, Mail, OtherMails
```

Expected: `UserPrincipalName` and `Mail` are identical.
Bad: They differ, or the user is signing in with an item from `OtherMails`/an Alternate Login ID — this fails silently on the Apple side with a generic sign-in error, not a UPN-specific one.

---

**Step 3 — Confirm this isn't the federation-admin account itself**

Apple Business → **Roles** → check the role assigned to the account that set up federation. If that role includes "set up and configure federation," it is explicitly blocked from signing in via federated auth on any device — this is by design, not a bug.

---

**Step 4 — Check for a recent Entra security event**

```
Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'ResetPassword' or activityDisplayName eq 'ChangePassword'" -Top 20 |
    Where-Object { $_.TargetResources.UserPrincipalName -eq "<UPN>" }
```

If a password reset/change appears in the last few hours, the resulting forced reauthentication on every Apple device is expected — Apple Business reads Entra's audit log specifically to catch this and terminate the session.

---

**Step 5 — Confirm whether directory sync is even enabled (separate from federation)**

Apple Business → **Settings → Domains → [domain] → Directory Sync** section. If this shows "Not connected," federation alone will let existing/manually-matched users sign in, but **no new Entra users will ever appear as Apple Business users** until directory sync is turned on and run.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Federation was approved/tested but never turned on</summary>

**When:** Domain shows federation in a pending/incomplete state; Step 1 and/or Step 2 were done but Step 3 wasn't.

1. Apple Business → **Settings → Domains → [domain] → Manage**
2. Select **"Turn on Sign in with Microsoft Entra ID"**
3. Confirm the toggle now reads **On**

If Step 2 (the single-user test) was never completed, complete it first — testing is a hard prerequisite for Step 3 and also finalizes the domain's Default Managed Apple Account Format, which cannot be changed back afterward without Apple support.

</details>

<details>
<summary>Fix 2 — UPN doesn't match email address (the most common failure)</summary>

**When:** `Get-MgUser` shows `UserPrincipalName` ≠ `Mail`, or the user has a UPN alias/Alternate Login ID.

There is no workaround on the Apple side — this is a hard Microsoft-documented requirement. Options:

- **Preferred:** Update the user's Entra `userPrincipalName` to match their primary email/SMTP address:
  ```
  Update-MgUser -UserId "<ObjectId>" -UserPrincipalName "<correct-email>"
  ```
  Confirm no other object already holds that UPN before running this.
- If the mismatch is intentional (e.g. a UPN suffix migration in progress), the user cannot use federated sign-in on Apple devices until the UPN is corrected — communicate this constraint rather than continuing to troubleshoot the Apple side.

</details>

<details>
<summary>Fix 3 — Federation setup account can't sign in (expected, not a fault)</summary>

**When:** The account used to approve/manage federation is the one reporting a sign-in failure.

This is by design: a role with federation-management permissions is excluded from federated sign-in. Give the affected person a **separate** Entra account/role for their day-to-day device sign-in, and keep the federation-management account purely administrative.

</details>

<details>
<summary>Fix 4 — Forced reauthentication after a password event (expected behavior)</summary>

**When:** Diagnosis Step 4 shows a recent `ResetPassword`/`ChangePassword` event for the user.

No fix needed — this is intended: Apple Business polls Entra's audit log (`AuditLog.Read.All` scope) specifically for password-change/reset events on federated users, and immediately terminates that user's Managed Apple Account session, forcing reauthentication with the new password. Communicate this to the user rather than treating it as a bug.

**Rollback note:** N/A — this is a one-way security control with no admin override short of disconnecting federation entirely (which would break sign-in for every user on the domain).

</details>

<details>
<summary>Fix 5 — New Entra users never appear in Apple Business</summary>

**When:** Federation is on and working for existing users, but newly created Entra accounts don't show up as Apple Business users.

Federation and directory sync are **independently toggled**. Federated authentication alone lets a user who already has (or manually gets) an Apple Business account sign in with Entra credentials — it does **not** create new Apple Business users by itself unless directory sync is also enabled.

1. Apple Business → **Settings → Domains → [domain] → Directory Sync → Set up**
2. Complete the Entra Connect setup for directory sync (separate consent from the federation Step 1 consent)
3. Trigger an initial sync, then confirm via **Sync Now** for subsequent on-demand syncs:
   Apple Business → Domains → [domain] → Directory Sync → **Sync Now**

Note the initial sync takes noticeably longer than subsequent cycles — don't judge failure from the first sync's duration alone.

</details>

<details>
<summary>Fix 6 — Duplicate/conflicting accounts after enabling sync</summary>

**When:** Apple Business shows an "Account Conflict" banner on the domain after connecting directory sync.

1. Apple Business → Domains → [domain] → Manage → find the Microsoft Entra ID section's conflict message → **Resolve**
2. Select **Download Conflicts** and review the list carefully
3. Only if the conflicting accounts are genuinely identical in both systems, select **Merge**

**Rollback note:** Merging is one-directional and cannot be undone from the Apple Business UI — if in doubt, do not merge; instead correct the source data in Entra ID or Apple Business first, then re-attempt.

</details>

---

## Escalation Evidence

```
=== Managed Apple ID Federation Escalation Package ===
Date/Time:                 ___________
Affected User UPN:         ___________
Domain:                    ___________
Federation state (On/Off/Pending): ___________
Directory sync state (On/Off):     ___________
Tenant cloud (Commercial/GCC/GCC High): ___________

=== Checks Performed ===
UserPrincipalName == Mail?           Yes / No   (paste Get-MgUser output)
Is this the federation-admin account?  Yes / No
Recent password change/reset event?    Yes / No  (paste audit log entry if yes)
Account Conflict banner present?       Yes / No

=== Error Description ===
- Device type (Mac/iPhone/iPad/Vision Pro/Shared iPad): ___________
- Exact error message/screen: ___________
- First occurred: ___________
- Affects one user / many users / whole domain: ___________

=== Steps Already Tried ===
[ ] Verified UPN/email match
[ ] Confirmed federation toggle state
[ ] Checked Entra audit log for password events
[ ] Checked for Account Conflict banner
[ ] Other: ___________
```

---

## 🎓 Learning Pointers

- **Federation ≠ directory sync — they are two separately toggled features that are easy to conflate.** Federated authentication only governs *how* an existing Apple Business user signs in; directory sync governs *whether new Entra users ever become* Apple Business users at all. See: [Intro to federated authentication with Apple Business](https://support.apple.com/guide/business/intro-to-federated-authentication-axmb19317543/web)

- **The UPN-must-equal-email requirement has no override.** Apple Business federation with Entra ID requires `userPrincipalName` to exactly match the user's email address — UPN aliases and Alternate Login IDs are both explicitly unsupported. This is the single highest-frequency real-world failure and is worth checking before anything else. See: [Use federated authentication with Microsoft Entra ID](https://support.apple.com/guide/business/federated-authentication-microsoft-entra-axm8c1cac980/web)

- **This is distinct from Platform SSO.** Platform SSO (`Platform-SSO-A.md`/`-B.md`) is a device-level authentication extension that lets *local* macOS login and app SSO ride on Entra credentials. Managed Apple ID federation is a completely different, higher layer: it changes what identity provider issues the user's actual **Apple Account** itself. A device can use Platform SSO with zero Managed Apple ID federation in place, and vice versa — don't assume one implies the other is configured.

- **This is also distinct from the ABM/DEP and VPP tokens.** Those tokens (`ABM-Token-Renewal-A.md`/`-B.md`) control device enrollment sync and app licensing between Apple Business and Intune. Managed Apple ID federation controls user sign-in identity. A tenant can have healthy tokens and broken federation, or vice versa — they fail independently.

- **No data is ever written back to Entra ID.** The relationship is one-way and read-only from Apple's side — Apple Business reads profile, domain, directory, and security-audit data from Entra ID via Microsoft Graph, but never modifies anything in Entra ID itself.

- **iCloud for Windows does not support Managed Apple Accounts at all.** Users can sign in to iCloud.com in a Mac browser after federated sign-in on an Apple device, but the iCloud for Windows desktop app is a hard exception — don't spend time troubleshooting it for federated users, it's an explicit product limitation.
