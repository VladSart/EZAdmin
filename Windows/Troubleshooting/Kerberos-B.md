# Kerberos Authentication Failures — Hotfix Runbook (Mode B: Ops)
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

Run these on the **affected client** as an administrator. Results guide you to the right fix path.

```powershell
# 1. Check current Kerberos ticket cache
klist

# 2. Check time skew between client and DC (must be < 5 minutes)
w32tm /query /status
net time /domain

# 3. Check DNS resolution of the domain
Resolve-DnsName <domain.com> -Type A
Resolve-DnsName _kerberos._tcp.<domain.com> -Type SRV

# 4. Check domain join health
nltest /sc_verify:<domain.com>
nltest /dsgetdc:<domain.com> /force

# 5. Check for recent Kerberos/NTLM errors in Security event log
Get-WinEvent -LogName Security -MaxEvents 100 |
    Where-Object { $_.Id -in @(4768,4769,4771,4776) } |
    Select-Object TimeCreated, Id, Message |
    Format-List | Out-Host -Paging
```

**Interpretation table:**

| Result | What it means | Go to |
|---|---|---|
| `klist` shows no tickets or tickets for wrong realm | Client has no valid TGT | [Fix 1 — Purge and re-request tickets](#fix-1--purge-and-re-request-kerberos-tickets) |
| Time skew > 5 minutes | Kerberos will reject authentication (KRB_AP_ERR_SKEW) | [Fix 2 — Fix time sync](#fix-2--fix-time-sync) |
| DNS resolution fails for domain | Client can't find DC | [Fix 3 — Fix DNS](#fix-3--fix-dns-so-kerberos-can-find-dcs) |
| `nltest /sc_verify` returns ERROR_NO_LOGON_SERVERS | Secure channel broken | [Fix 4 — Reset secure channel](#fix-4--reset-secure-channel) |
| Event 4771 (KDC_ERR_PREAUTH_FAILED) | Wrong credentials or locked account | Check account lockout; reset password |
| Event 4776 with error code 0xC000006D | NTLM fallback, credential mismatch | [Fix 5 — Force Kerberos, fix SPN](#fix-5--fix-spn-or-force-kerberos) |

---

## Dependency Cascade

<details><summary>What must be true for Kerberos to work</summary>

```
User logs in / accesses network resource
    │
    ▼
DNS resolves domain → finds KDC (Domain Controller)
    │   ← FAIL: client can't reach DC
    ▼
Clock skew < 5 minutes (client vs. DC)
    │   ← FAIL: KRB_AP_ERR_SKEW — authentication rejected
    ▼
Client requests TGT from KDC (AS-REQ → AS-REP)
    │   ← FAIL: 4771 — bad password, locked account, expired
    ▼
Client requests Service Ticket (TGS-REQ → TGS-REP)
    │   ← FAIL: SPN not registered, or registered on wrong account
    ▼
Client presents Service Ticket to target server
    │   ← FAIL: server can't decrypt (wrong service account, SPN mismatch)
    ▼
Access granted
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm tickets are present:**
```powershell
klist
```
Expected: Tickets listed for `krbtgt/<domain>` (TGT) and service tickets. Missing or expired → proceed to Fix 1.

**Step 2 — Confirm time is synchronised:**
```powershell
w32tm /query /status
```
Expected: `Leap Indicator: 0`, `Last Successful Sync Time` recent, `Source` points to a DC or NTP server.

**Step 3 — Confirm DC is reachable and responding:**
```powershell
nltest /sc_verify:<domain.com>
```
Expected: `Flags: ...WRITABLE DC LDAP...`, `Trusted domain:` info, final result `NERR_Success`.
Bad: `ERROR_NO_LOGON_SERVERS` or `ERROR_DOMAIN_CONTROLLER_NOT_FOUND`.

**Step 4 — Confirm SPN exists (for specific service failures):**
```powershell
# Run on a DC or machine with AD RSAT tools
setspn -Q HTTP/<servername>
setspn -Q HOST/<servername>
```
Expected: Lists account the SPN is registered to. Bad: `No such SPN found`.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Purge and re-request Kerberos tickets</summary>

**Use when:** Stale or corrupted tickets in cache. User recently changed password but old tickets persist.

```powershell
# Purge all Kerberos tickets
klist purge

# Re-request by reconnecting to a resource (e.g. a network share or mapping a drive)
# Or force a new TGT:
# Lock and unlock the machine, or log off/on
# On domain-joined: net use * /delete then try reconnecting

# Confirm new tickets issued
klist
```

If tickets are not re-issued after purge: check network connectivity to DC and proceed to Fix 3.

</details>

<details>
<summary>Fix 2 — Fix time sync</summary>

**Use when:** `w32tm /query /status` shows time more than 5 minutes off from domain time.

```powershell
# Run as administrator on the affected client

# Force sync with domain hierarchy
w32tm /resync /force

# If W32tm service is stopped
Start-Service W32Time
w32tm /resync /force

# If client is not syncing with domain (workgroup machine or VM with bad config):
w32tm /config /manualpeerlist:"<DC-IP-or-FQDN>" /syncfromflags:manual /update
w32tm /resync

# Verify
w32tm /query /status
net time /domain
```

For VMs: ensure the hypervisor time sync is configured correctly. On Hyper-V/Azure, disable the Hyper-V Time Synchronization service if the VM should sync from the domain hierarchy instead.

</details>

<details>
<summary>Fix 3 — Fix DNS so Kerberos can find DCs</summary>

**Use when:** `Resolve-DnsName _kerberos._tcp.<domain.com> -Type SRV` fails or returns no results.

```powershell
# Check current DNS server assignments
Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2

# Flush DNS cache
Clear-DnsClientCache

# Force DNS registration
ipconfig /registerdns

# Test SRV records exist
Resolve-DnsName _kerberos._tcp.<domain.com> -Type SRV
Resolve-DnsName _ldap._tcp.<domain.com> -Type SRV

# If wrong DNS server configured — set correct DNS (use DC IP)
# Replace 'Ethernet' with your actual adapter name
Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ServerAddresses '<DC-IP>'
```

**VPN/remote clients:** Ensure split DNS is configured so `<domain.com>` resolves via the on-premises DNS, not public DNS.

</details>

<details>
<summary>Fix 4 — Reset secure channel (broken trust)</summary>

**Use when:** `nltest /sc_verify:<domain.com>` returns errors. Computer account password may be out of sync.

```powershell
# Requires local admin — resets computer account password without domain admin
# Run on the affected machine
$credential = Get-Credential   # Use domain admin credentials
Test-ComputerSecureChannel -Repair -Credential $credential

# Verify
nltest /sc_verify:<domain.com>
```

If `Test-ComputerSecureChannel` fails, disjoin and rejoin the domain (last resort — requires backup of BitLocker key first).

**Rollback note:** Rejoining will not lose user data but will reset all machine-level GPO settings (reapplied on next GP refresh).

</details>

<details>
<summary>Fix 5 — Fix SPN or force Kerberos</summary>

**Use when:** Access to a specific service fails with "no credentials available" or NTLM is being used where Kerberos is expected.

```powershell
# On a DC or machine with AD RSAT — run as Domain Admin
# Check for duplicate or missing SPN
setspn -Q HTTP/<servername>
setspn -Q HTTP/<servername.domain.com>

# If SPN is missing — register it (replace values)
setspn -S HTTP/<servername> domain\<serviceaccount>
setspn -S HTTP/<servername.domain.com> domain\<serviceaccount>

# If SPN is registered to the wrong account — remove and re-add
setspn -D HTTP/<servername> domain\<wrongaccount>
setspn -S HTTP/<servername> domain\<correctaccount>

# Force Kerberos by testing with a fully-qualified name
# (NTLM is used for short names on same subnet; Kerberos for FQDN)
# E.g., instead of \\SERVER\share, use \\server.domain.com\share
```

After fixing SPN, purge tickets on the client (`klist purge`) and retry.

</details>

---

## Escalation Evidence

```
=== Kerberos Issue — Escalation Template ===
Date/Time:          ___________
Affected user(s):   ___________
Affected machine:   ___________
Domain:             ___________
DC contacted:       ___________

Symptom:
  [ ] No Kerberos tickets (klist shows none)
  [ ] Time skew error (KRB_AP_ERR_SKEW)
  [ ] Pre-auth failure (Event 4771, code: ___)
  [ ] Service ticket failure (Event 4769, code: ___)
  [ ] SPN not found / duplicate SPN
  [ ] Secure channel broken (nltest error: ___)

Output of klist:
  (paste here)

Output of w32tm /query /status:
  (paste here)

Output of nltest /sc_verify:<domain>:
  (paste here)

Output of setspn -Q <SPN>:
  (paste here)

Security event log (IDs 4768/4769/4771/4776):
  (paste relevant entries)

Steps already attempted:
  [ ] klist purge + retry
  [ ] w32tm /resync /force
  [ ] DNS flush + ipconfig /registerdns
  [ ] Test-ComputerSecureChannel -Repair
  [ ] SPN checked / fixed
```

---

## 🎓 Learning Pointers

- **Kerberos requires mutual trust through time:** The 5-minute skew limit is not arbitrary — it prevents replay attacks where an attacker captures and replays old authentication tokens. If you're seeing intermittent auth failures that correlate with DST changes, VM snapshot restores, or laptop sleep/wake cycles, time sync is almost always the culprit. [MS Docs — Kerberos and time](https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-authentication-overview)

- **NTLM silently masks Kerberos failures:** When Kerberos fails, Windows usually falls back to NTLM without informing the user. This means a user may appear to be working fine (NTLM auth succeeds) while Kerberos is broken. The giveaway is `klist` showing no tickets for the resource you expect. Use `klist -li 0x3e7` to see machine-level tickets too. [Identifying Kerberos vs NTLM](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/back-to-basics-using-kerberos-authentication)

- **Duplicate SPNs are silent killers:** If the same SPN is registered to two accounts, Kerberos cannot determine which account's key to use for encryption and will fail silently or fall back to NTLM. Run `setspn -X` in the domain to find all duplicate SPNs — this is a great proactive health check. [setspn documentation](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/cc731241(v=ws.11))

- **Event IDs 4768/4769/4771/4776 are your audit trail:** 4768 = TGT request, 4769 = service ticket request, 4771 = TGT failure (pre-auth), 4776 = NTLM auth attempt. These events are logged on DCs, not clients. For hybrid environments, check both on-premises DCs and Entra ID sign-in logs, as hybrid auth failures may appear in one but not both.

- **Constrained delegation is a common misconfiguration:** Web apps, SQL servers, and multi-hop RDP scenarios that pass credentials forward require constrained delegation (or resource-based constrained delegation). If "double-hop" scenarios fail (user → web server → SQL), Kerberos constrained delegation is almost always the cause. [Kerberos constrained delegation](https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-constrained-delegation-overview)
