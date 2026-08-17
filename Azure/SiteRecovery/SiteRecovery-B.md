# Azure Site Recovery (Azure-to-Azure) — Hotfix Runbook (Mode B: Ops)
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

Run these from Azure PowerShell (Az module) with a connected context and the vault context set. All five run in well under 60 seconds against a single vault. **Check replication health before anything else** — most tickets that look like "the VM is broken" are actually a replication-pipeline problem, not a compute problem.

```powershell
# 1. Set vault context (required before any other ASR cmdlet works)
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "<vaultRg>" -Name "<vaultName>"
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

# 2. Replication health + protection state for every replicated item in a container
$container = Get-AzRecoveryServicesAsrProtectionContainer -Fabric (Get-AzRecoveryServicesAsrFabric -Name "<fabricName>")
Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container |
  Select-Object FriendlyName, ProtectionState, ReplicationHealth

# 3. Current RPO and last recovery point for a specific VM
$rpi = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName "<vmName>" -ProtectionContainer $container
$rpi | Select-Object FriendlyName, ReplicationHealth, @{N='RPOInSeconds';E={$_.ProviderSpecificDetails.RPOInSeconds}}
Get-AzRecoveryServicesAsrRecoveryPoint -ReplicationProtectedItem $rpi | Sort-Object RecoveryPointTime -Descending | Select-Object -First 3 RecoveryPointType, RecoveryPointTime

# 4. Recent job failures (failover/reprotect/config-validation jobs, last 24h)
Get-AzRecoveryServicesAsrJob | Where-Object { $_.State -eq "Failed" -and $_.StartTime -gt (Get-Date).AddHours(-24) } |
  Select-Object DisplayName, TargetObjectName, StartTime, StateDescription

# 5. Confirm the source VM's Mobility Service extension is actually reporting (Azure VM extension layer, not the ASR control plane)
Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" | Where-Object Publisher -like "*SiteRecovery*" |
  Select-Object Name, ProvisioningState, PublicSettings
```

| What you see | What it means |
|---|---|
| `ReplicationHealth` = `Critical` | One or more error symptoms are actively blocking replication progress — go to the matching Fix below based on the specific error ID |
| `ReplicationHealth` = `Warning` | Something might impact replication soon but hasn't stopped it yet — don't ignore, but not an active incident |
| `ProtectionState` isn't `Protected` (e.g. `InitialReplicationInProgress`, `FailedOver`) | The item isn't in a normal steady-state — check which state it's actually in before assuming a fault; `FailedOver` is expected post-failover, not an error |
| Error ID 153007 in job/error details | No crash-consistent recovery point in 60 minutes — almost always high data churn or a network path problem to the cache storage account — Fix 1/2 |
| Error ID 153006 in job/error details | No app-consistent recovery point — a VSS problem on the source VM, not the block-level replication itself — Fix 3/4 |
| Failover fails with `BookmarkNotFound` | The recovery point you tried to fail over to predates a disk tier/SKU change — Fix 5 |
| `RPOInSeconds` is large and climbing but `ReplicationHealth` still shows `Normal`/`Healthy` | RPO breach alerting has its own threshold separate from health state — don't wait for health to flip Critical before investigating a climbing RPO |
| Extension `ProvisioningState` isn't `Succeeded` | This is a `Compute/VMExtensions-B.md` problem first — confirm the VM Agent and extension pipeline are healthy before troubleshooting ASR-specific symptoms |
| No replication health data at all / cmdlets return nothing | Vault context likely isn't set for this PowerShell session — re-run Triage step 1 before concluding anything is broken |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Recovery Services Vault (control plane — vault context must be set per session)
  │
  ▼
Fabric (one per Azure region) → Protection Container → Container Mapping → Replication Policy
  │  Each of these is a separate object; a missing or misconfigured mapping/policy
  │  blocks replication even if the fabric and containers both look fine.
  ▼
Mobility Service extension, installed on the source VM
  │  This is a standard Azure VM extension — it depends on the VM Agent/WireServer
  │  layer (see Compute/VMExtensions-A.md) exactly like any other extension.
  ▼
Cache storage account, in the SOURCE region
  │  Every disk write is staged here FIRST, before being shipped to the target
  │  region. This is the actual data-plane bottleneck for most churn/latency
  │  issues — not the vault, and not the target region.
  ▼
Target region: managed disks (or target storage account for unmanaged disks)
  │  Recovery points are materialized here. A disk tier/SKU change here can
  │  silently invalidate older recovery points (see Fix 5).
  ▼
Replication health (Healthy / Warning / Critical) + RPO
  Computed end-to-end from every layer above succeeding continuously —
  a single broken layer anywhere in the chain degrades this the same way.
```

Key failure points:
- The cache storage account sits in the **source** region, not the vault's region and not the target region — a lot of tickets waste time checking the wrong region's network path
- Fabric/Container/Mapping/Policy objects are created once during setup and rarely touched again — when they ARE the problem, it's almost always because someone deleted or recreated a network/storage resource they referenced, not because the objects themselves degraded
- The vault context (`Set-AzRecoveryServicesAsrVaultContext`) is **per PowerShell session** — every fresh session needs it re-set before any `Asr*` cmdlet will return meaningful data

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Set vault context and pull fleet-wide replication health**
```powershell
Set-AzRecoveryServicesAsrVaultContext -Vault (Get-AzRecoveryServicesVault -ResourceGroupName "<vaultRg>" -Name "<vaultName>")
```
Expected: no error. If this fails, nothing else in this file will work — resolve vault access/permissions first.

**Step 2 — Classify the specific error, don't guess from "replication is broken"**
```powershell
$rpi = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName "<vmName>" -ProtectionContainer $container
$rpi.ReplicationHealth
```
Expected: `Normal`/`Healthy`, or a specific error ID surfaced in the portal's **Errors** tab for the item (153007, 153006, `BookmarkNotFound`, etc.) — match against the Triage table above before picking a fix.

**Step 3 — Confirm whether this is a data-churn or network problem (for 153007)**
```powershell
# On the source VM, check write throughput against ASR's documented limits
Get-Counter '\PhysicalDisk(*)\Disk Write Bytes/sec'
```
Expected: sustained writes above ~10 MB/s (Premium) or ~2 MB/s (Standard) per disk without High Churn support enabled point at data churn, not network. Use `AzCopy` to test raw upload throughput to the cache storage account to rule out network latency separately.

**Step 4 — Confirm VSS health on the source VM (for 153006)**
```powershell
Get-Service | Where-Object { $_.Name -match "VSS|InMage" } | Select-Object Name, Status, StartType
```
Expected: VSS and the Azure Site Recovery VSS Provider both `Running`/`Automatic`. Anything else routes to Fix 4.

**Step 5 — Check for a disk tier/SKU change before trusting an older recovery point**
```powershell
(Get-AzDisk -ResourceGroupName "<rg>" -DiskName "<targetDiskName>").TimeCreated
```
Expected: compare against the recovery point's timestamp — if the disk was resized/tier-changed AFTER the recovery point you're trying to fail over to, expect `BookmarkNotFound` and pick a newer recovery point instead.

**Step 6 — Confirm configuration issues have actually re-validated, not just been fixed**
```powershell
Get-AzRecoveryServicesAsrJob | Where-Object DisplayName -like "*Validat*" | Sort-Object StartTime -Descending | Select-Object -First 1
```
Expected: a validation job newer than your fix. The portal's Configuration Issues panel is driven by a validator that runs **every 12 hours by default** — a fix you just made won't clear the dashboard until the next validator pass unless you force it (portal: refresh icon next to Configuration Issues).

**Step 7 — Confirm test failover has actually been run recently**
```powershell
Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container |
  Select-Object FriendlyName, @{N='LastTestFailover';E={$_.ProviderSpecificDetails.LastTestFailoverStatus}}
```
Expected: a successful test failover within the last 6 months (Microsoft's own recommended cadence). "Never tested" is itself an escalation-worthy finding, not just a diagnostic footnote.

---
## Common Fix Paths

<details><summary>Fix 1 — High data churn (Error 153007)</summary>

**Cause:** The data change rate on one or more disks exceeds Site Recovery's supported churn limit for that disk's size/tier, so recovery points stop being created.

```powershell
# Confirm which disk is churning via the portal's Events (last 72 hours) view first, then:

# Option A — exclude the noisy disk from replication (requires disabling and re-enabling replication)
# See: https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-exclude-disks

# Option B — increase the replica disk size to raise the churn ceiling (Premium managed disks only)
# The churn limit is tied to DISK SIZE, not performance tier — changing tier alone does nothing.
# Example: a 128 GiB Premium disk (P10) has an ~8 MB/s churn ceiling; resizing to 512 GiB raises it,
# even if you don't also change the performance tier.
```

**Rollback note:** Excluding a disk stops it from being protected at all — only do this for genuinely non-critical disks (e.g. scratch/temp volumes). Resizing the replica disk is not reversible without another resize; confirm the new size against actual observed churn before committing.

</details>

<details><summary>Fix 2 — Network latency or throttling to the cache storage account</summary>

**Cause:** Uploading replicated data from the VM to the cache storage account is slower than the ~4 MB/3 sec baseline Site Recovery expects — usually an NVA (network virtual appliance) throttling outbound traffic, not a genuine bandwidth shortage.

```powershell
# Test raw upload throughput with AzCopy from the source VM
azcopy bench "https://<cacheStorageAccount>.blob.core.windows.net/<container>?<sasToken>" --mode=Upload

# If an NVA is in the outbound path, add a Storage service endpoint on the VM's subnet
# so replication traffic bypasses the NVA entirely, rather than trying to raise NVA throughput limits.
```

**Rollback note:** Adding a service endpoint is non-destructive and doesn't change existing NSG allow/deny behavior — it only changes the route replication traffic takes.

</details>

<details><summary>Fix 3 — App-consistent recovery point failures (Error 153006) — known VSS/workload issues</summary>

**Cause:** Crash-consistent replication (block-level, every 5 minutes) is a separate track from app-consistent recovery points (VSS snapshot-based, on your policy's configured frequency) — this error means only the app-consistent track is failing.

```
Known causes, in order of frequency:
- SQL Server 2008/2008 R2: documented non-component VSS backup issue — see KB4504103
- Any SQL Server version with AUTO_CLOSE databases: see KB4504104
- SQL Server 2016/2017: fixed by Cumulative Update 16 for SQL Server 2017
- Storage Spaces Direct (S2D) configurations: app-consistent recovery points are
  NOT supported at all — reconfigure the replication policy to crash-consistent only
- Linux servers: app-consistency requires a custom pre/post script — it is not
  automatic the way it is on Windows
```

**Rollback note:** N/A — these are workload-specific compatibility issues, not configuration you're changing on the ASR side. Crash-consistent replication continues unaffected while you work through the underlying cause.

</details>

<details><summary>Fix 4 — VSS Provider not installed / disabled / not registered</summary>

**Cause:** Site Recovery's own VSS Provider service (installed alongside the Mobility Service agent) isn't running, so it can't request the VSS snapshot needed for an app-consistent recovery point.

```console
:: On the source VM, as administrator

:: Error 2147754756 (NOT_REGISTERED) — reinstall the provider
"C:\Program Files (x86)\Microsoft Azure Site Recovery\agent\InMageVSSProvider_Uninstall.cmd"
"C:\Program Files (x86)\Microsoft Azure Site Recovery\agent\InMageVSSProvider_Install.cmd"

:: Then, regardless of which specific VSS error you started from:
:: 1. Verify VSS Provider service startup type is Automatic
:: 2. Restart these services in order:
sc config VSS start= auto
net stop VSS
net start VSS
net stop "Azure Site Recovery VSS Provider"
net start "Azure Site Recovery VSS Provider"
net stop VDS
net start VDS
```

**Rollback note:** Reinstalling the VSS Provider does not touch replicated data or crash-consistent replication — it only affects the app-consistent snapshot mechanism.

</details>

<details><summary>Fix 5 — Failover fails with BookmarkNotFound after a disk tier/SKU change</summary>

**Cause:** Changing a replica disk's tier or SKU causes the underlying disk resource provider to regenerate its snapshots — recovery points created BEFORE that change reference bookmarks that no longer exist.

```powershell
# List available recovery points and pick one created AFTER the tier/SKU change
$rpi = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName "<vmName>" -ProtectionContainer $container
Get-AzRecoveryServicesAsrRecoveryPoint -ReplicationProtectedItem $rpi |
  Sort-Object RecoveryPointTime -Descending | Select-Object RecoveryPointType, RecoveryPointTime

# Retry failover using a newer recovery point
$newRP = (Get-AzRecoveryServicesAsrRecoveryPoint -ReplicationProtectedItem $rpi | Sort-Object RecoveryPointTime -Descending)[0]
Start-AzRecoveryServicesAsrUnplannedFailoverJob -ReplicationProtectedItem $rpi -Direction PrimaryToRecovery -RecoveryPoint $newRP
```

**Rollback note:** N/A — this is a selection problem, not a destructive action. Note that recovery-point pruning runs on a schedule, so a stale bookmarked recovery point may still be listed in the portal for a while even though it can no longer be used.

</details>

<details><summary>Fix 6 — Mobility Service heartbeat lost due to expired AAD tenant/client ID</summary>

**Cause:** The Mobility Service agent's local config file (`RCMInfo.conf`) references an Azure AD tenant/client ID pairing that's since expired or rotated — the agent stops reporting heartbeats even though it's still running.

```powershell
# 1. Retrieve current tenant/client IDs from the protected item's own API response
# GET https://management.azure.com/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.RecoveryServices/vaults/<vault>/replicationFabrics/<fabric>/replicationProtectionContainers/<container>/replicationProtectedItems/<item>?api-version=2025-01-01
# Note the values for mobilityAgentTenantIdToUpdate and mobilityAgentClientIdToUpdate

# 2. On the source VM, edit (Windows):
#    C:\ProgramData\Microsoft Azure Site Recovery\Config\RCMInfo.conf
#    Update AADTenantId, AADClientId, and the tenant segment of AADAudienceUri
#    (Linux equivalent: /usr/local/InMage/config/RCMInfo.conf)

# 3. Restart the agent services
#    Windows: "InMage Scout VX Agent - Sentinel/Outpost", "InMage Scout Application Service"
#    Linux: vxagent, appservice
```

**Rollback note:** Keep a copy of the original `RCMInfo.conf` before editing — an incorrect tenant/client ID pairing will keep the agent from reporting entirely, which is a worse state than the expired-ID heartbeat failure you started with.

</details>

<details><summary>Fix 7 — Configuration issue fixed but the dashboard still shows it</summary>

**Cause:** The Configuration Issues panel (missing config, missing resources, subscription quota, software updates) is driven by a periodic validator that runs **every 12 hours by default**, not in real time.

```
Portal: Recovery Services Vault > Site Recovery > Configuration Issues > refresh icon
(forces the validator to run immediately instead of waiting for the next 12-hour cycle)
```

**Rollback note:** N/A — this is a read-only diagnostic refresh, not a configuration change.

</details>

<details><summary>Fix 8 — Reprotect and fail back after a failover</summary>

**Cause:** After a failover, the failed-over Azure VM is running unprotected in the recovery region until you explicitly reverse the replication direction — this is not automatic.

```powershell
# 1. Confirm the failover was committed
Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName "<vmName>" -ProtectionContainer $recoveryContainer |
  Select-Object ProtectionState   # should show FailedOver / Commit already run

# 2. Create a cache storage account in the (now-source) recovery region if one doesn't exist
$cacheSA = New-AzStorageAccount -Name "<name>" -ResourceGroupName "<rg>" -Location "<recoveryRegion>" -SkuName Standard_LRS -Kind Storage

# 3. Reverse the protection direction — this starts reprotection back toward the original region
Update-AzRecoveryServicesAsrProtectionDirection -ReplicationProtectedItem $rpi -AzureToAzure `
  -ProtectionContainerMapping $reverseMapping -LogStorageAccountId $cacheSA.Id -RecoveryResourceGroupID $originalRG.ResourceId

# 4. Once reprotection completes, a second failover in the reverse direction completes the failback
```

**Rollback note:** Reprotection does not touch the currently-running failed-over VM's data — it only establishes a new outbound replication stream from it. Do not skip this step and assume you can "just fail back" later; without reprotection there is no replicated data to fail back from.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Azure Site Recovery (A2A)
Vault / subscription / resource group: ____________
Protected item (VM) friendly name: ____________
ReplicationHealth / ProtectionState at time of ticket: ____________
Error ID(s) shown in the portal Errors tab (exact text): ____________
RPO at time of ticket (seconds/minutes): ____________
Last successful recovery point timestamp + type (crash/app-consistent): ____________
Last test failover date and result: ____________
Cache storage account name + region: ____________
Recent disk tier/SKU changes on source or target disks (yes/no, date): ____________
Steps already attempted:
[ ] Confirmed vault context set and replication health pulled fresh (not cached from earlier)
[ ] Classified the exact error ID rather than assuming "replication is broken"
[ ] Checked data churn rate against documented limits (if 153007)
[ ] Checked VSS service health on the source VM (if 153006)
[ ] Forced a Configuration Issues validator refresh
[ ] Confirmed whether a disk tier/SKU change predates the affected recovery point
```

---
## 🎓 Learning Pointers

- **Crash-consistent and app-consistent recovery points are two independent tracks, not one pipeline with two names.** Crash-consistent replication (block-level, every 5 minutes) can be completely healthy while app-consistent recovery points fail entirely (Error 153006) due to a VSS problem specific to the workload — don't assume a VSS failure means data is being lost.
- **The churn limit is a property of disk SIZE, not performance tier.** Bumping a Premium SSD's performance tier without also increasing its size does nothing to raise the churn ceiling — a subtle trap when a client "already upgraded performance" and still sees 153007.
- **The cache storage account lives in the source region, and that's where the real network bottleneck usually is** — not the vault's region, and not the target region. Checking NSGs/firewalls on the wrong region wastes real troubleshooting time.
- **A disk tier or SKU change silently invalidates older recovery points.** The disk resource provider regenerates snapshots on tier change, so a `BookmarkNotFound` failover failure is often really "you picked a recovery point from before a routine disk resize," not a genuine replication defect.
- **The Configuration Issues dashboard is up to 12 hours stale by design.** A fix that looks like it "didn't work" may just be waiting on the next validator pass — force the refresh before escalating.
- **Failover does not automatically protect the VM again.** A failed-over Azure VM runs unprotected until you explicitly reverse replication (reprotect) — this is a common gap that leaves clients with zero DR coverage for days after an otherwise-successful failover.
- Related: [Troubleshoot replication of Azure VMs with Azure Site Recovery](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-troubleshoot-replication), [Azure Site Recovery dashboard and built-in alerts](https://learn.microsoft.com/en-us/azure/site-recovery/site-recovery-monitor-and-troubleshoot), [Disaster recovery for Azure VMs using Azure PowerShell](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-powershell), [General questions about the Azure Site Recovery service](https://learn.microsoft.com/en-us/azure/site-recovery/site-recovery-faq)
