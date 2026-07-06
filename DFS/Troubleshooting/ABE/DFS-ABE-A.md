# DFS Access-Based Enumeration (ABE) — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Access-Based Enumeration on DFS Namespaces (domain-based and standalone) and on the underlying SMB shares of folder targets
- Windows Server 2012 R2 and later
- Interaction between ABE, NTFS permissions, and DFSR-replicated folder targets

**Out of scope:**
- Folder/file-level auditing (that's Purview/Advanced Auditing, not ABE)
- Share permissions vs. NTFS permissions conceptual overview (assumed known)
- Non-Windows SMB implementations (Samba ABE behaves differently)

**Assumes:**
- Domain admin or delegated rights over the namespace and folder target servers
- RSAT DFS Management Tools installed
- Familiarity with `Get-Acl`/`icacls` and basic AD group nesting

---

## How It Works

<details><summary>Full architecture — how ABE decides what a user sees</summary>

### Two independent settings, one visible behavior

ABE is implemented at **two separate layers** that must both be configured for it to work end-to-end:

1. **DFS Namespace root property** (`EnableAccessBasedEnumeration` on the `Dfsn` root object). For domain-based namespaces this is stored in AD (under the namespace's configuration object) and replicates to every namespace server automatically via normal AD replication. For standalone namespaces it is local to the single namespace server with no replication involved.

2. **SMB Share property** (`FolderEnumerationMode` on the underlying share). This is a Server Service (`LanmanServer`) property that lives on the physical file server hosting each folder target — **per share, per server**. It is completely independent of the namespace-level flag and does not inherit from it, replicate via AD, or replicate via DFSR.

The namespace root setting only controls whether the **namespace referral/root view** enumerates based on access. Whether the **actual folder targets** (the real UNC paths behind each namespace folder) enumerate based on access is controlled entirely by the SMB share flag on each target server. A namespace with ABE "enabled" but folder target shares still in `AllFolders` mode will show all folders in the root view but not filter further down.

### Evaluation flow at enumeration time

```
Client requests directory listing (Explorer, dir, Get-ChildItem)
        │
        ▼
SMB server checks FolderEnumerationMode on the share
        │
    ┌───┴────┐
 AllFolders  AccessBased
    │            │
    │            ▼
    │      For each child folder, server computes the
    │      REQUESTING USER'S effective NTFS access token
    │      against that folder's ACL
    │            │
    │       ┌────┴─────┐
    │    No access   Any access
    │  (not even List) (List/Read/etc.)
    │       │            │
    │       ▼            ▼
    │   Folder omitted  Folder shown
    │   from listing
    ▼
All folders shown regardless of access
```

**Critical nuance:** ABE evaluates the user's *effective* access — including nested group membership, inherited ACEs, and deny rules — not just a direct ACE on the folder. A folder is hidden only when the computed effective access is truly zero. Even "List Folder Contents" alone is enough to make it visible.

### Interaction with DFS Namespace referrals

When a namespace folder has multiple folder targets (for redundancy or DFSR-based distribution), the client's referral resolves to **one specific target server** based on site costing and referral ordering. ABE is evaluated by whichever target server the client actually lands on — so if ABE (the SMB share flag) is configured differently across targets, users get inconsistent behavior purely based on which target their referral resolved to, with the namespace layer being completely blind to the discrepancy.

### DFSR and ABE settings

DFSR replicates **file and folder content**, and NTFS ACLs travel with files as metadata. But the SMB share object's `FolderEnumerationMode` is not filesystem content — it's a Server Service configuration property — so it is **never** replicated by DFSR. Every folder target server needs the share flag set independently, even when all targets are part of the same DFSR replication group serving identical content.

</details>

---

## Dependency Stack

```
┌───────────────────────────────────────────┐
│  User / Explorer directory listing         │  ← What the user actually sees
├───────────────────────────────────────────┤
│  DFS Namespace referral resolution         │  ← Picks which folder target server to query
├───────────────────────────────────────────┤
│  Namespace root: EnableAccessBasedEnumeration │  ← AD-replicated (domain-based) or local (standalone)
├───────────────────────────────────────────┤
│  SMB Share: FolderEnumerationMode          │  ← Per-server, per-share — NOT inherited, NOT replicated
├───────────────────────────────────────────┤
│  NTFS effective permissions on the folder  │  ← What ABE actually evaluates per user
├───────────────────────────────────────────┤
│  AD group membership (incl. nested groups) │  ← Feeds the user's effective access token
├───────────────────────────────────────────┤
│  Client-side cache (Explorer + DFS referral)│ ← Can mask a correct config change temporarily
└───────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| ABE "enabled" but users still see everything | Namespace flag set, but share-level `FolderEnumerationMode` still `AllFolders` | `Get-SmbShare` on each folder target server |
| Works on one target server, not another | Share flag configured on one target but not others (not replicated) | Compare `FolderEnumerationMode` across all `Get-DfsnFolderTarget` results |
| Folder visible that should be hidden | User (or a group they belong to) has an inherited ACE granting some access | `Get-Acl` filtered for broad principals (Everyone, Authenticated Users, Domain Users) |
| Folder hidden that should be visible | No effective NTFS access — direct or via nested group | Walk `MemberOf` recursively, cross-reference against the ACL |
| Config change made but nothing visibly changes | Client-side Explorer cache or DFS referral cache stale | `dfsutil /pktinfo`, `dfsutil /pktflush`, reopen Explorer |
| ABE flag reverts after a GPO refresh or namespace re-provision | A configuration management script or GPO is resetting the namespace/share property on a schedule | Check scheduled tasks/GPOs that touch `Set-DfsnRoot`/`Set-SmbShare` |
| Domain-based namespace ABE setting not appearing on a newly added namespace server | AD replication lag for the namespace configuration object | `repadmin /showrepl`, allow time or force sync |
| Standalone namespace ABE setting "disappears" after failover | Standalone namespaces have no built-in HA — the setting is local to a single server, not replicated at all | Confirm namespace type with `Get-DfsnRoot`; consider migrating to domain-based |

---

## Validation Steps

**1. Confirm namespace-level ABE flag**
```powershell
Get-DfsnRoot -Path "\\<domain>\<namespace>" |
  Select-Object Path, Type, EnableAccessBasedEnumeration
```
Expected: `Type : DomainV2` (or `Standalone`), `EnableAccessBasedEnumeration : True`. If `Type` is `Standalone`, remember this setting has no HA/replication.

**2. Enumerate every folder target and confirm the SMB share flag on each**
```powershell
$folders = Get-DfsnFolder -Path "\\<domain>\<namespace>\*"
foreach ($f in $folders) {
    $targets = Get-DfsnFolderTarget -Path $f.Path
    foreach ($t in $targets) {
        $parts = $t.TargetPath.TrimStart('\') -split '\\'
        Invoke-Command -ComputerName $parts[0] -ScriptBlock {
            param($share) Get-SmbShare -Name $share | Select-Object Name, FolderEnumerationMode
        } -ArgumentList $parts[1] |
          Select-Object @{N='Server';E={$parts[0]}}, Name, FolderEnumerationMode
    }
}
```
Expected: `FolderEnumerationMode : AccessBased` on every target for every folder. Any `AllFolders` result is a gap.

**3. Confirm NTFS ACLs match intended visibility**
```powershell
$path = "<localPathToFolder>"
(Get-Acl $path).Access |
  Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited |
  Format-Table -AutoSize
```
Expected: Only intended principals have any access; broad inherited grants (Everyone, Authenticated Users, Domain Users) are absent unless deliberate.

**4. Walk effective access for a specific test user**
```powershell
Get-ADUser <username> -Properties MemberOf |
  Select-Object -ExpandProperty MemberOf
# Cross-reference each group against the folder ACL, including nested membership:
Get-ADGroup <groupName> -Properties MemberOf | Select-Object -ExpandProperty MemberOf
```
Expected: Every group in the user's full transitive membership chain is accounted for when reasoning about what they should see.

**5. Confirm AD replication of the namespace config object (domain-based only)**
```powershell
repadmin /showrepl * /csv | Import-Csv | Where-Object {$_."Number of Failures" -gt 0}
```
Expected: No failures. A namespace server missing the ABE flag despite `Set-DfsnRoot` having been run elsewhere usually means replication hasn't caught up.

**6. Flush and confirm client-side view**
```powershell
dfsutil /pktinfo
dfsutil /pktflush
```
Expected: After flush, a fresh Explorer session reflects current server-side state.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm the two-layer configuration is actually complete
1. Run Validation Step 1 (namespace flag) and Step 2 (every target's share flag)
2. If either layer is missing, this is root cause — nothing downstream matters until both are set
3. Do not assume "I set it on the namespace" means the shares are covered — they are never linked automatically

### Phase 2 — If both layers are set, isolate to permissions
1. Run Validation Step 3 (ACL) and Step 4 (effective access)
2. Look specifically for broad inherited ACEs (Everyone/Authenticated Users/Domain Users) higher up the folder tree — these are the most common cause of "ABE isn't hiding this folder"
3. Confirm the test user's full nested group chain, not just direct membership

### Phase 3 — If configuration and permissions both look correct, isolate to caching/propagation
1. Check AD replication status for the namespace config object (domain-based namespaces only) — Validation Step 5
2. Flush DFS referral cache and Explorer cache — Validation Step 6
3. Confirm the client actually resolved to the target server you just changed (`dfsutil /pktinfo` shows the active referral)

### Phase 4 — If behavior is inconsistent across users or targets
1. Compare `FolderEnumerationMode` across **every** folder target server for the affected folder — this is the most common source of "works for some people, not others" when those people happen to be routed (via AD site costing) to different targets
2. Confirm NTFS ACLs are identical across DFSR-replicated targets — while file content and ACL metadata replicate via DFSR, a manual local ACL change on one target's physical path can drift from its partners

---

## Remediation Playbooks

<details><summary>Playbook 1 — Bring a namespace fully into ABE compliance (namespace + every target)</summary>

Use when: ABE needs to be enabled correctly across an entire namespace, not just spot-fixed on one folder.

```powershell
$namespace = "\\<domain>\<namespace>"

# Step 1: Enable at the namespace root
Set-DfsnRoot -Path $namespace -EnableAccessBasedEnumeration $true

# Step 2: Enumerate every folder and every target, enable at the share layer
$folders = Get-DfsnFolder -Path "$namespace\*"
foreach ($f in $folders) {
    $targets = Get-DfsnFolderTarget -Path $f.Path
    foreach ($t in $targets) {
        $parts = $t.TargetPath.TrimStart('\') -split '\\'
        Invoke-Command -ComputerName $parts[0] -ScriptBlock {
            param($share)
            Set-SmbShare -Name $share -FolderEnumerationMode AccessBased -Force
        } -ArgumentList $parts[1]
    }
}

# Step 3: Force AD replication if domain-based, then verify
repadmin /syncall /AdeP
Get-DfsnRoot -Path $namespace | Select-Object Path, EnableAccessBasedEnumeration
```

**Rollback:** Re-run with `-EnableAccessBasedEnumeration $false` at the namespace root and `-FolderEnumerationMode AllFolders` on each share.

</details>

<details><summary>Playbook 2 — Audit and remediate broad inherited ACEs blocking ABE from hiding folders</summary>

Use when: ABE is correctly configured at both layers but folders that should be hidden are still visible.

```powershell
$rootPath = "<localPathToNamespaceRoot>"

# Find every folder with a broad principal granted any access, inherited or not
Get-ChildItem $rootPath -Recurse -Directory | ForEach-Object {
    $acl = Get-Acl $_.FullName
    $broad = $acl.Access | Where-Object {
        $_.IdentityReference -match "Everyone|Authenticated Users|Domain Users|BUILTIN\\Users"
    }
    if ($broad) {
        [PSCustomObject]@{
            Path       = $_.FullName
            Principal  = ($broad.IdentityReference -join ", ")
            Rights     = ($broad.FileSystemRights -join ", ")
            Inherited  = ($broad.IsInherited -join ", ")
        }
    }
} | Export-Csv "C:\Temp\ABE-BroadACE-Audit.csv" -NoTypeInformation
```

Review the CSV before removing anything — a broad grant may be intentional at a higher, genuinely-public folder. Remove only the ACEs that are unintentionally cascading down into folders meant to be restricted, and prefer explicitly breaking inheritance on the restricted subfolder over globally rewriting the parent ACL.

**Rollback:** Re-add the removed ACE from a documented backup of the original ACL (`Get-Acl` output saved before the change).

</details>

<details><summary>Playbook 3 — Reconcile ABE configuration drift across DFSR-replicated folder targets</summary>

Use when: The same namespace folder shows different visibility behavior depending on which target server the client's referral resolves to.

```powershell
$namespaceFolder = "\\<domain>\<namespace>\<folder>"
$targets = Get-DfsnFolderTarget -Path $namespaceFolder

$report = foreach ($t in $targets) {
    $parts = $t.TargetPath.TrimStart('\') -split '\\'
    $shareInfo = Invoke-Command -ComputerName $parts[0] -ScriptBlock {
        param($share) Get-SmbShare -Name $share | Select-Object FolderEnumerationMode
    } -ArgumentList $parts[1]
    [PSCustomObject]@{
        Server = $parts[0]
        Share  = $parts[1]
        Mode   = $shareInfo.FolderEnumerationMode
    }
}
$report | Format-Table -AutoSize

# Remediate any target not matching the rest
$report | Where-Object { $_.Mode -ne 'AccessBased' } | ForEach-Object {
    Invoke-Command -ComputerName $_.Server -ScriptBlock {
        param($share) Set-SmbShare -Name $share -FolderEnumerationMode AccessBased -Force
    } -ArgumentList $_.Share
}
```

**Rollback:** Set the remediated targets back to `AllFolders` if the change needs to be reverted.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect a full ABE evidence bundle for a namespace folder across all targets
#>
param(
    [Parameter(Mandatory)] [string]$NamespacePath,
    [Parameter(Mandatory)] [string]$FolderName,
    [string]$OutputPath = "C:\Temp\ABE-Evidence"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$folderPath = "$NamespacePath\$FolderName"

# Namespace root state
Get-DfsnRoot -Path $NamespacePath |
    Select-Object Path, Type, EnableAccessBasedEnumeration |
    Export-Csv "$OutputPath\namespace-root-$ts.csv" -NoTypeInformation

# Per-target share state
$targets = Get-DfsnFolderTarget -Path $folderPath
$targetReport = foreach ($t in $targets) {
    $parts = $t.TargetPath.TrimStart('\') -split '\\'
    $mode = Invoke-Command -ComputerName $parts[0] -ScriptBlock {
        param($share) (Get-SmbShare -Name $share).FolderEnumerationMode
    } -ArgumentList $parts[1] -ErrorAction SilentlyContinue
    [PSCustomObject]@{ Server=$parts[0]; Share=$parts[1]; TargetPath=$t.TargetPath; FolderEnumerationMode=$mode; State=$t.State }
}
$targetReport | Export-Csv "$OutputPath\target-states-$ts.csv" -NoTypeInformation

# DFS referral cache
dfsutil /pktinfo | Out-File "$OutputPath\referral-cache-$ts.txt"

Write-Host "Evidence collected to: $OutputPath"
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath-$ts.zip" -Force
Write-Host "Zipped: $OutputPath-$ts.zip"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check namespace-level ABE flag | `Get-DfsnRoot -Path <ns> \| Select EnableAccessBasedEnumeration` |
| Set namespace-level ABE flag | `Set-DfsnRoot -Path <ns> -EnableAccessBasedEnumeration $true` |
| Check share-level ABE flag | `Get-SmbShare -Name <share> \| Select FolderEnumerationMode` |
| Set share-level ABE flag | `Set-SmbShare -Name <share> -FolderEnumerationMode AccessBased -Force` |
| List every folder target for a folder | `Get-DfsnFolderTarget -Path <ns>\<folder>` |
| List all folders under a namespace | `Get-DfsnFolder -Path <ns>\*` |
| Check effective NTFS ACL | `(Get-Acl <path>).Access` |
| Check group membership (incl. nesting) | `Get-ADUser <user> -Properties MemberOf` |
| Flush client DFS referral cache | `dfsutil /pktflush` |
| View client DFS referral cache | `dfsutil /pktinfo` |
| Force AD replication (domain-based namespaces) | `repadmin /syncall /AdeP` |

---

## 🎓 Learning Pointers

- **ABE is two independently-configured layers, and only one of them is even discoverable from the namespace admin console.** The namespace root flag is easy to find and easy to assume is "the setting" — the per-server share flag is invisible unless you specifically go looking at `Get-SmbShare` on each target. Build a habit of always checking both. [MS Docs: Access-based enumeration overview](https://learn.microsoft.com/en-us/windows-server/storage/file-server/access-based-enumeration-overview)
- **Nothing about ABE configuration replicates via DFSR, even between targets serving identical replicated content.** DFSR replicates files and NTFS ACL metadata, but `FolderEnumerationMode` is a Server Service property on the share object — nothing in the DFSR pipeline touches it. Any script or process that provisions a new folder target must explicitly set this flag as its own step.
- **ABE evaluates effective access, which includes nested group membership — eyeballing a direct ACL entry is not enough to predict what a user will see.** When troubleshooting an unexpected visibility result, always walk the user's full transitive `MemberOf` chain rather than trusting a flat ACL read.
- **Standalone namespaces have zero built-in redundancy for this (or any) setting.** If a standalone namespace server is rebuilt or failed over to a new box, the ABE flag is not there automatically — it must be reconfigured. This is one of several reasons domain-based namespaces are preferred for anything beyond a single-server, non-critical share.
- **Client-side caching is the most common false negative in ABE troubleshooting.** A server-side fix that is 100% correct can appear "not working" for several minutes because Explorer and the DFS referral cache are both showing stale state — always flush and reopen before concluding a fix failed. See also `DFS-ABE-B.md` for the fast triage path.
