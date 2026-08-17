# On-Premises to Azure Disaster Recovery (VMware & Hyper-V) — Reference Runbook (Mode A: Deep Dive)
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

This file covers **on-premises to Azure** disaster recovery for VMware VMs and Hyper-V VMs using Azure Site Recovery (ASR). It is deliberately separate from `Azure/SiteRecovery/SiteRecovery-A.md`, which covers **Azure-to-Azure (A2A)** replication — a related but architecturally distinct product surface that shares only the Recovery Services vault construct and the general failover/reprotect/failback lifecycle shape.

Assumes:
- An Azure subscription with Contributor (or higher) on the target resource group, and a Recovery Services vault already created (or about to be, per the setup playbook below)
- For VMware: a vSphere environment (vCenter recommended, standalone ESXi supported) and the **Modernized** architecture — the **Classic** architecture (Configuration Server + Process Server) is out of scope for new deployments; support for Classic ends **15 March 2026** and the capability retires entirely on **30 March 2026**
- For Hyper-V: Windows Server Hyper-V hosts, optionally managed by System Center Virtual Machine Manager (VMM); Windows Server 2008/2008 R2/2012/2012 R2 hosts are past end of support and should be flagged for OS upgrade independent of any DR ticket
- Az PowerShell (`Az.RecoveryServices` module) with an authenticated session (`Connect-AzAccount`) for the validation and evidence-pack commands throughout this file

Out of scope: Azure-to-Azure replication (see `SiteRecovery-A.md`), AWS/GCP-to-Azure migration paths, and Azure Backup (a separate, snapshot-based product that happens to share the Recovery Services vault container — see `Azure/Backup/AzureBackup-A.md` and the cross-reference note in `Azure/_AGENT.md`).

---
## How It Works

### Two platforms, two fundamentally different on-premises component stacks

The single most important architectural fact in this domain: **VMware and Hyper-V do not share an on-premises component model**, despite both being described as "Azure Site Recovery."

**VMware (Modernized):** everything on-premises runs inside a single deployed unit, the **ASR replication appliance** — one OVA/VM hosting six logical roles (proxy server, discovered-items service, re-protection server, process server, Recovery Service agent, Site Recovery provider). A **Mobility Service agent** is additionally installed inside each replicated VM's guest OS. The appliance is the one thing you check, restart, or re-register when VMware-side replication breaks.

**Hyper-V:** there is no appliance at all. Instead:
- **Without VMM:** the Azure Site Recovery Provider and the Recovery Services agent are installed directly on each standalone Hyper-V host (or each cluster node). Nothing is installed inside the guest VM — replication uses the native Hyper-V Replica mechanism.
- **With VMM:** the Provider is installed once on the VMM server (covering every Hyper-V host/cluster the VMM server manages); the Recovery Services agent is still installed on each individual Hyper-V host/cluster node. VM networks defined in VMM must additionally be mapped to Azure virtual networks before failover.

This split explains why a VMware fix ("restart the appliance services") has no Hyper-V equivalent — there's no single object playing that role — and why Hyper-V troubleshooting instead centers on the Provider/agent services running on whichever box you installed them on.

### VMware replication process (Modernized)

1. Enabling replication for a VM starts **block-level, near-continuous** replication via the Mobility Service agent inside the guest.
2. Traffic flow: guest VM → appliance on HTTPS 443 inbound (management) and HTTPS 9443 inbound (replication data, port configurable) → appliance → Azure over HTTPS 443 outbound only.
3. Data lands first in a **cache storage account in the source region** — the same architectural role the cache storage account plays in A2A replication (see `SiteRecovery-A.md`'s "replication pipeline" section for the shared downstream mechanics).
4. From the cache, data is processed into an Azure Managed Disk (internally named `asrseeddisk`), and recovery points are created against it.
5. Traffic can route over the public internet, ExpressRoute with Microsoft peering, or — for private-endpoint scenarios only — a site-to-site VPN.

### Hyper-V replication process

1. Enabling protection triggers a Hyper-V VM **snapshot**, then each virtual hard disk is replicated to Azure one at a time via `StartReplication`.
2. While initial replication is in progress, the **Hyper-V Replica Replication Tracker** records any disk changes as `.hrl` (Hyper-V Replication Log) files, one per disk, stored alongside the disk itself.
3. When initial replication completes, the snapshot is deleted and the tracked delta changes are merged into the parent disk.
4. Delta replication then proceeds on the configured replication policy interval, with each subsequent delta sent as another `.hrl` log to the storage account.
5. **No agent is ever installed inside the guest VM** for Hyper-V — this is the clearest practical difference from VMware, where the Mobility Service agent is mandatory inside every protected VM.

### Resynchronization (both platforms)

Both platforms mark a VM for resynchronization after: a network interruption during replication, a force shutdown of the source VM, or (VMware-specific) a disk resize. Hyper-V additionally triggers resync automatically when `.hrl` log files reach roughly 50% of the disk's size — an early-warning mechanism that avoids ever needing a full re-seed. Resync computes checksums (VMware: between source and Azure-stored data; Hyper-V: fixed-block chunking with per-chunk checksum comparison) and transfers only the differing blocks. Both platforms default to running resync **automatically outside office hours**; both support a manual on-demand trigger from the portal (there is no dedicated PowerShell cmdlet for triggering it — the portal is the mechanism).

### Retry behavior differs by platform — Hyper-V's is the more consequential one to know

Hyper-V explicitly classifies replication errors into two buckets:
- **Non-recoverable** (VM status → `Critical`, **zero automatic retry**): broken VHD chain, invalid replica VM state, network authentication/authorization errors, VM-not-found (standalone hosts only). These sit broken indefinitely until a human intervenes.
- **Recoverable** (automatic retry with exponential back-off — 1, 2, 4, 8, 10 minutes from the first attempt, then every 30 minutes thereafter): network errors, low disk space, low memory conditions on the host.

VMware/A2A-style replication health (`Normal`/`Warning`/`Critical`) doesn't document an equivalent explicit non-recoverable/recoverable split in the same way — Hyper-V's retry classification is a genuinely distinct behavior worth knowing before you assume "it'll self-heal eventually."

### Snapshot consistency model (shared concept, VMware-specific VSS detail)

Both platforms create **crash-consistent** recovery points on a fixed, non-configurable interval (VMware: every 5 minutes; Hyper-V: per replication policy interval) and optional **app-consistent** recovery points on a configurable frequency using VSS. On VMware specifically, the Mobility agent uses VSS's **Copy Only backup method (VSS_BT_COPY)** — chosen deliberately so it doesn't disturb SQL Server's own transaction-log backup sequence numbers, meaning ASR's app-consistent snapshots don't interfere with an independent SQL backup regime running on the same VM.

### Outbound connectivity model — proxy support is asymmetric

VMware Modernized architecture **supports** using an authentication proxy to control outbound connectivity from the appliance. Hyper-V architecture explicitly **does not support** any outbound authentication proxy at all — this is stated as a hard limitation, not a configuration option to enable. A corporate network team applying a single proxy policy across both DR platforms will break Hyper-V replication in a way that looks like a URL allow-list problem but isn't.

### Classic vs. Modernized (VMware/physical only) — timeline and the "new vault" trap

The Classic VMware/physical architecture (Configuration Server + Process Server, optionally scaled out with additional Process Servers) is being retired on a fixed public timeline:

| Date | What changes |
|---|---|
| 31 Jan 2026 | Enabling NEW replication via Classic is blocked in both the portal and PowerShell |
| 15 Mar 2026 | Support for the Classic experience is discontinued |
| 30 Mar 2026 | Classic capability is fully retired — replication health may be disrupted, and view/manage/DR operations through the ASR portal experience for Classic-protected machines stop working |

Migration to Modernized uses a "smart replication mechanism" — machines already replicating transfer only differential data during migration, not a full re-seed. The most consequential setup detail: **a new Recovery Services vault must be created for the Modernized ASR replication appliance — an existing Classic vault must not be reused.** This is stated explicitly in Microsoft's own deployment guidance and is the most common self-inflicted setup error in this domain.

### Failover and failback — two different sequences per platform

**VMware Modernized failback** is a strict 3-stage sequence:
1. **Reprotect** — the failed-over Azure VM begins replicating back toward the on-premises VMware VM (requires a new cache storage account in the now-source recovery region if one doesn't already exist there)
2. **Failover** — run a failover in the reverse direction, to on-premises
3. **Re-enable replication** — once failed back, replication is re-enabled for the on-premises VM so DR protection resumes going forward

**Hyper-V failback** is also 3 stages, but with a meaningful choice at stage 1:
1. **Planned failover from Azure back to on-premises**, with a choice between:
   - **Minimize Downtime** — pre-synchronizes changed data blocks to on-premises while the Azure VM keeps running, then a final short cutover; lowest downtime, best for planned/non-urgent failback
   - **Full Download** — downloads the entire disk with no checksum-based delta calculation; faster to *start*, but more total downtime — appropriate only when the on-premises VM no longer exists or has been offline long enough that a delta sync wouldn't meaningfully help
   - Also specifies **Create VM**: same-VM vs. alternate-VM target, and whether Site Recovery should create the target VM if it's missing
2. Complete the failover once initial synchronization finishes, verify the on-premises VM, confirm the Azure VM has stopped
3. **Commit** the failover, then **enable reverse replication** so the on-premises VM begins replicating to Azure again going forward

### Cost model

Both platforms bill based on: number of protected instances (per-instance ASR fee after any free trial period), the cache/target storage consumed in Azure, egress/ingress network transfer, and (VMware Modernized specifically) the compute cost of running the on-premises ASR replication appliance VM itself. Recovery point retention settings directly affect storage cost — VMware Modernized supports up to **15 days** of retention (default policy: 1 day recovery point retention, app-consistent snapshots disabled by default), and higher retention windows increase the number of recovery points retained and therefore storage consumed.

---
## Dependency Stack

```
Layer 6 — Replication health / RPO (computed end-to-end; platform-specific error surfaces above)
Layer 5 — Recovery points (crash-consistent always; app-consistent if VSS-enabled/configured)
Layer 4 — Target-region storage (cache storage account -> managed disk, same shared role as A2A)
Layer 3a (VMware) — Mobility Service agent inside guest VM, talking to the appliance
Layer 3b (Hyper-V) — Native Hyper-V Replica + .hrl log tracking (NOTHING installed in guest)
Layer 2a (VMware) — ASR replication appliance (proxy/discovery/reprotect/process/agent/provider)
Layer 2b (Hyper-V, no VMM) — Provider + Recovery Services agent on EACH standalone host
Layer 2c (Hyper-V, with VMM) — Provider on VMM server; Recovery Services agent on each host/node;
                                  VM network -> Azure VNet mapping
Layer 1 — Recovery Services Vault (VMware Modernized: MUST be newly created, never reused
                                     from a Classic deployment)
Layer 0 — Outbound connectivity: 443 (VMware mgmt), 9443 (VMware data, VM->appliance only),
                                    443 outbound appliance/agent->Azure; auth proxy supported
                                    on VMware Modernized, NOT supported at all on Hyper-V
```

A break at any layer degrades everything stacked above it. In practice, most VMware tickets that "look like" a Layer 5/6 replication-health problem trace back to Layer 2a (the appliance itself) or Layer 0 (connectivity/proxy); most Hyper-V tickets trace back to Layer 2b/2c (the Provider or agent service state) since there's no intermediate appliance to mask a service-level failure.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| VMware VM ReplicationHealth Critical, appliance heartbeat stale | Appliance VM offline, network-isolated, or a core service crashed | `Get-AzRecoveryServicesAsrFabric` health/heartbeat; log onto appliance directly |
| VMware VM stuck at "not communicating," appliance itself healthy | Mobility Service agent inside the VM can't reach the appliance (port 9443 blocked) | `Test-NetConnection` from the VM to the appliance on 9443 and 443 |
| Hyper-V VM Critical, no active job, error text mentions VHD or replica state | Non-recoverable error — zero automatic retry by design | Read exact error in portal Errors tab; classify per the four non-recoverable categories |
| Hyper-V VM cycling through repeated failures | Recoverable error under exponential back-off (network/disk/memory on the host) | Check host disk/memory headroom; confirm network path to Azure |
| Failed-over Hyper-V VM has no NIC/IP | VM network was never mapped to an Azure VNet (VMM-managed environments) | Confirm VMM logical network -> Azure VNet mapping predates the failover |
| VMware failback "stuck" for days | Mandatory reprotect stage never triggered | Check `ProtectionState`/Jobs tab for a completed reprotect job before assuming failure |
| Hyper-V failback taking far longer than expected | Full Download chosen when Minimize Downtime would have used delta sync | Confirm which failback option was selected; re-run with Minimize Downtime if appropriate |
| Portal shows a Configuration Server object for a VMware vault | Customer is still on the Classic (retiring) architecture | Flag for migration regardless of ticket's original symptom — see Fix 1 in `OnPremDR-B.md` |
| Replication "just stopped" after a routine network/proxy change | Auth-required proxy introduced in the outbound path (breaks Hyper-V outright; may or may not break VMware depending on proxy config) | Confirm proxy type and platform; Hyper-V has zero auth-proxy support |
| VM marked for resync every few days without an obvious network event | Hyper-V `.hrl` log files repeatedly approaching ~50% of disk size — likely a high-churn workload | Review write activity on the source VM/disk; consider replication policy or disk-level changes |
| App-consistent recovery points missing while crash-consistent ones are current | VSS-specific failure inside the guest (same class of issue as A2A error 153006 — see `SiteRecovery-B.md` Fix 3/4 for VSS service troubleshooting steps, applicable to VMware guests here too) | Check VSS/Mobility-related services inside the guest VM |

---
## Validation Steps

1. **Set vault context and confirm fabric type**
   ```powershell
   Set-AzRecoveryServicesAsrVaultContext -Vault (Get-AzRecoveryServicesVault -ResourceGroupName "<vaultRg>" -Name "<vaultName>")
   Get-AzRecoveryServicesAsrFabric | Select-Object FriendlyName, FabricSpecificDetails
   ```
   Good: returns a fabric with a recognizable VMware or Hyper-V/VMM type. Bad: empty result — vault/subscription context is wrong, or nothing has been registered yet.

2. **VMware — confirm appliance heartbeat and version currency**
   ```powershell
   Get-AzRecoveryServicesAsrFabric | Select-Object FriendlyName, Health, @{N='LastHeartbeat';E={$_.FabricSpecificDetails.LastHeartbeat}}
   ```
   Good: `Health` Normal, heartbeat within minutes. Bad: stale heartbeat — appliance is unreachable or a service has crashed; go to the appliance VM directly.

3. **Hyper-V — confirm Provider/agent services on the host or VMM server**
   ```powershell
   Get-Service | Where-Object { $_.DisplayName -match "Site Recovery|Recovery Services" } | Select-Object Name, Status
   ```
   Good: both `Running`. Bad: either stopped — this alone explains a total loss of replication reporting.

4. **Confirm per-item replication health and protection state**
   ```powershell
   Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container |
     Select-Object FriendlyName, ProtectionState, ReplicationHealth
   ```
   Good: `Protected` / `Normal`. Bad: anything else — cross-reference against the Symptom → Cause Map above before picking a fix.

5. **Confirm which architecture generation you're actually troubleshooting (VMware only)**
   ```
   Portal: vault > Site Recovery Infrastructure > For VMware/Physical machines
   Modernized shows an "ASR replication appliance"; Classic shows a "Configuration Server."
   ```
   Good: Modernized appliance present. Bad: Configuration Server present — this is a Classic deployment on a retirement clock; treat as a migration flag independent of the immediate ticket.

6. **Confirm recent job history for context before troubleshooting further**
   ```powershell
   Get-AzRecoveryServicesAsrJob | Sort-Object StartTime -Descending | Select-Object -First 10 DisplayName, State, StartTime
   ```
   Good: recent jobs succeeding on a normal cadence. Bad: a cluster of recent failures — read each `StateDescription` before assuming they're all the same root cause.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Identify platform and architecture generation.** Every subsequent step depends on this. Confirm VMware (Classic vs. Modernized) vs. Hyper-V (with vs. without VMM) before touching anything.

**Phase 2 — Confirm the on-premises component layer is alive.** VMware: appliance heartbeat and core service status. Hyper-V: Provider/Recovery Services agent service status on the host or VMM server. This single check resolves a large share of "replication looks completely dead" tickets.

**Phase 3 — Confirm connectivity, with platform-specific proxy awareness.** Test the VM-to-appliance ports (VMware: 443, 9443) or host-to-Azure outbound (Hyper-V: 443, plus the URL allow-list). Explicitly rule in/out an authentication proxy — remember Hyper-V has zero support for one.

**Phase 4 — Classify the specific error against platform-specific behavior.** For Hyper-V, this means immediately checking whether the error falls into the non-recoverable bucket (no self-healing, ever) versus recoverable (will retry on its own with back-off) — this single distinction changes whether you wait or act.

**Phase 5 — Validate the fix took effect, not just that you made a change.** Re-pull `ReplicationHealth`/`ProtectionState` after any remediation; for VMware Configuration Issues-style panels, remember validators can run on a periodic cycle rather than instantly (mirrors the same caution documented for A2A in `SiteRecovery-A.md`).

**Phase 6 — For any failover/failback ticket, confirm which stage of the sequence you're actually on.** Both platforms have multi-stage failback sequences with a mandatory step that's easy to skip (VMware: reprotect; Hyper-V with VMM: network mapping before failover) — read the Jobs tab rather than assuming based on symptoms alone.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Initial setup: VMware Modernized (new deployment)</summary>

```powershell
# 1. Create a NEW Recovery Services vault — do not reuse an existing Classic vault
$vault = New-AzRecoveryServicesVault -ResourceGroupName "<rg>" -Name "<newVaultName>" -Location "<region>"

# 2. Deploy the ASR replication appliance on-premises (OVA import into vSphere) — done outside
#    PowerShell, via the vault's Site Recovery Infrastructure > "Discover and add servers" flow.
#    The appliance must reach vCenter/ESXi and the required outbound URLs (see Command Cheat
#    Sheet below for the allow-list).

# 3. Once the appliance registers and discovers VMware VMs, create a replication policy
$policy = New-AzRecoveryServicesAsrPolicy -Name "<policyName>" -AzureToVMware `
  -RecoveryPointRetentionInHours 24 -ApplicationConsistentSnapshotFrequencyInHours 4

# 4. Enable replication for a discovered VM (cmdlet shape varies by exact module version —
#    confirm current parameter set with Get-Help New-AzRecoveryServicesAsrReplicationProtectedItem
#    -Full against the installed Az.RecoveryServices version before running against production)
```

**Rollback:** A vault with no protected items can simply be deleted. Once VMs are actively replicating, disabling replication for an individual VM removes that VM's replicated data in Azure without affecting the source VM.

</details>

<details><summary>Playbook 2 — Initial setup: Hyper-V (with VMM)</summary>

```powershell
# 1. Create/confirm the Recovery Services vault
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "<rg>" -Name "<vaultName>"
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

# 2. Install the Site Recovery Provider on the VMM server, and register the VMM server
#    with the vault (vault download key required — generated from the portal, done once
#    per registration, outside PowerShell)

# 3. Install the Recovery Services agent on every Hyper-V host/cluster node managed by
#    that VMM server (MSI install, done per-host, outside PowerShell)

# 4. Map VMM logical networks / VM networks to Azure virtual networks BEFORE any failover
#    is attempted — this is a portal-driven mapping step under the vault's network mapping
#    blade; there is no equivalent "just fix it after failover" path
```

**Rollback:** Uninstalling the Provider/agent stops new replication but doesn't retroactively delete already-replicated data in Azure; disable replication for individual VMs first if a full teardown is required.

</details>

<details><summary>Playbook 3 — Migrate from Classic to Modernized VMware (existing replication)</summary>

```
1. Review required infrastructure and minimum component versions for the Modernized target
2. Deploy the ASR replication appliance against a NEW vault (not the existing Classic vault)
3. Prepare the Classic vault (source of the migration) per Microsoft's documented steps
4. Prepare the Modernized vault (target, where the appliance is registered)
5. Trigger migration for each existing replicated machine — the smart replication mechanism
   transfers only differential data, not a full re-seed, for machines already protected
6. Validate replication health on the Modernized side before decommissioning anything on
   the Classic side
```

**Rollback:** Until the final cutover step, Classic-side replication continues unaffected — this allows a staged migration rather than a single flag-day cutover. After 30 Mar 2026, there is no rollback path; Classic capability is retired outright.

</details>

<details><summary>Playbook 4 — Recover a Hyper-V VM stuck on a non-recoverable error</summary>

```powershell
# 1. Pull the exact error text — do not proceed on assumption
$rpi = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName "<vmName>" -ProtectionContainer $container
$rpi | Select-Object FriendlyName, ReplicationHealth

# 2. Broken VHD chain -> disable and re-enable replication for the affected VM (forces a
#    fresh initial replication of the affected disk; communicate bandwidth/time impact first)

# 3. Invalid replica VM state -> inspect the replica VM directly on the target-side
#    Hyper-V infrastructure; a manually modified replica breaks the relationship and
#    typically also requires disable/re-enable

# 4. Network auth/authorization errors -> re-validate Provider/agent registration
#    credentials against the vault; re-register if credentials have rotated/expired

# 5. VM not found (standalone hosts) -> confirm the source VM wasn't renamed, moved, or
#    deleted outside Site Recovery's awareness; re-protect under the correct current name
#    if it was renamed
```

**Rollback:** Disable/re-enable replication re-seeds that VM from scratch — treat it as a full data-transfer operation, not a quick fix, when sizing the maintenance window.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects on-premises-to-Azure DR evidence for escalation — platform-agnostic.
#>
param(
    [Parameter(Mandatory)][string]$VaultResourceGroupName,
    [Parameter(Mandatory)][string]$VaultName,
    [string]$OutputPath = "."
)
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName -Name $VaultName
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

$fabrics = Get-AzRecoveryServicesAsrFabric
$evidence = foreach ($fabric in $fabrics) {
    $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric
    foreach ($c in $containers) {
        Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $c |
          Select-Object FriendlyName, ProtectionState, ReplicationHealth,
            @{N='FabricType';E={$fabric.FabricSpecificDetails.GetType().Name}},
            @{N='FabricFriendlyName';E={$fabric.FriendlyName}}
    }
}
$recentJobs = Get-AzRecoveryServicesAsrJob | Sort-Object StartTime -Descending | Select-Object -First 25
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$evidence | Export-Csv -Path (Join-Path $OutputPath "OnPremDR-ProtectedItems-$stamp.csv") -NoTypeInformation
$recentJobs | Export-Csv -Path (Join-Path $OutputPath "OnPremDR-RecentJobs-$stamp.csv") -NoTypeInformation
Write-Host "Evidence written to $OutputPath (2 files, stamp $stamp)"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Set-AzRecoveryServicesAsrVaultContext -Vault $vault` | Required first, every session — nothing else works without it |
| `Get-AzRecoveryServicesAsrFabric` | Identify platform/architecture (VMware vs. Hyper-V/VMM) and appliance/host heartbeat |
| `Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric` | List containers under a fabric |
| `Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container` | Per-VM protection state and replication health |
| `Get-AzRecoveryServicesAsrRecoveryPoint -ReplicationProtectedItem $rpi` | List recovery points for a specific VM |
| `Get-AzRecoveryServicesAsrJob \| Where-Object State -eq Failed` | Recent failed jobs across replication/failover/resync |
| `Start-AzRecoveryServicesAsrUnplannedFailoverJob` | Trigger an unplanned failover |
| `Start-AzRecoveryServicesAsrTestFailoverJob` | Trigger a test failover (isolated network) |
| `Update-AzRecoveryServicesAsrProtectionDirection` | Reverse protection direction (reprotect) |
| `Get-Service \| Where-Object DisplayName -match "Site Recovery\|Recovery Services"` | Local service check — Hyper-V host/VMM server, or the VMware appliance |
| `Test-NetConnection -ComputerName <target> -Port 443/9443` | Connectivity check — appliance management/data ports (VMware) or Azure endpoints (both) |
| Portal: vault > Site Recovery Infrastructure | Confirm Classic (Configuration Server) vs. Modernized (ASR replication appliance) for VMware |
| Portal: select VM > Resynchronize | Manually trigger resync instead of waiting for the overnight window (no PowerShell equivalent) |

---
## 🎓 Learning Pointers

- **This is genuinely two products wearing one name.** Treat a VMware ticket and a Hyper-V ticket as different troubleshooting domains from the first triage step — the on-premises component stack, retry behavior, proxy support, and even the failback sequence are all different.
- **The Classic-to-Modernized VMware deadline is a hard, dated retirement, not an evergreen recommendation.** New-replication enablement is already blocked; build migration into any Classic-flagged ticket's resolution plan rather than treating it as optional.
- **A Modernized VMware appliance's vault requirement is a one-way door.** Registering against a reused Classic vault isn't a misconfiguration you fix in place — the vault itself has to be recreated, so get this right during initial planning.
- **Hyper-V's non-recoverable/recoverable error split is a genuinely useful mental model**, not just internal Microsoft plumbing — it tells you directly whether to wait (recoverable, will retry with back-off) or act now (non-recoverable, will sit broken forever otherwise).
- **No outbound auth proxy support on Hyper-V is absolute, not a version/config gap to search for a workaround to.** Route around it at the network layer instead of hunting for a Hyper-V-side proxy authentication setting that doesn't exist.
- **The VSS Copy Only (VSS_BT_COPY) detail matters for any VMware VM also running independent SQL backups** — it's a deliberate design choice so ASR's app-consistent snapshots don't disturb SQL's own backup sequence numbering; useful context when a DBA asks whether ASR will interfere with their existing backup job.
- Related: [VMware to Azure disaster recovery architecture - Modernized](https://learn.microsoft.com/en-us/azure/site-recovery/vmware-azure-architecture-modernized), [Deprecation of classic experience to protect VMware and physical machines](https://learn.microsoft.com/en-us/azure/site-recovery/vmware-physical-azure-classic-deprecation), [Hyper-V to Azure disaster recovery architecture](https://learn.microsoft.com/en-us/azure/site-recovery/hyper-v-azure-architecture), [Common questions for Hyper-V disaster recovery](https://learn.microsoft.com/en-us/azure/site-recovery/hyper-v-azure-common-questions), [Support matrix for VMware/physical disaster recovery](https://learn.microsoft.com/en-us/azure/site-recovery/vmware-physical-azure-support-matrix)
