# Read-Only Domain Controllers (RODC) — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session with the `ActiveDirectory` module (any writable DC or RSAT host — **never** point Password Replication Policy (PRP) tools at the RODC itself for the authoritative view):

```powershell
# 1. What is currently ALLOWED to be cached on this RODC, and what is explicitly DENIED?
#    (Deny always wins over Allow — check this before assuming a config is wrong)
repadmin /prp view <RODC_Name> Allowed
repadmin /prp view <RODC_Name> Denied

# 2. Has a specific user's password actually been cached (revealed) on this RODC?
repadmin /prp view <RODC_Name> reveal | Select-String "<sam>"

# 3. Has that user ever tried to authenticate through this RODC at all?
#    (msDS-AuthenticatedToAccountList — helps decide whether to add them to Allowed)
Get-ADDomainController -Identity <RODC_Name> |
  Get-ADObject -Properties msDS-AuthenticatedToAccountList -ErrorAction SilentlyContinue

# 4. Quick sanity check: does the ADUC "Advanced PRP" view match repadmin's view?
#    A mismatch usually means replication lag between the RODC and a writable DC,
#    NOT a real config problem — repadmin always queries a writable DC, ADUC may query the RODC itself
Get-ADDomainController -Identity <RODC_Name> -Server <RODC_Name>

# 5. Is this RODC granted MORE than it should be? (the "replicates everyone's password" red flag)
dsacls "DC=<domain>,DC=<tld>" | Select-String "Enterprise Read-only Domain Controllers"
# Expect ONLY "Replicating Directory Changes" — if "Replicating Directory Changes All" is
# also listed, this RODC (and every other RODC in the domain) is bypassing PRP entirely — go to Fix 4
```

| What you see | What it means |
|---|---|
| A branch-office user authenticates fine on-site but fails completely the moment the WAN link to the hub is down | Their password was never cached on this RODC (not on the Allowed list, or this is their first-ever logon here) — go to Fix 1 |
| A user/group you explicitly added to the **Allowed** list still never gets cached | They're also (directly or via nested group membership) in the **Denied** list or a default-denied group — Deny always wins — go to Fix 2 |
| `repadmin /prp view <RODC> reveal` shows far more accounts cached than the branch office should ever authenticate | The RODC likely has **Replicating Directory Changes All** granted instead of just **Replicating Directory Changes** — this is a security-critical misconfiguration, not a PRP tuning issue — go to Fix 4 |
| LAPS password / BitLocker recovery key attribute isn't available when querying through the RODC, even for a fully-Allowed account | Expected. Those attributes are in the RODC **Filtered Attribute Set (FAS)** — never replicated to *any* RODC regardless of PRP. Query a writable DC instead — see Learning Pointers |
| RODC was physically stolen or is otherwise compromised | Stop tuning PRP — this is an incident. Go straight to Fix 3 (credential reset via computer account deletion) |
| Admin tries to reset a password or make any AD change while pointed at the RODC and it silently fails or behaves oddly | RODC hosts a **read-only** partition — it cannot process writes. The client should be following an LDAP referral to a writable DC automatically; if it isn't, point the tool explicitly at a writable DC — go to Fix 5 |
| New RODC deployed, DNS zone data / SRV records aren't showing up locally | Either normal replication latency, or (in older/long-upgraded forests) `adprep /rodcprep` was never run to grant RODCs read permission on the DNS application partitions — go to Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
RODC computer account created via a writable DC (RODC cannot be the first DC in a domain,
and cannot itself be the replication source for another RODC)
  └── RODC's own computer account + a dedicated PER-RODC krbtgt_<xxxxx> account are ALWAYS
      cached locally by default — this is what lets the RODC issue/validate Kerberos tickets
      at all, and is isolated from every other RODC's krbtgt and the domain's real krbtgt
        └── Password Replication Policy (PRP) — two attributes, Deny always beats Allow:
              ├── msDS-Reveal-OnDemandGroup → "Allowed" list (Allowed RODC Password
              │     Replication Group by default — EMPTY by default, nobody cached
              │     out of the box except the RODC's own account + its krbtgt)
              └── msDS-NeverRevealGroup → "Denied" list (Denied RODC Password Replication
                    Group by default — pre-populated with Domain Admins, Enterprise Admins,
                    Schema Admins, Cert Publishers, Enterprise Domain Controllers, Enterprise
                    Read-only Domain Controllers, Group Policy Creator Owners)
  └── Underlying AD replication permission: Enterprise Read-only Domain Controllers group
      MUST hold only "Replicating Directory Changes" on the domain partition — NEVER
      "Replicating Directory Changes All" (that right belongs only to Enterprise Domain
      Controllers / writable DCs) — this is the ACL PRP itself depends on to be enforceable
  └── Separate, broader exclusion layered on top of PRP: the RODC Filtered Attribute Set
      (FAS) — specific schema attributes (LAPS password, BitLocker recovery key, etc.) marked
      as NEVER replicated to any RODC, regardless of what PRP allows for that account
  └── Authentication flow at logon time:
        Client → RODC checks local cache
          ├── Cached → RODC authenticates locally, done
          └── Not cached → RODC forwards the auth request to a writable DC over its
              replication link → writable DC authenticates → result returned to RODC
                └── If PRP allows this account, RODC then pulls (unidirectional) that
                    one account's password so future logons are local
                      └── If the WAN link to a writable DC is down AND the password
                          isn't already cached → hard authentication failure, no
                          fallback exists
```

Key failure points:
- PRP only controls whether a password *gets cached* — it does **not** control whether a user can authenticate at all through the RODC (that always works, cached or not, as long as a writable DC is reachable to forward to)
- The Allowed list is empty by default — a brand-new RODC caches almost nothing until PRP is deliberately configured or accounts organically authenticate and get added
- Deny is absolute — no Allow entry, however specific, overrides Deny list membership (direct or nested)
- The "Replicating Directory Changes All" misconfiguration silently defeats the entire PRP model — the RODC stops being "read-only from a credential-exposure standpoint" and starts behaving like a full writable DC for replication purposes, while still living in a physically less-secure location by design

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm what's actually cached right now, from a writable DC's point of view**
```powershell
repadmin /prp view <RODC_Name> reveal
```
Expected: a short, deliberate list — the RODC's own account, its dedicated krbtgt, and accounts that have legitimately authenticated there and were allowed to cache. A long, unexplained list is a red flag.

**Step 2 — Confirm the Allowed and Denied list membership, including nested groups**
```powershell
Get-ADGroupMember -Identity "Allowed RODC Password Replication Group" -Recursive
Get-ADGroupMember -Identity "Denied RODC Password Replication Group" -Recursive
```
Expected: cross-reference against the affected account — Deny wins regardless of how deeply nested the Deny membership is.

**Step 3 — Confirm the account actually attempted to authenticate through this RODC**
```powershell
Get-ADObject -Identity (Get-ADDomainController -Identity <RODC_Name>).ComputerObjectDN `
  -Properties msDS-AuthenticatedToAccountList
```
Expected: if the affected user/computer isn't in this list, they've never actually reached this RODC — the problem may be site/subnet coverage routing them elsewhere, not PRP.

**Step 4 — Confirm the replication permission is correctly scoped (the security-critical check)**
```powershell
$domainDN = (Get-ADDomain).DistinguishedName
dsacls "$domainDN" | Select-String "Enterprise Read-only Domain Controllers"
```
Expected: only **Replicating Directory Changes**. If **Replicating Directory Changes All** also appears, escalate immediately — go to Fix 4.

**Step 5 — If DNS-related, confirm the RODC actually holds current zone data**
```powershell
Get-DnsServerZone -ComputerName <RODC_Name> | Where-Object { $_.ZoneType -eq 'Primary' }
```
Expected: zone present and `IsReadOnly = $true`. Missing zones point at Fix 6.

---
## Common Fix Paths

<details><summary>Fix 1 — User/computer fails to authenticate only when the WAN link is down</summary>

**Cause:** The account's password was never cached on this RODC — either it's not on the Allowed list, or it simply hasn't authenticated there yet (a first-time cache only happens after a successful forwarded authentication).

```powershell
# Add the user (and their computer account — logon needs BOTH cached) to the Allowed list
Add-ADDomainControllerPasswordReplicationPolicy -Identity <RODC_Name> `
  -AllowedList <sam>, <ComputerAccountName>$

# Prepopulate immediately rather than waiting for their next logon attempt
repadmin /rodcpwdrepl <RODC_Name> <Hub_Writable_DC> "<user DN>" "<computer DN>"

# Verify
repadmin /prp view <RODC_Name> reveal | Select-String "<sam>"
```

**Rollback note:** Removing an account from the Allowed list does not clear an already-cached password — see Fix 3 if credentials need to be actively purged, not just prevented from future caching.

</details>

<details><summary>Fix 2 — Account is on the Allowed list but still never gets cached</summary>

**Cause:** Deny always overrides Allow. The account is directly or transitively a member of the Denied RODC Password Replication Group, or one of the other default-denied groups (Domain Admins, Enterprise Admins, Schema Admins, Cert Publishers, Enterprise Domain/Read-only Domain Controllers, Group Policy Creator Owners).

```powershell
# Confirm the conflict
Get-ADGroupMember -Identity "Denied RODC Password Replication Group" -Recursive |
  Where-Object { $_.SamAccountName -eq '<sam>' }
```

**This is very likely intentional, not a bug** — Tier-0/privileged accounts are deny-listed by default specifically so their credentials never sit on a lower-security branch-office box. Do not remove a genuinely privileged account from the Denied list to work around this; instead:
- Use a non-privileged, branch-scoped account for day-to-day branch office work
- If the account genuinely shouldn't be privileged anymore, fix its actual group membership (see `Troubleshooting/AdminSDHolder/` if `adminCount` is also involved) rather than editing RODC deny policy around it

**Rollback note:** N/A — this is the Password Replication Policy protecting privileged credentials as designed.

</details>

<details><summary>Fix 3 — RODC stolen or otherwise physically compromised</summary>

**Cause:** Incident response, not routine PRP tuning. Every credential ever cached on this RODC (`msDS-RevealedList`) must be treated as compromised.

```powershell
# Before deleting: export the full list of cached accounts so every one can be reset
repadmin /prp view <RODC_Name> reveal | Out-File "C:\Temp\RODC_Compromised_Accounts.txt"

# Delete the RODC computer account via ADUC (Domain Controllers OU → right-click → Delete),
# and on the confirmation dialog:
#   [x] Reset all passwords for user accounts that were cached on this read-only domain controller
#   [x] Export the list of accounts that were cached on this RODC to this file
# There is no supported PowerShell-only equivalent for the automatic bulk password reset —
# use the ADUC deletion workflow specifically for this step.
```

**Rollback note:** N/A — deliberately destructive and irreversible by design (this is the point: force a credential reset for everything that was ever exposed). Coordinate with affected users/service owners before executing; this will lock out cached accounts until their passwords are reset.

</details>

<details><summary>Fix 4 — RODC has "Replicating Directory Changes All" instead of just "Replicating Directory Changes"</summary>

**Cause:** An administrator (often trying to resolve an unrelated replication error) granted the **Replicating Directory Changes All** extended right to the **Enterprise Read-only Domain Controllers** group, the RODC's computer object directly, or indirectly via another group. This right is supposed to belong only to writable DCs (**Enterprise Domain Controllers**). With it, the RODC replicates **all** attributes — including every user's password — exactly like a writable DC, completely bypassing Password Replication Policy.

```powershell
# 1. Confirm via LDP.exe (Connection > Bind > Browse > right-click domain DN > Advanced >
#    Security Descriptor > Text dump) that "Enterprise Read-only Domain Controllers" holds
#    Replicating Directory Changes All on the domain partition — dsacls output flags it too:
dsacls "DC=<domain>,DC=<tld>" | Select-String "Enterprise Read-only Domain Controllers"

# 2. Check whether it's coming through a DIFFERENT group the RODC computer object belongs to
#    (not just the obvious Enterprise Read-only Domain Controllers group) — use TokenGroups
#    via LDP (Browse > Search, Base scope, attribute = tokenGroups) against the RODC's
#    computer account, or:
Get-ADComputer <RODC_Name>$ -Properties MemberOf | Select-Object -ExpandProperty MemberOf

# 3. Remove the over-broad right — grant only "Replicating Directory Changes" back
dsacls "DC=<domain>,DC=<tld>" /R "<domain>\Enterprise Read-only Domain Controllers"
dsacls "DC=<domain>,DC=<tld>" /G "<domain>\Enterprise Read-only Domain Controllers:CA;DS-Replication-Get-Changes"
```

**This is a security-critical fix, not routine cleanup.** Treat every password that RODC has cached since the misconfiguration was introduced as potentially exposed — cross-reference `repadmin /prp view <RODC> reveal` timestamps against when the ACL was likely changed, and consider a targeted password reset for anything that shouldn't have been cached under the correct policy.

**Rollback note:** Restoring the narrower right does not retroactively un-cache anything already replicated. If exposure is confirmed or suspected, treat this the same as Fix 3 (reset the affected credentials) rather than assuming the ACL fix alone remediates the exposure.

</details>

<details><summary>Fix 5 — Write operation through the RODC fails or behaves oddly</summary>

**Cause:** RODC hosts a strictly read-only partition. Any tool pointed at it for a write (password reset, group membership change, GPO edit, etc.) should receive an LDAP referral to a writable DC automatically — if it isn't following that referral, the operation just fails or appears to hang.

```powershell
# Point the operation explicitly at a writable DC instead of relying on referral chasing
$writableDC = (Get-ADDomainController -Discover -Writable).HostName[0]
Set-ADUser <sam> -Server $writableDC -ChangePasswordAtLogon $true
```

**Rollback note:** N/A — no destructive change made; this simply routes the write to a DC that can actually process it.

</details>

<details><summary>Fix 6 — New RODC's DNS zone / SRV data isn't populating</summary>

**Cause:** Usually normal replication latency after promotion. In forests carried forward from very old versions, it can also mean `adprep /rodcprep` was never run, which grants RODCs the permissions needed to read the DNS application partitions.

```powershell
# Confirm rodcprep has been applied domain-wide (current schema versions imply this is done,
# but verify directly if this is a long-lived, multi-upgrade forest)
Get-ADObject "CN=ActiveDirectoryUpdate,CN=DomainUpdates,CN=System,$((Get-ADDomain).DistinguishedName)" `
  -Properties revision

# Confirm the RODC actually holds the DNS application partitions
Get-DnsServerZone -ComputerName <RODC_Name>
```

**Rollback note:** N/A — read-only verification. If `rodcprep` genuinely was never run, that's a forest-wide remediation to plan deliberately, not a quick fix during a live ticket.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — RODC / Password Replication Policy Issue
RODC name: ____________
Symptom (auth fails offline / Allowed account not caching / over-broad caching /
  RODC compromised / write operation failing / DNS not populating): ____________
Affected account(s): ____________
Currently on Allowed list (Yes/No): ____________
Currently on Denied list, direct or nested (Yes/No): ____________
`repadmin /prp view <RODC> reveal` output (attach): ____________
"Replicating Directory Changes All" present on Enterprise Read-only Domain Controllers
  (Yes/No — CRITICAL if Yes): ____________
WAN link to nearest writable DC status: ____________

Steps already attempted:
[ ] Checked Allowed vs. Denied list membership (including nested groups)
[ ] Confirmed via repadmin (not ADUC/MMC against the RODC itself) what's actually cached
[ ] Checked msDS-AuthenticatedToAccountList to confirm the account has reached this RODC
[ ] Verified Enterprise Read-only Domain Controllers holds ONLY "Replicating Directory
    Changes", not "...All"
[ ] Ruled out FAS/confidential-attribute exclusion as the actual cause (LAPS/BitLocker etc.)
```

---
## 🎓 Learning Pointers

- **Password Replication Policy (PRP) controls whether a password gets *cached*, not whether a user can *authenticate*.** An RODC will always forward an uncached account's authentication to a writable DC if one is reachable — the WAN link, not PRP, is what makes offline branch-office logon fail.
- **Deny always beats Allow, with no exceptions.** Before troubleshooting "why won't this account cache," check nested Denied-group membership first — it's usually intentional, not a bug.
- **"Replicating Directory Changes All" on an RODC is a distinct, security-critical failure mode from normal PRP misconfiguration** — it doesn't just cache more than intended, it defeats the entire read-only credential model. See [RODC replicates passwords when it's granted incorrect permissions](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/rodc-replicates-passwords-grant-incorrect-permissions).
- **Each RODC has its own dedicated krbtgt account, isolated from every other RODC and from the domain's real krbtgt.** This is a deliberate blast-radius control — compromising one RODC does not hand an attacker the domain-wide ticket-forging capability a compromised real krbtgt would.
- **The Filtered Attribute Set (FAS) is a separate, broader control from PRP** — attributes like LAPS passwords and BitLocker recovery keys are never replicated to *any* RODC regardless of PRP settings for that account. Don't mistake this for a PRP bug.
- Related: [Understanding "Read Only Domain Controller" authentication](https://learn.microsoft.com/en-us/archive/blogs/askds/understanding-read-only-domain-controller-authentication), [Password Replication Policy Administration](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-r2-and-2008/cc753470(v=ws.10)), [Attacking Read-Only Domain Controllers (RODCs) to Own Active Directory](https://adsecurity.org/?p=3592)
