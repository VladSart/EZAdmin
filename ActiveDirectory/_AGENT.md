# Active Directory (On-Prem AD DS) — Agent Instructions

## What's in this folder

On-premises Active Directory Domain Services — the identity foundation that DFS, Entra Connect/hybrid join, Kerberos auth, and Group Policy all sit on top of. This module covers the **directory replication layer** (NTDS.dit multi-master replication, FSMO roles, replication topology), **domain/forest trust relationships** (secure channel health, SID filtering, selective authentication), **backup/restore** (System State backup validity, authoritative vs. non-authoritative restore, USN rollback, DSRM, AD Recycle Bin), **Group Policy processing & replication** (client-side GPO processing pipeline, GPC/GPT version agreement, security/WMI filtering, loopback processing), **AD-integrated DNS** (zone replication scope, DC Locator SRV records, scavenging/aging, forwarders/root hints, split-brain detection), **AD FS / Web Application Proxy** (on-prem claims-based federation for M365/SaaS — token-signing/decrypting certificate lifecycle, relying party trusts, claims rules, WAP proxy trust), **Group Managed Service Accounts (gMSA)** (KDS root key/GKDS deterministic password derivation, the two-step AD-delegation-vs-local-installation authorization model, forest-scoping limits), and **Fine-Grained Password Policies** (Password Settings Objects/PSOs, precedence resolution, direct-vs-group targeting, the domain-wide GPO policy as fallback) — not the SYSVOL DFSR replication engine itself (see `DFS/`), not client-side DNS resolver config (see `Windows/`), and not cloud/hybrid sync or Entra Connect PHS/PTA (see `EntraID/`).

---

## Before responding, also check

- `DFS/` — if the symptom is a SYSVOL/DFSR replication backlog itself (not GPO processing behavior), that's a separate replication system layered on top of AD — `Troubleshooting/GroupPolicy/` here covers the GPO-processing side of that same dependency
- `Intune/` — if the org has migrated or is migrating settings off Group Policy onto CSP/Intune configuration profiles (see `Intune/Troubleshooting/GP-to-CSP-B.md`)
- `EntraID/` — if the symptom involves Entra Connect, hybrid join, cloud-side identity, or the org uses Password Hash Sync/Pass-through Auth instead of federation; on-prem AD health is a prerequisite dependency for all of it
- `Windows/` — if the issue is Kerberos/NTLM auth failures on a client (not between DCs), DNS client-side resolver config, or time sync at the endpoint level (this folder's DNS coverage is the AD-integrated *server* side — zones, SRV records, scavenging)
- `Security/ConditionalAccess/` — if access is being blocked by policy rather than by a broken identity/replication chain; this includes the case where AD FS issued a valid token but Entra ID's Conditional Access still blocks the resulting sign-in

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Troubleshooting/Replication/AD-Replication-B.md` | Hotfix: replication failures, error code lookup, common fix paths (network/DNS/time/topology/lingering objects) |
| `Troubleshooting/Replication/AD-Replication-A.md` | Deep dive: multi-master replication model, FSMO roles, USN/topology internals, FSMO seizure and lingering-object remediation playbooks |
| `Scripts/Get-ADReplicationHealth.ps1` | One-shot health check: replication summary, FSMO reachability, time sync offsets, tombstone/lingering-object risk, key DCDiag tests |
| `Troubleshooting/Trusts/AD-Trusts-B.md` | Hotfix: trust secure channel failures, SID filtering/selective auth denial patterns, common fix paths |
| `Troubleshooting/Trusts/AD-Trusts-A.md` | Deep dive: trust types, Kerberos referral path, SID filtering/selective auth internals, trust-password-reset and migration playbooks |
| `Scripts/Get-ADTrustHealth.ps1` | One-shot trust health check: attribute summary, secure channel verify, DNS SRV resolution, port reachability to trusted-domain DCs |
| `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` | Hotfix: USN rollback triage, DSRM password reset, authoritative restore of deleted objects, stale-backup decision gate |
| `Troubleshooting/BackupRestore/AD-BackupRestore-A.md` | Deep dive: System State backup internals, authoritative vs. non-authoritative restore, USN rollback mechanics, DSRM, AD Recycle Bin, demote/rebuild and scoped-restore playbooks |
| `Scripts/Get-ADBackupRestoreHealth.ps1` | One-shot backup/restore posture check: backup age vs. tombstone lifetime, NTDS VSS writer state, USN rollback/lingering-object event scan, replication isolation flags, Recycle Bin status |
| `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md` | Hotfix: Event 1058/1030/1096 triage, security/WMI filter denial, GPC/SYSVOL version mismatch, slow-link/loopback quirks |
| `Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md` | Deep dive: GPC/GPT two-part architecture, client-side processing pipeline internals, precedence model, DFSR-backlog and corrupt-GPO remediation playbooks |
| `Scripts/Get-GroupPolicyHealth.ps1` | One-shot GPO health check: gpresult summary, GP Operational log critical events, DFS client state, DC locator, time sync, optional GPC/GPT version comparison and DFSR backlog check |
| `Troubleshooting/DNS/AD-DNS-B.md` | Hotfix: missing/stale SRV records (DC Locator broken), over-aggressive scavenging, forwarder/root-hint failures, split-brain DNS, replication scope mismatch |
| `Troubleshooting/DNS/AD-DNS-A.md` | Deep dive: `_msdcs` zone architecture, dynamic update/registration lifecycle, replication scope internals, scavenging mechanics, rebuild/scavenging-recovery/cross-domain-scope playbooks |
| `Scripts/Get-ADDNSHealth.ps1` | One-shot DNS health check: zone inventory/scope, dynamic update mode, DC Locator SRV presence per DC, netlogon.dns comparison, scavenging config coherence, external resolution test |
| `Troubleshooting/ADFS/ADFS-B.md` | Hotfix: farm-wide vs. extranet-only outage triage, certificate expiry/mismatch checks, relying party trust and WAP proxy trust fix paths |
| `Troubleshooting/ADFS/ADFS-A.md` | Deep dive: token-signing/decrypting cert lifecycle and rollover mechanics, relying party trust and claims rule architecture, WAP proxy trust internals, farm topology/behavior level playbooks |
| `Scripts/Get-ADFSHealth.ps1` | One-shot farm health check: certificate expiry/rollover state, relying party trust inventory, farm topology, recent AD FS/Admin log errors, optional WAP proxy trust event scan |
| `Troubleshooting/gMSA/gMSA-B.md` | Hotfix: KDS root key convergence triage, authorization-vs-installation two-step diagnosis, service credential format fixes, forest-boundary dead ends |
| `Troubleshooting/gMSA/gMSA-A.md` | Deep dive: KDS root key/GKDS password derivation architecture, two-step authorization model, rotation mechanics, forest-scoping limits, cluster-node and static-to-gMSA migration playbooks |
| `Scripts/Get-GMSAHealth.ps1` | One-shot gMSA health check: KDS root key convergence, per-gMSA delegation resolution (direct + group), password interval, optional local Test-ADServiceAccount + GMSA event log scan via `-TestLocal` |
| `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` | Hotfix: resultant-policy lookup, invalid OU-targeting triage, precedence-collision and direct-link-override fixes, PSO delegation gaps |
| `Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md` | Deep dive: PSO/Password Settings Container architecture, precedence and direct-vs-group resolution rules, domain-wide GPO fallback, delegation model, new-tier and OU-to-group migration playbooks |
| `Scripts/Get-FGPPAudit.ps1` | One-shot PSO audit: invalid target-type detection (OU/wrong-scope-group), precedence-collision detection across all PSOs, optional per-user resultant-policy + direct-link check via `-UserName` |

---

## Common entry points

- "Replication is failing between DCs" / "repadmin shows errors" → `Troubleshooting/Replication/AD-Replication-B.md`
- "A DC seems to be missing changes / objects out of sync" → `Troubleshooting/Replication/AD-Replication-B.md`
- "FSMO role holder is down, need to seize a role" → `Troubleshooting/Replication/AD-Replication-A.md` (Playbook 1)
- "Deleted objects are reappearing after a DC came back online" → `Troubleshooting/Replication/AD-Replication-A.md` (Playbook 3, lingering objects)
- "Redesigned AD Sites/Subnets, replication looks wrong now" → `Troubleshooting/Replication/AD-Replication-A.md` (Playbook 2)
- "Need a quick health snapshot before/after a change" → `Scripts/Get-ADReplicationHealth.ps1`
- "GPOs aren't applying / files not syncing" → this is SYSVOL, go to `DFS/Troubleshooting/Replication/`
- "Trust relationship failed" / "netdom trust /verify fails" → `Troubleshooting/Trusts/AD-Trusts-B.md`
- "Trust looks healthy but users still get access denied cross-domain" → `Troubleshooting/Trusts/AD-Trusts-B.md` (SID filtering / selective auth, Fix 3/Fix 4)
- "Access broke for migrated users after a domain migration" → `Troubleshooting/Trusts/AD-Trusts-A.md` (SID filtering / Playbook 2)
- "Setting up a new cross-forest trust with selective authentication" → `Troubleshooting/Trusts/AD-Trusts-A.md` (Playbook 3)
- "Quick trust health snapshot" → `Scripts/Get-ADTrustHealth.ps1`
- "Event ID 2095 / USN rollback detected" → `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` (Fix 1 — urgent, isolate the DC)
- "Accidentally deleted an OU/users/group memberships, need them back" → `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` (check Recycle Bin first, Fix 2)
- "DSRM password unknown, need to boot into Directory Services Restore Mode" → `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` (Fix 3)
- "Is this backup even still restorable?" / backup age vs. tombstone lifetime → `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` (Fix 4) or `Scripts/Get-ADBackupRestoreHealth.ps1`
- "Difference between authoritative and non-authoritative restore" → `Troubleshooting/BackupRestore/AD-BackupRestore-A.md`
- "Quick backup/restore posture check" → `Scripts/Get-ADBackupRestoreHealth.ps1`
- "GPO isn't applying" / Event 1058, 1030, or 1096 → `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md`
- "gpresult shows AD / SYSVOL Version Mismatch" → `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md` (Fix 6) — check `DFS/Troubleshooting/Replication/` if DFSR itself is backlogged
- "GPO applies to some machines in an OU but not others" → `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md` (Fix 3/Fix 4, security/WMI filtering)
- "How does GPO precedence/inheritance actually resolve?" / "why did the wrong setting win?" → `Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md`
- "Loopback processing giving inconsistent results on shared machines" → `Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md` (Playbook 3)
- "Quick GPO health snapshot" → `Scripts/Get-GroupPolicyHealth.ps1`
- "Replication errors mention DNS lookup failure / error 8524" → `Troubleshooting/DNS/AD-DNS-B.md`
- "A DC's SRV records disappeared, DC Locator seems broken" → `Troubleshooting/DNS/AD-DNS-B.md` (Fix 1) or `Troubleshooting/DNS/AD-DNS-A.md` (Playbook 2 if scavenging is the cause)
- "Internal AD works but Outlook/Teams/websites are broken tenant-wide" → `Troubleshooting/DNS/AD-DNS-B.md` (Fix 3 — forwarders/root hints, not AD itself)
- "Some users get random DNS failures with no clear pattern" → `Troubleshooting/DNS/AD-DNS-B.md` (Fix 4 — split-brain DNS)
- "Cross-domain DC Locator fails in a multi-domain forest" → `Troubleshooting/DNS/AD-DNS-A.md` (Playbook 3 — `_msdcs` replication scope)
- "Quick AD DNS health snapshot" → `Scripts/Get-ADDNSHealth.ps1`
- "Everyone can't sign into M365/federated apps at once" → `Troubleshooting/ADFS/ADFS-B.md` (Fix 1 — check token-signing/decrypting cert expiry first)
- "Only external/remote users can't sign in, internal is fine" → `Troubleshooting/ADFS/ADFS-B.md` (Fix 5 — WAP proxy trust)
- "AD FS says signed in but Entra ID says user not found" → `Troubleshooting/ADFS/ADFS-A.md` (Playbook 2 — immutableid claims rule mismatch)
- "One specific app's SSO broke, everything else including M365 works" → `Troubleshooting/ADFS/ADFS-B.md` (Fix 3 — relying party trust)
- "AD FS certificate keeps expiring and breaking things repeatedly" → `Troubleshooting/ADFS/ADFS-B.md` (Fix 4 — enable AutoCertificateRollover)
- "Quick AD FS farm health snapshot" → `Scripts/Get-ADFSHealth.ps1`
- "A service/scheduled task using a gMSA won't start / logon failure" → `Troubleshooting/gMSA/gMSA-B.md`
- "Test-ADServiceAccount returns False" → `Troubleshooting/gMSA/gMSA-B.md` (Fix 2/Fix 3 — authorization vs. local installation)
- "gMSA worked fine for weeks, suddenly fails everywhere on the same day" → `Troubleshooting/gMSA/gMSA-B.md` (rotation-boundary correlation) or `Troubleshooting/gMSA/gMSA-A.md` (Phase 5)
- "Setting up gMSA for the first time in this forest" → `Troubleshooting/gMSA/gMSA-A.md` (Playbook 1)
- "Migrating a service off a static-password account onto a gMSA" → `Troubleshooting/gMSA/gMSA-A.md` (Playbook 2)
- "New cluster node can't run the clustered gMSA-based service" → `Troubleshooting/gMSA/gMSA-A.md` (Playbook 3)
- "Quick gMSA health snapshot" → `Scripts/Get-GMSAHealth.ps1`
- "User has the wrong password policy / wrong complexity or lockout settings" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md`
- "I linked a PSO to an OU and nothing happened" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` (Fix 1 — PSOs can't target OUs)
- "Two password policies seem to conflict / wrong one is winning" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` (Fix 3/Fix 4 — precedence and direct-link resolution)
- "Need to stand up a stricter password policy for admin/service accounts only" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md` (Playbook 1)
- "Non-Domain-Admin can't manage PSOs despite OU delegation" → `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` (Fix 5)
- "Quick PSO / FGPP audit across the domain" → `Scripts/Get-FGPPAudit.ps1`

---

## Key diagnostic commands

```powershell
repadmin /replsummary                        # domain-wide replication health, always start here
repadmin /showrepl <DC> /verbose /all         # exact error code for a failing partnership
netdom query fsmo                             # FSMO role holder identity
dcdiag /v /c /d /e                            # full DC health sweep
w32tm /query /status                          # time sync — Kerberos hard-fails past 5 min skew
```

---

## Key dependency chain

```
Network/DNS reachability between DCs
  └── Netlogon (SRV record registration, DC location)
        └── Firewall ports open (389/636/3268-3269/88/53/135 + dynamic RPC)
              └── W32Time (within 5 min of PDC Emulator — Kerberos hard limit)
                    └── Kerberos auth between DC pair
                          └── KCC/manual topology (connection objects, site links)
                                └── USN exchange → object/attribute replication
                                      └── (separate system) SYSVOL replicates via DFSR
```

**Trust dependency chain** (separate from intra-domain replication above — see `Troubleshooting/Trusts/`):

```
DNS resolution between the two domains (conditional forwarder/delegation)
  └── Network reachability (88/389/636/445/135+dynamic RPC) to a trusted-domain DC
        └── Trusted Domain Object (TDO) password in sync on both sides
              └── Netlogon secure channel (netdom trust /verify)
                    └── Kerberos referral chain across the trust
                          └── SID filtering (quarantine) + selective authentication evaluated
                                └── Normal resource ACL evaluation in the target domain
```

**Backup/restore dependency chain** (separate again — see `Troubleshooting/BackupRestore/`):

```
VSS-aware System State backup (not raw disk/VM snapshot of a live DC)
  └── Backup age within tombstone lifetime (default 180 days — hard usability ceiling)
        └── DSRM local admin password known/resettable
              └── (authoritative restore only) DC booted into DSRM
                    └── ntdsutil restore executed (authoritative or non-authoritative)
                          └── (authoritative only) version numbers incremented on restored objects
                                └── Normal replication propagates the restored state outward
```

**Group Policy processing chain** (see `Troubleshooting/GroupPolicy/`):

```
Network stack up (NLA) + DC Locator resolves a reachable, correctly-sited DC
  └── Kerberos auth succeeds (time sync dependency, same as above)
        └── SYSVOL (GPT) reachable via SMB + AD (GPC) enumerable via LDAP
              └── GPC (AD) version and GPT (SYSVOL/DFSR) version agree
                    └── Security filtering + WMI filtering pass
                          └── Loopback mode (if configured) resolves as expected
                                └── Client-Side Extensions apply settings
                                      └── Precedence resolves the final winning value
```

**AD-integrated DNS chain** (see `Troubleshooting/DNS/`):

```
DNS Server role running on enough DCs
  └── AD-integrated zone(s) present (domain zone + _msdcs.<forest-root>)
        └── Replication scope correct (Forest for _msdcs, Domain/Forest for domain zone)
              └── Dynamic Update = Secure only
                    └── Netlogon registers SRV + host records (netlogon.dns lists expected set)
                          └── Scavenging tuned wide enough not to remove live records
                                └── AD replication carries zone data to every DNS-hosting DC
                                      └── DC Locator (_ldap/_kerberos/_gc SRV) resolves correctly
                                            └── (separate path) Forwarders/root hints resolve external names
```

**AD FS federation chain** (see `Troubleshooting/ADFS/`):

```
Active Directory reachable (service account/gMSA authentication)
  └── AD FS Configuration Database (WID/SQL) shared across all farm nodes
        └── Token-Signing / Token-Decrypting certificates live + service account has private-key read access
              └── Relying Party Trust object (e.g. Microsoft Office 365 Identity Platform) — enabled, correct claims rules
                    └── Claims issued (immutableid must match Entra Connect's sourceAnchor/ImmutableId)
                          └── (extranet only) Web Application Proxy — separate rolling proxy trust certificate
                                └── Relying party (Entra ID) validates signature + claims → issues its own token
                                      └── (post-token) Conditional Access evaluated — see `Security/ConditionalAccess/`
```

**gMSA dependency chain** (see `Troubleshooting/gMSA/`):

```
Forest has >=1 Windows Server 2012+ DC able to serve KDS root key material
  └── KDS Root Key created (Add-KdsRootKey) AND past its EffectiveTime (default 10h delay)
        └── AD replication has carried the root key to every DC requesting hosts contact
              └── gMSA object exists with PrincipalsAllowedToRetrieveManagedPassword delegation
                    └── Target host authorized directly or via group (group membership replicated)
                          └── Install-ADServiceAccount run locally on that host
                                └── Service/task/app pool logs on as DOMAIN\gMSA$ with a BLANK password
                                      └── msDS-ManagedPasswordInterval rotation (default 30 days), no manual sync
```

**FGPP / PSO precedence chain** (see `Troubleshooting/FineGrainedPasswordPolicies/`):

```
Domain functional level >= Windows Server 2012
  └── Password Settings Container exists (hidden from default ADUC view)
        └── PSO created with Name + Precedence, msDS-PSOAppliesTo targets USERS/GLOBAL SECURITY
            GROUPS ONLY (never an OU — the #1 real-world misconfiguration)
              └── Direct-linked PSOs beat group-linked PSOs; among group-linked, lowest
                  msDS-PasswordSettingsPrecedence wins
                    └── msDS-ResultantPSO on the user object reflects the actual winner
                          └── If nothing applies: silent fallback to the domain-wide GPO-based
                              Default Domain Policy password settings
```

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — triage commands → fix → validation proof
2. **Deep Dive** — dependency chain, FSMO/topology architecture, community findings
3. **Learning Pointers** — what to go study after this is resolved
