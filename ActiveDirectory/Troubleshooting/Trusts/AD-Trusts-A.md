# AD Domain & Forest Trusts — Reference Runbook (Mode A: Deep Dive)
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
- Domain trusts (parent-child, tree-root, shortcut) within a single forest
- Forest trusts between two separate Active Directory forests
- External trusts (NT4-style, non-transitive) to a single domain in another forest
- Realm trusts to non-Windows Kerberos realms (brief coverage)
- SID filtering (quarantine) and selective authentication as trust-security controls
- Trust secure channel health, Kerberos referral path, and DNS dependencies

**Out of scope:**
- Intra-domain replication between DCs of the *same* domain (see `ActiveDirectory/Troubleshooting/Replication/AD-Replication-A.md`)
- Entra ID / Entra Connect hybrid identity (a completely different trust model — see `EntraID/Troubleshooting/Connect-Sync-A.md`)
- AD FS claims-based federation (uses trust-like constructs but is a separate federation protocol, not a Windows AD trust)
- Conditional Access / Azure-side authentication policy (see `Security/ConditionalAccess/`)

**Assumptions:**
- You have Domain Admin (or delegated trust-management) rights in at least the domain reporting the issue
- RSAT AD DS/AD LDS tools are available (`netdom`, `nltest`, the `ActiveDirectory` PowerShell module)
- You have some ability to coordinate with an admin on the "other side" of the trust — many trust problems cannot be fully diagnosed or fixed unilaterally

---
## How It Works

<details><summary>Full architecture — trust types, authentication path, and security boundaries</summary>

### What a Trust Actually Is

A trust is a **Trusted Domain Object (TDO)** stored in each participating domain's `System` container, containing the partner domain's name, SID, trust type/attributes, and a shared secret (the trust password), which both sides use to establish a **secure channel** (the same mechanism a workstation uses to trust its own domain, just between two domains instead).

A trust does **not** by itself grant access to anything. It only establishes that Domain A's Kerberos KDC will accept referral requests involving Domain B's security principals, and vice versa depending on direction. Actual access is still governed entirely by normal resource ACLs in the target domain — the trust just makes cross-domain Kerberos referrals and SID resolution possible.

### Trust Types

| Type | Transitive? | Scope | Typical use |
|---|---|---|---|
| Parent-Child | Yes (automatic) | Within one forest | Created automatically when a child domain is added |
| Tree-Root | Yes (automatic) | Within one forest | Created automatically when a new domain tree is added to a forest |
| Shortcut | Yes | Within one forest | Manually created to speed up authentication between distant domains in a large forest (skips walking the full tree) |
| Forest | Yes (optionally) | Between two forests | Full forest-to-forest trust — every domain in Forest A trusts every domain in Forest B |
| External | No | Between two specific domains, any forests | Narrower than a forest trust — only the two named domains trust each other; SID filtering (quarantine) is on by default |
| Realm | Configurable | Windows domain ↔ non-Windows Kerberos realm | Interop with MIT Kerberos or similar; less common in pure-Microsoft shops |

### Authentication Path Across a Trust

1. A user in Domain A requests access to a resource in Domain B.
2. The client asks Domain A's KDC for a service ticket to the Domain B resource.
3. Domain A's KDC recognizes the resource isn't local and issues a **referral ticket** (a TGT usable at Domain B's KDC), following the trust path — direct if a trust exists, or walked up/down the forest tree if not (parent-child/tree-root chaining).
4. The client presents the referral ticket to Domain B's KDC, which issues the actual service ticket for the target resource.
5. Domain B's resource server evaluates the presented ticket's SIDs against its ACL — access is a **local authorization decision**, entirely separate from the trust's existence.

### Security Controls Layered on Top of the Trust

- **SID Filtering (Quarantine):** By default, **external** and **forest** trusts (forest trust SID filtering is optional but recommended) strip SID history from tickets crossing the trust boundary. This exists because SID history is technically forgeable by anyone with sufficient rights in the source domain — quarantine assumes the other side of the trust might not be as tightly controlled as your own domain. This becomes a real support issue after a domain migration, where accounts rely on SID history from the old domain to retain access.
- **Selective Authentication:** An optional trust attribute that changes the default-allow model. With it enabled, a healthy trust and a valid ACL are *not* enough — every user or computer that should authenticate across the trust needs an explicit "Allowed to Authenticate" extended right granted directly on the target computer object in the resource domain. Without selective auth, any authenticated principal from the trusted domain can *attempt* authentication (still subject to normal resource ACLs); with it, unauthorized principals are blocked before they can even attempt to authenticate to that computer.
- **Trust Password Rotation:** Like a computer account, the TDO password rotates automatically (default ~30 days) via Netlogon. If one side of the trust is offline during a rotation or the rotation only completes on one side (e.g., a WAN partition), the two sides fall out of sync — this produces the classic "verifies on one side but not the other" symptom.

</details>

---
## Dependency Stack

```
DNS resolution between the two domains (conditional forwarder, secondary zone, or delegation)
  └── Network reachability (88 Kerberos, 389/636 LDAP, 445 SMB, 135+dynamic RPC)
        └── Trusted Domain Object (TDO) present and password-synchronized on both sides
              └── Netlogon secure channel (same mechanism as a domain-joined computer, between domains)
                    └── Kerberos referral chain (client domain KDC → trust path → resource domain KDC)
                          └── SID filtering (quarantine) evaluation on ticket crossing the boundary
                                └── Selective authentication evaluation, if enabled (per-object ACE required)
                                      └── Standard resource ACL evaluation in the target domain
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `netdom trust /verify` fails on one side only | TDO password out of sync between domains | Re-run `/verify` from both sides; reset password if mismatched |
| Users can't authenticate at all across the trust | Secure channel broken, DNS failure, or network path blocked | `netdom trust /verify`, DNS SRV lookup, port test |
| Trust shows healthy but access is still denied | SID filtering stripping required SID history, or selective auth blocking | `Get-ADTrust` SIDFilteringQuarantined/SelectiveAuthentication properties |
| Access worked before a domain migration, broke after | Migrated accounts depend on SID history, now filtered by external-trust quarantine | Confirm trust type is External (filters by default) vs Forest |
| One-way trust behaves like it doesn't exist from the "wrong" side | Trust direction misunderstood — a resource domain must trust the account domain, not the reverse | `Get-ADTrust` Direction property |
| Netlogon event ID 5719 in System log | Cannot locate a DC in the trusted domain | DNS SRV records, network path to trusted-domain DCs |
| Netlogon event ID 5722 in System log | Secure channel authentication failed | Trust password reset |
| Cross-forest Kerberos works for users but not for delegated/constrained-delegation service accounts | Constrained delegation across a forest boundary requires resource-based constrained delegation (RBCD) or explicit trust-level configuration — classic domain-only S4U2Proxy doesn't cross forest boundaries by default | Review delegation model, not the trust itself |
| Realm trust to a non-Windows Kerberos environment fails intermittently | Encryption type mismatch (AES vs RC4) between the Windows and non-Windows KDC | `Get-ADTrust` and `ktpass`/`msDS-SupportedEncryptionTypes` on the trust object |
| Trust exists in `Get-ADTrust` but `nltest /trusted_domains` doesn't list it on a specific DC | That DC hasn't replicated the TDO yet, or has a stale Netlogon cache | Confirm AD replication health first (see `AD-Replication-A.md`), then `nltest /sc_reset` |

---
## Validation Steps

**Step 1 — Enumerate all trusts and their key attributes**
```powershell
Get-ADTrust -Filter * | Select-Object Name, Direction, TrustType, ForestTransitive, SIDFilteringForestAware, SIDFilteringQuarantined, SelectiveAuthentication
```
Expected: matches your documented trust design (direction, type, and security flags all as intended — not just "a trust exists").

**Step 2 — Verify the secure channel from both sides**
```powershell
netdom trust <ThisDomain> /Domain:<TrustedDomain> /verify
# and, from a DC in the other domain:
netdom trust <TrustedDomain> /Domain:<ThisDomain> /verify
```
Expected: `The specified domain trust exists and is in valid condition` on both sides.

**Step 3 — Confirm DNS resolves the trusted domain's DCs**
```powershell
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<TrustedDomain>" -Type SRV
Resolve-DnsName -Name "_kerberos._tcp.dc._msdcs.<TrustedDomain>" -Type SRV
```
Expected: both resolve to reachable, current DCs.

**Step 4 — Confirm network path on required ports to a trusted-domain DC**
```powershell
Test-NetConnection -ComputerName <TrustedDomainDC> -Port 88   # Kerberos
Test-NetConnection -ComputerName <TrustedDomainDC> -Port 389  # LDAP
Test-NetConnection -ComputerName <TrustedDomainDC> -Port 445  # SMB
```

**Step 5 — Check SID filtering / quarantine state against design intent**
```powershell
Get-ADTrust -Filter * | Select-Object Name, TrustType, SIDFilteringQuarantined
```
Expected: `SIDFilteringQuarantined = True` on external trusts unless a controlled migration window is explicitly in progress.

**Step 6 — Check selective authentication scope, if enabled**
```powershell
(Get-ADTrust -Identity "<TrustedDomain>").SelectiveAuthentication
```
If `True`, cross-reference with the target computer object's ACL for an "Allowed to Authenticate" ACE for the relevant users/groups.

**Step 7 — Confirm Netlogon secure channel discovery from a client's perspective**
```powershell
nltest /dsgetdc:<TrustedDomain>
nltest /trusted_domains
```
Expected: the trusted domain is listed and a DC is returned without error.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Name Resolution & Network Layer
1. Confirm DNS conditional forwarder or delegation exists and resolves correctly in both directions
2. Confirm required ports (88, 389, 636, 445, 3268/3269 for GC, 135+dynamic RPC) are open between domains
3. Rule out split-horizon DNS returning different DC lists depending on which resolver answers

### Phase 2 — Trust Object & Secure Channel Layer
1. Run `netdom trust /verify` from both sides — a one-sided failure means a password desync, not a network problem
2. Check Netlogon event log (System log, source NETLOGON) for event IDs 5719/5722 on both sides
3. If desynced, reset the trust password (Playbook 1) — coordinate timing with the other domain's admin

### Phase 3 — Kerberos Referral Layer
1. Confirm the client actually receives a referral ticket (`klist tickets` after an access attempt) — no referral means the failure is upstream of the trust, not the trust itself
2. For cross-forest scenarios, confirm the forest trust (not just a domain trust) exists if resources span multiple domains within the partner forest
3. Check encryption type compatibility for realm trusts (`msDS-SupportedEncryptionTypes` on the trust object) — AES-only environments reject RC4-only realm KDCs and vice versa

### Phase 4 — Security Control Layer (SID Filtering / Selective Auth)
1. If the trust verifies but access is still denied, check `SIDFilteringQuarantined` — especially right after a domain migration where SID history matters
2. If `SelectiveAuthentication` is `True`, confirm the specific user/computer has the "Allowed to Authenticate" ACE on the target resource computer object
3. Don't disable SID filtering or selective auth as a first troubleshooting step — both are security boundaries; disabling either should be a deliberate, time-boxed, documented decision

### Phase 5 — Resource Authorization Layer
1. Once the trust, referral, and security-control layers are confirmed healthy, treat remaining access denials as a standard local ACL problem in the resource domain — not a trust problem
2. Confirm the resolved SID (post-filtering) actually appears on the resource ACL as expected

---
## Remediation Playbooks

<details><summary>Playbook 1 — Reset a desynced trust password</summary>

**Scenario:** `netdom trust /verify` succeeds from one domain but fails from the other — the TDO password has fallen out of sync, usually after a WAN partition during a scheduled rotation.

**Step 1 — Confirm the asymmetry**
```powershell
netdom trust <DomainA> /Domain:<DomainB> /verify
netdom trust <DomainB> /Domain:<DomainA> /verify
```

**Step 2 — Reset the password from one side with credentials for both**
```powershell
netdom trust <DomainA> /Domain:<DomainB> /ResetPWD `
  /UserD:<DomainA-Admin> /PasswordD:* `
  /UserO:<DomainB-Admin> /PasswordO:*
```

**Step 3 — Re-verify both directions**
```powershell
netdom trust <DomainA> /Domain:<DomainB> /verify
netdom trust <DomainB> /Domain:<DomainA> /verify
```

**Rollback note:** Non-destructive — resetting the trust password does not affect existing resource ACLs, SID history, or any object data. Safe to run any time both admin teams are available.

</details>

<details><summary>Playbook 2 — Controlled SID-filtering suspension during a domain migration</summary>

**Scenario:** Users were migrated from Domain B into Domain A (or vice versa) and need continued access to resources that check SID history, but the external trust's default quarantine is stripping it.

**Step 1 — Document the exact time-boxed window and get sign-off** (this is a security-relevant change — treat it like a change request, not a routine fix)

**Step 2 — Disable quarantine for the migration window**
```powershell
netdom trust <ThisDomain> /Domain:<TrustedDomain> /quarantine:No /UserD:<Admin> /PasswordD:*
```

**Step 3 — Validate migrated-account access works as expected**
```powershell
# From an affected client, confirm access to the resource that depends on SID history
klist tickets
```

**Step 4 — Re-enable quarantine the moment the migration cutover is complete**
```powershell
netdom trust <ThisDomain> /Domain:<TrustedDomain> /quarantine:Yes /UserD:<Admin> /PasswordD:*
```

**Rollback note:** Fully reversible via `/quarantine:Yes`. The risk isn't in reverting — it's in leaving quarantine disabled longer than the migration window requires, since SID history is forgeable by a sufficiently privileged attacker in the source domain during that time.

</details>

<details><summary>Playbook 3 — Scoping selective authentication for a new cross-forest integration</summary>

**Scenario:** A new forest trust with selective authentication enabled needs a specific group of users to reach a specific set of servers — nothing works by default, which is expected but often mistaken for a broken trust.

**Step 1 — Confirm selective authentication is indeed the model in use**
```powershell
(Get-ADTrust -Identity "<TrustedDomain>").SelectiveAuthentication
```

**Step 2 — Grant "Allowed to Authenticate" on each target computer object for the relevant trusted-domain group**
```powershell
$computers = Get-ADComputer -Filter 'Name -like "APP-SRV*"'
$identity  = New-Object System.Security.Principal.NTAccount("<TrustedDomain>\<GroupName>")
$sid       = $identity.Translate([System.Security.Principal.SecurityIdentifier])
$ace       = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid, "ExtendedRight", "Allow", [GUID]"68b1d179-0d15-4d4f-ab71-46152e79a7bc")

foreach ($c in $computers) {
    $acl = Get-Acl "AD:\$($c.DistinguishedName)"
    $acl.AddAccessRule($ace)
    Set-Acl "AD:\$($c.DistinguishedName)" -AclObject $acl
}
```

**Step 3 — Validate from an affected client**
```powershell
klist tickets
```

**Rollback note:** Additive, per-object ACE — remove the specific `AccessRule` from each computer's ACL to revert scope, or disable selective authentication entirely on the trust if the model itself needs to change (a bigger decision, coordinate with the trust owner).

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  AD Trust Evidence Collector
.NOTES     Run from a DC in the domain reporting the issue, with Domain Admin rights
#>

$reportPath = "C:\Temp\ADTrustEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== All Trusts ===" | Out-File "$reportPath\01_Trusts.txt"
Get-ADTrust -Filter * | Format-List | Out-File "$reportPath\01_Trusts.txt" -Append

"=== nltest trusted domains ===" | Out-File "$reportPath\02_NltestTrusts.txt"
nltest /trusted_domains | Out-File "$reportPath\02_NltestTrusts.txt" -Append

"=== Netlogon events (last 100) ===" | Out-File "$reportPath\03_NetlogonEvents.txt"
Get-WinEvent -LogName "System" -MaxEvents 100 |
  Where-Object { $_.ProviderName -eq "NETLOGON" } |
  Select-Object TimeCreated, Id, Message |
  Format-List | Out-File "$reportPath\03_NetlogonEvents.txt" -Append

"=== DNS SRV resolution checks ===" | Out-File "$reportPath\04_DnsChecks.txt"
foreach ($t in (Get-ADTrust -Filter *)) {
    "--- $($t.Name) ---" | Out-File "$reportPath\04_DnsChecks.txt" -Append
    try {
        Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$($t.Name)" -Type SRV -ErrorAction Stop |
          Out-File "$reportPath\04_DnsChecks.txt" -Append
    } catch {
        "DNS SRV resolution FAILED: $_" | Out-File "$reportPath\04_DnsChecks.txt" -Append
    }
}

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List all trusts with key attributes | `Get-ADTrust -Filter * \| Select Name, Direction, TrustType, ForestTransitive, SIDFilteringQuarantined, SelectiveAuthentication` |
| Verify trust secure channel | `netdom trust <ThisDomain> /Domain:<TrustedDomain> /verify` |
| Reset trust password | `netdom trust <ThisDomain> /Domain:<TrustedDomain> /ResetPWD /UserD:<Admin> /PasswordD:* /UserO:<OtherAdmin> /PasswordO:*` |
| Convert to bidirectional | `netdom trust <ThisDomain> /Domain:<TrustedDomain> /twoway /UserD:<Admin> /PasswordD:* /UserO:<OtherAdmin> /PasswordO:*` |
| Disable SID filtering (time-boxed) | `netdom trust <ThisDomain> /Domain:<TrustedDomain> /quarantine:No /UserD:<Admin> /PasswordD:*` |
| Re-enable SID filtering | `netdom trust <ThisDomain> /Domain:<TrustedDomain> /quarantine:Yes /UserD:<Admin> /PasswordD:*` |
| List trusted domains (client-side view) | `nltest /trusted_domains` |
| Locate a DC in the trusted domain | `nltest /dsgetdc:<TrustedDomain>` |
| Reset local computer secure channel | `Test-ComputerSecureChannel -Repair` |
| Check current Kerberos tickets | `klist tickets` |
| Add DNS conditional forwarder | `Add-DnsServerConditionalForwarderZone -Name "<TrustedDomain>" -MasterServers <IP1>,<IP2>` |
| Check selective authentication flag | `(Get-ADTrust -Identity "<TrustedDomain>").SelectiveAuthentication` |

---
## 🎓 Learning Pointers

- **A trust establishes the possibility of cross-domain authentication — it does not grant access.** Every access decision still goes through normal resource ACLs in the target domain. Treating "the trust is healthy" as equivalent to "access should work" is the most common misdiagnosis in this space. [Trust technologies overview](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-domain-and-forest-trusts)
- **SID filtering exists because SID history is forgeable, not because Microsoft distrusts your migration.** It's a real security boundary protecting against SID-history injection from a less-trusted domain — disabling it should always be a scoped, time-boxed, documented decision tied to an active migration, never a permanent workaround. [SID filtering background](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2003/cc835085(v=ws.10))
- **Selective authentication flips the default from allow-and-restrict-by-ACL to deny-by-default-until-explicitly-granted.** If a forest trust suddenly has selective auth turned on for a new security initiative, expect a wave of "access denied" tickets for previously-working integrations until each one gets its "Allowed to Authenticate" ACE.
- **A trust can genuinely be healthy on one side and broken on the other.** The TDO password lives independently on each side; always verify from both domains before concluding the trust itself is fine.
- **Domain trusts and forest trusts are not the same security boundary.** A forest trust extends transitively to every domain in the partner forest; an external trust is scoped to exactly the two named domains. Confirm which one you actually have before reasoning about blast radius.
- **Cross-forest constrained delegation needs more than a healthy trust.** Classic constrained delegation (S4U2Proxy) is domain-scoped; reaching across a forest boundary requires resource-based constrained delegation (RBCD) configured on the target side, not just an existing forest trust. [Kerberos constrained delegation across forests](https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-constrained-delegation-overview)
