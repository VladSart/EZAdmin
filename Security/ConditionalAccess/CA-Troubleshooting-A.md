# Conditional Access Troubleshooting — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

This runbook covers Conditional Access (CA) policy evaluation failures in **Microsoft Entra ID** (formerly Azure AD), including:

- Sign-in blocked by CA policy (expected or unexpected)
- MFA prompt loops or MFA not being satisfied
- Compliant device / Hybrid Azure AD Join requirement failures
- Named location / IP range mismatches
- CA policy interaction with Entra ID Protection (risk-based policies)
- Service account and workload identity exclusions
- Cross-tenant access policy (B2B) CA evaluation

**Assumes:**
- Tenant has P1 or P2 licensing (CA requires at minimum P1)
- Engineer has **Security Reader** + **Global Reader** or higher in Entra ID
- Access to **Entra Sign-in Logs** (retained 30 days for P1/P2)
- PowerShell: `Microsoft.Graph` module installed

---

## How It Works

<details><summary>Full CA evaluation architecture</summary>

Conditional Access is enforced at the **Microsoft Identity Platform token issuance layer** — it is not a network firewall. CA policy is evaluated at **every token request**, including silent refresh.

### Evaluation Flow

```
User/Device authenticates →
  Entra ID collects signals:
    - User identity (UPN, group memberships, role assignments)
    - Device state (compliant, HAADJ, registered, unregistered)
    - Location (IP → Named Location lookup, GPS if MAM)
    - Application (app ID, cloud app, or All Cloud Apps)
    - Sign-in risk (Entra ID Protection real-time risk engine)
    - Client app type (browser, modern auth, legacy auth, EAS)
    - Authentication context (step-up auth for specific resources)
  ↓
  Policy engine evaluates ALL enabled CA policies:
    - Policies are evaluated in parallel (not sequential)
    - Most restrictive grant control wins (block > require)
    - Multiple grant controls combined with AND or OR logic
  ↓
  Token issued (with session controls applied) OR
  Access blocked (401/403 with error code)
```

### Key Concepts

**Policy evaluation is stateless per request.** A user who was compliant 1 hour ago may be blocked now if:
- Device compliance dropped in Intune
- A new CA policy was published
- Risk score elevated by Entra ID Protection
- IP location changed (split-tunnel VPN, CGNAT)

**Session tokens cache CA state.** Once a Persistent Browser Session (PBS) or Primary Refresh Token (PRT) is issued, the session controls (sign-in frequency, persistent browser) govern re-evaluation intervals. This is why users often report "it started failing out of nowhere" — the PRT expired and fresh evaluation blocked them.

**Grant controls vs. Session controls:**
- **Grant controls** — what must be true to get a token (MFA, compliant device, approved app)
- **Session controls** — what restrictions apply to the token (sign-in frequency, app-enforced restrictions, MCAS integration)

### Legacy Authentication

Legacy auth (Basic Auth, NTLM, Kerberos over O365) **bypasses modern CA entirely** because it does not go through the OAuth 2.0 / OIDC token flow. Block legacy auth policies use the `Other clients` condition. If users are on Outlook 2013 or earlier, or IMAP/POP clients, CA policy will not apply to them unless legacy auth is explicitly blocked.

</details>

---

## Dependency Stack

```
CA Policy Grant (Block / Allow)
        │
        ├── User identity
        │     ├── Group membership (dynamic/static)
        │     ├── Directory role assignment
        │     └── User risk score (Entra ID Protection)
        │
        ├── Device state
        │     ├── Intune compliance evaluation engine
        │     │     └── Compliance policy assigned to device/user
        │     ├── Hybrid Azure AD Join (dsregcmd /status)
        │     └── Device registration state in Entra ID
        │
        ├── Network location
        │     ├── Named Location definitions (IP ranges / countries)
        │     ├── IPv4 / IPv6 exact match (CIDR)
        │     └── MFA trusted IPs (legacy; superseded by Named Locations)
        │
        ├── Application context
        │     ├── Target app (cloud app ID or All Cloud Apps)
        │     ├── Authentication context (step-up)
        │     └── User action (register security info, join devices)
        │
        └── Client app type
              ├── Browser
              ├── Mobile apps and desktop clients (modern auth)
              ├── Exchange ActiveSync clients
              └── Other clients (legacy auth)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| AADSTS50076 — MFA required | CA requires MFA, user hasn't satisfied it | Sign-in logs → CA tab → which policy triggered |
| AADSTS53003 — Blocked by CA | Block grant control applied | Sign-in logs → CA tab → policy name |
| AADSTS50158 — External security challenge | MFA server challenge (ADFS, 3rd-party) | Check MFA provider config |
| AADSTS90072 — Guest account | Guest/B2B user hit policy not scoped for guests | CA policy include/exclude guest users |
| AADSTS700016 — App not found | App ID in CA policy is wrong or deleted | Verify app registration |
| Device compliance = N/A in CA | Device not Intune-enrolled or HAADJ | `dsregcmd /status`; check Intune enrollment |
| MFA loop (prompted repeatedly) | Session control: sign-in frequency set too low | Check session controls on matching policies |
| Policy applies despite IP exclusion | Incorrect CIDR, IPv6 not included, or NATed exit | Test `whatif` with exact IP; check IPv6 |
| User excluded but still blocked | Exclusion group not populated or sync delay | Check group membership in Entra, not just AD |
| Works in browser, fails in app | Modern vs. legacy auth mismatch | Check client app condition on CA policy |
| Service account blocked | SPN hit CA policy targeting All Users | Use workload identity CA policy instead |

---

## Validation Steps

### Step 1 — Reproduce and capture the error

```powershell
# From affected user's machine — capture the exact error code
# The error dialog will show: AADSTS<code> — copy this verbatim
# Example: AADSTS53003 means block policy applied
```

**Good:** User can clearly state the AADSTS error code shown
**Bad:** Only "access denied" with no code — check browser console or Entra sign-in logs

---

### Step 2 — Check Entra Sign-In Logs

```powershell
Connect-MgGraph -Scopes "AuditLog.Read.All", "Policy.Read.All"

# Get last 10 failed sign-ins for a user
$upn = "<UserUPN>"
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn' and status/errorCode ne 0" -Top 10 |
    Select-Object CreatedDateTime, AppDisplayName, IpAddress,
        @{n="ErrorCode";e={$_.Status.ErrorCode}},
        @{n="FailureReason";e={$_.Status.FailureReason}},
        @{n="CAApplied";e={$_.AppliedConditionalAccessPolicies.DisplayName -join "; "}}
```

**Good:** Log entry shows exactly which CA policy triggered, result = "failure"
**Bad:** No sign-in log entry — user may not be reaching Entra (DNS/network issue, or ADFS pre-auth)

---

### Step 3 — CA What-If analysis

In **Entra ID portal → Security → Conditional Access → What If**:
- Set User = affected user
- Set App = the application they can't access
- Set IP = their current IP
- Set Device platform + compliance state
- Run → observe which policies apply and what they require

```powershell
# PowerShell equivalent (read-only policy check)
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.State -eq "enabled" } |
    Select-Object DisplayName, State,
        @{n="Conditions";e={ $_.Conditions | ConvertTo-Json -Depth 3 -Compress }},
        @{n="GrantControls";e={ $_.GrantControls | ConvertTo-Json -Depth 3 -Compress }} |
    Format-List
```

**Good:** What-If shows exactly which policy blocks, and why
**Bad:** What-If shows "no policy applies" but user is still blocked — likely a legacy auth or token caching issue

---

### Step 4 — Verify device state

```powershell
# Run on the affected device (as the affected user)
dsregcmd /status

# Key fields to check:
# AzureAdJoined        : YES / NO
# DomainJoined         : YES / NO
# EnterpriseJoined     : YES / NO (Workplace join = registered)
# DeviceCompliant      : YES / NO
# IsDeviceCompliant    : YES / NO
# TokenRefreshMandatory: YES = PRT needs refresh
```

**Good:** `AzureAdJoined: YES` + `DeviceCompliant: YES` → device meets HAADJ/compliant requirement
**Bad:** `DeviceCompliant: NO` → check Intune compliance policy; `IsDeviceCompliant: NO` may lag by up to 8 hours

---

### Step 5 — Check group membership for exclusions

```powershell
Connect-MgGraph -Scopes "GroupMember.Read.All", "User.Read.All"

# Verify user is in CA exclusion group
$groupId = "<ExclusionGroupObjectId>"
$userId = "<UserObjectId>"

$member = Get-MgGroupMember -GroupId $groupId | Where-Object { $_.Id -eq $userId }
if ($member) { Write-Host "User IS in exclusion group" -ForegroundColor Green }
else          { Write-Host "User NOT in exclusion group" -ForegroundColor Red }
```

**Good:** User is in the group
**Bad:** User not in group, or in group but Entra sync lag — dynamic group membership may take 1-2 minutes to update

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify the blocking policy

1. Pull sign-in logs for the affected user (Step 2 above)
2. Find the log entry matching the failed attempt
3. Open the **Conditional Access** tab within that sign-in log entry
4. Note: Policy name, Result (success/failure/not applied), Grant control that failed

### Phase 2 — Determine why the grant control failed

**If MFA required but not satisfied:**
- Was user prompted for MFA? If yes → MFA method issue (see MFA troubleshooting)
- Was user NOT prompted? → Legacy auth path; check client app type in the log

**If compliant device required but not met:**
- Check `dsregcmd /status` on device
- Check Intune compliance status in Intune admin center
- Check if compliance policy is actually assigned to the user/device group

**If Hybrid Azure AD Join required but not met:**
- `dsregcmd /status` → `AzureAdJoined: NO` = device not registered
- Check if device is in AD and Entra Connect sync has run
- Check `EntraConnectHealth` for sync errors

**If location condition mismatch:**
- Get user's actual IP from sign-in log
- Compare against Named Location CIDR ranges
- Check IPv6 — many corporate networks now use IPv6 egress

**If policy should not apply (user in exclusion):**
- Verify exclusion group membership (Step 5)
- Check if it's a user exclusion vs. a group exclusion
- Check if there is a second policy without the exclusion

### Phase 3 — Confirm fix in What-If before changing production

Always run What-If **after** a proposed fix to confirm the expected outcome before applying it.

---

## Remediation Playbooks

<details><summary>Fix 1 — Add user to CA exclusion group (emergency break-glass)</summary>

**Use when:** User is locked out by a CA policy that should not apply to them.

```powershell
Connect-MgGraph -Scopes "GroupMember.ReadWrite.All"

$groupId    = "<ExclusionGroupObjectId>"
$userId     = "<UserObjectId>"

New-MgGroupMember -GroupId $groupId -DirectoryObjectId $userId
Write-Host "User added to exclusion group. Allow 1-2 min for evaluation." -ForegroundColor Green
```

**Rollback:**
```powershell
Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $userId
```

**Note:** This is a temporary fix. Root cause must be addressed (compliance, MFA registration, etc.).

</details>

<details><summary>Fix 2 — Force device compliance re-evaluation</summary>

**Use when:** Device should be compliant in Intune but CA still reports non-compliant.

```powershell
# Step 1 — Force Intune sync on device (run as affected user)
Start-Process "$env:ProgramFiles\Microsoft Intune Management Extension\agentexecutor.exe" -ArgumentList '-SyncDeviceConfig'

# Step 2 — Force PRT refresh (re-evaluates device state in token)
# Run as affected user:
dsregcmd /refreshprt

# Step 3 — Clear AAD token cache for the user (if above insufficient)
# Run as affected user:
dsregcmd /leave   # WARNING: Leaves Azure AD Join — only use if device is HAADJ
# Then re-join via: dsregcmd /join
```

**Rollback:** `dsregcmd /leave` + `dsregcmd /join` (re-registers device)

</details>

<details><summary>Fix 3 — Correct Named Location CIDR range</summary>

**Use when:** CA is blocking users coming from a corporate IP that should be trusted.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

# List all named locations
Get-MgIdentityConditionalAccessNamedLocation | Select-Object DisplayName, Id,
    @{n="Type";e={$_.AdditionalProperties['@odata.type']}},
    @{n="IPRanges";e={$_.AdditionalProperties['ipRanges'] | ConvertTo-Json -Compress}}

# Update an IP Named Location (add a new CIDR)
$locationId = "<NamedLocationObjectId>"
$body = @{
    "@odata.type" = "#microsoft.graph.ipNamedLocation"
    displayName = "Corporate Network"
    isTrusted = $true
    ipRanges = @(
        @{ "@odata.type" = "#microsoft.graph.iPv4CidrRange"; cidrAddress = "203.0.113.0/24" },
        @{ "@odata.type" = "#microsoft.graph.iPv6CidrRange"; cidrAddress = "2001:db8::/32" }
    )
}
Update-MgIdentityConditionalAccessNamedLocation -NamedLocationId $locationId -BodyParameter $body
```

**Rollback:** Re-run with original IP range values.

</details>

<details><summary>Fix 4 — Disable a CA policy (emergency, audit-logged)</summary>

**Use when:** A CA policy is causing widespread outage and needs to be disabled immediately.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$policyId = "<CAPolicyObjectId>"
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -State "disabled"
Write-Host "Policy disabled. Confirm in portal. Re-enable after investigation." -ForegroundColor Yellow
```

**Rollback:**
```powershell
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -State "enabled"
```

**⚠️ This is logged in the Entra Audit Log. Document the reason in your ticket immediately.**

</details>

<details><summary>Fix 5 — Enrol device for MFA / fix MFA registration loop</summary>

**Use when:** User is stuck in an MFA registration loop because "Register security info" is blocked by CA.

```powershell
# Check if a CA policy blocks "Register security info" user action
Get-MgIdentityConditionalAccessPolicy | Where-Object {
    $_.Conditions.Users.IncludeUsers -contains "All" -or
    $_.Conditions.Users.IncludeGroups.Count -gt 0
} | Where-Object {
    $_.Conditions.Applications.IncludeUserActions -contains "urn:user:registersecurityinfo"
} | Select-Object DisplayName, State
```

To resolve: temporarily add user to the exclusion group for the "Register security info" CA policy, have them register MFA at https://aka.ms/mfasetup, then remove from exclusion.

</details>

---

## Evidence Pack

Run this on any machine with the Graph module to collect CA diagnostics for a ticket:

```powershell
<#
.SYNOPSIS  Collect CA diagnostic evidence for a support ticket
.NOTES     Requires Security Reader role; outputs to CSV
#>
Connect-MgGraph -Scopes "AuditLog.Read.All","Policy.Read.All","Device.Read.All"

$upn       = Read-Host "Affected user UPN"
$outputDir = "$env:TEMP\CA-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $outputDir | Out-Null

# 1. Recent failed sign-ins (last 50)
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn' and status/errorCode ne 0" -Top 50 |
    Select-Object CreatedDateTime, AppDisplayName, IpAddress, Location,
        @{n="ErrorCode";e={$_.Status.ErrorCode}},
        @{n="FailureReason";e={$_.Status.FailureReason}},
        @{n="ClientAppUsed";e={$_.ClientAppUsed}},
        @{n="DeviceOS";e={$_.DeviceDetail.OperatingSystem}},
        @{n="DeviceCompliant";e={$_.DeviceDetail.IsCompliant}},
        @{n="IsManaged";e={$_.DeviceDetail.IsManaged}},
        @{n="CAApplied";e={($_.AppliedConditionalAccessPolicies | Where-Object {$_.Result -ne "notApplied"}).DisplayName -join "; "}} |
    Export-Csv "$outputDir\SignInLogs.csv" -NoTypeInformation

# 2. All enabled CA policies (structure only — no grant secret)
Get-MgIdentityConditionalAccessPolicy -Filter "state eq 'enabled'" |
    Select-Object DisplayName, Id, State,
        @{n="IncludeUsers";e={$_.Conditions.Users.IncludeUsers -join ","}},
        @{n="ExcludeUsers";e={$_.Conditions.Users.ExcludeUsers -join ","}},
        @{n="IncludeGroups";e={$_.Conditions.Users.IncludeGroups -join ","}},
        @{n="ExcludeGroups";e={$_.Conditions.Users.ExcludeGroups -join ","}},
        @{n="IncludeApps";e={$_.Conditions.Applications.IncludeApplications -join ","}},
        @{n="GrantControls";e={$_.GrantControls.BuiltInControls -join ","}} |
    Export-Csv "$outputDir\CAPolicies.csv" -NoTypeInformation

# 3. Named locations
Get-MgIdentityConditionalAccessNamedLocation |
    Select-Object DisplayName, Id,
        @{n="Type";e={$_.AdditionalProperties['@odata.type']}},
        @{n="IPRanges";e={$_.AdditionalProperties['ipRanges'] | ConvertTo-Json -Compress}} |
    Export-Csv "$outputDir\NamedLocations.csv" -NoTypeInformation

# 4. Device state for affected user (requires device lookup)
$user = Get-MgUser -UserId $upn
Get-MgUserRegisteredDevice -UserId $user.Id |
    Select-Object DisplayName, Id, OperatingSystem, TrustType,
        @{n="IsCompliant";e={$_.AdditionalProperties['isCompliant']}},
        @{n="IsManaged";e={$_.AdditionalProperties['isManaged']}} |
    Export-Csv "$outputDir\UserDevices.csv" -NoTypeInformation

Write-Host "`nEvidence collected to: $outputDir" -ForegroundColor Cyan
Invoke-Item $outputDir
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all enabled CA policies | `Get-MgIdentityConditionalAccessPolicy -Filter "state eq 'enabled'"` |
| Get sign-in failures for user | `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>' and status/errorCode ne 0" -Top 20` |
| Disable a CA policy | `Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId <Id> -State "disabled"` |
| Check device compliance | `dsregcmd /status` (on device, as user) |
| Force PRT refresh | `dsregcmd /refreshprt` |
| List Named Locations | `Get-MgIdentityConditionalAccessNamedLocation` |
| Add user to exclusion group | `New-MgGroupMember -GroupId <groupId> -DirectoryObjectId <userId>` |
| Check group membership | `Get-MgGroupMember -GroupId <groupId>` |
| List CA policies affecting an app | `Get-MgIdentityConditionalAccessPolicy \| Where-Object { $_.Conditions.Applications.IncludeApplications -contains "<AppId>" }` |
| Get authentication context list | `Get-MgIdentityConditionalAccessAuthenticationContextClassReference` |
| Force Intune sync | `Start-Process "$env:ProgramFiles\Microsoft Intune Management Extension\agentexecutor.exe" -Args '-SyncDeviceConfig'` |
| Check sign-in risk policies | `Get-MgIdentityConditionalAccessPolicy \| Where-Object { $_.Conditions.SignInRiskLevels.Count -gt 0 }` |

---

## 🎓 Learning Pointers

- **CA evaluation is parallel, not sequential.** All enabled policies are evaluated simultaneously. If two policies both apply, the most restrictive grant control wins. A block in any policy = blocked. See: [How CA policies work](https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview)

- **Sign-in frequency resets on MFA satisfaction.** If a CA policy sets sign-in frequency to 1 hour, the timer resets each time MFA is completed — not from last sign-in. Users re-authenticating frequently may have session controls misconfigured. See: [Session controls](https://learn.microsoft.com/en-us/entra/identity/conditional-access/howto-conditional-access-session-lifetime)

- **Device compliance in CA has an 8-hour lag by default.** Intune evaluates compliance on its own schedule. A device that just became non-compliant may still pass CA for up to 8 hours due to PRT caching. For immediate enforcement, use `dsregcmd /refreshprt`. See: [Compliance evaluation](https://learn.microsoft.com/en-us/mem/intune/protect/device-compliance-get-started)

- **What-If is your best diagnostic tool.** Before making any policy change, run What-If in Report-Only mode against the affected scenario. This prevents accidental lockouts and documents the expected behaviour. See: [CA What If tool](https://learn.microsoft.com/en-us/entra/identity/conditional-access/what-if-tool)

- **Named Locations must include IPv6.** Most enterprise networks now dual-stack. If a corporate IP exclusion isn't working, check whether the user's sign-in IP is IPv6 and whether your Named Location includes the IPv6 CIDR. See: [Named locations](https://learn.microsoft.com/en-us/entra/identity/conditional-access/location-condition)

- **Break-glass accounts must be excluded from ALL CA policies.** Emergency access accounts (break-glass) should be excluded at the user level — not via group — from every CA policy. Group exclusions can fail if there's a directory sync issue. See: [Emergency access accounts](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/security-emergency-access)
