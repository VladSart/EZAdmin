# NTLM Authentication — Hotfix Runbook (Mode B: Ops)
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

Run these on the **affected client** as an administrator. Results dictate the fix path.

```powershell
# T1: Check if NTLM is blocked by policy
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LmCompatibilityLevel' -ErrorAction SilentlyContinue

# T2: Check if outgoing NTLM is restricted (common cause in hardened envs)
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -Name 'RestrictSendingNTLMTraffic' -ErrorAction SilentlyContinue

# T3: Check NetLogon service state (NTLM relay point)
Get-Service Netlogon | Select-Object Name, Status, StartType

# T4: Recent NTLM authentication failures (Security event log)
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4776; StartTime=(Get-Date).AddHours(-1)} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Message -First 10 | Format-List

# T5: Check if Kerberos fallback is broken (SPN lookup)
# Replace <server> with the resource server name
klist get <server>
```

**Interpretation table:**

| Result | Meaning | Action |
|--------|---------|--------|
| `LmCompatibilityLevel = 5` | NTLMv1 blocked, only NTLMv2 (correct) | Expected — skip |
| `LmCompatibilityLevel` absent | Default (varies by OS) — legacy NTLMv1 may be allowed | Check if target requires v2 |
| `RestrictSendingNTLMTraffic = 2` | Outgoing NTLM **blocked** to all servers | Fix Path 1 |
| `RestrictSendingNTLMTraffic = 1` | Outgoing NTLM allowed only to domain | Fix Path 1 or whitelist |
| Netlogon = Stopped | NetLogon down — Kerberos & NTLM both fail | Fix Path 2 |
| Event 4776 (SubStatus 0xC000006A) | Wrong password on NTLM auth | Password issue — not NTLM config |
| Event 4776 (SubStatus 0xC0000064) | Account does not exist on authenticating DC | Target DC sync issue |
| `klist get` fails with no TGT | Kerberos broken → NTLM fallback forced | Fix Path 3 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Active Directory Domain Services
    └── Domain Controller (reachable on TCP 445, 135, 389)
            └── NetLogon service (on DC and client)
                    └── Secure Channel (NLTEST)
                            └── NTLM negotiation (NTLMv2)
                                    └── LsaLogon (LSA subsystem)
                                            └── Application authentication
```

**NTLM is a fallback.** In an AD environment, Kerberos is preferred. NTLM fires when:
- Client uses IP address instead of hostname
- No SPN registered for the target service
- Kerberos port 88 is blocked
- Authentication crosses a forest/domain boundary without a trust

If NTLM is failing, always check Kerberos health first — fixing Kerberos often eliminates the NTLM issue.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm it's NTLM failing (not Kerberos)**
```powershell
# Run on client as user experiencing the failure
klist tickets
```
- If tickets exist and are valid: Kerberos is working → NTLM issues are isolated
- If no TGT: Kerberos is broken → fix Kerberos first (see Kerberos runbook)

**Expected output (healthy):** `Cached Tickets: (5)` with krbtgt ticket present
**Bad output:** `Cached Tickets: (0)` → Kerberos not working, forcing NTLM

---

**Step 2 — Check Security event log on the DC authenticating the user**
```powershell
# Run on the DC (or use RPC from domain-joined admin machine)
Get-WinEvent -ComputerName <DC-Name> -FilterHashtable @{
    LogName   = 'Security'
    Id        = 4776
    StartTime = (Get-Date).AddMinutes(-30)
} | ForEach-Object {
    $xml = [xml]$_.ToXml()
    [PSCustomObject]@{
        Time         = $_.TimeCreated
        User         = $xml.Event.EventData.Data[1].'#text'
        Workstation  = $xml.Event.EventData.Data[2].'#text'
        ErrorCode    = $xml.Event.EventData.Data[3].'#text'
    }
} | Format-Table -AutoSize
```

| Error Code | Meaning |
|------------|---------|
| 0x0 | Success |
| 0xC000006A | Wrong password |
| 0xC0000064 | No such user (account doesn't exist on this DC) |
| 0xC000006D | Generic logon failure |
| 0xC0000234 | Account locked out |
| 0xC0000072 | Account disabled |

---

**Step 3 — Check if NTLM is being blocked at network or policy level**
```powershell
# Firewall check — NTLM uses RPC and SMB
Test-NetConnection -ComputerName <DC-Name> -Port 445
Test-NetConnection -ComputerName <DC-Name> -Port 135
Test-NetConnection -ComputerName <TargetServer> -Port 445

# Check NTLM restriction policy
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' |
    Select-Object RestrictSendingNTLMTraffic, RestrictReceivingNTLMTraffic, AuditReceivingNTLMTraffic
```

**Expected:** RestrictSendingNTLMTraffic = 0 (or absent); ports open

---

**Step 4 — Validate secure channel to DC**
```powershell
# Confirm domain secure channel is healthy
Test-ComputerSecureChannel -Verbose

# If broken, repair it (requires Domain Admin)
# Test-ComputerSecureChannel -Repair
```
**Good:** `True` returned
**Bad:** `False` → Secure channel broken → Fix Path 4

---

## Common Fix Paths

<details><summary>Fix 1 — NTLM blocked by RestrictSendingNTLMTraffic policy</summary>

**Symptom:** Apps fail with "Access denied" or "0x80070005" when using NTLM. Event 4776 not appearing on DC (NTLM auth never reaches DC).

**Check:**
```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -Name 'RestrictSendingNTLMTraffic' -ErrorAction SilentlyContinue
# 2 = Deny All, 1 = Allow domain only, 0 = Allow all (default)
```

**Option A: Add a specific server to the NTLM whitelist (preferred)**
```powershell
# GPO path: Computer Configuration → Windows Settings → Security Settings →
# Local Policies → Security Options →
# "Network security: Restrict NTLM: Add remote server exceptions for NTLM authentication"

# Via registry directly (for testing only — manage via GPO in production)
$path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
$existing = (Get-ItemProperty $path -Name 'ClientAllowedNTLMServers' -ErrorAction SilentlyContinue).ClientAllowedNTLMServers
$newList = ($existing + '<TargetServerName>') | Sort-Object -Unique
Set-ItemProperty $path -Name 'ClientAllowedNTLMServers' -Value $newList -Type MultiString
```

**Option B: Temporarily allow all NTLM (use to confirm, then revert)**
```powershell
# Rollback required — this reduces security posture
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -Name 'RestrictSendingNTLMTraffic' -Value 0 -Type DWord
# After confirming fix, re-enable restriction and use Option A whitelist
```

**Rollback:** Set `RestrictSendingNTLMTraffic` back to its original value. Push the whitelist via GPO/Intune CSP for permanent fix.

</details>

<details><summary>Fix 2 — NetLogon service stopped</summary>

**Symptom:** ALL domain authentication fails — Kerberos and NTLM both broken. `Test-ComputerSecureChannel` returns False.

```powershell
#Requires -RunAsAdministrator

# Check current state
Get-Service Netlogon | Select-Object Name, Status, StartType

# Start the service
Start-Service Netlogon
Set-Service Netlogon -StartupType Automatic

# Verify
Get-Service Netlogon | Select-Object Name, Status

# Re-test secure channel
Test-ComputerSecureChannel -Verbose
```

**If NetLogon won't start:**
```powershell
# Check dependencies
Get-Service Netlogon | Select-Object -ExpandProperty DependentServices
# Check Windows Event log for service error
Get-WinEvent -LogName System | Where-Object { $_.ProviderName -eq 'Service Control Manager' -and $_.Message -like '*Netlogon*' } | Select-Object -First 5 | Format-List
```

**Rollback:** N/A — starting a stopped legitimate service is non-destructive.

</details>

<details><summary>Fix 3 — Force Kerberos re-authentication to eliminate NTLM fallback</summary>

**Symptom:** Application using IP address or short name forces NTLM. NTLM fails due to policy. Fixing: register SPN and force hostname usage.

```powershell
# Step 1: Check if SPN is registered for the target service
setspn -L <ServiceAccountOrComputerName>

# Step 2: Register SPN if missing (run as Domain Admin)
# For a web service on server WEBSRV01 using HTTP
setspn -S HTTP/<FQDN-of-server> <domain\computeraccount>
setspn -S HTTP/<shortname-of-server> <domain\computeraccount>

# Step 3: Flush Kerberos ticket cache on client
klist purge

# Step 4: If app is using IP address, configure it to use the hostname
# (application-specific — update connection string or hosts file entry)

# Step 5: Validate Kerberos ticket obtained
klist get HTTP/<FQDN>
```

**Rollback:** Remove incorrectly added SPN: `setspn -D HTTP/<name> <account>`

</details>

<details><summary>Fix 4 — Repair broken secure channel (computer account)</summary>

**Symptom:** `Test-ComputerSecureChannel` returns False. NTLM fails with "The trust relationship between this workstation and the primary domain failed."

```powershell
#Requires -RunAsAdministrator

# Test first
$result = Test-ComputerSecureChannel -Verbose
Write-Host "Secure channel healthy: $result"

if (-not $result) {
    # Option A: Repair in-place (preferred — no re-join)
    # Requires Domain Admin credential
    $cred = Get-Credential -Message "Enter Domain Admin credential"
    Test-ComputerSecureChannel -Repair -Credential $cred

    # Verify
    Test-ComputerSecureChannel -Verbose

    # If repair fails, use nltest for more detail
    nltest /sc_verify:<DomainName>
    nltest /sc_reset:<DomainName>
}
```

**Option B (if Repair fails): Reset computer account password via netdom**
```powershell
netdom resetpwd /server:<DC-Name> /userd:<domain\DomainAdmin> /passwordd:*
```

**Rollback:** If repair causes login issues, re-join to domain: `Remove-Computer` then `Add-Computer`. Requires local admin account that is NOT domain-dependent.

</details>

<details><summary>Fix 5 — Enable NTLM audit to identify what's failing</summary>

**Symptom:** NTLM failures are sporadic or from unknown sources. Need visibility before blocking.

```powershell
# Enable NTLM incoming audit on a server or DC
# Run on the TARGET server receiving NTLM auth

Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' `
    -Name 'AuditReceivingNTLMTraffic' -Value 2 -Type DWord
# 0=Disabled, 1=Audit domain accounts only, 2=Audit all accounts

# Events appear in Security log as Event ID 4776

# To audit outgoing NTLM from a client:
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' `
    -Name 'RestrictSendingNTLMTraffic' -Value 1 -Type DWord  # Audit mode when set to 1

# Review audit after 30 min
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4776; StartTime=(Get-Date).AddMinutes(-30)} |
    Select-Object TimeCreated, Message | Format-List
```

**Rollback:** Set `AuditReceivingNTLMTraffic` back to 0 when investigation is complete.

</details>

---

## Escalation Evidence

```
NTLM Authentication — Escalation Ticket
========================================
Date/Time:          _______________
Reported By:        _______________
Affected User(s):   _______________
Affected System(s): _______________

--- TRIAGE OUTPUT ---
LmCompatibilityLevel value:          _______________
RestrictSendingNTLMTraffic value:    _______________
NetLogon service status:             _______________
Test-ComputerSecureChannel result:   _______________

--- EVENT DATA ---
Event ID 4776 SubStatus code(s):     _______________
DC that processed the auth:          _______________
Workstation name in event:           _______________

--- NETWORK CHECKS ---
TCP 445 to DC:                       Open / Blocked
TCP 135 to DC:                       Open / Blocked
TCP 88 (Kerberos) to DC:             Open / Blocked

--- SCOPE ---
All users affected? Yes / No
Only specific apps? _______________
Only from specific subnets? _______________
Started after change: _______________

--- FIXES ATTEMPTED ---
1. _______________
2. _______________

--- ATTACHED ---
[ ] nltest /sc_verify output
[ ] Event 4776 export (CSV)
[ ] gpresult /h output
[ ] Network trace (.etl or .pcap) if available
```

---

## 🎓 Learning Pointers

- **NTLM is a last resort, not a first choice.** In a healthy AD/Entra environment, Kerberos handles 95%+ of auth. If NTLM is involved in a failure, the first question is always "why did Kerberos not handle this?" — usually an SPN issue or IP address in the connection string. [MS Docs: NTLM Overview](https://learn.microsoft.com/windows-server/security/kerberos/ntlm-overview)

- **NTLMv1 vs NTLMv2:** NTLMv1 is cryptographically weak (pass-the-hash, relay attacks). All modern environments should enforce `LmCompatibilityLevel = 5` (Send NTLMv2 response only, refuse LM & NTLM). If you encounter legacy apps that require NTLMv1, the correct answer is fix the app, not lower security. [MS Docs: LmCompatibilityLevel](https://learn.microsoft.com/windows/security/threat-protection/security-policy-settings/network-security-lan-manager-authentication-level)

- **NTLM relay is a real attack vector.** If your environment has NTLM enabled broadly, it's vulnerable to NTLM relay attacks (e.g., PetitPotam, PrinterBug). Microsoft's guidance: enable EPA (Extended Protection for Authentication) on all IIS/Exchange, enable SMB signing, and restrict NTLM using the `RestrictSendingNTLMTraffic` policy. [MS Security Advisory: NTLM Relay](https://msrc.microsoft.com/update-guide/vulnerability/CVE-2021-36942)

- **Hybrid environments and NTLM:** When using Entra ID with hybrid join, NTLM authentication still flows through on-prem DCs. If your DCs are unreachable (VPN down, ExpressRoute failure), NTLM fails even for cloud-joined users trying to access on-prem resources. Design for DC reachability as a dependency.

- **Event ID 4776 vs 4624:** Event 4776 is the **credential validation** event (DC-side NTLM check). Event 4624 is the **successful logon** event. When triaging, look for 4776 on the DC first — if it's not there, NTLM auth never reached the DC (blocked at client or network layer).
