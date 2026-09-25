# File Server Alias (CNAME / Alternate Computer Name) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers `\\alias\share` failing while `\\realname\share` works — typically after a file-server migration where the old server name was kept as a DNS CNAME.
> Generic SMB connectivity (445, DNS, share perms) → `SMB-B.md`. 24H2/WS2025 signing/guest/NTLM-blocking fallout → `SMBHardening-B.md`. Kerberos in general → `Kerberos-B.md`. DFS namespaces → `DFS/`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run on an **affected client** (normal PowerShell; `setspn` needs RSAT-AD or any domain-joined machine with the tool):

```powershell
# 1. Does the real name work but the alias doesn't? (proves it's an alias problem, not a share problem)
Test-Path \\<realserver>.<domain.fqdn>\<share>; Test-Path \\<alias>.<domain.fqdn>\<share>

# 2. How is the alias published in DNS — CNAME or A record, and where does it point?
Resolve-DnsName <alias>.<domain.fqdn> | Select Name, Type, NameHost, IPAddress

# 3. Who owns the alias SPN? (none / wrong server / two owners)
setspn -Q HOST/<alias>.<domain.fqdn>; setspn -Q cifs/<alias>.<domain.fqdn>

# 4. Can the client get a Kerberos ticket for the alias?
klist purge_bind; klist get cifs/<alias>.<domain.fqdn>

# 5. Does the server know the alias as one of its own names?
netdom computername <realserver>.<domain.fqdn> /enum:altnames
```

| If you see | Means | Go to |
|---|---|---|
| `Logon Failure: The target account name is incorrect` / Security-Kerberos event 4 `KRB_AP_ERR_MODIFIED` on the client | Alias SPN is registered on a **different** computer object (usually the old, decommissioned server) | Fix 2 |
| `setspn -Q` → `No such SPN found` and `klist get` → `0xc000018b` / `KDC_ERR_S_PRINCIPAL_UNKNOWN` | No SPN for the alias → Kerberos impossible → NTLM fallback (which may be blocked) | Fix 1 (preferred) or Fix 3 |
| `setspn -Q` shows the SPN on **two** objects | Duplicate SPN — KDC will refuse/pick wrong key | Fix 2 |
| `System error 52` "duplicate name exists on the network" | SMB server strict name check rejecting an unknown name | Fix 1 or Fix 4 |
| `Account restriction is preventing this user from signing in` / access denied only via alias | Server SPN target-name hardening rejects the alias, or NTLM path blocked | Fix 4 / Fix 3 |
| Alias fails **only when used on the file server itself** (e.g. scheduled task, backup job) | NTLM loopback check | Fix 5 |
| Works by FQDN alias, fails by short alias | Missing short-name SPN / DNS suffix search / NetBIOS name | Fix 1 (adds both) |

---
## Dependency Cascade
<details><summary>What must be true for \\alias\share to work</summary>

```
\\alias.contoso.com\share
 ├── DNS: alias resolves to the right server IP
 │     ├── Preferred: A record registered by the server itself (netdom alternate name)
 │     └── Legacy:    CNAME → realserver.contoso.com (CNAME and A for same name cannot coexist)
 ├── TCP 445 reachable (same as real name)
 ├── Authentication
 │     ├── Kerberos (default, required if NTLM is blocked)
 │     │     ├── Client asks KDC for cifs/alias.contoso.com  (Windows does NOT swap a CNAME for its target)
 │     │     ├── KDC maps cifs → HOST (sPNMappings) → finds EXACTLY ONE account owning HOST/alias
 │     │     └── That account = the server actually answering (else KRB_AP_ERR_MODIFIED)
 │     └── NTLM fallback (no SPN) → allowed by client/domain NTLM policy? → server loopback check (local access only)
 └── SMB server accepts the name it was called by
       ├── Name is primary / netdom alternate name / OptionalNames entry, OR DisableStrictNameChecking=1
       └── If SmbServerNameHardeningLevel ≥ 1 → alias listed in SrvAllowedServerNames
```
</details>

---
## Diagnosis & Validation Flow
1. **Confirm scope.** `Test-Path` real name vs alias (Triage #1). Real name also fails → not an alias problem, go to `SMB-B.md`.
2. **DNS.** `Resolve-DnsName <alias>` → expected: `Type A` with the server IP (netdom model) or `CNAME` → `realserver` then `A`. Pointing at the old server's IP or an unexpected host = stale record; fix DNS before anything else.
3. **SPN ownership.** `setspn -Q HOST/<alias-fqdn>` and `HOST/<alias-short>` → expected: exactly one `CN=<REALSERVER>,...`. Zero = Fix 1/3. Old server or two objects = Fix 2.
4. **Ticket.** `klist purge_bind` then `klist get cifs/<alias-fqdn>` → expected: `A ticket to cifs/... has been retrieved successfully.` Error `0xc000018b` = no SPN. Success but access still fails → check System log for Security-Kerberos event 4 (wrong key = SPN on wrong account).
5. **Server name acceptance.** On the file server:
   ```powershell
   Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' |
     Select DisableStrictNameChecking, OptionalNames, SmbServerNameHardeningLevel, SrvAllowedServerNames
   netdom computername $env:COMPUTERNAME /enum:altnames
   ```
   Expected (netdom model): alias listed in `altnames`. Expected (CNAME model): `DisableStrictNameChecking = 1`. If `SmbServerNameHardeningLevel` is `1` or `2`, the alias must appear in `SrvAllowedServerNames`.
6. **Re-test** with a fresh ticket cache: `klist purge`, `net use \\<alias-fqdn>\<share>`. Expected: `The command completed successfully.`

---
## Common Fix Paths

<details><summary>Fix 1 — Replace the CNAME with a proper alternate computer name (Microsoft-recommended)</summary>

Registers the alias as one of the server's own names: A record, `HOST/` SPNs (FQDN + short), and SMB name acceptance — no registry hacks.

```powershell
# Run elevated on (or against) the file server, as an account allowed to write the computer object (Domain Admin or delegated)
# 0. Record current state for rollback
Resolve-DnsName <alias>.<domain.fqdn> | Export-Csv "$env:TEMP\alias-dns-before.csv" -NoTypeInformation

# 1. Remove the CNAME (an A record cannot be created while a CNAME exists for the same name)
Remove-DnsServerResourceRecord -ZoneName <domain.fqdn> -Name <alias> -RRType CName -ComputerName <dns-server> -Force

# 2. Add the alternate name (must be an FQDN)
netdom computername <realserver>.<domain.fqdn> /add:<alias>.<domain.fqdn>

# 3. Verify
netdom computername <realserver>.<domain.fqdn> /enum:altnames
setspn -L <realserver>        # expect HOST/<alias> and HOST/<alias>.<domain.fqdn>
ipconfig /registerdns         # on the server; or create the A record manually if the zone disallows dynamic updates
```
Plan a reboot of the file server (or at minimum a `LanmanServer` restart in a maintenance window) so SMB picks up the new name.

**Fails with "already exists"?** The SPN is still on the old computer object → do Fix 2 first.
**Rollback:** `netdom computername <realserver>.<domain.fqdn> /remove:<alias>.<domain.fqdn>`, delete the A record, re-create the CNAME from the exported CSV.
</details>

<details><summary>Fix 2 — Remove the alias SPN from the old / wrong computer object (KRB_AP_ERR_MODIFIED, duplicates)</summary>

```powershell
# Find every owner
setspn -Q HOST/<alias>.<domain.fqdn>; setspn -Q HOST/<alias>
setspn -X -F                                  # forest-wide duplicate report (slow in big forests)

# Remove from the WRONG object only
setspn -D HOST/<alias>.<domain.fqdn> <oldserver>
setspn -D HOST/<alias> <oldserver>

# If the old server was renamed/kept as a member: also clear its alternate-name attribute
netdom computername <oldserver>.<domain.fqdn> /enum:altnames
netdom computername <oldserver>.<domain.fqdn> /remove:<alias>.<domain.fqdn>
```
Then add the SPN to the correct server (Fix 1 or Fix 3). Clients: `klist purge` (or log off/on) — cached tickets with the wrong key persist until expiry.
**Rollback:** `setspn -S HOST/<alias>.<domain.fqdn> <oldserver>` (only if the old server really is still serving).
</details>

<details><summary>Fix 3 — Keep the CNAME, register the SPNs manually (when netdom isn't an option, e.g. alias in another DNS zone)</summary>

```powershell
# -S checks for duplicates before adding
setspn -S HOST/<alias>.<domain.fqdn> <realserver>
setspn -S HOST/<alias> <realserver>

# Server must accept the unknown name
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name DisableStrictNameChecking -Value 1 -Type DWord
# Optional: NetBIOS-level alias for short-name/browse access
New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name OptionalNames -PropertyType MultiString -Value '<ALIAS>' -Force
Restart-Service LanmanServer -Force   # drops open SMB sessions — maintenance window
```
**Rollback:** `setspn -D` the two SPNs; `Remove-ItemProperty ... -Name DisableStrictNameChecking, OptionalNames`; restart `LanmanServer`.
</details>

<details><summary>Fix 4 — SMB server SPN target-name hardening is rejecting the alias</summary>

```powershell
# On the file server
$p = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
Get-ItemProperty $p | Select SmbServerNameHardeningLevel, SrvAllowedServerNames
# GPO: "Microsoft network server: Server SPN target name validation level"

# Add the alias names (keep existing entries)
$cur = @((Get-ItemProperty $p -ErrorAction SilentlyContinue).SrvAllowedServerNames) | Where-Object { $_ }
$new = @($cur + '<alias>', '<alias>.<domain.fqdn>') | Select-Object -Unique
New-ItemProperty $p -Name SrvAllowedServerNames -PropertyType MultiString -Value $new -Force
Restart-Service LanmanServer -Force
```
If the hardening level is GPO-delivered, put the alias list in the same GPO — a local edit will be overwritten at next refresh.
**Rollback:** restore `$cur` into `SrvAllowedServerNames`.
</details>

<details><summary>Fix 5 — Alias fails only from the server itself (NTLM loopback check)</summary>

Better fix: make Kerberos work (Fix 1/3) — loopback check only affects NTLM. If a local job must use NTLM:

```powershell
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
New-ItemProperty $k -Name BackConnectionHostNames -PropertyType MultiString -Value @('<alias>','<alias>.<domain.fqdn>') -Force
# Do NOT set DisableLoopbackCheck=1 — it disables the protection for every name.
```
No reboot normally needed; re-test the job. **Rollback:** `Remove-ItemProperty $k -Name BackConnectionHostNames`.
</details>

<details><summary>Fix 6 — Short-term user workaround while the fix is scheduled</summary>

Remap to the real FQDN: `net use <X>: /delete; net use <X>: \\<realserver>.<domain.fqdn>\<share> /persistent:yes`. For GPO drive maps, switch the path to the real FQDN or a DFS namespace path (`\\<domain.fqdn>\<namespace>\<folder>`) so the next server migration needs no alias at all.
</details>

---
## Escalation Evidence
```
Alias (FQDN + short):                 <alias>.<domain.fqdn> / <alias>
Real server:                          <realserver>.<domain.fqdn>
DNS record type / target / IP:        <CNAME→x | A x.x.x.x>
Real name works?                      <Y/N>      Alias FQDN works? <Y/N>   Alias short works? <Y/N>
Exact error text / code:              <...>
setspn -Q HOST/<alias-fqdn> output:   <paste>
klist get cifs/<alias-fqdn> result:   <ticket / 0xc000018b / other>
Client Security-Kerberos event 4?     <Y/N + text>
netdom /enum:altnames on server:      <paste>
Server DisableStrictNameChecking / OptionalNames / SmbServerNameHardeningLevel / SrvAllowedServerNames: <paste>
Client OS build / SMB BlockNTLM:      <build> / <True/False>
Recent change (migration, rename, decommission): <...>
Script output attached (Get-FileServerAliasHealth.ps1 CSV): <path>
```

---
## 🎓 Learning Pointers
- Windows' Kerberos client builds the SPN from the name **you typed**, not the CNAME target — so every alias needs its own `HOST/` SPN or it silently drops to NTLM. That's why aliases "suddenly broke" once NTLM was restricted. See [SMB file server share access is unsuccessful through DNS CNAME alias](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/dns-cname-alias-cannot-access-smb-file-server-share).
- `netdom computername /add` is Microsoft's recommended replacement for CNAME + `DisableStrictNameChecking` + `OptionalNames` + manual `setspn` — one command, one rollback. Background: [Using Computer Name Aliases in place of DNS CNAME Records](https://techcommunity.microsoft.com/blog/coreinfrastructureandsecurityblog/using-computer-name-aliases-in-place-of-dns-cname-records/259064).
- `KRB_AP_ERR_MODIFIED` almost always means "the ticket was encrypted for a different account than the one answering" — in migrations, the alias SPN is still on the old server. Always `setspn -Q` before `setspn -S`.
- Always use `setspn -S` (duplicate-checking), never `-A`. Reference: [setspn](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/cc731241(v=ws.11)).
- Long-term, drive maps should point at a DFS namespace, not a server name or alias — then server moves are a folder-target change, not a DNS/SPN change. See `DFS/` in this repo.
- Deep dive and design choices: `FileServerAlias-A.md`. Fleet/one-shot evidence: `Windows/Scripts/Get-FileServerAliasHealth.ps1`.
