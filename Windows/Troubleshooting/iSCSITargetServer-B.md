# iSCSI Target Server — Hotfix Runbook (Mode B: Ops)
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

Run these first. Results tell you which fix path to take.

```powershell
# 1. Is the iSCSI Target Server role actually installed and its cmdlets available? (run ON THE TARGET)
Get-WindowsFeature -Name FS-iSCSITarget-Server | Select-Object Name, Installed

# 2. What targets/virtual disks exist, and are they online? (run ON THE TARGET)
Get-IscsiServerTarget | Select-Object TargetName, Enabled, TargetIqn
Get-IscsiVirtualDisk | Select-Object Path, Size, DiskStatus

# 3. Is the Microsoft iSCSI Initiator service running and what sessions are live? (run ON THE CLIENT)
Get-Service -Name MSiSCSI | Select-Object Name, Status, StartType
Get-IscsiSession | Select-Object TargetNodeAddress, SessionIdentifier, IsConnected

# 4. Basic TCP reachability to the target on the iSCSI port (default 3260)
Test-NetConnection -ComputerName <TargetIPorFQDN> -Port 3260

# 5. Any iSCSI errors in the System log in the last hour? (run on the CLIENT — this is where session drops surface)
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='msiscsi','iScsiPrt'; StartTime=(Get-Date).AddHours(-1)} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message
```

| If | Then |
|----|------|
| `Test-NetConnection` on port 3260 fails | Network path or target-side firewall is blocking iSCSI → **Fix 1** |
| Session connects, but no disk shows up in Disk Management on the client | New volume never rescanned, or offline/RAW → **Fix 2** |
| Session repeatedly drops / shows `Reconnecting` in the iSCSI Initiator GUI | NIC/MPIO timing at boot, or driver/firmware mismatch → **Fix 3** |
| Login fails with an authentication error, or CHAP secret mismatch | CHAP username/secret don't match on both ends, or secret is under 12 characters → **Fix 4** |
| `Connect-IscsiTarget` / GUI login fails "target did not respond" but the target IS listening | Target-side ACL doesn't include this initiator's IQN/IP/DNS/MAC → **Fix 5** |
| Only one path is active even though the target has multiple portals/NICs | MPIO feature not installed or not claiming this device's Vendor/Product ID → **Fix 6** |
| Favorite/persistent target list is stale after an IP change or a rebuilt target | Remove and re-add the favorite target rather than editing it in place → **Fix 7** |
| `Get-IscsiServerTarget` / other iSCSI or Storage cmdlets throw provider errors | WMI/MOF repository corruption on the target → **Fix 8** |
| Clustered "iSCSI Target Server" role won't come online in Failover Cluster Manager | Its own backing storage for the VHDX files is itself iSCSI — the clustered role needs non-iSCSI shared storage → **Fix 9** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Network reachability, correct VLAN/MTU, between initiator (client) and target (server)
   iSCSI is a routable TCP/IP protocol — it crosses subnets/VLANs, unlike Fibre Channel
        │
Target: File and Storage Services role → iSCSI Target Server feature (FS-iSCSITarget-Server)
   Auto-creates its own inbound firewall rule for TCP 3260 on install
        │
[CLUSTERED TARGETS ONLY] Backing storage for the role's VHDX files must be NON-iSCSI
   (Fibre Channel, SAS shared storage, or Storage Spaces) — a clustered iSCSI Target
   Server role cannot store its own virtual disks on another iSCSI LUN (chicken/egg)
        │
iSCSI Virtual Disk (.vhdx file, created/associated via New-IscsiVirtualDisk)
        │
iSCSI Target object (an IQN identity, created via New-IscsiServerTarget) with the
virtual disk mapped to it (Add-IscsiVirtualDiskTargetMapping = the LUN assignment)
        │
Target ACL: each permitted initiator identified by IQN, IP address, DNS name, or MAC —
   must match EXACTLY what the initiator actually presents, or login is refused
        │
[OPTIONAL] CHAP (or mutual/reverse CHAP) secret configured IDENTICALLY on target
   (Set-IscsiServerTarget -ChapUserName/-ChapSecret/-EnableChap) and initiator
        │
Client: Microsoft iSCSI Initiator service (MSiSCSI) running, target portal registered
   (New-IscsiTargetPortal / iSCSI Initiator GUI "Discovery" tab)
        │
Session connected (Connect-IscsiTarget) — optionally marked persistent/"Favorite"
   so it reconnects automatically after a client reboot
        │
[OPTIONAL] MPIO feature installed (Install-WindowsFeature Multipath-IO) and claiming
   this device's Vendor/Product ID (MSFT2005iSCSIBusType_0x9) — without this, multiple
   target portals/NICs show as SEPARATE disks, not one multipathed disk
        │
Disk visible on the client — must still be brought Online, Initialized, and
formatted/mounted in Disk Management before any application can use it
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the role and its virtual disks are healthy on the target:**
```powershell
Get-WindowsFeature -Name FS-iSCSITarget-Server
Get-IscsiVirtualDisk | Select-Object Path, Size, DiskStatus, OriginalPath
```
Expected: `Installed = True`, every virtual disk `DiskStatus = Normal`. `DiskStatus` other than `Normal` (e.g. `Faulted`, `Missing`) points at the underlying VHDX file or its host volume, not at iSCSI itself.

**2. Confirm the target ACL actually contains this initiator:**
```powershell
Get-IscsiServerTarget -TargetName <TargetName> | Select-Object -ExpandProperty InitiatorIds
```
Compare this against the client's real initiator name:
```powershell
(Get-InitiatorPort).NodeAddress
```
A mismatch here (typo, wrong IQN copied, IP ACL used but client got a new DHCP address) is the single most common "target did not respond" / login-refused cause — and it looks identical to a firewall problem from the client side.

**3. Confirm the client-side service and session state:**
```powershell
Get-Service -Name MSiSCSI
Get-IscsiSession | Select-Object TargetNodeAddress, IsConnected, IsPersistent
Get-IscsiConnection | Select-Object TargetAddress, InitiatorAddress
```
`IsConnected = False` on a session that's supposed to be active, with `IsPersistent = True`, means the client is retrying — check Step 5 below for why.

**4. Rescan and confirm the disk actually surfaced on the client:**
```powershell
Update-HostStorageCache
Get-Disk | Where-Object BusType -eq 'iSCSI' | Select-Object Number, OperationalStatus, PartitionStyle, Size
```
A disk stuck `Offline` after rescan needs `Set-Disk -Number <N> -IsOffline $false` — this is expected default behavior for new iSCSI/SAN disks (SAN policy), not a fault.

**5. Pull the actual iSCSI System-log errors, not just the GUI's generic "reconnecting":**
```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='msiscsi','iScsiPrt'} -MaxEvents 30 |
    Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap
```
Event IDs 9, 20, 27, 39, 153 and "target did not respond" / "initiator failed to connect" are the documented signature of network instability or a NIC/team that wasn't ready when the iSCSI service started at boot — see Fix 3.

**6. If multipathing looks wrong, confirm MPIO is actually claiming the disk:**
```powershell
Get-MSDSMAutomaticClaimSettings
mpclaim.exe -v
```
If iSCSI isn't `True` in the claim settings, or `mpclaim -v` doesn't list the disk with more than one path, MPIO is installed but not claiming this specific device — see Fix 6.

---

## Common Fix Paths

<details><summary>Fix 1 — Can't reach the target on port 3260 (network/firewall)</summary>

**Symptom:** `Test-NetConnection -Port 3260` fails; no login attempt even reaches the target's event log.

```powershell
# On the TARGET — confirm the role's own inbound rule wasn't disabled/overridden by GPO
Get-NetFirewallRule -Direction Inbound -Enabled True |
    Where-Object { $_.DisplayName -like "*iSCSI*" } |
    Select-Object DisplayName, Action, Profile

# If missing entirely, recreate it explicitly
New-NetFirewallRule -DisplayName "iSCSI Target (TCP-In)" -Direction Inbound -Protocol TCP -LocalPort 3260 -Action Allow -Profile Domain,Private
```
Also confirm the client and target aren't on VLANs with a routed ACL blocking 3260 between the iSCSI subnets specifically (a common design where iSCSI traffic is intentionally isolated from general LAN routing).

**Rollback:** N/A — this only opens a port, it doesn't remove any existing rule.

</details>

<details><summary>Fix 2 — Session connects but no usable disk appears</summary>

**Symptom:** `Get-IscsiSession` shows `IsConnected = True`, but Disk Management / `Get-Disk` shows nothing new, or the disk is `Offline`/`RAW`.

```powershell
# Force a rescan — new LUNs don't always appear automatically
Update-HostStorageCache

# Bring it online and initialize if this is genuinely a brand-new disk
Get-Disk | Where-Object BusType -eq 'iSCSI' | Where-Object OperationalStatus -eq 'Offline' |
    Set-Disk -IsOffline $false
Initialize-Disk -Number <N> -PartitionStyle GPT
New-Partition -DiskNumber <N> -UseMaximumSize -AssignDriveLetter
Format-Volume -DriveLetter <X> -FileSystem NTFS -Confirm:$false
```
If the disk shows `RAW` and this is NOT a brand-new disk (i.e. it previously had data), stop — treat it as a corruption/data-loss scenario and escalate rather than reformatting.

**Rollback:** Formatting is destructive — do not run `Format-Volume` on a disk you haven't confirmed is genuinely new/empty.

</details>

<details><summary>Fix 3 — Session repeatedly drops or shows "Reconnecting"</summary>

**Symptom:** Event IDs 9/20/27/39/153, disk briefly disappears then returns, worse right after a reboot.

```powershell
# Confirm NIC/team is fully up before iSCSI depends on it — a common boot-race cause
Get-NetAdapter | Select-Object Name, Status, LinkSpeed
Get-NetAdapterStatistics | Select-Object Name, ReceivedPacketErrors, OutboundPacketErrors

# Confirm MTU is IDENTICAL end-to-end if jumbo frames are in use anywhere on the path
Get-NetAdapterAdvancedProperty -DisplayName "Jumbo Packet"
```
If the client is a VM whose vNIC/team wasn't ready when `MSiSCSI` started, the client will retry and self-heal — but if this happens on every boot, either delay-start the service or move persistent-target-dependent workloads to start after network is confirmed up. Also update NIC/storage-controller firmware and drivers — this is one of the most common root causes per Microsoft's own iSCSI connectivity guidance.

**Rollback:** N/A — diagnostic and configuration-only steps.

</details>

<details><summary>Fix 4 — CHAP authentication failure</summary>

**Symptom:** Login fails with an authentication-specific error rather than a timeout; works fine with CHAP disabled.

```powershell
# On the TARGET — set (or reset) the CHAP secret; CHAP secrets must be 12-16 characters
Set-IscsiServerTarget -TargetName <TargetName> -ChapUserName <InitiatorIqnOrUsername> -ChapSecret <NewSecret12to16chars> -EnableChap $true

# On the CLIENT — reconnect supplying the matching credentials
Disconnect-IscsiTarget -NodeAddress <TargetIqn> -Confirm:$false
Connect-IscsiTarget -NodeAddress <TargetIqn> -TargetPortalAddress <TargetIP> -AuthenticationType ONEWAYCHAP -ChapUsername <Username> -ChapSecret <NewSecret12to16chars> -IsPersistent $true
```
The single most common cause is simply that the secret was changed on one side and not the other — CHAP gives no useful partial-match diagnostic, it just refuses the login.

**Rollback:** `Set-IscsiServerTarget -TargetName <TargetName> -EnableChap $false` to remove the requirement while troubleshooting (re-enable once confirmed working).

</details>

<details><summary>Fix 5 — Target ACL doesn't recognize this initiator</summary>

**Symptom:** Target is reachable on 3260, but login is refused ("target did not respond" in the client GUI, despite the target being up).

```powershell
# On the CLIENT — get the exact identity being presented
(Get-InitiatorPort).NodeAddress

# On the TARGET — add it to the target's ACL (repeat -InitiatorId for multiple entries)
Set-IscsiServerTarget -TargetName <TargetName> -InitiatorIds "IQN:<ExactIqnFromClient>"
```
If the ACL is IP-based instead of IQN-based, confirm the client's IP hasn't changed (DHCP renewal, NIC reconfig) since the ACL was written — IP-based ACLs are the more fragile option for this reason; prefer IQN-based ACLs where practical.

**Rollback:** N/A — this only grants access; removing the ACL entry reverses it if added in error.

</details>

<details><summary>Fix 6 — Only one path active despite multiple NICs/portals</summary>

**Symptom:** `mpclaim -v` shows one path only, or performance/failover doesn't match the multi-NIC design.

```powershell
# Confirm MPIO feature is present
Get-WindowsFeature -Name Multipath-IO

# Install if missing
Install-WindowsFeature -Name Multipath-IO -IncludeManagementTools

# Claim the iSCSI bus type explicitly, then reboot
Enable-MSDSMAutomaticClaim -BusType iSCSI
Restart-Computer
```
After reboot, connect additional sessions to the SAME target over the OTHER NIC/portal explicitly (the initial `Connect-IscsiTarget` only creates one session on one path):
```powershell
Connect-IscsiTarget -NodeAddress <TargetIqn> -TargetPortalAddress <SecondPortalIP> -IsMultipathEnabled $true -IsPersistent $true
```

**Rollback:** `Disable-MSDSMAutomaticClaim -BusType iSCSI` reverses the claim policy (existing multipathed disks may need a reboot to fully revert).

</details>

<details><summary>Fix 7 — Stale Favorite/persistent target after an IP or identity change</summary>

**Symptom:** Client repeatedly tries to reconnect to an address/identity that no longer exists; editing the entry in the GUI doesn't stick.

```powershell
# Remove the stale persistent target entirely — do not try to edit it in place
Get-IscsiTarget | Where-Object NodeAddress -eq <StaleTargetIqn> | Disconnect-IscsiTarget -Confirm:$false
Remove-IscsiTargetPortal -TargetPortalAddress <OldIP> -TargetPortalPortNumber 3260 -Confirm:$false

# Re-add and reconnect against the CURRENT address/identity
New-IscsiTargetPortal -TargetPortalAddress <NewIP>
Connect-IscsiTarget -NodeAddress <TargetIqn> -TargetPortalAddress <NewIP> -IsPersistent $true
```

**Rollback:** N/A — this only removes and re-establishes a client-side connection definition.

</details>

<details><summary>Fix 8 — iSCSI/Storage PowerShell cmdlets throw provider errors</summary>

**Symptom:** `Get-IscsiServerTarget`, `Get-Disk`, or similar cmdlets fail with WMI/provider-level errors rather than normal PowerShell errors.

```console
mofcomp iscsirem.mof
mofcomp iscsidsc.mof
mofcomp iscsihba.mof
mofcomp iscsiprf.mof
mofcomp iscsiwmiv2.mof
mofcomp storagewmi.mof
```
Then restart the WMI service and the iSCSI-related services before retrying the cmdlets.

**Rollback:** N/A — `mofcomp` re-registers WMI class definitions; it does not remove data.

</details>

<details><summary>Fix 9 — Clustered iSCSI Target Server role won't come online</summary>

**Symptom:** The role comes online briefly then fails, or won't start at all, specifically in a clustered deployment.

Confirm the role's storage isn't itself iSCSI — a clustered iSCSI Target Server needs its OWN shared storage (Fibre Channel, SAS, or a Storage Spaces pool) to host the VHDX files it serves; it cannot host those files on a disk it reaches over iSCSI, since that creates a startup dependency loop.
```powershell
Get-ClusterResource | Where-Object ResourceType -eq "IscsiTargetServer" | Get-ClusterParameter
Get-ClusterSharedVolume
```
If the backing storage is confirmed non-iSCSI and the role still fails, treat it as a standard cluster-resource issue — validate the cluster and pull the cluster log:
```powershell
Test-Cluster
Get-ClusterLog -Destination C:\ClusterLogs
```

**Rollback:** N/A — diagnostic only.

</details>

---

## Escalation Evidence

Copy, fill in, and attach to the ticket:

```
ISCSI TARGET SERVER — ESCALATION SUMMARY
==========================================
Date/Time:
Engineer:
Target server (FQDN/IP):
Client/initiator (FQDN/IP):
Target IQN:
Client initiator IQN (Get-InitiatorPort):

SYMPTOM:
<exact error text from client GUI or PowerShell, verbatim>

TRIAGE RESULTS:
- FS-iSCSITarget-Server installed on target?      Y / N
- Test-NetConnection port 3260 result:             <output>
- Get-IscsiServerTarget InitiatorIds (target ACL): <output>
- Get-InitiatorPort NodeAddress (client identity): <output>
- Get-IscsiSession / IsConnected:                  <output>
- Relevant System-log event IDs (last 1 hr):       <IDs + first line of each>
- CHAP enabled? Secret verified matching on both sides? Y / N
- MPIO installed / claiming this BusType?          Y / N

STEPS ALREADY TRIED:
1.
2.

BUSINESS IMPACT:
<workload/VM/application affected, downtime so far>
```

---

## 🎓 Learning Pointers

- iSCSI is IP-routable — it deliberately doesn't require the client and target to share a subnet the way Fibre Channel would, but that also means ordinary firewall/VLAN/routing rules apply to it exactly like any other TCP service on port 3260. See [iSCSI Target Server overview](https://learn.microsoft.com/en-us/windows-server/storage/iscsi/iscsi-target-server).
- "Target did not respond" from the client is genuinely ambiguous between a network problem and an ACL problem — always check the target's `InitiatorIds` before assuming it's a firewall issue, per Step 2 of the Diagnosis flow.
- A clustered iSCSI Target Server role has a structural chicken-and-egg constraint: it cannot store its own virtual disks on storage it reaches over iSCSI. This is easy to miss when planning a lab/POC cluster and only surfaces as a role that won't stay online.
- CHAP failures give almost no diagnostic detail by design (that's the point of a challenge-handshake scheme) — don't spend time parsing the error text closely; go straight to re-setting the secret identically on both ends.
- Follow Microsoft's official [iSCSI storage connectivity troubleshooting guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/iscsi-storage-connectivity-troubleshooting) for the full checklist this runbook's Triage/Diagnosis sections are drawn from — it also documents the December 2025 KB5072033 fix for a class of iSCSI connectivity issues, worth checking patch level against if symptoms match but none of the fixes above resolve it.
- If Favorite Target entries look wrong after a reboot on Windows Server 2022, that's a known cosmetic display issue in the GUI with no functional back-end impact — don't chase it as a real fault; see the same Microsoft guidance above.

