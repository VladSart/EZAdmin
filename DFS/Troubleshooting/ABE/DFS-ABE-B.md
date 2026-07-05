# DFS Access-Based Enumeration (ABE) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

```powershell
# 1. Is ABE enabled on the namespace root itself?
Get-DfsnRoot -Path "\\<domain>\<namespace>" | Select-Object Path, EnableAccessBasedEnumeration

# 2. Is ABE enabled on the underlying SMB share on each folder target server?
# This is a SEPARATE setting from the namespace root — the #1 cause of "ABE doesn't work"
Invoke-Command -ComputerName <targetServer> -ScriptBlock {
    Get-SmbShare | Where-Object { $_.Special -eq $false } |
      Select-Object Name, FolderEnumerationMode
}

# 3. Confirm the folder target list for the namespace folder in question
Get-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>" | Select-Object TargetPath, State

# 4. Check effective NTFS permission for the affected user on the physical path
# (ABE hides based on NTFS access — it does not grant or restrict access itself)
icacls "<localOrUNCPath>"

# 5. Clear the client's cached referral/enumeration view before re-testing
dfsutil /pktflush
```

**Interpret:**
- `EnableAccessBasedEnumeration = False` on the root → ABE was never turned on at the namespace level, see [Fix 1](#fix-1--abe-not-enabled-on-namespace-root)
- Root shows `True` but `FolderEnumerationMode` on the target share shows `AllFolders` → ABE is not applied at the share layer, see [Fix 2](#fix-2--abe-not-enabled-on-underlying-smb-share)
- Both enabled but user still sees folders they shouldn't → NTFS permission problem, not an ABE problem, see [Fix 3](#fix-3--folders-visible-that-should-be-hidden)
- User can't see a folder they should have access to → check group nesting / effective access, see [Fix 4](#fix-4--folders-hidden-that-should-be-visible)
- Works on one folder target server, not another → ABE must be set per-server, see [Fix 5](#fix-5--inconsistent-behaviour-across-folder-targets)

---

## Dependency Cascade

<details><summary>What must be true for ABE to behave correctly</summary>

```
[User browses \\domain\namespace\folder in Explorer]
        │
        ▼
[DFS Namespace referral resolves to a folder target UNC path]
        │
        ▼
[Namespace-level ABE flag: EnableAccessBasedEnumeration]
   ├─ Domain-based namespace → stored in AD, replicates to all namespace servers automatically
   └─ Standalone namespace → local to the single namespace server, no replication
        │
        ▼
[Underlying SMB share ABE flag: FolderEnumerationMode]
   ├─ Set PER SHARE on EACH folder target server independently
   └─ Does NOT inherit from the namespace root setting — must be set manually on every target
        │
        ▼
[NTFS permissions on the physical folder]
   ├─ ABE reads the user's EFFECTIVE NTFS access token
   └─ A folder with "no access" is hidden; a folder with ANY access (even just List) is shown
        │
        ▼
[Client-side cache]
   ├─ Explorer caches directory listings per session
   └─ DFS referral cache (dfsutil /pktinfo) can mask a config change until it expires or is flushed
```

**Key fact:** ABE is a *visibility* filter layered on top of NTFS, not an access control mechanism. If NTFS permissions are wrong, ABE will faithfully hide or show the wrong things — fixing ABE settings without fixing NTFS permissions underneath will not resolve a permissions complaint.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm ABE state at the namespace level**
```powershell
Get-DfsnRoot -Path "\\<domain>\<namespace>" |
  Select-Object Path, Type, EnableAccessBasedEnumeration
```
Expected: `EnableAccessBasedEnumeration : True`. If `False`, this is the root cause — nothing downstream matters until this is fixed.

**Step 2 — Confirm ABE state on every folder target's underlying share**
```powershell
$targets = Get-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>"
foreach ($t in $targets) {
    $uncParts = $t.TargetPath.TrimStart('\') -split '\\'
    $server = $uncParts[0]
    $shareName = $uncParts[1]
    Invoke-Command -ComputerName $server -ScriptBlock {
        Get-SmbShare -Name $using:shareName | Select-Object Name, FolderEnumerationMode
    }
}
```
Expected: `FolderEnumerationMode : AccessBased` on every target. `AllFolders` on any one target means users hitting that target see everything, regardless of the namespace setting.

**Step 3 — Verify NTFS permissions match intent**
```powershell
# Run on the file server hosting the folder target
$path = "<localPathToFolder>"
(Get-Acl $path).Access | Select-Object IdentityReference, FileSystemRights, AccessControlType | Format-Table -AutoSize
```
Expected: The affected user (directly or via group membership) has no ACE granting access if the folder should be hidden from them.

**Step 4 — Check effective access for the specific user**
```powershell
# Security tab → Advanced → Effective Access is the fastest GUI check
# PowerShell equivalent using the AccessChk-style approach: confirm group membership first
Get-ADUser <username> -Properties MemberOf |
  Select-Object -ExpandProperty MemberOf
```
Cross-reference the group list against the folder's ACL — nested/transitive group membership is the most common reason "effective" access doesn't match what's expected from a direct look at the ACL.

**Step 5 — Rule out client-side caching**
```powershell
dfsutil /pktinfo     # Shows cached referrals — confirm the client is pointed at the target you just changed
dfsutil /pktflush    # Clear cache and force re-query
```
Have the user close and reopen Explorer (or sign out/in) after flushing — Explorer itself caches folder listings independently of the DFS referral cache.

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — ABE not enabled on namespace root</summary>

```powershell
Set-DfsnRoot -Path "\\<domain>\<namespace>" -EnableAccessBasedEnumeration $true

# Confirm
Get-DfsnRoot -Path "\\<domain>\<namespace>" | Select-Object Path, EnableAccessBasedEnumeration
```

For domain-based namespaces this setting replicates to all namespace servers via AD — allow a few minutes for AD replication (`repadmin /syncall` to force it immediately).

**Rollback:** `Set-DfsnRoot -Path "\\<domain>\<namespace>" -EnableAccessBasedEnumeration $false`

</details>

<details id="fix-2"><summary>Fix 2 — ABE not enabled on underlying SMB share</summary>

This is the single most common reason "we enabled ABE and nothing changed."

```powershell
# Run against EACH folder target server individually — this does not propagate automatically
Invoke-Command -ComputerName <targetServer> -ScriptBlock {
    Set-SmbShare -Name "<shareName>" -FolderEnumerationMode AccessBased -Force
}

# Verify
Invoke-Command -ComputerName <targetServer> -ScriptBlock {
    Get-SmbShare -Name "<shareName>" | Select-Object Name, FolderEnumerationMode
}
```

No service restart required — takes effect on next directory enumeration.

**Rollback:** `Set-SmbShare -Name "<shareName>" -FolderEnumerationMode AllFolders -Force`

</details>

<details><summary>Fix 3 — Folders visible that should be hidden</summary>

**Root cause is almost always NTFS, not ABE.** ABE only hides a folder if the user has *zero* access — even a single "List Folder Contents" ACE (often inherited from a broad group like "Domain Users" or "Authenticated Users" on a parent folder) will make it visible.

```powershell
# Check for overly broad inherited permissions
$path = "<localPathToFolder>"
(Get-Acl $path).Access |
  Where-Object { $_.IdentityReference -match "Everyone|Authenticated Users|Domain Users" } |
  Select-Object IdentityReference, FileSystemRights, IsInherited
```

Remove or scope down the broad ACE, then re-test. Do not disable inheritance blindly — document the change and confirm no legitimate access depends on it first.

</details>

<details><summary>Fix 4 — Folders hidden that should be visible</summary>

```powershell
# Grant minimum required access — List Folder Contents is enough for ABE to show it,
# Read/Execute if the user also needs to open files inside
$path = "<localPathToFolder>"
$acl = Get-Acl $path
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "<domain>\<userOrGroup>", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl -Path $path -AclObject $acl
```

Then have the user flush their DFS referral cache (`dfsutil /pktflush`) and refresh Explorer — ABE visibility is evaluated at enumeration time but Explorer may show a stale cached listing.

</details>

<details><summary>Fix 5 — Inconsistent behaviour across folder targets</summary>

**Symptom:** ABE works correctly when a user's client resolves to Target Server A, but not Target Server B (same namespace folder, multiple targets for redundancy/DFSR).

```powershell
# ABE on the SMB share is per-server, not per-namespace-folder — check and align all targets
$targets = Get-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>"
foreach ($t in $targets) {
    $parts = $t.TargetPath.TrimStart('\') -split '\\'
    Invoke-Command -ComputerName $parts[0] -ScriptBlock {
        param($share)
        Set-SmbShare -Name $share -FolderEnumerationMode AccessBased -Force
    } -ArgumentList $parts[1]
}
```

Also confirm NTFS permissions are identical across targets — DFSR replicates file *content*, not share-level or NTFS ACL settings by default (NTFS permissions DO replicate as file metadata via DFSR, but SMB share settings like ABE do not — they live on the share object, not the filesystem).

</details>

---

## Escalation Evidence

```
DFS ABE Issue — Evidence Pack
====================================
Namespace path:                 
Affected folder:                
Affected user(s)/group(s):      
Expected behaviour:             [folder should be hidden / should be visible]
Actual behaviour:                
Namespace-root ABE flag:        [Get-DfsnRoot output]
Per-target-server ABE flag:     [Get-SmbShare FolderEnumerationMode per target]
NTFS ACL on physical path:      [icacls / Get-Acl output]
User's group memberships:       [Get-ADUser -Properties MemberOf]
Referral cache state:           [dfsutil /pktinfo]
Consistent across all targets:  [Yes/No — list which target(s) differ]
```

---

## 🎓 Learning Pointers

- **ABE is a visibility filter, not an access control mechanism.** It never grants or denies access — it only decides whether a folder *appears* in a directory listing, based on the viewer's existing NTFS permissions. Fixing an "I can still open the folder" complaint by tweaking ABE settings is treating the wrong layer. [MS Docs: Access-based enumeration overview](https://learn.microsoft.com/en-us/windows-server/storage/file-server/access-based-enumeration-overview)
- **The namespace-level flag and the share-level flag are two different settings that must both be correct.** `Set-DfsnRoot -EnableAccessBasedEnumeration` controls the namespace object; `Set-SmbShare -FolderEnumerationMode` controls the actual SMB share on each target server. Enabling one without the other is the #1 support call for "ABE isn't working."
- **ABE does not replicate via DFSR.** DFSR replicates file and folder content (and NTFS ACLs travel with the files as metadata), but the SMB share's enumeration mode is a share-object property, not filesystem content — it must be configured independently on every server hosting a folder target for that namespace folder.
- **Nested group membership is the most common cause of "effective access doesn't match what I see in the ACL."** A user inheriting access through three levels of nested security groups is easy to miss when eyeballing an ACL. Always check effective access (Advanced Security → Effective Access tab, or walk `MemberOf` recursively) rather than trusting a direct ACL read.
- **Client-side caching (both DFS referral cache and Explorer's own listing cache) can make a correct fix look like it hasn't taken effect.** Always flush with `dfsutil /pktflush` and have the user reopen Explorer before concluding a fix didn't work.
