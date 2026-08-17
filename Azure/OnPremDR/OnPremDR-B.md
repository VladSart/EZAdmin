# On-Premises to Azure Disaster Recovery (VMware & Hyper-V) — Hotfix Runbook (Mode B: Ops)
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

**Identify the platform and architecture FIRST — the two on-prem-to-Azure paths share almost nothing at the component level.** VMware/physical machines replicate through an on-premises **ASR replication appliance** (a single OVA hosting several roles); Hyper-V replicates through a **Provider + Recovery Services agent** installed directly on the Hyper-V host(s) or VMM server, with no separate appliance box at all. Applying a VMware fix to a Hyper-V ticket (or vice versa) wastes time — confirm which one you're on before doing anything else.

```powershell
# 1. Set vault context (required before any other ASR cmdlet works)
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "<vaultRg>" -Name "<vaultName>"
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

# 2. Identify the fabric type — this tells you which architecture you're troubleshooting
Get-AzRecoveryServicesAsrFabric | Select-Object FriendlyName, FabricSpecificDetails, Health

# 3. Replication health + protection state for every replicated item in a container
$container = Get-AzRecoveryServicesAsrProtectionContainer -Fabric (Get-AzRecoveryServicesAsrFabric -Name "<fabricName>")
Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container |
  Select-Object FriendlyName, ProtectionState, ReplicationHealth

# 4. Recent job failures (replication/failover/resync jobs, last 24h)
Get-AzRecoveryServicesAsrJob | Where-Object { $_.State -eq "Failed" -and $_.StartTime -gt (Get-Date).AddHours(-24) } |
  Select-Object DisplayName, TargetObjectName, StartTime, StateDescription

# 5. VMware only — confirm this vault is on the Modernized experience, not Classic (Classic retires 30 Mar 2026)
(Get-AzRecoveryServicesVault -ResourceGroupName "<vaultRg>" -Name "<vaultName>").Properties |
  Select-Object -ExpandProperty VaultProperties -ErrorAction SilentlyContinue
# If PowerShell doesn't surface this cleanly, check the portal: vault > Site Recovery Infrastructure >
# "Recovery Services deployment" or the presence of a Configuration Server (Classic) vs. an
# ASR replication appliance (Modernized) under "For VMware/Physical machines"
```

| What you see | What it means |
|---|---|
| Fabric type shows a VMware/Physical site | Modernized architecture — on-prem component is the ASR replication appliance. Go to VMware fixes below |
| Fabric type shows a Hyper-V site or VMM cloud | On-prem components are the Site Recovery Provider + Recovery Services agent, installed directly on the host/VMM server — no appliance exists to check. Go to Hyper-V fixes below |
| Vault still shows a Configuration Server object | This customer is still on the **Classic** VMware experience — support for Classic ends 15 Mar 2026, capability fully retires 30 Mar 2026, PowerShell enable-replication already blocked from 31 Jan 2026 — flag for migration regardless of the ticket's original symptom (Fix 1) |
| `ReplicationHealth` = `Critical` | Something is actively blocking replication — match the specific error against the fixes below rather than guessing |
| VM status shows `Critical` on a Hyper-V-protected item with no active job | Hyper-V classifies some errors as **non-recoverable** — no automatic retry happens, ever, until you intervene (Fix 5) |
| Item marked for resynchronization | Expected after a network blip, force shutdown, or disk resize on either platform — not itself a fault; only escalate if resync has been pending outside the automatic overnight window for multiple nights (Fix 6) |
| Replication data not reaching Azure but the appliance/agent shows healthy | Check outbound connectivity/proxy next — VMware Modernized supports an authentication proxy, **Hyper-V does not support any outbound auth proxy at all** (Fix 7) |
| No replication health data at all / cmdlets return nothing | Vault context likely isn't set for this PowerShell session — re-run Triage step 1 before concluding anything is broken |

---
## Dependency Cascade

<details><summary>What must be true — VMware/Physical (Modernized)</summary>

```
Recovery Services Vault (MUST be a NEW vault — never reuse an existing Classic vault
for the Modernized appliance registration; this is the single most common setup mistake)
  │
  ▼
ASR replication appliance (single on-prem OVA/VM — the whole on-prem stack lives here)
  │  ├─ Proxy server        — proxy channel between Mobility agent and Azure Site Recovery
  │  ├─ Discovered items     — talks to vCenter, feeds inventory to the cloud service
  │  ├─ Re-protection server — coordinates reprotect/failback
  │  ├─ Process server       — caches + compresses data before it leaves the site
  │  ├─ Recovery Service agent — registers the appliance, monitors component health
  │  └─ Site Recovery provider — orchestrates reprotect (original vs. alternate location)
  ▼
vCenter / ESXi hosts (appliance discovers VMs here)
  │
  ▼
Mobility Service agent, installed on EACH replicated VMware VM
  │  VM → appliance: HTTPS 443 inbound (management), HTTPS 9443 inbound (replication data,
  │  port is configurable). Appliance → Azure: HTTPS 443 outbound only.
  ▼
Cache storage account, in the SOURCE region (same role as in Azure-to-Azure ASR —
  see Azure/SiteRecovery/SiteRecovery-A.md for the shared downstream architecture)
  ▼
Managed disk (asrseeddisk) in the target region → recovery points → ReplicationHealth
```

</details>

<details><summary>What must be true — Hyper-V (no appliance — two variants)</summary>

```
Without VMM:
  Recovery Services Vault
    │
    ▼
  Azure Site Recovery Provider + Recovery Services agent
  installed directly on EACH standalone Hyper-V host
    │  Nothing is installed inside the guest VM at all — replication is native
    │  Hyper-V Replica, tracked via .hrl (Hyper-V Replication Log) files per disk
    ▼
  Cache storage account (source region) → recovery points → ReplicationHealth

With VMM:
  Recovery Services Vault
    │
    ▼
  Site Recovery Provider — installed on the VMM SERVER (one install covers every
  Hyper-V host/cluster the VMM server manages)
    │
    ▼
  Recovery Services agent — installed on EACH Hyper-V host/cluster node
    │
    ▼
  VMM logical networks / VM networks — must be mapped to Azure virtual networks
  BEFORE failover, or failed-over VMs land with no network mapping at all
    │
    ▼
  Cache storage account (source region) → recovery points → ReplicationHealth
```

Key failure points:
- Hyper-V has **no separate appliance to reboot or reinstall** — when a VMware-style "just restart the appliance services" instinct kicks in on a Hyper-V ticket, there's no appliance object to act on; the fix is always on the Provider/agent installed on the host or VMM server itself
- The Modernized VMware vault is a hard, one-time requirement — an appliance registered against a Classic vault does not work and cannot be fixed after the fact; the vault has to be recreated
- VMM network mapping is configured once and rarely revisited — when a failover produces VMs with no NIC/IP, this is almost always the actual cause, not a compute or replication fault

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Set vault context and identify the fabric/platform**
```powershell
Set-AzRecoveryServicesAsrVaultContext -Vault (Get-AzRecoveryServicesVault -ResourceGroupName "<vaultRg>" -Name "<vaultName>")
Get-AzRecoveryServicesAsrFabric | Select-Object FriendlyName, FabricSpecificDetails
```
Expected: no error, and a fabric type that tells you VMware vs. Hyper-V (with or without VMM). If this fails, resolve vault access first — nothing else below works without it.

**Step 2 — VMware: confirm the appliance itself is registered and healthy**
```powershell
Get-AzRecoveryServicesAsrFabric | Select-Object FriendlyName, Health, @{N='LastHeartbeat';E={$_.FabricSpecificDetails.LastHeartbeat}}
```
Expected: `Health` = `Normal` and a heartbeat within the last few minutes. A stale heartbeat means the appliance itself is offline/unreachable — troubleshoot the appliance VM (powered on, network reachable, services running) before looking at individual VM replication.

**Step 3 — Hyper-V: confirm the Provider and Recovery Services agent services are running**
```powershell
# Run locally on the Hyper-V host (no VMM) or the VMM server (with VMM)
Get-Service | Where-Object { $_.DisplayName -match "Site Recovery|Recovery Services" } | Select-Object Name, DisplayName, Status
```
Expected: both services `Running`. Either stopped explains a complete loss of replication reporting with no error surfaced in the portal beyond a stale heartbeat.

**Step 4 — Classify the specific error, don't guess from "replication is broken"**
```powershell
$rpi = Get-AzRecoveryServicesAsrReplicationProtectedItem -FriendlyName "<vmName>" -ProtectionContainer $container
$rpi.ReplicationHealth
```
Expected: `Normal`/`Healthy`, or a specific error surfaced in the portal's **Errors** tab for the item — match it against the fixes below rather than treating "Critical" as one undifferentiated problem.

**Step 5 — Hyper-V only: distinguish non-recoverable from recoverable errors**
```
Non-recoverable (VM shows Critical, no retry happens): broken VHD chain, invalid replica VM
state, network authentication/authorization errors, VM-not-found (standalone hosts).
Recoverable (automatic retry with backoff — 1, 2, 4, 8, 10 min, then every 30 min): network
errors, low disk space, low memory conditions on the host.
```
If the item has sat `Critical` for longer than the recoverable back-off window with no change, it's a non-recoverable error waiting on you — see Fix 5.

**Step 6 — Confirm outbound connectivity, and don't assume proxy support is the same on both platforms**
```
VMware Modernized: authentication proxy IS supported for outbound connectivity.
Hyper-V: authentication proxy is NOT supported at all — any auth-required proxy in the
outbound path will silently break replication regardless of URL allow-listing.
```

**Step 7 — Confirm resynchronization isn't just pending its normal overnight window**
```powershell
Get-AzRecoveryServicesAsrJob | Where-Object DisplayName -like "*Resynchron*" | Sort-Object StartTime -Descending | Select-Object -First 3
```
Expected: resync runs automatically outside office hours by default on both platforms. Only escalate if it's been pending across multiple nights, or trigger it manually from the portal (select the VM > **Resynchronize**) if the business needs it sooner.

---
## Common Fix Paths

<details><summary>Fix 1 — Customer is still on the Classic VMware experience (retiring 30 Mar 2026)</summary>

**Cause:** The vault predates the Modernized architecture and is using a Configuration Server/Process Server setup. Support for Classic ends 15 Mar 2026; the capability itself retires 30 Mar 2026; enabling NEW replication via Classic (portal and PowerShell) has already been blocked since 31 Jan 2026.

```
This is not a same-day fix — flag it as a migration project, not a ticket:
1. Confirm required infrastructure and minimum component versions for the target Modernized setup
2. Deploy a NEW Azure Site Recovery replication appliance against a NEW Recovery Services
   vault (never reuse the existing Classic vault)
3. Prepare both the Classic vault (source) and the Modernized vault (target) for migration
4. Trigger migration — a smart replication mechanism transfers only differential data,
   not a full re-seed, for machines already replicating
See: https://learn.microsoft.com/en-us/azure/site-recovery/move-from-classic-to-modernized-vmware-disaster-recovery
```

**Rollback note:** Migration doesn't touch the source VM or interrupt Classic replication until the cutover step — but don't start it against a live production DR dependency without a scheduled window; if migration fails to complete before 30 Mar 2026, replication health may be disrupted and Classic-side management (view/manage/DR operations) stops working entirely.

</details>

<details><summary>Fix 2 — ASR replication appliance unregistered, offline, or stale heartbeat (VMware Modernized)</summary>

**Cause:** The appliance VM is powered off, network-isolated, or one of its internal services has crashed.

```powershell
# On the appliance VM, as administrator — restart the core services in order
Get-Service | Where-Object { $_.DisplayName -match "Site Recovery|Recovery Services" } |
  Restart-Service -Force

# Confirm outbound reachability from the appliance to the required URLs (see OnPremDR-A.md
# for the full allow-list) — pay special attention to *.prod.migration.windowsazure.com
# (discovery) and *.blob.core.windows.net (data upload), the two most commonly missed entries
Test-NetConnection -ComputerName "management.azure.com" -Port 443
```

**Rollback note:** Restarting appliance services doesn't affect already-replicated data or existing recovery points — it only affects new data landing until the services come back up.

</details>

<details><summary>Fix 3 — Mobility Service agent not communicating (VMware VM)</summary>

**Cause:** The Mobility Service on the individual VM can't reach the appliance — usually port 9443 (replication data) blocked by host-based or network firewall, distinct from port 443 (management).

```powershell
# On the VMware VM
Test-NetConnection -ComputerName "<applianceIP>" -Port 9443
Test-NetConnection -ComputerName "<applianceIP>" -Port 443

Get-Service | Where-Object Name -like "*InMage*" | Select-Object Name, Status
```

**Rollback note:** N/A — this is connectivity troubleshooting, not a config change with a rollback path.

</details>

<details><summary>Fix 4 — Hyper-V Provider or Recovery Services agent disconnected</summary>

**Cause:** Either service stopped on the host (no VMM) or the VMM server (with VMM) — this is the direct Hyper-V equivalent of "the appliance is down," except there's no appliance object, only these two services.

```powershell
# Run on the affected Hyper-V host, or the VMM server if VMM-managed
Get-Service -Name "*AzureSiteRecovery*", "*DRA*" | Restart-Service -Force

# Re-register if a restart doesn't restore heartbeat within a few minutes — this requires
# re-running the Hyper-V site/VMM server registration from the vault's Site Recovery
# Infrastructure blade; it does not require re-doing initial replication
```

**Rollback note:** Restarting these services doesn't interrupt already-committed recovery points; only new delta replication pauses until they're back up.

</details>

<details><summary>Fix 5 — Hyper-V VM stuck Critical with a non-recoverable error</summary>

**Cause:** By design, non-recoverable errors (broken VHD chain, invalid replica VM state, network authentication/authorization failures, VM-not-found on standalone hosts) get **zero automatic retries** — the VM will sit Critical indefinitely without intervention.

```
1. Read the exact error text in the portal's Errors tab for the item — the four
   non-recoverable categories require different manual actions:
   - Broken VHD chain: usually requires disabling and re-enabling replication for
     that VM (forces a fresh initial replication for the affected disk)
   - Invalid replica VM state: check the replica VM's state directly in Hyper-V
     Manager on the target-side infrastructure; a manually-modified replica breaks
     the relationship
   - Network authentication/authorization errors: re-validate the Provider/agent's
     registration credentials against the vault
   - VM not found (standalone hosts only): confirm the source VM wasn't renamed,
     moved, or deleted on the Hyper-V host outside of Site Recovery's awareness
2. Once corrected, replication does NOT automatically resume from Critical —
   confirm via a fresh Get-AzRecoveryServicesAsrReplicationProtectedItem pull
```

**Rollback note:** Disabling/re-enabling replication for a single VM re-seeds that VM's initial replication from scratch — expect a full data transfer, not a delta, and communicate the bandwidth/time impact before doing it on a large VM.

</details>

<details><summary>Fix 6 — Resynchronization pending longer than expected</summary>

**Cause:** Both platforms mark a VM for resync after a network interruption, force shutdown, or (VMware) a disk resize, and both default to running it automatically outside office hours rather than immediately.

```powershell
# Force it manually instead of waiting for the next overnight window
# Portal: select the affected VM > Resynchronize
# There is no PowerShell cmdlet equivalent for triggering resync on demand — use the portal
```

**Rollback note:** N/A — resync only transfers delta/checksum-verified data, it doesn't touch already-committed recovery points.

</details>

<details><summary>Fix 7 — Outbound proxy blocking replication traffic</summary>

**Cause:** An authentication-required proxy sits in the outbound path. VMware Modernized explicitly supports using an authentication proxy for outbound connectivity — Hyper-V explicitly does **not** support any outbound authentication proxy, full stop.

```
VMware Modernized: configure the authentication proxy on the ASR replication appliance
itself (Site Recovery Infrastructure > appliance > proxy settings), then re-validate
outbound URL access from the appliance.

Hyper-V: an authentication proxy in the outbound path cannot be worked around by
allow-listing URLs — it has to be replaced with a transparent (non-auth) proxy or a
direct route for Site Recovery traffic. This is a common gap when a customer's
standard corporate proxy policy gets applied uniformly to both DR platforms without
accounting for this difference.
```

**Rollback note:** N/A — this is a network path decision, not a reversible configuration change on the ASR side.

</details>

<details><summary>Fix 8 — Failback stuck or landed with no network</summary>

**Cause:** Either the wrong failback option was chosen (Hyper-V), the mandatory reprotect stage was skipped (VMware), or VM network mapping was never configured (Hyper-V with VMM).

```
Hyper-V failback has three options with real trade-offs — picking the wrong one for the
situation is the most common cause of "failback is taking forever" tickets:
  - Minimize Downtime: pre-syncs data while the Azure VM keeps running; use for a
    planned, non-urgent failback
  - Full Download: downloads the entire disk with no checksum comparison — faster to
    START but more downtime; use only if the on-prem VM was deleted or the Azure
    replica has been running long enough that a delta sync isn't meaningfully faster
  - Create VM: choose same-VM vs. alternate-VM failback target explicitly — don't
    let this default silently create a new VM when the customer expected same-VM

VMware Modernized: failback is a strict 3-stage sequence (reprotect Azure VM → on-prem,
failover to on-prem, re-enable replication) — a failback ticket that looks stuck is
almost always sitting on an un-triggered reprotect step, not a genuine failure.

Hyper-V with VMM specifically: confirm VM networks are mapped to Azure virtual networks
BEFORE failover — a failed-over VM with no network mapping comes up with no NIC/IP, which
looks like a boot failure but is a Site Recovery configuration gap.
```

**Rollback note:** None of these are destructive on their own, but re-triggering a failback mid-sequence on the wrong stage can leave the VM in an ambiguous state — confirm which stage you're actually on via the Jobs tab before retrying.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — On-Premises to Azure DR (VMware / Hyper-V)
Platform: VMware (Classic / Modernized — circle one) / Hyper-V (with VMM / without VMM)
Vault / subscription / resource group: ____________
Appliance or Provider+agent host name (as applicable): ____________
Protected item (VM) friendly name: ____________
ReplicationHealth / ProtectionState at time of ticket: ____________
Exact error text shown in the portal Errors tab: ____________
Non-recoverable vs. recoverable error (Hyper-V only): ____________
Last successful recovery point timestamp: ____________
Resynchronization status (pending / in progress / completed): ____________
Outbound proxy in path? Auth-required? (Hyper-V: any auth proxy is unsupported): ____________
Steps already attempted:
[ ] Confirmed platform and architecture (VMware Classic/Modernized vs. Hyper-V with/without VMM)
[ ] Confirmed vault context set and fabric/appliance heartbeat pulled fresh
[ ] Classified the exact error rather than assuming "replication is broken"
[ ] For VMware: confirmed appliance registered against a Modernized (not Classic) vault
[ ] For Hyper-V: confirmed VM network mapping exists before failover was attempted
[ ] Checked whether resync is simply pending its normal overnight window
```

---
## 🎓 Learning Pointers

- **VMware and Hyper-V on-prem-to-Azure DR share almost nothing at the component level** despite both being "Azure Site Recovery." VMware routes everything through a single on-prem appliance; Hyper-V has no appliance at all — just a Provider and Recovery Services agent installed directly on the host or VMM server. Confirming the platform before troubleshooting saves real time.
- **The Classic VMware experience is on a hard retirement clock, not a soft deprecation notice.** New-replication enablement is already blocked (31 Jan 2026), support ends 15 Mar 2026, and the capability itself disappears 30 Mar 2026 — a ticket that surfaces a customer still on Classic is a migration-project flag, not just a fix-and-close.
- **A Modernized VMware appliance must register against a brand-new vault, never a reused Classic one.** This is an easy trap during migration planning and can't be corrected after the fact without recreating the vault.
- **Hyper-V's non-recoverable error classification means some failures never self-heal.** A VM sitting `Critical` for days with no active job isn't "still working on it" — it's waiting on a human to fix a broken VHD chain, invalid replica state, or auth failure, none of which retry automatically.
- **Outbound auth-proxy support is asymmetric between the two platforms.** VMware Modernized supports it; Hyper-V flatly does not — applying one platform's proxy assumptions to the other produces confusing, hard-to-diagnose connectivity failures.
- **Hyper-V failback's "Minimize Downtime" vs. "Full Download" choice is a real trade-off, not a formality** — picking Full Download on a long-running Azure replica wastes bandwidth re-downloading data a checksum-based sync would have skipped.
- Related: [VMware to Azure disaster recovery architecture - Modernized](https://learn.microsoft.com/en-us/azure/site-recovery/vmware-azure-architecture-modernized), [Deprecation of classic experience to protect VMware and physical machines](https://learn.microsoft.com/en-us/azure/site-recovery/vmware-physical-azure-classic-deprecation), [Move from classic to modernized VMware disaster recovery](https://learn.microsoft.com/en-us/azure/site-recovery/move-from-classic-to-modernized-vmware-disaster-recovery), [Hyper-V to Azure disaster recovery architecture](https://learn.microsoft.com/en-us/azure/site-recovery/hyper-v-azure-architecture), [Common questions for Hyper-V disaster recovery](https://learn.microsoft.com/en-us/azure/site-recovery/hyper-v-azure-common-questions)
