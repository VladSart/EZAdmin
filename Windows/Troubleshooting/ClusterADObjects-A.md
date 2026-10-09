# Failover Cluster AD Objects (CNO / VCO) — Reference Runbook (Mode A: Deep Dive)
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

- **In scope:** AD-joined Windows Server 2016–2025 failover clusters (and Azure Local) with an **AD** administrative access point; the Cluster Name Object (CNO), Virtual Computer Objects (VCOs) for client access points (File Server, SQL Server FCI, SQL AG listener, Scale-Out File Server, generic service/application roles); OU delegation, prestaging, object passwords, Repair Active Directory Object, deletion/restore, DNS record ownership.
- **Out of scope:** quorum, networking, quarantine, CAU (`FailoverClustering-A.md`); CSV/VM behaviour (`HyperV-A.md`); S2D pool health (`StorageSpacesDirect-A.md`); SQL-side AG health beyond the listener's network name.
- **Assumes:** RSAT AD PowerShell and DNS Server modules on the admin host; Domain Admin or delegated rights on the cluster OU for remediation. Read-only checks need only domain user + local admin on a node.

---
## How It Works

<details><summary>Full architecture</summary>

### Two kinds of cluster computer objects

```
                 Active Directory  (OU=Clusters,DC=contoso,DC=com)
 ┌───────────────────────────────────────────────────────────────────┐
 │  CN=SQLCLU01   ← CNO  (created by the HUMAN running New-Cluster,   │
 │                        or prestaged disabled by an AD admin)      │
 │      │  CNO's own computer account then creates…                  │
 │      ├──► CN=SQLFCI01   ← VCO for SQL FCI client access point     │
 │      ├──► CN=AGLSN01    ← VCO for AG listener                     │
 │      └──► CN=FS01       ← VCO for clustered File Server role      │
 └───────────────────────────────────────────────────────────────────┘
```

- **CNO** — the computer object for the cluster's own administrative name (core resource "Cluster Name"). It's created during `New-Cluster` **using the credentials of the person creating the cluster** — that person needs Create Computer objects + Read all properties on the target container, or a prestaged disabled object they have Full Control on.
- **VCO** — one per client access point. Created **by the CNO's computer account** (the cluster service acting as the CNO), by default **in the same OU as the CNO**. This is the single most misunderstood point: the admin's own privileges are irrelevant at VCO creation time; the CNO needs Create Computer objects on that OU, or a prestaged VCO it has Full Control over.
- **Hyper-V VM roles** don't create VCOs — VMs have their own computer accounts.
- **Distributed Network Name (DNN)** resources (SOFS, and since WS2019 optionally the cluster name itself on Azure) register node IPs rather than a floating IP; SOFS still has a VCO.

### Binding: name ↔ AD object

Each Network Name resource stores private properties (`Get-ClusterParameter`) including `Name`, `DnsName`, `ObjectGUID`, `CreatingDC`, `StatusDNS`, `StatusKerberos`, `StatusNetBIOS`, `RegisterAllProvidersIP`, `HostRecordTTL`. `ObjectGUID` is how the resource finds its AD object. Consequence: if the object is deleted and an admin "fixes" it by creating a new computer object with the same name, the GUID differs and the resource still fails ("unable to get computer object using GUID"). **Restore, don't recreate.**

### Passwords

The cluster holds the CNO's credentials and manages the machine password like any computer account, and the CNO manages VCO passwords. If the stored credentials and AD disagree (object reset by someone else, restored from an old backup, disabled/re-enabled, USN rollback on a DC) Kerberos pre-auth for the object fails, and the name resource throws 1207-style "could not be updated" errors. **Repair Active Directory Object** (Failover Cluster Manager → name resource → More Actions) resets the object password using the logged-on admin's credentials and pushes the new secret into the cluster — it's a re-sync, not a recreate, and needs the object to exist and the admin to have Reset Password rights on it.

### DNS

Each name registers A/AAAA (and optionally PTR) records. In AD-integrated **secure** zones, the record's owner ACL matters: the CNO/VCO that registered it owns it and can update it on IP change/failover. If the record was hand-created, belonged to a previous server of the same name, or was created by another node's account, the cluster gets access denied → Event 1196/1257, `StatusDNS ≠ 0`. `Update-ClusterNetworkNameResource` forces re-registration once the ACL problem is cleared. Multi-subnet listeners: `RegisterAllProvidersIP=1` registers every subnet IP; legacy clients without `MultiSubnetFailover=True` then time out — that's a client issue, not an AD one, but it shows up on the same tickets.

### AD-detached clusters

Since WS2016, `New-Cluster -AdministrativeAccessPoint DNS` creates a cluster with **no CNO** (DNS-only admin point). Kerberos to the cluster name is unavailable (NTLM only), and roles needing Kerberos/VCOs (e.g. File Server with SMB Kerberos, SQL with Kerberos) are constrained. `-AdministrativeAccessPoint None` creates a cluster with no admin name at all (common on Azure SQL VMs using DNN). Check `(Get-Cluster).AdministrativeAccessPoint` before chasing a "missing CNO".

### Why MSP estates break this

1. Stale-computer cleanup (disable after 90 days of no `lastLogonTimestamp`) catches VCOs of rarely-failed-over roles — their objects are legitimately "quiet".
2. Hardened OUs where Create Child was stripped by a baseline; next new role/listener fails with 1194.
3. Cluster objects moved to a "Servers" OU by a tidy-up script — the CNO loses inherited delegation; VCOs now get created in the new OU where the CNO has no rights.
4. Manual DNS cleanup / scavenging misconfiguration deleting or re-owning records.
5. Domain-wide `ms-DS-MachineAccountQuota` set to 0 as hardening — irrelevant if the CNO has explicit Create Child delegation, fatal if it relied on the quota.
</details>

---
## Dependency Stack

```
Layer 7  Clients resolve <VCO> → connect with Kerberos (SPNs on the VCO object)
Layer 6  Clustered role online (depends on Network Name + IP + storage)
Layer 5  Network Name resource online  ── StatusDNS / StatusKerberos / StatusNetBIOS = 0
Layer 4  DNS record registerable by the CNO/VCO (owner ACL in secure zone)
Layer 3  VCO exists, enabled, CNO has Full Control (created-by-CNO or prestaged)
Layer 2  CNO exists, enabled, password in sync, Create Computer objects + Read all
         properties on its OU (or on the OU where VCOs are prestaged)
Layer 1  Writable DC reachable from the owner node; AD replication healthy
Layer 0  Node domain membership + secure channel (Test-ComputerSecureChannel)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| New role / AG listener fails with **1194** | CNO lacks Create Computer objects on its OU; quota exhausted; name taken by an object CNO can't write | OU ACL for CNO SID; `Get-ADComputer -Filter "Name -eq '<n>'"` |
| Cluster Name offline, **1207 + 1069** | CNO disabled, password out of sync, or CNO lacks rights on its own object | `Get-ADComputer <cno> -Prop Enabled,PasswordLastSet`; cluster log `status 5` |
| **1207** with cluster log `80072030` | Object deleted | `Get-ADObject -IncludeDeletedObjects` |
| "Unable to get computer object using GUID" | Object recreated instead of restored | Compare resource `ObjectGUID` with `Get-ADComputer <n>`.ObjectGUID |
| **1196 / 1257**, `StatusDNS` non-zero | DNS record owned by another principal; secure zone ACL | Record owner via `Get-Acl AD:\<recordDN>` |
| **1211 / 1212 / 1219** | No writable DC reachable | `nltest /dsgetdc:<dom> /writable` from owner node |
| **1218** after rename | CNO not found during rename | Object location/deletion |
| Role works on node A, fails after failover to node B | Node B secure channel broken / can't reach writable DC (site) | `Test-ComputerSecureChannel` on node B |
| Kerberos prompts / `KRB_AP_ERR_MODIFIED` to role name | Duplicate SPN, or VCO password mismatch | `setspn -X`; Repair the VCO |
| `Get-Cluster` works but no CNO in AD | AD-detached cluster | `(Get-Cluster).AdministrativeAccessPoint` |

---
## Validation Steps

1. **Admin access point type**
   ```powershell
   (Get-Cluster).AdministrativeAccessPoint
   ```
   Good: `ActiveDirectoryAndDns`. `Dns` / `None` → no CNO by design; most of this runbook doesn't apply.

2. **Every name resource online with zero status codes**
   ```powershell
   Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Network Name' } | ForEach-Object {
     $p = $_ | Get-ClusterParameter -Name StatusDNS, StatusKerberos, StatusNetBIOS, ObjectGUID, DnsName
     [pscustomobject]@{ Resource=$_.Name; State=$_.State
       DnsName=($p | ? Name -eq DnsName).Value; GUID=($p | ? Name -eq ObjectGUID).Value
       DNS=($p | ? Name -eq StatusDNS).Value; Kerb=($p | ? Name -eq StatusKerberos).Value }
   }
   ```
   Good: State `Online`, DNS `0`, Kerb `0`. Bad: any non-zero → `net helpmsg <code>`.

3. **AD object matches the resource**
   ```powershell
   Get-ADComputer -Identity '<DnsName>' -Properties ObjectGUID, Enabled, PasswordLastSet, ProtectedFromAccidentalDeletion
   ```
   Good: ObjectGUID equals the resource's `ObjectGUID` (format differences aside), `Enabled=True`, `PasswordLastSet` within ~30 days (default machine password age). Bad: mismatch → recreated; disabled → cleanup tooling.

4. **CNO delegation on the VCO OU** — see `Get-ClusterADObjectAudit.ps1` (`CnoCanCreateComputers` column). Good: `True`.

5. **Secure channel on every node**
   ```powershell
   Invoke-Command -ComputerName (Get-ClusterNode).Name { Test-ComputerSecureChannel }
   ```
   Good: `True` everywhere.

6. **Writable DC from every node**
   ```powershell
   Invoke-Command -ComputerName (Get-ClusterNode).Name { nltest /dsgetdc:$env:USERDNSDOMAIN /writable }
   ```

7. **DNS record ownership** (Fix 5 in the B runbook). Good: owner is `<DOMAIN>\<VCO>$` or the CNO.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Cluster creation fails (CNO stage).** The *human* account is the actor. Check: Create Computer objects + Read all properties on the target container, or a prestaged CNO that is **disabled** and on which the installer has Full Control. An *enabled* prestaged CNO fails because the wizard can't prove it isn't in use. `New-Cluster -Name <n> -Node <a>,<b> -StaticAddress <ip>` places the CNO in the default Computers container unless you pass a DN: `New-Cluster -Name 'CN=<n>,OU=Clusters,DC=contoso,DC=com' ...`.

**Phase 2 — Role/listener creation fails (VCO stage).** The *CNO* is the actor. Event 1194. Fix delegation on the CNO's OU, or prestage the VCO in any OU with CNO Full Control. For SQL AGs, the listener creation in SSMS/`New-SqlAvailabilityGroupListener` surfaces this as a generic "failed to bring network name online" — check System log 1194 on the node owning the AG role.

**Phase 3 — Existing name stops coming online.** Order: object exists? → enabled? → GUID matches? → CNO rights on object? → password re-sync (Repair) → DNS. Always pull the cluster log first; the status code tells you which.

**Phase 4 — Post-failover only.** Points at the node, not AD: secure channel, site/DC locator, DNS client config on that node.

**Phase 5 — Post-domain-change events** (DC restore, functional level raise, tiering/hardening project, OU restructure). Diff the cluster OU ACL against a known-good cluster OU; re-apply delegation; Repair CNO then each VCO.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standard delegation for a cluster OU (preventive)</summary>

```powershell
$dom = (Get-ADDomain).NetBIOSName
$ou  = '<OU=Clusters,DC=contoso,DC=com>'
$cno = '<ClusterName>'
dsacls "$ou" /G "$dom\$cno`$:CC;computer"
dsacls "$ou" /G "$dom\$cno`$:RP"
Get-ADComputer -SearchBase $ou -Filter * | Set-ADObject -ProtectedFromAccidentalDeletion $true
```
Add the OU to the exclusion list of any stale-computer cleanup automation. Rollback: `dsacls "$ou" /R "$dom\$cno$"`.
</details>

<details><summary>Playbook 2 — Prestage CNO + VCOs for a locked-down environment</summary>

```powershell
$ou = '<OU=Clusters,DC=contoso,DC=com>'; $dom = (Get-ADDomain).NetBIOSName
$installer = '<DOMAIN\installer>'; $cno = '<ClusterName>'; $vcos = @('<VCO1>','<VCO2>')

New-ADComputer -Name $cno -SamAccountName $cno -Path $ou -Enabled $false
dsacls "CN=$cno,$ou" /G "$($installer):GA"
foreach ($v in $vcos) {
  New-ADComputer -Name $v -SamAccountName $v -Path $ou -Enabled $false
  dsacls "CN=$v,$ou" /G "$dom\$cno`$:GA"
}
```
Wait for replication (or target the same DC), then `New-Cluster -Name $cno ...`. Note: the VCO ACEs reference `$cno$` — `dsacls` resolves the name at grant time, so the CNO object must exist first (it does: created above).
</details>

<details><summary>Playbook 3 — Restore deleted CNO/VCO</summary>

1. Take the affected role offline (it's failed anyway); stop scripted cleanup.
2. `Get-ADObject -Filter "isDeleted -eq `$true -and Name -like '<n>*'" -IncludeDeletedObjects -Properties lastKnownParent,whenChanged`
3. If a *new* same-name object exists, delete it first (it's the wrong GUID).
4. `... | Restore-ADObject`; `Enable-ADAccount '<n>$'` if needed.
5. Re-apply CNO Full Control on a VCO if ACLs were lost.
6. Repair Active Directory Object on the name resource; `Start-ClusterResource`.
7. Protect: `Set-ADObject <DN> -ProtectedFromAccidentalDeletion $true`.

No Recycle Bin: authoritative restore of the object from a System State backup — destructive to the DC, plan per `ActiveDirectory/` backup-restore runbook, or escalate to Microsoft. As a last resort for a VCO only: remove and recreate the client access point (role downtime, new GUID, new SPNs, clients may cache).
</details>

<details><summary>Playbook 4 — Password re-sync without GUI (Repair alternative)</summary>

Repair AD Object is the supported path and is GUI-only. If you can only reach nodes via PowerShell remoting, use Failover Cluster Manager from an admin workstation (`cluadmin.msc` connecting to the cluster) — don't reset the computer password in ADUC ("Reset Account"), which breaks the sync further.
</details>

<details><summary>Playbook 5 — DNS ownership cleanup for a set of names</summary>

```powershell
$zone = '<contoso.com>'
foreach ($n in (Get-ClusterResource | ? { $_.ResourceType.Name -eq 'Network Name' } |
               ForEach-Object { ($_ | Get-ClusterParameter -Name DnsName).Value })) {
  $r = Get-DnsServerResourceRecord -ComputerName '<DNSServer>' -ZoneName $zone -Name $n -RRType A -ErrorAction SilentlyContinue
  if ($r) { foreach ($x in @($r)) { [pscustomobject]@{Name=$n; IP=$x.RecordData.IPv4Address; Owner=(Get-Acl "AD:\$($x.DistinguishedName)").Owner} } }
}
```
Records whose Owner isn't the matching `$`-account: record IP, delete, `Update-ClusterNetworkNameResource`. Rollback: re-add A record with the recorded IP.
</details>

---
## Evidence Pack

```powershell
# Run elevated on a cluster node with RSAT-AD-PowerShell. Read-only.
$out = "C:\Temp\ClusterADEvidence_$(Get-Date -Format yyyyMMdd_HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null
Get-Cluster | Select-Object Name, Domain, AdministrativeAccessPoint | Export-Csv "$out\cluster.csv" -NoTypeInformation
Get-ClusterResource | Select-Object Name, ResourceType, State, OwnerGroup, OwnerNode | Export-Csv "$out\resources.csv" -NoTypeInformation
Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Network Name' } |
  ForEach-Object { $_ | Get-ClusterParameter | Select-Object @{n='Resource';e={$_.ClusterObject.Name}}, Name, Value } |
  Export-Csv "$out\netname-params.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-FailoverClustering'; StartTime=(Get-Date).AddDays(-14)} -ErrorAction SilentlyContinue |
  Where-Object { $_.Id -in 1069,1194,1196,1205,1206,1207,1211,1212,1218,1219,1257 } |
  Select-Object TimeCreated, Id, MachineName, Message | Export-Csv "$out\events.csv" -NoTypeInformation
Get-ClusterLog -Destination $out -TimeSpan 60 -UseLocalTime | Out-Null
Invoke-Command -ComputerName (Get-ClusterNode).Name { [pscustomobject]@{Node=$env:COMPUTERNAME; SecureChannel=(Test-ComputerSecureChannel)} } |
  Select-Object Node, SecureChannel | Export-Csv "$out\securechannel.csv" -NoTypeInformation
# AD-side audit (CNO/VCO objects + OU delegation)
# .\Get-ClusterADObjectAudit.ps1 -OutputPath $out
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List network names | `Get-ClusterResource \| ? { $_.ResourceType.Name -eq 'Network Name' }` |
| Name resource private props | `Get-ClusterResource '<n>' \| Get-ClusterParameter` |
| Admin access point type | `(Get-Cluster).AdministrativeAccessPoint` |
| Focused cluster log | `Get-ClusterLog -Destination C:\Temp -TimeSpan 15 -UseLocalTime` |
| CNO object state | `Get-ADComputer <cno> -Prop Enabled,PasswordLastSet,ProtectedFromAccidentalDeletion` |
| Grant Create Computer objects | `dsacls "<OU DN>" /G "DOM\<cno>$:CC;computer"` |
| Grant Read all properties | `dsacls "<OU DN>" /G "DOM\<cno>$:RP"` |
| Full Control on prestaged VCO | `dsacls "<VCO DN>" /G "DOM\<cno>$:GA"` |
| Prestage disabled object | `New-ADComputer -Name <n> -Path <OU> -Enabled $false` |
| Find deleted object | `Get-ADObject -Filter "isDeleted -eq `$true -and Name -like '<n>*'" -IncludeDeletedObjects` |
| Restore deleted object | `... \| Restore-ADObject` |
| Re-register DNS | `Get-ClusterResource '<n>' \| Update-ClusterNetworkNameResource` |
| Writable DC from node | `nltest /dsgetdc:<domain> /writable` |
| Secure channel per node | `Invoke-Command (Get-ClusterNode).Name { Test-ComputerSecureChannel }` |
| Duplicate SPNs | `setspn -X` |
| Decode status code | `net helpmsg <code>` |

---
## 🎓 Learning Pointers
- The "who creates what" model (installer → CNO, CNO → VCOs, same OU by default) and the official prestaging steps: [Configure cluster accounts in Active Directory](https://learn.microsoft.com/en-us/windows-server/failover-clustering/configure-failover-cluster-accounts)
- Microsoft's checklist and the full network-name event table (1050–1052, 1207, 1211/1212, 1218/1219): [Can't bring a network name online in a failover cluster](https://learn.microsoft.com/en-us/troubleshoot/windows-server/high-availability/troubleshoot-cannot-bring-network-name-online)
- What Repair actually does to the password and when it's safe: *Understanding the Repair Active Directory Object Recovery Action* — Failover Clustering blog on Tech Community.
- Older but still-accurate background on prestaging: [Prestage Cluster Computer Objects in AD DS](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-R2-and-2012/dn466519(v=ws.11))
- Account troubleshooting beyond network names (installer rights, quota): [Troubleshoot issues with accounts used by failover clusters](https://learn.microsoft.com/en-us/troubleshoot/windows-server/high-availability/troubleshoot-issues-accounts-used-failover-clusters)
- Related in this repo: `FailoverClustering-A.md` (quorum/network layer), `ActiveDirectory/` (Recycle Bin, authoritative restore, stale-object cleanup).
