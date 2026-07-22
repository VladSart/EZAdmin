# Kerberos Delegation — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session with the `ActiveDirectory` module (DC or RSAT host):

```powershell
# 1. What delegation is configured on the front-end service account/computer causing the ticket?
Get-ADUser <serviceAccountSam> -Properties TrustedForDelegation, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo, PrincipalsAllowedToDelegateToAccount |
  Select-Object Name, TrustedForDelegation, TrustedToAuthForDelegation, 'msDS-AllowedToDelegateTo'
# For a computer account instead of a service account, swap Get-ADUser for Get-ADComputer

# 2. Is the target/backend account exempt from being delegated (sensitive account or Protected Users)?
Get-ADUser <targetUserSam> -Properties AccountNotDelegated, MemberOf |
  Select-Object Name, AccountNotDelegated, @{N='ProtectedUsers';E={$_.MemberOf -match 'Protected Users'}}

# 3. Is RBCD configured on the resource (backend) side instead of/alongside classic constrained delegation?
Get-ADComputer <backendServerSam> -Properties PrincipalsAllowedToDelegateToAccount |
  Select-Object Name, PrincipalsAllowedToDelegateToAccount

# 4. Recent Kerberos delegation-relevant failures on the front-end server (System/Security logs)
Get-WinEvent -FilterHashtable @{LogName='System'; Id=4,6,7} -MaxEvents 10 -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match 'KDC_ERR|KRB_AP_ERR|delegat' } | Select-Object TimeCreated, Message

# 5. Confirm the exact SPN the backend call is targeting exists and matches what's authorized
setspn -L <backendServiceAccountSam>
```

| What you see | What it means |
|---|---|
| `TrustedForDelegation = True` and `msDS-AllowedToDelegateTo` is empty | This account has **unconstrained delegation** — it can impersonate any user to any service domain-wide. Do not "fix forward" by adding more here; this is a standing security risk regardless of what ticket you're chasing — go to Fix 4 |
| `TrustedToAuthForDelegation = True` with a populated `msDS-AllowedToDelegateTo` | Classic (constrained) delegation with protocol transition — confirm the exact SPN string in the list matches the backend service SPN exactly (host+port/instance matters for SQL) — go to Fix 1 |
| Front-end account's delegation looks fine, but `PrincipalsAllowedToDelegateToAccount` on the **backend** computer doesn't list the front-end's SID | Resource-based constrained delegation (RBCD) is expected but not configured on the resource side — go to Fix 2 |
| Target user has `AccountNotDelegated = True` or is a member of **Protected Users** | Delegation is being correctly and intentionally blocked by design — this is not a bug to route around; the app must use a different auth path for this specific account (see Fix 3) |
| App works when accessed directly on the server but fails with "access denied" only when accessed through a front-end (web app, RDS, proxy) | Classic **double-hop problem** — the front-end has no delegation configured at all yet, or it's configured for the wrong SPN — go to Fix 1 or Fix 2 depending on target architecture |
| `KDC_ERR_BADOPTION` in a captured Kerberos trace/event | KDC flatly refused to delegate — almost always a sensitive/Protected-Users account, or delegation not authorized at all for this front-end→backend pair |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
User authenticates to the front-end service (web app, RDS session host, app-tier server)
  └── Front-end service account/computer object must itself be authorized to delegate
        ├── Unconstrained: TrustedForDelegation = True (userAccountControl TRUSTED_FOR_DELEGATION)
        │     └── Front-end caches the user's forwarded TGT — can impersonate to ANY service
        ├── Constrained (KCD): TrustedToAuthForDelegation (S4U2Self) + msDS-AllowedToDelegateTo
        │     lists exact target SPN(s) — front-end can only impersonate TO those services
        │     └── Same domain only (classic constrained delegation does not cross domain boundaries)
        └── Resource-Based (RBCD): backend's msDS-AllowedToActOnBehalfOfOtherIdentity
              (PrincipalsAllowedToDelegateToAccount) lists the front-end's SID
              └── Configured by the RESOURCE owner, not the front-end's domain admin
                    └── Works cross-domain / cross-forest-trust within the same forest
  └── Target/impersonated user account must NOT be exempt
        ├── userAccountControl NOT_DELEGATED ("Account is sensitive and cannot be delegated") — blocks it
        └── Member of Protected Users group — blocks ALL delegation + disables NTLM + caps ticket lifetime
  └── Exact SPN match between what's authorized and what's requested
        └── Missing/mismatched SPN (wrong host, missing port/instance) = S4U2Proxy failure, not a
            permission failure — looks identical to a misconfigured delegation from the outside
```

Key failure points:
- Unconstrained delegation is frequently found still configured on legacy IIS/SQL servers from environments migrated forward for a decade — it's rarely the *cause* of today's ticket, but it's always worth flagging when found, since it's a standing lateral-movement risk independent of the symptom you're chasing
- `msDS-AllowedToDelegateTo` requires the **exact** SPN string, including the correct host and, for SQL Server named instances, the correct port/instance-qualified SPN — a partial or host-only match fails silently from the app's point of view
- RBCD is configured on the **target/backend** object, which means the team troubleshooting the front-end app frequently doesn't have rights to see or fix it — this is the single most common cause of "we configured delegation and it still doesn't work"
- A service account password reset does not itself break delegation configuration, but rotating from a standard service account to a gMSA does change the SID the delegation ACL needs to reference — re-verify after any account-type migration

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm which delegation model is actually configured on the front-end**
```powershell
Get-ADUser <serviceAccountSam> -Properties TrustedForDelegation, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo |
  Format-List
```
Expected: exactly one model in use — `TrustedForDelegation=True` with nothing else (unconstrained), or `TrustedToAuthForDelegation` + a populated `msDS-AllowedToDelegateTo` list (constrained). If both patterns are absent, delegation isn't configured on the front-end side at all.

**Step 2 — Confirm the target user isn't exempt**
```powershell
Get-ADUser <targetUserSam> -Properties AccountNotDelegated, MemberOf |
  Select-Object Name, AccountNotDelegated, @{N='InProtectedUsers';E={($_.MemberOf | Where-Object {$_ -match 'Protected Users'}) -ne $null}}
```
Expected: both `False`/empty for accounts that should be delegable. `True`/membership present on a normal (non-Tier-0) account is itself worth investigating — someone deliberately hardened this account.

**Step 3 — Confirm SPN registration and exact match on the backend**
```powershell
setspn -L <backendServiceAccountSam>
# Compare each entry character-for-character against the front-end's msDS-AllowedToDelegateTo list
```
Expected: an exact string match. For SQL Server, confirm the SPN includes the correct port for named instances (`MSSQLSvc/sqlhost.domain.com:1433` vs. `MSSQLSvc/sqlhost.domain.com:InstanceName`).

**Step 4 — Check for RBCD on the resource side if classic delegation checks out clean**
```powershell
Get-ADComputer <backendServerSam> -Properties PrincipalsAllowedToDelegateToAccount |
  Select-Object -ExpandProperty PrincipalsAllowedToDelegateToAccount
```
Expected: if using RBCD, the front-end's computer/service SID appears here. Empty/absent means RBCD isn't authorizing this front-end regardless of what's configured on the front-end object itself.

**Step 5 — Reproduce and capture the exact Kerberos error**
```powershell
klist tickets   # on the front-end server, after reproducing the failure, to see what tickets it actually holds
```
Expected: a service ticket for the backend SPN if delegation succeeded; its absence, or an error captured in a network trace (`KRB_AP_ERR_MODIFIED`, `KDC_ERR_BADOPTION`, `KDC_ERR_S_PRINCIPAL_UNKNOWN`), pinpoints which stage failed.

---
## Common Fix Paths

<details><summary>Fix 1 — Classic constrained delegation (KCD) SPN mismatch or missing entry</summary>

**Cause:** `msDS-AllowedToDelegateTo` on the front-end account doesn't contain the exact SPN the backend call is targeting, or the front-end isn't authorized for constrained delegation at all.

```powershell
# View current authorized targets
Get-ADUser <serviceAccountSam> -Properties msDS-AllowedToDelegateTo | Select-Object -ExpandProperty msDS-AllowedToDelegateTo

# Add the missing target SPN (use the exact SPN from setspn -L on the backend)
Set-ADUser <serviceAccountSam> -Add @{'msDS-AllowedToDelegateTo' = 'MSSQLSvc/sqlhost.domain.com:1433'}

# Ensure protocol transition is enabled if the front-end needs to impersonate WITHOUT the user's
# Kerberos ticket in hand (e.g. authenticated the user via forms/cert auth, not Kerberos) —
# this is the "Use any authentication protocol" radio button in ADUC's Delegation tab
Set-ADAccountControl <serviceAccountSam> -TrustedToAuthenticateForDelegation $true
```

**Rollback note:** Removing an SPN from `msDS-AllowedToDelegateTo` immediately revokes that specific delegation path — safe to do if added in error; confirm no production dependency first.

</details>

<details><summary>Fix 2 — Resource-based constrained delegation (RBCD) not configured on the backend</summary>

**Cause:** The front-end is correctly set up, but the backend resource hasn't authorized it via `PrincipalsAllowedToDelegateToAccount`. This is configured by whoever owns the **backend** object, which is often a different team.

```powershell
# Grant the front-end's computer/service account permission to delegate to this backend
Set-ADComputer <backendServerSam> -PrincipalsAllowedToDelegateToAccount <frontEndComputerOrServiceSam>

# Verify
Get-ADComputer <backendServerSam> -Properties PrincipalsAllowedToDelegateToAccount |
  Select-Object -ExpandProperty PrincipalsAllowedToDelegateToAccount
```

**Rollback note:** `Set-ADComputer -PrincipalsAllowedToDelegateToAccount $null` clears the list entirely. To remove a single principal without clearing everyone else, use `Set-ADComputer -Remove` against the underlying `msDS-AllowedToActOnBehalfOfOtherIdentity` security descriptor instead of a blind overwrite.

</details>

<details><summary>Fix 3 — Target user is intentionally exempt (sensitive account / Protected Users)</summary>

**Cause:** The user being impersonated has `AccountNotDelegated` set, or is a member of Protected Users. This is working as designed — these controls exist specifically to prevent privileged/Tier-0 accounts from being delegated.

```powershell
# Confirm this is the actual blocker (do NOT remove the protection to "fix" the ticket)
Get-ADUser <targetUserSam> -Properties AccountNotDelegated, MemberOf

# The correct remediation is an architecture change, not removing the protection:
#  - The app/service should not need to impersonate a Tier-0/privileged account through a
#    delegation chain at all — re-scope what account the operation runs as
#  - If genuinely required, use a lower-privileged proxy account for the delegated operation
#    instead of the protected identity
```

**Rollback note:** N/A — removing `AccountNotDelegated` or Protected Users membership from a privileged account to unblock an app is a security regression, not a fix. Escalate for an architecture review instead.

</details>

<details><summary>Fix 4 — Unconstrained delegation found on a server (standing risk, not necessarily today's cause)</summary>

**Cause:** `TrustedForDelegation = True` with no scoped `msDS-AllowedToDelegateTo`. Any user who authenticates to this server has their TGT cached in memory on it — compromise of this server is effectively compromise of every account that has ever logged into it via Kerberos.

```powershell
# Identify scope of impact before changing anything — do not flip this in production without a
# migration plan, since removing it breaks whatever currently relies on it
Get-ADUser <serviceAccountSam> -Properties TrustedForDelegation

# Migration path: move to constrained delegation with an explicit SPN list scoped to only the
# services this account actually needs to reach
Set-ADAccountControl <serviceAccountSam> -TrustedForDelegation $false
Set-ADUser <serviceAccountSam> -Add @{'msDS-AllowedToDelegateTo' = 'HTTP/backend.domain.com'}
Set-ADAccountControl <serviceAccountSam> -TrustedToAuthenticateForDelegation $true
```

**Rollback note:** Disabling unconstrained delegation without first configuring the replacement constrained/RBCD path will break the dependent application immediately — stage the constrained delegation config first, validate, then disable unconstrained. Track this as a planned hardening change, not an emergency toggle.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Kerberos Delegation Issue

Front-end server/service account: ____________
Backend/target server + SPN: ____________
Delegation model configured on front-end (None/Unconstrained/Constrained/RBCD): ____________
msDS-AllowedToDelegateTo contents (if constrained): ____________
PrincipalsAllowedToDelegateToAccount on backend (if RBCD): ____________
Target/impersonated user — AccountNotDelegated or Protected Users member (Yes/No): ____________
Exact error captured (KRB_AP_ERR_MODIFIED / KDC_ERR_BADOPTION / other): ____________
Works when accessed directly on backend, fails only via front-end (double-hop pattern) (Yes/No): ____________

Steps already attempted:
[ ] Confirmed delegation model and exact configured targets on the front-end
[ ] Confirmed SPN registration and exact string match on the backend
[ ] Checked RBCD (PrincipalsAllowedToDelegateToAccount) on the backend object
[ ] Confirmed target user isn't sensitive/Protected Users
[ ] Captured klist/network trace evidence of the specific failure stage
```

---
## 🎓 Learning Pointers

- **RBCD is configured on the resource, classic constrained delegation is configured on the front-end** — troubleshooting the wrong side of the relationship is the single most common time-waster here. Always ask which team owns which object before assuming a config is missing.
- **`AccountNotDelegated` and Protected Users membership are not bugs to route around.** They're the two intentional controls that prevent privileged accounts from being caught up in a delegation chain at all — treat a delegation failure against a protected account as a signal the architecture needs to change, not the config.
- **Unconstrained delegation is a standing lateral-movement risk independent of any specific ticket.** If you find it while chasing something else, flag it for migration to constrained/RBCD even if it isn't the cause of today's issue.
- **SPN mismatches fail silently from the application's perspective** — a missing port/instance qualifier on a SQL Server SPN produces the same "access denied" symptom as no delegation being configured at all. Always diff the exact SPN string, don't eyeball it.
- Related: [Kerberos Constrained Delegation overview (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-constrained-delegation-overview), [Configure Kerberos delegation for gMSAs](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/group-managed-service-accounts/group-managed-service-accounts/configure-kerberos-delegation-group-managed-service-accounts), [Protected Users security group](https://learn.microsoft.com/en-us/windows-server/security/credentials-protection-and-management/protected-users-security-group)
