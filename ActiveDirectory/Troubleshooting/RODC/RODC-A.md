# Read-Only Domain Controllers (RODC) — Reference Runbook (Mode A: Deep Dive)
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
- RODC architecture: the read-only AD database partition, unidirectional inbound replication, and why an RODC can never be another RODC's replication source
- Password Replication Policy (PRP): the Allowed/Denied list model, `msDS-Reveal-OnDemandGroup`/`msDS-NeverRevealGroup`, the default-empty Allowed list and default-populated Denied list, and the absolute precedence of Deny over Allow
- The per-RODC dedicated `krbtgt_<xxxxx>` account and why it exists as a blast-radius isolation control
- Authentication forwarding: how an RODC handles a logon for an account whose password isn't cached, and the WAN-down failure mode
- The RODC Filtered Attribute Set (FAS) as a distinct, broader exclusion layered on top of PRP
- The "Replicating Directory Changes All" misconfiguration: root cause, security impact, and remediation
- Local Administrator Role Separation, read-only DNS zone behavior, and the credential-reset-on-deletion incident response workflow

**Out of scope:**
- AdminSDHolder/SDProp ACL-stamping — a completely different protection mechanism for Tier-0 account permissions, not password caching (see `Troubleshooting/AdminSDHolder/AdminSDHolder-A.md`)
- Kerberos delegation/impersonation models (unconstrained, constrained, RBCD) — an authorization mechanism for the "double hop" problem, unrelated to RODC credential caching (see `Troubleshooting/KerberosDelegation/Delegation-A.md`)
- gMSA/dMSA managed service account password derivation — a different, KDS-root-key-based password model entirely (see `Troubleshooting/gMSA/gMSA-A.md` and `Troubleshooting/dMSA/dMSA-A.md`)
- General AD multi-master replication topology/FSMO mechanics between writable DCs — RODC replication is a specialized, unidirectional subset of this; see `Troubleshooting/Replication/AD-Replication-A.md` for the base replication model RODC inherits and restricts
- General Kerberos ticket lifecycle and NTLM fallback mechanics — this topic assumes the base authentication protocols already work; see `Windows/Troubleshooting/Kerberos-A.md`

**Assumptions:**
- The environment has at least one writable Windows Server domain controller — an RODC cannot be the first or only DC in a domain
- The `ActiveDirectory` PowerShell module and `repadmin`/`dsacls`/`ldp.exe` are available on the diagnostic host
- Forest schema and functional level requirements for RODC deployment have already been met (Windows Server 2008+ forest/domain functional level for RODC support; `adprep /rodcprep` — folded into standard forest preparation on modern installation media — must have run at least once to grant RODCs read access to the DNS application partitions)

---
## How It Works

<details><summary>Full architecture — read-only replication, PRP, per-RODC krbtgt, and the FAS</summary>

### The Read-Only Partition and Unidirectional Replication

An RODC hosts a read-only copy of the AD database. Except for passwords (governed separately by PRP, below), it holds essentially all the same objects and attributes a writable DC holds — but the local copy cannot be written to directly. Any client or tool that attempts a write against an RODC receives an LDAP referral pointing at a writable DC; the write never lands locally. Replication into an RODC is strictly **inbound**: changes flow from a writable DC to the RODC, never the reverse, with one narrow exception — after an RODC authenticates a user on behalf of a writable DC (see below), it issues a special, targeted **pull request** for that specific account's password, which is still technically an inbound replication event the RODC itself initiates, not an outbound push of locally-originated changes. Because of this one-way model, an RODC can never serve as the replication source for another RODC — every RODC's replication partner must be a writable DC.

### Password Replication Policy (PRP)

PRP is the mechanism that decides which account passwords are permitted to be cached locally on a *specific* RODC. It's implemented through two constructed/linked attributes on the RODC's computer object:

- **`msDS-Reveal-OnDemandGroup`** — points to the **Allowed list**. By default this points at the built-in **Allowed RODC Password Replication Group**, which has **no members by default**. A brand-new RODC therefore caches almost nothing out of the box.
- **`msDS-NeverRevealGroup`** — points to the **Denied list**. By default this points at the built-in **Denied RODC Password Replication Group**, which comes **pre-populated** with high-value/Tier-0 principals: Domain Admins, Enterprise Admins, Schema Admins, Cert Publishers, Enterprise Domain Controllers, Enterprise Read-only Domain Controllers, and Group Policy Creator Owners. This default-deny population is a deliberate secure-by-default choice — a fresh RODC ships already protecting the accounts that would do the most damage if exposed.

Two supporting, read-only-to-admins attributes complete the model:
- **`msDS-RevealedList`** — every account whose password has *ever* been cached on this RODC (a historical record; entries don't disappear just because an account is later removed from the Allowed list)
- **`msDS-AuthenticatedToAccountList`** — every account that has *authenticated through* this RODC, whether or not its password was ever cached — the intended feedback signal for right-sizing the Allowed list over time (`repadmin /prp move` can automate promoting frequently-authenticating accounts into the Allowed list)

**Deny always overrides Allow**, with no exception — if an account is in the Denied list (directly or via nested group membership) and simultaneously in the Allowed list, it will never be cached.

### The Authentication Flow

When a client authenticates against an RODC:
1. The RODC checks whether the account's password is already cached locally.
2. **Cached** → the RODC authenticates the request entirely on its own, no WAN traffic required.
3. **Not cached** → the RODC forwards the authentication request to a writable DC (over its existing replication connection). The writable DC performs the actual authentication and returns success/failure to the RODC, which relays it to the client.
4. If PRP permits caching for that account, the RODC then issues its own pull request to replicate that one account's password from the writable DC — so the *next* logon can be serviced locally. This is a background step; the client's current logon has already completed by this point.
5. If the WAN link to a reachable writable DC is down **and** the password was never previously cached, authentication fails outright — there is no further fallback.

The RODC's **own computer account** and a **dedicated per-RODC `krbtgt_<xxxxx>` account** are cached locally by default, regardless of PRP — this is what allows the RODC to issue and validate Kerberos service tickets for the accounts it *does* service, without which it couldn't function as a KDC at all. Critically, **every RODC gets its own unique krbtgt account**, separate from every other RODC's and from the domain's single shared krbtgt used by writable DCs. This is a deliberate blast-radius boundary: compromising one RODC's local krbtgt only lets an attacker forge tickets that a validating DC will recognize as originating from that specific RODC's trust boundary — it does not grant the domain-wide, universally-trusted forging capability that compromising the real domain krbtgt (a Golden Ticket) would.

### The Filtered Attribute Set (FAS) — A Separate, Broader Exclusion

PRP governs *account passwords*. A related but architecturally distinct mechanism, the **RODC Filtered Attribute Set (FAS)**, governs specific *schema attributes* that should never be replicated to **any** RODC at all, regardless of what PRP says about the account that owns them. Typical FAS members in a modern environment include LAPS password attributes and BitLocker recovery key attributes — data that's sensitive but isn't a logon credential PRP was designed around. FAS exclusions are forest-wide (marked at the schema attribute level) and apply uniformly to every RODC; they cannot be relaxed per-RODC the way PRP can be tuned per-RODC. Administrators extending the FAS are also advised to mark the same attribute confidential, which adds a defense-in-depth layer by removing the read permission needed to retrieve the value at all from an RODC that's later compromised.

### The "Replicating Directory Changes All" Misconfiguration

By design, only the **Enterprise Domain Controllers** group (writable DCs) holds the **Replicating Directory Changes All** extended right (`DS-Replication-Get-Changes-All`) on the domain partition. The **Enterprise Read-only Domain Controllers** group is supposed to hold only the narrower **Replicating Directory Changes** right (`DS-Replication-Get-Changes`). If an administrator — often while troubleshooting an unrelated replication error and reaching for a broad fix — grants the "All" variant to the Enterprise Read-only Domain Controllers group, to an individual RODC's computer object, or indirectly through any other group that RODC belongs to, the affected RODC(s) begin replicating **every** attribute, including every user's password, exactly as a writable DC would. This completely bypasses PRP: the Allowed/Denied list model has no effect once the underlying replication permission itself is over-scoped. The result is an RODC that still *looks* like a hardened, low-exposure branch-office box administratively, while actually holding the same credential exposure as a full writable DC — precisely inverting the security assumption the RODC role exists to provide, and a known technique for escalating access if an attacker can manipulate this specific ACL through any other compromised path.

</details>

---
## Dependency Stack

```
Forest/domain functional level meets RODC minimum; adprep/rodcprep has granted RODCs
read access to DNS application partitions
  └── At least one writable DC exists (RODC cannot be the first DC, and cannot be another
      RODC's replication source — RODC-to-RODC replication is not supported)
        └── RODC computer account created; unidirectional inbound replication established
            against a writable DC
              ├── RODC's own computer account + dedicated per-RODC krbtgt_<xxxxx> cached
              │   locally by default (isolated per-RODC, distinct from the domain krbtgt)
              └── Password Replication Policy governs all other accounts:
                    ├── msDS-Reveal-OnDemandGroup → Allowed list (empty by default)
                    └── msDS-NeverRevealGroup → Denied list (pre-populated with Tier-0
                        groups by default) — DENY ALWAYS WINS over Allow
                          └── Underlying enforcement DEPENDS ON the Enterprise Read-only
                              Domain Controllers group holding ONLY "Replicating Directory
                              Changes" (not "...All") on the domain partition — if this ACL
                              is over-scoped, PRP is bypassed entirely regardless of its
                              own configuration
  └── Separate, parallel control: RODC Filtered Attribute Set (FAS) — forest-wide schema
      attribute exclusions (LAPS, BitLocker, etc.) applied identically to every RODC,
      independent of PRP and not tunable per-RODC
  └── At logon time: cached → local auth | not cached → forward to writable DC → (if PRP
      allows) background pull-replicate that account's password for next time
        └── WAN link down + password never cached = hard authentication failure, no fallback
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Branch-office users authenticate fine normally but fail completely the instant the WAN link to the hub goes down | Their password was never cached on the local RODC — not on the Allowed list, or this is their first logon attempt at that site | `repadmin /prp view <RODC> reveal` — confirm absence |
| An account explicitly added to the Allowed list still never caches | Deny overrides Allow — the account is directly or transitively in the Denied list / a default-denied group (Domain Admins, Enterprise Admins, etc.) | `Get-ADGroupMember "Denied RODC Password Replication Group" -Recursive` |
| `repadmin /prp view <RODC> reveal` shows far more cached accounts than the branch site should ever produce | **Replicating Directory Changes All** is likely granted to Enterprise Read-only Domain Controllers (or this RODC specifically) instead of just "Replicating Directory Changes" — PRP is being bypassed | `dsacls` on the domain partition; look for "...All" next to Enterprise Read-only Domain Controllers |
| ADUC's Password Replication Policy tab and `repadmin /prp` disagree about what's cached | Replication lag between the RODC and the writable DC being queried — ADUC/MMC can query the RODC itself, `repadmin /prp` always queries a writable DC | Re-check both against the same, confirmed-current DC; wait out normal replication latency before assuming a config bug |
| A LAPS password or BitLocker recovery key attribute isn't retrievable when the query is routed through the RODC | Expected — these attributes are typically in the RODC Filtered Attribute Set and are never replicated to *any* RODC, independent of PRP | Query a writable DC for that specific attribute instead |
| RODC was physically stolen, lost, or otherwise compromised | Every credential in `msDS-RevealedList` for that RODC must be treated as exposed | Export the reveal list before deleting the computer account; use the ADUC deletion workflow's built-in bulk password-reset option |
| A write operation (password reset, group change, GPO edit) fails or hangs when a tool is pointed at the RODC | RODC hosts a read-only partition; the client should follow an LDAP referral to a writable DC automatically — if it doesn't, the operation just fails locally | Point the tool explicitly at a discovered writable DC instead |
| New RODC's DNS zone data or SRV records aren't appearing locally | Normal replication latency in most cases; in very old, multi-upgrade forests, `adprep /rodcprep` permissions on the DNS application partitions may genuinely be missing | `Get-DnsServerZone -ComputerName <RODC>`; confirm zone presence and `IsReadOnly` state |

---
## Validation Steps

**Step 1 — Establish the authoritative cached-credential baseline (always from a writable DC)**
```powershell
repadmin /prp view <RODC_Name> reveal
```
Expected: a short, explainable list — the RODC's own account, its dedicated krbtgt, and legitimately-Allowed branch accounts. Anything unexplained warrants Step 4 immediately.

**Step 2 — Confirm Allowed/Denied list membership, transitively**
```powershell
Get-ADGroupMember -Identity "Allowed RODC Password Replication Group" -Recursive
Get-ADGroupMember -Identity "Denied RODC Password Replication Group" -Recursive
```
Expected: cross-reference against any account behaving unexpectedly — remember Deny wins even through nested membership several groups deep.

**Step 3 — Confirm whether the account has ever actually reached this RODC**
```powershell
Get-ADObject -Identity (Get-ADDomainController -Identity <RODC_Name>).ComputerObjectDN `
  -Properties msDS-AuthenticatedToAccountList
```
Expected: presence here means the account genuinely authenticates via this RODC — useful before deciding whether to expand the Allowed list at all.

**Step 4 — Verify the domain partition's replication ACL is correctly scoped for RODCs**
```powershell
$domainDN = (Get-ADDomain).DistinguishedName
dsacls "$domainDN" | Select-String "Enterprise (Read-only )?Domain Controllers"
```
Expected: **Enterprise Domain Controllers** holds "Replicating Directory Changes All"; **Enterprise Read-only Domain Controllers** holds only "Replicating Directory Changes". Any RODC-related "...All" grant is a critical finding.

**Step 5 — If an FAS exclusion is suspected, confirm the attribute is actually filtered, not just missing due to a real fault**
```powershell
# Requires querying the schema partition for searchFlags bit 0x200 (fRODCFilteredAttribute)
# on the attribute in question — see the Evidence Pack script for an automated version
Get-ADObject -SearchBase (Get-ADRootDSE).schemaNamingContext `
  -LDAPFilter "(lDAPDisplayName=<attributeName>)" -Properties searchFlags
```
Expected: `searchFlags` includes bit `0x200` for genuinely FAS-excluded attributes.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Distinguish "Won't Authenticate" from "Won't Cache"
1. Confirm whether the actual complaint is a hard authentication failure (WAN-down, no fallback) or merely "credentials aren't cached" (which doesn't block authentication when the WAN is up)
2. A hard failure with the WAN up points at something other than PRP entirely (network, DNS, site/subnet coverage) — don't over-focus on PRP if the WAN link is confirmed healthy

### Phase 2 — Validate PRP State From the Correct Vantage Point
1. Always confirm cached/allowed/denied state via `repadmin /prp` against a writable DC, not ADUC pointed at the RODC itself, to avoid chasing replication-lag false positives
2. Check nested group membership on both Allowed and Denied — Deny's precedence is absolute and the most common source of "I added them but it's still not working" tickets

### Phase 3 — Rule Out the Over-Broad Replication ACL
1. Treat any RODC caching noticeably more than expected as a potential **Replicating Directory Changes All** misconfiguration until confirmed otherwise via `dsacls`
2. If confirmed, this is a security incident-adjacent finding, not routine tuning — proceed to Remediation Playbook 1

### Phase 4 — Separate FAS Exclusions From Genuine Faults
1. If a specific attribute (not a whole account) is missing via the RODC, check whether it's a known FAS member (LAPS, BitLocker) before treating it as a bug
2. Query a writable DC directly for anything FAS-excludes — there is no per-RODC override

### Phase 5 — Incident Response Path
1. Physical compromise or theft moves this out of routine troubleshooting entirely — treat `msDS-RevealedList` as the exposure inventory and execute Remediation Playbook 2
2. Don't skip the export step before deletion — the list is not recoverable after the RODC computer account is gone

---
## Remediation Playbooks

<details><summary>Playbook 1 — Correcting an over-broad "Replicating Directory Changes All" grant</summary>

**Scenario:** `dsacls` confirms the Enterprise Read-only Domain Controllers group (or a specific RODC's computer object, directly or via another group) holds Replicating Directory Changes All on the domain partition, and `repadmin /prp view <RODC> reveal` shows an unexplained, broad set of cached credentials.

**Step 1 — Confirm scope: is this domain-wide (the built-in group) or isolated to one RODC?**
```powershell
$domainDN = (Get-ADDomain).DistinguishedName
dsacls "$domainDN" | Select-String "Enterprise Read-only Domain Controllers|<RODC_Name>\$"
```

**Step 2 — If via nested group membership, identify the exact path using TokenGroups (LDP: Browse > Search, Base scope, attribute `tokenGroups`, against the RODC's computer object) rather than assuming it's the obvious built-in group**

**Step 3 — Remove the over-broad right and restore the narrow one**
```powershell
dsacls "$domainDN" /R "<domain>\Enterprise Read-only Domain Controllers"
dsacls "$domainDN" /G "<domain>\Enterprise Read-only Domain Controllers:CA;DS-Replication-Get-Changes"
```

**Step 4 — Treat cached credentials since the likely introduction date as exposed**
```powershell
repadmin /prp view <RODC_Name> reveal
# Cross-reference whenChanged/replication metadata for the affected accounts against
# the likely window the ACL was wrong, and plan targeted password resets accordingly
```

**Rollback note:** Restoring the correct ACL does not retroactively un-cache anything already replicated under the incorrect permission — this playbook's Step 4 (credential exposure review) is not optional cleanup, it's the actual remediation for the exposure itself, not just the misconfiguration.

</details>

<details><summary>Playbook 2 — RODC theft / physical compromise incident response</summary>

**Scenario:** An RODC (typically a branch-office box with weaker physical security by design) is confirmed lost, stolen, or otherwise compromised.

**Step 1 — Export the full reveal list immediately, before any deletion action**
```powershell
repadmin /prp view <RODC_Name> reveal | Out-File "C:\Temp\RODC_$($RODC_Name)_Compromised_$(Get-Date -Format yyyyMMdd_HHmmss).txt"
```

**Step 2 — Delete the RODC's computer account via Active Directory Users and Computers** (Domain Controllers OU → right-click the RODC → Delete), and on the confirmation dialog select:
- **Reset all passwords for user accounts that were cached on this read-only domain controller**
- **Export the list of accounts that were cached on this read-only domain controller to this file**

There is no supported PowerShell-only equivalent that performs the automatic bulk password reset — this specific workflow is the documented, supported path for this scenario.

**Step 3 — Coordinate the resulting password resets and re-provisioning with affected users/service owners before they attempt to log on again**

**Rollback note:** N/A by design — this is a deliberately destructive, irreversible incident-response action. The entire point is to invalidate every credential that could have been physically exposed.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  RODC / Password Replication Policy Evidence Collector
.NOTES     Read-only. Run against/for a specific RODC from a writable DC or RSAT host.
#>

param([Parameter(Mandatory=$true)][string]$RODCName)

$reportPath = "C:\Temp\RODCEvidence_${RODCName}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Allowed List (recursive) ===" | Out-File "$reportPath\01_Allowed.txt"
Get-ADGroupMember -Identity "Allowed RODC Password Replication Group" -Recursive -ErrorAction SilentlyContinue |
  Select-Object Name, SamAccountName | Format-Table -AutoSize | Out-File "$reportPath\01_Allowed.txt" -Append

"=== Denied List (recursive) ===" | Out-File "$reportPath\02_Denied.txt"
Get-ADGroupMember -Identity "Denied RODC Password Replication Group" -Recursive -ErrorAction SilentlyContinue |
  Select-Object Name, SamAccountName | Format-Table -AutoSize | Out-File "$reportPath\02_Denied.txt" -Append

"=== Currently Revealed (cached) Credentials — via repadmin ===" | Out-File "$reportPath\03_Revealed.txt"
repadmin /prp view $RODCName reveal | Out-File "$reportPath\03_Revealed.txt" -Append

"=== Domain Partition Replication ACL (RODC-relevant rows) ===" | Out-File "$reportPath\04_ReplicationACL.txt"
$domainDN = (Get-ADDomain).DistinguishedName
dsacls "$domainDN" | Select-String "Enterprise (Read-only )?Domain Controllers" |
  Out-File "$reportPath\04_ReplicationACL.txt" -Append

"=== RODC Computer Object Group Membership (indirect replication-right paths) ===" | Out-File "$reportPath\05_RODCMemberOf.txt"
Get-ADComputer "$RODCName`$" -Properties MemberOf -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty MemberOf | Out-File "$reportPath\05_RODCMemberOf.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| View cached (revealed) credentials on an RODC | `repadmin /prp view <RODC> reveal` |
| View Allowed / Denied PRP list for an RODC | `repadmin /prp view <RODC> Allowed` / `Denied` |
| Add account(s) to the Allowed list | `Add-ADDomainControllerPasswordReplicationPolicy -Identity <RODC> -AllowedList <sam>` |
| Add account(s) to the Denied list | `Add-ADDomainControllerPasswordReplicationPolicy -Identity <RODC> -DeniedList <sam>` |
| Prepopulate a password onto an RODC | `repadmin /rodcpwdrepl <RODC> <HubDC> "<DN>"` |
| Promote frequent authenticators from Authenticated to Allowed | `repadmin /prp move` |
| Check who has ever authenticated to this RODC | `Get-ADObject <RODC-computer-DN> -Properties msDS-AuthenticatedToAccountList` |
| Check the domain partition's replication ACL | `dsacls "DC=<domain>,DC=<tld>"` |
| Correct an over-broad RODC replication right | `dsacls <domainDN> /R ... ; dsacls <domainDN> /G "...:CA;DS-Replication-Get-Changes"` |
| Verify RODC read-only DNS zone state | `Get-DnsServerZone -ComputerName <RODC>` |
| Discover a writable DC for a redirected write | `Get-ADDomainController -Discover -Writable` |

---
## 🎓 Learning Pointers

- **PRP governs credential caching, not authentication capability.** An RODC always forwards uncached logons to a writable DC when one is reachable — offline branch failures are a WAN-availability problem intersecting with an empty cache, not a PRP bug by itself.
- **The Denied list's precedence over Allowed is absolute, and its default membership is intentionally conservative** (Domain Admins, Enterprise Admins, Schema Admins, and other Tier-0 groups) — this is the RODC threat model working correctly, not something to route around.
- **Every RODC has its own isolated krbtgt account, distinct from the domain's shared krbtgt.** This is the specific design choice that keeps a single compromised branch-office RODC from becoming a domain-wide Golden-Ticket-equivalent event.
- **"Replicating Directory Changes All" on an RODC is not a bigger version of a PRP misconfiguration — it's a different, more serious failure mode that bypasses PRP entirely.** Any RODC caching an unexplained volume of credentials should have this ACL checked before anything else. See [RODC replicates passwords when it's granted incorrect permissions](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/rodc-replicates-passwords-grant-incorrect-permissions) and [Attacking Read-Only Domain Controllers (RODCs) to Own Active Directory](https://adsecurity.org/?p=3592) for the security-research framing of the same underlying ACL.
- **The Filtered Attribute Set is forest-wide and cannot be tuned per-RODC** — don't spend time adjusting PRP for an account when the actual missing data (LAPS, BitLocker) is excluded at the schema-attribute level for every RODC uniformly.
- **The RODC deletion workflow's built-in credential-reset option exists specifically for the theft/compromise scenario the role is designed around** — export the reveal list first, since it isn't recoverable after deletion.
- Related: [Understanding "Read Only Domain Controller" authentication](https://learn.microsoft.com/en-us/archive/blogs/askds/understanding-read-only-domain-controller-authentication), [Password Replication Policy Administration](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-r2-and-2008/cc753470(v=ws.10)), [RODC Filtered Attribute Set, Credential Caching, and the Authentication Process with an RODC](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-R2-and-2008/cc753459(v=ws.10))
