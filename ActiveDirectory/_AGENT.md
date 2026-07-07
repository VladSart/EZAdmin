# Active Directory (On-Prem AD DS) — Agent Instructions

## What's in this folder

On-premises Active Directory Domain Services — the identity foundation that DFS, Entra Connect/hybrid join, Kerberos auth, and Group Policy all sit on top of. This module covers the **directory replication layer** (NTDS.dit multi-master replication, FSMO roles, replication topology) — not SYSVOL (see `DFS/`) and not cloud/hybrid sync (see `EntraID/`).

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

---

## Common entry points

- "Replication is failing between DCs" / "repadmin shows errors" → `Troubleshooting/Replication/AD-Replication-B.md`
- "A DC seems to be missing changes / objects out of sync" → `Troubleshooting/Replication/AD-Replication-B.md`
- "FSMO role holder is down, need to seize a role" → `Troubleshooting/Replication/AD-Replication-A.md` (Playbook 1)
- "Deleted objects are reappearing after a DC came back online" → `Troubleshooting/Replication/AD-Replication-A.md` (Playbook 3, lingering objects)
- "Redesigned AD Sites/Subnets, replication looks wrong now" → `Troubleshooting/Replication/AD-Replication-A.md` (Playbook 2)
- "Need a quick health snapshot before/after a change" → `Scripts/Get-ADReplicationHealth.ps1`
- "GPOs aren't applying / files not syncing" → this is SYSVOL, go to `DFS/Troubleshooting/Replication/`

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

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — triage commands → fix → validation proof
2. **Deep Dive** — dependency chain, FSMO/topology architecture, community findings
3. **Learning Pointers** — what to go study after this is resolved
