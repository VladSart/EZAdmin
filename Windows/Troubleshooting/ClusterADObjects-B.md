# Failover Cluster AD Objects (CNO / VCO) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---
## Triage

**This runbook covers the Active Directory side of a failover cluster** — the Cluster Name Object (CNO), the Virtual Computer Objects (VCOs) it creates for clustered roles (file server, SQL FCI, AG listener, SOFS, generic roles), their OU permissions, passwords and DNS records. For quorum/networking/quarantine, use `FailoverClustering-B.md`. Hyper-V VM roles do not get a VCO — if only a VM role is failing, this is the wrong runbook.

Run on any cluster node, elevated:

```powershell
# 1. Every network name resource and its state
Get-ClusterResource | Where-Object { $_.ResourceType.Name -in 'Network Name','Distributed Network Name' } |
  Select-Object Name, State, OwnerGroup, OwnerNode

# 2. Per-name health flags (DNS / Kerberos / NetBIOS) and the AD object it is bound to
Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Network Name' } | ForEach-Object {
  $p = $_ | Get-ClusterParameter
  [pscustomobject]@{
    Resource  = $_.Name
    DnsName   = ($p | Where-Object Name -eq 'DnsName').Value
    ObjectGUID= ($p | Where-Object Name -eq 'ObjectGUID').Value
    StatusDNS = ($p | Where-Object Name -eq 'StatusDNS').Value
    StatusKerb= ($p | Where-Object Name -eq 'StatusKerberos').Value
  }
}

# 3. Network-name events in the last 7 days
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-FailoverClustering';
  Id=1069,1194,1196,1205,1206,1207,1211,1212,1218,1219,1257; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Format-List

# 4. Does the CNO exist in AD, is it enabled, and where does it live? (needs RSAT AD module)
Get-ADComputer -Identity (Get-Cluster).Name -Properties Enabled, DistinguishedName, ProtectedFromAccidentalDeletion, PasswordLastSet |
  Select-Object Name, Enabled, DistinguishedName, ProtectedFromAccidentalDeletion, PasswordLastSet
```

| Finding | Interpretation | Do this |
|---|---|---|
| New role / AG listener fails, **Event 1194** "failed to create its associated computer object" | CNO lacks **Create Computer objects** on its OU (or the VCO name already exists and CNO has no rights on it) | **Fix 1** (grant) or **Fix 2** (prestage VCO) |
| Name resource fails, **Event 1207** "computer object ... could not be updated" (usually + 1069) | CNO/VCO lacks rights on its own object, object disabled, or password out of sync | **Fix 3** |
| `Get-ADComputer` for the CNO returns "Cannot find an object" | CNO deleted from AD | **Fix 4** |
| CNO exists but `Enabled = False` | Disabled by cleanup script / stale-computer policy | **Fix 3** (enable, then Repair) |
| `StatusDNS` non-zero, **Event 1196 / 1257** | DNS record not registerable — stale record owned by another principal, or secure-zone ACL | **Fix 5** |
| **Event 1211 / 1212 / 1219** | Cluster can't find a writable DC — this is DC/site/DNS, not permissions | Check `nltest /dsgetdc:<domain> /writable` from the owner node; fix DC reachability first |
| **Event 1218** | Rename failed — cluster couldn't find the CNO; it will try to recreate it on next online | **Fix 4** if the object was deleted; otherwise **Fix 1** |
| `StatusKerberos` non-zero, users get auth prompts / SPN errors on the role name | VCO password/SPN problem | **Fix 3** on that VCO |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Writable DC reachable from the owner node (DNS SRV _ldap._tcp.dc._msdcs.<domain>)
    │
CNO computer object exists, ENABLED, password in sync with the cluster
  (cluster stores CNO credentials; Repair AD Object re-syncs them)
    │
CNO has on its OU:  Create Computer objects + Read all properties
  (VCOs are created in the SAME OU/container as the CNO by default)
    │
Each VCO: either created by the CNO, or prestaged (disabled) with
  CNO granted Full Control on it
    │
Network Name resource bound to the right AD object (ObjectGUID private property)
    │
DNS A/AAAA record registerable by the CNO/VCO (secure zone: the object
  that owns the record must be the CNO/VCO, or have Full Control on it)
    │
Clustered role online → clients resolve name → Kerberos SPNs on the VCO
```
</details>

---
## Diagnosis & Validation Flow

1. **Find the exact failing resource and event**
   ```powershell
   Get-ClusterResource | Where-Object State -ne 'Online' | Select-Object Name, ResourceType, State, OwnerGroup
   ```
   Expected: nothing returned. Any Network Name in `Failed` → note the name and go to step 2.

2. **Generate a focused cluster log** (most precise source — shows the LDAP/DNS error code)
   ```powershell
   Get-ClusterLog -Destination C:\Temp -TimeSpan 15 -UseLocalTime
   Select-String -Path C:\Temp\*cluster.log -Pattern 'Netname|NetName' | Select-Object -Last 40
   ```
   Look for: `status 5` (access denied → Fix 1/3), `80072030` "no such object" (deleted → Fix 4), `9005`/DNS errors (→ Fix 5), "unable to get computer object using GUID" (object recreated, GUID mismatch → Fix 4).

3. **Confirm where the CNO lives and whether it can create children there**
   ```powershell
   Import-Module ActiveDirectory
   $cno = Get-ADComputer (Get-Cluster).Name
   $ou  = ($cno.DistinguishedName -split ',',2)[1]
   $sid = $cno.SID
   (Get-Acl -Path "AD:\$ou").Access | Where-Object {
     ($_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])) -eq $sid
   } | Select-Object ActiveDirectoryRights, ObjectType, AccessControlType, InheritanceType
   ```
   Good: a row with `CreateChild` and ObjectType `bf967a86-0de6-11d0-a285-00aa003049e2` (computer) or `00000000-...` (all), plus `ReadProperty`. Nothing returned → Fix 1. Rights may also come via a group the CNO is in — `Get-ADPrincipalGroupMembership $cno` if no direct ACE.

4. **For a failing VCO, check whether the object already exists**
   ```powershell
   Get-ADComputer -Filter "Name -eq '<VCOName>'" -Properties Enabled, DistinguishedName, whenCreated
   ```
   Exists but not created by this CNO → CNO needs Full Control on it (Fix 2 step 3). Exists in a *different* OU than the CNO → fine if CNO has rights on it.

5. **Check DNS ownership for the name**
   ```powershell
   Resolve-DnsName <VCOName> -Type A
   ```
   Wrong/old IP returned → stale record (Fix 5).

---
## Common Fix Paths

<details><summary>Fix 1 — Grant the CNO "Create Computer objects" on its OU (Event 1194)</summary>

Run as a Domain Admin (or delegated OU admin) from a machine with RSAT:

```powershell
$domain = (Get-ADDomain).NetBIOSName
$cno    = Get-ADComputer (Get-Cluster -Name <ClusterName>).Name
$ou     = ($cno.DistinguishedName -split ',',2)[1]

# CC on computer objects + Read all properties, on the OU itself
dsacls "$ou" /G "$domain\$($cno.Name)`$:CC;computer"
dsacls "$ou" /G "$domain\$($cno.Name)`$:RP"
```

Then retry the role: `Start-ClusterResource -Name '<NetworkNameResource>'`.

Also check the domain-wide computer quota isn't the blocker: if your org removed the CNO's rights and relied on `ms-DS-MachineAccountQuota` (default 10), an old cluster with many roles can exhaust it — explicit OU delegation (above) removes the dependency.

Rollback: `dsacls "$ou" /R "$domain\$($cno.Name)$"` removes **all** ACEs for that principal on the OU — only use if you added them.
</details>

<details><summary>Fix 2 — Prestage the VCO (locked-down OU / change control won't allow Fix 1)</summary>

```powershell
$ou   = '<OU=Clusters,DC=contoso,DC=com>'
$vco  = '<VCOName>'                       # the client access point name, ≤15 chars
$cno  = '<ClusterName>'
$dom  = (Get-ADDomain).NetBIOSName

# 1. Create the object DISABLED (the cluster enables it when it takes ownership)
New-ADComputer -Name $vco -SamAccountName $vco -Path $ou -Enabled $false

# 2. Allow replication to the DC the cluster will hit (or wait)
# 3. Give the CNO Full Control on the new object
dsacls "CN=$vco,$ou" /G "$dom\$cno`$:GA"
```

Then rerun the role wizard / `Add-ClusterServerRole` / AG listener creation with that exact name.
</details>

<details><summary>Fix 3 — Object disabled or password out of sync (Event 1207)</summary>

```powershell
# 1. Re-enable if disabled (CNO or VCO)
Enable-ADAccount -Identity '<ObjectName>$'

# 2. Ensure the CNO has Full Control on its own object and on the VCO
$dom = (Get-ADDomain).NetBIOSName
$cno = (Get-Cluster).Name
dsacls (Get-ADComputer $cno).DistinguishedName /G "$dom\$cno`$:GA"
dsacls (Get-ADComputer '<VCOName>').DistinguishedName /G "$dom\$cno`$:GA"   # VCO case only
```

3. **Repair the AD object** — resets the object password and re-syncs it into the cluster. GUI only:
   Failover Cluster Manager → **Cluster Core Resources** → right-click the *Name:* resource → **More Actions → Repair Active Directory Object** (for a VCO: the role's Resources tab → name → More Actions → Repair). Run as an account with rights to reset the object's password.

4. Bring it online: `Start-ClusterResource -Name '<NetworkNameResource>'`

⚠ Microsoft's guidance is to fix permissions first and run Repair in a maintenance window on production clusters — Repair briefly cycles the name.
</details>

<details><summary>Fix 4 — CNO/VCO deleted from AD</summary>

**Restore it — do not recreate it.** The cluster binds to the object by `ObjectGUID`; a new object with the same name has a different GUID and the resource will still fail.

```powershell
# AD Recycle Bin enabled?
(Get-ADOptionalFeature 'Recycle Bin Feature').EnabledScopes

# Find and restore
Get-ADObject -Filter "isDeleted -eq `$true -and Name -like '<ObjectName>*'" -IncludeDeletedObjects -Properties lastKnownParent |
  Select-Object Name, ObjectGUID, lastKnownParent
Get-ADObject -Filter "isDeleted -eq `$true -and Name -like '<ObjectName>*'" -IncludeDeletedObjects | Restore-ADObject

# Then: enable if needed, and run Repair Active Directory Object (Fix 3 step 3)
Set-ADObject -Identity (Get-ADComputer '<ObjectName>').DistinguishedName -ProtectedFromAccidentalDeletion $true
```

No Recycle Bin → authoritative restore of the object from System State backup (see `ActiveDirectory/` AD-BackupRestore runbook) or escalate. If someone already created a *new* object with that name, delete the impostor before restoring.
</details>

<details><summary>Fix 5 — DNS registration fails (Event 1196 / 1257)</summary>

```powershell
# On a DNS server: who owns the record?
$zone = '<contoso.com>'; $name = '<VCOName>'
$rec = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ErrorAction SilentlyContinue
$rec
(Get-Acl -Path "AD:\$($rec.DistinguishedName)").Owner
```

If the owner isn't the CNO/VCO (e.g. a decommissioned server or an admin who hand-created it):

```powershell
# Remove the stale record, then let the cluster register a fresh one
Remove-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -Force
# On a cluster node:
Get-ClusterResource '<NetworkNameResource>' | Update-ClusterNetworkNameResource
```

Rollback: note the old record IP before deleting; `Add-DnsServerResourceRecordA -ZoneName $zone -Name $name -IPv4Address <oldIP>`.
</details>

---
## Escalation Evidence

```
Cluster name / CNO:            ____________________
Failing resource (name / role): ____________________
Owner node at failure:          ____________________
Event IDs observed (1069/1194/1196/1207/…): ________
Cluster log excerpt (Netname lines, error code): ____
CNO DN / Enabled / PasswordLastSet: _______________
CNO rights on OU (CreateChild computer? Y/N): ______
VCO exists? prestaged? CNO Full Control? __________
DNS record owner for the name:  ____________________
Writable DC from node (nltest /dsgetdc:<dom> /writable): ____
AD Recycle Bin enabled? (Y/N):  ____________________
Changes made so far + timestamps: __________________
Get-ClusterADObjectAudit.ps1 CSV attached? (Y/N): __
```

---
## 🎓 Learning Pointers
- VCOs are created by the **CNO's** computer account, not by you — so "I'm Domain Admin and it still fails" is expected when the CNO lacks rights. [Configure cluster accounts in AD](https://learn.microsoft.com/en-us/windows-server/failover-clustering/configure-failover-cluster-accounts)
- Event 1207 + 1069 is the signature pair; Microsoft's checklist is permissions → Repair → validation → DNS. [Can't bring a network name online](https://learn.microsoft.com/en-us/troubleshoot/windows-server/high-availability/troubleshoot-cannot-bring-network-name-online)
- Restoring beats recreating because the resource is bound by ObjectGUID — enable the AD Recycle Bin on every client domain before you need it. [AD Administrative Center enhancements — Recycle Bin](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/get-started/adac/introduction-to-active-directory-administrative-center-enhancements--level-100-)
- Stale-computer cleanup scripts are the #1 cause of disabled/deleted CNOs in MSP estates — exclude cluster OUs and set `ProtectedFromAccidentalDeletion`. See `ActiveDirectory/` stale-object guidance.
- Deep dive on the object model, Repair semantics and AD-detached clusters: `ClusterADObjects-A.md`; full audit: `Scripts/Get-ClusterADObjectAudit.ps1`.
