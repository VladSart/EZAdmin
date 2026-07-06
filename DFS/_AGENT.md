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
| `Troubleshooting/FRS-Migration/FRS-to-DFSR-Migration-B.md` | Hotfix: stuck/failed SYSVOL migration from legacy FRS to DFSR |
| `Troubleshooting/FRS-Migration/FRS-to-DFSR-Migration-A.md` | Deep dive: the 4-state migration model, AD dependency, irreversibility of Eliminated state |
| `Troubleshooting/ABE/DFS-ABE-B.md` | Hotfix: Access-Based Enumeration hiding/showing wrong folders |
| `Troubleshooting/ABE/DFS-ABE-A.md` | Deep dive: namespace-root vs. per-share ABE flags, DFSR non-replication of share settings |
| `Troubleshooting/SiteCosting/DFS-SiteCosting-B.md` | Hotfix: users routed to wrong/slow folder target — referral ordering & AD site-costing misconfiguration |
| `Troubleshooting/SiteCosting/DFS-SiteCosting-A.md` | Deep dive: referral ordering algorithm, AD site/subnet/site-link cost dependency chain, priority overrides |
| `Scripts/Test-DFSHealth.ps1` | Full health check: namespace targets, replication backlog, event errors |
| `Scripts/Get-DFSRBacklog.ps1` | Backlog size per replication group/connection |
| `Scripts/Get-DFSRMigrationState.ps1` | Cross-references dfsrmig state against live DC inventory, flags orphaned DCs and unshared SYSVOL |

---

## Common entry points

- "DFS share not accessible" → `Namespace-B.md`
- "Users can't reach \\domain\share" → `Namespace-B.md`, check DNS + AD first
- "Files not replicating between sites" → `Replication-B.md`
- "SYSVOL not replicating / GPOs not applying" → `Replication-B.md`
- "DFS conflict files appearing" → `Replication-A.md`
- "Setting up DFS for the first time" → `Namespace-A.md` + `Replication-A.md`
- "Migrating SYSVOL off FRS / dfsrmig stuck" → `FRS-Migration/FRS-to-DFSR-Migration-B.md`
- "Planning a FRS-to-DFSR SYSVOL migration project" → `FRS-Migration/FRS-to-DFSR-Migration-A.md`
- "Health check before/after migration" → `Scripts/Test-DFSHealth.ps1`, `Scripts/Get-DFSRMigrationState.ps1`
- "Users see folders they shouldn't (or can't see ones they should)" → `Troubleshooting/ABE/DFS-ABE-B.md`
- "Branch users are being routed to a slow/remote file server instead of their local one" → `Troubleshooting/SiteCosting/DFS-SiteCosting-B.md`
- "DFS referral order looks random / not respecting site topology" → `Troubleshooting/SiteCosting/DFS-SiteCosting-A.md`

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
