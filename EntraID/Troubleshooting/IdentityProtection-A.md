# Entra ID Protection (Risky Users & Sign-Ins) — Reference Runbook (Mode A: Deep Dive)
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

---
## Scope & Assumptions

This runbook covers **Microsoft Entra ID Protection** — risk detection, risky users/sign-ins, and risk-based Conditional Access enforcement. It does not cover general Conditional Access design (see `Security/ConditionalAccess/CA-Design-A.md`) except where risk conditions intersect with it.

**Assumes:**
- Microsoft Graph PowerShell SDK installed
- Operator has Security Administrator, Security Operator, or Global Administrator
- Entra ID P2 license present for full risk-policy enforcement (P1/free tiers get limited detection only)

**What Identity Protection solves:**
Static credentials (passwords) are inherently phishable and reusable across breaches. Identity Protection uses Microsoft's global threat-intelligence signal set (billions of daily sign-ins across the Microsoft ecosystem) to score the *probability an authentication event is not the legitimate user*, and lets you gate access dynamically on that score — rather than applying the same static rules to every sign-in regardless of risk.

---
## How It Works

<details><summary>Full architecture</summary>

### Detection Types

| Category | Evaluated | Examples |
|----------|-----------|----------|
| **Real-time sign-in risk** | At the moment of authentication | Anonymous IP, unfamiliar sign-in properties, malware-linked IP, atypical travel (some are near-real-time) |
| **Offline sign-in risk** | After the sign-in, via batch analysis | Additional atypical travel refinement, malicious IP address correlated after the fact |
| **User risk (aggregate)** | Rolled up from unremediated sign-in risk + external signals | Leaked credentials (breach corpus matches), password spray campaigns, Microsoft Threat Intelligence Center reports |

### Detection Pipeline

```
Authentication attempt
        │
        ▼
Sign-in evaluated against:
  ├── Device/network reputation (IP intelligence feeds)
  ├── Behavioral baseline for this user (typical locations, devices, apps)
  ├── Token/session anomalies (replay, unusual client)
  └── Global threat intel (known bad infra, leaked creds databases)
        │
        ▼
Risk score assigned: none / low / medium / high
        │
        ▼
riskDetection object created (real-time or offline, per detection type)
        │
        ▼
Aggregated into:
  ├── signInRiskState  (per-session)
  └── userRiskState    (account-level, persists until remediated/dismissed)
        │
        ▼
Conditional Access evaluates risk conditions on THIS sign-in
        │
        ▼
Grant control applied: Allow / Require MFA / Require password change / Block
```

### Remediation Paths

| Path | Trigger | Effect |
|------|---------|--------|
| **Self-remediation** | CA policy grants access after MFA + secure password change | User clears their own risk state without admin involvement |
| **Admin remediation** | Admin resets password / revokes sessions via Graph or portal | Forces the account back to a known-good state |
| **Dismissal** | Admin confirms detection is a false positive | Clears risk state without password reset — detection record remains for audit |
| **Automatic aging out** | Some low-confidence detections decay if no corroborating signal appears | Rare; do not rely on this for actual incident response |

### Interaction With Conditional Access

Identity Protection does not enforce anything on its own — it only *classifies*. Enforcement is entirely delegated to Conditional Access policies with `signInRiskLevels` or `userRiskLevels` conditions. Two built-in Microsoft-managed policy templates exist (in the CA "Policy templates" gallery): "Require multifactor authentication for risky sign-ins" and "Require password change for high-risk users." Custom policies can combine risk conditions with other CA conditions (app, location, device platform).

### Data Retention & Investigation

- Risk detections and risky user records are retrievable via Graph (`riskDetections`, `riskyUsers`, `riskyUsersHistoryItem`) for the retention period tied to your license (typically 90 days rolling, longer with Microsoft Sentinel/Log Analytics export).
- For long-term retention and correlation, export sign-in/risk logs to a Log Analytics workspace or SIEM (Sentinel, Splunk via Graph/Event Hub).

### Interplay with Microsoft Defender for Cloud Apps (MDA / MDA session controls)

Risk signals from Identity Protection can feed into MDA conditional access app control (session-level controls like blocking downloads for risky sessions), creating a layered response beyond simple allow/block.

</details>

---
## Dependency Stack

```
Threat Intelligence Layer
    └── Microsoft global signal corpus (breach databases, malicious IP feeds, behavioral baselines)

License Layer
    └── Entra ID P2 (full risk-based CA enforcement)
            └── P1 / Free — limited detections, no risk-based CA policy enforcement
    └── (Optional) Microsoft Defender for Cloud Apps — session-level risk response

Detection Layer
    └── Identity Protection risk engine
            └── Real-time evaluation at sign-in
            └── Offline/batch evaluation post sign-in
            └── riskDetection objects created per event

State Layer
    └── signInRiskState (per session)
    └── userRiskState (aggregate, persists across sessions)

Policy Layer
    └── Conditional Access policy with risk conditions
            └── signInRiskLevels: low / medium / high
            └── userRiskLevels: low / medium / high
            └── Grant control: MFA / password change / block

Enforcement Layer
    └── Applied at token issuance for the specific sign-in
            └── Session/token respects the grant control decision

Remediation Layer
    └── Self-service (MFA + secure password change) OR
    └── Admin action (force reset, revoke sessions, dismiss)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| User permanently blocked, can't self-remediate | Policy grant control is "Block access" instead of "Require password change" | Review CA policy grant controls |
| Risk detected but no CA enforcement occurs | No P2 license, or no risk-based CA policy exists/targets the user | License + policy assignment check |
| Same user flagged repeatedly for travel | Legitimate frequent traveler; named location not configured | Add trusted named location, review real travel pattern |
| High volume of `passwordSpray` detections tenant-wide | Active credential-stuffing campaign against the tenant | Review Security > Identity Protection > Risk detections report, consider Smart Lockout tuning |
| `leakedCredentials` on a service account | Service account password reused elsewhere / present in a breach dump | Rotate credential immediately, review for hardcoded usage |
| Risk state stuck at `atRisk` despite password reset | Admin reset the password but never called `Invoke-MgDismissRiskyUser` or a session token wasn't revoked | Explicitly dismiss + revoke sessions |
| Sign-in risk high but MDA/CA don't seem to see it | Data propagation delay (a few minutes typical) or the app doesn't route through Entra CA (legacy auth / unsupported protocol) | Check `AppliedConditionalAccessPolicies` on the specific sign-in log entry |
| Break-glass account shows risk detections | Should be excluded from user-risk based policies to avoid lockout scenario | Confirm exclusion group membership on all risk-based CA policies |
| Users bypass MFA remediation prompt entirely | Legacy authentication protocol in use (IMAP/POP/SMTP basic auth) — doesn't support interactive claims challenge | Block legacy auth via separate CA policy |

---
## Validation Steps

**Step 1 — Confirm license and feature availability**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2|SPE_E5|M365_E5" } | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
```
*Good:* At least one P2-covering SKU present with available seats.

**Step 2 — Inventory active risk-based CA policies**
```powershell
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.Conditions.UserRiskLevels -or $_.Conditions.SignInRiskLevels } |
    Select-Object DisplayName, State, @{N='SignInRisk';E={$_.Conditions.SignInRiskLevels}}, @{N='UserRisk';E={$_.Conditions.UserRiskLevels}}
```
*Bad:* Empty result — no risk-based enforcement exists; detections are logged but nothing acts on them.

**Step 3 — Pull current risky users tenant-wide**
```powershell
Connect-MgGraph -Scopes "IdentityRiskyUser.Read.All"
Get-MgRiskyUser -All | Select-Object UserPrincipalName, RiskLevel, RiskState, RiskLastUpdatedDateTime | Sort-Object RiskLevel -Descending
```

**Step 4 — Check detection type distribution (spot campaigns)**
```powershell
Get-MgRiskDetection -All | Group-Object RiskEventType | Sort-Object Count -Descending | Select-Object Name, Count
```
A spike in `passwordSpray` or `maliciousIPAddress` across many distinct users indicates an active external campaign, not isolated user issues.

**Step 5 — Confirm break-glass exclusions**
```powershell
$bgGroupId = "<BreakGlassGroupObjectId>"
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.UserRiskLevels -or $_.Conditions.SignInRiskLevels } |
    ForEach-Object { [PSCustomObject]@{ Policy = $_.DisplayName; ExcludesBreakGlass = ($_.Conditions.Users.ExcludeGroups -contains $bgGroupId) } }
```
*Good:* `ExcludesBreakGlass: True` for every risk-based policy.

**Step 6 — Validate remediation actually clears state**
```powershell
Get-MgRiskyUserHistory -RiskyUserId '<ObjectId>' | Select-Object RiskLevel, RiskState, ActivityDateTime, InitiatedBy | Sort-Object ActivityDateTime -Descending
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Detection Not Firing As Expected

1. Confirm the risk event type is actually covered by your license tier — some detections (e.g., `anomalousToken`, `tokenIssuerAnomaly`) are P2-only.
2. Check the sign-in occurred through a path Entra CA actually evaluates — legacy authentication (basic auth IMAP/POP/SMTP) bypasses interactive risk remediation prompts entirely; block it separately.
3. Confirm the account isn't in scope of an exclusion group on the detection side (rare — most exclusions apply at the CA policy level, not detection level).

### Phase 2: Detection Firing But Not Enforced

1. Verify a CA policy with risk conditions is `enabled` (not `enabledForReportingButNotEnforced`).
2. Confirm the policy's user/group assignment includes the affected user (not scoped too narrowly).
3. Confirm the app/resource used is in scope of the policy — some legacy or third-party apps may be excluded from "All cloud apps" scoping by design.
4. Check for a competing "Allow" policy at higher precedence that overrides the risk block (Conditional Access policies are all evaluated together — the most restrictive applicable grant wins, but explicit "Grant access" with no controls on a broadly scoped policy can create confusion; audit for overlapping policies).

### Phase 3: Remediation Stuck

1. Confirm the grant control is "Require password change" (self-remediating) not "Block access" (admin-only remediation required).
2. Check the user has a working MFA method registered — self-remediation requires completing MFA as part of the flow.
3. If admin remediation: confirm both the password reset AND `Invoke-MgDismissRiskyUser` / session revoke were performed — a password reset alone does not always clear the `userRiskState` in the same operation depending on client caching.

### Phase 4: False Positive Storms

1. Identify the common pattern: same egress IP (corporate VPN/proxy change), same new legitimate location (branch office opening), or new client app rollout triggering "unfamiliar sign-in properties."
2. Add the IP range as a trusted Named Location.
3. If it's an app change (e.g., migrating to a new SSO client), consider a temporary report-only window on the relevant risk policy while baselining the new behavior — but do not leave it in report-only indefinitely.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full compromise response for a confirmed-compromised account</summary>

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","IdentityRiskyUser.ReadWrite.All","UserAuthenticationMethod.ReadWrite.All"

$upn = "<UPN>"
$user = Get-MgUser -Filter "userPrincipalName eq '$upn'"

# 1. Revoke all sessions and refresh tokens immediately
Revoke-MgUserSignInSession -UserId $user.Id

# 2. Force password reset
Update-MgUser -UserId $user.Id -PasswordProfile @{ ForceChangePasswordNextSignIn = $true }

# 3. Review and remove any suspicious MFA methods the attacker may have registered
Get-MgUserAuthenticationMethod -UserId $user.Id | Select-Object Id, AdditionalProperties

# 4. Review recent Inbox rules / mail forwarding (common post-compromise persistence)
# (Requires Exchange Online module)
# Get-InboxRule -Mailbox $upn | Where-Object { $_.ForwardTo -or $_.RedirectTo }

# 5. Dismiss the risk once remediation is complete and verified
Invoke-MgDismissRiskyUser -UserIds @($user.Id)
```

**Rollback:** N/A — this is incident containment, not a reversible change. Document every step in the security incident ticket.

</details>

<details><summary>Playbook 2 — Create a risk-based Conditional Access policy (sign-in risk → MFA)</summary>

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$params = @{
    displayName = "Require MFA for medium and high sign-in risk"
    state       = "enabledForReportingButNotEnforced"   # Validate before enforcing
    conditions  = @{
        users      = @{ includeUsers = @("All"); excludeGroups = @("<BreakGlassGroupId>") }
        applications = @{ includeApplications = @("All") }
        signInRiskLevels = @("medium", "high")
    }
    grantControls = @{
        operator        = "OR"
        builtInControls = @("mfa")
    }
}
New-MgIdentityConditionalAccessPolicy -BodyParameter $params
```

Run in report-only for 1-2 weeks, review impact in sign-in logs (`AppliedConditionalAccessPolicies` field), then flip `state` to `enabled`.

**Rollback:** Set `state` back to `enabledForReportingButNotEnforced` or `disabled` via `Update-MgIdentityConditionalAccessPolicy`.

</details>

<details><summary>Playbook 3 — Create a user-risk policy (high risk → require password change)</summary>

```powershell
$params = @{
    displayName = "Require secure password change for high user risk"
    state       = "enabledForReportingButNotEnforced"
    conditions  = @{
        users         = @{ includeUsers = @("All"); excludeGroups = @("<BreakGlassGroupId>") }
        applications  = @{ includeApplications = @("All") }
        userRiskLevels = @("high")
    }
    grantControls = @{
        operator        = "AND"
        builtInControls = @("mfa", "passwordChange")
    }
}
New-MgIdentityConditionalAccessPolicy -BodyParameter $params
```

⚠️ `passwordChange` control requires `mfa` also be present in the same policy — this is a Microsoft platform requirement, not optional.

</details>

<details><summary>Playbook 4 — Bulk review and triage of a risk detection spike</summary>

```powershell
# Pull last 24h of detections, group by type and affected user count
$since = (Get-Date).AddHours(-24).ToString("o")
$detections = Get-MgRiskDetection -Filter "detectedDateTime ge $since" -All

$detections | Group-Object RiskEventType | Sort-Object Count -Descending |
    Select-Object Name, Count

$detections | Group-Object UserPrincipalName | Where-Object { $_.Count -gt 3 } |
    Select-Object Name, Count | Sort-Object Count -Descending
```

Users appearing many times in a short window with `passwordSpray` or `maliciousIPAddress` detections are the priority triage list — check these accounts first for compromise indicators.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collect Identity Protection evidence for escalation or incident response
.DESCRIPTION Gathers risk state, detection history, applicable CA policies, license status,
             and recent sign-ins for a specified user.
.PARAMETER   UserUPN   UPN of the user to investigate
.EXAMPLE     .\Collect-IdentityProtectionEvidence.ps1 -UserUPN "user@contoso.com"
#>
param(
    [Parameter(Mandatory)][string]$UserUPN
)

Connect-MgGraph -Scopes "IdentityRiskyUser.Read.All","AuditLog.Read.All","User.Read.All","Policy.Read.All"

$user = Get-MgUser -Filter "userPrincipalName eq '$UserUPN'" -Property Id,DisplayName,UserPrincipalName,AccountEnabled
if (-not $user) { Write-Error "User not found: $UserUPN"; exit 1 }

Write-Host "`n=== USER ===" -ForegroundColor Cyan
$user | Format-List DisplayName, UserPrincipalName, Id, AccountEnabled

Write-Host "`n=== CURRENT RISK STATE ===" -ForegroundColor Cyan
Get-MgRiskyUser -Filter "userPrincipalName eq '$UserUPN'" | Format-List

Write-Host "`n=== RISK HISTORY ===" -ForegroundColor Cyan
Get-MgRiskyUserHistory -RiskyUserId $user.Id | Select-Object RiskLevel, RiskState, ActivityDateTime, InitiatedBy | Format-Table

Write-Host "`n=== RECENT DETECTIONS ===" -ForegroundColor Cyan
Get-MgRiskDetection -Filter "userPrincipalName eq '$UserUPN'" -Top 20 |
    Select-Object DetectedDateTime, RiskEventType, RiskLevel, RiskState, Source | Format-Table

Write-Host "`n=== RECENT SIGN-INS ===" -ForegroundColor Cyan
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UserUPN'" -Top 10 |
    Select-Object CreatedDateTime, RiskLevelDuringSignIn, RiskState, Location, IpAddress, ConditionalAccessStatus | Format-Table

Write-Host "`n=== LICENSE ===" -ForegroundColor Cyan
Get-MgUserLicenseDetail -UserId $user.Id | Select-Object SkuPartNumber | Format-Table

Write-Host "`n=== APPLICABLE RISK-BASED CA POLICIES ===" -ForegroundColor Cyan
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.UserRiskLevels -or $_.Conditions.SignInRiskLevels } |
    Select-Object DisplayName, State | Format-Table
```

---
## Command Cheat Sheet

```powershell
# Connect with Identity Protection scopes
Connect-MgGraph -Scopes "IdentityRiskyUser.ReadWrite.All","IdentityRiskEvent.Read.All","Policy.ReadWrite.ConditionalAccess"

# List all currently risky users
Get-MgRiskyUser -All | Where-Object { $_.RiskState -ne "dismissed" } | Select-Object UserPrincipalName, RiskLevel, RiskState

# List all risk detections in the last 7 days
$since = (Get-Date).AddDays(-7).ToString("o")
Get-MgRiskDetection -Filter "detectedDateTime ge $since" -All

# Dismiss risk for one or more users
Invoke-MgDismissRiskyUser -UserIds @('<ObjectId1>','<ObjectId2>')

# Confirm one or more users as compromised (marks risk as real, does not auto-remediate)
Invoke-MgConfirmRiskyUserCompromised -UserIds @('<ObjectId>')

# Force password reset + revoke sessions
Update-MgUser -UserId '<ObjectId>' -PasswordProfile @{ ForceChangePasswordNextSignIn = $true }
Revoke-MgUserSignInSession -UserId '<ObjectId>'

# List all risk-based CA policies
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.UserRiskLevels -or $_.Conditions.SignInRiskLevels }

# Get sign-in log with full CA evaluation detail for one event
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 1 | Select-Object -ExpandProperty AppliedConditionalAccessPolicies

# Check named locations (for trusted IP tuning)
Get-MgIdentityConditionalAccessNamedLocation | Select-Object DisplayName, Id
```

---
## 🎓 Learning Pointers

- **Risk is a probability score, not a fact** — "high risk" means Microsoft's models assign high confidence this isn't the legitimate user, based on billions of correlated signals. Treat `leakedCredentials` and `passwordSpray` as near-certain; treat `unfamiliarFeatures` as needing more context (could just be a new laptop).
- **Enforcement is entirely delegated to Conditional Access** — Identity Protection alone will happily log risk forever without doing anything, if no CA policy consumes the risk condition. Detection and enforcement are separate products working together.
- **Break-glass accounts must be excluded from risk-based policies** — a false positive on a break-glass account during an actual outage is how organizations lock themselves out during the exact moment they need emergency access. Exclude proactively, don't wait for an incident to discover the gap.
- **Report-only mode is not optional for new policies** — deploy every new risk-based CA policy in `enabledForReportingButNotEnforced` first, review the sign-in logs for a representative period, then enforce. Skipping this step is the most common cause of unplanned lockouts.
- **Legacy authentication is invisible to risk remediation** — protocols like IMAP/POP/SMTP AUTH can't present an interactive MFA/password-change challenge. If legacy auth isn't blocked separately, a compromised account can keep authenticating through it even after Identity Protection flags the risk.
- **MS Docs:** [Identity Protection overview](https://learn.microsoft.com/en-us/entra/id-protection/overview-identity-protection) | [Risk-based CA policies](https://learn.microsoft.com/en-us/entra/id-protection/howto-identity-protection-configure-risk-policies) | [Investigate risk](https://learn.microsoft.com/en-us/entra/id-protection/howto-identity-protection-investigate-risk)
