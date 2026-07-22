# Kerberos Delegation — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- All three Kerberos delegation models: unconstrained, constrained (KCD, with and without protocol transition), and resource-based constrained delegation (RBCD)
- The S4U2Self / S4U2Proxy protocol extensions that make constrained delegation and RBCD possible
- The "double-hop" problem this entire feature exists to solve, and its correct architectural solutions
- Hardening controls that intentionally block delegation: `AccountNotDelegated` ("Account is sensitive and cannot be delegated") and the Protected Users security group
- Security posture guidance: identifying and migrating away from unconstrained delegation, auditing delegation ACLs domain-wide
- Cross-domain/cross-forest delegation boundaries and the specific limitations of each model

**Out of scope:**
- Constrained delegation configuration specifically for gMSAs/dMSAs — the mechanics are the same, but see `ActiveDirectory/Troubleshooting/gMSA/gMSA-A.md` and `dMSA/dMSA-A.md` for the managed-service-account-specific KDS root key and authorization model
- NTLM authentication and NTLM relay attacks — delegation is a Kerberos-only mechanism; the "double-hop" problem this topic solves is frequently *mistaken* for an NTLM issue, and the two are cross-referenced here but covered independently (see `Windows/Troubleshooting/NTLM-A.md`)
- Kerberos Armoring/FAST, LDAP signing/channel binding, and PetitPotam/NTLM-relay-to-AD-CS — related hardening topics with their own dedicated runbooks (see `ActiveDirectory/Troubleshooting/KerberosArmoring/`, `LDAPSigning/`, `Windows/Troubleshooting/NTLMRelayADCS-A.md`)
- General Kerberos ticket lifecycle, SPN management, and the base double-hop symptom walkthrough — see `Windows/Troubleshooting/Kerberos-A.md` for foundational Kerberos mechanics this topic builds on
- AD FS claims-based delegation and OAuth token-based delegation in cloud/hybrid apps — an architecturally different, non-Kerberos delegation model (see `ActiveDirectory/Troubleshooting/ADFS/ADFS-A.md` and `EntraID/Troubleshooting/WorkloadIdentity-A.md`)

**Assumptions:**
- Domain functional level supports the delegation model in question — RBCD requires Windows Server 2012 or later domain controllers (the feature is server-side, evaluated by the KDC, and does not depend on client OS version)
- You have delegated rights or Domain Admin/appropriate OU-delegated permissions to read/modify `userAccountControl` flags, `msDS-AllowedToDelegateTo`, and `msDS-AllowedToActOnBehalfOfOtherIdentity` on the relevant objects
- The `ActiveDirectory` PowerShell module is available on the host running diagnostics

---
## How It Works

<details><summary>Full architecture — why delegation exists and how the three models differ</summary>

### The Problem Delegation Solves: The Double Hop

Kerberos authentication, by design, is **not transitively forwardable** by default. When a user authenticates to a front-end service (a web app, a file server, an RDS session host), that service receives a service ticket proving the user's identity *to that service specifically*. If the front-end then needs to make a second, "second-hop" call to a backend resource (a SQL Server, a file share, another API) **as that same user**, it has no credential material to do so — the user's password isn't available to it, and the service ticket it holds is scoped only to itself, not re-usable against a different service. Without a solution, the second hop either fails outright (access denied against the backend, because the backend sees the front-end's own service identity, not the user's) or the application falls back to NTLM for the second hop, which has its own, weaker security properties and doesn't solve the underlying problem, it just papers over the symptom. Kerberos delegation exists specifically to let an administrator explicitly, deliberately authorize a front-end service to act on behalf of an already-authenticated user for a defined, scoped second hop.

### Model 1 — Unconstrained Delegation

The oldest and simplest model, set via the `userAccountControl` flag `TRUSTED_FOR_DELEGATION` (`0x80000`, and reflected in ADUC's "Trust this computer for delegation to any service (Kerberos only)" option). When a user authenticates to a front-end configured this way, the KDC includes the user's **entire TGT**, forwarded and cached in memory on the front-end server. The front-end can now request a service ticket to **any** service in the domain on behalf of that user, indefinitely, for as long as the cached TGT remains valid — there is no scoping to a specific backend at all.

This is architecturally the highest-risk model: compromise of a server with unconstrained delegation configured means an attacker can potentially extract every cached TGT for every user who has authenticated to it (a well-documented post-exploitation technique), effectively achieving domain-wide impersonation without needing those users' actual credentials. This is why unconstrained delegation is now considered legacy and its continued presence in an environment should be treated as a standing finding to remediate, independent of whatever specific ticket brought you to look at it.

### Model 2 — Constrained Delegation (KCD) via S4U2Self / S4U2Proxy

Introduced to scope delegation down to an explicit, administrator-defined list of backend services, constrained delegation relies on two Microsoft protocol extensions to the Kerberos specification:

- **S4U2Self ("Service for User to Self")** — allows a service to request a service ticket **to itself**, on behalf of a specified user, without needing that user's TGT or password. This solves the specific problem of a front-end that authenticated the user via a non-Kerberos mechanism (forms auth, client certificates, a custom auth scheme) and therefore never received a Kerberos ticket for the user in the first place, but still needs to delegate onward. This capability is gated by the `TrustedToAuthForDelegation` flag (`userAccountControl` `TRUSTED_TO_AUTH_FOR_DELEGATION`, `0x1000000`) — ADUC's "Use any authentication protocol" radio button. Without this flag, only "Use Kerberos only" delegation is possible, meaning the front-end must have received an actual Kerberos-authenticated ticket from the user to begin with.
- **S4U2Proxy ("Service for User to Proxy")** — takes the ticket obtained via S4U2Self (or a genuine Kerberos ticket the user presented) and exchanges it for a service ticket to a **specific backend SPN**, on the user's behalf. This is where the authorization boundary actually lives: the KDC checks the front-end account's `msDS-AllowedToDelegateTo` attribute, and only issues the S4U2Proxy ticket if the requested backend SPN is explicitly listed there.

Classic constrained delegation, configured this way, has one significant architectural boundary: **it is intra-domain only.** `msDS-AllowedToDelegateTo` on the front-end account can only authorize delegation to SPNs the domain's own KDC can resolve and vouch for — it does not work across a domain or forest trust boundary, even within the same forest, without the resource-based model below.

### Model 3 — Resource-Based Constrained Delegation (RBCD)

Introduced in Windows Server 2012, RBCD inverts where the authorization decision is made. Instead of the **front-end's** account declaring what it's allowed to delegate to, the **backend/resource's** account declares who is allowed to delegate to it, via the `msDS-AllowedToActOnBehalfOfOtherIdentity` attribute (surfaced in PowerShell as `PrincipalsAllowedToDelegateToAccount` — a security descriptor listing the front-end principal(s) authorized).

This inversion has two significant practical consequences:
1. **Authorization is granted by whoever owns the resource, not the front-end's domain/OU admin.** This is frequently the actual root cause when "we configured delegation and it still doesn't work" — the front-end-side configuration was correct, but nobody with rights over the backend object ever added the corresponding entry.
2. **RBCD works across domain boundaries within the same forest**, and — since the authorization decision is entirely local to the resource's own domain, evaluated by that domain's own KDC — it does not require the front-end's domain to trust the resource's domain in the traditional constrained-delegation sense. This makes RBCD the only practical delegation model for cross-domain multi-tier applications in a multi-domain forest.

RBCD does **not** require `TrustedToAuthForDelegation` on the front-end account the way classic constrained delegation does for protocol transition — the S4U2Self step, when needed, is authorized implicitly by the resource-side ACL rather than a front-end-side flag.

### The Two Deliberate Blocking Controls

Two independent, intentional mechanisms exist specifically to prevent an account from being delegated at all, regardless of what any front-end is authorized to do:

- **`AccountNotDelegated`** (`userAccountControl` flag `NOT_DELEGATED`, `0x100000` — ADUC's "Account is sensitive and cannot be delegated" checkbox). When set on the **target/impersonated user's** account, the KDC refuses to issue a forwardable TGT or honor any S4U2Proxy request naming that user, regardless of what the front-end or resource is authorized for. This is the standard, lightweight control for marking individual Tier-0/privileged accounts as non-delegable.
- **Protected Users security group.** A domain-level group whose members receive a bundle of hardening behaviors simultaneously: Kerberos delegation is blocked entirely (equivalent to and beyond `AccountNotDelegated`), NTLM authentication is disabled outright for the account, Kerberos ticket lifetimes are capped (typically 4 hours, non-renewable) forcing more frequent re-authentication, and DES/RC4 encryption types are disallowed. Because Protected Users disables the *fallback* to NTLM as well, an application that silently depended on NTLM as a workaround for a broken delegation chain will fail outright for a Protected Users member rather than degrading — this is intentional, and a common source of "it worked for everyone except this one admin account" tickets once an account is added to the group.

Both controls are evaluated by the KDC at ticket-request time and produce the same class of error (`KDC_ERR_BADOPTION` is common) regardless of how thoroughly the front-end/resource side is configured — there is no delegation-side workaround for either.

</details>

---
## Dependency Stack

```
User authentication event at the front-end service
  │
  ├── UNCONSTRAINED DELEGATION path
  │     TrustedForDelegation=True on front-end account/computer
  │       └── User's full TGT forwarded and cached in front-end's memory (LSASS)
  │             └── Front-end can request a service ticket to ANY SPN in the domain, at will,
  │                 for the cached TGT's remaining lifetime — no per-target authorization check
  │
  ├── CONSTRAINED DELEGATION (KCD) path
  │     Front-end holds either:
  │       ├── A genuine Kerberos ticket from the user (Kerberos-only auth), OR
  │       └── TrustedToAuthForDelegation=True → S4U2Self ticket obtained without user's TGT
  │             (needed when front-end authenticated the user via non-Kerberos means)
  │     └── S4U2Proxy request to KDC: "let me get a ticket to SPN X on behalf of user Y"
  │           └── KDC checks front-end's msDS-AllowedToDelegateTo — SPN X must be an EXACT match
  │                 └── Same domain only — this attribute cannot authorize cross-domain targets
  │
  └── RESOURCE-BASED CONSTRAINED DELEGATION (RBCD) path
        Front-end requests S4U2Proxy to backend SPN
          └── KDC checks the BACKEND's msDS-AllowedToActOnBehalfOfOtherIdentity
                (PrincipalsAllowedToDelegateToAccount) — front-end's SID must be listed
                └── Authorization lives on the resource's own domain — works cross-domain
                      within the same forest without requiring front-end-side msDS-AllowedToDelegateTo

  ALL THREE PATHS ARE BLOCKED UNCONDITIONALLY IF:
    ├── Target/impersonated user has AccountNotDelegated=True, OR
    └── Target/impersonated user is a member of Protected Users
          (also disables NTLM fallback — no silent degradation, hard failure instead)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| App works when RDP'd directly to the backend server, fails with access denied only when accessed through the front-end/web tier | Classic double-hop — no delegation configured on the front-end at all | `Get-ADUser/-ADComputer <frontend> -Properties TrustedForDelegation, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo` |
| Front-end's delegation config looks correct (SPN listed, protocol transition enabled) but the call to the backend still fails | RBCD not configured on the backend side — the resource never authorized this front-end | `Get-ADComputer <backend> -Properties PrincipalsAllowedToDelegateToAccount` |
| Delegation worked for months, broke after a SQL Server named-instance move or a hostname/port change | `msDS-AllowedToDelegateTo` SPN string no longer matches the backend's actual registered SPN (host/port/instance changed) | `setspn -L <backend>` and diff character-for-character against `msDS-AllowedToDelegateTo` |
| Delegation fails specifically for one admin/service account, works for regular users hitting the identical code path | Target account has `AccountNotDelegated=True` or was recently added to Protected Users | `Get-ADUser <target> -Properties AccountNotDelegated, MemberOf` |
| App previously "worked" via a silent NTLM fallback, now fails hard after an account was added to Protected Users | Protected Users disables NTLM fallback entirely — the underlying delegation gap was never actually fixed, only masked | Confirm delegation is genuinely configured correctly, not just previously working by NTLM accident |
| Cross-domain multi-tier app (front-end in Domain A, backend in Domain B) can't get constrained delegation working no matter what's set on the front-end | Classic constrained delegation (`msDS-AllowedToDelegateTo`) cannot authorize cross-domain targets — this requires RBCD instead | Confirm domain functional level ≥ Server 2012 on Domain B; configure RBCD on the Domain B resource instead |
| `KDC_ERR_BADOPTION` captured in a network trace or Kerberos-auditing event | KDC refused the delegation request outright — almost always a sensitive-account or Protected-Users block, occasionally a completely unauthorized front-end | Check target user's `AccountNotDelegated`/Protected Users status first, before assuming a config gap |
| A server is found with `TrustedForDelegation=True` and no one recalls configuring it or knows what depends on it | Legacy unconstrained delegation, likely inherited from an old app deployment or a default that was never revisited | Treat as a standing finding regardless of the current ticket — schedule migration to constrained/RBCD per Remediation Playbook 2 |
| Delegation works from one front-end server in a load-balanced pool but not another with supposedly identical configuration | Delegation was configured against the specific front-end computer/service account object, and the pool members aren't using the same identity (e.g., different gMSA, or one node's SPN registration drifted) | Compare the exact account each pool node runs as; confirm SPN registration is consistent across all nodes |

---
## Validation Steps

**Step 1 — Inventory the front-end's delegation configuration precisely**
```powershell
Get-ADUser <serviceAccountSam> -Properties TrustedForDelegation, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo, userAccountControl |
  Select-Object Name, TrustedForDelegation, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo
```
Expected: exactly one delegation model represented, with `msDS-AllowedToDelegateTo` populated (if constrained) with SPN strings that exactly match the backend's registration.

**Step 2 — Inventory the backend's RBCD authorization, regardless of whether classic KCD is also in use**
```powershell
Get-ADComputer <backendSam> -Properties PrincipalsAllowedToDelegateToAccount |
  Select-Object -ExpandProperty PrincipalsAllowedToDelegateToAccount
```
Expected: if RBCD is the intended model, the front-end's SID/name appears in this list. Absence here is authoritative — no amount of front-end-side configuration substitutes for this.

**Step 3 — Confirm the target user isn't subject to a blocking control**
```powershell
Get-ADUser <targetUserSam> -Properties AccountNotDelegated, MemberOf, msDS-SupportedEncryptionTypes |
  Select-Object Name, AccountNotDelegated, @{N='ProtectedUsers';E={($_.MemberOf|Where-Object{$_ -match 'Protected Users'}) -ne $null}}
```
Expected: both negative for any account that should be delegable. A positive result here ends the investigation on the delegation-config side — the block is intentional and by design.

**Step 4 — Confirm SPN registration matches exactly, including port/instance qualifiers**
```powershell
setspn -L <backendServiceAccountSam>
```
Expected: an SPN string that is an exact, character-for-character match to what's listed in `msDS-AllowedToDelegateTo` on the front-end (classic KCD) — mismatched casing is tolerated, but a missing port/instance qualifier is not.

**Step 5 — Capture the actual ticket exchange for definitive proof**
```powershell
# On the front-end, after reproducing the failure
klist tickets
# A successful delegation shows a service ticket for the backend SPN, cached under the
# impersonated user's context, not just the front-end's own service ticket
```
Expected: presence of a service ticket to the backend SPN confirms the delegation chain succeeded up through S4U2Proxy; its absence means the failure occurred before that point — check Steps 1-4 in order.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Identify the Architecture in Play
1. Confirm which delegation model (unconstrained / constrained / RBCD) is intended for this application, not just what happens to be configured — mixed or legacy leftover configuration is common
2. Identify which team/owner controls the front-end object vs. the backend/resource object — RBCD troubleshooting frequently stalls because the two are owned by different teams

### Phase 2 — Rule Out Intentional Blocks First
1. Check the target user's `AccountNotDelegated` and Protected Users status before investigating delegation configuration at all — this is the fastest possible dead end to rule out
2. If the target is genuinely meant to be exempt, stop here — the fix is an architecture change (a lower-privileged proxy identity), not a delegation config change

### Phase 3 — Validate Front-End Authorization
1. Confirm the correct `userAccountControl` flags for the intended model
2. For constrained delegation, confirm `msDS-AllowedToDelegateTo` contains the exact target SPN
3. For RBCD, this step is a no-op on the front-end side — proceed to Phase 4

### Phase 4 — Validate Resource-Side Authorization (RBCD)
1. Confirm `PrincipalsAllowedToDelegateToAccount` on the backend lists the front-end's identity
2. If missing, this requires rights over the backend object — escalate to its owning team rather than attempting to work around it from the front-end side

### Phase 5 — Confirm SPN Registration Consistency
1. `setspn -L` the backend account and diff exactly against what's authorized
2. Pay specific attention to port/instance qualifiers, which are easy to omit and fail silently

### Phase 6 — Capture Definitive Ticket Evidence
1. Reproduce the failure and immediately check `klist tickets` on the front-end
2. If a Kerberos/network trace is available, capture the exact KDC error code (`KDC_ERR_BADOPTION`, `KDC_ERR_S_PRINCIPAL_UNKNOWN`, `KRB_AP_ERR_MODIFIED`) to disambiguate an authorization failure from an SPN-resolution failure

### Phase 7 — Security Review (if unconstrained delegation is found anywhere in the chain)
1. Flag it regardless of whether it's the cause of the current ticket
2. Schedule migration to constrained delegation or RBCD per Remediation Playbook 2 — do not leave it in place "since it works"

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up constrained delegation (KCD) for a new multi-tier app, intra-domain</summary>

**Scenario:** A new front-end web app needs to call a backend SQL Server as the logged-in user, both objects in the same domain.

**Step 1 — Confirm the backend's exact registered SPN**
```powershell
setspn -L <backendSqlServiceAccount>
```

**Step 2 — Authorize the front-end to delegate to that exact SPN**
```powershell
Set-ADUser <frontEndServiceAccount> -Add @{'msDS-AllowedToDelegateTo' = 'MSSQLSvc/sqlhost.domain.com:1433'}
```

**Step 3 — Enable protocol transition only if the front-end authenticates users via a non-Kerberos method (forms auth, certs)**
```powershell
Set-ADAccountControl <frontEndServiceAccount> -TrustedToAuthenticateForDelegation $true
```
Skip this step if the front-end receives a genuine Kerberos ticket from the user (IIS with Windows/Negotiate auth against a domain-joined browser client, for example) — "Use Kerberos only" is the more restrictive and preferable option when it's sufficient.

**Step 4 — Validate**
```powershell
Get-ADUser <frontEndServiceAccount> -Properties msDS-AllowedToDelegateTo, TrustedToAuthForDelegation
```

**Rollback note:** `Set-ADUser -Remove @{'msDS-AllowedToDelegateTo' = '<SPN>'}` removes a single entry cleanly without affecting other authorized targets.

</details>

<details><summary>Playbook 2 — Migrating a server off unconstrained delegation</summary>

**Scenario:** An audit or investigation surfaces a server with `TrustedForDelegation=True` and no scoped target list — a standing lateral-movement risk that needs to be closed without breaking the dependent application.

**Step 1 — Identify what actually depends on this delegation today**
```powershell
# Review application architecture/documentation; unconstrained delegation gives no built-in
# audit trail of which backends were actually targeted historically — this must be determined
# from the application side, not from AD
```

**Step 2 — Stand up the replacement (constrained or RBCD) BEFORE touching the existing unconstrained flag**
```powershell
# Constrained, intra-domain:
Set-ADUser <serviceAccount> -Add @{'msDS-AllowedToDelegateTo' = 'HTTP/backend.domain.com'}
Set-ADAccountControl <serviceAccount> -TrustedToAuthenticateForDelegation $true

# OR, resource-based (preferred where the target supports it, including cross-domain):
Set-ADComputer <backendServer> -PrincipalsAllowedToDelegateToAccount <serviceAccount>
```

**Step 3 — Validate the new path works in parallel, then disable unconstrained delegation**
```powershell
Set-ADAccountControl <serviceAccount> -TrustedForDelegation $false
```

**Step 4 — Confirm the application continues functioning post-change**
Re-test the full user-facing workflow, not just a direct ticket request — some applications cache delegation-dependent connections and may need a service restart to pick up the new ticket path.

**Rollback note:** Re-enabling `TrustedForDelegation` reverts to the higher-risk state immediately — only do this as a last resort if the migration breaks something unexpected, and treat it as a temporary bridge with an explicit re-attempt date, not a final state.

</details>

<details><summary>Playbook 3 — Cross-domain delegation via RBCD (classic KCD won't work here)</summary>

**Scenario:** Front-end in Domain A, backend resource in Domain B, same forest. Classic `msDS-AllowedToDelegateTo` cannot authorize this — RBCD is required.

**Step 1 — Confirm Domain B's domain controllers are Windows Server 2012 or later (RBCD is evaluated by the resource's own domain KDC)**
```powershell
Get-ADDomainController -Discover -Domain <DomainB> | Select-Object Name, OperatingSystem
```

**Step 2 — Configure the authorization on the Domain B resource (requires rights in Domain B)**
```powershell
Set-ADComputer <backendServerInDomainB> -PrincipalsAllowedToDelegateToAccount <frontEndAccountInDomainA> -Server <DomainB-DC>
```

**Step 3 — No `msDS-AllowedToDelegateTo` configuration is needed or possible on the Domain A front-end account for this cross-domain target — confirm this isn't attempted, since it will silently fail to authorize anything cross-domain**

**Step 4 — Validate from the front-end**
```powershell
klist tickets   # after reproducing the workflow, confirm a service ticket for the Domain B backend SPN appears
```

**Rollback note:** Clear `PrincipalsAllowedToDelegateToAccount` on the Domain B object to revoke; this is a single-sided, reversible change with no dependency on the Domain A side.

</details>

<details><summary>Playbook 4 — Domain-wide delegation exposure audit</summary>

**Scenario:** Periodic security review to inventory every account/computer authorized for any form of Kerberos delegation, as a Tier-0 hygiene check.

**Step 1 — Find all unconstrained delegation (highest priority findings)**
```powershell
Get-ADObject -LDAPFilter "(userAccountControl:1.2.840.113556.1.4.803:=524288)" -Properties Name, ObjectClass, userAccountControl
```

**Step 2 — Find all classic constrained delegation and list authorized targets**
```powershell
Get-ADObject -LDAPFilter "(msDS-AllowedToDelegateTo=*)" -Properties Name, ObjectClass, msDS-AllowedToDelegateTo, TrustedToAuthForDelegation |
  Select-Object Name, ObjectClass, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo
```

**Step 3 — Find all RBCD authorizations**
```powershell
Get-ADObject -LDAPFilter "(msDS-AllowedToActOnBehalfOfOtherIdentity=*)" -Properties Name, ObjectClass, msDS-AllowedToActOnBehalfOfOtherIdentity
```

**Step 4 — Cross-reference every account found against Tier-0/privileged group membership — a Tier-0 account with delegation rights of any kind onto a lower-tier resource is a tiering violation**

**Rollback note:** N/A — this is a read-only audit playbook. Findings should feed Playbook 2 (unconstrained migration) or a scoped access review, not an automated remediation.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Kerberos Delegation Evidence Collector
.NOTES     Run with rights to read the front-end, backend, and target user objects.
#>

$reportPath = "C:\Temp\DelegationEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

param($FrontEndSam, $BackendSam, $TargetUserSam)

"=== Front-End Delegation Configuration ===" | Out-File "$reportPath\01_FrontEnd.txt"
Get-ADObject -Filter "SamAccountName -eq '$FrontEndSam'" -Properties TrustedForDelegation, TrustedToAuthForDelegation, 'msDS-AllowedToDelegateTo' |
  Format-List | Out-File "$reportPath\01_FrontEnd.txt" -Append

"=== Backend RBCD Authorization ===" | Out-File "$reportPath\02_Backend.txt"
Get-ADComputer $BackendSam -Properties PrincipalsAllowedToDelegateToAccount -ErrorAction SilentlyContinue |
  Format-List | Out-File "$reportPath\02_Backend.txt" -Append

"=== Backend SPN Registration ===" | Out-File "$reportPath\03_SPNs.txt"
setspn -L $BackendSam | Out-File "$reportPath\03_SPNs.txt" -Append

"=== Target User Delegation-Exempt Status ===" | Out-File "$reportPath\04_TargetUser.txt"
Get-ADUser $TargetUserSam -Properties AccountNotDelegated, MemberOf -ErrorAction SilentlyContinue |
  Select-Object Name, AccountNotDelegated, @{N='ProtectedUsers';E={($_.MemberOf | Where-Object {$_ -match 'Protected Users'}) -ne $null}} |
  Format-List | Out-File "$reportPath\04_TargetUser.txt" -Append

"=== Domain-Wide Unconstrained Delegation Inventory ===" | Out-File "$reportPath\05_UnconstrainedInventory.txt"
Get-ADObject -LDAPFilter "(userAccountControl:1.2.840.113556.1.4.803:=524288)" -Properties Name, ObjectClass |
  Select-Object Name, ObjectClass | Format-Table -AutoSize | Out-File "$reportPath\05_UnconstrainedInventory.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check front-end delegation model | `Get-ADUser <sam> -Properties TrustedForDelegation, TrustedToAuthForDelegation, msDS-AllowedToDelegateTo` |
| Check RBCD authorization on backend | `Get-ADComputer <sam> -Properties PrincipalsAllowedToDelegateToAccount` |
| Grant RBCD authorization | `Set-ADComputer <backend> -PrincipalsAllowedToDelegateToAccount <frontend>` |
| Add a constrained-delegation target SPN | `Set-ADUser <sam> -Add @{'msDS-AllowedToDelegateTo'='<SPN>'}` |
| Enable protocol transition (S4U2Self) | `Set-ADAccountControl <sam> -TrustedToAuthenticateForDelegation $true` |
| Disable unconstrained delegation | `Set-ADAccountControl <sam> -TrustedForDelegation $false` |
| Check target user's delegation-exempt status | `Get-ADUser <sam> -Properties AccountNotDelegated, MemberOf` |
| List registered SPNs for an account | `setspn -L <sam>` |
| View cached tickets after reproducing a failure | `klist tickets` |
| Find all unconstrained-delegation objects domain-wide | `Get-ADObject -LDAPFilter "(userAccountControl:1.2.840.113556.1.4.803:=524288)"` |
| Find all classic constrained-delegation objects | `Get-ADObject -LDAPFilter "(msDS-AllowedToDelegateTo=*)"` |
| Find all RBCD-authorized objects | `Get-ADObject -LDAPFilter "(msDS-AllowedToActOnBehalfOfOtherIdentity=*)"` |

---
## 🎓 Learning Pointers

- **Classic constrained delegation is configured on the front-end; RBCD is configured on the backend.** These are opposite ends of the relationship, frequently owned by different teams — confirm which model is in play and who owns the object that needs the fix before troubleshooting further.
- **`AccountNotDelegated` and Protected Users are intentional, hard blocks, not misconfigurations.** A delegation failure against a Tier-0/privileged account is the system working correctly — the fix is an architecture change (a lower-privileged proxy identity), never removing the protection.
- **Protected Users disables the NTLM fallback that many "working" apps were silently relying on.** If an app breaks specifically when an account is added to Protected Users, the delegation chain was likely never actually correct — it was being masked by an NTLM degradation path that no longer exists for that account.
- **Unconstrained delegation is a standing security finding regardless of the ticket that led you to it.** Compromise of a server configured this way can yield cached TGTs for every user who's authenticated to it — treat discovery of it as a scheduled migration item, not background noise.
- **Classic constrained delegation cannot cross a domain boundary, even within the same forest.** RBCD is the only model that supports this, because its authorization decision is evaluated entirely by the resource's own domain KDC.
- **SPN mismatches — especially missing port/instance qualifiers on SQL Server SPNs — fail with the same outward symptom as a completely missing delegation configuration.** Always diff the exact SPN string; never eyeball it as "close enough."
- Related: [Kerberos Constrained Delegation overview](https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-constrained-delegation-overview), [Resource-based constrained delegation technical background](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn466531(v=ws.11)), [Protected Users security group](https://learn.microsoft.com/en-us/windows-server/security/credentials-protection-and-management/protected-users-security-group), [Configure Kerberos delegation for gMSAs](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/group-managed-service-accounts/group-managed-service-accounts/configure-kerberos-delegation-group-managed-service-accounts)
