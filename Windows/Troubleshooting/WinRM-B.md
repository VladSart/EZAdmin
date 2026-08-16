# WinRM / PowerShell Remoting — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these first. Results tell you which fix path to take.

```powershell
# 1. Is WinRM even running, and is a listener actually configured?
Get-Service WinRM | Select-Object Status, StartType
winrm enumerate winrm/config/listener

# 2. Can the target be reached on the WinRM ports at all?
Test-NetConnection -ComputerName <target> -Port 5985   # HTTP
Test-NetConnection -ComputerName <target> -Port 5986   # HTTPS

# 3. What does a real connection attempt actually say?
Test-WSMan -ComputerName <target> -ErrorAction Stop

# 4. Is this a domain-joined Kerberos path or a workgroup/NTLM path?
(Get-CimInstance Win32_ComputerSystem).PartOfDomain
Get-Item WSMan:\localhost\Client\TrustedHosts

# 5. Is a GPO managing WinRM on the target (this changes which fix applies)?
Get-Item WSMan:\localhost\Service\Auth\* -ErrorAction SilentlyContinue
gpresult /r /scope:computer | Select-String -Pattern "WinRM|Remote Management" -Context 0,3
```

| If | Then |
|----|------|
| `Test-NetConnection` port test fails | Firewall or network path blocked → **Fix 1** |
| Port reachable, `Test-WSMan` fails with "Access is denied" | Credentials wrong, or NTLM path needs `TrustedHosts` → **Fix 2** |
| `Enable-PSRemoting` itself fails with "conflicting Group Policy setting" | A GPO already owns WinRM config on this box → **Fix 3** |
| Works to one server, fails to a second resource *from inside* that remote session | Kerberos double-hop — credentials don't forward → **Fix 4** |
| Error mentions CredSSP / "Encryption Oracle Remediation" | CVE-2018-0886 patch level mismatch between client and server → **Fix 5** |
| Error is "WinRM cannot process the request" under heavy concurrent/automation load, not on a single interactive attempt | WSMan quota exhaustion (`MaxShellsPerUser` / `MaxConcurrentOperationsPerUser`) → **Fix 6** |
| Target is not domain-joined, or connecting by IP instead of name | Kerberos isn't available for this path — needs `TrustedHosts` or HTTPS → **Fix 2** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
WinRM service running on the target
        │
Listener bound (HTTP 5985 and/or HTTPS 5986)
        │
Firewall rule "WINRM-HTTP-In-TCP" / "WINRM-HTTPS-In-TCP" enabled for the active network profile
   (Public profile is EXCLUDED by default — a box on a "Public" profile is unreachable
    even with a perfectly configured listener)
        │
Network path reachable (routing, NSG, on-prem firewall) on 5985/5986
        │
Authentication succeeds:
   - Kerberos (domain-joined ↔ domain-joined, connecting by name not IP) — no TrustedHosts needed
   - NTLM (workgroup, cross-domain, or by-IP) — REQUIRES client-side TrustedHosts entry, or HTTPS
        │
Session configuration (Microsoft.PowerShell / JEA endpoint) exists and grants the caller access
        │
[If a second hop is needed] credential delegation mechanism configured
   (CredSSP, or Kerberos constrained/resource-based constrained delegation)
        │
Command executes in the remote session and returns output
```

**The one Group Policy short-circuit:** if "Allow remote server management through WinRM" is Enabled or Disabled via GPO, the GPO's listener/firewall configuration overrides anything `Enable-PSRemoting`/`winrm quickconfig` tries to set locally. Running the local cmdlet against a GPO-managed box doesn't fail silently — it throws a specific, named error — but that error is easy to misread as a permissions problem.

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the service and listener exist:**
```powershell
Get-Service WinRM | Select-Object Status, StartType
winrm enumerate winrm/config/listener
```
Expected: `Status = Running`, at least one listener with `Transport = HTTP` (and `HTTPS` if configured) and a non-empty `ListeningOn` address list.
If no listener exists → this box was never remoted-into; run `Enable-PSRemoting -Force` (see Fix 3 first if a GPO is in play).

**2. Confirm network reachability, independent of WinRM itself:**
```powershell
Test-NetConnection -ComputerName <target> -Port 5985
```
Expected: `TcpTestSucceeded = True`.
If `False` → stop here. This is firewall/routing, not a WinRM configuration problem. Fix 1.

**3. Confirm the network profile on the target isn't Public:**
```powershell
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory
```
Expected: `DomainAuthenticated` or `Private`. If `Public`, the default WinRM firewall rules do not apply — this is the single most common "I ran Enable-PSRemoting and it still doesn't work" root cause on non-domain machines.

**4. Test the actual protocol handshake, not just the port:**
```powershell
Test-WSMan -ComputerName <target> -ErrorAction Stop
```
A successful port test with a failed `Test-WSMan` means the listener responded but authentication/negotiation failed — move to the credential-path checks (steps 5–6), not the firewall.

**5. Determine which authentication path applies:**
```powershell
# Is this domain ↔ domain, connecting by hostname/FQDN (not IP)?
nslookup <target>
Resolve-DnsName <target>
```
Kerberos requires: both machines domain-joined (same domain or a trusted domain), connection made by name (not IP), and no SPN mismatch. Any of those false → this is an NTLM path, which requires `TrustedHosts` on the client or an HTTPS listener with a trusted certificate.

**6. Check TrustedHosts (only relevant for the NTLM path):**
```powershell
Get-Item WSMan:\localhost\Client\TrustedHosts
```
Empty/blank and the target isn't reachable via Kerberos → this is why authentication fails. See Fix 2.

**7. If this is a "works directly, fails when the remote command tries to reach a third resource" symptom, confirm it's the double-hop problem:**
```powershell
# Run INSIDE the remote session
whoami /groups | Select-String "NT AUTHORITY\\Authenticated Users"
# If the remote session can't reach a file share/SQL server/second computer
# that the SAME account can reach when logged on locally, this is double-hop.
```
See Fix 4.

---

## Common Fix Paths

<details><summary>Fix 1 — Port unreachable (firewall / network path)</summary>

**Symptom:** `Test-NetConnection -Port 5985` returns `TcpTestSucceeded = False`.

```powershell
# On the TARGET — confirm the firewall rules exist and are enabled for the active profile
Get-NetFirewallRule -DisplayName "WinRM*" | Select-Object DisplayName, Enabled, Profile, Direction

# Re-enable if disabled
Enable-NetFirewallRule -DisplayName "Windows Remote Management (HTTP-In)"

# If the active network profile is Public, the default rule won't apply.
# Either change the profile (only if appropriate for this network) or scope the rule to all profiles:
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory
Set-NetFirewallRule -DisplayName "Windows Remote Management (HTTP-In)" -Profile Any

# Retest
Test-NetConnection -ComputerName <target> -Port 5985
```

**Rollback:**
```powershell
Set-NetFirewallRule -DisplayName "Windows Remote Management (HTTP-In)" -Profile Domain,Private
```

If the firewall on the target is clean and it still fails, the block is upstream (network firewall, NSG, VPN split-tunnel) — escalate to network team with the `Test-NetConnection` output as evidence.

</details>

<details><summary>Fix 2 — Access denied / NTLM path needs TrustedHosts</summary>

**Symptom:** Port reachable, `Test-WSMan` or `Enter-PSSession` fails with "Access is denied" and the target is a workgroup machine, a different (untrusted) domain, or being reached by IP.

```powershell
# Confirm this really is the NTLM path (Kerberos not usable)
(Get-CimInstance Win32_ComputerSystem).PartOfDomain
# If both machines ARE domain-joined and in the same/trusted domain, and you're
# still hitting this, you're likely connecting by IP — switch to hostname/FQDN
# instead of adding TrustedHosts, since Kerberos requires a name, not an IP.

# Add the target to TrustedHosts (client-side, NTLM path only)
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "<target>" -Concatenate -Force

# Verify
Get-Item WSMan:\localhost\Client\TrustedHosts

# Retest with explicit credentials
Test-WSMan -ComputerName <target> -Credential (Get-Credential)
```

**Prefer HTTPS over TrustedHosts where possible** — TrustedHosts disables server identity verification entirely for that entry (the client will trust ANY host claiming that name). For anything crossing a network boundary you don't fully control, configure an HTTPS listener with a real certificate instead:
```powershell
# On the target, once a cert with a matching CN/SAN is in the local machine store:
winrm create winrm/config/listener?Address=*+Transport=HTTPS '@{Hostname="<target-fqdn>";CertificateThumbprint="<thumbprint>"}'
```

**Rollback:**
```powershell
Clear-Item WSMan:\localhost\Client\TrustedHosts -Force
```

</details>

<details><summary>Fix 3 — "Cannot complete the request due to a conflicting Group Policy setting"</summary>

**Symptom:** `Enable-PSRemoting -Force` or `winrm quickconfig` fails with this exact message, or WinRM behaves as if configuration changes aren't sticking.

```powershell
# Confirm a GPO is managing WinRM (not just leftover local config)
gpresult /h C:\Temp\gpresult.html /f
# Open the report, search "Windows Remote Management" — look under
# Computer Configuration → Administrative Templates → Windows Components → Windows Remote Management (WinRM)

# Read the current effective listener/service config
winrm get winrm/config
```

**This is not a bug — the GPO is working as designed and always wins.** Do not fight it locally. Two real fixes:

1. **The GPO already enables WinRM correctly** (most common — many environments deploy "Allow remote server management through WinRM" precisely so `Enable-PSRemoting` is unnecessary). Just connect — no local action needed. The "conflicting policy" error only appears when you try to *re-configure* something GPO already owns, not when connecting.
2. **The GPO needs to be changed** for this population of machines (e.g. adding an IP range, changing auth methods): edit the actual GPO (`Computer Configuration → Administrative Templates → Windows Components → Windows Remote Management (WinRM) → WinRM Service → Allow remote server management through WinRM`), not the local machine.

**Do not** set the policy to "Not Configured" locally to work around this on a single machine unless you're prepared to also remove it from the GPO for that OU/machine — GPO refresh will silently re-apply the conflict on the next cycle (typically 90–120 min).

</details>

<details><summary>Fix 4 — Double-hop: remote session can't reach a second resource</summary>

**Symptom:** `Enter-PSSession -ComputerName ServerA` succeeds, but a command run *inside* that session that tries to reach ServerB, a file share, or a database fails with access denied — even though the same account can reach ServerB fine when logged on directly.

This is the Kerberos double-hop problem: your credentials authenticate the first hop (client → ServerA) but are not forwarded for ServerA to use on your behalf against ServerB.

**Fastest unblock (lab / short-term only) — CredSSP:**
```powershell
# On the CLIENT
Enable-WSManCredSSP -Role Client -DelegateComputer ServerA -Force

# On ServerA (the middle hop)
Enable-WSManCredSSP -Role Server -Force

# Connect using CredSSP
Enter-PSSession -ComputerName ServerA -Authentication Credssp -Credential (Get-Credential)
```
**CredSSP sends your credentials to ServerA in a form ServerA can replay anywhere** — treat this as a compensating control for testing, not a production pattern. Disable it once done:
```powershell
Disable-WSManCredSSP -Role Client
# (run on ServerA) Disable-WSManCredSSP -Role Server
```

**Correct production fix — Resource-Based Constrained Delegation (RBCD):** configure delegation on ServerB's own object so it explicitly trusts ServerA to act on a user's behalf, without any client-side configuration. This is the current Microsoft-recommended approach — see `../../ActiveDirectory/Troubleshooting/KerberosDelegation/Delegation-A.md` for the full RBCD configuration and the classic-constrained-delegation alternative (only if ServerA and ServerB are in the same domain).

**Rollback:** `Disable-WSManCredSSP` as shown above; RBCD changes are reverted by clearing `msDS-AllowedToActOnBehalfOfOtherIdentity` on ServerB's computer object (see the delegation runbook for the exact command).

</details>

<details><summary>Fix 5 — CredSSP / Encryption Oracle Remediation mismatch</summary>

**Symptom:** CredSSP connection fails with an error referencing "Encryption Oracle Remediation" or the connection is refused after CredSSP is enabled on both sides.

```powershell
# Check the policy level on BOTH client and server
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters" -Name AllowEncryptionOracle -ErrorAction SilentlyContinue
```

This is CVE-2018-0886 patch behavior: modern Windows defaults to "Force updated clients," which refuses CredSSP to any peer that hasn't received the corresponding security update. It is **not** a bug to route around by weakening the policy — patch the older peer instead. If you cannot patch it immediately and must unblock as a documented, time-boxed exception:
```powershell
# Only as a temporary compensating control on machines you control — do not leave set to "Vulnerable"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters" -Name AllowEncryptionOracle -Value 1 -Type DWord   # 1 = Mitigated
```

**Rollback:** remove the registry value (or set back to `0` = Force updated clients) once both peers are patched.

</details>

<details><summary>Fix 6 — WSMan quota exhaustion under automation/CI load</summary>

**Symptom:** Interactive `Enter-PSSession` works fine, but automation (CI pipelines, orchestration tools, parallel `Invoke-Command` fan-out) intermittently fails with "WinRM cannot process the request" or shells stop being created.

```powershell
# Check current quotas
winrm get winrm/config/winrs
Get-Item WSMan:\localhost\Shell\MaxShellsPerUser
Get-Item WSMan:\localhost\Plugin\Microsoft.PowerShell\Quotas\MaxConcurrentOperationsPerUser

# Raise quotas (defaults: MaxShellsPerUser=30, MaxConcurrentOperationsPerUser=1500)
Set-Item WSMan:\localhost\Shell\MaxShellsPerUser 100
winrm set winrm/config/winrs '@{MaxShellsPerUser="100"}'

# Also check for orphaned/stuck shells consuming the quota
Get-WSManInstance -ResourceURI shell -Enumerate
```

**Clear stuck shells if quota is exhausted by orphans, not legitimate load:**
```powershell
Get-WSManInstance -ResourceURI shell -Enumerate | ForEach-Object {
    Remove-WSManInstance -ResourceURI shell -SelectorSet @{ShellID=$_.ShellId}
}
```

**Rollback:** reset quotas to default with `winrm set winrm/config/winrs '@{MaxShellsPerUser="30"}'`.

</details>

---

## Escalation Evidence

```
=== WinRM / PowerShell Remoting Failure — Ticket Evidence ===

Date/Time:              _______________
Client machine:         _______________
Target machine:         _______________
Domain relationship:    _______________  (same domain / trusted domain / workgroup)
Connection method used: _______________  (hostname / FQDN / IP)
Error message (exact):  _______________

--- Commands Run ---
Test-NetConnection <target> -Port 5985:     TcpTestSucceeded = _______________
Test-WSMan <target>:                        _______________
Get-Service WinRM (on target):              _______________
Get-NetConnectionProfile (on target):       NetworkCategory = _______________
GPO managing WinRM confirmed (Y/N):         _______________
TrustedHosts entry present (Y/N):           _______________

--- Scenario ---
[ ] Single-hop only (client → target)
[ ] Double-hop (target needs to reach a third resource)
[ ] Failure only under automation/parallel load (possible quota exhaustion)
[ ] CredSSP involved

--- Steps Taken ---
[ ] Verified port reachability
[ ] Verified network profile is not Public
[ ] Checked for GPO-managed WinRM config
[ ] Verified Kerberos vs NTLM path and TrustedHosts accordingly
[ ] Checked WSMan quotas if under automation load
```

---

## 🎓 Learning Pointers

- **A GPO-managed WinRM configuration always wins over local `Enable-PSRemoting`** — and the resulting error message names the cause explicitly ("conflicting Group Policy setting"), so don't waste time re-running the cmdlet with `-Force` repeatedly. Check `gpresult` first. [MS Docs: about_Remote_Troubleshooting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_remote_troubleshooting)

- **TrustedHosts only matters for NTLM, and adding an entry doesn't fix a broken Kerberos path.** If two domain-joined machines in the same forest can't authenticate, the fix is in Kerberos (SPN, clock skew, DNS) — not `TrustedHosts`. Confirm which auth path actually applies before touching the trust list.

- **The double-hop problem has one durable fix: resource-based constrained delegation, not CredSSP.** CredSSP is a legitimate short-term compensating control, but it hands your credentials to the middle hop in a replayable form. This repo's own delegation runbook covers RBCD configuration in full — cross-reference it rather than defaulting to CredSSP for anything that will run more than once. See `../../ActiveDirectory/Troubleshooting/KerberosDelegation/Delegation-A.md`.

- **`Enable-PSRemoting` does more than start a service** — it registers the `Microsoft.PowerShell` session configuration, creates the listener, opens the firewall rule, and (on non-domain machines) may need the network profile to not be Public. Any one of those missing produces a different, specific failure mode; don't assume "I ran Enable-PSRemoting" means all of them succeeded — check each independently.

- **WSMan has its own quota system independent of the OS's general resource limits** (`MaxShellsPerUser`, `MaxConcurrentOperationsPerUser`). This is invisible until automation or parallel tooling hits it, and the resulting error looks identical to a generic connectivity failure. If failures correlate with load rather than a specific machine, check quotas before firewall rules.

- **CredSSP's "Encryption Oracle Remediation" refusal (CVE-2018-0886) is intentional, not a misconfiguration** — Windows will not downgrade to protect an unpatched peer. Patch the peer; don't set the policy to `Vulnerable` as a permanent fix. [MS Docs: CVE-2018-0886 guidance](https://support.microsoft.com/en-us/topic/credssp-updates-for-cve-2018-0886-5cbf9e5f-dc6d-744f-9e97-7ba024efb2ea)
