# DFS Namespace Delegation & Management Permissions — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** who can create, modify and delete DFS Namespaces (domain-based V1/V2 and standalone) on Windows Server 2016–2025; where those permissions are stored; least-privilege delegation models for MSPs; auditing and cleaning namespace ACLs.
- **Out of scope:** end-user access to folder targets (share/NTFS — `Namespace-A.md`), Access-Based Enumeration folder ACLs (`ABE/DFS-ABE-A.md` — though the distinction is explained here), DFS Replication delegation (briefly noted), namespace migration (`NamespaceMigration/`).
- **Assumptions:** RSAT DFS Management Tools + ActiveDirectory module; rights to read `CN=System` in the domain partition (Authenticated Users have this by default).

---
## How It Works
<details><summary>Full architecture</summary>

### Three permission planes — keep them separate
```
                ┌───────────────────────────────────────────────┐
 PLANE 1        │ MANAGEMENT: who can change namespace config    │  ← this runbook
                │  store = AD object (domain) or registry (SA)   │
                ├───────────────────────────────────────────────┤
 PLANE 2        │ ENUMERATION: who SEES a namespace folder (ABE) │  ← Grant-DfsnAccess / dfsutil property sd
                │  store = SD on the DFS link (msDFS-Linkv2 /    │
                │  reparse point in root share)                  │
                ├───────────────────────────────────────────────┤
 PLANE 3        │ DATA: who can open files in the target share   │  ← share + NTFS on file servers
                └───────────────────────────────────────────────┘
```
Tickets go wrong when someone fixes plane 2 or 3 for a plane 1 problem (or vice versa). `Grant-DfsnAccess` sounds like delegation but only affects plane 2.

### Where plane 1 lives
| Namespace type | Configuration store | Management ACL |
|---|---|---|
| Domain V2 ("Windows Server 2008 mode") | One `msDFS-Namespacev2` object per namespace under `CN=Dfs-Configuration,CN=System,<domainDN>`, with child `msDFS-Linkv2` objects per folder | DACL on the `msDFS-Namespacev2` object (children inherit) |
| Domain V1 ("Windows 2000 mode") | Single `fTDfs` object per namespace holding the whole config as a blob (`pKT` attribute) | DACL on the `fTDfs` object |
| Standalone | Registry on the namespace server: `HKLM\SOFTWARE\Microsoft\Dfs\Standalone\<namespace>` | DACL on that registry key |

Namespace servers also need to **write** to their share/reparse-point folder locally, which is why some operations additionally require local Administrators on the server.

### What each tool actually changes
- **DFS Management → Delegate Management Permissions** on a namespace: adds a Full Control ACE for the chosen principal on the namespace object (or registry key).
- **Delegate Management Permissions on the *Namespaces* node**: adds rights on the `CN=Dfs-Configuration` container so the principal can create new namespace objects — and, through inheritance, can manage every existing namespace that hasn't blocked inheritance.
- **`Set-DfsnRoot -GrantAdminAccounts / -RevokeAdminAccounts`** (Server 2012+): scriptable equivalent of the per-namespace dialog.
- **`Grant-DfsnAccess` / `Revoke-DfsnAccess` / `Remove-DfsnAccess` / `Get-DfsnAccess`**: plane 2 — folder enumeration ACLs used when ABE is enabled on the namespace.

### Default holders (Microsoft Learn)
| Task | Default | Extra requirement when delegated |
|---|---|---|
| Create a domain-based namespace | Domain Admins | Local admin on the namespace server |
| Add a namespace server | Domain Admins | Local admin on the server being added |
| Manage a domain-based namespace | Local Administrators on each namespace server (plus Domain Admins via AD ACL) | — |
| Create a standalone namespace | Local Administrators on the server | — |
| Manage a standalone namespace | Local Administrators on the server | Delegation tab only readable by local admins |
| Create replication group / enable DFSR | Domain Admins | Separate delegation on the Replication node |

### How changes propagate
The DFS Management console and DFSN cmdlets bind to the **PDC emulator** by default for domain namespaces (unless root scalability mode or *Change Domain Controller* is used). Namespace servers poll for changes (PDC by default, closest DC in root-scalability mode) roughly hourly. A delegated admin's change can therefore be "saved" yet not seen by all namespace servers for a while — that is propagation, not a permissions failure.

### MSP delegation pattern
```
Tier 0 (Domain Admins) ── create namespaces, add namespace servers (rare, change-controlled)
Tier 1 group "DFS-NS-Admins-<Client>" ── Full Control on specific namespace objects only
                                        + local admin on namespace servers via GPO (only if they add/remove root targets)
Helpdesk ── no plane-1 rights; uses ABE/NTFS groups for access requests (plane 2/3)
```
Avoid delegating on `CN=Dfs-Configuration` unless the group really should own every namespace in the domain.
</details>

---
## Dependency Stack
```
[6] Change visible to clients (namespace servers polled the config store; client referral cache expired)
[5] Write succeeds against config store
      Domain: AD object ACL grants principal write  │  Standalone: registry key ACL on server
[4] Extra task rights: local admin on namespace server (add server / create namespace / SA delegation tab)
[3] Principal in user's Kerberos token (fresh logon after group change)
[2] Console/cmdlet reaches DC (PDC emulator by default) and namespace servers (RPC 135 + dynamic, SMB 445)
[1] Namespace type correctly identified (V1 / V2 / Standalone) → tells you which store to inspect
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Delegated user: "Access is denied" adding a folder | Group not on namespace object ACL / not in token | `Get-Acl "AD:\<nsDN>"`; `whoami /groups` |
| "Access is denied" adding a namespace server | Not local admin on the new server | `Get-LocalGroupMember Administrators` on server |
| Cannot create namespace (non-DA) | No create-child on `CN=Dfs-Configuration` | ACL on container |
| Delegation tab blank (standalone) | Expected for non-local-admins | Documented behaviour |
| Delegation tab shows unknown SIDs | Deleted accounts left ACEs | `IdentityReference` starts `S-1-5-21-` |
| Everyone in IT can edit namespace | Inherited rights from `CN=Dfs-Configuration` or `CN=System` | `IsInherited` = True on writer ACEs |
| "I granted Grant-DfsnAccess but they still can't edit" | Plane 2 tool used for plane 1 | Use `Set-DfsnRoot -GrantAdminAccounts` |
| Change saved, some users don't see new folder | Namespace server polling / client referral cache | `Get-DfsnRoot` TTL, `dfsutil cache referral flush` |
| Works against PDC, fails elsewhere | Console bound to a DC lacking replicated ACL | `repadmin /showobjmeta <DC> <nsDN>` |
| V1 namespace: any edit rewrites the whole blob, conflicts between admins | V1 single-object design | Migrate to V2 (`NamespaceMigration-A.md`) |

---
## Validation Steps
1. **Type** — `Get-DfsnRoot -Path \\<domain>\<ns> | Select Type` → `Domain V2` good; `Domain V1` works but legacy; `Standalone` → registry store.
2. **Object exists** — `Get-ADObject -SearchBase "CN=Dfs-Configuration,CN=System,<domainDN>" -Filter * | Select Name, ObjectClass` → your namespace with `msDFS-Namespacev2`.
3. **Writers** — `(Get-Acl "AD:\<nsDN>").Access | ? ActiveDirectoryRights -match 'GenericAll|Write|Child'` → only Tier-0 + intended groups. Bad: individuals, raw SIDs, `Domain Users`.
4. **Inheritance** — same output, `IsInherited` → understand which writers come from the container.
5. **Token** — on admin workstation `whoami /groups | findstr /i "<group>"` → present.
6. **Local admin** — `Invoke-Command <nsServer> { Get-LocalGroupMember Administrators }` → group present where server-level tasks are delegated.
7. **Plane 2 sanity** — `Get-DfsnAccess -Path \\<domain>\<ns>\<folder>` → only relevant when ABE is enabled; not related to management.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Classify.** Management action? (plane 1) Seeing folders? (plane 2) Opening files? (plane 3). Route 2/3 elsewhere.

**Phase 2 — Locate store.** From namespace type pick AD object or server registry.

**Phase 3 — Compare ACL to intent.** Is the delegated group there, with GenericAll (or at least write + create/delete child)? Any Deny ACEs?

**Phase 4 — Task extras.** Adding root targets or creating namespaces → local admin on the server(s).

**Phase 5 — Token & DC.** Fresh logon; ensure console's DC has the change.

**Phase 6 — Propagation.** If the write succeeded but users don't see it, it's namespace polling/referral cache, not delegation — see `Namespace-A.md`.

---
## Remediation Playbooks

<details><summary>Playbook A — Implement least-privilege per-namespace delegation</summary>

```powershell
$ns = '\\<domain>\<namespace>'
$group = '<DOMAIN>\DFS-NS-Admins-<Client>'
Set-DfsnRoot -Path $ns -GrantAdminAccounts $group
# Only if they will add/remove namespace servers:
Get-DfsnRootTarget -Path $ns | ForEach-Object {
    $server = ($_.TargetPath -split '\\')[2]
    Invoke-Command -ComputerName $server -ScriptBlock { param($g) Add-LocalGroupMember -Group Administrators -Member $g -ErrorAction SilentlyContinue } -ArgumentList $group
}
```
Rollback: `Set-DfsnRoot -Path $ns -RevokeAdminAccounts $group` and `Remove-LocalGroupMember`.
</details>

<details><summary>Playbook B — Remove inherited over-delegation from CN=Dfs-Configuration</summary>

1. Back up: `Get-Acl "AD:\CN=Dfs-Configuration,CN=System,<domainDN>" | Export-Clixml dfscfg-acl.xml`.
2. Identify non-Tier-0 write ACEs on the container (`IsInherited` False there).
3. Remove them (ADSI Edit or `RemoveAccessRule` + `Set-Acl`), then re-grant per namespace with Playbook A.
4. Re-run the audit script to confirm namespace objects now only list intended writers.
Rollback: `Set-Acl -Path "AD:\CN=Dfs-Configuration,CN=System,<domainDN>" -AclObject (Import-Clixml dfscfg-acl.xml)`.
</details>

<details><summary>Playbook C — Orphaned SID clean-up across all namespaces</summary>

Run `Get-DFSNamespaceDelegationAudit.ps1` → filter `Finding = OrphanedSid`, then per namespace back up and remove the explicit ACEs as in `DFSN-Delegation-B.md` Fix 6. Never remove inherited ACEs at the object — fix the parent.
</details>

<details><summary>Playbook D — Allow a site IT team to create their own namespaces (controlled)</summary>

Instead of delegating on `CN=Dfs-Configuration` (which inherits to all namespaces), have Tier 0 create the namespace object and immediately run Playbook A for the site group. If self-service creation is required, delegate create-child of `msDFS-Namespacev2` only (ADSI Edit → Advanced → *This object only* → Create msDFS-Namespacev2 objects) so existing namespaces don't inherit write. The creator becomes owner of the new object.
</details>

<details><summary>Playbook E — Standalone namespace delegation</summary>

`Set-DfsnRoot -Path \\<server>\<ns> -GrantAdminAccounts <group>`; confirm with `Get-Acl HKLM:\SOFTWARE\Microsoft\Dfs\Standalone\<ns>` on the server. Long-term: standalone namespaces have no AD-level audit trail and a single server — consider migrating to domain V2 (`NamespaceMigration-A.md`).
</details>

---
## Evidence Pack
Use `../../Scripts/Get-DFSNamespaceDelegationAudit.ps1 -Domain <domain>` (CSV of every namespace's writers, orphaned SIDs, broad groups, inheritance, and optional local-admin check). Minimal inline:

```powershell
Import-Module DFSN, ActiveDirectory
$domain = (Get-ADDomain)
$cfg = "CN=Dfs-Configuration,CN=System,$($domain.DistinguishedName)"
$out = foreach ($obj in Get-ADObject -SearchBase $cfg -SearchScope OneLevel -Filter "objectClass -eq 'msDFS-Namespacev2' -or objectClass -eq 'fTDfs'") {
    foreach ($ace in (Get-Acl "AD:\$($obj.DistinguishedName)").Access) {
        [pscustomobject]@{ Namespace=$obj.Name; Class=$obj.ObjectClass; Identity=$ace.IdentityReference; Rights=$ace.ActiveDirectoryRights; Type=$ace.AccessControlType; Inherited=$ace.IsInherited }
    }
}
$out | Export-Csv "$env:TEMP\dfsn-delegation-$(Get-Date -f yyyyMMdd).csv" -NoTypeInformation
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Namespace type | `Get-DfsnRoot -Path \\<domain>\<ns> \| Select Type` |
| List namespaces | `Get-DfsnRoot -Domain <domain>` |
| Grant management | `Set-DfsnRoot -Path <ns> -GrantAdminAccounts <group>` |
| Revoke management | `Set-DfsnRoot -Path <ns> -RevokeAdminAccounts <group>` |
| Namespace object ACL | `(Get-Acl "AD:\CN=<ns>,CN=Dfs-Configuration,CN=System,<domainDN>").Access` |
| Container ACL | `(Get-Acl "AD:\CN=Dfs-Configuration,CN=System,<domainDN>").Access` |
| Standalone ACL | `Invoke-Command <srv> { (Get-Acl HKLM:\SOFTWARE\Microsoft\Dfs\Standalone\<ns>).Access }` |
| Root targets | `Get-DfsnRootTarget -Path <ns>` |
| Local admins | `Invoke-Command <srv> { Get-LocalGroupMember Administrators }` |
| Add local admin | `Invoke-Command <srv> { Add-LocalGroupMember Administrators -Member <group> }` |
| Folder (ABE) ACL — plane 2 | `Get-DfsnAccess -Path <ns>\<folder>` |
| Token check | `whoami /groups` / `klist purge` |
| Object replication metadata | `repadmin /showobjmeta <DC> "<nsDN>"` |
| Flush client referral cache | `dfsutil cache referral flush` |

---
## 🎓 Learning Pointers
- [Delegate management permissions for DFS Namespaces](https://learn.microsoft.com/windows-server/storage/dfs-namespaces/delegate-management-permissions-for-dfs-namespaces) — the authoritative default-holder table, including the standalone Delegation-tab limitation.
- [Set-DfsnRoot](https://learn.microsoft.com/powershell/module/dfsn/set-dfsnroot) and [Grant-DfsnAccess](https://learn.microsoft.com/powershell/module/dfsn/grant-dfsnaccess) — read both pages side by side to see the plane 1 / plane 2 split.
- [Choose a namespace type](https://learn.microsoft.com/windows-server/storage/dfs-namespaces/choose-a-namespaces-type) — why V2 stores one object per folder (finer-grained ACLs, smaller replication) versus V1's single blob.
- Treat `CN=Dfs-Configuration` like any Tier-1 AD container in your delegation reviews; inheritance from it silently delegates every namespace. Related: `ActiveDirectory/` delegation and ACL audit content.
- Related: `Namespace-A.md` (referrals, polling), `ABE/DFS-ABE-A.md` (plane 2), `NamespaceMigration/NamespaceMigration-A.md` (V1 → V2, standalone → domain).
