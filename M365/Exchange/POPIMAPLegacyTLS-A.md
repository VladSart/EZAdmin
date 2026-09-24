# Exchange Online POP3/IMAP4 Legacy TLS Retirement — Reference Runbook (Mode A: Deep Dive)
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

- **In scope:** POP3 and IMAP4 client connections to Exchange Online (worldwide and 21Vianet), on the standard endpoint `outlook.office365.com` and the opt-in legacy endpoints `pop-legacy.office365.com` / `imap-legacy.office365.com` (21Vianet: `pop-legacy.partner.outlook.cn` / `imap-legacy.partner.outlook.cn`).
- **The change (MC1293480):** published 27 April 2026, timeline revised 7 July 2026. Gradual worldwide rollout **1 Aug 2026 → 31 Dec 2026**; after it reaches a tenant, POP3/IMAP4 require **TLS 1.2 or later** and TLS 1.0/1.1 handshakes fail. Act-by date in Message Center: 31 July 2026. The original April announcement (and most press coverage) said "July 2026" — treat July as superseded.
- **GCC / GCC High / DoD:** the legacy opt-in endpoint never existed there (legacy TLS permanently off), so this change is effectively a no-op in those clouds.
- **Out of scope:** SMTP AUTH client submission (separate legacy endpoint `smtp-legacy.office365.com`, not named in MC1293480), inbound/outbound SMTP between mail servers (connector TLS — see `Mail-Flow-A.md`), EWS (`EWSRetirement-A.md`), Exchange Server on-premises.
- **Assumes:** ExchangeOnlineManagement v3, Microsoft Graph PowerShell SDK (see `EntraID/Graph/GraphPowerShellSDK-A.md` for the 2026 SDK auth changes), admin roles Exchange Administrator / Global Reader and Reports Reader.
- **Sourcing:** timeline and behaviour from MC1293480 (via the mc.merill.net archive, v2 7 Jul 2026); endpoint/opt-in mechanics from Microsoft Learn (POP3/IMAP4 and SMTP AUTH legacy-TLS opt-in pages). The Exchange Team blog post *Deprecating Legacy TLS and Endpoints for POP and IMAP in Exchange Online* (27 Apr 2026) is quoted via BleepingComputer; the title mentions "endpoints" but Microsoft has not published a separate decommission date for the `*-legacy` hostnames — assume they stop being useful for POP/IMAP when your tenant is reached.

---
## How It Works

<details><summary>Full architecture</summary>

### Three layers people conflate

```
 Client app / device
   │  1. TCP to outlook.office365.com:993/995 (implicit TLS) or :143/:110 + STARTTLS
   │  2. TLS handshake  ─────────────  ← MC1293480 acts HERE (protocol version floor = 1.2)
   │  3. Protocol auth: AUTHENTICATE XOAUTH2 <Entra access token>
   │                                    ← Basic auth retired 2022; OAuth mandatory
   │  4. Mailbox access check: CASMailbox PopEnabled / ImapEnabled
   ▼
 Exchange Online front end → mailbox
```

The TLS floor is enforced **before** any authentication. A client that fails here never reaches Entra-token validation or the mailbox — so nothing appears in the Exchange side for that attempt, and the Entra sign-in log only shows the (successful) token issuance that happened earlier against `login.microsoftonline.com`, which is a *different* TLS session to a *different* service. This is why sign-in logs "look fine" while mail collection is dead.

### History (why the legacy endpoints exist)

| Date | Event |
|---|---|
| Oct 2020 | TLS 1.0/1.1 declared unsupported in Exchange Online (still tolerated). |
| Oct 2022 | Basic auth for POP/IMAP disabled — survivors moved to OAuth. |
| Jan 2023 | Opt-in legacy endpoints (`pop-legacy` / `imap-legacy` / `smtp-legacy`) introduced behind `AllowLegacyTLSClients` so frozen-TLS clients could keep working while main endpoints were hardened. |
| 27 Apr 2026 | MC1293480 + Exchange Team blog: legacy TLS for POP/IMAP to be removed entirely. |
| 7 Jul 2026 | MC1293480 updated: rollout **1 Aug – 31 Dec 2026**. |

### Who actually breaks

Microsoft's stated expectation is that mainly tenants that **explicitly opted in** to the legacy endpoints are affected. In practice the at-risk population is:

1. **Anything pointed at a `*-legacy` host** — by definition it needed TLS 1.0/1.1 in 2023.
2. **.NET Framework 4.0–4.6.x apps** without strong-crypto registry values: the runtime's `ServicePointManager.SecurityProtocol` default may exclude TLS 1.2, independent of the OS. Setting `SchUseStrongCrypto=1` + `SystemDefaultTlsVersions=1` makes such apps inherit OS defaults.
3. **Old hosts** (Windows 7 / Server 2008 R2 without the TLS 1.2 client enablement, appliances on end-of-life Linux/OpenSSL).
4. **Embedded devices** — MFP "scan-to-folder via mailbox polling", voice systems collecting voicemail/fax mail, access-control and alarm systems, OT/IoT gateways. Frozen TLS libraries; firmware may never be updated.
5. **Apps that pin `SslProtocols.Tls`** in code — registry changes won't help.

Modern clients (Thunderbird, Apple Mail, Android/iOS mail, current MailKit/.NET, Python ≥3.x with OpenSSL 1.1+) negotiate TLS 1.2/1.3 by default and are unaffected.

### The shared switch

`Set-TransportConfig -AllowLegacyTLSClients` (EAC: *Settings → Mail flow → Turn on use of legacy TLS clients*) is documented on **both** the POP3/IMAP4 and SMTP AUTH legacy pages. It's org-wide, not per-protocol. Turning it off as part of POP/IMAP clean-up also closes `smtp-legacy.office365.com` to your tenant's users — a classic self-inflicted outage for scan-to-email.

</details>

---
## Dependency Stack

```
Layer 6  Mail processed by the app (ticket created, invoice ingested, scan filed)
Layer 5  Mailbox authorisation — CASMailbox PopEnabled / ImapEnabled; mailbox permissions (shared mbx FullAccess for the app identity)
Layer 4  Protocol auth — XOAUTH2 with an Entra token (app registration, consent, POP.AccessAsApp / IMAP.AccessAsApp or delegated scopes; Exchange service principal registration for app-only)
Layer 3  TLS ≥ 1.2 handshake  ← MC1293480
           ├─ Client TLS stack: Schannel (Windows) / OpenSSL / device firmware
           ├─ App runtime protocol selection (.NET SecurityProtocol, Java jdk.tls.client.protocols, etc.)
           └─ Cipher-suite overlap with EXO
Layer 2  TCP 993/995 (or 143/110 + STARTTLS) to outlook.office365.com (not *-legacy)
Layer 1  DNS + outbound firewall/proxy (no TLS-inspecting proxy that downgrades)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Collector stops on a date between 1 Aug and 31 Dec 2026, "nothing changed" | Tenant reached by MC1293480; client uses TLS 1.0/1.1 | Handshake probe from the host (Validation 2) |
| Client configured with `imap-legacy.office365.com` | Explicit legacy dependency | Client config; `AllowLegacyTLSClients` |
| Error like *"The client and server cannot communicate, because they do not possess a common algorithm"* / `SEC_E_ALGORITHM_MISMATCH` / OpenSSL `wrong version number` / `unsupported protocol` | TLS version or cipher mismatch | Probe; Schannel registry; app runtime |
| Works from admin PC, fails from server | Host-specific TLS stack / .NET defaults | Validation 2 + 3 on the server |
| App fails, but `Tls12 OK` on host | App pins old protocol or runs on old .NET defaults | .NET registry; vendor |
| Entra sign-in log shows success, mail not collected | Token obtained (different TLS session); IMAP TLS fails later | Probe; app logs |
| `AUTHENTICATE failed` after TLS succeeds | Not a TLS issue — OAuth/app permission/mailbox permission | `Outlook-Client-A.md`, app registration |
| SMTP scanner breaks the day POP/IMAP clean-up happens | `AllowLegacyTLSClients` set to `$false` also closed `smtp-legacy` | Transport config change time vs. failure time |
| Only 32-bit app affected | WOW6432Node .NET key missing | Check both .NET registry hives |

---
## Validation Steps

1. **Tenant opt-in state**
   ```powershell
   Get-TransportConfig | Format-List AllowLegacyTLSClients
   ```
   Good: `False` (nothing depends on legacy). Bad/needs work: `True` → inventory before disabling.

2. **Handshake probe from the affected host**
   ```powershell
   .\Get-POPIMAPLegacyTLSReadiness.ps1 -SkipTenant -ProbeHost outlook.office365.com
   ```
   Good: `Tls12` succeeds (negotiated `Tls12`). After rollout reaches the tenant, `Tls`/`Tls11` failing is **expected and correct**. Bad: `Tls12` fails → OS/stack problem.

3. **Runtime defaults on the host**
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' | Select-Object SchUseStrongCrypto, SystemDefaultTlsVersions
   Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' | Select-Object SchUseStrongCrypto, SystemDefaultTlsVersions
   ```
   Good: both `1` in both hives. Bad: missing/`0` for a .NET 4.x app.

4. **Who uses POP/IMAP (180 days)**
   `getEmailAppUsageUserDetail(period='D180')` rows with `POP3 App` / `IMAP4 App` populated. Good: empty, or only known service mailboxes. Bad: unknown users → comms.

5. **Which mailboxes *can* use POP/IMAP**
   ```powershell
   Get-EXOCASMailbox -ResultSize Unlimited -PropertySets Minimum,Pop,Imap |
     Where-Object { $_.PopEnabled -or $_.ImapEnabled } | Measure-Object
   ```
   Good: small, justified set. Bad: tenant default (all mailboxes) — attack surface regardless of TLS.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Scope (5 min):** client product/version, host, server:port, error text, first-failure timestamp. Compare to the MC1293480 window and any `Set-TransportConfig` change in the audit log:
```powershell
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-90) -EndDate (Get-Date) -Operations Set-TransportConfig -ResultSize 100 |
  Select-Object CreationDate, UserIds, @{n='Params';e={($_.AuditData | ConvertFrom-Json).Parameters | ConvertTo-Json -Compress}}
```

**Phase 2 — Network & TLS (10 min):** `Test-NetConnection outlook.office365.com -Port 993` then the probe. Check for a TLS-inspecting proxy/firewall between host and EXO (inspection devices that re-originate with old TLS reproduce the symptom exactly — probe from inside and outside the inspection path).

**Phase 3 — Runtime (10 min):** .NET keys (both hives), Java (`jdk.tls.client.protocols`, JRE version), Python/OpenSSL version (`python -c "import ssl;print(ssl.OPENSSL_VERSION)"`), device firmware version vs vendor TLS 1.2 statement.

**Phase 4 — Above TLS:** if TLS 1.2 now succeeds but auth fails, you have a second, independent problem (OAuth app, `POP.AccessAsApp`/`IMAP.AccessAsApp` permission, Exchange service principal + mailbox permission for app-only, or CAS protocol disabled). Treat it as a normal POP/IMAP OAuth ticket.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Tenant-wide legacy-endpoint exit</summary>

1. Inventory: usage report (POP/IMAP), sign-in logs (`clientAppUsed` IMAP4/POP3/Authenticated SMTP), and ask device owners for any `*-legacy` hostnames. Search config management / scripts for `-legacy.office365.com`.
2. Repoint each client to `outlook.office365.com` (POP/IMAP) or `smtp.office365.com` (SMTP AUTH) and verify TLS 1.2 from each host.
3. Disable the opt-in:
   ```powershell
   Set-TransportConfig -AllowLegacyTLSClients $false
   ```
4. Watch helpdesk tickets and sign-ins for 7 days.
**Rollback:** `Set-TransportConfig -AllowLegacyTLSClients $true`. Buys nothing for POP/IMAP once your tenant is in the rollout, but restores SMTP AUTH legacy access if that's what broke.
</details>

<details><summary>Playbook 2 — Fleet .NET strong-crypto baseline (Intune / GPO)</summary>

Set on every server that runs mail-polling apps (and ideally all Windows endpoints):

| Hive | Value | Data |
|---|---|---|
| `HKLM\SOFTWARE\Microsoft\.NETFramework\v4.0.30319` | `SchUseStrongCrypto` | 1 (DWORD) |
| same | `SystemDefaultTlsVersions` | 1 (DWORD) |
| `HKLM\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319` | `SchUseStrongCrypto` | 1 |
| same | `SystemDefaultTlsVersions` | 1 |

Deliver via GPO Preferences → Registry, or an Intune remediation (detection = the four values equal 1). Restart affected services. **Rollback:** delete/restore the values and restart. Risk: an app that talks to a *different* legacy endpoint only capable of TLS 1.0 may break — test on one host first.
</details>

<details><summary>Playbook 3 — Replace POP/IMAP polling with Microsoft Graph</summary>

Microsoft's direction of travel (EWS, legacy TLS, SMTP AUTH basic) is Graph. For in-house collectors:
- App registration with **Mail.Read** (application) scoped via **RBAC for Applications** / application access policy to the specific shared mailbox (not tenant-wide).
- Poll `GET /users/<mailbox>/mailFolders/inbox/messages?$filter=isRead eq false` or use change notifications/delta queries.
- Removes the POP/IMAP protocol from the equation — then disable `ImapEnabled`/`PopEnabled` on that mailbox.
See `EntraID/Graph/GraphPowerShellSDK-A.md` and `M365/Exchange/SharedMailbox-A.md`.
</details>

<details><summary>Playbook 4 — Shrink the POP/IMAP surface (hygiene, do it anyway)</summary>

```powershell
# Default for NEW mailboxes: off
Get-CASMailboxPlan | Set-CASMailboxPlan -PopEnabled $false -ImapEnabled $false
# Existing: disable for everyone except an allow-list of service mailboxes
$keep = @('<svc1@contoso.com>','<svc2@contoso.com>')
Get-EXOCASMailbox -ResultSize Unlimited -PropertySets Minimum,Pop,Imap |
  Where-Object { ($_.PopEnabled -or $_.ImapEnabled) -and $_.PrimarySmtpAddress -notin $keep } |
  ForEach-Object { Set-CASMailbox -Identity $_.PrimarySmtpAddress -PopEnabled $false -ImapEnabled $false -WhatIf }
```
Remove `-WhatIf` after review. **Rollback:** export the list first (`Export-Csv`) and re-enable from it. Coordinate with users found in the usage report.
</details>

---
## Evidence Pack

Run `M365/Exchange/Scripts/Get-POPIMAPLegacyTLSReadiness.ps1` (read-only). Minimal inline version:

```powershell
$out = Join-Path $PWD ("POPIMAP-TLS-Evidence-{0}.txt" -f (Get-Date -Format yyyyMMdd-HHmm))
& {
  "=== Transport config ==="; Get-TransportConfig | Format-List AllowLegacyTLSClients | Out-String
  "=== POP/IMAP-enabled mailboxes (count) ==="
  (Get-EXOCASMailbox -ResultSize Unlimited -PropertySets Minimum,Pop,Imap | Where-Object { $_.PopEnabled -or $_.ImapEnabled }).Count
  "=== Local handshake probe (outlook.office365.com:993) ==="
  foreach ($p in 'Tls','Tls11','Tls12') {
    $tcp = [System.Net.Sockets.TcpClient]::new('outlook.office365.com',993)
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(),$false)
    try { $ssl.AuthenticateAsClient('outlook.office365.com',$null,[System.Security.Authentication.SslProtocols]::$p,$false); "$p OK ($($ssl.SslProtocol))" }
    catch { "$p FAIL: $($_.Exception.GetBaseException().Message)" } finally { $ssl.Dispose(); $tcp.Dispose() }
  }
  "=== .NET strong crypto ==="
  'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319','HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' |
    ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue | Select-Object PSPath,SchUseStrongCrypto,SystemDefaultTlsVersions | Out-String }
  "=== OS ==="; Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber | Out-String
} *>&1 | Out-File -FilePath $out -Encoding utf8
"Evidence written to $out"
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Legacy opt-in state | `Get-TransportConfig \| fl AllowLegacyTLSClients` |
| Disable legacy opt-in (POP/IMAP **and** SMTP legacy) | `Set-TransportConfig -AllowLegacyTLSClients $false` |
| Mailbox POP/IMAP flags | `Get-EXOCASMailbox <UPN> -PropertySets Pop,Imap` |
| Disable for a mailbox | `Set-CASMailbox <UPN> -PopEnabled $false -ImapEnabled $false` |
| Default for new mailboxes | `Get-CASMailboxPlan \| Set-CASMailboxPlan -PopEnabled $false -ImapEnabled $false` |
| Usage (180 d) | `Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/reports/getEmailAppUsageUserDetail(period='D180')" -OutputFilePath x.csv` |
| Sign-ins by protocol | `Get-MgAuditLogSignIn -Filter "clientAppUsed eq 'IMAP4'" -Top 100` |
| Port reachability | `Test-NetConnection outlook.office365.com -Port 993` |
| TLS probe | `SslStream.AuthenticateAsClient(host,$null,[SslProtocols]::Tls12,$false)` (see Evidence Pack) |
| .NET defaults | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'` |
| Schannel TLS 1.2 client | `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'` |
| Audit who changed transport config | `Search-UnifiedAuditLog -Operations Set-TransportConfig -StartDate ... -EndDate ...` |
| Readiness report | `.\Get-POPIMAPLegacyTLSReadiness.ps1 -IncludeUsageReport -IncludeSignIns` |

---
## 🎓 Learning Pointers

- **Order of operations matters for diagnosis:** TCP → TLS → XOAUTH2 → CAS protocol flag. A failure at TLS is invisible to Exchange and Entra logs, so evidence has to come from the client host. Keep this model for any "protocol retirement" ticket.
- **Read the Message Center version history, not the press.** MC1293480 moved from "July" to **1 Aug – 31 Dec 2026**; the archive keeps both versions: [MC1293480 on mc.merill.net](https://mc.merill.net/message/MC1293480).
- **One switch, two services.** `AllowLegacyTLSClients` covers POP/IMAP and SMTP AUTH legacy endpoints — [POP3/IMAP4 page](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/opt-in-exchange-online-endpoint-for-legacy-tls-using-pop3-or-imap4), [SMTP AUTH page](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/opt-in-exchange-online-endpoint-for-legacy-tls-using-smtp-auth).
- **Fix the runtime, not just the OS.** [TLS best practices with the .NET Framework](https://learn.microsoft.com/en-us/dotnet/framework/network-programming/tls) explains `SchUseStrongCrypto` / `SystemDefaultTlsVersions` and why hard-coded protocols defeat them.
- **Use the retirement to shrink attack surface.** POP/IMAP enabled on every mailbox by default is the real finding in most tenants — see [Enable or disable POP3 or IMAP4 access](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/pop3-and-imap4/enable-or-disable-pop3-or-imap4-access).
- **This is part of a pattern** — EWS (Oct 2026 / Apr 2027), SMTP AUTH basic auth, legacy TLS. Community tracking: [Office365ITPros — legacy TLS removal](https://office365itpros.com/2026/04/29/legacy-tls-removal/) and `EWSRetirement-A.md` in this repo.
