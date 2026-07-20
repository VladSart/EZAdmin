# Conditional Access — Authentication Strengths Hotfix Runbook (Mode B: Ops)
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

Run these to confirm whether a Conditional Access **Authentication Strength** grant control is the cause of a sign-in block or unexpected MFA prompt.

| Check | Where | If X → Do Y |
|-------|-------|-------------|
| **1. Is the block actually an auth-strength claims challenge?** | Entra sign-in logs → open the event → Conditional Access tab | Grant control shows `Require authentication strength` with a named strength (e.g. "Phishing-resistant MFA") rather than plain `Require multifactor authentication` |
| **2. Which strength is required, and does the user have a qualifying method registered?** | Policy → Grant → Require authentication strength → note the strength name | Compare against `Get-MgUserAuthenticationMethod` output for the user — if no method in the combination list is registered, this is an enrollment gap, not a policy bug |
| **3. Is this a custom strength with a narrow combination list?** | Entra → Protection → Authentication methods → Authentication strengths → open the strength | Custom strengths only list the exact combinations an admin picked — a method the user has (e.g. SMS) may simply not be in the allowed list |
| **4. Is the app/protocol capable of a claims challenge at all?** | Check app type in sign-in log | Legacy auth (POP/IMAP/older Office clients), some third-party SAML apps, and on-prem apps behind AD FS cannot always satisfy a step-up challenge — expect a hard block, not a prompt |
| **5. Did the user just register a new method?** | Entra → Users → Authentication methods | New FIDO2/WHfB registrations can take a few minutes to propagate before they satisfy a strength evaluation — retry after a short wait |

**Interpretation table**

| Symptom | Most Likely Cause |
|---------|--------------------|
| User prompted for MFA but still blocked after entering a code | Policy requires "Phishing-resistant MFA" or a custom strength that SMS/voice/push does not satisfy |
| User with FIDO2 key still blocked | Key not registered against this tenant/account, or excluded combination (e.g., FIDO2 key's AAGUID restricted via key restriction policy) |
| Works on one device, not another | WHfB is device-bound — a WHfB credential registered on Device A does not satisfy the strength when signing in from Device B |
| Federated (AD FS) user always fails phishing-resistant strength | `federatedMultiFactor` requires the federation trust to be explicitly marked as doing MFA in a way Entra trusts — see Fix 4 |
| Custom strength never satisfied even with the right method | Combination list built incorrectly (single methods vs. combinations of two) — see Fix 2 |
| User bypassed strength requirement unexpectedly | Another CA policy with a weaker/no auth-strength grant also matched and used "OR" logic across policies — review overlapping policies |
| Break-glass account blocked during an incident | Break-glass accounts should be excluded from ALL auth-strength policies — verify exclusion group membership |

---

## Dependency Cascade

<details><summary>What must be true for an Authentication Strength requirement to be satisfied</summary>

```
User signs in / resource requests step-up
  └─ CA policy has grant control: "Require authentication strength: <Strength Name>"
       └─ Entra determines which authentication method(s) the user used THIS session
            ├─ Built-in strengths (fixed, cannot be edited):
            │     ├─ Multifactor authentication (any two methods)
            │     ├─ Passwordless MFA (FIDO2, WHfB, Certificate-based Auth MF, MS Authenticator passwordless)
            │     └─ Phishing-resistant MFA (FIDO2, WHfB, Certificate-based Auth MF, federatedMultiFactor if trusted)
            └─ Custom strengths (admin-defined combination list)
       └─ Method(s) used this session compared against the strength's allowed combination list
            ├─ Match → grant satisfied, access allowed
            └─ No match → user is challenged for an additional/different method (step-up)
                   └─ If no qualifying method is registered → hard block, user must register one out-of-band
  └─ PREREQUISITE: method must be registered in Entra for THIS user, on THIS device (for device-bound methods)
       ├─ FIDO2 security key — registered per-key, tenant-scoped
       ├─ Windows Hello for Business — registered per-device (device-bound key)
       ├─ Certificate-based auth (Multi-Factor) — requires CBA configured + cert issued per user
       └─ federatedMultiFactor — requires AD FS/third-party IdP federation configured as MFA-trusted
```

**Key gotcha:** Authentication strength is evaluated against the methods used **in the current sign-in session**, not everything the user has ever registered. A user with a FIDO2 key who signs in with a password + SMS code will fail a "Phishing-resistant MFA" strength requirement even though they own a qualifying key — they simply didn't use it this time. Entra will prompt them to use it if it detects it's available, but on some client/browser combinations the prompt UX can be unclear.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the exact strength and grant control from the sign-in log**
```
Entra ID → Monitoring → Sign-in logs → filter User = <UPN>, Date = <incident time>
Open the sign-in → Conditional Access tab → find the policy → Grant controls detail
```
Look for `Require authentication strength` and the strength's display name.

---

**Step 2 — Check which methods the user has registered**
```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All"

$upn = "<user@domain.com>"
Get-MgUserAuthenticationMethod -UserId $upn |
    Select-Object Id, @{N='Type';E={$_.AdditionalProperties['@odata.type']}}
```
Cross-reference method types against the strength's allowed combinations (Step 3).

---

**Step 3 — Pull the strength's exact allowed combinations**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"

Get-MgPolicyAuthenticationStrengthPolicy | Select-Object Id, DisplayName, PolicyType |
    Format-Table -AutoSize

# Detail on a specific strength, including allowed combinations
Get-MgPolicyAuthenticationStrengthPolicy -AuthenticationStrengthPolicyId "<strengthId>" |
    Select-Object -ExpandProperty AllowedCombinations
```

---

**Step 4 — Check for device-bound method mismatch (WHfB / FIDO2)**
```
User → Authentication methods (Entra portal) shows registered methods, but NOT which device
For WHfB specifically: the credential is bound to the device it was provisioned on
```
If the user is signing in from a different/new device, WHfB from the old device won't help — they need WHfB provisioned on the current device, or a portable method like FIDO2.

---

**Step 5 — Check for federation trust configuration (federated users only)**
```powershell
Connect-MgGraph -Scopes "Domain.Read.All"
Get-MgDomainFederationConfiguration -DomainId "<domain.com>" |
    Select-Object IssuerUri, FederatedIdpMfaBehavior
```
`FederatedIdpMfaBehavior` must be `acceptIfMfaDoneByFederatedIdp` (or similar trusted-MFA setting) for `federatedMultiFactor` to satisfy phishing-resistant strength — otherwise Entra will always re-challenge.

---

**Step 6 — Simulate with What If**
```
Entra → Protection → Conditional Access → What If
User + target app → review which policies apply and their grant controls
```
Confirms whether the auth-strength policy is even the one in scope, ruling out a different overlapping policy.

---

## Common Fix Paths

<details><summary>Fix 1 — Register a qualifying method for the user (fastest unblock)</summary>

**Problem:** User has no method that satisfies the required strength.

**Fix — self-service (preferred):**
```
Have the user go to https://mysignins.microsoft.com/security-info
→ Add method → FIDO2 Security Key / Windows Hello for Business (on the current device)
```

**Fix — admin-assisted (Temporary Access Pass to bootstrap registration):**
```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.ReadWrite.All"

$params = @{
    lifetimeInMinutes = 60
    isUsableOnce = $true
}
New-MgUserAuthenticationTemporaryAccessPassMethod -UserId "<upn>" -BodyParameter $params
```
Note: a Temporary Access Pass itself will **not** satisfy a phishing-resistant strength — it is only meant to let the user sign in once to register a real qualifying method (FIDO2/WHfB/CBA).

**Rollback:** N/A — this is additive; revoke the TAP after use if unused (`Remove-MgUserAuthenticationTemporaryAccessPassMethod`).

</details>

---

<details><summary>Fix 2 — Correct a custom strength's allowed combinations</summary>

**Problem:** A custom authentication strength was built with the wrong combination (e.g., single methods when a two-factor combination was intended, or missing a method your users actually have).

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.AuthenticationMethod"

$strengthId = "<customStrengthId>"

# View current combinations
(Get-MgPolicyAuthenticationStrengthPolicy -AuthenticationStrengthPolicyId $strengthId).AllowedCombinations

# Update combinations — example: FIDO2 alone, OR password+softwareOneTimePasscode
$body = @{
    allowedCombinations = @(
        "fido2",
        "windowsHelloForBusiness",
        "password,softwareOath"
    )
}
Update-MgPolicyAuthenticationStrengthPolicy -AuthenticationStrengthPolicyId $strengthId -BodyParameter $body
```

**Rollback:** Re-apply the previous `allowedCombinations` array (copy it before editing).

</details>

---

<details><summary>Fix 3 — Exclude break-glass / service accounts from the auth-strength policy</summary>

**Problem:** Emergency access accounts got caught by a phishing-resistant strength requirement during an incident and are now locked out because they have no FIDO2/WHfB registered (by design, for portability).

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$policyId = "<caPolicyId>"
$breakGlassGroupId = "<breakGlassSecurityGroupId>"

$policy = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId
$excluded = $policy.Conditions.Users.ExcludeGroups + $breakGlassGroupId

Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -BodyParameter @{
    conditions = @{ users = @{ excludeGroups = $excluded } }
}
```

**Rollback:** Remove the group ID from `excludeGroups` once break-glass accounts have qualifying methods registered.

</details>

---

<details><summary>Fix 4 — Enable federated MFA trust for phishing-resistant strength</summary>

**Problem:** Federated (AD FS) users can never satisfy "Phishing-resistant MFA" even though AD FS is doing MFA on its side.

```powershell
Connect-MgGraph -Scopes "Domain.ReadWrite.All"

Update-MgDomainFederationConfiguration -DomainId "<domain.com>" -BodyParameter @{
    federatedIdpMfaBehavior = "acceptIfMfaDoneByFederatedIdp"
}
```

**Requires:** the AD FS relying party trust for Entra must actually emit the `http://schemas.microsoft.com/claims/authnmethodsreferences` claim with a recognized MFA method value, or Entra will still re-challenge regardless of this setting.

**Rollback:**
```powershell
Update-MgDomainFederationConfiguration -DomainId "<domain.com>" -BodyParameter @{
    federatedIdpMfaBehavior = "rejectMfaByFederatedIdp"
}
```

</details>

---

<details><summary>Fix 5 — Temporarily downgrade the grant control during an outage</summary>

**Problem:** A newly enabled phishing-resistant strength policy is blocking a large population who haven't finished FIDO2/WHfB rollout, and it needs to be safely rolled back without disabling MFA entirely.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$policyId = "<caPolicyId>"

# Swap the grant control from a specific authentication strength to standard MFA
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -BodyParameter @{
    grantControls = @{
        operator = "OR"
        builtInControls = @("mfa")
    }
}
```

**Rollback (re-apply the strength once rollout is complete):**
```powershell
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -BodyParameter @{
    grantControls = @{
        authenticationStrength = @{ id = "<strengthId>" }
    }
}
```

</details>

---

## Escalation Evidence

```
CONDITIONAL ACCESS — AUTHENTICATION STRENGTH ISSUE — ESCALATION TICKET
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Tenant ID:                 ___________________________________
Policy Name / ID:          ___________________________________
Required Strength Name:    ___________________________________
Strength Type:             [ ] Built-in  [ ] Custom
Allowed Combinations:      ___________________________________
Affected User (UPN):       ___________________________________
Sign-in time:               ___________________________________
Sign-in ID (GUID):         ___________________________________
Methods registered (Get-MgUserAuthenticationMethod output):
  ___________________________________________________________
Device used at sign-in:    ___________________________________
Is user federated (AD FS)? [ ] Yes  [ ] No
FederatedIdpMfaBehavior:   ___________________________________

CA sign-in log result for this policy: ___________________________________
CA failure reason:                     ___________________________________

Steps taken:
[ ] Verified strength's allowed combinations via Graph
[ ] Verified user's registered methods
[ ] Checked device-binding (WHfB) mismatch
[ ] Ran What If simulation
[ ] Checked break-glass exclusion group membership
[ ] Checked federation MFA trust setting (if applicable)

Attach:
- Sign-in log event JSON
- Get-MgPolicyAuthenticationStrengthPolicy output for the named strength
- Get-MgUserAuthenticationMethod output for the affected user
```

---

## 🎓 Learning Pointers

- **Authentication strength evaluates the current session's methods, not the user's full registration set.** A user can own a FIDO2 key and still fail a phishing-resistant challenge if they authenticated with password+SMS this session. Prompt them to explicitly choose the stronger method at sign-in. [Authentication strengths overview](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-strengths)

- **Built-in strengths cannot be edited — only custom strengths can.** If the built-in "Phishing-resistant MFA" strength doesn't fit a client's exact method mix, clone the concept into a custom strength rather than trying to modify the built-in one (the API will reject edits to built-ins). [Custom authentication strengths](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-strengths#custom-authentication-strengths)

- **Windows Hello for Business is device-bound; FIDO2 is portable.** For users who roam across devices (shared kiosks, hot-desking), FIDO2 security keys are the more reliable phishing-resistant method — WHfB requires re-provisioning per device. [WHfB deployment guide](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-passwordless)

- **Federated (AD FS) phishing-resistant MFA requires an explicit trust setting, not just AD FS doing MFA.** `federatedIdpMfaBehavior` on the domain's federation configuration controls whether Entra ID trusts the `authnmethodsreferences` claim instead of re-challenging. Silent misconfiguration here is a common source of "federated users always get re-prompted" tickets. [Federated MFA behavior](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-strengths#authentication-strengths-with-federated-users)

- **Always stage a new/edited authentication-strength CA policy in Report-only first.** Because a hard-mismatch means a hard block (not a soft warning), roll out with `state = "enabledForReportingButNotEnforced"`, check sign-in logs for a week, and confirm the affected population's method registration coverage before enforcing. [CA report-only mode](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-report-only)

- **Authentication Context vs. Authentication Strength are different, complementary controls.** Authentication Context (`c1`–`c25` claims tagged on specific apps/actions, e.g., a SharePoint sensitivity label) triggers *when* a step-up challenge fires; Authentication Strength defines *what counts* as satisfying it. Don't confuse the two when a client asks for "step-up MFA on sensitive documents." [Authentication context](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-cloud-apps#authentication-context)
