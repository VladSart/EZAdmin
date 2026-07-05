# Entra Password Protection & Smart Lockout — Hotfix Runbook (Mode B: Ops)
> Fix or escalate password ban / lockout complaints in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Two distinct complaint types land here: **"my new password keeps getting rejected"** (Password Protection / banned password list) and **"my account is locked out after a few tries"** (Smart Lockout). Diagnose which one first.

```powershell
Connect-MgGraph -Scopes "Directory.Read.All","AuditLog.Read.All" -NoWelcome

$UPN = "<user@domain.com>"

# 1. Confirm whether the account is currently locked
Get-MgUser -UserId $UPN -Property "accountEnabled" | Select-Object AccountEnabled

# 2. Check recent sign-in failures and error codes
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UPN'" -Top 20 |
    Select-Object CreatedDateTime, @{N="ErrorCode";E={$_.Status.ErrorCode}}, @{N="Reason";E={$_.Status.FailureReason}}

# 3. Tenant-level password protection mode (Enforced vs Audit)
# Portal only: Entra ID > Security > Authentication methods > Password protection
# (No direct Graph cmdlet exposes this setting as of 2026 — portal is authoritative)

# 4. Is on-prem Password Protection Proxy healthy? (only relevant if hybrid + password writeback / on-prem enforcement in use)
Get-Service AzureADPasswordProtectionProxy, AzureADPasswordProtectionDCAgent -ErrorAction SilentlyContinue |
    Select-Object Name, Status
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| Sign-in error `50053` | Account locked by Smart Lockout → Fix 1 |
| Sign-in error `50057` | Account disabled by admin — not a lockout issue, different runbook |
| Password change/reset rejected with "doesn't meet complexity/banned list" | Password Protection banned list match → Fix 2 |
| On-prem `AzureADPasswordProtectionDCAgent` service stopped on a DC | On-prem enforcement is silently not happening → Fix 3 |
| User locked out repeatedly from one specific device/app | Cached/stale credential retry storm, not a real lockout each time → Fix 4 |
| Password reset succeeds in cloud but on-prem AD still has old password (hybrid) | Password writeback misconfigured or failing → Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true for password protection & smart lockout to work correctly</summary>

```
Entra ID tenant (Password Protection + Smart Lockout are on by default, cloud-only, no license required for baseline)
  │
  ├── Smart Lockout
  │     └── Lockout threshold + duration (default: 10 attempts, 60s duration, tunable in Authentication Methods policy)
  │           └── Familiar location vs unfamiliar location tracked separately (unfamiliar locations get stricter counting)
  │                 └── Threshold exceeded → account temporarily locked (self-clears after duration, no admin action required)
  │
  └── Password Protection (banned password lists)
        └── Global banned password list (Microsoft-maintained, always on, cannot be disabled)
              └── Custom banned password list (tenant-defined, admin-maintained, cloud-only baseline)
                    └── Fuzzy matching engine (catches leetspeak substitutions, e.g. "P@ssw0rd" blocked if "password" is banned)
                          └── [HYBRID ONLY] On-prem enforcement extension
                                ├── Requires: Azure AD Password Protection Proxy service (one or more, domain-joined)
                                ├── Requires: Azure AD Password Protection DC Agent (installed on EVERY writable DC)
                                └── Mode: Audit (log only) or Enforced (actually block on-prem password changes)
                                      └── DC Agent caches the policy locally — works even if proxy/cloud is briefly unreachable
```

**Key interlock:** In hybrid environments, the cloud banned-password policy does nothing to on-prem password changes (e.g., Ctrl+Alt+Del password change while domain-joined) unless the DC Agent is installed on every writable DC and the Proxy is healthy. A password can be perfectly compliant with cloud policy and still be set on-prem using an old, non-compliant local policy if the agent was never deployed.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm this is Smart Lockout, not a disabled/blocked account**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 10 |
    Select-Object CreatedDateTime, @{N="ErrorCode";E={$_.Status.ErrorCode}}, @{N="Reason";E={$_.Status.FailureReason}}
```
*Good (expected lockout):* Error `50053` with reason mentioning account lockout, following a burst of `50126` (invalid credentials) attempts.
*Bad / different issue:* Error `50057` (account disabled) or `50055` (password expired) — these are not lockout and need a different fix path.

---

**Step 2 — Check current lockout policy values**
Portal: `Entra ID → Security → Authentication methods → Password protection` (baseline values shown, no Graph API surface for reading current threshold/duration as of 2026).
Defaults: Lockout threshold = 10, Lockout duration = 60 seconds, doubling on repeated lockouts up to a cap. Confirm nobody has set the threshold unusually low (some tenants over-tighten this trying to stop brute force and end up locking normal users on typo bursts).

---

**Step 3 — Reproduce the exact banned-password rejection**
Ask the user for the exact password they tried (never store it) — or have them attempt it while you watch the on-screen error. Cloud rejection message specifically references Microsoft's password policy; a generic "password does not meet requirements" may instead be an on-prem AD complexity policy conflict, not Entra Password Protection.

---

**Step 4 — For hybrid tenants: confirm on-prem agent health**
```powershell
# Run on each writable Domain Controller
Get-Service AzureADPasswordProtectionDCAgent | Select-Object Name, Status, StartType

# Run on the Proxy server(s)
Get-Service AzureADPasswordProtectionProxy | Select-Object Name, Status, StartType

# Check DC Agent event log for policy download success
Get-WinEvent -LogName "Microsoft-AzureADPasswordProtection-DCAgent/Admin" -MaxEvents 20 |
    Select-Object TimeCreated, Id, Message
```
*Good:* Both services `Running`; DC Agent event log shows recent successful policy downloads (event ID 30002 or similar "retrieved password policy" entries).
*Bad:* Service stopped, or DC Agent hasn't successfully retrieved a policy update in days — on-prem enforcement is effectively stale or off.

---

**Step 5 — For hybrid password writeback complaints**
```powershell
# Confirm writeback is enabled at the tenant level (requires Entra Connect config, not just a Graph read)
# On the Entra Connect server:
Get-ADSyncAADPasswordSyncConfiguration -All  # returns password hash sync state, not writeback directly

# Better: check Entra Connect Health / Synchronization Service Manager for password writeback errors
# Portal: Entra Connect Health > Sync errors, filter for password writeback failures
```
*Good:* No writeback errors correlated with the user's timestamp.
*Bad:* Writeback error logged at the same time the user attempted a cloud-initiated reset — password changed in the cloud but never landed on-prem.

---

## Common Fix Paths

<details><summary>Fix 1 — Smart Lockout: confirm self-clearing, don't manually unlock unnecessarily</summary>

**Cause:** Smart Lockout is working as designed — the account will self-unlock after the lockout duration with no admin action needed. The most common mistake is admins manually resetting the password or disabling/re-enabling the account, which doesn't speed anything up and adds unnecessary change.

```powershell
# Confirm the lockout has already cleared naturally (check sign-ins after the lockout duration window)
$UPN = "<user@domain.com>"
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UPN'" -Top 5 |
    Select-Object CreatedDateTime, @{N="ErrorCode";E={$_.Status.ErrorCode}}
```
If repeated lockouts are happening frequently for the same user, look for a stale credential retry storm (Fix 4) rather than treating each lockout as a one-off.

**Rollback:** N/A — no destructive action taken.

</details>

<details><summary>Fix 2 — Adjust or clarify the custom banned password list</summary>

**Cause:** A legitimate business term (company name, product name, local sports team) is unintentionally being caught by fuzzy matching against the custom banned list, or the custom list is missing an obviously weak term that should be banned.

Portal-only (no Graph write API for custom banned passwords as of 2026):
`Entra ID → Security → Authentication methods → Password protection → Custom banned password list`

- To relax: remove overly broad terms causing false-positive rejections for legitimate passwords
- To tighten: add company name, product names, local terms attackers would guess first
- Test change: have the affected user retry password creation in Audit mode first if unsure of impact tenant-wide

**Rollback:** Remove/re-add the specific term changed; changes take effect within roughly 1 hour tenant-wide.

</details>

<details><summary>Fix 3 — Repair on-prem Password Protection Proxy / DC Agent</summary>

**Cause:** DC Agent or Proxy service stopped or was never installed on a newer DC, so on-prem password changes aren't being checked against the cloud policy.

```powershell
# On the affected DC — restart the agent service
Restart-Service AzureADPasswordProtectionDCAgent

# On the Proxy server — restart the proxy service
Restart-Service AzureADPasswordProtectionProxy

# If the DC Agent was never installed on a newly promoted DC, install it:
# (Run the AzureADPasswordProtectionDCAgentSetup.msi from the DC Agent install package)
# Then force a policy refresh:
Get-Service AzureADPasswordProtectionDCAgent | Restart-Service
```

Verify recovery:
```powershell
Get-WinEvent -LogName "Microsoft-AzureADPasswordProtection-DCAgent/Admin" -MaxEvents 5
```

**Rollback:** N/A — restarting a service is non-destructive. If newly installing an agent, uninstalling reverts the DC to unprotected (not recommended).

</details>

<details><summary>Fix 4 — Break a stale credential retry storm</summary>

**Cause:** A device, mapped drive, scheduled task, or mobile app (commonly Outlook mobile or a mapped network drive) is silently retrying an old cached password hundreds of times, repeatedly tripping Smart Lockout even after the user manually resets their password correctly.

```powershell
# Identify the source app/device from sign-in logs — look at the ResourceDisplayName and AppDisplayName
# across the burst of 50126 failures immediately preceding the lockout
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 50 |
    Where-Object { $_.Status.ErrorCode -eq 50126 } |
    Select-Object CreatedDateTime, AppDisplayName, ResourceDisplayName, IpAddress, DeviceDetail
```

Common culprits: old mapped drive with saved credentials, Outlook mobile profile not re-prompted after password change, a scheduled task running under the user's old password, IoT/multi-function printer with saved SMTP creds.

Once identified, have the user update/remove the cached credential (Windows Credential Manager, Outlook mobile re-auth, printer scan-to-email config) rather than repeatedly resetting the password, which does not fix a stale-credential source.

**Rollback:** N/A — this is credential hygiene, not a destructive change.

</details>

<details><summary>Fix 5 — Repair password writeback failure (hybrid)</summary>

**Cause:** Password writeback is enabled in Entra Connect but failing for this user — often due to an on-prem AD password policy conflict (cloud accepted the password, on-prem complexity/history policy rejected the writeback) or the user's on-prem account being disabled/locked independently.

```powershell
# On the Entra Connect server — check writeback-specific sync errors
# Portal: Entra Connect Health > Sync Errors > filter type = Password writeback

# Confirm on-prem account isn't independently locked (run against on-prem AD, not Entra)
Get-ADUser -Identity "<sAMAccountName>" -Properties LockedOut, PasswordExpired, Enabled
```
If the on-prem account is locked/disabled independently of Entra, unlock on-prem first:
```powershell
Unlock-ADAccount -Identity "<sAMAccountName>"
```
If it's a complexity policy conflict, have the user choose a password satisfying both cloud AND on-prem policy requirements (the stricter of the two effectively governs).

**Rollback:** N/A — unlocking an account is not destructive.

</details>

---

## Escalation Evidence

```
=== PASSWORD PROTECTION / LOCKOUT ISSUE ESCALATION ===
Date/Time (UTC):                    ____________________
Reported by:                        ____________________
Affected user UPN:                  ____________________
Tenant ID:                          ____________________
Issue type:                         SMART LOCKOUT / BANNED PASSWORD / WRITEBACK FAILURE
Hybrid environment:                 YES / NO

=== CHECKS COMPLETED ===
[ ] Sign-in log error code identified:      ____________________
[ ] Account currently locked/disabled:      YES / NO
[ ] Lockout threshold/duration confirmed:   ____________________
[ ] On-prem DC Agent/Proxy service status:  ____________________ (if hybrid)
[ ] Retry-storm source identified:          YES / NO — source: ____________________
[ ] Writeback error correlated:             YES / NO (if hybrid)

=== ACTIONS TAKEN ===
[ ] Waited for Smart Lockout self-clear:    YES / NO
[ ] Adjusted custom banned password list:   YES / NO — term: ____________________
[ ] Restarted DC Agent/Proxy service:       YES / NO
[ ] Identified and removed stale credential source: YES / NO
[ ] Unlocked on-prem AD account:            YES / NO

=== ESCALATION PATH ===
If lockouts persist after 4+ hours with all checks clean:
- Open a case via https://admin.microsoft.com
- Provide: UPN, Tenant ID, sign-in log Correlation IDs for 3-5 recent failures, DC Agent event log export (if hybrid)
```

---

## 🎓 Learning Pointers

- **Smart Lockout is self-healing by design — don't "fix" it with unnecessary admin actions.** Manually disabling/re-enabling the account or force-resetting the password doesn't shorten the lockout window and adds noise to the audit trail. Confirm the error code is genuinely `50053` before taking any action at all. [MS Docs: Smart Lockout](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-password-smart-lockout)
- **The global banned password list cannot be turned off, and it uses fuzzy/leetspeak matching.** Users are frequently confused when "P@ssw0rd123" is rejected — it's not literal string matching, so explaining the substitution logic helps set expectations for password choices going forward. [MS Docs: Password Protection overview](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-password-ban-bad-overview)
- **On-prem enforcement requires an agent on every writable DC — missing even one is a silent policy gap.** A newly promoted DC or a DC rebuilt from a backup can easily be missed during agent rollout. Include DC Agent installation in every DC build/promotion checklist, not just the initial hybrid setup. [MS Docs: Deploy password protection on-premises](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-password-ban-bad-on-premises-deploy)
- **Repeated lockouts for the same user are almost always a stale-credential retry storm, not repeated genuine mistyping.** Chasing the wrong root cause (assuming the user keeps mistyping) wastes time; check the sign-in log burst pattern and source app/device first. [MS Docs: Sign-in log error codes](https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes)
- **In hybrid tenants, password writeback failures can make a "successful" cloud password reset a trap.** The user believes their password is changed because the cloud portal confirmed it, but on-prem resources (file shares, VPN, RDP) still expect the old password until writeback completes — always check writeback health as part of any hybrid password reset ticket. [MS Docs: Password writeback](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sspr-writeback)
