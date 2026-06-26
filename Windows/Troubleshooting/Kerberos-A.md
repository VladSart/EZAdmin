# Kerberos Authentication — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Applies to:** Windows 10/11, Windows Server 2016–2025, Active Directory domains, Azure AD-joined with hybrid scenarios
- **Covers:** Kerberos authentication, TGT/service ticket lifecycle, SPN management, constrained delegation, Kerberos errors and event IDs
- **Out of scope:** NTLM-only environments, MIT Kerberos interoperability, Kerberos for Linux (PAM/SSSD) — see separate runbook
- **Assumed role:** L2/L3 engineer with domain admin rights or equivalent; DC event log access
- **Tools required:** `klist`, `nltest`, `setspn`, `w32tm`, PowerShell, Event Viewer (on DC)

---

## How It Works

<details><summary>Full architecture — Kerberos v5 in Active Directory</summary>

### Protocol Overview

Kerberos v5 is a mutual authentication protocol using symmetric-key cryptography. In Active Directory, the KDC (Key Distribution Center) role is hosted on every Domain Controller. Authentication requires three parties: client, KDC, and target service.

### Ticket Exchange Flow

```
Phase 1 — Authentication Service (AS) Exchange
  Client → KDC:    AS-REQ (pre-authentication: timestamp encrypted with client's password hash)
  KDC   → Client:  AS-REP (TGT encrypted with krbtgt account key + session key encrypted with client's key)

Phase 2 — Ticket Granting Service (TGS) Exchange
  Client → KDC:    TGS-REQ (TGT + SPN of target service)
  KDC   → Client:  TGS-REP (Service Ticket encrypted with service account's key)

Phase 3 — Client/Server (CS) Exchange
  Client → Server:  AP-REQ (Service Ticket + Authenticator encrypted with session key)
  Server → Client:  AP-REP (mutual authentication confirmation — optional)
```

### Ticket Types and Lifetimes

| Ticket | Default Lifetime | Encrypted With | Purpose |
|---|---|---|---|
| TGT (Ticket-Granting Ticket) | 10 hours (renewable 7 days) | `krbtgt` account's hash | Prove identity to KDC |
| Service Ticket | 10 hours | Target service account's hash | Prove identity to a specific service |
| Forwarded TGT | Same as TGT | Same | Used in delegation scenarios |

### Key Cryptography

Windows uses AES-256 by default (AES-128, RC4/NTLM hash as fallback). The KDC selects the strongest encryption type mutually supported by client and service. RC4 (NTLM hash-based) is legacy and should be disabled for security hardening but may be required for older services.

### Service Principal Names (SPNs)

An SPN is the unique identifier for a service instance. Format: `serviceclass/hostname:port/servicename`

Common examples:
```
HOST/server01
HOST/server01.contoso.com
HTTP/webserver.contoso.com
MSSQLSvc/sqlserver.contoso.com:1433
WSMAN/server01.contoso.com
```

When a client requests a service ticket, it provides the SPN to the KDC. The KDC looks up the SPN in Active Directory to find the associated account and encrypts the ticket with that account's key. If the SPN doesn't exist or is registered to the wrong account, the ticket cannot be issued or decrypted.

### Delegation Types

```
No delegation (default)
  Client → Server: service ticket only — server cannot act on behalf of user

Unconstrained delegation (legacy, avoid)
  Server receives client's TGT — can impersonate user to ANY service
  Risk: if server is compromised, attacker has full impersonation capability

Constrained delegation (KCD)
  Server can impersonate user only to specific, pre-defined SPNs
  Configured via: msDS-AllowedToDelegateTo attribute

Resource-based constrained delegation (RBCD)
  Target resource defines which accounts can delegate to it
  Configured via: msDS-AllowedToActOnBehalfOfOtherIdentity on the target
  Does not require Domain Admin to configure
```

### Multi-hop (Double-Hop) Problem

```
User → Web Server (using Kerberos)
           │
           └──→ SQL Server (FAIL — web server has no TGT to present)
```

The web server received the user's service ticket (encrypted, non-forwardable by default) — it cannot request a service ticket for SQL Server on behalf of the user without delegation configured. This is the "double-hop" problem.

**Solution:** Configure constrained delegation from the web server's service account to the SQL Server's SPN.

</details>

---

## Dependency Stack

```
Kerberos Authentication
    │
    ├── Active Directory Domain Services
    │       ├── KDC role (runs on all DCs)
    │       ├── krbtgt account (secret — encrypts all TGTs)
    │       └── SPN database (msDS-SPNs in AD)
    │
    ├── DNS
    │       ├── A/AAAA records for DCs (KDC discovery via _kerberos._tcp SRV)
    │       └── A/AAAA records for all Kerberos targets (SPN hostname resolution)
    │
    ├── Time Synchronization (W32TM)
    │       └── Max skew: 5 minutes (default; KerberosMaxClockSkew GPO)
    │
    ├── Network Connectivity
    │       ├── UDP/TCP 88    → KDC (Kerberos)
    │       ├── TCP 389/636   → LDAP/LDAPS (AD queries)
    │       └── TCP 445       → SMB (for domain operations)
    │
    └── Client Configuration
            ├── Domain membership (computer account in AD)
            ├── Secure channel to DC (Netlogon service)
            └── Correct DNS pointing to AD-integrated DNS
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "No credentials available" / 0x8009030E | No Kerberos ticket available; client fell back to NTLM and it failed | `klist`; check if FQDN vs. short name used |
| "The referenced account is currently locked out" | Account lockout — Kerberos pre-auth failure triggering lockout | Event 4771 on DC; check lockout source |
| Intermittent auth failures, resolves after reboot | Stale/corrupted ticket cache | `klist purge`; check ticket expiry |
| Auth fails only for specific services | SPN missing, duplicate, or registered to wrong account | `setspn -Q` |
| "Double hop" scenario fails | Missing delegation configuration | Check msDS-AllowedToDelegateTo or RBCD |
| Auth works with IP but not hostname | SPN registered against short name only; NTLM used for IP | `setspn -Q`; add FQDN SPN |
| Auth fails on VPN / remote / Azure-joined | DNS not resolving domain; time skew on device | `Resolve-DnsName`; `w32tm /query` |
| Kerberos worked, now fails after password reset | Old tickets still valid; service account password changed | `klist purge`; restart service on server |
| KDC_ERR_ETYPE_NOSUPP | Client or service doesn't support required encryption type | Check AES/RC4 GPO settings |
| Pass-the-ticket / golden ticket suspected | Security incident — compromised krbtgt | Escalate immediately; rotate krbtgt |

---

## Validation Steps

**1. Check Kerberos ticket cache (client):**
```powershell
klist
# Machine-level tickets:
klist -li 0x3e7
```
Expected good: TGT present for `krbtgt/<domain>`, service tickets for accessed resources, all within validity window.
Bad: Empty cache, or `>> Klist Failed with 0x8009030c <<`.

**2. Verify time sync (client and DC):**
```powershell
# On client:
w32tm /query /status
# On DC:
Invoke-Command -ComputerName <DC-FQDN> { w32tm /query /status }
# Compare times:
Get-Date
net time /domain
```
Expected: Offset < 5 minutes. Bad: Large offset → time sync failure.

**3. Check DC reachability and secure channel:**
```powershell
nltest /sc_verify:<domain.com>
nltest /dsgetdc:<domain.com> /force
```
Expected: `NERR_Success`, DC name and IP returned. Bad: `ERROR_NO_LOGON_SERVERS`.

**4. Check SPN registration:**
```powershell
# Search for a specific SPN
setspn -Q HTTP/<servername>
setspn -Q HTTP/<servername.domain.com>

# Find duplicate SPNs (run on DC or RSAT machine)
setspn -X

# List all SPNs for a specific account
setspn -L domain\<serviceaccount>
```
Expected: Single account listed per SPN. Bad: "Duplicate SPN found" or "No such SPN found".

**5. Check Kerberos error events on DC:**
```powershell
# Run on the relevant DC (or use -ComputerName for remote)
Get-WinEvent -LogName Security -MaxEvents 500 |
    Where-Object { $_.Id -in @(4768,4769,4771,4776) } |
    Select-Object TimeCreated, Id,
        @{N='User';E={$_.Properties[0].Value}},
        @{N='ErrorCode';E={$_.Properties[6].Value}},
        @{N='ServiceName';E={$_.Properties[3].Value}} |
    Where-Object User -match '<username-or-domain>' |
    Format-Table -AutoSize
```

**6. Verify Kerberos ports open:**
```powershell
Test-NetConnection -ComputerName <DC-FQDN> -Port 88    # Kerberos
Test-NetConnection -ComputerName <DC-FQDN> -Port 389   # LDAP
Test-NetConnection -ComputerName <DC-FQDN> -Port 445   # SMB
```
Expected: `TcpTestSucceeded: True` for all.

**7. Verify constrained delegation configuration (for multi-hop):**
```powershell
# RSAT required
Import-Module ActiveDirectory
Get-ADUser <serviceaccount> -Properties msDS-AllowedToDelegateTo |
    Select-Object Name, msDS-AllowedToDelegateTo
Get-ADComputer <server> -Properties msDS-AllowedToDelegateTo, TrustedForDelegation |
    Select-Object Name, TrustedForDelegation, msDS-AllowedToDelegateTo
```

---

## Troubleshooting Steps by Phase

### Phase 1 — Confirm authentication method

1. Run `klist` — if no tickets, Kerberos isn't being used (NTLM fallback)
2. Use `nltest /sc_verify:<domain>` to confirm secure channel
3. Check if using FQDN vs. short name for resource access (Kerberos requires FQDN in most cases)
4. Check event log on DC for 4768/4769/4771 to confirm where the failure happens

### Phase 2 — Time and connectivity

5. Verify time sync on client, then on DC — compare with `net time /domain`
6. Check DNS: `Resolve-DnsName _kerberos._tcp.<domain.com> -Type SRV` — must return DC names
7. Test Kerberos port (88) connectivity to all DCs in site
8. On VPN: ensure split DNS and routing allow client to reach domain KDC

### Phase 3 — Ticket and credential issues

9. If tickets are stale/expired: `klist purge` then re-authenticate
10. If pre-auth failure (4771): check account status, password, lockout
11. If service ticket failure (4769 with error code): check SPN, encryption type support

### Phase 4 — SPN and delegation issues

12. Run `setspn -Q <SPN>` to confirm SPN exists and is on the correct account
13. Run `setspn -X` to check for duplicates across the domain
14. For multi-hop: configure constrained delegation or RBCD
15. After any SPN change: `klist purge` on all affected clients; allow up to 15 minutes for AD replication

### Phase 5 — Encryption type issues

16. If `KDC_ERR_ETYPE_NOSUPP`: check GPO "Network security: Configure encryption types allowed for Kerberos"
17. AES-256 + AES-128 should be enabled; RC4 may need to remain if legacy services require it
18. After changing encryption types: restart Kerberos-dependent services and purge ticket cache

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Comprehensive SPN audit and cleanup</summary>

```powershell
# Run on DC or machine with RSAT / AD PowerShell module
Import-Module ActiveDirectory

# Find all duplicate SPNs in domain
Write-Host "=== Duplicate SPNs ===" -ForegroundColor Yellow
setspn -X   # Reports any duplicates

# List all SPNs for a specific service account
$account = '<domain>\<serviceaccount>'
Write-Host "=== SPNs for $account ===" -ForegroundColor Cyan
setspn -L $account

# Register missing SPNs (replace values)
$server   = '<servername>'
$domain   = '<domain.com>'
$svcAcct  = '<domain>\<serviceaccount>'

$spnsToRegister = @(
    "HTTP/$server",
    "HTTP/$server.$domain",
    "HOST/$server",
    "HOST/$server.$domain"
)

foreach ($spn in $spnsToRegister) {
    $existing = setspn -Q $spn 2>&1
    if ($existing -match 'No such SPN found') {
        Write-Host "Registering: $spn" -ForegroundColor Green
        setspn -S $spn $svcAcct
    } else {
        Write-Host "Already registered: $spn" -ForegroundColor Cyan
    }
}
```

</details>

<details>
<summary>Playbook 2 — Configure Resource-Based Constrained Delegation (RBCD)</summary>

**Use for:** Multi-hop scenarios without needing Domain Admin on the front-end server account.

```powershell
Import-Module ActiveDirectory

# The front-end server that will delegate (e.g., web server)
$frontEnd = '<frontend-server-name>'  # Computer account name (no $)

# The back-end resource that will accept delegation (e.g., SQL server)
$backEnd  = '<backend-server-name>'

# Get the SID of the front-end computer account
$frontEndSID = (Get-ADComputer $frontEnd).SID

# Configure RBCD on the back-end resource
$backEndObject = Get-ADComputer $backEnd
Set-ADComputer $backEnd -PrincipalsAllowedToDelegateToAccount (Get-ADComputer $frontEnd)

# Verify
Get-ADComputer $backEnd -Properties msDS-AllowedToActOnBehalfOfOtherIdentity |
    Select-Object Name, msDS-AllowedToActOnBehalfOfOtherIdentity

Write-Host "[OK] RBCD configured. Allow 15 min for AD replication, then purge Kerberos caches."
```

**Rollback:**
```powershell
Set-ADComputer $backEnd -PrincipalsAllowedToDelegateToAccount $null
```

</details>

<details>
<summary>Playbook 3 — Force Kerberos and disable NTLM fallback (per-server)</summary>

**Use for:** Security hardening or confirming Kerberos works before disabling NTLM.

```powershell
# Test Kerberos specifically to a target
# Map a drive using FQDN (Kerberos) vs short name (NTLM)
New-PSDrive -Name Z -PSProvider FileSystem -Root \\<server.domain.com>\share -Credential (Get-Credential)
klist  # Should show a service ticket for cifs/<server.domain.com>

# Check which auth protocol was used for an active SMB connection
Get-SmbConnection | Where-Object ServerName -match '<server>' |
    Select-Object ServerName, ShareName, UserName, Dialect, Encrypted
```

To audit NTLM usage in environment (requires DC audit policy):
```powershell
# Enable NTLM audit on DC via GPO:
# Computer Configuration → Policies → Windows Settings → Security Settings →
# Local Policies → Security Options:
#   "Network security: Restrict NTLM: Audit NTLM authentication in this domain" → Enable all

# View NTLM audit events
Get-WinEvent -LogName 'Microsoft-Windows-NTLM/Operational' -MaxEvents 100 |
    Select-Object TimeCreated, Message | Format-List
```

</details>

<details>
<summary>Playbook 4 — Reset krbtgt account (security incident response)</summary>

> ⚠️ **DESTRUCTIVE — only in security incident context.** Resetting krbtgt invalidates ALL existing Kerberos tickets domain-wide. All users will need to re-authenticate. Coordinate with stakeholders before proceeding.

```powershell
# Must be run on a DC as Domain Admin
Import-Module ActiveDirectory

# Step 1: Reset krbtgt password (first reset)
Set-ADAccountPassword -Identity 'krbtgt' -Reset -NewPassword (
    ConvertTo-SecureString -AsPlainText (
        [System.Web.Security.Membership]::GeneratePassword(32,8)
    ) -Force
)
Write-Host "[OK] krbtgt password reset #1. Wait for AD replication (minimum 10 min for single domain)."

# Step 2: Wait for replication, then reset AGAIN
# (krbtgt has two keys — both must be rotated)
# After confirming replication:
Start-Sleep -Seconds 600  # 10 minutes minimum
Set-ADAccountPassword -Identity 'krbtgt' -Reset -NewPassword (
    ConvertTo-SecureString -AsPlainText (
        [System.Web.Security.Membership]::GeneratePassword(32,8)
    ) -Force
)
Write-Host "[OK] krbtgt password reset #2. All existing TGTs are now invalid."
Write-Host "Users and services will need to re-authenticate. Monitor helpdesk volume."
```

Microsoft tool: [New-KrbtgtKeys.ps1](https://github.com/microsoft/New-KrbtgtKeys.ps1) — handles the two-reset sequence with replication verification.

</details>

---

## Evidence Pack

```powershell
# Run as Domain Admin on affected client — collects full Kerberos evidence pack
$out = "C:\Temp\KerberosEvidence_$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$domain = $env:USERDNSDOMAIN

# 1. Kerberos ticket cache
klist | Out-File "$out\klist_user.txt"
klist -li 0x3e7 | Out-File "$out\klist_machine.txt"

# 2. Time sync status
w32tm /query /status | Out-File "$out\w32tm_status.txt"
(Get-Date).ToString() | Out-File "$out\local_time.txt"

# 3. Network connectivity to DCs
$dcs = (Resolve-DnsName "_kerberos._tcp.$domain" -Type SRV -ErrorAction SilentlyContinue).NameTarget
foreach ($dc in $dcs) {
    "=== DC: $dc ===" | Out-File "$out\dc_connectivity.txt" -Append
    Test-NetConnection $dc -Port 88  | Out-File "$out\dc_connectivity.txt" -Append
    Test-NetConnection $dc -Port 389 | Out-File "$out\dc_connectivity.txt" -Append
}

# 4. Secure channel
nltest /sc_verify:$domain | Out-File "$out\nltest_verify.txt"
nltest /dsgetdc:$domain /force | Out-File "$out\nltest_dsgetdc.txt"

# 5. DNS SRV records
Resolve-DnsName "_kerberos._tcp.$domain" -Type SRV | Out-File "$out\dns_srv.txt"

# 6. System info
Get-ComputerInfo | Select-Object CsName, CsDomain, OsName, OsVersion |
    Out-File "$out\systeminfo.txt"

# 7. Kerberos events from this machine's Security log
Get-WinEvent -LogName Security -MaxEvents 500 -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in @(4768,4769,4771,4776) } |
    Select-Object TimeCreated, Id, Message |
    Export-Csv "$out\kerberos_events.csv" -NoTypeInformation

Write-Host "[OK] Evidence collected: $out"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "[OK] Archive: $out.zip"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| View current Kerberos tickets | `klist` |
| View machine-level tickets | `klist -li 0x3e7` |
| Purge ticket cache | `klist purge` |
| Check time sync status | `w32tm /query /status` |
| Force time sync | `w32tm /resync /force` |
| Verify secure channel | `nltest /sc_verify:<domain.com>` |
| Find DC | `nltest /dsgetdc:<domain.com> /force` |
| Check SPN | `setspn -Q <SPN>` |
| List account SPNs | `setspn -L domain\account` |
| Find duplicate SPNs | `setspn -X` |
| Add SPN | `setspn -S <SPN> domain\account` |
| Remove SPN | `setspn -D <SPN> domain\account` |
| Reset secure channel | `Test-ComputerSecureChannel -Repair -Credential (Get-Credential)` |
| Check Kerberos events on DC | `Get-WinEvent -LogName Security \| Where Id -in 4768,4769,4771` |
| Test Kerberos port | `Test-NetConnection <DC-FQDN> -Port 88` |
| Configure RBCD | `Set-ADComputer <backend> -PrincipalsAllowedToDelegateToAccount (Get-ADComputer <frontend>)` |

---

## 🎓 Learning Pointers

- **The krbtgt account is the master secret:** Every TGT in the domain is encrypted with the krbtgt account's password hash. If an attacker steals the krbtgt hash (via DCSync or domain compromise), they can forge TGTs indefinitely — this is a "Golden Ticket" attack. Rotating krbtgt **twice** (to cycle both the current and previous key) is the only way to invalidate all existing forged tickets. This is why krbtgt rotation is a standard post-incident recovery step. [Golden Ticket defense](https://learn.microsoft.com/en-us/security/operations/incident-response-playbook-compromised-malicious-app)

- **Kerberos uses UDP by default, switches to TCP for large tickets:** If there are many group memberships or Kerberos extension data in the ticket (PAC), the ticket can exceed the 65KB UDP limit and automatically retries over TCP (port 88). Network devices blocking large UDP packets or TCP/88 cause intermittent Kerberos failures. Set `MaxTokenSize` if PAC bloat is suspected. [MaxTokenSize — MS Docs](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/increase-kerberos-token-size)

- **RC4 vs. AES matters for security and compatibility:** Windows 11 and Server 2025 are deprecating RC4 (NTLM hash-based Kerberos). Environments with old NAS devices, printers, or third-party software may still require RC4. Audit RC4 usage with `Get-WinEvent -LogName Security | Where Id -eq 4769 | Where { $_.Message -match 'Encryption Type: 0x17' }` — 0x17 = RC4. Plan migration to AES before Microsoft enforcement. [Kerberos RC4 deprecation](https://techcommunity.microsoft.com/t5/windows-it-pro-blog/rc4-removal-from-kerberos-and-windows/ba-p/3827558)

- **SPN conflicts across forests are especially painful:** In multi-forest environments or after migrations, SPNs may persist in the source domain while new ones are registered in the target. `setspn -X` only checks within the current domain — run it in every domain in the forest separately. Cross-forest authentication adds an additional KDC hop through inter-realm trust tickets, which adds another failure point. [Cross-forest Kerberos](https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-constrained-delegation-overview)

- **Azure AD Kerberos is different — but increasingly important:** Azure AD issues Kerberos tickets for hybrid resources accessed via Azure AD Kerberos (used by Windows Hello for Business, passkeys, and passwordless scenarios). These are "Cloud TGTs" issued by Azure AD and converted to on-premises tickets by Entra Connect / Kerberos Cloud TGT. If WHfB or passwordless auth is failing, check if Azure AD Kerberos is configured correctly in Entra Connect. [Azure AD Kerberos](https://learn.microsoft.com/en-us/azure/active-directory/authentication/howto-authentication-passwordless-security-key-on-premises)

- **Kerberos is invisible until it breaks:** Most engineers only encounter Kerberos when auth fails because it works silently when everything is right. Build proactive monitoring: alert on high volumes of 4771 events (failed pre-auth), monitor krbtgt account for unexpected password changes (4723/4724), and periodically run `setspn -X` to catch SPN drift before it causes an incident.
