# Self-Service Password Reset (SSPR) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Entra ID Self-Service Password Reset (SSPR)** in hybrid and cloud-only environments. It applies to:

- **Cloud-only SSPR** — password is changed directly in Entra ID; no on-premises writeback required.
- **Hybrid SSPR with Password Writeback** — password is changed in Entra ID and written back to on-premises AD via Entra Connect (formerly Azure AD Connect).
- **SSPR combined registration** — users register both MFA methods and SSPR methods through `https://aka.ms/mysecurityinfo`.

**Not in scope:** SSPR via Azure AD B2C, ADFS-only flows, or legacy per-user MFA (SSPR requires combined registration or separate SSPR registration portal).

**Licensing requirements:**
- **Cloud-only users:** Entra ID P1 or P2 (or Microsoft 365 Business Premium, EMS E3/E5)
- **Hybrid users with Password Writeback:** Entra ID P1 or P2 minimum
- No license is required for **Entra ID Free** tenants — but SSPR is then limited to admins only (6-method admin reset policy)

---

## How It Works

<details><summary>Full SSPR architecture</summary>

### Cloud-Only SSPR Flow

```
User visits https://aka.ms/sspr
       │
       ▼
Entra ID authenticates user identity (username only — not password)
       │
       ▼
SSPR Policy evaluated:
  - Is user in scope? (All users / Selected group / None)
  - How many auth methods required? (1 or 2)
  - Which methods are enabled? (email, mobile app code, SMS, security questions, etc.)
       │
       ▼
User completes required auth method challenges
       │
       ▼
Entra ID validates challenges against registered methods
       │
       ▼
Password reset accepted → Entra ID updates password hash
       │
       ▼
Password Hash Sync (PHS) pushes new hash to on-prem AD (if hybrid + PHS enabled)
```

### Hybrid SSPR with Password Writeback Flow

```
User completes SSPR challenge (same as above)
       │
       ▼
Entra ID generates a reset request
       │
       ▼
Request transmitted via Azure Service Bus (encrypted, outbound TCP 443)
to Entra Connect agent on-premises
       │
       ▼
Entra Connect validates:
  - Is Password Writeback feature enabled?
  - Does connector account have "Reset password" permission on user in AD?
  - Is the account subject to Fine-Grained Password Policy that blocks reset?
       │
       ▼
Entra Connect writes new password to on-premises AD
       │
       ▼
Password Hash Sync picks up the new hash and syncs back to cloud
       │
       ▼
User can sign in to both cloud and on-prem resources
```

### SSPR Registration Portal

Users must pre-register at least one (or two, depending on policy) auth methods before SSPR works. Registration happens at:
- `https://aka.ms/mysecurityinfo` (combined registration — recommended)
- `https://aka.ms/ssprsetup` (legacy SSPR-only registration — being deprecated)

Combined registration requires that **Combined registration preview** is enabled in Entra ID > User settings > Manage user feature settings.

### Authentication Methods Available for SSPR

| Method | Notes |
|--------|-------|
| Microsoft Authenticator app notification | Requires app registration |
| Microsoft Authenticator app OATH code | 6-digit TOTP |
| SMS | Phone number must be mobile, not VoIP |
| Email (not primary UPN) | Alternate email address |
| Security questions | Min 3 required; only for non-admin accounts |
| Office phone | Requires tenant to have phone auth plan |
| Mobile app code (3rd party TOTP) | Supported via combined registration |

**Important:** Security questions are NOT available for admin accounts — this is a deliberate Microsoft policy.

</details>

---

## Dependency Stack

```
User SSPR Reset (cloud)
  └── Entra ID SSPR Policy
        ├── User in scope (All / Group / None)
        ├── Auth methods registered (mysecurityinfo)
        ├── Number of methods required (1 or 2)
        └── License assigned (P1/P2 or equivalent)

User SSPR Reset (hybrid — Password Writeback)
  └── Entra ID SSPR Policy (above)
        └── Password Writeback feature enabled in Entra Connect
              └── Entra Connect service running on-prem
                    ├── Outbound TCP 443 → *.servicebus.windows.net
                    ├── Connector account permissions:
                    │     ├── Reset password (on user OU)
                    │     ├── Write lockoutTime attribute
                    │     └── Write pwdLastSet attribute
                    └── Target user not blocked by:
                          ├── Fine-Grained Password Policy (min age > 0)
                          ├── Protected Users security group
                          └── Account restrictions (cannot change password)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "SSPR is not enabled for your account" | User not in SSPR scope group, or SSPR set to "None" | Entra ID > Password reset > Properties |
| "You don't have enough auth methods registered" | User hasn't completed SSPR registration | `Get-MgUser -UserId <UPN> \| Select-Object StrongAuthenticationMethods` |
| "We couldn't verify your identity" | Auth method challenge failed (wrong code, expired code) | User-side issue; advise retry or register alternate method |
| Reset completes but on-prem password not changed | Password Writeback not enabled, or Entra Connect service stopped | Check writeback feature in Entra Connect wizard |
| "Your organization's password policy doesn't allow…" | Fine-Grained Password Policy blocks reset (min age) | Check FGPP on user in ADAC |
| Reset completes but user still can't log in | PRT stale; user needs to lock/unlock or sign out | Force token refresh; check PRT with `dsregcmd /status` |
| Writeback succeeds but user still prompted for old password | Kerberos TGT not expired; cached credential | Flush Kerberos tickets: `klist purge` |
| Admin reset fails for another admin | Entra ID P1/P2 admin reset policy (6 methods) is stricter | Admins cannot use security questions; must have 2 other methods |
| Combined registration unavailable | Feature not enabled or Conditional Access blocking registration | Check CA policies for `MicrosoftAzureActiveDirectoryMFA` app |

---

## Validation Steps

**1. Confirm SSPR is enabled and scoped correctly**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"

# Get SSPR policy
$policy = Get-MgPolicyAuthorizationPolicy
$policy | Select-Object DefaultUserRolePermissions

# Check SSPR policy via beta endpoint
$uri = "https://graph.microsoft.com/beta/policies/authorizationPolicy"
Invoke-MgGraphRequest -Method GET -Uri $uri | ConvertTo-Json -Depth 5
```
Expected: `"selfServePasswordResetEnabled": true` (or check portal: Entra ID > Password reset > Properties shows "Selected" or "All")

**2. Check user's registered auth methods**
```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All"

$userId = "<UPN>"
Get-MgUserAuthenticationMethod -UserId $userId | Select-Object Id, AdditionalProperties
```
Expected: At least 1 method registered (2 if policy requires 2). Bad: Empty array — user has no methods registered.

**3. Verify Password Writeback is enabled (hybrid only)**
```powershell
# On the Entra Connect server
Import-Module ADSync
Get-ADSyncConnector | Where-Object {$_.Type -eq "Extensible2"} | Select-Object Name, Enabled
Get-ADSyncGlobalSettings | Select-Object PasswordWritebackEnabled
```
Expected: `PasswordWritebackEnabled : True`. Bad: `False` — enable via Entra Connect configuration wizard.

**4. Verify connector account permissions**
```powershell
# Run on Entra Connect server or DC
Import-Module ActiveDirectory

$connectorAccount = "<MSOL_xxxxxxxxx or connector account UPN>"
$userOU = "OU=Users,DC=contoso,DC=com"

# Check effective permissions — requires RSAT
$acl = Get-Acl -Path "AD:\$userOU"
$acl.Access | Where-Object {$_.IdentityReference -like "*$connectorAccount*"} |
    Select-Object IdentityReference, ActiveDirectoryRights, AccessControlType
```
Expected: `Reset Password`, `Write pwdLastSet`, `Write lockoutTime` rights present.

**5. Test writeback path connectivity**
```powershell
# On Entra Connect server — test outbound to Service Bus
Test-NetConnection -ComputerName "*.servicebus.windows.net" -Port 443
# Use specific endpoint if wildcard fails:
Test-NetConnection -ComputerName "sb.windows.net" -Port 443
```

**6. Check audit log for SSPR events**
```powershell
Connect-MgGraph -Scopes "AuditLog.Read.All"

$filter = "activityDisplayName eq 'Reset password (self-service)' or activityDisplayName eq 'Self-serve password reset flow activity progress'"
$logs = Get-MgAuditLogDirectoryAudit -Filter $filter -Top 20
$logs | Select-Object ActivityDateTime, ActivityDisplayName, Result, ResultReason,
    @{N='User';E={$_.TargetResources[0].UserPrincipalName}} |
    Sort-Object ActivityDateTime -Descending | Format-Table -AutoSize
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — User Registration Issues

**Problem:** User cannot reach `https://aka.ms/mysecurityinfo`

1. Check if Conditional Access is blocking the registration app:
   - Sign-in logs for the user > filter for app "Combined MFA and SSPR Registration"
   - Look for Failure reason in CA evaluation details
2. Check if the user's location/device is blocked by a named location or device compliance CA policy
3. Test with a browser in InPrivate mode to rule out extension/cached credential issues

**Problem:** User registered methods but SSPR still says "not enough methods"

1. Confirm the SSPR policy's "Number of methods required to reset" setting
2. Check if the user registered methods via the *legacy* SSPR portal — these may not count toward combined registration
3. Force re-registration: Entra ID > Users > select user > Authentication methods > "Require re-register MFA"

---

### Phase 2 — Reset Fails at Challenge Step

**Problem:** SMS/email code not received

1. Verify the phone number or email in the user's `mysecurityinfo` profile is correct
2. Check if SMS delivery is blocked by a Conditional Access policy requiring compliant device for auth method registration
3. For email: check spam folder; verify the alternate email domain isn't blocking Microsoft IPs
4. Microsoft Authenticator not working — advise user to check time sync on phone (TOTP is time-based)

---

### Phase 3 — Reset Completes but Password Not Written Back

1. Check Entra Connect Application Event Log on the sync server:
   ```
   Event ID 33001 — Password writeback service stopped
   Event ID 33002 — Password writeback service started
   Event ID 33010 — Password writeback succeeded
   Event ID 33011 — Password writeback failed
   ```

2. Restart the ADSync service and retry:
   ```powershell
   Restart-Service ADSync
   Start-Sleep -Seconds 30
   # Retry the SSPR reset
   ```

3. Check Fine-Grained Password Policy:
   ```powershell
   Get-ADUserResultantPasswordPolicy -Identity <samAccountName>
   ```
   If `MinPasswordAge` is > 0, user cannot reset until that time has elapsed.

4. Verify user account is not in the "Protected Users" security group:
   ```powershell
   Get-ADGroupMember -Identity "Protected Users" | Where-Object {$_.SamAccountName -eq "<samAccountName>"}
   ```
   Protected Users group members have restricted Kerberos behaviour and some write-back operations may behave differently.

---

### Phase 4 — Post-Reset Sign-In Issues

**Problem:** Password changed successfully but user cannot log in

1. On a domain-joined machine, check if the Kerberos ticket is stale:
   ```cmd
   klist purge
   ```
   Then sign out completely and sign back in.

2. If user is signing into a cloud service: PRT may still have old credential cached. Sign out of all sessions via Entra ID > Users > Revoke sessions.

3. If user signs into VPN or legacy app using NTLM: the on-prem password change may need to propagate. Check DC replication health:
   ```powershell
   repadmin /showrepl
   ```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Enable SSPR for a Specific Group</summary>

```powershell
# SSPR group membership and scope are managed in the Entra ID portal.
# There is no direct Graph API to toggle SSPR policy scope — use portal:
# Entra ID > Password reset > Properties > Self service password reset enabled: Selected
# Select the group, Save.

# To add a user to the SSPR scope group via PowerShell:
Connect-MgGraph -Scopes "GroupMember.ReadWrite.All"

$groupId = "<SSPR-Group-Object-ID>"
$userId  = "<User-Object-ID>"

New-MgGroupMember -GroupId $groupId -DirectoryObjectId $userId
Write-Host "User added to SSPR scope group." -ForegroundColor Green
```

**Rollback:** Remove the user from the group with `Remove-MgGroupMemberDirectoryObjectByRef`.

</details>

<details><summary>Playbook 2 — Enable Password Writeback in Entra Connect</summary>

```powershell
# Run on Entra Connect server — requires ADSync module
Import-Module ADSync

# Check current state
$settings = Get-ADSyncGlobalSettings
Write-Host "Password Writeback currently: $($settings.PasswordWritebackEnabled)"

# Enable via wizard (recommended) — or via PowerShell:
Set-ADSyncPasswordWritebackConfiguration -Enable $true

# Verify
$settings = Get-ADSyncGlobalSettings
Write-Host "Password Writeback now: $($settings.PasswordWritebackEnabled)"

# Restart service to apply
Restart-Service ADSync
Write-Host "ADSync service restarted." -ForegroundColor Green
```

**Note:** If using Entra Connect cloud sync (not the classic agent), Password Writeback is configured differently — enable it in the cloud sync agent settings in the portal.

**Rollback:** `Set-ADSyncPasswordWritebackConfiguration -Enable $false`

</details>

<details><summary>Playbook 3 — Grant Connector Account Reset Password Rights</summary>

```powershell
# Run on a DC with RSAT. Replace placeholders with real values.
Import-Module ActiveDirectory

$connectorAccount = "CONTOSO\MSOL_<suffix>"  # Entra Connect service account
$targetOU          = "OU=Users,DC=contoso,DC=com"

# Get the account SID
$sid = (Get-ADUser -Filter {SamAccountName -eq "MSOL_<suffix>"}).SID

# Get the OU ACL
$acl = Get-Acl -Path "AD:\$targetOU"

# Define the "Reset Password" permission
$resetPasswordGuid  = [GUID]"00299570-246d-11d0-a768-00aa006e0529"
$allPropertiesGuid  = [GUID]"00000000-0000-0000-0000-000000000000"

$rule1 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
    [System.Security.AccessControl.AccessControlType]::Allow,
    $resetPasswordGuid,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
    [GUID]"bf967aba-0de6-11d0-a285-00aa003049e2"  # User class GUID
)

$acl.AddAccessRule($rule1)
Set-Acl -Path "AD:\$targetOU" -AclObject $acl

Write-Host "Reset password ACE added for $connectorAccount on $targetOU" -ForegroundColor Green
```

**Rollback:** Remove the specific ACE from the ACL using `$acl.RemoveAccessRule($rule1)` and call `Set-Acl` again.

</details>

<details><summary>Playbook 4 — Force User to Re-Register SSPR Methods</summary>

```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.ReadWrite.All"

$userId = "<UPN>"

# List current methods
$methods = Get-MgUserAuthenticationMethod -UserId $userId
Write-Host "Current methods for $userId :" -ForegroundColor Cyan
$methods | ForEach-Object { Write-Host "  $_OdataType: $($_.Id)" }

# To revoke and force re-registration, use the portal:
# Entra ID > Users > <user> > Authentication methods > "Require re-register MFA"
# This sets a flag that prompts the user to re-register at next sign-in.

# Via Graph API — set the requireReRegisterMFA property:
$uri = "https://graph.microsoft.com/v1.0/users/$userId/authentication/requirements"
$body = @{ perUserMfaState = "enabled" } | ConvertTo-Json
# Note: Forcing re-registration is primarily a portal action; advise using portal for this step.
Write-Host "Navigate to: Entra ID > Users > $userId > Authentication methods > Require re-register MFA" -ForegroundColor Yellow
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collect SSPR diagnostic evidence for a specific user.
.DESCRIPTION
    Gathers SSPR policy state, user registration, writeback config, and audit logs.
    Run before escalating to Microsoft Support.
.PARAMETER UserPrincipalName
    UPN of the affected user (e.g. jsmith@contoso.com)
.PARAMETER OutputPath
    Path to save the report (default: C:\Temp\SSPR-Evidence-<date>.txt)
.EXAMPLE
    .\Collect-SSPREvidence.ps1 -UserPrincipalName jsmith@contoso.com
#>
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$OutputPath = "C:\Temp\SSPR-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
)

Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","UserAuthenticationMethod.Read.All","Policy.Read.All"

$evidence = [System.Text.StringBuilder]::new()
$nl = "`n"

$null = $evidence.AppendLine("=== SSPR EVIDENCE PACK ===")
$null = $evidence.AppendLine("User : $UserPrincipalName")
$null = $evidence.AppendLine("Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$null = $evidence.AppendLine("Collector: $env:USERDOMAIN\$env:USERNAME")
$null = $evidence.AppendLine("")

# 1. User basic info
$null = $evidence.AppendLine("--- USER DETAILS ---")
$user = Get-MgUser -UserId $UserPrincipalName -Property Id,DisplayName,UserPrincipalName,AccountEnabled,AssignedLicenses
$null = $evidence.AppendLine("Display Name     : $($user.DisplayName)")
$null = $evidence.AppendLine("UPN              : $($user.UserPrincipalName)")
$null = $evidence.AppendLine("Account Enabled  : $($user.AccountEnabled)")
$null = $evidence.AppendLine("Assigned Licenses: $($user.AssignedLicenses.Count)")
$null = $evidence.AppendLine("")

# 2. Auth methods registered
$null = $evidence.AppendLine("--- REGISTERED AUTH METHODS ---")
$methods = Get-MgUserAuthenticationMethod -UserId $UserPrincipalName
foreach ($m in $methods) {
    $null = $evidence.AppendLine("  Method: $($m.AdditionalProperties['@odata.type'])  Id: $($m.Id)")
}
if ($methods.Count -eq 0) { $null = $evidence.AppendLine("  [NONE REGISTERED]") }
$null = $evidence.AppendLine("")

# 3. SSPR audit logs (last 20 events)
$null = $evidence.AppendLine("--- SSPR AUDIT LOG (last 20) ---")
$filter = "activityDisplayName eq 'Reset password (self-service)' and initiatedBy/user/userPrincipalName eq '$UserPrincipalName'"
$logs = Get-MgAuditLogDirectoryAudit -Filter $filter -Top 20
foreach ($l in $logs) {
    $null = $evidence.AppendLine("  $($l.ActivityDateTime) | $($l.ActivityDisplayName) | $($l.Result) | $($l.ResultReason)")
}
if ($logs.Count -eq 0) { $null = $evidence.AppendLine("  [NO EVENTS FOUND]") }
$null = $evidence.AppendLine("")

# 4. Password writeback (if on hybrid server)
$null = $evidence.AppendLine("--- PASSWORD WRITEBACK CONFIG ---")
if (Get-Module -ListAvailable -Name ADSync) {
    Import-Module ADSync
    $wb = Get-ADSyncGlobalSettings
    $null = $evidence.AppendLine("  PasswordWritebackEnabled: $($wb.PasswordWritebackEnabled)")
    $svc = Get-Service -Name ADSync -ErrorAction SilentlyContinue
    $null = $evidence.AppendLine("  ADSync Service Status   : $($svc.Status)")
} else {
    $null = $evidence.AppendLine("  [ADSync module not available — not running on Entra Connect server]")
}

$null = $evidence.AppendLine("")
$null = $evidence.AppendLine("=== END OF EVIDENCE PACK ===")

$content = $evidence.ToString()
$content | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "Evidence saved to: $OutputPath" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check SSPR policy scope | Portal: Entra ID > Password reset > Properties |
| List user's registered auth methods | `Get-MgUserAuthenticationMethod -UserId <UPN>` |
| View SSPR audit events for user | `Get-MgAuditLogDirectoryAudit -Filter "..."` (see Validation Steps) |
| Check writeback enabled | `Get-ADSyncGlobalSettings \| Select PasswordWritebackEnabled` |
| Restart ADSync service | `Restart-Service ADSync` |
| Check FGPP on user | `Get-ADUserResultantPasswordPolicy -Identity <sam>` |
| Check Protected Users membership | `Get-ADGroupMember -Identity "Protected Users"` |
| Purge Kerberos tickets (post-reset) | `klist purge` |
| Revoke all user sessions in Entra | `Revoke-MgUserSignInSession -UserId <UPN>` |
| Check Entra Connect event log | `Get-WinEvent -LogName Application -Source "Directory Synchronization" -MaxEvents 50` |
| Force SSPR re-registration | Portal: Entra ID > Users > \<user\> > Authentication methods > Require re-register |
| Test DNS resolution for Service Bus | `Resolve-DnsName servicebus.windows.net` |

---

## 🎓 Learning Pointers

- **SSPR and MFA use the same auth method registry** since combined registration was introduced. If a user's MFA stops working after they change their SSPR methods, the two are now linked. See: [Combined registration overview](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-registration-mfa-sspr-combined)

- **Fine-Grained Password Policies (FGPP) are the #1 hybrid writeback failure cause** that isn't immediately obvious. A MinPasswordAge of even 1 day will silently block SSPR writeback for users who reset recently. Always run `Get-ADUserResultantPasswordPolicy` before escalating. See: [Password writeback troubleshooting](https://learn.microsoft.com/en-us/entra/identity/authentication/troubleshoot-sspr-writeback)

- **Security questions cannot be used by admin accounts.** Microsoft enforces this tenant-wide regardless of policy settings. Admins must register phone/app methods. See: [SSPR policies for admins](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sspr-policy#administrator-reset-policy-differences)

- **The Azure Service Bus relay is the writeback transport.** Entra Connect doesn't need an inbound firewall hole — it opens an *outbound* connection on 443 to `*.servicebus.windows.net` and holds it open. If your proxy requires FQDN allowlisting and uses SSL inspection, this connection must be excluded from inspection. See: [Entra Connect network requirements](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/reference-connect-ports)

- **Stale PRT after password reset** is a common "it didn't work" complaint. When a user resets via SSPR and then tries to use a cloud app, the PRT (Primary Refresh Token) on their device still holds old credential state. The fix is to sign out of Windows entirely (not just lock), which forces PRT renewal. See: [What is a Primary Refresh Token?](https://learn.microsoft.com/en-us/entra/identity/devices/concept-primary-refresh-token)

- **Password writeback and Protected Users security group**: Members of "Protected Users" have Kerberos restrictions enforced at the DC level. While writeback itself usually succeeds, the post-reset experience can be degraded. Avoid adding regular end-user accounts to Protected Users unless specifically required for privileged accounts.
