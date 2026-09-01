# Passkey Default Authentication Rollout (SMS/Voice Retirement) — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer. **This is a tenant-wide auto-enablement event, not a
per-user bug.** Starting **September 1, 2026**, Microsoft Entra ID automatically enrolls every user
who is enabled for SMS or Voice authentication into a passkey (FIDO2) profile and turns on a
Microsoft-managed Registration Campaign for them. This is distinct from ordinary passkey
registration issues — see `Passkeys-B.md`/`Passkeys-A.md` for FIDO2-specific troubleshooting once a
user is already mid-registration. This file covers the rollout event itself: who is affected, how
to check exposure, how to opt out temporarily, and how to handle the resulting helpdesk load.

```powershell
Connect-MgGraph -Scopes "Policy.Read.All","Policy.ReadWrite.AuthenticationMethod","UserAuthenticationMethod.Read.All"

# 1. Check whether the tenant has opted out of automatic passkey enablement
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" |
    Select-Object -ExpandProperty optOutSettings

# 2. Check current SMS/Voice authentication method policy state (legacy + modern)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Sms" |
    Select-Object state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Voice" |
    Select-Object state

# 3. Check Registration Campaign state (should flip to "Microsoft Managed" for in-scope users after Sept 1)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/registrationEnforcement" |
    ConvertTo-Json -Depth 5

# 4. Spot-check one affected user's authentication methods
$upn = "<user@contoso.com>"
Get-MgUserAuthenticationMethod -UserId $upn | Select-Object Id, "@odata.type"
```

| Result | Action |
|--------|--------|
| `optOutSettings.passkeyDynamicMigration` is missing/`false` and tenant still has SMS/Voice users | → Fix 1: Set the temporary opt-out (only if not ready to migrate yet) |
| Helpdesk flooded with "why am I being asked for a passkey" tickets since Sept 1 | → Fix 2: Communicate + scope the registration campaign properly |
| Users blocked/looped trying to register a passkey via the nudge prompt | → Fix 3: Same bootstrap-loop root cause as `Passkeys-B.md` Fix 2 — check CA phishing-resistant policies |
| Org has a genuine regulatory/operational need to keep SMS/Voice | → Fix 4: Plan for a customer-managed telecom provider (Security Store, available from Oct 30, 2026) |
| SSPR suddenly rejecting SMS/voice-based resets | → Expected — SSPR only accepts explicitly registered methods as of **Sept 7, 2026**; see `SSPR-B.md` |
| Question is "will we get locked out Feb 1, 2027?" | → No forced lockout — non-compliant users get a **blocking passkey registration prompt** at sign-in, not account lockout |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Microsoft-wide retirement timeline — not a tenant-configurable schedule]
  ├─ Sept 1, 2026  : Auto-enable passkeys + Registration Campaign for SMS/Voice-enabled users
  ├─ Sept 7, 2026   : SSPR requires explicitly registered auth methods (no more SMS/voice-by-default)
  ├─ Sept 18, 2026  : Customer-managed telecom provider details published (Security Store)
  ├─ Sept 30, 2026  : CA Custom Controls — no new/modified controls (see CustomControlsRetirement-B.md)
  ├─ Oct 30, 2026   : Customers can select/configure a telecom provider via Security Store
  └─ Feb 1, 2027    : Microsoft-provided SMS/Voice telecom delivery fully retired — no opt-out
         |
[Tenant's authentication methods policy (AMP)]
  ├─ Users enabled for SMS in AMP or legacy MFA settings  → in scope
  ├─ Users enabled for Voice in AMP or legacy MFA settings → in scope
  └─ Users already on passkeys / WHfB / another phishing-resistant method → NOT re-prompted
         |
[Opt-out gate — optOutSettings.passkeyDynamicMigration]
  ├─ true  → tenant excluded from auto-enablement + auto-campaign during the opt-out window
  └─ false/unset → auto-enablement proceeds on schedule, no admin action required
         |
[Registration Campaign — flips to "Microsoft Managed" for in-scope users]
  └─ Nudges user to register a passkey on next MFA-satisfied sign-in
  └─ Unlimited snoozes by default — does not block sign-in before Feb 1, 2027
         |
[Feb 1, 2027 hard enforcement — applies regardless of opt-out]
  └─ Users whose ONLY MFA method is still SMS/Voice get a BLOCKING passkey registration prompt
  └─ Users with a customer-managed telecom provider configured are unaffected
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm whether the tenant has already opted out**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" |
    Select-Object -ExpandProperty optOutSettings
```
If this returns nothing or `passkeyDynamicMigration: false`, the tenant is on the default (in-scope)
path and auto-enablement applies on schedule.

**2. Identify exactly which users are enabled for SMS or Voice**
Microsoft publishes a dedicated PowerShell analyzer for this — do not attempt to hand-roll the same
logic against `authenticationMethodsPolicy` alone, since legacy per-user MFA settings are a separate
(deprecated) surface from the modern AMP and both must be checked:
```powershell
# https://github.com/microsoft/entra-sms-voice-usage-analyzer
# Requires Global Reader, Authentication Policy Administrator, or Security Reader
git clone https://github.com/microsoft/entra-sms-voice-usage-analyzer
cd entra-sms-voice-usage-analyzer
# Follow the repo's own README for the exact invocation — output is a CSV of in-scope users
```
Any non-zero result means the tenant is in scope for the Sept 1 auto-enablement.

**3. Confirm Registration Campaign scope after Sept 1**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/registrationEnforcement" |
    ConvertTo-Json -Depth 6
```
Expect `authenticationMethodsRegistrationCampaign.state: microsoftManaged` with the target now
including the SMS/Voice population if the tenant did not opt out.

**4. Check whether a specific ticket is "rollout noise" vs. a real bootstrap-loop bug**
If the user reaches the passkey registration prompt and can dismiss/snooze it, that's expected
rollout behavior — not a bug. If the user is blocked from signing in entirely because Conditional
Access requires phishing-resistant MFA before they can reach registration, that is the same chicken/
egg loop covered in `Passkeys-B.md` Fix 2 — treat it as that fix, not as a new issue.

**5. Confirm SSPR impact if password-reset tickets spike after Sept 7**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" |
    Select-Object -ExpandProperty allowedToUseSSPR
```
As of Sept 7, 2026, SSPR only accepts methods the user has **explicitly registered** — a user who
relied on an implicitly-available SMS/voice number without formally registering it for SSPR will
start failing resets. Direct them to register a passkey or another explicit SSPR-eligible method.

---
## Common Fix Paths

<details><summary>Fix 1 — Temporarily opt out of automatic passkey enablement</summary>

Use when: the org needs more lead time (configuring a customer-managed telecom provider, running its
own migration plan) before Microsoft auto-enrolls SMS/Voice users into passkeys and the Registration
Campaign.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.AuthenticationMethod"

$body = @{
    optOutSettings = @{
        passkeyDynamicMigration = $true
    }
} | ConvertTo-Json -Depth 5

Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" `
    -Body $body
```

**Important caveats:**
- This is a **temporary** window only — it covers the Sept 1, 2026 → Feb 1, 2027 period. The Feb 1,
  2027 enforcement (blocking passkey prompt for SMS/voice-only users) applies **regardless of this
  setting** — there is no opt-out for that date.
- Opting out does not stop the clock on planning — use the extra time to actually migrate users or
  stand up a customer-managed telecom provider, not to defer indefinitely.

**Rollback:** `PATCH` the same property back to `false`, or simply leave it — Microsoft's own
enforcement takes over automatically once the opt-out period ends on Feb 1, 2027.

</details>

<details><summary>Fix 2 — Scope and communicate the registration campaign properly</summary>

Use when: helpdesk ticket volume spikes because users are confused by unexpected passkey-registration
prompts.

```
1. Run the SMS/Voice usage analyzer (Diagnosis Step 2) to get the exact in-scope user list.
2. Create a security group from that CSV:
   New-MgGroup -DisplayName "SMS-Voice-Migration-Users" -MailEnabled:$false -SecurityEnabled:$true `
       -MailNickname "smsvoicemigration" -GroupTypes @()
   (add members via Add-MgGroupMember in a loop over the CSV)
3. Send a phased communication BEFORE the technical change lands wherever possible:
   - Awareness: SMS/Voice is retiring, here's why, here's what replaces it
   - Action: step-by-step passkey registration guidance for their device type
   - Reminder: for anyone who hasn't registered yet
   Use Microsoft's own templates: https://aka.ms/mfatemplates — scope messaging to the group above.
4. If ticket volume remains high, verify the Registration Campaign snooze behavior — by default users
   get UNLIMITED snoozes, which should mean this is annoying but never blocking pre-Feb 2027. If users
   report being blocked, escalate as the bootstrap-loop issue (Fix 3), not rollout noise.
```

**Rollback:** N/A — this is a communication/process fix, not a technical change.

</details>

<details><summary>Fix 3 — User blocked/looped by the registration nudge (bootstrap loop)</summary>

Use when: a user reports they cannot sign in at all because of the new passkey prompt, not just an
annoying-but-dismissible nudge.

```
This is the same phishing-resistant-MFA bootstrap loop covered in Passkeys-B.md Fix 2 — a
Conditional Access policy is requiring phishing-resistant MFA on "All resources" (including the
"Register security information" user action) before the user has any phishing-resistant method
registered yet. The Sept 1 rollout did not introduce a new failure mode here — it just increased
how many users hit the existing one at once, because far more users are now being nudged to register.

Follow Passkeys-B.md Fix 2 verbatim: build the scoped TAP-based "Onboard Passkey" bootstrap flow.
```

**Rollback:** See `Passkeys-B.md` Fix 2.

</details>

<details><summary>Fix 4 — Plan for a customer-managed telecom provider (genuine SMS/Voice need)</summary>

Use when: the organization has a documented regulatory, compliance, or operational reason to keep
SMS/voice as an MFA/SSPR channel past Feb 1, 2027 (e.g., specific regulated-industry requirements, or
user populations without a passkey-capable device).

```
1. Document the specific requirement (which regulation, which user segment, why passkeys alone
   don't satisfy it) — this becomes the business justification for procurement/security sign-off.
2. From Sept 18, 2026: review available telecom providers and terms in the Microsoft Security Store.
3. From Oct 30, 2026: select and configure a telecom provider from the Security Store for the
   documented user segment(s).
4. Stand up the carrier contract via the marketplace flow; pilot with a small group before broad
   rollout.
5. For every other user segment NOT covered by the documented need, default to passkeys — don't use
   the telecom-provider path as a blanket way to avoid the passkey migration tenant-wide.
```

**Rollback:** N/A — this is a forward-looking procurement/config task, not a reversible technical
change captured here.

</details>

---
## Escalation Evidence

```
PASSKEY DEFAULT AUTH ROLLOUT ESCALATION
=========================================
Date/Time                          :
Tenant ID                          :
Tenant opted out (passkeyDynamicMigration) : Yes / No
User(s) affected                   :
Was user previously SMS/Voice-only? : Yes / No
Symptom                            : Dismissible nudge / Blocking prompt / SSPR failure / Other
SMS/Voice AMP policy state         : Sms=___  Voice=___
Registration Campaign state        : notMicrosoftManaged / microsoftManaged
CA policy suspected (if blocking)  :
CA targets "Register security
information" user action?          : Yes / No
Error message (verbatim)           :
Steps Already Tried                :
```

---
## 🎓 Learning Pointers

- **This is a scheduled, Microsoft-driven tenant change, not an opt-in feature launch** — starting
  September 1, 2026, every tenant with SMS/Voice-enabled users is auto-enrolled unless it explicitly
  sets `optOutSettings.passkeyDynamicMigration` beforehand. Proactive tenants should have run the
  usage analyzer and communicated to users *before* this date, not reacted to it. [Passkeys by default
  and retirement of Microsoft-provided SMS and voice authentication](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sms-voice-retirement)
- **The opt-out is temporary and has a hard expiry** — `passkeyDynamicMigration: true` only delays
  things until Feb 1, 2027. There is explicitly no opt-out for that date's enforcement; plan the
  opt-out window as extra migration time, not a permanent exemption.
- **SSPR tightened on a different date than the main rollout (Sept 7, 2026)** — don't conflate the
  two when triaging tickets. A user who can't reset their password via SMS after Sept 7 is hitting the
  SSPR explicit-registration requirement, which is a separate FAQ item from the Sept 1 passkey nudge.
  [FAQ for SMS and voice retirement](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sms-voice-retirement-faq)
- **Azure AD B2C tenants are entirely out of scope; Entra External ID is delayed to a later,
  separately-announced date** — don't apply this runbook or set expectations for either of those
  tenant types.
- **The Registration Campaign nudge is non-blocking by design until Feb 1, 2027** — unlimited snoozes
  are the default. If a ticket describes an actual sign-in block, look for the CA phishing-resistant
  bootstrap loop first before assuming it's "just" this rollout.
- **B2B/guest users are in scope but passkey support for them isn't planned until end of calendar year
  2026** — flag any B2B-heavy tenant as needing a distinct migration plan/timeline until that ships.
