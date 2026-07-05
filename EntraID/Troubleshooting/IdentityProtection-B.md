# Entra ID Protection (Risky Users & Sign-Ins) — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer.

```powershell
# 1. Check the user's current risk state
Connect-MgGraph -Scopes "IdentityRiskyUser.Read.All"
Get-MgRiskyUser -Filter "userPrincipalName eq '<UPN>'" |
    Select-Object UserPrincipalName, RiskLevel, RiskState, RiskDetail, RiskLastUpdatedDateTime

# 2. Check recent risk detections for the user
Get-MgRiskDetection -Filter "userPrincipalName eq '<UPN>'" -Top 10 |
    Select-Object DetectedDateTime, RiskEventType, RiskLevel, RiskState, Activity

# 3. Check whether user is blocked by a risk-based Conditional Access policy
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.UserRiskLevels -or $_.Conditions.SignInRiskLevels } |
    Select-Object DisplayName, State

# 4. Check license — Identity Protection risk policies require Entra ID P2
Get-MgUserLicenseDetail -UserId '<UPN>' | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2|SPE_E5|M365_E5" }

# 5. Check sign-in logs for the specific flagged event
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 5 |
    Select-Object CreatedDateTime, RiskLevelDuringSignIn, RiskState, RiskDetail, Location, IpAddress, ConditionalAccessStatus
```

| Result | Action |
|--------|--------|
| `RiskState: atRisk` or `confirmedCompromised` | → Fix 1: Remediate risky user |
| User blocked from sign-in, `RiskLevel: high` | → Fix 2: Self-remediation via risk policy (password reset/MFA) |
| No P2 license on the user | → Fix 3: License gap — risk detection still logs, but policies won't enforce |
| CA policy in `report-only` | → Fix 4: Flip to enforced once validated |
| Detection is a known false positive (e.g., travel, VPN) | → Fix 5: Dismiss risk / confirm safe |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Entra ID P2 license]
  └─ Assigned to the user (or covered by Security Defaults' free-tier heuristics — limited)
         |
[Identity Protection detection engine]
  └─ Microsoft's ML/threat-intel signals (leaked creds, atypical travel, anonymous IP, malware-linked IP,
     password spray, token replay, etc.)
         |
[Risk Detection recorded]
  └─ riskDetection object created — sign-in risk (real-time) or user risk (offline/aggregate)
         |
[Risk state on user/session]
  └─ userRiskState / signInRiskState fields updated
         |
[Conditional Access risk policy]
  └─ "Sign-in risk" and/or "User risk" conditions configured
  └─ Grant control: require MFA, require password change, or block
         |
[Enforcement at sign-in]
  └─ User challenged, blocked, or allowed based on policy + current risk state
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the risk detection is real, not a portal artifact**
```powershell
Get-MgRiskDetection -Filter "userPrincipalName eq '<UPN>'" -Top 5 |
    Select-Object DetectedDateTime, RiskEventType, RiskLevel, Source, DetectionTimingType
```
`RiskEventType` values to know: `leakedCredentials`, `anonymizedIPAddress`, `unfamiliarFeatures`, `maliciousIPAddress`, `unlikelyTravel`, `passwordSpray`, `tokenIssuerAnomaly`, `mcasImpossibleTravel`. `leakedCredentials` and `passwordSpray` are the most actionable — the account password should be treated as compromised.

**2. Check whether the risk is sign-in (real-time) or user (aggregate) risk**
```powershell
Get-MgRiskyUser -Filter "userPrincipalName eq '<UPN>'" | Select-Object RiskLevel, RiskState, RiskLastUpdatedDateTime
```
Sign-in risk is evaluated per session; user risk aggregates unremediated sign-in risk over time into an account-level risk score.

**3. Check the CA policy actually applying**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 1 |
    Select-Object -ExpandProperty AppliedConditionalAccessPolicies
```
*Good:* Policy shows `enforcedGrantControls: ["Mfa"]` and `result: success` after remediation.
*Bad:* `result: failure` with `notApplied` — policy isn't targeting this user/group, or is in report-only.

**4. Confirm license coverage**
```powershell
Get-MgUserLicenseDetail -UserId '<UPN>' | Select-Object SkuPartNumber
```
Without P2, risk *detections* still populate in the free tier for a subset of signals, but risk-based CA policies (the enforcement layer) require P2.

**5. Check if the user already self-remediated**
```powershell
Get-MgRiskyUserHistory -RiskyUserId '<ObjectId>' | Select-Object RiskLevel, RiskState, ActivityDateTime, InitiatedBy
```
`RiskState: remediated` with `InitiatedBy: self` means the user cleared it via MFA/SSPR satisfying the risk policy.

---
## Common Fix Paths

<details><summary>Fix 1 — Remediate a confirmed risky user</summary>

Use when: `RiskState: atRisk` and the risk is high-confidence (leaked credentials, confirmed compromise).

```powershell
Connect-MgGraph -Scopes "IdentityRiskyUser.ReadWrite.All","User.ReadWrite.All"

# Force password reset (invalidates current password, revokes sessions)
Update-MgUser -UserId '<UPN>' -PasswordProfile @{ ForceChangePasswordNextSignIn = $true }

# Revoke all active sessions/tokens immediately
Revoke-MgUserSignInSession -UserId '<UPN>'

# Dismiss the risk after confirming remediation is complete
Invoke-MgDismissRiskyUser -UserIds @('<ObjectId>')
```

**Rollback:** None needed — this is a security action. If the account was falsely flagged, use Fix 5 instead.

</details>

<details><summary>Fix 2 — Guide user through self-remediation</summary>

Use when: risk policy is configured to allow "self-remediation" (require MFA + secure password change) rather than admin-only reset.

1. User attempts sign-in → is prompted to register/complete MFA and change password.
2. Confirm the policy allows this:
```powershell
Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId '<PolicyId>' |
    Select-Object -ExpandProperty GrantControls
```
Expected: `BuiltInControls` includes both `mfa` and requires a secure password change control — this is set in the policy's session controls, not visible via Graph alone; verify in the portal (Protection > Conditional Access > policy > Grant).
3. If the user is stuck in a loop, confirm they have at least one working MFA method registered:
```powershell
Get-MgReportAuthenticationMethodUserRegistrationDetail -UserId '<ObjectId>' | Select-Object IsMfaRegistered, MethodsRegistered
```

**Rollback:** N/A — self-remediation is non-destructive to the account.

</details>

<details><summary>Fix 3 — Handle missing P2 license</summary>

Use when: detections show up but no risk-based CA policy is enforcing.

```powershell
# Check available P2 licenses in the pool
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# Assign if available
Set-MgUserLicense -UserId '<UPN>' -AddLicenses @{SkuId = '<P2SkuId>'} -RemoveLicenses @()
```

If no licenses are available, escalate for procurement — in the interim, rely on Security Defaults or manual review of `Get-MgRiskDetection` output, since enforcement won't trigger automatically.

**Rollback:** Remove the license assignment if applied in error: `Set-MgUserLicense -UserId '<UPN>' -AddLicenses @() -RemoveLicenses @('<P2SkuId>')`.

</details>

<details><summary>Fix 4 — Move a risk policy from report-only to enforced</summary>

Use when: a new sign-in/user risk CA policy has been validated in report-only mode and needs to go live.

```powershell
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId '<PolicyId>' -BodyParameter @{
    state = "enabled"
}
```

**Rollback:**
```powershell
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId '<PolicyId>' -BodyParameter @{
    state = "enabledForReportingButNotEnforced"
}
```

</details>

<details><summary>Fix 5 — Dismiss a false-positive risk detection</summary>

Use when: risk is due to known travel, corporate VPN egress IP change, or a confirmed-safe pattern.

```powershell
Connect-MgGraph -Scopes "IdentityRiskyUser.ReadWrite.All"
Invoke-MgDismissRiskyUser -UserIds @('<ObjectId>')
```

Also consider adding the corporate egress IP range as a **Named Location** marked "trusted" to prevent recurrence:
Portal: Protection > Conditional Access > Named locations > add IP range > check "Mark as trusted location."

**Rollback:** Dismissal doesn't delete the detection record — it only clears the current risk state. No further action needed.

</details>

---
## Escalation Evidence

```
ENTRA ID PROTECTION ESCALATION
======================================
Date/Time                :
Tenant ID                 :
User UPN                  :
Risk Level                : (low / medium / high)
Risk State                : (atRisk / confirmedCompromised / remediated / dismissed)
Risk Event Type(s)        :
Detection Source          :
P2 License Assigned       : YES / NO
CA Policy Name Applied    :
CA Policy State           : (enabled / report-only / disabled)
Sign-in Result            : (success / failure / interrupted)
Actions Taken             : (password reset / session revoke / dismiss / license assign)
Steps Already Tried       :
```

---
## 🎓 Learning Pointers

- **Sign-in risk vs. user risk are different signals** — sign-in risk is evaluated per-session in real time (e.g., anonymized IP this specific login); user risk is an aggregate score built from unremediated sign-in risk over time. A CA policy can target either or both independently.
- **`leakedCredentials` is the highest-value alert type** — it means Microsoft found the user's actual password in a known breach dump. Treat it as a confirmed compromise, not a maybe — force reset immediately, don't wait for self-remediation.
- **Free tier still detects, but doesn't enforce** — every tenant gets some risk detections even without P2 (via Microsoft's baseline heuristics/Security Defaults), but the Conditional Access risk-based policies that automatically respond require Entra ID P2.
- **Dismissing ≠ deleting** — dismissing a risky user clears the active risk state for policy purposes but the detection history and audit trail remain for investigation.
- **MS Docs:** [What is Identity Protection](https://learn.microsoft.com/en-us/entra/id-protection/overview-identity-protection) | [Risk detections reference](https://learn.microsoft.com/en-us/entra/id-protection/concept-identity-protection-risks) | [Remediate risks](https://learn.microsoft.com/en-us/entra/id-protection/howto-identity-protection-remediate-unblock)
