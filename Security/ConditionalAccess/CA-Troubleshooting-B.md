# Conditional Access — Hotfix Runbook (Mode B: Ops)

> CA is blocking a user or an app. Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis Flow](#diagnosis--validation-flow)
- [Fix Paths](#common-fix-paths)
- [CA Policy Patterns That Commonly Break Things](#ca-patterns-that-commonly-break-things)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

```
Step 1: Get the exact error message the user sees
  - "You can't get there from here" → device not meeting CA requirement
  - "Your sign-in was blocked" → CA block policy matched
  - "Additional verification required" → MFA required, not enrolled
  - "This device doesn't meet compliance requirements" → Intune compliance
  - "Your administrator has disabled this app" → App blocked

Step 2: Get the sign-in log entry
  Entra Portal → Sign-in logs → Filter by user + time
  Find the failed sign-in → Click it → "Conditional Access" tab
  → Shows EVERY policy evaluated and result (Success/Failure/Not applied)
  → The one showing "Failure" is your culprit
```

```powershell
# Get CA failure via Graph (faster than portal for bulk)
Connect-MgGraph -Scopes "AuditLog.Read.All"

Get-MgAuditLogSignIn `
  -Filter "userPrincipalName eq '<UPN>' and conditionalAccessStatus eq 'failure'" `
  -Top 5 |
  Select-Object CreatedDateTime, AppDisplayName, ConditionalAccessStatus,
    @{N="CA Policies";E={$_.AppliedConditionalAccessPolicies | Select-Object DisplayName,Result}} |
  Format-List
```

**Interpret:**
| Sign-in log result | Meaning |
|-------------------|---------|
| Block | A policy explicitly blocked the sign-in |
| Failed controls (MFA) | MFA required but not completed |
| Failed controls (Compliant device) | Device not compliant in Intune |
| Failed controls (Hybrid join) | Device not hybrid joined — or PRT stale |
| Not applied / Success on all | CA is NOT the problem — look elsewhere |

---

## Dependency Cascade

<details><summary>What CA evaluates — in order</summary>

```
1. Is this user/group in the policy scope?
2. Is this app (cloud app) in scope?
3. Does the sign-in platform match? (Windows, iOS, etc.)
4. Does the location match? (Named location, country)
5. Is this a legacy auth client? (SMTP, POP, IMAP, older Office)
6. What is the device state? (Compliant / Hybrid joined / Entra joined)
7. What is the sign-in risk? (requires Identity Protection P2)

If ALL conditions match → apply the grant/block controls.
ALL matching policies must be satisfied simultaneously.
BLOCK always wins over any Grant control.
```

**Key:** CA failure in sign-in logs shows which control failed, not why the underlying thing (compliance, device state) is in that state. Always follow the chain:
- `Compliant: No` → go to Intune
- `Hybrid join: No` → go to Entra ID / Entra Connect
- `MFA: not satisfied` → user hasn't set up MFA or is in wrong location

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify the exact policy blocking access**

```powershell
# Get sign-in log entry for the user
$signIn = Get-MgAuditLogSignIn `
  -Filter "userPrincipalName eq '<UPN>'" `
  -Top 20 |
  Where-Object { $_.ConditionalAccessStatus -eq "failure" } |
  Select-Object -First 1

# Show CA evaluation results
$signIn.AppliedConditionalAccessPolicies |
  Select DisplayName, Result, GrantControlsNotSatisfied | Format-Table
```

**Step 2 — Check the device state (if device compliance is the blocker)**

```powershell
# On the device
dsregcmd /status
# Check: AzureAdJoined, DomainJoined, AzureAdPrt, ComplianceState

# In Intune portal
# Devices → find device → Overview
# Check: Compliance state, Last check-in time

# Via Graph
Get-MgDeviceManagementManagedDevice `
  -Filter "userPrincipalName eq '<UPN>'" |
  Select DeviceName, ComplianceState, LastSyncDateTime, ManagementState
```

**Step 3 — Check if user is in break-glass exclusion (if emergency)**

```
Entra Portal → Security → Conditional Access
Find the blocking policy
Edit → Users → Exclusions
Check: is there a break-glass group? Add user temporarily if urgent.
```

**Step 4 — Validate with What If tool**

```
Entra Portal → Security → Conditional Access → What If
Input: User, App, IP, Device state
Output: Exact policies that would apply and result
Use this BEFORE making CA changes to predict impact
```

---

## Common Fix Paths

<details><summary>Fix 1 — Device not compliant (blocking CA)</summary>

```powershell
# Force Intune sync to pick up latest compliance status
# Option A: On device
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" `
  -TaskName "Schedule #1 created by enrollment client" -ErrorAction SilentlyContinue

# Option B: Via Graph
Invoke-MgDeviceManagementManagedDeviceSyncDevice -ManagedDeviceId "<deviceId>"

# Check what's making it non-compliant
Get-MgDeviceManagementManagedDeviceComplianceActionItems -ManagedDeviceId "<deviceId>"
# Or in portal: Devices → device → Device compliance → which policy is failing?
```

If compliance policy is the actual problem (e.g. requires BitLocker but BitLocker isn't configured):
→ Fix the underlying compliance requirement
→ Wait up to 15 minutes for compliance state to update
→ User may need to sign out and back in after compliance state changes

</details>

<details><summary>Fix 2 — User locked out — emergency exclusion</summary>

> Use only when business is impacted. Always revert after resolving root cause.

```
Entra Portal → Security → Conditional Access
1. Open the blocking policy
2. Edit → Users → Exclusions
3. Add the specific user or their group
4. Save
5. Have user retry sign-in (no cache flush needed — immediate)
6. Document: who, when, why, ticket number
7. Plan: fix root cause within 24h, remove exclusion
```

> ⚠️ Never exclude entire groups permanently. Each exclusion is a security gap.

</details>

<details><summary>Fix 3 — Legacy auth being blocked</summary>

**Symptoms:** Outlook desktop (old), SMTP relay, PowerShell via Basic Auth suddenly fails after CA policy change

```powershell
# Identify legacy auth sign-ins
Get-MgAuditLogSignIn `
  -Filter "clientAppUsed ne 'Browser' and clientAppUsed ne 'Mobile Apps and Desktop clients'" `
  -Top 50 |
  Select UserPrincipalName, ClientAppUsed, AppDisplayName, CreatedDateTime |
  Format-Table
```

Options:
1. **Modern auth route** — migrate the app/client to use modern auth (MSAL/OAuth2)
2. **Temporary exclusion** — exclude the service account or legacy app user from the CA policy
3. **Named location exemption** — if legacy app comes from a known IP, exclude that named location

</details>

<details><summary>Fix 4 — New policy rolled out, unexpected impact</summary>

```
Quick mitigation: put new policy in "Report-only" mode
Entra Portal → CA Policy → Edit → Enable policy = "Report only"
This stops enforcement but still logs what WOULD have happened

Analyse with sign-in logs in report-only mode:
Get-MgAuditLogSignIn ... → check "reportOnlyPolicies" in output

Then adjust conditions/exclusions before switching back to Enabled
```

</details>

<details><summary>Fix 5 — MFA not satisfying CA requirement</summary>

Common scenario: CA requires MFA, user completed MFA, but still blocked.

Causes:
- **Claim mismatch** — MFA was completed in a different auth context (different app, different token)
- **Auth methods** — CA may require "Authentication strength" (specific MFA method), not just any MFA
- **PRT stale** — device has old token without MFA claim, needs fresh sign-in

```
Fix: Have user sign out completely (all accounts in Windows Settings or browser)
     Sign back in → complete MFA fresh → CA should pass
     
If still failing: Check if policy has "Authentication strength" set to Phishing-resistant
  → Requires FIDO2/WHfB, not TOTP/push notification
```

</details>

---

## CA Patterns That Commonly Break Things

| Pattern | What goes wrong | Prevention |
|---------|----------------|------------|
| Require compliant device for All Users | New devices / BYOD blocked on day 1 | Exclude "Device registration" app or grace period |
| Block legacy auth broadly | SMTP relay for print/scan breaks | Exclude service account IPs first |
| Require Hybrid join AND compliant device | Hybrid join takes time; newly joined devices blocked | Use OR not AND; add grace period |
| CA change without What If testing | Unexpected lockouts | Always run What If before enabling |
| No break-glass accounts | Admin locked out of Entra | Always have 2 break-glass accounts excluded from all CA |
| Sign-in frequency set too short | Users constantly re-auth disrupts work | Don't set < 1 hour for typical users |

---

## Escalation Evidence

```
Conditional Access Blocking — Evidence Pack
============================================
Affected user UPN:        
App being accessed:       
Error message user sees:  
Time of failure:          
Policy name blocking:     [from sign-in log CA tab]
Controls not satisfied:   [MFA / Compliant device / Hybrid join]
Device name + join type:  [dsregcmd /status output]
Intune compliance state:  [Compliant / Non-compliant / reason]
Sign-in log export:       [Attach CSV from Entra portal if escalating]
What If tool result:      [Paste output]
Break-glass triggered:    [Yes/No]
Recent CA changes:        [Who changed what, when — from Audit logs]
```

---

## 🎓 Learning Pointers

- **The What If tool is underused** — every CA change should be run through What If before enabling. It shows exactly which policies fire for a given user/app/device combination. Prevents most CA lockout incidents. [Entra: What If](https://learn.microsoft.com/en-us/entra/identity/conditional-access/troubleshoot-conditional-access-what-if)
- **Report-only mode** — CA can run in report-only for weeks without impacting anyone. Use it to baseline every new policy and understand real-world impact before enforcing. This is the professional way to roll out CA changes.
- **Authentication strength vs MFA requirement** — there are two ways to require MFA in CA: the older "require multifactor authentication" (any registered method) and the newer "authentication strength" (specifies exact methods like phishing-resistant). Knowing the difference matters when clients want FIDO2-only access.
- **PRT and CA interaction** — the Primary Refresh Token carries claims about how the user authenticated (MFA claim, device join claim). CA validates these claims, not just the sign-in event. If the PRT was obtained without MFA, CA may challenge even if user completed MFA earlier. Deep read: [MS Identity tokens and claims](https://learn.microsoft.com/en-us/entra/identity-platform/access-tokens)
- **Break-glass accounts** — every organisation needs exactly 2 emergency admin accounts completely excluded from all CA policies, not associated with any person, with 50+ character random passwords stored in a physical safe or vault. Search "break glass account Entra ID best practices" — Microsoft has a specific doc on this.
