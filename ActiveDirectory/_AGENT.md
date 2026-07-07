# Active Directory (On-Prem AD DS) — Agent Instructions

## What's in this folder

On-premises Active Directory Domain Services — the identity foundation that DFS, Entra Connect/hybrid join, Kerberos auth, and Group Policy all sit on top of. This module covers the **directory replication layer** (NTDS.dit multi-master replication, FSMO roles, replication topology) and **domain/forest trust relationships** (secure channel health, SID filtering, selective authentication) — not SYSVOL (see `DFS/`) and not cloud/hybrid sync (see `EntraID/`).

---

## Before responding, also check

- `DFS/` — if the symptom is "GPOs not applying" or "files not syncing between sites," that's SYSVOL/DFSR, a separate replication system layered on top of AD
- `EntraID/` — if the symptom involves Entra Connect, hybrid join, or cloud-side identity; on-prem AD health is a prerequisite dependency for all of it
- `Windows/` — if the issue is Kerberos/NTLM auth failures on a client (not between DCs), DNS client-side config, or time sync at the endpoint level
- `Security/ConditionalAccess/` — if access is being blocked by policy rather than by a broken identity/replication chain

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

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — triage commands → fix → validation proof
2. **Deep Dive** — dependency chain, FSMO/topology architecture, community findings
3. **Learning Pointers** — what to go study after this is resolved
