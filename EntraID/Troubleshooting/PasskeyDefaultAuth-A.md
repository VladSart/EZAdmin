# Passkey Default Authentication Rollout (SMS/Voice Retirement) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Retirement Timeline](#retirement-timeline)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Applies to:** Microsoft Entra ID public cloud tenants only, all editions. Covers the
  Microsoft-driven auto-enablement of passkeys for SMS/Voice-enabled users, the associated
  Registration Campaign auto-enrollment, the SSPR explicit-registration tightening, and the
  Microsoft-provided SMS/Voice telecom retirement itself.
- **Does not cover:** Passkey (FIDO2) registration/sign-in mechanics for a user who is already
  attempting to register — see `Passkeys-A.md`/`Passkeys-B.md` for that. Does not cover Conditional
  Access Custom Controls retirement (a related but administratively separate Sept 2026 change) — see
  `Security/ConditionalAccess/CustomControlsRetirement-B.md`.
- **Explicitly out of scope per Microsoft:** Azure AD B2C tenants (unaffected). Microsoft Entra
  External ID (change is delayed to a later, separately-announced date). Sovereign/government cloud
  environments follow a later schedule with separate communications.
- **Assumes:** Authentication Policy Administrator or Global Reader role to read/change the affected
  policies; Security Reader is sufficient to run the exposure-analysis script.
- **Key terminology:** "AMP" = Authentication Methods Policy, the modern per-method tenant policy
  surface. "Legacy MFA settings" = the older per-user MFA configuration surface that predates AMP and
  is also in scope for this retirement. "Registration Campaign" = the nudge mechanism that prompts
  users to register a specific method on next MFA-satisfied sign-in.

---

## How It Works

<details><summary>Full mechanism — why Microsoft is doing this and how the rollout actually executes</summary>

### Why This Change Exists

SMS and voice OTP delivery are among the most phishable, SIM-swap-vulnerable, and
replay-vulnerable authentication factors Entra ID has ever offered natively. Microsoft's stated
driver is that phishing-resistant authentication (passkeys, WHfB, FIDO2 hardware keys) needs to
become the *default* experience — not an opt-in security posture that only security-mature tenants
adopt — in order for enterprises to safely adopt AI-driven workflows at scale, where credential
compromise has outsized downstream blast radius. Rather than only offering passkeys as an option,
Microsoft is retiring its own SMS/voice telecom delivery outright and using automatic enrollment to
force the migration across the entire installed base, on a fixed calendar, not a per-tenant
opt-in schedule.

### What "Automatic Enablement" Actually Does

On September 1, 2026, for every tenant that has not set the temporary opt-out, Entra ID:

1. Scans the tenant's Authentication Methods Policy (and the deprecated legacy per-user MFA
   settings surface) for users enabled for SMS or Voice.
2. Puts those users into a passkey profile that allows all passkey types (both device-bound and
   synced) — this is a Microsoft-managed action, not something an admin configures per profile.
3. Sets the tenant's Registration Campaign state to `microsoftManaged`, targeting exactly that
   population.
4. On each subsequent sign-in where the user satisfies MFA, the registration campaign nudges them
   to register a passkey. By default, the snooze count is **unlimited** — this is deliberately
   non-disruptive in the near term; the actual enforcement doesn't land until Feb 1, 2027.

Critically, this only touches SMS/Voice users. Users who already have a phishing-resistant method
(passkey, WHfB, FIDO2 key) registered are not re-prompted or otherwise affected by this rollout.

### The Two-Phase Retirement Design

Microsoft designed this as two distinct phases with different enforcement characteristics, which is
the single most common source of confusion in tickets and internal comms:

**Phase 1 (Sept 1, 2026 – Jan 31, 2027) — "Nudge, don't block."** Passkeys become the default
suggested method. SMS/Voice continues to function as an MFA/SSPR factor throughout this window.
Users see repeated but dismissible registration prompts. Admins have a temporary opt-out available
via the `passkeyDynamicMigration` policy setting to delay the nudge/auto-enrollment specifically —
this does NOT delay Phase 2.

**Phase 2 (Feb 1, 2027 onward) — "Blocking enforcement, no opt-out."** Microsoft-provided SMS/Voice
telecom delivery stops working entirely for tenants that have not configured a customer-managed
telecom provider through the Microsoft Security Store. Any user whose *only* available MFA method
is SMS or Voice at that point receives a **blocking** passkey-registration prompt at sign-in — they
cannot skip it and cannot access their account until they register a passkey (or another available
phishing-resistant/registered method). This is enforced tenant-wide regardless of whether the tenant
used the Phase 1 opt-out.

### The Customer-Managed Telecom Provider Escape Hatch

For tenants with a genuine regulatory, compliance, or operational need to retain an SMS/voice
channel past Feb 1, 2027, Microsoft is not eliminating the capability entirely — it's moving the
telecom relationship from "Microsoft as your carrier" to "you contract directly with a carrier
listed in the Microsoft Security Store." Key dates: provider/pricing information publishes Sept 18,
2026; customers can actually select and configure a provider starting Oct 30, 2026. This is priced
per-message/per-region by the provider, not bundled into Entra ID licensing the way Microsoft's own
SMS/voice delivery was.

### SSPR's Separate, Earlier Tightening (Sept 7, 2026)

Distinct from the passkey auto-enablement above, Self-Service Password Reset changes its acceptance
rules on Sept 7, 2026 (six days after the main rollout starts): SSPR will only accept methods a user
has **explicitly registered** for password reset — it stops implicitly trusting an SMS/voice number
that exists on the account but was never formally registered as an SSPR method. This is a narrower,
faster-moving change than the main retirement timeline and is a common source of "why did password
reset suddenly stop working" tickets that land in the same week as the passkey rollout but have a
different root cause.

</details>

---

## Dependency Stack

```
[Microsoft's fixed, tenant-independent retirement calendar]
         │
[Tenant's Authentication Methods Policy (AMP) + legacy per-user MFA settings]
    ├── Users enabled for SMS  ─┐
    └── Users enabled for Voice ┴─→ in-scope population for auto-enablement
         │
[optOutSettings.passkeyDynamicMigration — Graph beta policy property]
    ├── true  → Phase 1 auto-enablement/campaign suppressed for the tenant
    └── false/unset (default) → Phase 1 proceeds on Microsoft's schedule
         │
[Phase 1: Sept 1, 2026 — Passkey profile auto-assignment + Registration Campaign]
    └── microsoftManaged campaign state, unlimited snoozes, non-blocking
         │
[Sept 7, 2026 — SSPR explicit-registration requirement (independent sub-timeline)]
         │
[Sept 18 – Oct 30, 2026 — Security Store customer-managed telecom provider window]
    └── Only relevant to tenants pursuing Fix 4 / the telecom-provider escape hatch
         │
[Feb 1, 2027 — Phase 2 hard enforcement, NO opt-out]
    ├── Microsoft-provided SMS/Voice telecom delivery stops
    ├── Tenant WITH configured customer-managed provider → SMS/Voice keeps working
    └── Tenant WITHOUT one AND user's only MFA method is SMS/Voice
          → BLOCKING passkey registration prompt at next sign-in
```

---

## Retirement Timeline

| Date | Milestone | Admin Action Required |
|---|---|---|
| Sept 1, 2026 | SMS/Voice-enabled users auto-enrolled into passkey profile + Microsoft-managed Registration Campaign | Communicate to users; optionally opt out via `passkeyDynamicMigration` if not ready |
| Sept 7, 2026 | SSPR requires explicitly registered methods only | Audit which users have formally registered an SSPR method, not just an implicit SMS/voice number |
| Sept 18, 2026 | Customer-managed telecom provider pricing/terms published in Security Store | Review if pursuing the telecom-provider path |
| Sept 30, 2026 | (Related, separate change) CA Custom Controls — no new/modified controls allowed | See `CustomControlsRetirement-B.md` |
| Oct 30, 2026 | Customers can select/configure a Security Store telecom provider | Stand up carrier contract if needed |
| End of CY2026 | Passkey support planned for B2B/guest users | Re-evaluate B2B-heavy tenant migration plan once available |
| Feb 1, 2027 | Microsoft-provided SMS/Voice fully retired; blocking passkey prompt enforced for SMS/Voice-only users; NO opt-out | Ensure all users have a phishing-resistant method OR a configured telecom provider before this date |

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Users suddenly seeing "set up a passkey" prompts after Sept 1, 2026 with no admin change made | Expected — Microsoft-driven auto-enablement for SMS/Voice-enabled users | `optOutSettings.passkeyDynamicMigration` — if `false`/unset, this is expected behavior |
| Ticket volume spike, but users CAN dismiss/snooze the prompt | Non-blocking Phase 1 nudge — working as designed | Registration Campaign state = `microsoftManaged`, unlimited snoozes by default |
| User reports being fully blocked from signing in by the passkey prompt (cannot dismiss) | Either genuine Phase 2 enforcement (only valid after Feb 1, 2027) or a CA phishing-resistant bootstrap loop misdiagnosed as rollout behavior | Confirm current date vs. Feb 1, 2027; if before, treat as the `Passkeys-B.md` Fix 2 bootstrap loop instead |
| Password reset (SSPR) suddenly fails for a user who "always" used SMS | SSPR explicit-registration requirement, effective Sept 7, 2026 — user never formally registered SMS/voice as an SSPR method | `authorizationPolicy.allowedToUseSSPR` + user's registered methods list |
| Org wants to keep SMS/voice indefinitely with no changes | Not supported natively past Feb 1, 2027 — must either migrate to passkeys or configure a Security Store telecom provider | No opt-out exists for Phase 2; plan Fix 4 |
| Admin sets `passkeyDynamicMigration: true` expecting it to also delay Feb 1, 2027 | Misunderstanding of scope — the opt-out ONLY covers the Phase 1 window | Re-read opt-out scope; there is no opt-out for Phase 2 |
| B2B/guest users not seeing passkey prompts at all | Expected in the near term — passkey support for B2B/guest users is planned for end of CY2026, not yet available | Confirm tenant's guest population and defer their migration plan accordingly |
| Azure AD B2C tenant admin asking about this rollout | Out of scope entirely — B2C is explicitly unaffected | No action needed |
| Entra External ID tenant admin asking about this rollout | Delayed to a separately-announced future date, not this timeline | Do not apply this runbook's dates to External ID tenants |
| Helpdesk mis-routes "why is Entra asking me for a passkey" ticket to standard FIDO2 troubleshooting | Rollout awareness gap on the support team | Cross-train against this file's Triage table, distinct from `Passkeys-B.md` |

---

## Validation Steps

**1. Confirm the tenant's current opt-out state**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" |
    Select-Object -ExpandProperty optOutSettings
```
Expected shape: `@{ passkeyDynamicMigration = $true|$false }`. Absence of the property entirely is
equivalent to `false` (in scope for Phase 1 auto-enablement).

**2. Enumerate the exact in-scope (SMS/Voice-enabled) user population**
Use Microsoft's own published analyzer rather than reconstructing the logic manually — it correctly
accounts for both the modern AMP surface and the deprecated legacy per-user MFA settings surface,
which most hand-rolled Graph queries miss:
```
https://github.com/microsoft/entra-sms-voice-usage-analyzer
```
A non-zero result confirms Phase 1/Phase 2 exposure.

**3. Confirm Registration Campaign target and state**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/registrationEnforcement" |
    ConvertTo-Json -Depth 6
```
After Sept 1, 2026, expect `state: microsoftManaged` if the tenant did not opt out, with the target
scope including the SMS/Voice population identified in Step 2.

**4. Confirm SSPR's explicit-registration posture**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" |
    Select-Object -ExpandProperty allowedToUseSSPR
Get-MgUserAuthenticationMethod -UserId "<user@contoso.com>" | Select-Object "@odata.type"
```
Cross-reference: does the user have a method registered that is SSPR-eligible, or were they relying
on an implicit SMS/voice number never formally registered for reset?

**5. Confirm SMS/Voice authentication method policy states directly**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Sms" | Select-Object state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Voice" | Select-Object state
```
Note: these remain `enabled` throughout Phase 1 — Microsoft does not disable the methods themselves
until the Feb 1, 2027 telecom-delivery retirement. A ticket claiming "SMS MFA stopped working" before
that date is NOT explained by this policy state and needs separate root-causing (carrier issue, CA
policy change, etc.).

**6. If pursuing the telecom-provider path, confirm Security Store availability for the tenant's
region**
No stable Graph endpoint is published for Security Store provider listings as of this writing — this
is an admin-center/marketplace UI check: **Microsoft Security Store > (search telecom providers)**,
available from Sept 18, 2026 for review and Oct 30, 2026 for configuration.

---

## Troubleshooting Steps by Phase

### Phase 1 — Rollout Awareness / Triage Misclassification

1. Confirm the current date relative to Sept 1, 2026 and Feb 1, 2027 before diagnosing anything —
   most "is this a bug" questions are answered by the calendar alone (Validation Step, Retirement
   Timeline table).
2. Confirm the affected users are actually SMS/Voice-enabled (Validation Step 2) — a user reporting
   an unexpected passkey prompt who is NOT SMS/Voice-enabled has a different root cause (e.g., a
   tenant-wide Registration Campaign the org itself configured for another method).
3. Confirm the prompt is dismissible (non-blocking) — if yes, this is expected Phase 1 behavior;
   route to Fix 2 (communication), not a technical fix.

### Phase 2 — Genuine Sign-In Blocking Reported

1. Confirm current date — genuine Phase 2 (unavoidable blocking) enforcement is only valid on or
   after Feb 1, 2027. A block reported before that date is NOT expected Phase 2 behavior.
2. If before Feb 1, 2027: treat as the Conditional Access phishing-resistant bootstrap loop — follow
   `Passkeys-B.md` Fix 2 / Phase 2 of `Passkeys-A.md`'s troubleshooting sequence directly; this
   rollout does not introduce a new lockout mechanism, it just increases the number of users hitting
   the pre-existing CA-driven one.
3. If on/after Feb 1, 2027: confirm whether the tenant configured a customer-managed telecom
   provider (Validation Step 6). If not, and the user's only method was SMS/Voice, this IS expected
   enforcement — the fix is to help the user complete passkey registration at the blocking prompt,
   not to try to bypass it (there is no bypass by design).

### Phase 3 — SSPR-Specific Tickets

1. Confirm the ticket date is on/after Sept 7, 2026 — before that date, SSPR-via-SMS/voice should
   still work normally and a failure has a different cause.
2. Confirm whether the user's SMS/voice number was ever formally *registered* as an SSPR method,
   versus just existing as a contact/MFA number (Validation Step 4) — this is the most common gap.
3. Direct the user to register an explicit SSPR-eligible method (passkey where supported, or another
   registered method) going forward.

### Phase 4 — Telecom-Provider Path Planning

1. Confirm a genuine, documented business/regulatory need exists — this path is not a general-purpose
   way to avoid the passkey migration.
2. Track the three relevant dates: Sept 18 (review), Oct 30 (configure), Feb 1, 2027 (must be live by
   this date to avoid any gap in SMS/voice availability for the affected population).
3. Pilot with a small user segment before assuming org-wide readiness.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full tenant exposure assessment and migration plan</summary>

```powershell
Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","Group.ReadWrite.All"

# Step 1 — run Microsoft's exposure analyzer (see Validation Step 2) and export the CSV

# Step 2 — build a migration tracking group from the CSV
New-MgGroup -DisplayName "SMS-Voice-Migration-Tracking" -MailEnabled:$false -SecurityEnabled:$true `
    -MailNickname "smsvoicemigrationtracking" -GroupTypes @()

$csvUsers = Import-Csv ".\sms-voice-exposure.csv"   # from the analyzer's own output
foreach ($u in $csvUsers) {
    $user = Get-MgUser -Filter "userPrincipalName eq '$($u.UserPrincipalName)'"
    if ($user) {
        New-MgGroupMember -GroupId "<trackingGroupId>" -DirectoryObjectId $user.Id
    }
}

# Step 3 — decide, per organizational segment, whether the target state is:
#   (a) migrate to passkeys (default recommendation for the vast majority of users), or
#   (b) configure a customer-managed telecom provider (only for documented regulatory/operational need)

# Step 4 — for segment (a), proactively enable a scoped Registration Campaign BEFORE Sept 1 rather
# than waiting for Microsoft's automatic one, so rollout is on your own communication schedule:
# Entra ID > Authentication methods > Registration campaign > State = Microsoft Managed > target the
# tracking group from Step 2

# Step 5 — for segment (b), begin the Security Store provider evaluation on/after Sept 18, 2026
```

**Rollback:** Removing users from the tracking group does not undo Microsoft's own retirement
timeline — this playbook is planning/tracking only; there is no tenant-level rollback of the
underlying Microsoft-driven schedule.

</details>

<details><summary>Playbook 2 — Set and later reverse the temporary opt-out</summary>

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.AuthenticationMethod"

# Set the opt-out (delays Phase 1 auto-enablement/campaign only)
Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" `
    -Body (@{ optOutSettings = @{ passkeyDynamicMigration = $true } } | ConvertTo-Json -Depth 5)

# Later, once ready to proceed with the standard rollout behavior, reverse it:
Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" `
    -Body (@{ optOutSettings = @{ passkeyDynamicMigration = $false } } | ConvertTo-Json -Depth 5)
```

**Rollback:** The reversal step above IS the rollback — flipping the same boolean back. Remember
this only ever affects the Phase 1 window; Phase 2 (Feb 1, 2027) enforcement is unaffected either
way.

</details>

<details><summary>Playbook 3 — Pre-empt SSPR breakage before Sept 7, 2026</summary>

```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","Reports.Read.All"

# Identify users whose ONLY plausible SSPR path today is an unregistered/implicit SMS or voice number
$users = Get-MgUser -All -Property Id,UserPrincipalName
$atRisk = foreach ($u in $users) {
    $methods = Get-MgUserAuthenticationMethod -UserId $u.Id -ErrorAction SilentlyContinue
    $hasExplicitSsprMethod = $methods | Where-Object {
        $_."@odata.type" -notmatch "passwordAuthenticationMethod"
    }
    if (-not $hasExplicitSsprMethod) {
        [PSCustomObject]@{ UPN = $u.UserPrincipalName; RegisteredMethodCount = $methods.Count }
    }
}
$atRisk | Export-Csv ".\SSPR-At-Risk-Users.csv" -NoTypeInformation
```

Direct at-risk users to formally register an SSPR-eligible method (ideally a passkey) before Sept 7,
2026, using the same communication cadence as the main migration (Playbook 1, Step 4).

**Rollback:** N/A — read-only reporting.

</details>

---

## Evidence Pack

```powershell
# Passkey Default Auth Rollout — Evidence Collector
# Scopes: Policy.Read.All, UserAuthenticationMethod.Read.All, AuditLog.Read.All
param(
    [Parameter(Mandatory)][string]$UserPrincipalName
)

Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","AuditLog.Read.All"

$out = ".\PasskeyRollout-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 1. Tenant opt-out state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" |
    ConvertTo-Json -Depth 6 | Out-File "$out\optout-policy.json"

# 2. SMS / Voice method policy state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Sms" |
    ConvertTo-Json | Out-File "$out\sms-policy.json"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Voice" |
    ConvertTo-Json | Out-File "$out\voice-policy.json"

# 3. Registration campaign state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/registrationEnforcement" |
    ConvertTo-Json -Depth 6 | Out-File "$out\registration-campaign.json"

# 4. User's registered methods
Get-MgUserAuthenticationMethod -UserId $UserPrincipalName |
    Select-Object Id, "@odata.type" |
    Export-Csv "$out\user-auth-methods.csv" -NoTypeInformation

# 5. SSPR authorization policy
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" |
    Select-Object allowedToUseSSPR | ConvertTo-Json | Out-File "$out\sspr-policy.json"

# 6. Recent sign-ins for the affected user
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UserPrincipalName'" -Top 10 |
    Select-Object CreatedDateTime, Status, AuthenticationRequirement, ConditionalAccessStatus |
    Export-Csv "$out\recent-signins.csv" -NoTypeInformation

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
Write-Host "Evidence pack: $out.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# 1. Check tenant opt-out state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" | Select-Object -ExpandProperty optOutSettings

# 2. Set the temporary opt-out
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" -Body '{"optOutSettings":{"passkeyDynamicMigration":true}}'

# 3. Reverse the opt-out
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" -Body '{"optOutSettings":{"passkeyDynamicMigration":false}}'

# 4. Check SMS authentication method policy state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Sms"

# 5. Check Voice authentication method policy state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Voice"

# 6. Check Registration Campaign state/target
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/registrationEnforcement"

# 7. Check a user's registered authentication methods
Get-MgUserAuthenticationMethod -UserId "<user@contoso.com>"

# 8. Check SSPR authorization policy
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy"

# 9. Pull recent sign-ins for MFA/CA status
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<user@contoso.com>'" -Top 5

# 10. Clone Microsoft's SMS/Voice exposure analyzer
git clone https://github.com/microsoft/entra-sms-voice-usage-analyzer

# 11. List CA policies requiring phishing-resistant strength (bootstrap-loop check)
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.GrantControls.AuthenticationStrength.DisplayName -match "Phishing" }

# 12. Check authorization policy's default MFA-related settings broadly
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" | ConvertTo-Json -Depth 6
```

---

## 🎓 Learning Pointers

- **Two separate enforcement phases with two very different risk profiles** — Phase 1 (Sept 1, 2026)
  is a nudge, Phase 2 (Feb 1, 2027) is a hard, opt-out-free block. Every internal communication and
  runbook should make this distinction explicit; conflating them either creates unnecessary panic in
  September or false complacency going into February. [Passkeys by default and retirement of
  Microsoft-provided SMS and voice authentication](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sms-voice-retirement)
- **The SSPR tightening (Sept 7) is a distinct sub-timeline from the main passkey rollout (Sept 1)** —
  treat "password reset broke" and "getting a passkey prompt" as two different investigation paths
  even though they land in the same week. [FAQ for SMS and voice retirement](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sms-voice-retirement-faq)
- **The `passkeyDynamicMigration` opt-out is scoped narrowly and permanently expires** — it is not a
  general "keep SMS/Voice forever" switch. The only durable path to keep SMS/voice past Feb 1, 2027
  is a customer-managed telecom provider through the Security Store, which itself has its own
  Sept 18 / Oct 30, 2026 sub-timeline.
- **Most "blocked by the passkey prompt" tickets filed before Feb 1, 2027 are not this rollout** —
  they're almost always the pre-existing Conditional Access phishing-resistant bootstrap loop
  documented in `Passkeys-A.md`/`Passkeys-B.md`, just surfacing more often because more users are
  being nudged toward registration simultaneously.
- **B2B/guest passkey support isn't available at rollout launch** — plan a distinct, later timeline
  for guest-heavy tenants rather than assuming Sept 1 parity with internal users.
- **This change is public-cloud-only at launch** — sovereign clouds and Entra External ID follow
  separately-announced, later schedules; don't apply this file's dates to those tenant types.
