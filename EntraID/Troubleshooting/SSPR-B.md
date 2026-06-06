# SSPR (Self-Service Password Reset) — Hotfix Runbook (Mode B: Ops)
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

Run these as the engineer — not on the user's machine. Requires Graph/Entra PowerShell.

```powershell
# 1. Check if SSPR is enabled for the tenant / user's group
# Open: https://portal.azure.com > Microsoft Entra ID > Password reset > Properties

# 2. Check the user's authentication methods registered for SSPR
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All", "User.Read.All"
$upn = "<userUPN>"
Get-MgUserAuthenticationMethod -UserId $upn | Select-Object -ExpandProperty AdditionalProperties

# 3. Check if the user account is blocked / locked in Entra
Get-MgUser -UserId $upn -Property AccountEnabled, SignInActivity, OnPremisesSyncEnabled |
  Select-Object DisplayName, AccountEnabled, OnPremisesSyncEnabled

# 4. Check if the user is in the SSPR-enabled group (if scoped to a group)
# Replace <groupId> with the SSPR group's object ID from Entra portal
Get-MgGroupMember -GroupId "<SSPR-GroupId>" | Where-Object { $_.Id -eq (Get-MgUser -UserId $upn).Id }

# 5. Check SSPR audit logs for the user's recent reset attempts
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn'" -Top 5 |
  Select-Object CreatedDateTime, Status, ClientAppUsed
```

| Result | Action |
|--------|--------|
| No auth methods registered (step 2 returns empty) | → Fix 1: Register methods / user must register |
| AccountEnabled = False | → Fix 2: Re-enable account first, then reset |
| OnPremisesSyncEnabled = True + password change failing | → Fix 3: Password writeback issue |
| User not in SSPR group | → Fix 4: Add user to SSPR scope |
| Auth methods registered but reset still fails | → Fix 5: License / SSPR config audit |
| SSPR works for others but not this user | → Check auth method registration + MFA registration policy |

---
## Dependency Cascade

<details><summary>What must be true for SSPR to work</summary>

```
User Account (Entra ID)
    └── Account Enabled + Not Locked
            └── SSPR Feature Enabled (tenant-level or group-scoped)
                    └── User in SSPR-enabled scope (All users or specific group)
                            └── Auth Methods Registered (≥ 1 method, ≥ 2 if required by policy)
                                    ├── Mobile phone (SMS/voice)
                                    ├── Authenticator app (notification or OATH code)
                                    ├── Email (alternate)
                                    ├── Security questions
                                    └── Office phone (if enabled)
                                            └── Entra SSPR Portal (aka.ms/sspr)
                                                    └── [For hybrid] Password Writeback
                                                                └── Entra Connect
                                                                        └── On-prem AD
```

**Password Writeback must be enabled in Entra Connect if:**
- The user account is synced from on-premises AD (OnPremisesSyncEnabled = True)
- Without writeback, the user changes their cloud password but on-prem password remains old — login fails

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm SSPR is enabled at the tenant level**
```
Azure Portal → Microsoft Entra ID → Password reset → Properties
```
- Expected: "Selected" (group-scoped) or "All" — never "None" for an SSPR ticket
- If "None" → escalate to Global Admin to enable

**Step 2 — Confirm user's auth method registrations**
```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All"
Get-MgUserAuthenticationMethod -UserId "<upn>" |
  Select-Object -ExpandProperty AdditionalProperties | ConvertTo-Json
```
- Look for `phoneAuthenticationMethod`, `microsoftAuthenticatorAuthenticationMethod`, `emailAuthenticationMethod`
- If none registered → user needs to register at [aka.ms/ssprsetup](https://aka.ms/ssprsetup)
- Count registered methods — check against SSPR policy minimum (1 or 2)

**Step 3 — Check SSPR registration status in the portal**
```
Azure Portal → Microsoft Entra ID → Password reset → Registration → Search user
```
- Shows whether user is "registered" for SSPR
- "Not registered" with methods present → policy number-of-methods mismatch

**Step 4 — For hybrid users: verify password writeback**
```powershell
# On the Entra Connect server
Get-ADSyncAADPasswordResetConfiguration
# Should show: PasswordWritebackEnabled = True
```
```
Azure Portal → Microsoft Entra ID → Password reset → On-premises integration
→ "Write back passwords to your on-premises directory" = Yes
```

**Step 5 — Try the reset manually from portal (admin-initiated)**
```
Azure Portal → Microsoft Entra ID → Users → [User] → Reset password
```
- If this fails → account-level issue (locked/disabled/sync error)
- If this works but SSPR doesn't → auth method registration or SSPR policy issue

---
## Common Fix Paths

<details><summary>Fix 1 — User needs to register SSPR methods</summary>

The most common cause: user simply hasn't registered.

**Direct the user to:**
```
https://aka.ms/ssprsetup
```

**Or send the registration enforcement policy (admin):**
```
Azure Portal → Microsoft Entra ID → Password reset → Registration
→ "Require users to register when signing in" = Yes
→ "Number of days before users are asked to re-confirm" = 180 (recommended)
```

**Admin: pre-populate a mobile phone number for the user**
```powershell
# Requires UserAuthenticationMethod.ReadWrite.All
$upn = "<userUPN>"
$phoneBody = @{
    phoneNumber = "+44<number>"  # E.164 format
    phoneType   = "mobile"
}
$bodyJson = $phoneBody | ConvertTo-Json
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/v1.0/users/$upn/authentication/phoneMethods" `
  -Body $bodyJson -ContentType "application/json"
```

Note: Pre-populating phone numbers doesn't mean the user is "registered" — they still need to verify. But it pre-fills the field so the experience is smoother.

</details>

<details><summary>Fix 2 — Account locked or disabled</summary>

SSPR cannot reset a password on a disabled or locked account — the reset portal will show a generic error.

```powershell
# Check status
$user = Get-MgUser -UserId "<upn>" -Property AccountEnabled, OnPremisesSyncEnabled, OnPremisesLastSyncDateTime

# If cloud-only: re-enable
Update-MgUser -UserId "<upn>" -AccountEnabled $true

# If synced from on-prem: fix in AD, wait for sync (or force sync)
# On domain controller or AD admin machine:
Enable-ADAccount -Identity "<samAccountName>"
Unlock-ADAccount -Identity "<samAccountName>"

# Force Entra Connect delta sync
# On Entra Connect server:
Start-ADSyncSyncCycle -PolicyType Delta
```

**Validate:** `Get-MgUser -UserId "<upn>" -Property AccountEnabled` returns `True`

</details>

<details><summary>Fix 3 — Password writeback not working (hybrid users)</summary>

Symptom: User resets via SSPR portal, sees "success", but still can't log in on-prem with new password.

```powershell
# Step 1: Verify writeback is configured
# On Entra Connect server:
Get-ADSyncAADPasswordResetConfiguration
# PasswordWritebackEnabled should be True

# Step 2: Check Entra Connect service account has permissions
# The MSOL_ account needs Reset Password permission on the OU containing the user
# Run on Entra Connect server:
$connectAccount = (Get-ADSyncConnector | Where-Object { $_.Type -eq 'AD' }).ConnectivityParameters |
  Where-Object { $_.Name -eq 'forest-login-user' } | Select-Object -ExpandProperty Value
Write-Host "Entra Connect AD Account: $connectAccount"

# Step 3: Check the connector health
Get-ADSyncConnectorStatistics -ConnectorName "<AD domain name>"
```

**Portal check:**
```
Azure Portal → Microsoft Entra ID → Password reset → On-premises integration
→ Verify both toggles are On
→ Click "Test on-premises connectivity" button
```

**If writeback service is running but failing:**
- Check `Application` and `System` event logs on the Entra Connect server for ID 33004, 33005, 33006, 33007 (ADSync password writeback events)
- EventID 33004 = permission issue on AD account
- EventID 33006 = directory connectivity problem

</details>

<details><summary>Fix 4 — Add user to SSPR scope</summary>

When SSPR is scoped to a specific group ("Selected" rather than "All"):

```powershell
# Find the SSPR group
# Azure Portal → Entra ID → Password reset → Properties → Selected group name

# Add user to the group
$groupId   = "<SSPR-GroupObjectId>"
$userId    = (Get-MgUser -UserId "<upn>").Id

New-MgGroupMember -GroupId $groupId -DirectoryObjectId $userId
Write-Host "User added to SSPR group"

# Verify
Get-MgGroupMember -GroupId $groupId | Where-Object { $_.Id -eq $userId }
```

**Note:** Group membership change takes effect within minutes (not instant). Ask the user to wait 5 minutes before retrying.

</details>

<details><summary>Fix 5 — SSPR policy / licensing check</summary>

SSPR requires one of: Microsoft Entra ID P1/P2, M365 Business Premium, or EMS E3/E5. Without a license, SSPR is unavailable.

```powershell
# Check user's licenses
Get-MgUserLicenseDetail -UserId "<upn>" | Select-Object SkuPartNumber, SkuId

# Licenses that include SSPR:
# AAD_PREMIUM (P1), AAD_PREMIUM_P2 (P2), SPB (Business Premium)
# EMSPREMIUM (EMS E3), RIGHTSMANAGEMENT_ADHOC, many M365 E3/E5 bundles
```

**Check SSPR policy methods required:**
```
Azure Portal → Entra ID → Password reset → Authentication methods
```
- If policy requires 2 methods and user only has 1 registered → registration incomplete
- Reduce to 1 if appropriate, or help user register a second method

</details>

---
## Escalation Evidence

```
## SSPR Escalation Pack

Ticket: [ticket number]
Date/Time: [timestamp]
Affected user: [UPN]
User type: [Cloud-only / Hybrid (synced from AD)]

--- Account State ---
AccountEnabled: [True/False]
OnPremisesSyncEnabled: [True/False]

--- SSPR Configuration ---
SSPR scope: [None / Selected / All]
User in SSPR group: [Yes/No/N/A]
Methods required by policy: [1 / 2]

--- Registered Auth Methods ---
[paste output of Get-MgUserAuthenticationMethod]

--- Password Writeback (hybrid only) ---
Writeback enabled in portal: [Yes/No]
PasswordWritebackEnabled (Get-ADSyncAADPasswordResetConfiguration): [True/False]
Entra Connect event log errors: [paste EventIDs 33004-33007 if present]

--- Licenses ---
[paste Get-MgUserLicenseDetail output]

--- Error seen by user ---
[exact error message from aka.ms/sspr portal]

--- Steps taken ---
[ ] Fix 1: Auth method registration
[ ] Fix 2: Re-enabled account
[ ] Fix 3: Writeback verified
[ ] Fix 4: Added to SSPR group
[ ] Fix 5: License/policy reviewed

Current status: [resolved / still failing]
```

---
## 🎓 Learning Pointers

- **SSPR is not the same as admin-initiated password reset.** SSPR specifically means the user resets their own password at [aka.ms/sspr](https://aka.ms/sspr) without admin involvement. Admin-initiated reset works even with SSPR disabled — make sure you're diagnosing the right problem.

- **Password writeback is the most dangerous part of SSPR.** If the Entra Connect service account doesn't have `Reset Password` rights on the AD OU, writeback silently fails. Set this via `Active Directory Users and Computers` → OU properties → Security → Advanced → Add the MSOL_ account with Reset Password permission. See: [Entra Connect — Writeback Permissions](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-password-writeback)

- **SSPR registration is separate from MFA registration.** A user can be registered for MFA (Authenticator app) but not for SSPR if the SSPR policy requires a specific method type (e.g., mobile phone). Combined registration (`aka.ms/mysecurityinfo`) lets users register both simultaneously. See: [Combined security information registration](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-registration-mfa-sspr-combined)

- **SSPR audit logs are your forensic trail.** Every reset attempt is logged in: `Azure Portal → Entra ID → Monitoring → Audit logs → Category: Self-service Password Management`. Filter by user to see exactly what failed and when.

- **Pre-register methods for VIP/exec users.** Admins can pre-populate phone numbers via Graph API before VIPs get locked out. Combine with Temporary Access Pass (TAP) for a smooth recovery path — TAP lets the user bypass MFA/SSPR to register methods from scratch. See: [Temporary Access Pass](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-temporary-access-pass)

- **SSPR at Windows login screen requires Entra-joined or hybrid-joined devices** with the feature enabled via Intune (`Windows Hello for Business CSP` or a custom OMA-URI for SSPR on lock screen). It doesn't work on domain-joined-only machines without Entra join. See: [Enable SSPR at Windows sign-in screen](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-sspr-windows)
