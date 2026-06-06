# DFS — Agent Instructions

## What's in this folder

Distributed File System — both components:
- **DFSN (DFS Namespaces)** — the virtual path layer (`\\domain\share`) that abstracts physical UNC paths. Users see one path; the namespace redirects them to a folder target.
- **DFSR (DFS Replication)** — the multi-master replication engine that keeps folder targets in sync. Also used by AD to replicate SYSVOL.

This module covers setup, health validation, access failures, replication backlog, SYSVOL issues, and conflict resolution.

---

## Before responding, also check

- `EntraID/` — if access failures are identity-related (Kerberos, PRT, token)
- `Windows/` — if the issue is local firewall, DNS, or network stack
- `Intune/` — if DFS client configuration is being pushed via MDM policy

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Troubleshooting/Namespace/Namespace-B.md` | Hotfix: namespace referral failures, access errors |
| `Troubleshooting/Namespace/Namespace-A.md` | Deep dive: how DFSN works, dependency chain, all failure modes |
| `Troubleshooting/Replication/Replication-B.md` | Hotfix: replication backlog, stuck replication, SYSVOL |
| `Troubleshooting/Replication/Replication-A.md` | Deep dive: DFSR architecture, conflict types, health monitoring |
| `Scripts/Test-DFSHealth.ps1` | Full health check: namespace targets, replication backlog, event errors |
| `Scripts/Get-DFSRBacklog.ps1` | Backlog size per replication group/connection |

---

## Common entry points

- "DFS share not accessible" → `Namespace-B.md`
- "Users can't reach \\domain\share" → `Namespace-B.md`, check DNS + AD first
- "Files not replicating between sites" → `Replication-B.md`
- "SYSVOL not replicating / GPOs not applying" → `Replication-B.md`
- "DFS conflict files appearing" → `Replication-A.md`
- "Setting up DFS for the first time" → `Namespace-A.md` + `Replication-A.md`
- "Health check before/after migration" → `Scripts/Test-DFSHealth.ps1`

---

## Key dependencies (always check these first)

```
DNS resolution → AD replication → DFS service running → Namespace server reachable
      ↓                                                          ↓
Kerberos auth                                         RPC + firewall ports open
      ↓                                                          ↓
User permissions on target                           DFSR service on all members
```

**Firewall ports required:**
- TCP 135 (RPC endpoint mapper)
- TCP 5722 (DFSR RPC)
- TCP/UDP 137–139, 445 (SMB)
- TCP 49152–65535 (dynamic RPC — must be open between DFS members)

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — triage commands → fix → validation proof
2. **Deep Dive** — dependency chain, architecture, community findings
3. **Learning Pointers** — what to go study after this is resolved
