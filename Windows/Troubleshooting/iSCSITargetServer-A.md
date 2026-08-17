# iSCSI Target Server — Reference Runbook (Mode A: Deep Dive)
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

Covers the **iSCSI Target Server** role service (File and Storage Services → iSCSI Target Server, Windows feature `FS-iSCSITarget-Server`) on Windows Server 2016 through 2025, and the built-in **Microsoft iSCSI Initiator** on the client side. This is Microsoft's software-defined block-storage-over-Ethernet stack: a Windows Server computer exposes VHDX-backed virtual disks as iSCSI LUNs over the existing IP network, no dedicated SAN hardware required.

Does not cover:
- Third-party/hardware SAN iSCSI targets (Dell, NetApp, Synology, TrueNAS, etc.) — the client-side (Microsoft iSCSI Initiator, MPIO) content applies identically, but target-side administration is vendor-specific.
- Fibre Channel storage — architecturally unrelated transport, see `HyperV-A.md`'s Failover Clustering section for shared-storage concepts that apply to both.
- Storage Spaces Direct (S2D) — a separate hyperconverged storage architecture; see `StorageSpacesDirect-A.md`. S2D and iSCSI Target Server can coexist (S2D can back the VHDX files an iSCSI target serves) but are not the same technology.
- Storage Migration Service (file-level server migration) — see `StorageMigrationService-A.md`. iSCSI Target Server serves block storage; SMS migrates file shares.
- iSNS (Internet Storage Name Service) server deployment and management in depth — mentioned only where it affects target discovery.

---

## How It Works

<details><summary>Full architecture</summary>

iSCSI (Internet Small Computer System Interface) encapsulates SCSI commands inside TCP/IP, letting a Windows Server computer act as a **block storage device** reachable over an ordinary Ethernet network — no Fibre Channel HBAs or SAS cabling required. It is genuinely IP-routable: unlike Fibre Channel, an initiator and target do not need to share a physical fabric or even a subnet, provided ordinary IP routing and firewall rules permit port 3260 traffic between them.

**Server side — the role:**

The **iSCSI Target Server** role service creates and serves virtual disks. Each virtual disk is backed by a `.vhdx` file on the target server's own storage (the exact same VHD format Hyper-V uses for VM disks — this is a deliberate design reuse, not a coincidence). A **Target** object is an IQN (iSCSI Qualified Name) identity that one or more virtual disks are mapped to; initiators connect to a Target, not directly to a virtual disk. This target/disk separation is why a single Target can present multiple LUNs (multiple virtual disks mapped to the same Target) to one initiator, mirroring how a real SAN LUN group works.

Target-side access control is an **initiator ACL**, not authentication in the traditional sense: each Target maintains a list of permitted initiators identified by IQN, IP address, DNS name, or MAC address. CHAP (Challenge Handshake Authentication Protocol), and optionally mutual/reverse CHAP, is a genuinely separate, optional layer on top of that ACL — an initiator can be correctly listed in the ACL and still be refused login if CHAP is enabled and its secret doesn't match.

**Client side — the initiator:**

The built-in **Microsoft iSCSI Initiator** (service name `MSiSCSI`) discovers targets via a **Target Portal** (an IP:port pair, default port 3260) and establishes a **session** per target. Each session can have one or more **connections** — this is where **MPIO (Multipath I/O)** comes in: with the separate MPIO Windows feature installed and configured to claim the iSCSI bus type, multiple sessions to the *same* target over *different* NICs/subnets are aggregated by the Microsoft Device-Specific Module (MSDSM) into a single multipathed disk with a configurable load-balance policy (Round Robin, Failover Only, Least Queue Depth, etc.), rather than appearing as separate duplicate disks. Without MPIO claiming the device, multiple paths to the same LUN are a bug waiting to corrupt data, not a performance feature — this is why MPIO is treated as a prerequisite for any multi-NIC iSCSI design, not an optional tuning step.

A session can be marked **persistent** ("Favorite Target" in the GUI) so the initiator automatically reconnects after a reboot — this reconnection happens early in boot, which is the root of the single most common iSCSI reliability complaint: if the network adapter, NIC team, or virtual switch isn't fully up yet when `MSiSCSI` starts, the initial connection attempt fails and the client enters a retry/"Reconnecting" cycle until the network genuinely stabilizes.

**The clustering chicken-and-egg constraint:**

iSCSI Target Server can itself be deployed as a **clustered role** for high availability of the block storage it serves. This is where a structural constraint that catches almost everyone planning their first deployment applies: the clustered role's own virtual disks must be backed by storage that is **not itself iSCSI** — Fibre Channel, SAS-attached shared storage, or a Storage Spaces (including S2D) pool. A clustered iSCSI Target Server cannot host its VHDX files on a LUN it reaches over iSCSI, because that would make the role's own startup depend on a working iSCSI session that in turn depends on the role being started — an unresolvable circular dependency. Microsoft's own guidance states this plainly: "If high availability is an important criterion, consider setting up a high-availability cluster. You need shared storage for a high-availability cluster — either hardware for Fibre Channel storage or a serial attached SCSI (SAS) storage array."

**VDS/VSS hardware providers (legacy, optional):**

A separate, optional **iSCSI Target Storage Provider** feature installs VDS (Virtual Disk Service) and VSS (Volume Shadow Copy Service) hardware providers for iSCSI virtual disks. The VDS provider lets older storage-management tooling (e.g. `diskraid.exe`) manage iSCSI virtual disks through the generic VDS API rather than iSCSI-specific cmdlets. The VSS hardware provider lets VSS-aware backup applications take genuine hardware-level shadow copies of iSCSI-backed volumes, including (since Windows Server 2012) auto-recovery support that allows a Hyper-V host backup running against iSCSI Target Storage to complete correctly. This is a legacy integration point most modern deployments don't need — the native `IscsiTarget` PowerShell module and Windows Admin Center cover day-to-day management without it.

</details>

---

## Dependency Stack

```
┌─────────────────────────────────────────────────────────────┐
│ Application / VM / OS consuming the LUN as ordinary storage  │
├─────────────────────────────────────────────────────────────┤
│ Client: Disk Online + Initialized + Volume formatted/mounted │
├─────────────────────────────────────────────────────────────┤
│ [OPTIONAL] MPIO — MSDSM claims BusType iSCSI, aggregates     │
│ multiple sessions into one multipathed disk                  │
├─────────────────────────────────────────────────────────────┤
│ Client: MSiSCSI service running, session connected           │
│ (optionally persistent/"Favorite")                           │
├─────────────────────────────────────────────────────────────┤
│ [OPTIONAL] CHAP / mutual CHAP secret matches on both ends     │
├─────────────────────────────────────────────────────────────┤
│ Target ACL: initiator's IQN / IP / DNS / MAC explicitly       │
│ permitted on this Target                                     │
├─────────────────────────────────────────────────────────────┤
│ Target object (IQN identity) ← virtual disk LUN mapping       │
│ (Add-IscsiVirtualDiskTargetMapping)                           │
├─────────────────────────────────────────────────────────────┤
│ iSCSI Virtual Disk (.vhdx file, New-IscsiVirtualDisk)         │
├─────────────────────────────────────────────────────────────┤
│ [CLUSTERED ONLY] Non-iSCSI backing storage for the role's     │
│ own VHDX files (Fibre Channel / SAS / Storage Spaces)         │
├─────────────────────────────────────────────────────────────┤
│ Target: iSCSI Target Server role installed (FS-iSCSITarget-   │
│ Server), inbound firewall rule for TCP 3260 present           │
├─────────────────────────────────────────────────────────────┤
│ IP network reachability + consistent MTU between initiator    │
│ and target — iSCSI is routable, ordinary IP rules apply       │
└─────────────────────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `Test-NetConnection -Port 3260` fails | Firewall (client, target, or intermediate) blocking 3260; VLAN/routing gap | `Get-NetFirewallRule` on target; trace route between subnets |
| "Target did not respond" on login, target IS reachable | Target ACL doesn't list this initiator's exact IQN/IP/DNS/MAC | `Get-IscsiServerTarget -TargetName <T> \| Select InitiatorIds` vs. `(Get-InitiatorPort).NodeAddress` |
| Login fails with an authentication-specific error | CHAP secret mismatch, or secret under 12 characters | `Get-IscsiServerTarget` CHAP state; re-set on both ends |
| Session connects, but no new disk in Disk Management | No rescan triggered yet | `Update-HostStorageCache` then `Get-Disk` |
| Disk appears but is `Offline` | Default SAN policy for new iSCSI/SAN disks — expected, not a fault | `Set-Disk -IsOffline $false` |
| Disk appears as `RAW` and previously held data | Underlying corruption, wrong disk, or a target-side data problem | Stop — escalate before any format/repair attempt |
| Session repeatedly enters `Reconnecting` | NIC/team not ready at boot when `MSiSCSI` started; driver/firmware issue | `Get-WinEvent` for iSCSI provider IDs 9/20/27/39/153; `Get-NetAdapter` timing |
| Disk "surprise removed" (Event ID 157) after a reboot or path flap | Same network-instability class as above, more severe (path fully lost) | Same event/NIC checks; confirm MPIO path count didn't drop to zero |
| Only one path shown despite multiple target portals/NICs | MPIO not installed, or not claiming BusType iSCSI | `Get-WindowsFeature Multipath-IO`; `Get-MSDSMAutomaticClaimSettings` |
| `mpclaim -v` shows disk with paths in a `Degraded`/`Unhealthy` state | One physical path down — network or target-portal issue on that specific path | `Get-IscsiConnection` per session; check the specific NIC/portal |
| Favorite Target reconnect attempts a stale IP/identity | Target rebuilt or re-IP'd; client-side favorite entry not updated | `Get-IscsiTarget`; remove and re-add rather than editing in place |
| iSCSI/Storage PowerShell cmdlets throw provider-level errors | WMI/MOF repository corruption for the iSCSI/Storage providers | `mofcomp` re-registration sequence (see Remediation Playbooks) |
| Clustered iSCSI Target Server role won't stay online | Backing storage for its own VHDX files is itself iSCSI (circular dependency) | `Get-ClusterResource` type/parameters; confirm storage type |
| Volume on an iSCSI-backed disk becomes RAW/corrupted after an ungraceful disconnect | Improper shutdown/disconnect while the volume had outstanding writes | `chkdsk`/`refsutil salvage`; treat as a data-integrity incident |
| Windows Server 2022 shows a wrong Favorite Target IP after restart | Known cosmetic display-only issue, no functional impact | Confirmed via `Get-IscsiTarget`/session state actually being correct |

---

## Validation Steps

**1. Role and virtual disk health (target):**
```powershell
Get-WindowsFeature -Name FS-iSCSITarget-Server
Get-IscsiServerTarget | Select-Object TargetName, Enabled, TargetIqn
Get-IscsiVirtualDisk | Select-Object Path, Size, DiskStatus
```
Good: `Installed = True`, every `DiskStatus = Normal`. Bad: any status other than `Normal` — this points at the VHDX file or its host volume/storage layer, not at the iSCSI stack itself; investigate storage health first.

**2. Target ACL matches the real client identity:**
```powershell
# Target
Get-IscsiServerTarget -TargetName <T> | Select-Object -ExpandProperty InitiatorIds
# Client
(Get-InitiatorPort).NodeAddress
```
Good: an exact string match (IQN comparisons are case-sensitive in practice even though the IQN spec is nominally case-insensitive — always compare literally, don't eyeball it). Bad: any discrepancy, including trailing whitespace copied from a ticket or chat message.

**3. CHAP configuration consistency:**
```powershell
Get-IscsiServerTarget -TargetName <T> | Select-Object EnableChap, ChapUserName
```
Good: if `EnableChap = True`, the `ChapUserName` matches what the initiator is configured to send, and the secret (not readable back — track it in your password manager, not in the ticket) is 12-16 characters as required by the CHAP spec. Bad: `EnableChap = True` with no way to confirm the initiator's side matches — this is the most common self-inflicted outage of this entire stack.

**4. Client session and connection state:**
```powershell
Get-IscsiSession | Select-Object TargetNodeAddress, IsConnected, IsPersistent, IsDataDigest, IsHeaderDigest
Get-IscsiConnection | Select-Object TargetAddress, InitiatorAddress, ConnectionIdentifier
```
Good: `IsConnected = True` for every session expected to be active; `IsPersistent = True` for anything that must survive a reboot. Bad: any expected session showing `False`.

**5. Disk-level presentation on the client:**
```powershell
Get-Disk | Where-Object BusType -eq 'iSCSI' | Select-Object Number, OperationalStatus, PartitionStyle, Size, IsOffline
```
Good: `OperationalStatus = Online` for every disk expected to be in use. Bad: `Offline` (expected default for new disks, needs one `Set-Disk` call) or `RAW`/`Unknown` on a disk that previously had data (data-integrity concern, not a routine fix).

**6. MPIO claim and path health, if multipathing is in scope:**
```powershell
Get-MSDSMAutomaticClaimSettings
mpclaim.exe -v
```
Good: `iSCSI = True` in claim settings; `mpclaim -v` lists the disk with the expected path count, all `Active/Optimized`. Bad: fewer paths than expected, or any path shown `Unhealthy`/`Failed`.

**7. Firewall state on the target:**
```powershell
Get-NetFirewallRule -Direction Inbound -Enabled True | Where-Object { $_.DisplayName -like "*iSCSI*" } | Select-Object DisplayName, Action
```
Good: at least one enabled Allow rule covering TCP 3260. Bad: no matching rule (role's auto-created rule was deleted, disabled, or overridden by a GPO-managed firewall policy).

---

## Troubleshooting Steps (by phase)

**Phase 1 — Reachability.** Confirm IP connectivity and port 3260 first, before touching any iSCSI-specific configuration. A network problem produces symptoms (timeouts, "target did not respond") that are easy to misdiagnose as an ACL or CHAP problem if you start at the wrong layer.

**Phase 2 — Target-side identity and access.** Confirm the Target exists, is enabled, has the expected virtual disk mapped, and — critically — that its ACL contains the client's *actual current* identity. This is the phase where most "it was working yesterday" tickets resolve: something changed the client's IP, or the ACL was copy-pasted with a typo, or CHAP was enabled without coordinating the secret to the client side.

**Phase 3 — Client-side session establishment.** Confirm the `MSiSCSI` service state, the target portal is registered, and the session actually connects. If Phase 1 and 2 both check out but the session still won't establish, check the client's own local security/IPsec policy — a policy blocking outbound 3260 (rare, but seen in hardened environments) looks identical to a target-side firewall problem from this vantage point.

**Phase 4 — Disk presentation and multipathing.** Once the session is up, confirm the disk actually surfaced, is online, and — if multiple paths are expected — that MPIO is claiming it correctly. A connected session with no visible disk is very often just a missing rescan, not a deeper fault.

**Phase 5 — Stability under load and reboot.** Confirm behavior survives a client reboot (persistent/Favorite session reconnects cleanly) and sustained I/O (no repeated Reconnecting cycles, no MPIO path flapping). This phase is where NIC/team boot-timing issues and firmware/driver mismatches surface — they rarely show up in a quick initial connectivity test.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Stand up a new iSCSI target and virtual disk from scratch</summary>

```powershell
# 1. Install the role (target server) — include management tools for the MMC snap-in + module
Install-WindowsFeature -Name FS-iSCSITarget-Server -IncludeManagementTools

# 2. Create a virtual disk backed by a new VHDX
New-IscsiVirtualDisk -Path "D:\iSCSIVirtualDisks\Disk01.vhdx" -Size 100GB

# 3. Create the target (IQN identity), scoping the initiator ACL at creation time
New-IscsiServerTarget -TargetName "app01-lun01" -InitiatorIds "IQN:iqn.1991-05.com.microsoft:app01.contoso.com"

# 4. Map the virtual disk to the target (this is the LUN assignment)
Add-IscsiVirtualDiskTargetMapping -TargetName "app01-lun01" -Path "D:\iSCSIVirtualDisks\Disk01.vhdx"

# 5. (Optional) Enable CHAP
Set-IscsiServerTarget -TargetName "app01-lun01" -ChapUserName "app01-init" -ChapSecret "Str0ngChapSecret1" -EnableChap $true
```
On the client:
```powershell
Start-Service MSiSCSI
Set-Service MSiSCSI -StartupType Automatic
New-IscsiTargetPortal -TargetPortalAddress <TargetIP>
Connect-IscsiTarget -NodeAddress "iqn.1991-05.com.microsoft:targetserver-app01-lun01-target" -TargetPortalAddress <TargetIP> -IsPersistent $true -AuthenticationType ONEWAYCHAP -ChapUsername "app01-init" -ChapSecret "Str0ngChapSecret1"
Update-HostStorageCache
Get-Disk | Where-Object BusType -eq 'iSCSI'
```

**Rollback:** `Remove-IscsiServerTarget -TargetName "app01-lun01"` removes the target definition (virtual disk file itself is not deleted — remove the VHDX file separately if it's genuinely no longer needed).

</details>

<details><summary>Playbook 2 — Expand an existing iSCSI virtual disk (two-sided operation)</summary>

This is commonly missed as a two-step process — expanding the VHDX on the target does **not** automatically expand the visible volume on the client.

```powershell
# On the TARGET — grow the underlying virtual disk
Resize-IscsiVirtualDisk -Path "D:\iSCSIVirtualDisks\Disk01.vhdx" -SizeInBytes 200GB
```
```powershell
# On the CLIENT — rescan, then extend the partition into the newly available space
Update-HostStorageCache
Get-Disk | Where-Object BusType -eq 'iSCSI'
Get-PartitionSupportedSize -DiskNumber <N> -PartitionNumber <P>
Resize-Partition -DiskNumber <N> -PartitionNumber <P> -Size <NewSizeFromSupportedSize>
```

**Rollback:** Shrinking a live volume back down is a separate, higher-risk operation (`Resize-Partition` with a smaller `-Size`, only after confirming used space fits) — do not shrink to reverse a grow unless the grow itself caused a specific, confirmed problem.

</details>

<details><summary>Playbook 3 — Set up MPIO for a multi-NIC/multi-portal target</summary>

```powershell
# On the CLIENT
Install-WindowsFeature -Name Multipath-IO -IncludeManagementTools
Enable-MSDSMAutomaticClaim -BusType iSCSI
Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR   # Round Robin — reasonable default for most deployments
Restart-Computer

# After reboot — connect the SAME target over each additional NIC/portal explicitly
Connect-IscsiTarget -NodeAddress <TargetIqn> -TargetPortalAddress <Portal1IP> -IsMultipathEnabled $true -IsPersistent $true
Connect-IscsiTarget -NodeAddress <TargetIqn> -TargetPortalAddress <Portal2IP> -IsMultipathEnabled $true -IsPersistent $true

# Verify
mpclaim.exe -v
```

**Rollback:** `Disable-MSDSMAutomaticClaim -BusType iSCSI` followed by a reboot reverts to single-path (unclaimed) behavior; existing sessions over the now-unclaimed paths may need to be manually disconnected first to avoid duplicate-disk confusion.

</details>

<details><summary>Playbook 4 — Recover from WMI/MOF provider corruption</summary>

```console
mofcomp iscsirem.mof
mofcomp iscsidsc.mof
mofcomp iscsihba.mof
mofcomp iscsiprf.mof
mofcomp iscsiwmiv2.mof
mofcomp storagewmi.mof
```
```powershell
Restart-Service Winmgmt -Force
Restart-Service MSiSCSI -Force
```
If the problem persists after re-registration and both service restarts, treat it as a candidate for a full WMI repository rebuild (`winmgmt /salvagerepository`, then `winmgmt /resetrepository` as a last resort) or, per Microsoft's own guidance, plan to rebuild/reimage the computer if the issue recurs.

**Rollback:** N/A — `mofcomp` re-registers class definitions; it does not remove existing data or configuration.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects iSCSI Target Server / Initiator evidence for escalation. Read-only.
#>
$out = "iSCSI-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss).txt"

"=== Role / Feature ===" | Out-File $out
Get-WindowsFeature -Name FS-iSCSITarget-Server, Multipath-IO | Out-File $out -Append

"=== Targets / Virtual Disks (target only) ===" | Out-File $out -Append
Get-IscsiServerTarget -ErrorAction SilentlyContinue | Format-List * | Out-File $out -Append
Get-IscsiVirtualDisk -ErrorAction SilentlyContinue | Format-List * | Out-File $out -Append

"=== Sessions / Connections (client only) ===" | Out-File $out -Append
Get-IscsiSession -ErrorAction SilentlyContinue | Format-List * | Out-File $out -Append
Get-IscsiConnection -ErrorAction SilentlyContinue | Format-List * | Out-File $out -Append

"=== Disks ===" | Out-File $out -Append
Get-Disk | Where-Object BusType -eq 'iSCSI' | Format-List * | Out-File $out -Append

"=== MPIO ===" | Out-File $out -Append
Get-MSDSMAutomaticClaimSettings -ErrorAction SilentlyContinue | Out-File $out -Append
mpclaim.exe -v | Out-File $out -Append

"=== Firewall ===" | Out-File $out -Append
Get-NetFirewallRule -Direction Inbound | Where-Object { $_.DisplayName -like "*iSCSI*" } |
    Select-Object DisplayName, Enabled, Action, Profile | Out-File $out -Append

"=== Recent iSCSI events (System log, last 4 hours) ===" | Out-File $out -Append
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='msiscsi','iScsiPrt'; StartTime=(Get-Date).AddHours(-4)} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap | Out-File $out -Append

Write-Host "Evidence written to $out"
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-WindowsFeature -Name FS-iSCSITarget-Server` | Confirm role installed (target) |
| `Get-IscsiServerTarget` | List targets, their IQNs, enabled state, ACL (target) |
| `Get-IscsiVirtualDisk` | List virtual disks and `DiskStatus` (target) |
| `New-IscsiVirtualDisk -Path <vhdx> -Size <n>` | Create a new virtual disk (target) |
| `New-IscsiServerTarget -TargetName <n> -InitiatorIds <ids>` | Create a target with an initial ACL (target) |
| `Add-IscsiVirtualDiskTargetMapping` | Map a virtual disk to a target (LUN assignment, target) |
| `Set-IscsiServerTarget -ChapUserName/-ChapSecret/-EnableChap` | Configure CHAP (target) |
| `Resize-IscsiVirtualDisk` | Grow a virtual disk (target — client-side extend still required) |
| `Get-Service MSiSCSI` | Initiator service state (client) |
| `New-IscsiTargetPortal -TargetPortalAddress <ip>` | Register a target portal for discovery (client) |
| `Connect-IscsiTarget -NodeAddress <iqn> ...` | Establish a session (client) |
| `Get-IscsiSession` / `Get-IscsiConnection` | Session/connection state (client) |
| `(Get-InitiatorPort).NodeAddress` | This client's own initiator IQN |
| `Update-HostStorageCache` | Force a storage rescan after target-side changes (client) |
| `Get-Disk \| Where-Object BusType -eq 'iSCSI'` | List iSCSI-attached disks (client) |
| `Get-MSDSMAutomaticClaimSettings` | Confirm MPIO is claiming the iSCSI bus type (client) |
| `mpclaim.exe -v` | View claimed multipath disks and path health (client) |
| `Test-NetConnection -ComputerName <t> -Port 3260` | Basic reachability test |
| `Get-WinEvent -FilterHashtable @{ProviderName='msiscsi','iScsiPrt'}` | iSCSI-specific System log events |

---

## 🎓 Learning Pointers

- The Target/virtual-disk separation (one IQN identity, multiple mapped LUNs) mirrors how real SAN LUN groups work — understanding this distinction explains why `Get-IscsiServerTarget` and `Get-IscsiVirtualDisk` are two separate cmdlets with two separate health states, not one combined object. See [iSCSI Target Server overview](https://learn.microsoft.com/en-us/windows-server/storage/iscsi/iscsi-target-server).
- The clustered-role backing-storage constraint (no iSCSI-on-iSCSI) is a real architectural rule, not a configuration best practice you can work around — plan lab/POC cluster storage accordingly from day one.
- MPIO is a prerequisite for correctness in a multi-path design, not a performance add-on — connecting the same LUN over multiple NICs without MPIO claiming the device risks two independent, uncoordinated write paths to the same blocks.
- Microsoft's official [iSCSI storage connectivity troubleshooting guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/iscsi-storage-connectivity-troubleshooting) (updated February 2026) is the authoritative source for the event-ID-driven troubleshooting checklist this runbook builds on, including the December 2025 KB5072033 fix relevant to some connectivity symptoms — check patch level early if none of the fixes above resolve a persistent issue.
- See also the dedicated Microsoft troubleshooting article on [initiator failing to log in to Favorite Targets after the initiator name changes](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/iscsi-initiator-not-login-to-favorite-targets) — a narrower, specifically-named variant of the ACL-mismatch class of problem covered generally in this runbook's Fix 5/Playbook process.
- The VDS/VSS hardware provider integration (`diskraid.exe`, hardware-level VSS snapshots) is a legacy feature most deployments never touch — don't spend troubleshooting time on it unless a specific backup product's documentation calls it out as a requirement.

