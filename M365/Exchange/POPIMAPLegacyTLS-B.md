# Exchange Online POP3/IMAP4 Legacy TLS Retirement — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Scope:** POP3 and IMAP4 client connections to **Exchange Online** that negotiate **TLS 1.0 or 1.1**, including clients pointed at the opt-in legacy endpoints `pop-legacy.office365.com` / `imap-legacy.office365.com`. Microsoft is retiring legacy TLS for these protocols in a gradual worldwide rollout from **1 August 2026 to 31 December 2026** (Message Center **MC1293480**, updated 7 July 2026 — originally announced for July). After your tenant is reached, TLS 1.0/1.1 POP/IMAP handshakes **fail**; there is no opt-out.
Not in scope: SMTP AUTH (`smtp.office365.com` / `smtp-legacy.office365.com`) — MC1293480 does not cover it; see `Mail-Flow-B.md` and `DirectSendAbuse-B.md`. EWS → `EWSRetirement-B.md`. Windows Schannel/PQC TLS changes → `Windows/Troubleshooting/PostQuantumTLS-B.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

Typical tickets (Aug–Dec 2026): *"scanner/ERP/helpdesk tool stopped collecting mail"*, *"IMAP login fails but the password/OAuth app is fine"*, *"works from my PC, fails from the old server"*, *"vendor says nothing changed"*.

```powershell
Connect-ExchangeOnline -ShowBanner:$false

# 1. Is the tenant opted in to the legacy endpoints? (shared switch — also gates smtp-legacy)
Get-TransportConfig | Format-List AllowLegacyTLSClients

# 2. Is POP/IMAP even enabled for the affected (often shared/service) mailbox?
Get-EXOCASMailbox -Identity <UPN> -PropertySets Pop,Imap |
    Format-List PopEnabled, ImapEnabled

# 3. From the FAILING host (not your admin PC): which TLS versions can it complete against EXO?
#    Run in Windows PowerShell on the affected server.
foreach ($p in 'Tls','Tls11','Tls12') {
    $tcp = [System.Net.Sockets.TcpClient]::new('outlook.office365.com', 993)
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false)
    try   { $ssl.AuthenticateAsClient('outlook.office365.com', $null, [System.Security.Authentication.SslProtocols]::$p, $false)
            "{0,-6} OK -> negotiated {1}" -f $p, $ssl.SslProtocol }
    catch { "{0,-6} FAILED: {1}" -f $p, $_.Exception.InnerException.Message }
    finally { $ssl.Dispose(); $tcp.Dispose() }
}

# 4. .NET Framework strong-crypto defaults on that host (the #1 hidden cause for in-house/older apps)
'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319','HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' |
    ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue | Select-Object PSPath, SchUseStrongCrypto, SystemDefaultTlsVersions }
```

| Result | Meaning | Action |
|---|---|---|
| Client configured for `pop-legacy`/`imap-legacy.office365.com` | It was *explicitly* kept on TLS 1.0/1.1 — first thing to break | → Fix 1 |
| Test 3: `Tls12 OK` on the host, but the app still fails | Host OS can do TLS 1.2; the **application** pins/defaults to 1.0/1.1 | → Fix 2 (.NET) or Fix 3 (vendor/device) |
| Test 3: `Tls12 FAILED` on the host | OS/Schannel can't do TLS 1.2 (old OS, disabled protocol, missing cipher suites) | → Fix 4 |
| Test 3: `Tls`/`Tls11 FAILED` with *"The client and server cannot communicate…"* and `Tls12 OK` | Expected once your tenant is in the rollout — server refuses legacy TLS | Confirms the cause; fix the client |
| Test 3 all OK incl. `Tls` (before your tenant is reached) | Legacy still accepted *today* — not the cause of *this* failure yet | Check auth (OAuth), PopEnabled/ImapEnabled, CA; see `Outlook-Client-B.md` |
| `SchUseStrongCrypto` / `SystemDefaultTlsVersions` absent or `0` on a .NET 4.x host | .NET 4.0–4.6.x apps may default to SSL3/TLS 1.0 | → Fix 2 |
| Embedded device (MFP/scanner, PBX, door system) with no firmware update | Frozen TLS library — cannot be fixed on-box | → Fix 3 (replace path / relay) |
| `PopEnabled`/`ImapEnabled : False` | Protocol off for that mailbox — unrelated to TLS | Enable (Fix 5) only if required |

> Note: POP/IMAP **Basic** authentication was already retired in Exchange Online (2022). A client that still works today is using **OAuth (XOAUTH2)** — so the TLS change is the *only* new variable. Don't let tickets drift into re-troubleshooting auth unless the error says so.

---
## Dependency Cascade

<details><summary>What must be true for a POP3/IMAP4 client to connect (Aug–Dec 2026 onward)</summary>

```
[Mailbox] PopEnabled / ImapEnabled = True (Get-EXOCASMailbox)
  └─ [Entra ID] OAuth token for the POP/IMAP scope (XOAUTH2) — app registration + consent
       │         (Basic auth for POP/IMAP no longer works in EXO)
       └─ [Network] Host → outlook.office365.com :995 (POP3S) / :993 (IMAPS) (or :110/:143 + STARTTLS)
            └─ [TLS] Handshake at TLS 1.2+   ← NEW HARD REQUIREMENT once tenant is in MC1293480 rollout
                 ├─ OS/Schannel (Windows) or OpenSSL/device stack supports TLS 1.2 + a supported cipher suite
                 ├─ Application doesn't pin SSL3/TLS1.0/TLS1.1
                 │    └─ .NET Framework 4.x apps: SchUseStrongCrypto / SystemDefaultTlsVersions = 1
                 └─ Endpoint is outlook.office365.com — NOT pop-legacy / imap-legacy
                      └─ [Legacy only] AllowLegacyTLSClients = True (org) — irrelevant after retirement
```
</details>

---
## Diagnosis & Validation Flow

1. **Identify the exact client, host and endpoint.**
   Ask for: hostname/IP of the machine that polls mail, product + version, configured server name and port.
   - Server = `pop-legacy.office365.com` / `imap-legacy.office365.com` → confirmed legacy-TLS dependency.
   - Server = `outlook.office365.com` but the app is old → still possible (the main endpoint also accepted TLS 1.0/1.1 until retirement).

2. **Reproduce the handshake from the failing host** (Triage step 3).
   Expected good: `Tls12 OK -> negotiated Tls12`.
   If `Tls12` fails from the host → OS problem (Fix 4). If `Tls12` works but the app fails → app problem (Fix 2/3).

3. **Check the tenant switch.**
   ```powershell
   Get-TransportConfig | Format-List AllowLegacyTLSClients
   ```
   `True` means someone opted in (Jan 2023 onward) — somewhere a client (POP/IMAP **or** SMTP AUTH) was pointed at a `*-legacy` endpoint. Find it before you turn it off (Fix 1).

4. **Find who actually uses POP/IMAP** (last 180 days; reports lag ~2 days).
   ```powershell
   Connect-MgGraph -Scopes Reports.Read.All
   Invoke-MgGraphRequest -Method GET -OutputFilePath .\EmailAppUsage.csv `
     -Uri "https://graph.microsoft.com/v1.0/reports/getEmailAppUsageUserDetail(period='D180')"
   Import-Csv .\EmailAppUsage.csv |
     Where-Object { $_.'POP3 App' -or $_.'IMAP4 App' } |
     Select-Object 'User Principal Name','POP3 App','IMAP4 App','Last Activity Date'
   ```
   If UPNs show as hashes, the tenant has report concealment on (M365 admin center → Settings → Org settings → Reports).

5. **Correlate with sign-ins** (which app registration and which source IP):
   ```powershell
   Connect-MgGraph -Scopes AuditLog.Read.All
   Get-MgAuditLogSignIn -Filter "clientAppUsed eq 'IMAP4' or clientAppUsed eq 'POP3'" -Top 200 |
     Select-Object CreatedDateTime, UserPrincipalName, AppDisplayName, ClientAppUsed, IPAddress, @{n='Result';e={$_.Status.ErrorCode}}
   ```
   Sign-in logs record the OAuth token request, **not** the TLS version — use them to find *which host* to test in step 2.

6. **Validate after the fix:** from the host, the app connects and the Triage step 3 test shows `Tls12 OK`. Mail is collected on the next poll.

---
## Common Fix Paths

<details><summary>Fix 1 — Move clients off pop-legacy / imap-legacy and (then) turn the opt-in off</summary>

1. Repoint each client to the standard endpoint:
   - POP3: `outlook.office365.com`, port **995**, SSL/TLS (or 110 + STARTTLS)
   - IMAP4: `outlook.office365.com`, port **993**, SSL/TLS (or 143 + STARTTLS)
2. Confirm the client connects at TLS 1.2 (Triage step 3 from its host).
3. Only when nothing uses any `*-legacy` endpoint (POP, IMAP **and** `smtp-legacy.office365.com`), opt out:
   ```powershell
   Set-TransportConfig -AllowLegacyTLSClients $false
   Get-TransportConfig | Format-List AllowLegacyTLSClients
   ```
   **Rollback:** `Set-TransportConfig -AllowLegacyTLSClients $true` — but understand this does **not** keep POP/IMAP legacy TLS alive once your tenant is reached by MC1293480. It only affects whatever the legacy endpoints still accept.
   ⚠️ The same switch (and EAC *Mail flow → Turn on use of legacy TLS clients*) gates the **SMTP AUTH** legacy endpoint. Check SMTP devices before opting out.
</details>

<details><summary>Fix 2 — .NET Framework application defaulting to TLS 1.0/1.1</summary>

Common for in-house tools, older helpdesk/CRM connectors and scheduled scripts built on .NET 4.0–4.6.x (e.g. `System.Net.Mail`, older MailKit builds on .NET Framework). Tell the runtime to use the OS defaults (TLS 1.2+):

```powershell
#Requires -RunAsAdministrator
$paths = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
         'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
foreach ($p in $paths) {
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    New-ItemProperty -Path $p -Name SchUseStrongCrypto       -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $p -Name SystemDefaultTlsVersions -Value 1 -PropertyType DWord -Force | Out-Null
}
# Restart the application / its service (or reboot) so the runtime rereads the values
```
**Rollback:** set both values back to their previous state (record them first with the Triage step 4 command) and restart the app.

For a PowerShell script that polls mail on **Windows PowerShell 5.1**, add at the top as a stop-gap:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
```
If the app hard-codes `SslProtocols.Tls` in code, registry keys won't help — it needs a code change or vendor update (Fix 3).
</details>

<details><summary>Fix 3 — Device or vendor app that cannot do TLS 1.2</summary>

1. Check vendor firmware/app updates for TLS 1.2 support (MFPs/scanners, PBX voicemail-to-mail collectors, archiving/ticketing connectors). Many only need a setting change (e.g. "TLS 1.2 only" / "Use modern security").
2. If no update exists, decide:
   - **Replace** the device/app, or
   - **Re-architect** away from POP/IMAP polling: Microsoft Graph mail API (recommended by Microsoft), or a Power Automate flow triggered on new mail in a shared mailbox, or
   - **Interim bridge**: a supported, TLS 1.2-capable mail-collection service/relay on a maintained host that the old device talks to locally. Treat as a documented, time-boxed exception (it's a security risk you own).
3. Record the exception and owner in the ticket; there is **no** Microsoft-side extension.
</details>

<details><summary>Fix 4 — Host OS cannot negotiate TLS 1.2</summary>

```powershell
# Is TLS 1.2 explicitly disabled in Schannel? (absent = OS default; Enabled=0 = disabled)
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -ErrorAction SilentlyContinue |
    Select-Object Enabled, DisabledByDefault
# OS build (Server 2008 R2 / Windows 7 need updates + explicit enablement; unsupported OSes = replace)
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber
```
If TLS 1.2 client is disabled:
```powershell
#Requires -RunAsAdministrator
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
New-Item -Path $k -Force | Out-Null
New-ItemProperty -Path $k -Name Enabled           -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $k -Name DisabledByDefault -Value 0 -PropertyType DWord -Force | Out-Null
# Reboot required for Schannel changes
```
**Rollback:** restore the previous values (or delete the `Client` key if it didn't exist) and reboot. Hardening baselines (GPO/Intune/IISCrypto) may re-apply their own values — fix at the source.
Unsupported OS (e.g. Server 2008/2012 non-ESU) → migrate the workload; don't patch around it.
</details>

<details><summary>Fix 5 — POP/IMAP disabled on the mailbox (unrelated to TLS)</summary>

```powershell
Set-CASMailbox -Identity <UPN> -ImapEnabled $true   # or -PopEnabled $true
Get-EXOCASMailbox -Identity <UPN> -PropertySets Pop,Imap | Format-List PopEnabled, ImapEnabled
```
**Rollback:** set back to `$false`. Enable only on the specific service mailbox that needs it — not tenant-wide (`Set-CASMailboxPlan`).
</details>

---
## Escalation Evidence

```
Ticket: POP/IMAP collection failure — suspected legacy TLS retirement (MC1293480)
Tenant (initial domain):            <tenant>.onmicrosoft.com
Affected mailbox(es):               <UPN>
Client product / version:           <product> <version>
Polling host (name / OS / build):   <host> / <OS> / <build>
Configured server : port : security <server>:<port>:<SSL/TLS | STARTTLS>
AllowLegacyTLSClients:              <True/False>
PopEnabled / ImapEnabled:           <True/False> / <True/False>
Handshake test from host (Tls/Tls11/Tls12): <OK/FAIL> / <OK/FAIL> / <OK/FAIL>
SchUseStrongCrypto / SystemDefaultTlsVersions (64-bit / 32-bit): <v>/<v> ; <v>/<v>
Exact client error text + timestamp (UTC): <text> @ <time>
Entra sign-in (clientAppUsed, AppDisplayName, IP, ErrorCode): <values>
Vendor contacted / TLS 1.2 support statement: <yes/no, reference>
Changes already made + rollback status: <list>
```

---
## 🎓 Learning Pointers

- **Legacy TLS was never "supported", only tolerated.** Exchange Online stopped *supporting* TLS 1.0/1.1 in October 2020; the Jan 2023 `*-legacy` endpoints were an escape hatch. MC1293480 removes the hatch for POP/IMAP — read the opt-in page to understand what you're unwinding: [Opt in to the EXO endpoint for legacy TLS clients using POP3 or IMAP4](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/opt-in-exchange-online-endpoint-for-legacy-tls-using-pop3-or-imap4).
- **`AllowLegacyTLSClients` is one switch for two protocols.** The SMTP AUTH page documents the same parameter for `smtp-legacy.office365.com` — flipping it for POP/IMAP cleanup can break a scan-to-email device: [Legacy TLS clients using SMTP AUTH](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/opt-in-exchange-online-endpoint-for-legacy-tls-using-smtp-auth).
- **Test from the failing host, not your laptop.** TLS is negotiated by the client's stack; your admin PC succeeding proves nothing. The `SslStream` probe in Triage isolates OS vs app in one run.
- **.NET Framework's TLS defaults are the silent killer.** Apps compiled against older .NET 4.x can default to TLS 1.0 regardless of what the OS supports: [Transport Layer Security best practices with .NET Framework](https://learn.microsoft.com/en-us/dotnet/framework/network-programming/tls).
- **Usage data before comms.** The Email apps usage report (Graph `getEmailAppUsageUserDetail`) tells you who actually used POP/IMAP in 180 days; Tony Redmond's walkthrough is a good template: [Office365ITPros — Exchange Online to Deprecate Legacy TLS for POP3 and IMAP4](https://office365itpros.com/2026/04/29/legacy-tls-removal/).
- Deep dive, evidence script and architecture: `POPIMAPLegacyTLS-A.md`, `Scripts/Get-POPIMAPLegacyTLSReadiness.ps1`.
