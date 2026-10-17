# DFS Namespace Delegation & Management Permissions — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. For "a delegated admin (helpdesk, site IT, app owner) gets Access is denied managing a DFS namespace", "Delegation tab is blank", or "who can change our namespace?". End-user *file access* problems are `Namespace-B.md`; folder *visibility* (ABE) is `ABE/DFS-ABE-B.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run from a management box with RSAT DFS Management Tools and the ActiveDirectory module.

```powershell
Import-Module DFSN, ActiveDirectory

# 1. What kind of namespace is it? (Domain V2 / Domain V1 / Standalone decides where permissions live)
Get-DfsnRoot -Path '\\<domain>\<namespace>' | Select-Object Path, Type, State, Flags

# 2. Domain-based: who has write rights on the namespace object in AD?
$dn = "CN=<namespace>,CN=Dfs-Configuration,CN=System,$((Get-ADDomain).DistinguishedName)"
(Get-Acl -Path "AD:\$dn").Access |
    Where-Object { $_.AccessControlType -eq 'Allow' -and $_.ActiveDirectoryRights -match 'GenericAll|GenericWrite|WriteProperty|CreateChild|DeleteChild|WriteDacl' } |
    Select-Object IdentityReference, ActiveDirectoryRights, IsInherited

# 3. Is the delegated user/group local admin on every namespace server? (needed to add servers / for some tasks)
Get-DfsnRootTarget -Path '\\<domain>\<namespace>' | Select-Object TargetPath, State
Invoke-Command -ComputerName <nsServer> -ScriptBlock { Get-LocalGroupMember -Group Administrators | Select-Object Name, ObjectClass }

# 4. Which groups is the delegated user actually in (token, not just AD)?
Get-ADPrincipalGroupMembership -Identity <samAccountName> | Select-Object Name
```

| Result | Meaning | Go to |
|---|---|---|
| Delegated group **absent** from step 2 | Delegation never applied (or applied to another namespace) | Fix 1 |
| Delegated group present, user still denied adding **folders/targets** | User not in group yet in their token (needs re-logon), or using an old console session | Fix 2 |
| User denied **adding a namespace server** | Must also be local admin on the server being added | Fix 3 |
| User denied **creating a new domain namespace** | Default is Domain Admins only — needs rights on `CN=Dfs-Configuration` + local admin | Fix 4 |
| `Type` = Standalone and Delegation tab empty/errors | Standalone ACL lives in server registry; tab only works for local admins | Fix 5 |
| Step 2 shows raw SIDs (`S-1-5-21-…`) | Orphaned ACEs from deleted accounts | Fix 6 |
| Step 2 shows broad groups (e.g. `Domain Users`, `Authenticated Users`) with write | Over-delegation — security issue | Fix 6 |
| User says "permission denied" opening `\\domain\ns\folder` | That is file access, not management | `Namespace-B.md` / `ABE/DFS-ABE-B.md` |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Delegated admin can change the namespace
├─ Correct namespace TYPE identified
│  ├─ Domain V2 → ACL on msDFS-Namespacev2 object  CN=<ns>,CN=Dfs-Configuration,CN=System,<domainDN>
│  ├─ Domain V1 → ACL on fTDfs object (same container)
│  └─ Standalone → ACL on registry key on the namespace server (HKLM\SOFTWARE\Microsoft\Dfs\Standalone\<ns>)
├─ Delegated principal holds write/Full Control on that object
│  └─ AD change replicated to the DC the console binds to (PDC emulator by default for DFSN)
├─ User's Kerberos token contains the group (log off/on or klist purge after membership change)
├─ Task-specific extras
│  ├─ Add namespace server → local Administrators on THAT server
│  ├─ Create domain namespace → create-child rights on CN=Dfs-Configuration + local admin on server
│  └─ Standalone Delegation tab → local Administrators on namespace server
└─ RPC/SMB to namespace servers + DC (TCP 135, 445, dynamic RPC)
```
</details>

---
## Diagnosis & Validation Flow

1. **Identify type and root targets.**
   ```powershell
   Get-DfsnRoot -Path '\\<domain>\<namespace>' | Format-List Path, Type, State
   Get-DfsnRootTarget -Path '\\<domain>\<namespace>'
   ```
   Expected: `Type : Domain V2` for modern namespaces. `Standalone` → permissions are per-server registry (Fix 5).

2. **Read the namespace object ACL (domain-based).**
   ```powershell
   $dn = "CN=<namespace>,CN=Dfs-Configuration,CN=System,$((Get-ADDomain).DistinguishedName)"
   (Get-Acl "AD:\$dn").Access | Sort-Object IdentityReference |
       Format-Table IdentityReference, ActiveDirectoryRights, AccessControlType, IsInherited -AutoSize
   ```
   Expected: Domain Admins / Enterprise Admins / SYSTEM / BUILTIN\Administrators with GenericAll, plus your delegated group with `GenericAll` (what the console's *Delegate Management Permissions* grants). Missing group = never delegated.

3. **Confirm the user's effective membership.**
   ```powershell
   Get-ADUser <samAccountName> -Properties MemberOf | Select-Object -ExpandProperty MemberOf
   # On the user's admin workstation, after a group change:
   klist purge
   ```
   Expected: delegated group present. Nested groups count, but a membership added minutes ago is not in an existing logon token.

4. **Check local admin on the namespace server for server-level tasks.**
   ```powershell
   Invoke-Command -ComputerName <nsServer> { Get-LocalGroupMember Administrators }
   ```

5. **Reproduce with PowerShell to get a clean error.**
   ```powershell
   New-DfsnFolder -Path '\\<domain>\<namespace>\DelegationTest' -TargetPath '\\<fileServer>\<share>' -WhatIf
   ```
   `-WhatIf` validates parameters only; drop it (and remove the test folder after) to prove write access.

---
## Common Fix Paths

<details><summary>Fix 1 — Delegate management of an existing domain or standalone namespace</summary>

```powershell
# Grant (adds a Full Control ACE for the account on the namespace's config store)
Set-DfsnRoot -Path '\\<domain>\<namespace>' -GrantAdminAccounts '<DOMAIN>\<DFS-Admins-Group>'

# Verify
$dn = "CN=<namespace>,CN=Dfs-Configuration,CN=System,$((Get-ADDomain).DistinguishedName)"
(Get-Acl "AD:\$dn").Access | Where-Object IdentityReference -like '*<DFS-Admins-Group>*'
```
GUI: DFS Management → right-click the namespace → **Delegate Management Permissions**.

Always delegate to a **group**, never an individual. Rollback:
```powershell
Set-DfsnRoot -Path '\\<domain>\<namespace>' -RevokeAdminAccounts '<DOMAIN>\<DFS-Admins-Group>'
```
</details>

<details><summary>Fix 2 — Delegation is right but user is still denied</summary>

1. Have the user sign out/in, or run `klist purge` and reopen DFS Management.
2. Ensure the console is pointed at a DC that has the change: DFS Management → namespace → **Change Domain Controller**… or force replication:
   ```powershell
   repadmin /syncall /AdeP
   ```
3. Confirm the user isn't hitting a **Deny** ACE (step 2 output with `AccessControlType Deny`).
4. If the action is on a specific root target server (e.g. enabling ABE, changing root target state), check local admin on that server (Fix 3).
</details>

<details><summary>Fix 3 — Allow a delegated admin to add a namespace server (root target)</summary>

Microsoft requires both namespace delegation **and** local Administrators on the server being added.
```powershell
Invoke-Command -ComputerName <newNsServer> -ScriptBlock {
    Add-LocalGroupMember -Group Administrators -Member '<DOMAIN>\<DFS-Admins-Group>'
}
# Then, as the delegated admin:
New-DfsnRootTarget -Path '\\<domain>\<namespace>' -TargetPath '\\<newNsServer>\<namespace>'
```
Prefer pushing local admin membership via GPO Restricted Groups / Group Policy Preferences or Intune/LAPS-aligned tooling instead of ad-hoc. Rollback: `Remove-LocalGroupMember -Group Administrators -Member '<DOMAIN>\<DFS-Admins-Group>'`.
</details>

<details><summary>Fix 4 — Allow non-Domain-Admins to create new domain-based namespaces</summary>

Default: Domain Admins only. Delegate at the **Namespaces** node in DFS Management (right-click → Delegate Management Permissions), which grants rights on `CN=Dfs-Configuration,CN=System,<domainDN>`. Also make the group local admin on the server that will host the namespace (Fix 3).

Verify:
```powershell
$cfg = "CN=Dfs-Configuration,CN=System,$((Get-ADDomain).DistinguishedName)"
(Get-Acl "AD:\$cfg").Access | Where-Object IdentityReference -like '*<DFS-Admins-Group>*' |
    Select-Object IdentityReference, ActiveDirectoryRights, InheritanceType
```
Caution: rights here **inherit** to every existing namespace object (unless inheritance is blocked), so this effectively delegates all namespaces in the domain. Rollback: remove the ACE in the same console dialog (Remove) or ADSI Edit.
</details>

<details><summary>Fix 5 — Standalone namespace delegation</summary>

```powershell
Set-DfsnRoot -Path '\\<nsServer>\<namespace>' -GrantAdminAccounts '<DOMAIN>\<DFS-Admins-Group>'
# Inspect the backing registry ACL on the server
Invoke-Command -ComputerName <nsServer> -ScriptBlock {
    (Get-Acl 'HKLM:\SOFTWARE\Microsoft\Dfs\Standalone\<namespace>').Access |
        Select-Object IdentityReference, RegistryRights, AccessControlType
}
```
The DFS Management **Delegation** tab cannot read standalone DACLs for non-local-admins (documented behaviour) — a blank tab for a delegated user is expected, not a fault. Rollback: `-RevokeAdminAccounts`.
</details>

<details><summary>Fix 6 — Remove orphaned SIDs or over-broad delegation</summary>

```powershell
$dn  = "CN=<namespace>,CN=Dfs-Configuration,CN=System,$((Get-ADDomain).DistinguishedName)"
$acl = Get-Acl "AD:\$dn"
$acl | Export-Clixml "$env:TEMP\dfsn-acl-backup-<namespace>.xml"       # backup first
$bad = $acl.Access | Where-Object { -not $_.IsInherited -and
        ($_.IdentityReference.Value -match '^S-1-5-21-' -or $_.IdentityReference.Value -in @('<DOMAIN>\Domain Users','NT AUTHORITY\Authenticated Users')) -and
        $_.ActiveDirectoryRights -match 'GenericAll|GenericWrite|WriteProperty|CreateChild|DeleteChild|WriteDacl' }
$bad | Format-Table IdentityReference, ActiveDirectoryRights
foreach ($ace in $bad) { [void]$acl.RemoveAccessRule($ace) }
Set-Acl -Path "AD:\$dn" -AclObject $acl
```
Keep `Authenticated Users` **Read** — clients need it for referrals. Only remove write-type rights. Inherited ACEs must be fixed on the parent container. Rollback: `Set-Acl -Path "AD:\$dn" -AclObject (Import-Clixml "$env:TEMP\dfsn-acl-backup-<namespace>.xml")`.
</details>

---
## Escalation Evidence

```
Ticket: ________   Namespace: \\________\________   Type: Domain V2 / V1 / Standalone
Delegated principal: ________   User reporting: ________
Task attempted: add folder / add target / add namespace server / create namespace / other: ____
Exact error text: ____________________________________________
Namespace object ACL (writers): _______________________________
Delegated group in user's token (whoami /groups) Y/N: __
Local admin on namespace server(s) Y/N: __ (server: ________)
DC used by console: ________   repadmin /showrepl clean Y/N: __
Get-DFSNamespaceDelegationAudit.ps1 CSV attached Y/N: __
```

---
## 🎓 Learning Pointers
- The default-holders table and the "also add to local Administrators" rule behind Fix 3/4 are in [Delegate management permissions for DFS Namespaces](https://learn.microsoft.com/windows-server/storage/dfs-namespaces/delegate-management-permissions-for-dfs-namespaces).
- `Set-DfsnRoot -GrantAdminAccounts/-RevokeAdminAccounts` is the scriptable equivalent of the console dialog: [Set-DfsnRoot](https://learn.microsoft.com/powershell/module/dfsn/set-dfsnroot).
- `Grant-DfsnAccess` / `Get-DfsnAccess` are **not** management delegation — they set the per-folder ACL used for Access-Based Enumeration. Mixing the two up is the most common cause of "I delegated it but it didn't work". See `ABE/DFS-ABE-A.md`.
- Domain-based namespace config is just an AD object; any AD ACL auditing you already do (e.g. `ActiveDirectory/` delegation audits) should include `CN=Dfs-Configuration,CN=System`.
- Deep dive: `DFSN-Delegation-A.md`. Audit: `../../Scripts/Get-DFSNamespaceDelegationAudit.ps1`.
