# File Server Alias (CNAME / Alternate Computer Name) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what. Hotfix path → `FileServerAlias-B.md`.

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
- **In scope:** Windows Server SMB file servers (2016–2025) in an AD domain, accessed by a name other than their primary hostname — DNS CNAMEs, `netdom` alternate computer names, NetBIOS `OptionalNames`, and the Kerberos/NTLM, SMB name-acceptance and loopback consequences. Server consolidation / migration scenarios ("keep the old server name alive").
- **Out of scope:** Failover-cluster client access points and Scale-Out File Server (cluster network-name resources own their own computer objects/SPNs); DFS Namespace design (see `DFS/`); non-Windows NAS aliasing (vendor-specific — the Kerberos rule below still applies: the NAS's AD account needs the alias SPN); SMB over QUIC name/cert matching (`SMBoverQUIC-A.md`).
- **Assumes:** Domain-joined clients, AD-integrated DNS, admin rights on the file server and write rights on its computer object (Domain Admin or delegated write to `servicePrincipalName` + `msDS-AdditionalDnsHostName` + `msDS-AdditionalSamAccountName`).

---
## How It Works
<details><summary>Full architecture</summary>

### 1. Three independent checks happen when a client opens `\\alias\share`

```
Client                                 DNS            KDC (DC)                    File server
  │ resolve alias ───────────────────► A / CNAME
  │ ◄──────────────────────────────── IP
  │ TGS-REQ cifs/alias.contoso.com ─────────────────► lookup SPN owner
  │ ◄──────────────────────────────────────────────── ticket encrypted with OWNER's key
  │ SMB NEGOTIATE / SESSION_SETUP (Kerberos AP-REQ, target name = alias) ───────────────►
  │                                                               (a) can I decrypt? (my key == owner key?)
  │                                                               (b) do I accept this name? (strict name / SPN hardening)
  │ ◄──────────────────────────────────────────────────────────── success / KRB_AP_ERR_MODIFIED / access denied
```

Any one failing breaks the alias, and each fails with a different, often misleading error.

### 2. Kerberos: Windows does not canonicalize CNAMEs
The Windows Kerberos client forms the SPN from the host name **as the application supplied it** (`cifs/alias.contoso.com`), not the CNAME target. So:
- **No SPN for the alias** → KDC returns `KDC_ERR_S_PRINCIPAL_UNKNOWN` → SMB client falls back to NTLM (if permitted). Historically this "worked" silently; with NTLM auditing/blocking (domain NTLM restrictions, the Windows 11 24H2 SMB client `BlockNTLM` option) it fails.
- **SPN on the wrong account** (typical after migration: `HOST/oldfs` still on the old computer object while DNS now points `oldfs` at the new server) → ticket encrypted with the old server's key → new server can't decrypt → `KRB_AP_ERR_MODIFIED` (client System log, Security-Kerberos event 4), surfaced to users as "The target account name is incorrect."
- **SPN on two accounts** → duplicate; KDC behaviour is undefined for the client's purposes — treat as broken.
- `cifs/` is not normally registered explicitly: the KDC maps `cifs` to `HOST` via the `sPNMappings` attribute on `CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,...`. Registering `HOST/alias` is sufficient for SMB.

### 3. SMB server name acceptance
Independently of authentication, the SMB server may reject a connection addressed to a name it doesn't consider its own:
- **Strict name checking** (legacy): an unknown called name yields `System error 52 — a duplicate name exists on the network`. Bypassed by `DisableStrictNameChecking=1`, or avoided entirely by registering the name as an alternate computer name / `OptionalNames` entry.
- **SPN target-name validation** (`SmbServerNameHardeningLevel` 0/1/2, GPO "Microsoft network server: Server SPN target name validation level"): when enabled, the server validates the target name in the client's authentication against its own names plus `SrvAllowedServerNames` (REG_MULTI_SZ). Aliases missing from that list are refused — this is the "configuration issue or SMB server service hardening issue" called out in Microsoft's CNAME article.

### 4. The netdom alternate-name model
`netdom computername <server> /add:<alias-fqdn>` makes the alias a first-class name of the machine:
- Writes the alias to the computer object's `msDS-AdditionalDnsHostName` (FQDN) and `msDS-AdditionalSamAccountName` (short `ALIAS$`).
- Registers `HOST/alias` and `HOST/alias.fqdn` SPNs on the server's own computer object (fails if another object already owns them).
- The server's DNS client registers an **A record** for the alias (dynamic update) — which is why any existing CNAME for that name must be deleted first (RFC: a CNAME cannot coexist with other records for the same owner name).
- SMB accepts the name without `DisableStrictNameChecking`/`OptionalNames` edits.
- Reversible with `/remove:`; enumerable with `/enum:altnames`; `/makeprimary:` exists for rename-in-place scenarios.

Microsoft's current support guidance is to **avoid CNAMEs for file-server aliases** and use this command instead.

### 5. NTLM loopback check
When a process on the server connects to itself by an alias using **NTLM**, LSA's loopback check rejects the logon (access denied / 401-style failures). Kerberos is not affected. Targeted exemption: `BackConnectionHostNames` (REG_MULTI_SZ under `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0`). `DisableLoopbackCheck=1` removes the protection globally and should not be used.

### 6. Why aliases exist at all — and the better design
Aliases are usually a migration crutch: hard-coded UNC paths in drive maps, shortcuts, Office links, line-of-business app configs, scanner profiles. A DFS namespace (`\\contoso.com\files\dept`) moves the dependency from a server name to a domain-based path whose targets can change without touching DNS/SPNs. Use an alias to bridge a migration, then retire it.
</details>

---
## Dependency Stack
```
L7  User / app path:  \\alias\share, \\alias.fqdn\share, mapped drive, shortcut, app config
L6  SMB server name acceptance: primary | netdom alt name | OptionalNames | DisableStrictNameChecking
                                + SrvAllowedServerNames if SmbServerNameHardeningLevel ≥ 1
L5  Auth (Kerberos): exactly one account owns HOST/alias(.fqdn), and it's the answering server
L5' Auth (NTLM fallback): permitted by client BlockNTLM / domain NTLM policy; loopback exemption for local use
L4  KDC reachability + sPNMappings (cifs→HOST)
L3  TCP 445 to the server IP
L2  DNS: alias → correct IP (A registered by server, or CNAME → real host → A)
L1  AD computer object attributes: servicePrincipalName, msDS-AdditionalDnsHostName, msDS-AdditionalSamAccountName
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| "The target account name is incorrect"; Security-Kerberos event 4 on client | Alias SPN on old/wrong computer object | `setspn -Q HOST/<alias-fqdn>` |
| Worked for years, broke after NTLM restriction / 24H2 client rollout | No alias SPN; was silently using NTLM | `klist get cifs/<alias-fqdn>` → `0xc000018b` |
| `System error 52` duplicate name | Strict name checking | server `DisableStrictNameChecking`, `netdom /enum:altnames` |
| "Account restriction is preventing this user from signing in" via alias only | SPN target-name hardening without `SrvAllowedServerNames`, or NTLM restrictions | `SmbServerNameHardeningLevel`, NTLM operational log |
| FQDN alias works, short alias fails | Only FQDN SPN registered; DNS suffix search missing | `setspn -Q HOST/<alias>`; `Get-DnsClientGlobalSetting` |
| Works for some clients, not others | Cached tickets from before SPN change; mixed NTLM policy | `klist purge` on a failing client |
| Scheduled task / backup on server fails via alias, users fine | NTLM loopback check | Security 4625 on server, `BackConnectionHostNames` |
| `netdom /add` fails "already exists" | SPN or `msDS-AdditionalDnsHostName` held by another object | `setspn -Q`, AD search on the attribute |
| A record for alias won't register | CNAME still present, or zone disallows dynamic updates / record owned by another account (secure updates) | `Resolve-DnsName -Type CNAME`, DNS record ACL |
| Alias points at old IP intermittently | Both CNAME and a stale A in different zones/split-brain, or client DNS cache | `Resolve-DnsName -DnsOnly -Server <each DC>` |

---
## Validation Steps
1. **DNS consistency across DCs**
   `foreach ($dc in (Get-ADDomainController -Filter *).HostName) { Resolve-DnsName <alias>.<domain.fqdn> -Server $dc -DnsOnly | Select @{n='DC';e={$dc}},Type,NameHost,IPAddress }`
   Good: identical answer from every DC. Bad: mixed CNAME/A or different IPs (replication lag or stale record in a non-replicated zone).
2. **SPN ownership**
   `setspn -Q HOST/<alias>.<domain.fqdn>` and `setspn -Q HOST/<alias>`
   Good: one object, the real server. Bad: none, old server, or two entries.
3. **Alternate-name attributes**
   `Get-ADComputer <realserver> -Properties msDS-AdditionalDnsHostName,msDS-AdditionalSamAccountName,servicePrincipalName`
   Good (netdom model): alias present in both `msDS-Additional*` attributes. Bad: alias present on the old server's object instead.
4. **Kerberos ticket**
   `klist purge_bind; klist get cifs/<alias>.<domain.fqdn>`
   Good: ticket retrieved; `klist` shows `Server: cifs/<alias>...`. Bad: `0xc000018b` (no SPN) or success followed by access failure + event 4 (wrong key).
5. **Server acceptance**
   On the server: `netdom computername $env:COMPUTERNAME /enum:altnames` and the `LanmanServer\Parameters` values. Good: alias listed (or `DisableStrictNameChecking=1` for CNAME model), and alias in `SrvAllowedServerNames` if hardening is on.
6. **End-to-end with the protocol confirmed**
   `net use \\<alias-fqdn>\<share>` then on the server `Get-SmbSession | Where ClientUserName -like '*<user>*' | Select ClientComputerName, Dialect, @{n='Auth';e={$_.ClientUserName}}` and on the client `klist | Select-String cifs/<alias>`. Good: a cifs ticket for the alias exists → Kerberos was used.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Scope (1 min).** Real name vs alias vs IP. Real name failing → not this runbook. Only alias failing → continue.

**Phase 2 — Name resolution.** Resolve alias from the client and from every DC. Flush client cache (`Clear-DnsClientCache`). If multiple answers exist, fix DNS first — every later test is meaningless against the wrong IP.

**Phase 3 — Kerberos.** `setspn -Q` → `klist get`. Decide: no SPN (register), wrong owner (move), duplicate (dedupe). Check client System log for Security-Kerberos event 4. On DCs, Security 4769 with failure code `0x7` for `cifs/<alias>` confirms "principal unknown".

**Phase 4 — NTLM path (only if Kerberos deliberately not used).** Check client `Get-SmbClientConfiguration | Select BlockNTLM, BlockNTLMServerExceptionList` and domain NTLM restriction GPOs (`NTLM-B.md`). Local-on-server access → loopback.

**Phase 5 — SMB server acceptance.** Strict name checking / SPN hardening values; `netdom /enum:altnames`. Any registry change needs a `LanmanServer` restart (session-dropping).

**Phase 6 — Clients' caches.** After any SPN or DNS fix: `klist purge` + `Clear-DnsClientCache`, or log off/on. Mapped drives reconnect with cached credentials/tickets — test with a fresh `net use`.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate an old server name onto a new file server (the canonical case)</summary>

Scenario: `OLDFS` is being retired; `NEWFS` should answer `\\oldfs\...`.

1. Copy data/shares/permissions to `NEWFS` (outside scope). Export `OLDFS` state for rollback:
   ```powershell
   Get-ADComputer OLDFS -Properties servicePrincipalName,msDS-AdditionalDnsHostName,DNSHostName |
     Export-Clixml "$env:TEMP\OLDFS-object.xml"
   ```
2. Cutover window: stop sharing on `OLDFS`, then **disjoin and delete** its computer object (or rename it — renaming rewrites its own `HOST/` SPNs to the new name, freeing `HOST/oldfs`). Deleting frees `HOST/oldfs` and `HOST/oldfs.fqdn`.
3. Delete the `oldfs` A record (and any CNAME) from DNS; wait for AD DNS replication.
4. On `NEWFS`: `netdom computername newfs.<domain.fqdn> /add:oldfs.<domain.fqdn>`; reboot `NEWFS`.
5. Validate (steps 1–6 above) from a client after `klist purge`.
6. Update drive-map GPOs/scripts to the DFS path or `\\newfs`, and schedule alias removal.

**Rollback:** `netdom ... /remove:oldfs.<domain.fqdn>` on `NEWFS`, restore `OLDFS` (re-join or restore object from AD Recycle Bin), re-register its A record.
</details>

<details><summary>Playbook 2 — Keep an existing CNAME but make it Kerberos-capable</summary>

Use when the alias lives in a zone the server can't dynamically update (e.g. a different DNS namespace) or change control forbids replacing the CNAME.
```powershell
setspn -S HOST/<alias>.<zone.fqdn> <realserver>
setspn -S HOST/<alias> <realserver>          # only if the short name resolves to this server
$p='HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
Set-ItemProperty $p DisableStrictNameChecking 1 -Type DWord
# If SPN target-name hardening is on:
New-ItemProperty $p SrvAllowedServerNames -PropertyType MultiString -Value @('<alias>','<alias>.<zone.fqdn>') -Force
Restart-Service LanmanServer -Force
```
Note: an alias in a DNS zone that doesn't match an AD domain can hit Kerberos realm-mapping problems for clients that can't determine the realm; a host-to-realm mapping (GPO "Define host name-to-Kerberos realm mappings") may be needed.
**Rollback:** `setspn -D` both, remove the two registry values, restart `LanmanServer`.
</details>

<details><summary>Playbook 3 — Clean up duplicate / orphaned alias SPNs forest-wide</summary>

```powershell
setspn -X -F > "$env:TEMP\spn-duplicates.txt"       # review before deleting anything
# For each duplicated HOST/<alias> SPN: keep it on the server that actually answers DNS for <alias>
setspn -D HOST/<alias>.<domain.fqdn> <wrong-object>
```
Also check `msDS-AdditionalDnsHostName` on stale objects:
```powershell
Get-ADComputer -LDAPFilter '(msDS-AdditionalDnsHostName=<alias>.<domain.fqdn>)' -Properties msDS-AdditionalDnsHostName
```
Destructive: removing an SPN from the object that is actually serving breaks Kerberos to it immediately. Export `setspn -L <object>` for every object you touch first.
</details>

<details><summary>Playbook 4 — Retire an alias safely</summary>

1. Measure use: on the server, enable/inspect SMB session data over a week — `Get-SmbSession` doesn't record the called name, so instead remove the alias from DNS for a short pilot window **or** use DNS debug/analytic logging on DCs to see which clients query `<alias>`.
2. Repoint consumers (GPO drive maps, scripts, app configs) to the DFS path.
3. Remove: `netdom computername <server> /remove:<alias-fqdn>` (removes SPNs and alt-name attributes); delete the A/CNAME record; remove any `OptionalNames`/`SrvAllowedServerNames`/`BackConnectionHostNames` entries; reboot or restart `LanmanServer`.
**Rollback:** re-run `/add:`.
</details>

---
## Evidence Pack
```powershell
# Run on a CLIENT that reproduces the issue (domain user; RSAT-AD optional). Output: one folder + zip.
param([string]$Alias = '<alias>.<domain.fqdn>', [string]$RealServer = '<realserver>.<domain.fqdn>', [string]$Share = '<share>')
$out = Join-Path $env:TEMP ("AliasEvidence_{0:yyyyMMdd_HHmmss}" -f (Get-Date)); New-Item $out -ItemType Directory | Out-Null
$short = $Alias.Split('.')[0]
Resolve-DnsName $Alias -ErrorAction SilentlyContinue | Out-File "$out\dns-alias.txt"
Resolve-DnsName $RealServer -ErrorAction SilentlyContinue | Out-File "$out\dns-real.txt"
foreach ($s in "HOST/$Alias","HOST/$short","cifs/$Alias") { "== $s"; setspn -Q $s } *>&1 | Out-File "$out\spn-owners.txt"
klist purge_bind *>&1 | Out-Null
klist get "cifs/$Alias" *>&1 | Out-File "$out\klist-get.txt"
"Real:  $(Test-Path "\\$RealServer\$Share")`nAlias: $(Test-Path "\\$Alias\$Share")`nShort: $(Test-Path "\\$short\$Share")" | Out-File "$out\access-test.txt"
Get-SmbClientConfiguration | Select RequireSecuritySignature, BlockNTLM, BlockNTLMServerExceptionList -ErrorAction SilentlyContinue | Out-File "$out\smbclient.txt"
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Security-Kerberos'; StartTime=(Get-Date).AddDays(-1)} -ErrorAction SilentlyContinue |
  Select TimeCreated, Id, Message | Export-Csv "$out\kerberos-events.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-SMBClient/Security'; StartTime=(Get-Date).AddDays(-1)} -ErrorAction SilentlyContinue |
  Select TimeCreated, Id, Message | Export-Csv "$out\smbclient-security.csv" -NoTypeInformation
Compress-Archive "$out\*" "$out.zip" -Force; Write-Host "Evidence: $out.zip"
```
Server-side: run `Windows/Scripts/Get-FileServerAliasHealth.ps1 -Server <realserver> -Alias <alias-fqdn> -IncludeServerRegistry`.

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Add alternate name (preferred) | `netdom computername <srv-fqdn> /add:<alias-fqdn>` |
| List alternate names | `netdom computername <srv-fqdn> /enum:altnames` |
| Remove alternate name | `netdom computername <srv-fqdn> /remove:<alias-fqdn>` |
| Who owns an SPN | `setspn -Q HOST/<alias-fqdn>` |
| Add SPN (dup-checked) | `setspn -S HOST/<alias-fqdn> <srv>` |
| Remove SPN | `setspn -D HOST/<alias-fqdn> <srv>` |
| Forest duplicate SPNs | `setspn -X -F` |
| Test Kerberos to alias | `klist purge_bind; klist get cifs/<alias-fqdn>` |
| Clear client tickets | `klist purge` |
| Alias DNS record | `Resolve-DnsName <alias-fqdn> \| Select Type,NameHost,IPAddress` |
| Remove CNAME | `Remove-DnsServerResourceRecord -ZoneName <zone> -Name <alias> -RRType CName -Force` |
| Server name settings | `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters \| Select DisableStrictNameChecking,OptionalNames,SmbServerNameHardeningLevel,SrvAllowedServerNames` |
| Loopback exemption | `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0\BackConnectionHostNames` (MULTI_SZ) |
| AD alt-name attributes | `Get-ADComputer <srv> -Properties msDS-AdditionalDnsHostName,msDS-AdditionalSamAccountName` |

---
## 🎓 Learning Pointers
- The core rule — *Kerberos uses the name you typed* — explains nearly every alias failure. Microsoft's own fix for CNAME failures is not a registry tweak but replacing the CNAME: [SMB file server share access is unsuccessful through DNS CNAME alias](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/dns-cname-alias-cannot-access-smb-file-server-share).
- Read the Core Infrastructure & Security team's walkthrough of the netdom model and what it writes to AD/DNS: [Using Computer Name Aliases in place of DNS CNAME Records](https://techcommunity.microsoft.com/blog/coreinfrastructureandsecurityblog/using-computer-name-aliases-in-place-of-dns-cname-records/259064).
- `KRB_AP_ERR_MODIFIED` = key mismatch between ticket and server. Beyond aliases it also shows up with duplicate SPNs on service accounts and stale DNS pointing at the wrong host — the same `setspn -Q` discipline applies (see `Kerberos-A.md`).
- Aliases that "always worked" were often NTLM-only. Before enforcing NTLM restrictions (`NTLM-A.md`, `SMBHardening-A.md`), inventory aliases and give each one an SPN — this runbook's script does that in one pass.
- SPN target-name validation (`SmbServerNameHardeningLevel`) is a relay-attack defence; when you enable it, maintain `SrvAllowedServerNames` alongside it in the same GPO. Reference: [Microsoft network server: Server SPN target name validation level](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/microsoft-network-server-server-spn-target-name-validation-level).
- Design out the problem: DFS namespaces decouple paths from server names — see `DFS/` in this repo.
