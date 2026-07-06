# Continuous Access Evaluation (CAE) — Reference Runbook (Mode A: Deep Dive)
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

- **Scope:** Continuous Access Evaluation (CAE) architecture, the critical-event revocation model, strict location enforcement, and how CAE interacts with Conditional Access, Microsoft Graph, Exchange Online, SharePoint Online, and Teams.
- **Not covered:** Standard token lifetime configuration (Conditional Access Session > Sign-in frequency without CAE) — those are governed by separate token lifetime policies. Not a replacement for `PRT-Issues-A.md`, which covers device-bound PRT acquisition; CAE operates on access/refresh tokens issued to a session, independent of PRT health.
- **Applies to:** Any Entra ID tenant (CAE for supported workloads is enabled by default; no opt-in required for baseline critical-event revocation). Strict location enforcement requires explicit Conditional Access configuration.
- **Client requirement:** CAE requires clients built on MSAL (Microsoft Authentication Library) or equivalent CAE-aware token handling. Legacy/basic auth clients cannot participate.

---

## How It Works

<details><summary>Full architecture</summary>

### The problem CAE solves

Before CAE, an OAuth 2.0 access token issued to a client was valid for its full lifetime (historically ~60-90 minutes for Microsoft Graph/Exchange/SharePoint) regardless of what happened to the user or device in the meantime. If an admin disabled a compromised account, the attacker's already-issued access token kept working until natural expiry — potentially up to 90 minutes of continued access after the "fix" was applied.

CAE closes that window by introducing a **push-based revocation channel** between Entra ID and CAE-enabled resource providers, allowing near-real-time (typically under 5 minutes, often faster) session termination independent of the token's stated expiry.

### Two distinct CAE mechanisms

**1. Critical event revocation (default-on for supported workloads)**

Entra ID emits a signal to CAE-aware resource providers when specific high-confidence events occur:

```
Trigger events:
  - User account disabled or deleted
  - Password changed or reset (admin or self-service)
  - Multi-factor authentication method reset/re-registered
  - Admin explicitly revokes all refresh tokens for a user
  - Identity Protection detects high user risk or high sign-in risk

        │
        ▼
Entra ID pushes a "Shared Signals Framework" (SSF) style event/token
to the CAE-enabled resource provider (Exchange Online, SharePoint
Online, Teams, Microsoft Graph)
        │
        ▼
Resource provider invalidates the client's current access token
IMMEDIATELY at the resource, without waiting for token expiry
        │
        ▼
Client's next request fails with a 401 + a claims challenge
(WWW-Authenticate header containing a "claims" parameter)
        │
        ▼
CAE-aware client (MSAL-based) parses the claims challenge and
silently re-authenticates against Entra ID with the updated
requirements baked in
        │
        ▼
Entra ID re-evaluates current Conditional Access policy state
at the moment of re-auth (not the original sign-in time)
        │
        ├─ If the account is genuinely fine now → new token issued transparently
        └─ If truly blocked (disabled account, failed CA policy) → user is
           prompted to sign in again / blocked, matching current state
```

**2. Strict location enforcement (explicit opt-in via Conditional Access)**

This extends CAE to **network location changes mid-session**, not just identity/account events:

```
Conditional Access policy configured with:
  Session > Customize continuous access evaluation > Strict Location Enforcement

        │
        ▼
Client's network location is continuously reported to Entra ID
via the CAE signaling channel (for CAE-aware clients/resource combos)
        │
        ▼
If the client's network location no longer satisfies the CA
policy's Named Location requirement (e.g., moved from a trusted
corporate network to an unknown network)
        │
        ▼
Access token is revoked within minutes, independent of any
identity-level event — this is purely a network/location signal
```

### Why "near-real-time" and not "instant"

CAE relies on the resource provider's own polling/signal-processing cadence and network propagation. Microsoft documents this as typically taking effect within a few minutes, not instantaneously — worth setting correct expectations when explaining unexpected delay to a stakeholder during an incident response.

### CAE and claims challenges — the mechanism client apps must support

The revocation itself doesn't "log the user out" in a vacuum — it causes the **next API call** to the resource to fail with a structured claims challenge. A CAE-unaware client will just see a generic 401/403 and may show a confusing error instead of gracefully re-prompting. This is the single biggest source of "weird behavior" tickets: the client app, not Entra ID, is the broken link.

</details>

---

## Dependency Stack

```
┌──────────────────────────────────────────────────────┐
│  Identity Protection / Directory event stream         │
│  (password change, account disable, MFA reset,        │
│   risk detection, admin token revocation)              │
└───────────────────────┬────────────────────────────────┘
                        │
┌───────────────────────▼────────────────────────────────┐
│  Entra ID — CAE signal emission                        │
│  (Shared Signals Framework-style push to subscribers)   │
└───────────────────────┬────────────────────────────────┘
                        │
        ┌────────────────┼────────────────┬─────────────────┐
        ▼                ▼                ▼                 ▼
  Exchange Online   SharePoint Online   Teams          Microsoft Graph
  (CAE-aware)        (CAE-aware)       (CAE-aware)     (CAE-aware endpoints)
        │                │                │                 │
        └────────────────┴────────────────┴─────────────────┘
                        │
        ┌────────────────▼────────────────────────────────┐
        │  Client application (MUST be CAE-aware / MSAL)   │
        │  - Current Office apps, Teams client, Edge/Chrome │
        │  - Legacy/basic auth clients CANNOT participate   │
        └────────────────┬────────────────────────────────┘
                        │
        ┌────────────────▼────────────────────────────────┐
        │  Conditional Access — re-evaluated at claims      │
        │  challenge time, using CURRENT policy state        │
        │  (not the original sign-in's policy snapshot)       │
        └───────────────────────────────────────────────────┘

  [Strict Location Enforcement — additional, opt-in path]
        ┌───────────────────────────────────────────────────┐
        │  Network location signal (continuous)               │
        │  compared against Conditional Access Named Locations │
        └───────────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User signed out within minutes of an admin password reset | Expected critical-event revocation | Sign-in logs: CAE entry timestamp vs. audit log password reset timestamp |
| User signed out after connecting/disconnecting from VPN | Strict location enforcement triggered | CA policy Session settings for the relevant policy |
| Generic 401 error in a third-party or legacy app, user confused about "random" sign-out | Client doesn't support CAE claims challenge | Check "Client app" field in sign-in logs; confirm auth protocol (legacy vs modern) |
| Many users signed out simultaneously with no per-user account changes | Identity Protection bulk risk event, or a CA policy session-control change | Identity Protection > Risky sign-ins; CA policy modified date |
| Sign-out happens but Entra sign-in logs show no CAE-related entry at all | Not a CAE issue — likely standard token expiry or PRT problem | Cross-check `PRT-Issues-A.md`; check standard token lifetime config |
| CAE re-auth succeeds but user is prompted for MFA unexpectedly | Current CA policy now requires MFA due to changed risk/location state, differing from original sign-in | Compare CA policy conditions evaluated at re-auth vs. original sign-in in the log detail |
| Delay of several minutes (not instant) between the triggering event and enforcement | Expected — CAE is "near real-time," not synchronous | Confirm delay is within a few minutes; if much longer, check resource provider health |
| CAE strict location enforcement fires for users on a legitimate but unlisted network | Missing Named Location entry for a legitimate remote-work network | Conditional Access > Named locations — review scope and coverage |

---

## Validation Steps

**1. Confirm a CAE event in sign-in logs**
```
Entra admin center > Users > [user] > Sign-in logs
→ Look for entries with Status "Interrupted" or "Failure" where the
  "Continuous access evaluation" detail is present
→ Click into the entry, check the "Additional Details" / "Conditional Access" tabs
```
Good: A CAE entry with a clear reason code (e.g., token revoked due to password change).
Bad: No such entry despite the reported symptom — this is likely not CAE-related at all.

---

**2. Correlate against directory audit logs**
```
Entra admin center > Identity > Monitoring & health > Audit logs
→ Filter: Target = user, Date/time = ±15 min around the sign-in log CAE event
```
Good: A matching audit event (password reset, account disable, MFA reset, admin token revocation).
Bad: No correlating event — check for a network-location trigger (strict enforcement) instead, or investigate as a non-CAE issue.

---

**3. Confirm the resource provider is CAE-enabled for this workload**
```
Not directly queryable per-tenant via portal — CAE support is workload-dependent
and rolled out progressively by Microsoft (Exchange Online, SharePoint Online,
Teams, and Microsoft Graph are the primary supported workloads as of this writing).
```
Good: Symptom occurs on a known CAE-supported workload.
Bad: Symptom on a workload without CAE support — the "sign-out" is likely a different, unrelated issue (standard token expiry, app-specific session timeout).

---

**4. Check whether strict location enforcement is configured on the relevant policy**
```
Entra admin center > Protection > Conditional Access > [policy] > Session
→ Look for "Customize continuous access evaluation" and confirm whether
  "Strict Enforcement" is selected (vs. default)
```
Good: Clear visibility into whether this policy opts into network-location-based revocation.
Bad: Ambiguous ownership of which policy applies to the affected user/app combination — check "What If" tool.

---

**5. Test policy targeting with the Conditional Access "What If" tool**
```
Entra admin center > Protection > Conditional Access > Policies > What If
→ Input the affected user, target app, and (if relevant) network/location conditions
```
Good: Confirms exactly which policies apply and what session controls are in effect for this user/app/context combination.
Bad: Unexpected policy applying that wasn't accounted for — investigate policy scope/assignment.

---

**6. Confirm client CAE-awareness**
```
Sign-in logs > [event] > check "Client app" field
```
Good: Client is a current-version modern/MSAL-based app (Outlook, Teams, current browser with modern auth).
Bad: Legacy authentication protocol, ancient client version, or third-party app using an outdated auth library — CAE claims challenges will not be handled gracefully.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Establish whether this is genuinely a CAE event
1. Pull sign-in logs for the affected user/time window (Validation Step 1)
2. If no CAE-related entry exists, stop here and redirect to standard PRT/token troubleshooting
3. If found, note the exact reason/trigger shown in the log detail

### Phase 2 — Correlate trigger source
1. Check directory audit logs for identity-level triggers (Validation Step 2)
2. If no identity-level trigger, check Conditional Access strict location enforcement configuration (Validation Step 4)
3. Determine whether this was: (a) an identity/account critical event, (b) a network location change, or (c) a broader Identity Protection risk-driven revocation

### Phase 3 — Assess whether the trigger was expected/legitimate
1. If identity-level (password reset, account disable): confirm with the requesting admin this was intentional
2. If network-location driven: confirm the user's reported network at the time and cross-reference against Named Locations coverage
3. If Identity Protection risk-driven: review the specific risk detection details before taking any action — do not dismiss risk signals without investigation

### Phase 4 — Client-side verification
1. Confirm the client app in use is CAE-aware (Validation Step 6)
2. If not CAE-aware: this produces confusing generic errors by design — the fix is a client update, not a CAE/CA policy change
3. Test in a known-good, current client (e.g., latest Outlook or Edge) to isolate whether the issue is CAE behavior itself or client incompatibility

### Phase 5 — Policy scope review (for recurring false-positive patterns)
1. Use the "What If" tool to confirm exactly which Conditional Access policies and session controls apply to the affected user/app
2. If strict location enforcement is producing frequent legitimate false positives for a defined population (e.g., remote workers), review whether Named Locations coverage needs expansion, or whether strict enforcement scope should be narrowed to only the highest-sensitivity apps
3. Any policy change must go through whoever owns Conditional Access design for the tenant — CAE session controls are a security control, not a convenience setting

---

## Remediation Playbooks

<details><summary>Playbook 1 — Add a legitimate remote-work network to Named Locations</summary>

**Scenario:** Strict location enforcement is triggering for a known-good remote office or trusted network that isn't yet represented as a Named Location.

```
1. Confirm the network's public egress IP range with the affected user/site
   (do NOT add broad or dynamic residential ISP ranges — this defeats the purpose
   of location-based enforcement)

2. Entra admin center > Protection > Conditional Access > Named locations > + Countries location or + IP ranges location

3. Add the specific, static IP range for the legitimate site
   (e.g., a branch office's known static public IP)

4. Mark as "trusted location" only if appropriate for this network's actual security posture —
   do not mark home/residential networks as trusted merely to silence the alert

5. Validate: use the Conditional Access "What If" tool with the new location
   to confirm policy evaluation now passes as expected
```

**Rollback:** Remove the Named Location entry if it was added in error or the IP range was incorrect.

</details>

<details><summary>Playbook 2 — Scope strict enforcement narrower to reduce false positives</summary>

**Scenario:** Strict location enforcement is applied broadly and generating excessive legitimate-user friction; the security requirement doesn't actually need it applied that broadly.

```
1. Identify the specific policy applying strict CAE enforcement:
   Entra admin center > Protection > Conditional Access > [policy] > Session

2. Review the policy's current scope: which users/groups, which cloud apps

3. Discuss with the CA policy owner whether strict enforcement should be:
   - Scoped only to highly sensitive apps (not all cloud apps)
   - Scoped only to a higher-risk user population (e.g., admin roles)
     rather than the entire user base

4. Create or modify the policy to narrow scope accordingly — do NOT simply
   disable strict enforcement tenant-wide as a workaround

5. Test in Report-only mode first if available, review impact via
   Entra admin center > Protection > Conditional Access > Insights and reporting
   before enforcing broadly
```

**Rollback:** Revert scope changes to the previous group/app assignment if the narrower scope leaves an actual security gap.

</details>

<details><summary>Playbook 3 — Investigate and respond to a mass Identity Protection risk-driven revocation</summary>

**Scenario:** Many users were signed out simultaneously due to Identity Protection risk detections feeding CAE-driven revocation, not individual account actions.

```
1. Entra admin center > Protection > Identity Protection > Risky sign-ins / Risky users
   → Identify the specific risk detection type (e.g., leaked credentials, impossible travel,
     anomalous token, malicious IP)

2. For each affected user, review the individual risk detail before taking any
   remediation action — do not mass-dismiss

3. If risk detections are confirmed false positives (e.g., a legitimate travel
   pattern flagged as impossible travel):
   Entra admin center > Protection > Identity Protection > Risky users >
   select affected users > Dismiss user risk
   (only after individual review — this action should be deliberate, not routine)

4. If risk detections are confirmed legitimate (real credential compromise indicators):
   - Do NOT dismiss risk
   - Follow incident response procedure: force password reset, revoke sessions,
     review sign-in history for the compromised account(s) for further malicious activity
   - See `Security/ConditionalAccess/` and Identity Protection remediation policies
     for automated risk-based response configuration
```

**Rollback:** N/A — this is an investigative/response playbook, not a reversible configuration change.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects CAE-related sign-in and audit correlation evidence for a specific user.
.DESCRIPTION Pulls sign-in logs and directory audit logs for a target user within a time
             window, to help correlate a reported CAE-driven session interruption with its
             triggering event. Read-only.
.PARAMETER   UserPrincipalName - the affected user's UPN
.PARAMETER   WindowMinutes - minutes before/after the reported incident time to search (default 30)
.PARAMETER   IncidentTime - the approximate UTC timestamp of the reported issue
.NOTES       Requires: Microsoft.Graph.Authentication module,
             AuditLog.Read.All + Directory.Read.All scopes.
             Run: Connect-MgGraph -Scopes "AuditLog.Read.All","Directory.Read.All" first.
#>

param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [Parameter(Mandatory)][datetime]$IncidentTime,
    [int]$WindowMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$startTime = $IncidentTime.AddMinutes(-$WindowMinutes).ToUniversalTime().ToString("o")
$endTime   = $IncidentTime.AddMinutes($WindowMinutes).ToUniversalTime().ToString("o")

$outputDir = "$env:TEMP\CAE-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# 1. Sign-in logs for the user within the window
$signInUri = "https://graph.microsoft.com/v1.0/auditLogs/signIns?" +
    "`$filter=userPrincipalName eq '$UserPrincipalName' and createdDateTime ge $startTime and createdDateTime le $endTime" +
    "&`$orderby=createdDateTime desc"

$signIns = Invoke-MgGraphRequest -Method GET -Uri $signInUri -OutputType PSObject

$signIns.value | Select-Object createdDateTime, appDisplayName, clientAppUsed, status, conditionalAccessStatus,
    @{N='FailureReason';E={$_.status.failureReason}} |
    Export-Csv "$outputDir\sign-in-logs.csv" -NoTypeInformation

Write-Host "[OK] Sign-in logs exported: $($signIns.value.Count) entries"

# 2. Directory audit logs for the user within the window
$auditUri = "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?" +
    "`$filter=targetResources/any(t:t/userPrincipalName eq '$UserPrincipalName') and activityDateTime ge $startTime and activityDateTime le $endTime"

$auditLogs = Invoke-MgGraphRequest -Method GET -Uri $auditUri -OutputType PSObject

$auditLogs.value | Select-Object activityDateTime, activityDisplayName, category, result,
    @{N='InitiatedBy';E={$_.initiatedBy.user.userPrincipalName}} |
    Export-Csv "$outputDir\directory-audit-logs.csv" -NoTypeInformation

Write-Host "[OK] Directory audit logs exported: $($auditLogs.value.Count) entries"

# 3. Simple correlation summary
Write-Host "`n=== CORRELATION SUMMARY ===" -ForegroundColor Cyan
Write-Host "User: $UserPrincipalName"
Write-Host "Incident window: $startTime to $endTime"
Write-Host "Sign-in log entries found: $($signIns.value.Count)"
Write-Host "Audit log entries found:   $($auditLogs.value.Count)"
if ($auditLogs.value.Count -gt 0) {
    Write-Host "Likely trigger event(s):" -ForegroundColor Yellow
    $auditLogs.value | ForEach-Object { Write-Host "  - $($_.activityDateTime): $($_.activityDisplayName)" }
} else {
    Write-Host "No correlating audit event found — check Conditional Access strict location enforcement or Identity Protection risk detections instead." -ForegroundColor Yellow
}

Write-Host "`n[OK] Evidence collected to: $outputDir"
```

---

## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Check sign-in logs for CAE events | Entra admin center > Users > [user] > Sign-in logs |
| Check directory audit trail | Entra admin center > Identity > Monitoring & health > Audit logs |
| Test CA policy application for a user/app/context | Entra admin center > Protection > Conditional Access > What If |
| Check/configure strict location enforcement | Entra admin center > Protection > Conditional Access > [policy] > Session |
| Review Named Locations | Entra admin center > Protection > Conditional Access > Named locations |
| Review risk detections (multi-user impact) | Entra admin center > Protection > Identity Protection > Risky sign-ins / Risky users |
| Query sign-in logs via Graph | `GET /auditLogs/signIns?$filter=userPrincipalName eq '<upn>'` |
| Query audit logs via Graph | `GET /auditLogs/directoryAudits?$filter=targetResources/any(t:t/userPrincipalName eq '<upn>')` |
| Dismiss user risk (after individual review only) | Identity Protection > Risky users > select user(s) > Dismiss user risk |

---

## 🎓 Learning Pointers

- **CAE fundamentally changes the security model from "wait for token expiry" to "revoke on signal" — understanding this shift is the key to explaining unexpected sign-outs to non-technical stakeholders.** Before CAE, a compromised account's stolen token could remain valid for up to the token's full lifetime after remediation; CAE closes that gap to minutes. Frame incidents through this lens rather than treating every CAE sign-out as a bug report. [MS Docs: Continuous Access Evaluation overview](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-continuous-access-evaluation)

- **The claims challenge mechanism is the actual technical contract CAE depends on — and it's optional for client developers to implement well.** A CAE-unaware client doesn't "fail to support CAE" in an obvious way; it just shows a confusing generic error where an MSAL-aware client would silently re-authenticate. When troubleshooting "random" sign-outs in third-party or older apps, always check client CAE-awareness before assuming a policy misconfiguration. [MS Docs: Claims challenges, claims requests, and client capabilities](https://learn.microsoft.com/en-us/entra/identity-platform/claims-challenge)

- **Strict location enforcement is a meaningfully different risk/tradeoff decision than baseline critical-event revocation, and should be evaluated separately.** Baseline CAE (password change, account disable, risk detection) has essentially no legitimate-user downside — it only revokes access when something is actually wrong. Strict location enforcement can generate real friction for legitimate remote/hybrid workers whose network posture changes throughout the day, so it deserves narrower, more deliberate scoping. [MS Docs: Strict location enforcement](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-continuous-access-evaluation-strict-enforcement)

- **"Near real-time" is a deliberate phrase in Microsoft's documentation, not a guarantee of instant enforcement.** Expect propagation delay measured in minutes. When advising a stakeholder mid-incident (e.g., "we just disabled the compromised account, how fast is access actually cut off"), set expectations accordingly rather than promising instantaneous revocation.

- **Mass CAE-triggered sign-outs are a security signal before they're a support ticket.** When multiple users are affected simultaneously with no individual account action explaining it, always check Identity Protection risk detections first — this pattern is a common signature of automated threat response (e.g., a leaked credentials feed cross-referencing your tenant), not routine policy noise. Treat it with the same seriousness as any other security alert until ruled out. [MS Docs: Identity Protection risk detections](https://learn.microsoft.com/en-us/entra/id-protection/concept-identity-protection-risks)

- **CAE re-evaluates Conditional Access using the CURRENT policy state at the moment of the claims challenge, not the policy state at original sign-in.** This means a user re-authenticating mid-session can be held to different (typically newer/stricter) requirements than what applied when they first signed in — a subtlety worth knowing when explaining why a re-auth prompt suddenly asks for MFA that wasn't required earlier in the same session.
