# DFS Namespace Migration — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** three migrations MSPs actually run — (1) server-UNC paths (`\\FS01\Finance`) → domain-based namespace (`\\contoso.com\Files\Finance`); (2) domain-based Windows 2000 mode (`DomainV1`) → Windows Server 2008 mode (`DomainV2`); (3) stand-alone root → domain-based root. Plus the client-side path inventory (drive maps, home folders, profiles, Folder Redirection, Offline Files) that decides whether a cutover is quiet or loud.
- **Out of scope:** DFS Replication design (see `DFS/Troubleshooting/Replication/`), SYSVOL FRS→DFSR (see `FRS-Migration/`), cross-forest namespace migration, Azure File Sync cloud tiering.
- Assumes Windows Server 2016+ namespace servers, RSAT DFS Management Tools, AD PowerShell, and namespace-admin rights (Domain Admins or delegated via `Grant-DfsnAccess`).

---
## How It Works
<details><summary>Full architecture</summary>

### Three root types
| | Stand-alone | Domain-based, Windows 2000 mode | Domain-based, Windows Server 2008 mode |
|---|---|---|---|
| `Get-DfsnRoot` `Type` | `Standalone` | `DomainV1` | `DomainV2` |
| Path | `\\FS01\Files` | `\\contoso.com\Files` | `\\contoso.com\Files` |
| Config store | Registry on the one server (`HKLM\SOFTWARE\Microsoft\Dfs\Standalone`) | Single AD object (`fTDfs`) holding a blob of the whole namespace | AD container `msDFS-Namespacev2` with one child object per folder |
| HA | Only via failover cluster | Multiple namespace servers | Multiple namespace servers |
| ABE on namespace | Yes (2008+ server) | **No** | Yes |
| Scale | Large (local registry) | Recommended ≤ ~5,000 folders — the whole blob replicates on every change | Tens of thousands of folders; per-folder AD objects |
| Prereqs | Any | Any | Domain functional level 2008+, namespace servers 2008+ |

Why DomainV1 hurts: every folder add/change rewrites the single `fTDfs` blob in `CN=Dfs-Configuration,CN=System`, which AD then replicates whole. Large V1 namespaces cause AD replication churn and slow namespace-server polling.

### Referral flow (why a migration is a client-path problem, not a data problem)
```
Client opens \\contoso.com\Files\Finance\Q3.xlsx
  1. Domain referral    -> DC (DFS service on DCs) returns list of DCs for contoso.com
  2. Root referral      -> DC returns namespace servers for "Files", ordered by site cost
  3. Link referral      -> namespace server returns folder targets for "Finance" (\\FS01\Finance)
  4. SMB to \\FS01\Finance -> Kerberos ticket for cifs/FS01 -> NTFS/share ACL
  Referrals cached: root TTL default 300 s, folder TTL default 1800 s
```
The namespace is an *indirection layer*. Nothing in steps 1–3 touches file data, so introducing a namespace in front of existing shares is non-disruptive — the disruption comes entirely from changing every place the old `\\FS01` path is written down.

### Where server paths hide (the real inventory)
| Location | How it stores the path | Cutover behaviour |
|---|---|---|
| GPP Drive Maps | GPO XML `Drives.xml` | Action **Update** keeps an existing mapping's old path; use **Replace** |
| Logon scripts | `net use` in .bat/.vbs/.ps1 in SYSVOL / NETLOGON | Edit and test |
| AD `homeDirectory` / `homeDrive` | User attribute | Bulk `Set-ADUser`; applies at next logon |
| AD `profilePath` (roaming) | User attribute | Changing it without moving data = new empty profile |
| Folder Redirection | GPO `fdeploy1.ini` / per-user registry | Path change + "Move the contents" = full per-user copy |
| Offline Files (CSC) | Cache keyed by UNC path | New path = new cache namespace; unsynced edits under old path at risk |
| FSLogix `VHDLocations` | Registry / Intune / GPO | Change in policy; open containers locked until logoff |
| Shortcuts, Office MRU, linked spreadsheets, app configs | Per user / per document | Long tail — the reason to keep the old name alive (alias) for a while |
| Scheduled tasks, backup jobs, SQL `BACKUP TO DISK` paths | Server-side configs | Inventory per server |

### Mode migration mechanics (V1 → V2, stand-alone → domain)
There is no conversion API. `dfsutil root export` serialises the namespace (folders, targets, target priority, referral TTLs, timeouts) to XML; `dfsutil root import` replays it into an *existing* root in one of three modes:
- `set` — make the destination match the file exactly (removes extra folders),
- `merge` — add/update from the file, keep extras,
- `compare` — report differences only (use as a dry run).

Root targets (namespace servers) are **not** imported. Delegation (`Get-DfsnAccess`) and namespace-level flags should be re-verified after import.
</details>

---
## Dependency Stack
```
[7] Client path references (drive maps, AD attributes, FR, scripts, shortcuts)
[6] Client referral cache / DFS client (Mup.sys, Dfsc.sys)
[5] Folder targets: SMB shares + NTFS ACLs on back-end servers
[4] Namespace servers: DFS Namespace service + root share (C:\DFSRoots\<root>)
[3] Namespace config: AD (DomainV1 fTDfs / DomainV2 msDFS-Namespacev2) or local registry (Standalone)
[2] DCs: DFS Namespace service answering domain/root referrals; AD sites & subnets for ordering
[1] AD DS + DNS: domain name resolution, domain functional level (V2 needs 2008+)
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| `\\contoso.com\Files` "network path not found" right after V1→V2 | In the window between `root remove` and `adddom`/import, or AD replication of new root not yet reached client's DC | `repadmin /syncall`; `Get-DfsnRoot` from client-site DC |
| Folders missing after import | Imported with wrong mode, or export taken from a stale namespace server | `dfsutil root import compare` vs XML |
| Namespace only served by one server after migration | Root targets not re-added (dfsutil doesn't import them) | `Get-DfsnRootTarget` |
| ABE stopped working post-migration | Flag not re-applied on new root | `Get-DfsnRoot -Path ... | Select Flags` |
| Users' H: drive still `\\FS01\Home` | AD `homeDirectory` not updated, or GPP drive map action Update | `Get-ADUser -Properties homeDirectory` |
| Users report empty Documents after path change | Folder Redirection path change without content move / Offline Files new cache | FR event log (`Folder Redirection` channel), `Get-WmiObject Win32_OfflineFilesCache` |
| Access denied via namespace, works via `\\FS01` | Root share/ACL on namespace server, or Kerberos to target by different name | `Get-SmbShareAccess` on root share; `klist` |
| Users routed to remote-site target | Missing AD subnet / priority classes | `DFS/Troubleshooting/SiteCosting/` |
| Cannot create `DomainV2` root | Domain functional level < 2008 | `(Get-ADDomain).DomainMode` |
| `New-DfsnRoot` fails "share does not exist" | Root share not created on namespace server first | `Get-SmbShare -CimSession NS01` |

---
## Validation Steps
1. **Root inventory**
   ```powershell
   Get-DfsnRoot -Domain <contoso.com> | Select-Object Path, Type, State
   ```
   Good: every production root `DomainV2`, `Online`. Bad: `DomainV1` (plan Playbook 2) or `Standalone` serving many users (Playbook 3).
2. **Namespace server redundancy**
   ```powershell
   Get-DfsnRootTarget -Path \\<contoso.com>\<Files> | Select-Object TargetPath, State
   ```
   Good: ≥ 2 targets, `Online`, in different failure domains. Bad: one target = namespace SPOF.
3. **Folder targets reachable**
   ```powershell
   Get-DfsnFolder -Path '\\<contoso.com>\<Files>\*' | ForEach-Object { Get-DfsnFolderTarget -Path $_.Path } |
     Where-Object { -not (Test-Path $_.TargetPath) }
   ```
   Good: no output. Bad: any row = dead referral users will hit.
4. **Export integrity**
   ```powershell
   dfsutil root export \\<contoso.com>\<Files> C:\DFSBackup\Files.xml
   ([xml](Get-Content C:\DFSBackup\Files.xml)).SelectNodes('//Link').Count
   ```
   Good: count equals `(Get-DfsnFolder -Path '\\contoso.com\Files\*').Count`.
5. **Client after cutover**
   ```powershell
   dfsutil cache referral flush; Test-Path \\<contoso.com>\<Files>\<Finance>; dfsutil cache referral
   ```
   Good: referral entry for the namespace with the expected target `ACTIVE`.
6. **Residual legacy paths**: `Get-DFSNamespaceMigrationReadiness.ps1 -LegacyServer FS01` → 0 GPO hits, 0 AD attribute hits.

---
## Troubleshooting Steps (by phase)
**Phase 0 — Discovery.** Inventory roots and types, folder counts, root targets, domain functional level, and every place the legacy server name appears (GPOs, AD attributes, logon scripts in `\\contoso.com\NETLOGON`, scheduled tasks). Decide the target design: root name(s), ≥2 namespace servers, folder layout that mirrors shares 1:1 for the first phase.

**Phase 1 — Build in parallel.** Create the root share and DomainV2 root, add root targets, add folders pointing at existing shares. Nothing changes for users yet. Validate from a pilot client.

**Phase 2 — Pilot cutover.** Move a pilot OU's drive maps (GPP Replace), home directories and FR policy. Watch for: Offline Files sync conflicts, FR copy storms, apps with hard-coded paths.

**Phase 3 — Bulk cutover.** Same changes for remaining OUs. Keep old shares untouched — rollback is just reverting the path.

**Phase 4 — Long tail.** Shortcuts, linked documents, line-of-business apps. Optionally keep the old name answering via an alternate computer name/CNAME (see `Windows/Troubleshooting/FileServerAlias-A.md`) until access logs show it is unused.

**Phase 5 — Back-end freedom.** Future server replacements: add new folder target (`New-DfsnFolderTarget`), replicate/copy data, set old target offline (`Set-DfsnFolderTarget -State Offline`), then remove it. No client changes.

For V1→V2 and stand-alone→domain migrations, Phase 1 includes the export, and the cutover is a scheduled outage window (V1→V2 keeps the same path, so no client changes; stand-alone→domain changes the path, so Phases 2–4 apply).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Server-UNC → domain namespace</summary>

```powershell
$domainNs = '\\<contoso.com>\Files'
foreach ($ns in '<NS01>','<NS02>') {
  Invoke-Command -ComputerName $ns {
    New-Item C:\DFSRoots\Files -ItemType Directory -Force | Out-Null
    if (-not (Get-SmbShare -Name Files -ErrorAction SilentlyContinue)) {
      New-SmbShare -Name Files -Path C:\DFSRoots\Files -ReadAccess 'Everyone' | Out-Null }
  }
}
New-DfsnRoot -Path $domainNs -TargetPath '\\<NS01>\Files' -Type DomainV2
New-DfsnRootTarget -Path $domainNs -TargetPath '\\<NS02>\Files'

# Mirror existing shares 1:1 (skip admin/hidden shares)
Get-SmbShare -CimSession <FS01> | Where-Object { -not $_.Special -and $_.Name -notmatch '\$$' } | ForEach-Object {
  New-DfsnFolder -Path "$domainNs\$($_.Name)" -TargetPath "\\<FS01>\$($_.Name)" }
Get-DfsnFolder -Path "$domainNs\*" | Select-Object Path
```
Then follow Phases 2–4. Rollback: revert client paths; `Remove-DfsnRoot -Path $domainNs` removes the indirection without touching data.
</details>

<details><summary>Playbook 2 — DomainV1 → DomainV2 (same path, outage window)</summary>

```powershell
$ns = '\\<contoso.com>\Files'; $bk = 'C:\DFSBackup'
New-Item $bk -ItemType Directory -Force | Out-Null
dfsutil root export $ns "$bk\Files-v1.xml"
Get-DfsnRootTarget -Path $ns | Export-Csv "$bk\Files-rootTargets.csv" -NoTypeInformation
Get-DfsnAccess -Path $ns -ErrorAction SilentlyContinue | Export-Csv "$bk\Files-access.csv" -NoTypeInformation
(Get-DfsnRoot -Path $ns).Flags | Out-File "$bk\Files-flags.txt"

# --- outage starts ---
dfsutil root remove $ns                       # keep replication groups if prompted in the GUI
dfsutil root adddom \\<NS01>\Files v2
dfsutil root import merge "$bk\Files-v1.xml" $ns     # run ON a namespace server for speed
Import-Csv "$bk\Files-rootTargets.csv" | Where-Object TargetPath -ne '\\<NS01>\Files' |
  ForEach-Object { New-DfsnRootTarget -Path $ns -TargetPath $_.TargetPath }
# --- outage ends once clients' DCs see the new root ---

dfsutil root import compare "$bk\Files-v1.xml" $ns   # expect no differences
Get-DfsnRoot -Path $ns | Select-Object Path, Type, Flags
```
Re-apply ABE (`Set-DfsnRoot -Path $ns -EnableAccessBasedEnumeration $true`) and delegation (`Grant-DfsnAccess`) from the CSV if they did not come across.
Rollback: `dfsutil root remove $ns`; `dfsutil root adddom \\NS01\Files v1`; `dfsutil root import set "$bk\Files-v1.xml" $ns`; re-add root targets.
</details>

<details><summary>Playbook 3 — Stand-alone → domain-based</summary>

```powershell
$old = '\\<FS01>\Files'; $new = '\\<contoso.com>\Files'
dfsutil root export $old C:\DFSBackup\Files-standalone.xml
# Build new root on a different server or share name (see Playbook 1 for root share)
New-DfsnRoot -Path $new -TargetPath '\\<NS01>\Files' -Type DomainV2
dfsutil root import compare C:\DFSBackup\Files-standalone.xml $new
dfsutil root import merge   C:\DFSBackup\Files-standalone.xml $new
New-DfsnRootTarget -Path $new -TargetPath '\\<NS02>\Files'
```
Clients change path (`\\FS01\Files` → `\\contoso.com\Files`), so Phases 2–4 apply. Keep the stand-alone root until the readiness script shows no remaining references, then `Remove-DfsnRoot -Path $old`.
Clustered stand-alone roots: the root lives on the cluster role's network name; export from that name, and remove the role's DFS resource only after cutover.
</details>

<details><summary>Playbook 4 — Bulk path rewrite in AD with rollback file</summary>

```powershell
param($Old = '\\<FS01>\Home', $New = '\\<contoso.com>\Files\Home', [switch]$Apply)
$rx = [regex]::Escape($Old)
$u = Get-ADUser -Filter * -Properties homeDirectory, profilePath |
     Where-Object { $_.homeDirectory -match $rx -or $_.profilePath -match $rx }
$u | Select-Object SamAccountName, homeDirectory, profilePath | Export-Csv C:\DFSBackup\paths-before.csv -NoTypeInformation
if ($Apply) {
  foreach ($x in $u) {
    $h = @{}
    if ($x.homeDirectory -match $rx) { $h.HomeDirectory = $x.homeDirectory -replace $rx, $New }
    if ($x.profilePath   -match $rx) { $h.ProfilePath   = $x.profilePath   -replace $rx, $New }
    Set-ADUser $x @h
  }
}
```
Roaming `profilePath` only changes safely if the namespace folder targets the *same* share — otherwise users get a new profile.
Rollback: replay `paths-before.csv` with `Set-ADUser`.
</details>

<details><summary>Playbook 5 — Replacing a back-end file server behind the namespace</summary>

```powershell
$f = '\\<contoso.com>\Files\Finance'
New-DfsnFolderTarget -Path $f -TargetPath '\\<FS02>\Finance' -State Offline   # add new target, not yet referred
# copy/replicate data (Robocopy /MIR /COPYALL /DCOPY:DAT or DFSR), then flip
Set-DfsnFolderTarget -Path $f -TargetPath '\\<FS02>\Finance' -State Online
Set-DfsnFolderTarget -Path $f -TargetPath '\\<FS01>\Finance' -State Offline
# after folder referral TTL (1800 s default) + validation:
Remove-DfsnFolderTarget -Path $f -TargetPath '\\<FS01>\Finance'
```
Rollback: swap the states back. Two online targets without replication = users editing different copies — never leave both online unless DFSR is healthy.
</details>

---
## Evidence Pack
```powershell
# Collect-DfsnMigrationEvidence.ps1 - read-only
param([string]$Namespace = '\\<contoso.com>\Files', [string]$Out = "$env:TEMP\DfsnEvidence")
New-Item $Out -ItemType Directory -Force | Out-Null
Get-DfsnRoot -Path $Namespace | Format-List * | Out-File "$Out\root.txt"
Get-DfsnRootTarget -Path $Namespace | Export-Csv "$Out\rootTargets.csv" -NoTypeInformation
Get-DfsnFolder -Path "$Namespace\*" | ForEach-Object { Get-DfsnFolderTarget -Path $_.Path } |
  Export-Csv "$Out\folderTargets.csv" -NoTypeInformation
dfsutil root export $Namespace "$Out\export.xml" 2>&1 | Out-File "$Out\export.log"
dfsutil cache referral | Out-File "$Out\clientReferralCache.txt"
(Get-ADDomain).DomainMode | Out-File "$Out\dfl.txt"
Get-WinEvent -LogName 'Microsoft-Windows-DFSN-Server/Admin' -MaxEvents 200 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$Out\dfsnEvents.csv" -NoTypeInformation
Compress-Archive -Path "$Out\*" -DestinationPath "$Out.zip" -Force
"Evidence: $Out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| List roots + type | `Get-DfsnRoot -Domain contoso.com \| Select Path,Type,State` |
| Namespace servers | `Get-DfsnRootTarget -Path \\contoso.com\Files` |
| Export | `dfsutil root export \\contoso.com\Files C:\bk\Files.xml` |
| Import dry run | `dfsutil root import compare C:\bk\Files.xml \\contoso.com\Files` |
| Import add/update | `dfsutil root import merge C:\bk\Files.xml \\contoso.com\Files` |
| Import exact | `dfsutil root import set C:\bk\Files.xml \\contoso.com\Files` |
| Remove root | `dfsutil root remove \\contoso.com\Files` / `Remove-DfsnRoot` |
| New 2008-mode root | `New-DfsnRoot -Path \\contoso.com\Files -TargetPath \\NS01\Files -Type DomainV2` |
| Add namespace server | `New-DfsnRootTarget -Path \\contoso.com\Files -TargetPath \\NS02\Files` |
| Add folder | `New-DfsnFolder -Path \\contoso.com\Files\HR -TargetPath \\FS01\HR` |
| Take target offline | `Set-DfsnFolderTarget -Path ... -TargetPath ... -State Offline` |
| Client cache | `dfsutil cache referral` / `dfsutil cache referral flush` |
| Enable ABE | `Set-DfsnRoot -Path \\contoso.com\Files -EnableAccessBasedEnumeration $true` |
| DFL | `(Get-ADDomain).DomainMode` |
| Readiness audit | `.\Get-DFSNamespaceMigrationReadiness.ps1 -Domain contoso.com -LegacyServer FS01` |

---
## 🎓 Learning Pointers
- The V1→V2 procedure is officially export/delete/recreate/import — no switch exists: [Migrate a domain-based namespace to Windows Server 2008 mode](https://learn.microsoft.com/en-us/windows-server/storage/dfs-namespaces/migrate-a-domain-based-namespace-to-windows-server-2008-mode).
- Choosing namespace type and its limits: [Choose a namespace type](https://learn.microsoft.com/en-us/windows-server/storage/dfs-namespaces/choose-a-namespace-type).
- `dfsutil root import compare` is your free dry run — always diff before `set`, which deletes folders not in the file.
- Think of the namespace as DNS for file shares: pay the client-path migration cost once, then every future file server move is a back-end change (Playbook 5).
- Community: the "Ask the Directory Services Team" archive on Microsoft Tech Community has the classic DFSN deep dives (referral ordering, V2 object model).
- Related here: `DFS/Troubleshooting/SiteCosting/DFS-SiteCosting-A.md` (referral ordering after adding namespace servers in new sites), `Windows/Troubleshooting/FileServerAlias-A.md` (keeping the old server name alive).
