# Conditional Access — Reference Runbook (Mode A: Deep Dive)
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

- **Environment:** Microsoft Entra ID (Azure AD) P1 or P2 licensing required for CA policies
- **Applies to:** Cloud-only, hybrid (Entra Connect synced), and B2B guest scenarios
- **Not covered:** ADFS-based claims rules, on-premises MFA Server, legacy auth deep-dive (see `Mail-Flow-A.md` for legacy auth in Exchange)
- **Assumed knowledge:** Basic understanding of OAuth 2.0 / OIDC token flows and MFA concepts

---
## How It Works

<details><summary>Full architecture</summary>

### The CA Evaluation Engine

Conditional Access is Microsoft's **policy enforcement plane** — it sits between identity (authentication) and resource access (authorisation). Every token request that touches a registered Entra ID application passes through CA evaluation.

**Flow:**

```
User → App (sign-in request)
         │
         ▼
   Entra ID STS
   ┌────────────────────────────────────────────────────┐
   │  1. AUTHENTICATION                                  │
   │     Username/password, FIDO2, WHfB, cert, etc.      │
   │                                                     │
   │  2. SESSION EVALUATION                              │
   │     Is there an existing valid session/PRT?         │
   │                                                     │
   │  3. CA POLICY EVALUATION  ◄── This is the engine   │
   │     For each enabled policy:                        │
   │       a. Does the user/group match? (Assignments)   │
   │       b. Does the app/workload match?               │
   │       c. Does the condition match?                  │
   │          (platform, location, device state, risk)   │
   │       d. What is the Grant control?                 │
   │          (block, require MFA, require compliant,    │
   │           require hybrid join, require ToU, etc.)   │
   │       e. What is the Session control?               │
   │          (sign-in frequency, persistent browser,    │
   │           app enforced restrictions, MCAS proxy)    │
   │                                                     │
   │  4. OUTCOME                                         │
   │     GRANT (possibly with control applied)           │
   │     BLOCK                                           │
   │     INTERRUPT (user must satisfy grant control)     │
   └────────────────────────────────────────────────────┘
         │
         ▼
   Access Token / Refresh Token issued (or denied)
```

### How Multiple Policies Interact

CA policies are **OR'd at the policy level, AND'd within a policy**:
- If ANY matching policy says **Block** → user is blocked regardless of other policies
- If multiple policies say **Require MFA** → user only needs to satisfy MFA once per session
- Grant controls within one policy are **AND'd** (require MFA AND require compliant device)
- The `Require one of the selected controls` option switches to OR within a policy

### Named Locations and IP Ranges

Named locations are evaluated against the `ipAddress` claim in the sign-in token. For compliant networks (corporate proxy/SASE), the IP the Entra STS sees is the egress IP of the proxy — not the end user's IP. If corporate IPs aren't registered as trusted named locations, MFA prompts will fire for on-site users.

### Device States and Trust

| Device State | How Achieved | CA Can Require |
|---|---|---|
| Hybrid Azure AD Joined | Entra Connect + domain join | `Require Hybrid Azure AD joined` |
| Entra ID Registered | User registers personal device | `Require registered or compliant device` |
| Entra ID Joined | Cloud-only join (Autopilot/OOBE) | Either of above |
| Intune Compliant | Compliant = Intune policy met | `Require compliant device` |

`Require compliant device` is the strictest. A hybrid-joined device is NOT automatically compliant — it must also be enrolled in Intune and pass all compliance policies.

### Risk-Based CA (P2 Only)

Identity Protection feeds real-time and aggregate risk signals into CA:
- **Sign-in risk**: anomalous session signals (atypical travel, anonymous IP, etc.)
- **User risk**: aggregate signals suggesting compromised credentials (leaked creds, etc.)

Risk levels: Low → Medium → High. CA policies can condition on risk level and require MFA or password change as remediation.

</details>

---
## Dependency Stack

```
Azure AD Premium P1/P2 Licensing
        │
        ▼
Entra ID Tenant
├── Users / Groups / Roles (assignment targets)
├── Applications (resource targets: All cloud apps, specific app IDs)
├── Named Locations (trusted IPs, countries)
└── Registered Devices (via Intune or manual registration)
        │
        ▼
CA Policy Engine (evaluated at every token request)
├── Policy Assignments (users, groups, workload identities, roles)
├── Conditions (platform, location, device state, sign-in risk, user risk, client apps)
├── Grant Controls (block / MFA / compliant device / hybrid join / ToU / custom)
└── Session Controls (sign-in freq / persistent browser / MCAS / app restrictions)
        │
        ▼
Token Issuance / Block / Interrupt
        │
        ▼
Resource Access (SharePoint, Exchange, Teams, Custom Apps, etc.)
        │
        ▼
(Optional) Microsoft Defender for Cloud Apps (MCAS) — proxy session monitoring
```

**External dependencies that affect CA:**
- **Identity Protection** (P2): feeds risk signals into risk-based policies
- **Intune**: device compliance state synced to Entra — latency up to 8h in some cases
- **Entra Connect**: hybrid join device state flows from on-prem AD; sync lag can cause "device not found" at CA evaluation time
- **Named Location configuration**: incorrect IP ranges cause location mis-classification
- **MFA registration**: users without MFA methods registered will be blocked by any "Require MFA" policy

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| User blocked: "You cannot access this from here" | Named location not configured, corporate IP not trusted | Sign-in log → CA tab → which policy blocked, Location field |
| MFA prompt loops / never satisfies | MFA not registered, or session cookie blocked by sign-in frequency policy | Check MFA registration; check sign-in frequency session control |
| "Device is not compliant" despite device passing Intune | Compliance state sync lag (Intune → Entra) or wrong device enrolled | `Get-IntuneDeviceStatus.ps1`; check device object in Entra portal |
| Block on modern app but not web browser | Legacy auth not covered by policy (client apps condition not set to all) | Sign-in log → Client app field; check if policy includes `Exchange ActiveSync` and `Other clients` |
| Guest user blocked accessing tenant | Guest not excluded from or correctly targeted by policy | Check Assignments → Include/Exclude → Guest or external users |
| Intermittent block for same user on same device | Sign-in frequency policy triggering re-auth; token not refreshing | Check Session Controls on matching policy → sign-in frequency value |
| New Autopilot device fails ESP during first boot | CA blocking Intune enrollment (Entra-only auth during OOBE) | Exclude `Microsoft Intune Enrollment` app from MFA/compliant device policies |
| SSPR (self-service password reset) blocked | Password change flow hitting a CA policy requiring compliant device | Exclude SSPR app or registration context from compliant device requirement |
| CA policy in Report-Only shows block but user gets through | Policy is in Report-Only mode — not enforced | Switch policy state to On when ready to enforce |

---
## Validation Steps

**Step 1 — Pull sign-in logs for blocked user**
```powershell
# Requires: Az.Identity or Microsoft.Graph module + at least Reports Reader role
Connect-MgGraph -Scopes "AuditLog.Read.All","Directory.Read.All"

$upn = "<user@domain.com>"
$signIns = Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn'" -Top 50 |
    Select-Object CreatedDateTime, AppDisplayName, ConditionalAccessStatus,
                  @{N="Status";E={$_.Status.ErrorCode}},
                  @{N="FailureReason";E={$_.Status.FailureReason}},
                  @{N="CAResult";E={$_.ConditionalAccessPolicies | ForEach-Object { "$($_.DisplayName): $($_.Result)" }}}
$signIns | Format-List
```

Expected (successful): `ConditionalAccessStatus = success`, all policy results = `success` or `notApplied`  
Bad: Any policy result = `failure` or `blocked`

**Step 2 — Identify device compliance state**
```powershell
$deviceName = "<DeviceName>"
$device = Get-MgDevice -Filter "displayName eq '$deviceName'" |
    Select-Object DisplayName, IsCompliant, TrustType, OperatingSystem, ApproximateLastSignInDateTime
$device
```
Expected: `IsCompliant = True`, `TrustType = ServerAd` (hybrid) or `AzureAd` (cloud join)  
Bad: `IsCompliant = False` or `IsCompliant = $null` (not enrolled in Intune)

**Step 3 — List all enabled CA policies and their assignments**
```powershell
Get-MgIdentityConditionalAccessPolicy -Filter "state eq 'enabled'" |
    Select-Object DisplayName, State,
                  @{N="IncludedUsers";E={$_.Conditions.Users.IncludeUsers}},
                  @{N="IncludedGroups";E={$_.Conditions.Users.IncludeGroups}},
                  @{N="ExcludedUsers";E={$_.Conditions.Users.ExcludeUsers}},
                  @{N="GrantControls";E={$_.GrantControls.BuiltInControls}} |
    Format-Table -AutoSize
```

**Step 4 — Check MFA registration status for a user**
```powershell
$upn = "<user@domain.com>"
Get-MgUserAuthenticationMethod -UserId $upn |
    Select-Object @{N="Method";E={$_.AdditionalProperties['@odata.type']}},
                  @{N="Id";E={$_.Id}} |
    Format-Table
```
Expected: At least one authenticator method registered (Microsoft Authenticator, phone, FIDO2).  
Bad: Empty list = user will be blocked by any "Require MFA" policy and cannot self-remediate.

**Step 5 — What If analysis (What would happen for a given user/app/condition)**
Use the **What If** tool in Entra portal:  
`portal.azure.com → Entra ID → Security → Conditional Access → What If`  
Input: User, App, IP/Location, Device platform, Client app. Output: which policies apply and what they require.  
(No PowerShell equivalent — portal-only tool as of 2026.)

---
## Troubleshooting Steps (by phase)

### Phase 1 — Scoping
1. Get the sign-in log entry (ideally the exact Correlation ID from the user's error screen)
2. Identify: which app, which policy, which condition matched, what grant was required
3. Confirm: is this policy intended to apply to this user/app/scenario?

### Phase 2 — Device State Issues
1. Check `IsCompliant` via Graph (Step 2 above)
2. If `False`: open Intune portal → Device → Compliance status tab → which policy is failing
3. If `null`: device is not Intune-enrolled — enrol it or exclude it from the CA policy
4. If compliant but CA still blocks: check if the Entra device object is the same one the user authenticated with (stale device objects can cause mismatch)

### Phase 3 — Location Issues
1. Check sign-in log → Location field
2. Compare against Named Locations in CA portal → is the corporate IP range listed?
3. If using proxy/SASE/VPN, the egress IP the STS sees will be the proxy's IP — make sure proxy egress IPs are in the trusted Named Location

### Phase 4 — MFA Registration Issues
1. Check methods registered (Step 4 above)
2. If no methods: admin must either register on behalf of the user (Temporary Access Pass) or exclude the user temporarily to let them self-register
3. Use Temporary Access Pass (TAP) for zero-touch MFA bootstrapping — valid for single sign-in

### Phase 5 — Legacy Auth
1. Check sign-in log → Client app = "Exchange ActiveSync clients" or "Other clients"
2. If legacy auth is hitting a policy that doesn't handle it: the policy's Client Apps condition may be missing `Other clients` and `Exchange ActiveSync`
3. To block legacy auth: create a separate policy targeting `Other clients` + `Exchange ActiveSync clients` with `Block` grant control

### Phase 6 — Service Account / Automation Blocked
1. Service accounts (used by scripts, scheduled tasks, Power Platform connectors) can't do MFA interactively
2. Solution: create a **Workload Identity** CA policy or exclude the service account from MFA policies and target it with an IP-based Named Location restriction instead
3. Prefer Managed Identities over service accounts where possible — they're excluded from user CA policies automatically

---
## Remediation Playbooks

<details><summary>Playbook 1 — Add corporate IP to Trusted Named Location</summary>

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

# Check existing named locations
Get-MgIdentityConditionalAccessNamedLocation | Select-Object DisplayName, Id, @{N="Type";E={$_.AdditionalProperties['@odata.type']}}

# Create new trusted IP named location
$params = @{
    "@odata.type" = "#microsoft.graph.ipNamedLocation"
    displayName   = "Corporate HQ - Trusted"
    isTrusted     = $true
    ipRanges      = @(
        @{
            "@odata.type" = "#microsoft.graph.iPv4CidrRange"
            cidrAddress   = "<x.x.x.x/24>"
        }
    )
}
New-MgIdentityConditionalAccessNamedLocation -BodyParameter $params
```

**After creation:** Update the relevant CA policy's Conditions → Locations to **Exclude** the new named location from MFA requirements.

**Rollback:** Delete the named location or remove it from the policy exclusion.
</details>

<details><summary>Playbook 2 — Exclude a user from all CA policies temporarily (emergency access)</summary>

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Directory.Read.All"

$upn = "<user@domain.com>"
$user = Get-MgUser -UserId $upn
$userId = $user.Id

# Get all enabled policies
$policies = Get-MgIdentityConditionalAccessPolicy -Filter "state eq 'enabled'"

foreach ($policy in $policies) {
    $currentExcludes = $policy.Conditions.Users.ExcludeUsers
    if ($userId -notin $currentExcludes) {
        $newExcludes = $currentExcludes + $userId
        $update = @{
            conditions = @{
                users = @{
                    excludeUsers = $newExcludes
                }
            }
        }
        Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -BodyParameter $update
        Write-Host "Excluded $upn from: $($policy.DisplayName)"
    }
}
```

⚠️ **This is a break-glass procedure.** Set a calendar reminder to re-add the user after the issue is resolved. Document why it was done.

**Rollback:** Remove user ID from ExcludeUsers in each policy.
</details>

<details><summary>Playbook 3 — Issue a Temporary Access Pass (TAP) for MFA bootstrap</summary>

```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.ReadWrite.All"

$upn = "<user@domain.com>"

# Create TAP valid for 1 hour, single-use
$tapParams = @{
    "@odata.type"     = "#microsoft.graph.temporaryAccessPassAuthenticationMethod"
    startDateTime     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    lifetimeInMinutes = 60
    isUsableOnce      = $true
}
$tap = New-MgUserAuthenticationTemporaryAccessPassMethod -UserId $upn -BodyParameter $tapParams

Write-Host "TAP for $upn : $($tap.TemporaryAccessPass)"
Write-Host "Valid until: $((Get-Date).AddMinutes(60))"
Write-Host "IMPORTANT: Deliver this securely to the user (not via email)."
```

**Rollback:** TAP expires automatically. Can be revoked with:
```powershell
Remove-MgUserAuthenticationTemporaryAccessPassMethod -UserId $upn -TemporaryAccessPassAuthenticationMethodId $tap.Id
```
</details>

<details><summary>Playbook 4 — Create a break-glass (emergency access) account exclusion</summary>

Best practice: maintain two break-glass accounts (cloud-only, Global Admin, no MFA, strong password in sealed vault) **explicitly excluded** from all CA policies.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Directory.Read.All"

# Get break-glass account UPNs
$breakGlassUpns = @("<breakglass1@domain.com>", "<breakglass2@domain.com>")
$bgIds = $breakGlassUpns | ForEach-Object { (Get-MgUser -UserId $_).Id }

$policies = Get-MgIdentityConditionalAccessPolicy
foreach ($policy in $policies) {
    $currentExcludes = $policy.Conditions.Users.ExcludeUsers
    $missingBg = $bgIds | Where-Object { $_ -notin $currentExcludes }
    if ($missingBg) {
        $newExcludes = $currentExcludes + $missingBg
        $update = @{
            conditions = @{
                users = @{
                    excludeUsers = $newExcludes
                }
            }
        }
        Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -BodyParameter $update
        Write-Host "Added break-glass exclusion to: $($policy.DisplayName)"
    }
}
```
</details>

---
## Evidence Pack

```powershell
# Run this to collect all CA-relevant data for escalation or audit
Connect-MgGraph -Scopes "AuditLog.Read.All","Policy.Read.All","Directory.Read.All"

$output = [ordered]@{}

# 1 — All enabled CA policies
$output["CA_Policies"] = Get-MgIdentityConditionalAccessPolicy -Filter "state eq 'enabled'" |
    Select-Object DisplayName, State, Id,
                  @{N="GrantControls";E={$_.GrantControls.BuiltInControls -join ", "}},
                  @{N="IncludeUsers";E={$_.Conditions.Users.IncludeUsers -join ", "}},
                  @{N="IncludeGroups";E={$_.Conditions.Users.IncludeGroups -join ", "}},
                  @{N="ExcludeUsers";E={$_.Conditions.Users.ExcludeUsers -join ", "}}

# 2 — Named locations
$output["Named_Locations"] = Get-MgIdentityConditionalAccessNamedLocation |
    Select-Object DisplayName, Id, @{N="Type";E={$_.AdditionalProperties['@odata.type']}}

# 3 — Recent failed sign-ins (last 100)
$output["Failed_SignIns"] = Get-MgAuditLogSignIn -Filter "status/errorCode ne 0" -Top 100 |
    Select-Object CreatedDateTime, UserPrincipalName, AppDisplayName,
                  @{N="ErrorCode";E={$_.Status.ErrorCode}},
                  @{N="FailureReason";E={$_.Status.FailureReason}},
                  @{N="Location";E={$_.Location.City + ", " + $_.Location.CountryOrRegion}},
                  ConditionalAccessStatus

# 4 — Export to CSV
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$output["CA_Policies"]    | Export-Csv "$env:TEMP\CA_Policies_$timestamp.csv" -NoTypeInformation
$output["Named_Locations"]| Export-Csv "$env:TEMP\CA_NamedLocations_$timestamp.csv" -NoTypeInformation
$output["Failed_SignIns"] | Export-Csv "$env:TEMP\CA_FailedSignIns_$timestamp.csv" -NoTypeInformation

Write-Host "Evidence collected to $env:TEMP\CA_*_$timestamp.csv"
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all enabled CA policies | `Get-MgIdentityConditionalAccessPolicy -Filter "state eq 'enabled'"` |
| Get sign-ins for user | `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<upn>'" -Top 50` |
| Get device compliance state | `Get-MgDevice -Filter "displayName eq '<name>'" \| Select IsCompliant, TrustType` |
| Check MFA methods registered | `Get-MgUserAuthenticationMethod -UserId <upn>` |
| Issue a TAP | `New-MgUserAuthenticationTemporaryAccessPassMethod -UserId <upn> -BodyParameter $tapParams` |
| List named locations | `Get-MgIdentityConditionalAccessNamedLocation` |
| Create named location | `New-MgIdentityConditionalAccessNamedLocation -BodyParameter $params` |
| Update CA policy | `Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId <id> -BodyParameter $update` |
| Get CA policy by name | `Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<name>'"` |
| Get user risk state | `Get-MgRiskyUser -Filter "userPrincipalName eq '<upn>'"` |
| Dismiss user risk | `Invoke-MgDismissRiskyUser -UserIds @("<userId>")` |
| List report-only policies | `Get-MgIdentityConditionalAccessPolicy -Filter "state eq 'enabledForReportingButNotEnforced'"` |
| Get auth methods policy | `Get-MgPolicyAuthenticationMethodPolicy` |
| Check SSPR registration | `Get-MgUserAuthenticationMethod -UserId <upn>` |

---
## 🎓 Learning Pointers

- **"All cloud apps" is not the same as "everything"**: Workload identities (service principals, managed identities) are excluded from user CA policies. They require separate **Workload Identity** CA policies (Entra ID P2). — [MS Docs: Workload identity CA](https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity)
- **CAPolicy evaluation is per-token, not per-session**: A user can have a valid browser session and still get blocked when a new app requests a token, because CA re-evaluates at each token issuance. Sign-in frequency policies control how often the *full auth + CA flow* is re-triggered. — [MS Docs: Sign-in frequency](https://learn.microsoft.com/en-us/entra/identity/conditional-access/howto-conditional-access-session-lifetime)
- **Intune compliance lag is a real escalation driver**: Compliance state is polled from Intune by Entra, not pushed. In large environments, freshly-compliant devices can take up to 8 hours to show as compliant at the CA layer. Engineers who don't know this will waste time re-running compliance policies. — [MS Docs: Device compliance](https://learn.microsoft.com/en-us/mem/intune/protect/device-compliance-get-started)
- **Report-Only mode is your deployment friend**: All new CA policies should start in Report-Only, analysed via the Sign-In Logs (filter by CA Result), then promoted to On. Skipping Report-Only is how organisations accidentally lock out users. — [MS Docs: Report-only mode](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-report-only)
- **Break-glass accounts must be excluded from every CA policy**: A single CA misconfiguration can lock out Global Admins. Two cloud-only break-glass accounts explicitly excluded from all policies is a Microsoft-recommended practice. Monitor their sign-in activity as an alert signal. — [MS Docs: Emergency access accounts](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/security-emergency-access)
- **The Correlation ID is your best friend**: Every blocked sign-in has a Correlation ID visible on the user's error screen. This maps directly to the Sign-In Log entry and CA evaluation detail. Train users to screenshot it.
