# DFS Namespace Migration — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers: moving clients off `\\server\share` paths onto a domain namespace, Windows 2000 mode → Windows Server 2008 mode, stand-alone → domain-based, and the breakage that follows a cutover.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run on a namespace server or an admin box with RSAT DFS Management Tools (`RSAT-DFS-Mgmt-Con`).

```powershell
# 1. What roots exist, and what mode are they in?
Get-DfsnRoot -Domain <contoso.com> | Select-Object Path, Type, State, Flags

# 2. Which servers actually host each root? (Dfsutil cannot import these - record them)
Get-DfsnRoot -Domain <contoso.com> | ForEach-Object { Get-DfsnRootTarget -Path $_.Path } |
    Select-Object Path, TargetPath, State, ReferralPriorityClass

# 3. Stand-alone roots on a specific server
Get-DfsnRoot -ComputerName <FS01> | Where-Object Type -eq 'Standalone'

# 4. From an affected client: what referral did it get?
dfsutil cache referral
Get-ChildItem \\<contoso.com>\<Files> -ErrorAction Stop | Select-Object -First 3

# 5. Domain functional level (2008 mode prerequisite)
(Get-ADDomain).DomainMode
```

| Result | Meaning | Go to |
|---|---|---|
| `Type = DomainV1` | Windows 2000 mode root — no ABE in namespace, scale limits | Fix 2 |
| `Type = Standalone` and users depend on it | Single point of failure, cannot convert in place | Fix 3 |
| Root target `State = Offline` after migration | Namespace server not re-added or share missing | Fix 4 |
| Client still hits old server after cutover | Stale drive map / GPO / referral cache | Fix 5 |
| `DomainMode` below `Windows2008Domain` | Cannot create DomainV2 roots yet | Raise DFL first (change control) |
| Folder redirection / home drives still on `\\server` | Path references not migrated | Fix 1, Fix 6 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Client resolves \\contoso.com\Files
└── DNS: contoso.com resolves to a reachable DC
    └── DC returns domain referral + root referral (DFS Namespace service running on DCs)
        └── AD: CN=<root>,CN=Dfs-Configuration,CN=System,DC=contoso,DC=com
            │   (DomainV2 = msDFS-Namespacev2 object; DomainV1 = fTDfs blob)
            └── Namespace server(s): DFS Namespace service running
                └── Root share exists on each namespace server (e.g. C:\DFSRoots\Files shared as "Files")
                    └── Folder link -> folder target \\FS01\Finance
                        └── SMB share + NTFS permissions on FS01
                            └── Client referral cache (root TTL default 300 s, folder 1800 s)
```
Stand-alone roots skip AD entirely — config lives on the one namespace server
(`HKLM\SOFTWARE\Microsoft\Dfs\Standalone`), so the root path is `\\FS01\Files`.
</details>

---
## Diagnosis & Validation Flow

1. **Export before you touch anything** (all migration types):
   ```powershell
   dfsutil root export \\<contoso.com>\<Files> C:\DFSBackup\<Files>-$(Get-Date -f yyyyMMdd).xml
   Get-DfsnRootTarget -Path \\<contoso.com>\<Files> | Export-Csv C:\DFSBackup\<Files>-rootTargets.csv -NoTypeInformation
   ```
   Expected: XML containing every `<Link>` and `<Target>`. If it fails with access denied → you lack namespace admin delegation.

2. **Count folders** — sizing tells you which mode you need:
   ```powershell
   (Get-DfsnFolder -Path '\\<contoso.com>\<Files>\*').Count
   ```
   Over ~5,000 folders in a DomainV1 root → AD object bloat and slow replication; must move to DomainV2.

3. **Confirm every folder target is reachable** before cutover:
   ```powershell
   Get-DfsnFolder -Path '\\<contoso.com>\<Files>\*' | ForEach-Object {
     Get-DfsnFolderTarget -Path $_.Path } | ForEach-Object {
     [pscustomobject]@{ Folder=$_.Path; Target=$_.TargetPath; Reachable=(Test-Path $_.TargetPath) } }
   ```
   `Reachable = False` → fix the back-end share first; the namespace will only hand out a dead referral.

4. **After cutover, validate from a client:**
   ```powershell
   dfsutil cache referral flush
   Get-ChildItem \\<contoso.com>\<Files>\<Finance> | Select-Object -First 3
   dfsutil cache referral   # should list \\contoso.com\Files and the active target marked ACTIVE
   ```

5. **Find leftover hard-coded server paths** (the real work in a UNC → namespace migration):
   ```powershell
   Get-ADUser -Filter "homeDirectory -like '*<FS01>*' -or profilePath -like '*<FS01>*'" -Properties homeDirectory, profilePath |
     Select-Object SamAccountName, homeDirectory, profilePath
   Get-GPOReport -All -ReportType Xml -Path C:\DFSBackup\AllGPOs.xml
   Select-String -Path C:\DFSBackup\AllGPOs.xml -Pattern '\\\\<FS01>\\' -AllMatches | Measure-Object
   ```
   Or run `DFS/Scripts/Get-DFSNamespaceMigrationReadiness.ps1 -LegacyServer <FS01>`.

---
## Common Fix Paths

<details><summary>Fix 1 — Move clients from \\server\share to a new domain namespace (no data move)</summary>

The namespace sits in front of the *existing* shares, so no data moves on day 1.

```powershell
# On the namespace server (often the file server itself + a second server for HA)
New-Item -Path C:\DFSRoots\Files -ItemType Directory -Force
New-SmbShare -Name Files -Path C:\DFSRoots\Files -ReadAccess 'Everyone'   # root share; real ACLs live on the targets

New-DfsnRoot -Path \\<contoso.com>\Files -TargetPath \\<NS01>\Files -Type DomainV2
New-DfsnRootTarget -Path \\<contoso.com>\Files -TargetPath \\<NS02>\Files     # second namespace server

# One folder per existing share - targets point at the current server
New-DfsnFolder -Path \\<contoso.com>\Files\Finance -TargetPath \\<FS01>\Finance
New-DfsnFolder -Path \\<contoso.com>\Files\HR      -TargetPath \\<FS01>\HR
```
Then switch clients:
- **GPP Drive Maps:** change the Location to `\\contoso.com\Files\Finance`, action **Replace** (Update does not change an existing mapping's path).
- **Home folders:** `Set-ADUser <user> -HomeDirectory \\<contoso.com>\Files\Home\<user>` (see Fix 6 for bulk).
- **Folder Redirection:** see Fix 6 — changing the path with "Move the contents" ticked triggers a full copy per user.

Rollback: re-point the drive map back to `\\FS01\...` — the old shares were never touched.
</details>

<details><summary>Fix 2 — Windows 2000 mode (DomainV1) → Windows Server 2008 mode (DomainV2)</summary>

There is no in-place upgrade. Export → delete → recreate → import. **Clients lose the namespace between delete and import** — schedule a window.

```powershell
$ns = '\\<contoso.com>\<Files>'
dfsutil root export $ns C:\DFSBackup\Files-v1.xml
$targets = Get-DfsnRootTarget -Path $ns | Select-Object -ExpandProperty TargetPath   # Dfsutil does NOT import namespace servers
$targets | Out-File C:\DFSBackup\Files-rootTargets.txt

# Delete the root. In DFS Management, if prompted, DO NOT delete the associated replication groups.
dfsutil root remove $ns

# Recreate same name in 2008 mode on the first namespace server
dfsutil root adddom \\<NS01>\<Files> v2
# Import the folder structure (run on a namespace server - much faster for large roots)
dfsutil root import merge C:\DFSBackup\Files-v1.xml $ns

# Re-add the other namespace servers you recorded
$targets | Where-Object { $_ -notlike '\\<NS01>\*' } | ForEach-Object { New-DfsnRootTarget -Path $ns -TargetPath $_ }
Get-DfsnRoot -Path $ns | Select-Object Path, Type    # Type should now be DomainV2
```
Prereqs: domain functional level Windows Server 2008+, all namespace servers Windows Server 2008+.
After import, re-check ABE (`Get-DfsnRoot $ns | Select Flags`), delegation (`Get-DfsnAccess`) and referral settings — re-apply anything that did not come across.

Rollback: `dfsutil root remove $ns`, recreate as v1 (`dfsutil root adddom \\NS01\Files v1`), `dfsutil root import set C:\DFSBackup\Files-v1.xml $ns`, re-add root targets.
</details>

<details><summary>Fix 3 — Stand-alone root → domain-based root</summary>

No conversion exists; a stand-alone root path is `\\server\name`, a domain root is `\\domain\name` — clients must change path anyway.

```powershell
dfsutil root export \\<FS01>\<Files> C:\DFSBackup\Files-standalone.xml

# Create the domain root under the same or a new name (Fix 1 steps for root share + New-DfsnRoot -Type DomainV2)
New-DfsnRoot -Path \\<contoso.com>\<Files> -TargetPath \\<NS01>\<Files> -Type DomainV2

# Dry-run the import, then apply
dfsutil root import compare C:\DFSBackup\Files-standalone.xml \\<contoso.com>\<Files>
dfsutil root import merge   C:\DFSBackup\Files-standalone.xml \\<contoso.com>\<Files>
```
Keep the stand-alone root online until all drive maps/GPOs are moved, then remove it: `Remove-DfsnRoot -Path \\FS01\Files`.
Note: a stand-alone root and a domain root with the same name cannot share the same root *share* on one server — use a different server or share name for the new root.
</details>

<details><summary>Fix 4 — Root target offline / namespace server missing after migration</summary>

```powershell
Get-DfsnRootTarget -Path \\<contoso.com>\<Files>
Invoke-Command -ComputerName <NS02> { Get-Service Dfs; Get-SmbShare -Name <Files> }
```
- Share missing → recreate it on the original path, then `New-DfsnRootTarget -Path \\contoso.com\Files -TargetPath \\NS02\Files`.
- Target present but offline → `Set-DfsnRootTarget -Path \\contoso.com\Files -TargetPath \\NS02\Files -State Online`.
- Service stopped → `Invoke-Command -ComputerName NS02 { Start-Service Dfs }`.
</details>

<details><summary>Fix 5 — Clients still using the old path / stale referral</summary>

```powershell
gpupdate /force
net use                                   # look for drives still mapped to \\FS01\...
net use <H:> /delete /y
dfsutil cache referral flush
dfsutil cache domain flush
klist purge                              # only if access denied after a target server change
```
If a GPP drive map was edited with action **Update**, existing mappings keep the old path — change to **Replace** or delete-then-create.
Offline Files (CSC) caches by UNC path; after a path change users can see an empty or stale copy. Sync first, then change path; reset the cache only as last resort (data loss risk for unsynced changes).
</details>

<details><summary>Fix 6 — Bulk-update home directories and profile paths</summary>

```powershell
# Preview
$old = '\\<FS01>\Home'; $new = '\\<contoso.com>\Files\Home'
$users = Get-ADUser -Filter "homeDirectory -like '$old*'" -Properties homeDirectory
$users | Select-Object SamAccountName, homeDirectory, @{n='New';e={$_.homeDirectory -replace [regex]::Escape($old), $new}} |
  Export-Csv C:\DFSBackup\homedir-preview.csv -NoTypeInformation

# Apply (after review) - keeps a CSV for rollback
$users | ForEach-Object { Set-ADUser $_ -HomeDirectory ($_.homeDirectory -replace [regex]::Escape($old), $new) }
```
Rollback: re-apply the `homeDirectory` column from the preview CSV.
Folder Redirection: when only the *path* changes (same data behind the namespace), untick **Move the contents of Documents to the new location** to avoid every user re-copying their data on next logon.
</details>

---
## Escalation Evidence
```
Namespace path:                 \\________\________
Root type before / after:       ________ / ________   (Standalone / DomainV1 / DomainV2)
Migration type:                 [ ] UNC->namespace  [ ] V1->V2  [ ] Standalone->Domain
Folder count:                   ______
Namespace servers (before):     ______________________
Namespace servers (after):      ______________________
dfsutil export file location:   ______________________
Domain functional level:        ______________________
Client error / symptom:         ______________________
Output of `dfsutil cache referral` on failing client: (attach)
Get-DfsnRoot / Get-DfsnRootTarget output: (attach)
Event log (DFS Namespace / DFSN-Server) errors: (attach)
Steps already tried:            ______________________
```

---
## 🎓 Learning Pointers
- **Dfsutil never imports namespace servers.** The XML holds folders and targets only — that's why Fix 2 makes you record root targets first. Procedure: [Migrate a domain-based namespace to Windows Server 2008 mode](https://learn.microsoft.com/en-us/windows-server/storage/dfs-namespaces/migrate-a-domain-based-namespace-to-windows-server-2008-mode).
- **Put the namespace in front of existing shares first, move data later.** Once clients use `\\domain\Files\Finance`, a future file-server replacement is just a folder-target swap with no client change.
- **`Get-DfsnRoot` `Type` is the fastest mode check** — `DomainV1`, `DomainV2`, `Standalone`. Cmdlet reference: [DFSN module](https://learn.microsoft.com/en-us/powershell/module/dfsn/).
- **GPP "Update" vs "Replace"** is the most common reason drive maps keep pointing at the old server after a cutover.
- If you must keep the old `\\FS01` name alive during a long tail of hard-coded paths, see `Windows/Troubleshooting/FileServerAlias-B.md` (alternate names, SPNs, `DisableStrictNameChecking`).
- Related: `DFS/Troubleshooting/Namespace/Namespace-B.md` for referral failures, `DFS/Troubleshooting/ABE/DFS-ABE-B.md` if folders show/hide wrongly after the move.
