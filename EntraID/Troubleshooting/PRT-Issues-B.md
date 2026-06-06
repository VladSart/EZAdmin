# Primary Refresh Token (PRT) Issues — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes. User getting constant auth prompts, SSO broken, or Conditional Access blocking access despite being on a compliant device.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these on the affected device, logged in as the affected user (or check the fields for the affected user's session).

```powershell
# 1. PRT present and valid?
dsregcmd /status
# KEY FIELDS:
#   AzureAdPrt              : YES or NO
#   AzureAdPrtUpdateTime    : timestamp — when PRT was last refreshed
#   AzureAdPrtExpiryTime    : when PRT expires (typically 14 days)
#   AzureAdPrtAuthority     : login.microsoftonline.com (expected)
#   EnterprisePrt           : YES (hybrid environments only)
#   EnterprisePrtUpdateTime : timestamp

# 2. Is the device registered at all? (If NO — PRT cannot be issued)
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|WorkplaceJoined"

# 3. Check WAM (Web Account Manager) token state for the user
# Run as the affected user in their session
whoami /upn
dsregcmd /status | Select-String "Prt|Sso"

# 4. Check time sync — PRT refresh fails if clock is off by >5 minutes
w32tm /query /status
# Check: ClockOffset — must be under 300 seconds (5 min) for Kerberos/token operations

# 5. Check device-to-token-endpoint reachability
Test-NetConnection -ComputerName "device.login.microsoftonline.com" -Port 443
Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443
```

**Interpret — if X then do Y:**

| Finding | Next action |
|---------|------------|
| `AzureAdPrt: NO` + device just joined | Wait 10–15 minutes. PRT is issued on first interactive logon after join. Lock/unlock the device. |
| `AzureAdPrt: NO` + device has been joined for days | Work through [Dependency Cascade](#dependency-cascade). Check proxy and clock. |
| `AzureAdPrt: YES` but `AzureAdPrtUpdateTime` is >14 days ago | PRT is expired — force refresh, see [Fix 1](#fix-1--force-prt-refresh) |
| `AzureAdPrt: YES` but user still prompted for MFA | PRT missing MFA claim — see [Fix 3](#fix-3--prt-present-but-mfa-claim-missing) |
| `ClockOffset` >300 sec | Fix time sync first — everything else is meaningless until clock is correct |
| `Test-NetConnection` fails to token endpoints | Proxy blocking — see [Fix 4](#fix-4--proxy-or-ssl-inspection-blocking-prt-refresh) |
| `AzureAdPrt: YES` but CA still blocking | Check CA policy specifically — see [Conditional Access interaction](#interaction-with-conditional-access) |

---

## Dependency Cascade

<details><summary>What must be true for a PRT to exist and stay valid — click to expand</summary>

```
[Device is Entra Joined OR Hybrid Entra Joined OR Entra Registered]
    │   (Device must have a device identity in Entra)
    │
    ▼
[User logs in interactively on the device]
    │
    ▼
[Windows WAM (Web Account Manager) broker invoked]
    │   WAM is a Windows component (lsaiso.exe / backgroundtaskhost.exe)
    │   It intermediates all modern auth token requests
    │   WAM calls the Entra token endpoint on behalf of the device + user
    │
    ▼
[Device proves identity using its device certificate]
    │   The certificate was issued during device registration
    │   Stored in: Cert:\LocalMachine\My (device cert) or TPM
    │   On hybrid-joined devices, Kerberos is also used to prove AD identity
    │
    ▼
[Entra issues the PRT — bound to device + user combination]
    │   PRT = long-lived session key (~14 days, sliding window on use)
    │   Contains claims: device ID, user ID, join type, MFA claim (if MFA was done)
    │   Encrypted and stored in lsass.exe — not accessible to user-space apps
    │
    ▼
[WAM uses PRT to silently obtain Access Tokens + Refresh Tokens]
    │   Apps call WAM → WAM presents PRT → Entra issues app-specific tokens
    │   No user interaction needed = SSO
    │
    ▼
[Conditional Access evaluates claims in the token]
    │   CA checks: device compliant? device joined? MFA claim present? location?
    │   All these claims flow from the PRT through to the access token
    │
    ▼
[User accesses resource without being prompted]
```

**PRT refresh conditions:**
- Refreshed automatically every 4 hours while device is active
- Refreshed on lock/unlock
- Requires reaching `https://device.login.microsoftonline.com`
- Requires valid device certificate
- Password change invalidates PRT — new PRT is issued on next interactive auth

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Full dsregcmd output (key PRT fields)**
```powershell
# Run as affected user on affected device
dsregcmd /status

# Pipe to file for evidence collection
dsregcmd /status > C:\Temp\dsregcmd-$(Get-Date -Format yyyyMMdd-HHmm).txt
```

PRT section will look like this when healthy:
```
AzureAdPrt              : YES
AzureAdPrtUpdateTime    : 2024-01-15 09:32:14.000 UTC
AzureAdPrtExpiryTime    : 2024-01-29 09:32:14.000 UTC
AzureAdPrtAuthority     : https://login.microsoftonline.com/<tenantID>
```

When broken:
```
AzureAdPrt              : NO
```
or:
```
AzureAdPrt              : YES
AzureAdPrtUpdateTime    : 2024-01-01 09:00:00.000 UTC   ← stale
```

**Step 2 — Verify device join state**
```powershell
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|WorkplaceJoined|TenantName|DeviceId"
```
If `AzureAdJoined: NO` → PRT cannot be issued. Fix the device join first (see HybridJoin-B.md or re-join to Entra).

**Step 3 — Check device certificate validity**
```powershell
# The device certificate is what proves identity during PRT acquisition
Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Issuer -like "*MS-Organization-Access*" -or $_.Issuer -like "*CN=MS-Organization-P2P*" } |
    Select-Object Subject, Issuer, NotBefore, NotAfter, Thumbprint |
    Format-List

# Expected: certificate present, NotAfter in the future
# Missing or expired cert = PRT cannot be obtained
```

**Step 4 — Verify clock synchronisation**
```powershell
w32tm /query /status | Select-String "ClockOffset|Source|NTPServer|Stratum"
# ClockOffset must be under 5 minutes
# If domain-joined: source should be a DC, not time.windows.com

# Force resync if needed
w32tm /resync /force
```

**Step 5 — Check token endpoint connectivity (SYSTEM context)**
```powershell
# PRT operations run as SYSTEM, not as the user
# Test from SYSTEM context using PsExec or a scheduled task running as SYSTEM
# Quick test from current session:
$endpoints = @(
    "https://device.login.microsoftonline.com",
    "https://login.microsoftonline.com",
    "https://login.microsoftonline.com/common/oauth2/token"
)
foreach ($url in $endpoints) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -Method Head -TimeoutSec 10 -ErrorAction Stop
        Write-Host "OK      $url" -ForegroundColor Green
    } catch [System.Net.WebException] {
        # 4xx responses still mean the endpoint was reached
        if ($_.Exception.Response) {
            Write-Host "OK      $url (HTTP $([int]$_.Exception.Response.StatusCode))" -ForegroundColor Green
        } else {
            Write-Host "FAIL    $url — $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
```

**Step 6 — Check sign-in logs in Entra**
```powershell
Connect-MgGraph -Scopes "AuditLog.Read.All"

# Get non-interactive sign-in failures for the user (PRT refresh shows here)
$upn = "<user@domain.com>"
$cutoff = (Get-Date).AddHours(-4).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn' and createdDateTime ge $cutoff and status/errorCode ne 0" `
    -All -Top 20 |
    Select-Object CreatedDateTime, AppDisplayName, ClientAppUsed, DeviceDetail,
        @{N="ErrorCode";E={$_.Status.ErrorCode}},
        @{N="FailureReason";E={$_.Status.FailureReason}},
        @{N="ConditionalAccessStatus";E={$_.ConditionalAccessStatus}} |
    Format-Table -Wrap
```

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Force PRT refresh (lock/unlock)</summary>

**Symptom:** `AzureAdPrt: YES` but `AzureAdPrtUpdateTime` is stale, or `AzureAdPrt: NO` on a device that recently re-joined.

This is the first thing to try — it's instant and non-destructive.

```powershell
# Option A: Lock the workstation and unlock (user does this interactively)
# Lock: Win+L
# Unlock with password or Windows Hello
# Wait 60 seconds after unlock, then re-check:
dsregcmd /status | Select-String "AzureAdPrt|AzureAdPrtUpdateTime"

# Option B: Force refresh via dsregcmd (Windows 10 1903+ / Windows 11)
dsregcmd /refreshprt
# This forces WAM to attempt a PRT refresh immediately
# Run as the affected user (NOT as admin — WAM is per-user context)

# Option C: Sign out and back in (nuclear option for session — loses all open work)
# Logoff → Wait for logoff to complete → Log back in → Test
```

After refresh, verify:
```powershell
dsregcmd /status | Select-String "AzureAdPrt|AzureAdPrtUpdateTime|AzureAdPrtExpiryTime"
```
`AzureAdPrtUpdateTime` should now be within the last few minutes.

</details>

<details id="fix-2"><summary>Fix 2 — Re-register device (PRT persistently NO after other fixes)</summary>

**Symptom:** Lock/unlock doesn't help, `dsregcmd /refreshprt` returns an error, device cert is missing or expired.

> ⚠️ This removes the device from Entra and re-registers it. MDM enrollment will re-trigger. Test in non-production first and confirm with your lead if this is a critical workstation.

```powershell
# Step 1: Leave Entra (dsregcmd /leave clears the registration but not domain join)
dsregcmd /leave
# Expected output: "Successfully performed leave for device"

# Step 2: Verify registration is cleared
dsregcmd /status | Select-String "AzureAdJoined"
# Should now show: AzureAdJoined: NO

# Step 3: Re-register
# Option A — via scheduled task (preferred, no reboot needed)
Start-ScheduledTask -TaskName "Automatic-Device-Join" -TaskPath "\Microsoft\Windows\Workplace Join\"

# Option B — reboot (most reliable — runs registration tasks at logon)
# Restart-Computer

# Step 4: After task completes (~2–3 min) or after reboot, verify
dsregcmd /status | Select-String "AzureAdJoined|AzureAdPrt"
```

If the device was hybrid-joined, also trigger Entra Connect delta sync after re-registration to link the on-prem computer object to the new Entra device object:
```powershell
# On Entra Connect server
Import-Module ADSync
Start-ADSyncSyncCycle -PolicyType Delta
```

</details>

<details id="fix-3"><summary>Fix 3 — PRT present but MFA claim missing</summary>

**Symptom:** `AzureAdPrt: YES`, device is healthy, but Conditional Access policies requiring MFA still prompt the user, or user is blocked by a CA policy requiring `mfa` claim in the token.

This happens when:
- The PRT was acquired without MFA (e.g., user signed in with just password)
- The PRT's MFA claim has expired (MFA claim lifetime is shorter than the PRT itself)
- CA policy requires a fresh MFA claim within a specific window

```powershell
# Check if MFA is registered for the user
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All"
$userId = (Get-MgUser -UserId "<upn>").Id
Get-MgUserAuthenticationMethod -UserId $userId | Select-Object Id, AdditionalProperties
# Should show registered methods: MicrosoftAuthenticator, PhoneAuthenticationMethod, etc.
```

**Fix — force fresh MFA to populate MFA claim in PRT:**
1. User signs out of all sessions: **Entra portal** → **Users** → user → **Revoke sessions**
2. User signs back in — they will be prompted for MFA
3. After successful MFA + sign-in, the new PRT will carry the MFA claim
4. Verify with `dsregcmd /status` — the `AzureAdPrtExpiryTime` will be refreshed

**If CA policy requires MFA every N hours (Authentication Context / session control):**
- This is by design — the policy's `Sign-in frequency` or `Persistent browser session` controls this
- Check the specific CA policy: **Entra portal** → **Security** → **Conditional Access** → select policy → **Session controls**
- If the frequency is too aggressive for the business use case, that is a CA policy design conversation, not a device fix

</details>

<details id="fix-4"><summary>Fix 4 — Proxy or SSL inspection blocking PRT refresh</summary>

**Symptom:** `AzureAdPrt: NO` persists. Connectivity test to `device.login.microsoftonline.com` fails or shows a certificate issued by the proxy CA rather than Microsoft.

```powershell
# Check what certificate is actually being presented
# Run from affected device
$url = "https://device.login.microsoftonline.com"
$request = [System.Net.HttpWebRequest]::Create($url)
$request.AllowAutoRedirect = $false
try { $response = $request.GetResponse() } catch {}
$cert = $request.ServicePoint.Certificate
if ($cert) {
    Write-Host "Certificate Subject:  $($cert.Subject)"
    Write-Host "Certificate Issuer:   $($cert.Issuer)"
    Write-Host "Certificate Expiry:   $($cert.GetExpirationDateString())"
    # If Issuer is your proxy CA (e.g., "Forcepoint", "Zscaler", "Palo Alto") → SSL inspection is the problem
} else {
    Write-Host "No certificate retrieved — endpoint may be blocked entirely" -ForegroundColor Red
}

# Check WinHTTP proxy settings (used by SYSTEM-context operations)
netsh winhttp show proxy
```

**Fix — add proxy bypass for token and device registration endpoints:**

Endpoints that must NOT be SSL-inspected (add as bypass on proxy appliance AND as WinHTTP bypass):
```
device.login.microsoftonline.com
login.microsoftonline.com
*.login.microsoftonline.com
enterpriseregistration.windows.net
*.microsoftonline.com
```

```powershell
# Set WinHTTP proxy with bypass (deploy via GPO for all devices)
netsh winhttp set proxy proxy-server="<proxyip>:<port>" `
    bypass-list="*.microsoftonline.com;device.login.microsoftonline.com;enterpriseregistration.windows.net"

# Verify
netsh winhttp show proxy

# Force PRT refresh after proxy fix
dsregcmd /refreshprt
Start-Sleep -Seconds 60
dsregcmd /status | Select-String "AzureAdPrt|AzureAdPrtUpdateTime"
```

</details>

<details id="fix-5"><summary>Fix 5 — Password change invalidated PRT</summary>

**Symptom:** User changed their password, and immediately afterward SSO breaks. `AzureAdPrtUpdateTime` timestamp is before the password change.

This is expected behaviour — password changes invalidate the existing PRT. The new PRT is issued on the next interactive authentication.

```powershell
# Resolution: user must sign in interactively with new password
# Lock/unlock forces this for domain-joined devices:
# Win+L → enter new password → unlock
# WAM will detect password change, acquire new PRT automatically

# If the device is hybrid-joined, also ensure on-prem password change
# has replicated to the DC the device is authenticating against:
nltest /dsgetdc:<domain> /force
# Then run:
dsregcmd /refreshprt
```

> If the user changed their password on a different device or via the web portal, and this device still has cached old credentials in Credential Manager, clear them:
```powershell
# Clear cached credentials (user context)
cmdkey /list | Where-Object { $_ -match "microsoftonline|microsoft" } | ForEach-Object {
    if ($_ -match "Target: (.+)") {
        cmdkey /delete:$Matches[1]
    }
}
```

</details>

---

## Interaction with Conditional Access

CA policies evaluate claims carried in the access token, which are derived from the PRT. Understanding what CA checks prevents wasted time re-registering devices when the real issue is a CA policy configuration.

| CA condition | Where the claim comes from | What breaks it |
|---|---|---|
| **Require compliant device** | Intune compliance state, synced to Entra | Device not enrolled in Intune, or compliance policy not assigned |
| **Require Hybrid AD Joined device** | `TrustType: ServerAd` in the device token claim | Device not HAADJ, or `AzureAdJoined: NO` |
| **Require MFA** | MFA claim in the PRT (set when user completes MFA) | PRT acquired without MFA, or MFA claim expired |
| **Require approved app / app protection policy** | App-level claim from Intune MAM | App not managed by Intune, or no MAM policy |
| **Sign-in risk: none** | Identity Protection risk score | Risky sign-in detected — must dismiss the risk in Identity Protection |
| **Named location** | IP address of the sign-in | Device on unexpected network, VPN not in named locations |

```powershell
# Check what CA policies are applying to a failed sign-in
# In Entra portal: Sign-in logs → select the failed event → Conditional Access tab
# Shows: policy name, result (Success/Failure/Not applied), grant controls required

# Or via Graph:
Connect-MgGraph -Scopes "AuditLog.Read.All"
$signIn = Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<upn>'" -Top 5 |
    Where-Object { $_.ConditionalAccessStatus -ne "success" }
$signIn | ForEach-Object {
    $_.AppliedConditionalAccessPolicies | Where-Object { $_.Result -ne "success" } |
        Select-Object DisplayName, Result, GrantControlsOperator,
            @{N="Controls";E={$_.EnforcedGrantControls -join ", "}}
}
```

---

## Escalation Evidence

```
PRT Issue — Evidence Pack
====================================
Affected user UPN:        
Device name:              
Device OS version:        
Join type:                [Hybrid / Entra / Registered]
Domain:                   
Tenant:                   

dsregcmd /status output (key fields):
  AzureAdJoined:          [YES / NO]
  DomainJoined:           [YES / NO]
  AzureAdPrt:             [YES / NO]
  AzureAdPrtUpdateTime:   [timestamp]
  AzureAdPrtExpiryTime:   [timestamp]
  AzureAdPrtAuthority:    
  EnterprisePrt:          [YES / NO / N/A]

Device cert present:      [YES / NO — see Step 3]
Device cert expiry:       
Clock offset:             [w32tm output]
Token endpoint reachable: [YES / NO — see Step 5]
Proxy type:               [Zscaler / Forcepoint / other / none]
SSL inspection active:    [YES / NO]

Entra sign-in log errors:
  Error code:             
  Failure reason:         
  CA policy blocking:     [policy name + required control]

Symptoms:
  User prompted for auth: [Yes — frequency]
  Apps affected:          [all / specific apps]
  Symptom started:        
  Password change recent: [Yes / No / Unknown]

Steps already tried:
```

---

## 🎓 Learning Pointers

- **The PRT is not the same as an access token or a refresh token.** An access token is short-lived (1 hour, app-specific). A refresh token is app-specific, user-specific, can be revoked. A PRT is device-AND-user-specific, long-lived (14 days), and is used by WAM to obtain all other tokens silently. Conflating these leads to wrong diagnoses — someone saying "the token expired" might mean any of the three. Always confirm which token is the subject. [MS Docs: What is a PRT?](https://learn.microsoft.com/en-us/entra/identity/devices/concept-primary-refresh-token)

- **WAM (Web Account Manager) is the invisible broker.** Modern auth on Windows doesn't go app-to-Entra directly — it goes app-to-WAM-to-Entra. WAM caches the PRT in lsass.exe and handles all token requests invisibly. When SSO breaks, WAM is almost always involved. The `dsregcmd /status` PRT section is your window into WAM's state. Understanding WAM is what separates engineers who solve auth issues from those who randomly re-join devices.

- **PRT has an MFA claim, but it doesn't last forever.** The MFA claim in the PRT has its own lifetime, separate from the PRT itself. CA policies with Authentication Context or sign-in frequency controls can require a fresh MFA claim even when the PRT is valid. This is by design for high-sensitivity resources (finance apps, admin portals). Don't fight it — understand what the policy is protecting and set appropriate frequency.

- **`dsregcmd /refreshprt` vs `dsregcmd /leave` — use the right tool.** `/refreshprt` asks WAM to refresh the existing PRT without changing device registration. It is non-destructive and the right first tool. `/leave` removes the device from Entra and requires full re-registration — it is a last resort and will trigger MDM re-enrollment. Many engineers jump to `/leave` when `/refreshprt` would have been sufficient.

- **Token lifetime policies are being deprecated in favour of CA session controls.** The older `New-AzureADPolicy -Type TokenLifetimePolicy` approach is legacy. Modern token lifetime control is done through CA → Session controls → Sign-in frequency. If you encounter token lifetime policies in an older tenant, flag them as tech debt. [MS Docs: Token lifetimes](https://learn.microsoft.com/en-us/entra/identity-platform/configurable-token-lifetimes)

- **PRT failures in hybrid environments often have a Kerberos component.** On Hybrid Entra Joined devices, the PRT is partially backed by a Kerberos TGT from the on-prem DC. If Kerberos breaks (DC unreachable, clock skew, trust issues), the PRT can fail to refresh even though Entra connectivity is fine. `klist` on the affected device shows current Kerberos tickets — missing DC tickets are a signal.
