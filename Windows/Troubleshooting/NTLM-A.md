# NTLM Authentication — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- NTLM v1, NTLMv2 authentication protocol mechanics
- NTLM pass-through authentication to Domain Controllers
- NTLM blocking/restriction policies and their downstream impact
- Common NTLM failure scenarios in hybrid environments (file shares, legacy apps, Exchange, SSRS, IIS)
- Auditing NTLM usage and identifying candidates for Kerberos migration
- Security hardening (LAN Manager auth level, session security, extended protection)

**Assumes:**
- On-premises AD environment (or hybrid — Entra Connect + AD)
- Domain-joined Windows endpoints
- Engineers have Domain Admin or equivalent for DC-level diagnostics
- For Kerberos context, see `Windows/Troubleshooting/Kerberos-A.md`

**Out of scope:**
- Workgroup/local NTLM (non-domain)
- Azure AD-only (no NTLM — Kerberos or modern auth only)
- NTLM relay attacks / offensive security

---

## How It Works

<details><summary>Full architecture — NTLM authentication protocol</summary>

### NTLM vs. Kerberos: When NTLM fires

Kerberos is preferred in AD environments, but NTLM is used when:
- Client connects to a server by **IP address** (not hostname)
- **DNS resolution** returns CNAME that doesn't match SPN
- Server is **not domain-joined**
- Kerberos tickets are unavailable (DC unreachable, clock skew >5 min)
- Application hardcodes NTLM or sends `WWW-Authenticate: NTLM`
- Local account authentication (not domain account)

### NTLMv2 Challenge-Response (3-leg handshake)

```
Client                  Server (Resource)           Domain Controller
  │                          │                             │
  │──── 1. NEGOTIATE ────────▶│                             │
  │    (capabilities,         │                             │
  │     NTLM version)         │                             │
  │                          │                             │
  │◀─── 2. CHALLENGE ─────────│                             │
  │    (server nonce,         │                             │
  │     server flags)         │                             │
  │                          │                             │
  │──── 3. AUTHENTICATE ──────▶│                             │
  │    (NT response,          │                             │
  │     username, domain,     │──── Pass-through auth ─────▶│
  │     workstation)          │    (NetLogon secure channel) │
  │                          │◀─── NetLogon response ───────│
  │◀─── Auth result ──────────│                             │
```

**NT response calculation:**
```
NT Hash = MD4(Unicode(Password))
NTLMv2 Hash = HMAC-MD5(NT Hash, Username + Domain)
Response = HMAC-MD5(NTLMv2 Hash, ServerChallenge + ClientChallenge + Timestamp + TargetInfo)
```

### Pass-through Authentication

When the server itself is not the DC, it passes the NTLM AUTHENTICATE message to a DC via **NetLogon** over the **secure channel**. The DC validates credentials and returns `STATUS_SUCCESS` or `STATUS_LOGON_FAILURE`.

```
App Server (NTLM resource)
    └── NetLogon service
            └── Secure channel to DC (TCP 445 / NetBIOS 139)
                    └── DC: NtlmsspChallengeResponse validation
```

**This means: if the secure channel between server and DC is broken → all NTLM auth on that server fails.**

### LAN Manager Authentication Levels

Configured via GPO: `Computer Config → Windows Settings → Security Settings → Local Policies → Security Options → Network security: LAN Manager authentication level`

| Level | Value | Behavior |
|-------|-------|---------|
| 0 | Send LM & NTLM responses | Legacy — sends LM (insecure) |
| 1 | Send LM & NTLM, use NTLMv2 if negotiated | Legacy+ |
| 2 | Send NTLM only | Moderate |
| 3 | Send NTLMv2 only | Recommended baseline |
| 4 | Send NTLMv2; DC refuses LM | Server hardened |
| 5 | Send NTLMv2; DC refuses LM & NTLM | **Maximum hardening** — breaks legacy clients |

Microsoft recommends level 5 in modern environments. Setting level 5 on DCs while clients are at level 0 **breaks all NTLM auth** from those clients.

### NTLM Session Security (Extended Protection for Authentication / EPA)

EPA (also called NTLM Channel Binding) ties the NTLM session to a specific TLS channel. Prevents NTLM relay attacks. Configured per-application (IIS, Exchange, LDAP). Required for MDE and modern Exchange hardening.

</details>

---

## Dependency Stack

```
NTLM Authentication
        │
        ├── Network Connectivity
        │       ├── Client → Server: SMB/TCP 445 or app port
        │       └── Server → DC: NetLogon (TCP 445, TCP/UDP 135, dynamic RPC)
        │
        ├── NetLogon Service (on resource server)
        │       ├── Must be running
        │       └── Secure channel to DC must be valid
        │
        ├── Domain Controller
        │       ├── Reachable from resource server
        │       ├── Time sync (Kerberos clock skew tolerance: 5 min)
        │       └── NTLM not blocked by DC security policy
        │
        ├── LAN Manager Auth Level (GPO)
        │       ├── Client level must be ≤ DC accepted level
        │       └── Level 5 DC breaks Level 0-2 clients
        │
        ├── DNS Resolution
        │       └── Hostname-based: Kerberos attempted first
        │           IP-based: NTLM forced
        │
        └── Application Configuration
                ├── IIS Authentication providers (NTLM/Negotiate order)
                ├── Extended Protection for Authentication (EPA)
                └── Legacy app NTLM hardcoding
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Access denied" on file share via IP | NTLM failing pass-through auth; or NTLM blocked | Event 4625 on DC (sub-status 0xC000006D or 0xC0000064) |
| NTLM auth fails after hardening LM Level to 5 | Legacy clients/servers still sending NTLMv1 | Audit NTLM events 4776 on DCs; check client LM level |
| Web app 401 loop with Windows Auth | IIS Negotiate:Kerberos first fails, NTLM fallback blocked | Check IIS authentication providers order; SPN on app pool account |
| NTLM auth slow (2-3 seconds) | Secure channel delay; DC offline; NetLogon lookup | Test-NetConnection from server to DC port 445 |
| All NTLM fails after moving server to new subnet | Firewall blocking NetLogon ports (server→DC) | Netstat / firewall logs for TCP 445 from resource server |
| Exchange OWA keeps prompting credentials | NTLM blocked on CAS; EPA mismatch | Check IIS auth on Exchange CAS; check EPA setting |
| Event 4776 with error 0xC0000064 | Username doesn't exist in domain | Verify UPN/SAM, check for typos in target domain |
| Event 4776 with error 0xC000006A | Wrong password | Password mismatch (cached credential, locked account) |
| Event 4776 with error 0xC0000234 | Account locked out | Unlock account; trace lockout source with LockoutStatus.exe |
| NTLM Restriction policy blocking service | "Restrict NTLM: Outgoing NTLM to remote servers" | Check restriction GPO + add exceptions |

---

## Validation Steps

**1. Check LAN Manager authentication level**
```powershell
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").LmCompatibilityLevel
# 0-2 = legacy (insecure); 3 = NTLMv2 only (good); 5 = max hardening (verify all clients support)
```

**2. Check NTLM restriction policies (if applicable)**
```powershell
$ntlmPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters"
Get-ItemProperty $ntlmPath | Select-Object RestrictNTLMInDomain, RestrictSendingNTLMTraffic, RestrictReceivingNTLMTraffic
# 0 = not restricted; 1-3 = progressive restriction
```

**3. Check NetLogon secure channel status**
```powershell
# Run on resource server
nltest /sc_query:<DomainName>
# Expected: Status = 0x0 NERR_Success, Flag = HAS IP
```

**4. Test DC connectivity from resource server**
```powershell
$dc = (Get-ADDomainController -Discover -NextClosestSite).HostName
Test-NetConnection -ComputerName $dc -Port 445
Test-NetConnection -ComputerName $dc -Port 135
```

**5. Audit NTLM events on DC**
```powershell
# On DC — check Event 4776 (NTLM credential validation)
Get-WinEvent -ComputerName <DC> -FilterHashtable @{
    LogName   = "Security"
    Id        = 4776
    StartTime = (Get-Date).AddHours(-1)
} | Select-Object TimeCreated, @{N="Details"; E={$_.Message}} | Format-List
```

**6. Check if NTLM auditing is enabled**
```powershell
auditpol /get /subcategory:"Credential Validation"
# Should show: Success and Failure
```

**7. Test authentication with specific credentials**
```powershell
# Test NTLM auth explicitly (for file share)
$cred = Get-Credential
$unc = "\\<serverIP>\<share>"   # Use IP to force NTLM
Test-Path -Path $unc -Credential $cred
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify Whether NTLM Is Actually Being Used

```powershell
# Enable NTLM operational logging (on resource server or DC)
# Network security: Restrict NTLM: Audit NTLM authentication in this domain
# Set to: Enable all

# Then check operational NTLM log
Get-WinEvent -LogName "Microsoft-Windows-NTLM/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Format-List
```

### Phase 2 — Determine Failure Category

```powershell
# On DC — correlate 4776 error codes
$events = Get-WinEvent -ComputerName <DC> -FilterHashtable @{
    LogName   = "Security"
    Id        = 4776
    StartTime = (Get-Date).AddHours(-1)
} | ForEach-Object {
    $xml = [xml]$_.ToXml()
    [PSCustomObject]@{
        Time        = $_.TimeCreated
        AccountName = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "TargetUserName" } | Select-Object -Exp "#text"
        Workstation = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "Workstation" } | Select-Object -Exp "#text"
        ErrorCode   = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "Status" } | Select-Object -Exp "#text"
    }
}

$events | Group-Object ErrorCode | Sort-Object Count -Descending | Format-Table -AutoSize
```

**Error code reference:**
- `0x0` = Success
- `0xC000006A` = Wrong password
- `0xC0000064` = No such user
- `0xC000006D` = Generic logon failure (often LM level mismatch)
- `0xC0000234` = Account locked out
- `0xC000015B` = Logon type not granted
- `0xC0000193` = Account expired

### Phase 3 — Secure Channel Diagnostics (on resource server)

```powershell
# 1. Check secure channel
$domain = (Get-WmiObject Win32_ComputerSystem).Domain
nltest /sc_query:$domain

# 2. If broken, reset it
nltest /sc_reset:$domain

# 3. Verify NetLogon is running
Get-Service -Name Netlogon | Select-Object Status, StartType

# 4. Check NetLogon log for errors
$netlogonLog = "$env:SystemRoot\debug\netlogon.log"
if (Test-Path $netlogonLog) {
    Get-Content $netlogonLog -Tail 50 | Where-Object { $_ -match "ERROR|CRITICAL|failed" }
}
```

### Phase 4 — LM Level Compatibility Check (DC-side)

```powershell
# Run on DC to see what level it's configured at
$lmLevel = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").LmCompatibilityLevel
Write-Host "DC LM Level: $lmLevel"

# Find clients still sending NTLMv1 (Event 4776 + check logon process)
# Logon Process = "NtLmSsp" = NTLM; "Kerberos" = Kerberos
# NTLM Operational log Event ID 4001 = NTLMv1 attempt
Get-WinEvent -LogName "Microsoft-Windows-NTLM/Operational" |
    Where-Object { $_.Id -eq 4001 } |
    Select-Object TimeCreated, Message |
    Format-List
```

### Phase 5 — NTLM Restriction Policy Audit

```powershell
# Check all NTLM restriction settings (servers and DCs)
$settings = [ordered]@{
    "LmCompatibilityLevel"          = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").LmCompatibilityLevel
    "NTLMMinClientSec"              = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").NTLMMinClientSec
    "NTLMMinServerSec"              = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").NTLMMinServerSec
    "RestrictNTLMInDomain"          = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" -ErrorAction SilentlyContinue).RestrictNTLMInDomain
    "RestrictSendingNTLMTraffic"    = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" -ErrorAction SilentlyContinue).RestrictSendingNTLMTraffic
    "RestrictReceivingNTLMTraffic"  = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" -ErrorAction SilentlyContinue).RestrictReceivingNTLMTraffic
}
$settings | Format-Table -AutoSize
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — LM Level Mismatch (Client vs. DC)</summary>

**Symptom:** NTLM auth fails after DC hardened to LM Level 5; legacy clients fail.

**Cause:** DC set to `LmCompatibilityLevel = 5` (NTLMv2 only; refuse LM/NTLM), but clients still at level 2 or lower.

**Diagnosis:**
```powershell
# Find clients sending NTLMv1 (Event 4001 in NTLM Operational log on DC)
Get-WinEvent -ComputerName <DC> -LogName "Microsoft-Windows-NTLM/Operational" |
    Where-Object { $_.Id -eq 4001 } |
    Select-Object TimeCreated, @{N="Source"; E={$_.MachineName}}
```

**Fix (staged approach):**
1. Set DC to Level 3 temporarily (NTLMv2 only — doesn't refuse v1 yet)
2. Push Level 3 to all clients via GPO
3. After verification, advance DC to Level 5

```powershell
# On DC — temporary rollback to Level 3 (still secure, doesn't refuse NTLMv1)
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LmCompatibilityLevel -Value 3
```

```
GPO Path: Computer Config → Windows Settings → Security Settings →
Local Policies → Security Options →
"Network security: LAN Manager authentication level" = Send NTLMv2 response only
```

**Rollback:** Revert LM level registry value or GPO setting.

</details>

<details><summary>Playbook 2 — NTLM Pass-Through Failing (Broken Secure Channel)</summary>

**Symptom:** NTLM auth fails on specific server only; DCs healthy; Event 5719/5722 on resource server.

**Fix:**
```powershell
# Step 1: Verify NetLogon service
Get-Service Netlogon | Start-Service

# Step 2: Test and reset secure channel
$domain = (Get-ADDomain).DNSRoot
$result = nltest /sc_query:$domain
Write-Host $result

# Reset if broken:
nltest /sc_reset:$domain

# Step 3: Unjoin and rejoin if reset fails (last resort)
# Get admin creds ready before this step
Test-ComputerSecureChannel -Repair -Credential (Get-Credential)

# Step 4: Verify
nltest /sc_verify:$domain
```

**Rollback:** No destructive changes until unjoin/rejoin step.

</details>

<details><summary>Playbook 3 — NTLM Blocked by Restriction Policy</summary>

**Symptom:** `RestrictSendingNTLMTraffic = 2` (Deny all) blocking service accounts to legacy apps.

**Fix — add exception for specific server:**
```powershell
# GPO Path:
# Computer Config → Windows Settings → Security Settings → Local Policies → Security Options →
# "Network security: Restrict NTLM: Add remote server exceptions for NTLM authentication"

# Add exception via registry (if not using GPO)
$path = "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters\AllowNTLMForDomainTo"
New-Item $path -Force | Out-Null
Set-ItemProperty $path -Name "<serverFQDN>" -Value ""
```

**Note:** Prefer Kerberos migration over adding exceptions long-term. See Kerberos-A.md.

**Rollback:** Remove registry exception or remove from GPO exception list.

</details>

<details><summary>Playbook 4 — IIS NTLM Authentication 401 Loop</summary>

**Symptom:** Web app on IIS keeps prompting for credentials; browser doesn't pass Windows auth.

**Cause:** IIS Negotiate order wrong, SPN missing, or Extended Protection mismatch.

**Fix:**
```powershell
# Check IIS authentication providers (run on IIS server)
Import-Module WebAdministration

# List authentication providers for site
$site = "<SiteName>"
Get-WebConfiguration "system.webServer/security/authentication/windowsAuthentication/providers/add" `
    -PSPath "IIS:\Sites\$site" | Select-Object value

# Correct order should be: Negotiate (Kerberos first), NTLM (fallback)
# If order is wrong, fix:
Remove-WebConfigurationProperty -PSPath "IIS:\Sites\$site" `
    -Filter "system.webServer/security/authentication/windowsAuthentication/providers" -Name "."
Add-WebConfiguration "system.webServer/security/authentication/windowsAuthentication/providers" `
    -PSPath "IIS:\Sites\$site" -Value @{value="Negotiate"}
Add-WebConfiguration "system.webServer/security/authentication/windowsAuthentication/providers" `
    -PSPath "IIS:\Sites\$site" -Value @{value="NTLM"}
```

**Check Extended Protection setting:**
```powershell
Get-WebConfigurationProperty -PSPath "IIS:\Sites\$site" `
    -Filter "system.webServer/security/authentication/windowsAuthentication" -Name "extendedProtection.tokenChecking"
# "None" = EPA disabled; "Require" = EPA mandatory; "Allow" = try EPA, fallback
```

**Rollback:** Restore original provider order; revert extendedProtection setting.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  NTLM Authentication Evidence Collection
.NOTES     Run as Administrator on the resource server and/or DC.
           Safe — read-only except nltest which has no side effects in query mode.
#>

$report = @{}
$domain = (Get-WmiObject Win32_ComputerSystem).Domain

# 1. LM authentication level
$lsa = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
$report["LMLevel"] = [PSCustomObject]@{
    LmCompatibilityLevel = $lsa.LmCompatibilityLevel
    NTLMMinClientSec     = $lsa.NTLMMinClientSec
    NTLMMinServerSec     = $lsa.NTLMMinServerSec
}

# 2. NTLM restriction settings
$netlogonParams = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" -ErrorAction SilentlyContinue
$report["NTLMRestrictions"] = [PSCustomObject]@{
    RestrictNTLMInDomain         = $netlogonParams.RestrictNTLMInDomain
    RestrictSendingNTLMTraffic   = $netlogonParams.RestrictSendingNTLMTraffic
    RestrictReceivingNTLMTraffic = $netlogonParams.RestrictReceivingNTLMTraffic
}

# 3. Secure channel status
$scQuery = & nltest /sc_query:$domain 2>&1
$report["SecureChannel"] = $scQuery -join "`n"

# 4. NetLogon service status
$report["NetLogonService"] = Get-Service Netlogon | Select-Object Name, Status, StartType

# 5. DC connectivity
$dc = (& nltest /dsgetdc:$domain 2>&1) -match "DC:" | Select-Object -First 1
$report["DCConnectivity"] = [PSCustomObject]@{
    DCQuery     = $dc
    Port445     = (Test-NetConnection -ComputerName ($dc -replace ".*\\\\","" -replace "\[.*","").Trim() -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded
}

# 6. Recent NTLM events (local)
$report["NTLMOperationalEvents"] = Get-WinEvent -LogName "Microsoft-Windows-NTLM/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message

# 7. Recent Security event 4776 (if on DC)
$report["SecurityEvent4776"] = Get-WinEvent -FilterHashtable @{
    LogName   = "Security"
    Id        = 4776
    StartTime = (Get-Date).AddHours(-1)
} -ErrorAction SilentlyContinue | Select-Object -First 20 TimeCreated, Message

# Export
$ts = Get-Date -Format "yyyyMMdd-HHmm"
$outFile = "$env:TEMP\NTLMEvidence-$ts.json"
$report | ConvertTo-Json -Depth 5 | Out-File $outFile -Encoding UTF8
Write-Host "Evidence saved to: $outFile" -ForegroundColor Cyan

# Display summary
Write-Host "`n=== LM Level ===" -ForegroundColor Yellow
$report["LMLevel"] | Format-List
Write-Host "`n=== NTLM Restrictions ===" -ForegroundColor Yellow
$report["NTLMRestrictions"] | Format-List
Write-Host "`n=== Secure Channel ===" -ForegroundColor Yellow
Write-Host $report["SecureChannel"]
```

---

## Command Cheat Sheet

| Action | Command |
|--------|---------|
| Check LM auth level | `(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").LmCompatibilityLevel` |
| Check NTLM restriction | `Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters"` |
| Query secure channel | `nltest /sc_query:<domain>` |
| Reset secure channel | `nltest /sc_reset:<domain>` |
| Repair computer trust | `Test-ComputerSecureChannel -Repair -Credential (Get-Credential)` |
| Force secure channel verify | `nltest /sc_verify:<domain>` |
| Get DC for domain | `nltest /dsgetdc:<domain>` |
| Check NetLogon service | `Get-Service Netlogon` |
| View NetLogon log | `Get-Content "$env:SystemRoot\debug\netlogon.log" -Tail 50` |
| View NTLM events | `Get-WinEvent -LogName "Microsoft-Windows-NTLM/Operational" -MaxEvents 50` |
| View event 4776 on DC | `Get-WinEvent -FilterHashtable @{LogName="Security";Id=4776}` |
| Test auth (force NTLM via IP) | `Test-Path "\\<IP>\<share>" -Credential (Get-Credential)` |
| Enable NTLM auditing (GPO) | `auditpol /set /subcategory:"Credential Validation" /success:enable /failure:enable` |
| Check IIS auth providers | `Get-WebConfiguration ".../windowsAuthentication/providers/add" -PSPath "IIS:\Sites\<site>"` |

---

## 🎓 Learning Pointers

- **IP address = NTLM, hostname = Kerberos (usually).** This is the single most important NTLM trigger to understand. Connecting to `\\server01\share` attempts Kerberos; connecting to `\\10.0.0.5\share` falls back to NTLM immediately. If you're seeing unexplained NTLM in your audit logs, check whether users or applications are connecting by IP. See: [Choosing between Kerberos and NTLM](https://learn.microsoft.com/en-us/windows-server/security/kerberos/ntlm-overview)

- **Event 4776 is your ground truth on DCs.** Every NTLM authentication attempt — success or failure — is logged as Event 4776 on the DC that validated it. The error status codes (0xC000006A, 0xC0000234, etc.) tell you exactly what failed. Always start here before guessing. Enable Credential Validation auditing if it isn't on: `auditpol /set /subcategory:"Credential Validation" /success:enable /failure:enable`

- **LM Level mismatch is a silent breaker.** Advancing the DC to Level 5 without staging clients first will silently break all NTLM auth from legacy clients. The correct order: audit NTLMv1 senders → push Level 3 to clients → advance DC. Microsoft's guidance: [Configure LAN Manager](https://learn.microsoft.com/en-us/windows/security/threat-protection/security-policy-settings/network-security-lan-manager-authentication-level)

- **Broken secure channel is a resource-server problem, not a user problem.** If one server starts failing NTLM for everyone, the culprit is almost always the NetLogon secure channel between that server and its DC. `nltest /sc_query` → `nltest /sc_reset` resolves this in seconds. Don't start resetting user passwords.

- **NTLM Restrict policies have three granularities.** `RestrictSendingNTLMTraffic` controls what this machine sends; `RestrictReceivingNTLMTraffic` controls what it accepts; `RestrictNTLMInDomain` is a DC-level control. Getting the wrong level wrong is a common post-hardening break. Always add exceptions before enabling restriction, not after. See: [NTLM Restriction](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-R2-and-2008/jj865388(v=ws.10))

- **Extended Protection for Authentication (EPA) breaks old NTLM relayers but also breaks misconfigured apps.** If you enable EPA on IIS (`extendedProtection.tokenChecking = Require`) and your load balancer is doing SSL offloading, NTLM auth will fail because the inner TLS channel hash won't match. Always set to `Allow` first, then `Require` after confirming your network path supports it. See: [Extended Protection for Authentication](https://learn.microsoft.com/en-us/dotnet/framework/wcf/feature-details/extended-protection-for-authentication-overview)
