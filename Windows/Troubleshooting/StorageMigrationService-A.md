# Storage Migration Service — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why a migration succeeds or silently loses fidelity, not just what to click.

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
- Storage Migration Service (SMS) architecture: orchestrator, proxy, and the Inventory → Transfer → Cutover model
- Source types: Windows Server (2003 through 2025, including SBS/Essentials editions), failover clusters, Linux/Samba servers, NetApp CIFS servers
- Destination requirements, identity cutover mechanics, and the hard Domain-Controller-source cutover restriction
- Permission/ACL fidelity during transfer, including the documented backup-privilege and DFSR-preseeding-related defects
- Firewall/network/account requirements across the orchestrator/source/destination triangle
- Azure VM migration via Windows Admin Center's SMS integration

**Out of scope:**
- Azure Migrate (lift-and-shift of entire VMs without an OS-version change) — a different tool for a different goal; see Microsoft's own guidance to use Azure Migrate instead of SMS when the destination is simply "the same server as a VM," not a newer OS
- DFS Replication's own preseeding/database-cloning validation steps beyond the specific SMS-interaction defect — see `DFS/Troubleshooting/Replication/Replication-A.md`
- General Robocopy usage outside of its role as an SMS-adjacent manual-reconciliation tool
- Azure File Sync's own cloud-tiering architecture — SMS supports migrating TO a server already running the Azure File Sync agent, but doesn't configure or manage Azure File Sync itself
- Print server/print queue migration — SMS is file-server-focused and does not migrate printers at all; see `PrintServerMigration-A.md` for the PrintBRM-based equivalent workflow for a print role

**Assumptions:**
- Orchestrator and destination run Windows Server 2019 or later (Windows Server 2016 destinations are supported but slower and lose mainstream support in January 2027)
- Windows Admin Center (latest) with the current Storage Migration Service extension is available to drive the migration
- Reader has domain admin or an equivalent scoped migration account with local admin rights on every server pairing involved
- PowerShell 5.1 baseline; SMS's native automation surface is the `Microsoft.StorageMigration` PowerShell module plus the WAC UI — there is no separate Az/Graph API for SMS since it's an on-box service, not a cloud control plane

---

## How It Works

<details><summary>Full architecture</summary>

### Why Storage Migration Service Exists

Storage Migration Service replaces the traditional manual pattern of "stand up a new file server, Robocopy the data over, manually recreate shares and NTFS ACLs, then either tell users to update every mapped drive/UNC path or attempt a risky manual server-rename." SMS automates all of it — including, optionally, taking over the **identity** (computer name and IP) of the source server so that every existing UNC path, mapped drive, and application connection string keeps working unchanged after the cutover, with zero client-side reconfiguration.

```
Source Server(s)                  Orchestrator                    Destination Server(s)
┌─────────────────┐          ┌──────────────────┐            ┌──────────────────┐
│ Files, shares,    │  1. Inventory │ Storage Migration │  1. Inventory  │ (new hardware/VM) │
│ security config   │◀────────────▶│ Service            │───────────────▶│                    │
│                   │  2. Transfer  │ (Windows Server    │  2. Transfer   │ Proxy service      │
│ NEVER modified    │◀──────────────│  2019+)            │──────────────▶│ (WS2019+, 2x speed)│
│ or deleted by SMS │               └──────────────────┘                └──────────────────┘
└─────────────────┘                        │
                                   3. Cutover (OPTIONAL)
                                   Destination assumes source's
                                   name/IP; source → maintenance
                                   state (files remain, inaccessible)
```

### The Three-Phase Model

**1. Inventory** — SMS connects to each source and catalogs its files, shares, and security configuration (NTFS ACLs, share permissions, local accounts referenced by SIDs). This is read-only and non-destructive by definition; it produces the data SMS uses to plan the transfer.

**2. Transfer** — a bulk copy of the inventoried files, shares, and security config from source to destination. **Source files are never removed or modified during this or any other phase** — this is a documented, load-bearing guarantee, not an implementation detail. Transfer performance roughly doubles on a Windows Server 2019+ destination with the **Storage Migration Service Proxy** service installed, since WS2019+ introduced a built-in proxy specifically to accelerate this path; older destinations (2016, 2012 R2) transfer more slowly and without the proxy.

**3. Cutover (optional)** — the destination server assumes the source's network identity: computer name and, depending on configuration, IP address. Once cutover completes, existing UNC paths (`\\oldserver\share`), mapped drives, and application configs that reference the old server name transparently resolve to the new hardware with zero client-side change. The **source enters a maintenance state**: it keeps every file it always had (SMS never deletes source data, even post-cutover) but becomes unavailable to users and applications, since its former identity now belongs to the destination. The source can then be decommissioned on the administrator's own schedule — cutover is not a race against a self-destruct timer.

### The Orchestrator/Proxy Split

Migrating a **single** server can use that destination as its own orchestrator. Migrating **multiple** servers should use a dedicated orchestrator, since it drives potentially many concurrent inventory/transfer/cutover operations and benefits from not competing for resources with an active destination workload. The orchestrator needs only one inbound firewall rule opened on itself (File and Printer Sharing, SMB-In); the real firewall burden — SMB-In, Netlogon (NP-In), and WMI (both DCOM-In and WMI-In) — falls on the source and destination computers the orchestrator reaches out to.

### The Domain-Controller Cutover Restriction

SMS can fully **inventory and transfer** data from a domain controller. It **cannot cut over from one, under any circumstances** — this is an explicit, permanent architectural restriction, not a missing feature planned for a future release. The practical trap: **Windows Small Business Server (2003 R2/2008/2011) and every Windows Server Essentials edition ARE domain controllers**, even though they're marketed, sold, and administered as simple combined file/app/print servers with none of the visual trappings of a "real" DC. A migration plan built around SMS's automated cutover that includes one of these source types will complete Inventory and Transfer successfully and then hit a wall at Cutover — the identity/DNS portion of that migration has to be handled manually (proper DC demotion via `Uninstall-ADDSDomainController`, then rename/re-IP the new server and update DNS records) rather than through SMS's own workflow.

### Same-Domain Requirement for Clean Cutover

Cutover technically works across different Active Directory domains, but Microsoft's own guidance flags this as likely to cause DNS problems: the destination's fully qualified domain name differs from the source's post-cutover (since it's still joined to its own, different domain), breaking the "nothing changes for clients" promise that makes cutover valuable in the first place. **For a clean, transparent cutover, keep source and destination in the same AD domain** — cross-domain migrations are better served by transferring data without cutover and handling the identity/namespace change deliberately as part of a broader domain-consolidation project.

### Security and Permission Fidelity

SMS transfers both NTFS ACLs and SMB share-level permissions as part of Transfer — these are two structurally different permission layers (file-system ACL vs. registry-stored share config) and SMS handles both, which is a meaningful advantage over a naive Robocopy-only approach that typically only covers NTFS ACLs and requires a separate manual step (or a `reg export`/`reg import` of `HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Shares`) to carry share permissions across. Two documented defects affect this fidelity on unpatched builds:

- **Backup-privilege defect (fixed in KB4490481):** the SMS proxy wasn't correctly invoking the backup privilege needed to read files where a user had explicitly removed the Administrators group's own NTFS permission — those specific files silently failed to transfer with error 5 ("Access is denied") in the Proxy Debug log, with **no corresponding error surfaced in the Windows Admin Center UI**, making this a genuinely stealthy data-loss risk on an unpatched orchestrator/proxy.
- **ACL-ordering defect (fixed in KB4512534):** SMS could write a functionally identical NTFS ACL to the destination but in a **different internal entry order** than the source. This has zero practical effect for normal file access (Windows evaluates the full ACL regardless of entry order) but becomes a real problem the moment that data is used to preseed a new DFS Replication member via database cloning — DFSR's clone-import hash comparison is order-sensitive, so every single file registers as a mismatch and gets fully re-replicated, silently discarding the entire point of preseeding (avoiding an expensive initial full replication over the WAN). See `DFS/Troubleshooting/Replication/Replication-A.md` for DFSR's own database-cloning validation steps — this defect sits at the seam between the two features, not fully "owned" by either one's own documentation.

### Azure VM Migration Integration

Windows Admin Center layers Azure IaaS deployment on top of SMS: rather than hand-building a destination VM, storage, domain join, and roles in the Azure portal first, WAC can provision the Azure VM, configure its storage, join the domain, install the needed roles/features, and then run the standard SMS Inventory→Transfer→Cutover flow against it — reducing the chance of a missed manual step. This is explicitly a **rehost-to-a-newer-OS** path. If the goal is instead a pure lift-and-shift of an existing VM with no OS version change, Microsoft's own guidance directs to **Azure Migrate** instead, a separate, purpose-built tool for that narrower goal.

</details>

---

## Dependency Stack

```
Orchestrator server — Windows Server 2019+ running the Storage Migration Service
   (single-server migration: destination doubles as orchestrator; multi-server: dedicated orchestrator)
        │
Windows Admin Center (latest) + current Storage Migration Service extension
   pointed at the orchestrator — a version-mismatched WAC can fail to even
   present the SMS tool against an otherwise-healthy orchestrator
        │
Migration account — local/domain admin on FOUR required pairings:
   source+orchestrator AND (separately) destination+orchestrator
        │
Inbound firewall rules, split by role:
   Orchestrator:            File and Printer Sharing (SMB-In)
   Source AND Destination:  SMB-In, Netlogon (NP-In), WMI (DCOM-In), WMI (WMI-In)
        │
[Destination WS2019+] Storage Migration Service Proxy installed
   → auto-opens its own firewall ports, ~2x transfer throughput vs. proxy-less destinations
        │
Same AD forest for source+destination (required); same AD DOMAIN specifically
   recommended for clean cutover (cross-domain works but risks post-cutover DNS mismatch)
        │
INVENTORY — read-only catalog of files/shares/security config; never modifies the source
        │
TRANSFER — bulk copy of data + NTFS ACLs + share permissions to destination
   Long path support (LongPathsEnabled registry value) required for any path > 260 chars
   Backup-privilege defect (pre-KB4490481) can silently drop files with stripped
   Administrators-group ACEs — no UI error, only visible in the Proxy Debug log
   ACL-ordering defect (pre-KB4512534) breaks downstream DFSR preseeding specifically
        │
[OPTIONAL] CUTOVER — destination assumes source's name/IP identity
   HARD BLOCK if source is a Domain Controller (includes SBS/Server Essentials editions)
   Source → maintenance state afterward; files remain but the server is inaccessible
   under its old identity, which now belongs to the destination
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Couldn't transfer storage on any of the endpoints" (0x9044) | Orchestrator can't reach source/destination — firewall or missing WMI/SMB rule | `Test-NetConnection -Port 135` / `-Port 445` from the orchestrator |
| Inventory scan "partially succeeded," error 0x800705AA | Long path support disabled, or invalid filename characters in the source tree | `LongPathsEnabled` registry value; `Get-ChildItem -Recurse` regex scan for illegal characters |
| Access Denied (Event 5000/1069/45062) during transfer | Migration account not admin on one of the four required pairings, or NTFS/share ACL genuinely restrictive | Confirm admin rights on source+orchestrator AND destination+orchestrator separately |
| Specific files missing post-transfer, no UI error at all | Backup-privilege defect (pre-KB4490481) — files where Administrators-group ACE was removed | Proxy Debug log for `(5) Access is denied` on those exact paths |
| Cutover validation: "Access is denied for the token filter policy" | Pre-KB4512534 orchestrator/WAC build | Confirm patch level; install KB4512534 |
| Cutover unavailable or fails immediately | Source is a Domain Controller (including SBS/Server Essentials) | `(Get-CimInstance Win32_OperatingSystem).ProductType` — `2` = DC |
| Cutover "succeeds" but clients get DNS/FQDN errors afterward | Source and destination were in different AD domains | Confirm both machines' domain membership pre-migration |
| DFSR re-replicates 100% of preseeded data instead of near-zero | ACL-ordering defect (pre-KB4512534) — DFSR clone hash is order-sensitive | `icacls /save` comparison between source and destination; check patch level |
| 2008 R2 source transfers nothing, 0x9044 | Source OS not fully patched | Confirm current Critical/Important updates on the 2008 R2 box |
| CSV/log download from WAC times out | Default 1-minute WCF operation timeout too short for the file count | Check `sendTimeout` in `Microsoft.StorageMigration.Service.exe.config`; use `Get-SmsState` PowerShell fallback |
| Destination proxy validation warning ("proxy wasn't found") | Expected — proxy service not installed, or destination is WS2016/2012 R2 (proxy doesn't exist there) | `Get-Service "Storage Migration Service Proxy"` on the destination |
| Robocopy-based manual reconciliation shows files "updated" that didn't actually change | Switch/timestamp semantics misunderstood, not a real discrepancy | Review `/MIR` vs `/M`/`/XO`/`/XC`/`/XN` switch behavior against the actual sync intent |

---

## Validation Steps

**1. Confirm the orchestrator service and, if applicable, the destination proxy are running:**
```powershell
Get-Service -Name "Storage Migration Service*" | Select-Object Name, Status, StartType
```
Expected: `Running`/`Automatic` for the orchestrator's own service; the destination proxy is only expected to exist/run on WS2019+ destinations.

**2. Confirm the migration account's admin rights on all four required pairings:**
```powershell
# Run on source, destination, AND orchestrator independently
net localgroup Administrators
```
Expected: the migration account (or a group it belongs to) present on all three, satisfying both the source+orchestrator and destination+orchestrator requirements.

**3. Confirm the required inbound firewall rules on each role:**
```powershell
# Orchestrator
Get-NetFirewallRule -DisplayName "File and Printer Sharing (SMB-In)" | Select-Object Enabled

# Source AND Destination
Get-NetFirewallRule -DisplayName "File and Printer Sharing (SMB-In)","Netlogon Service (NP-In)","Windows Management Instrumentation (DCOM-In)","Windows Management Instrumentation (WMI-In)" |
    Select-Object DisplayName, Enabled
```

**4. Confirm long path support before migrating any deep/legacy file tree:**
```powershell
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue
```
Expected: `1`. A `0` or missing value guarantees failures on any path exceeding 260 characters, framed as a generic path error rather than an obvious "enable long paths" message.

**5. Confirm patch level on the orchestrator/destination for the two documented ACL-fidelity defects:**
```powershell
Get-HotFix -Id KB4490481, KB4512534 -ErrorAction SilentlyContinue
```
Both should be present (or superseded by a later cumulative update) before trusting a transfer's permission fidelity, especially if DFSR preseeding is anywhere in the plan.

**6. If the source might be a Domain Controller, confirm it explicitly before promising a client an automated cutover:**
```powershell
(Get-CimInstance Win32_OperatingSystem).ProductType
```
`2` = Domain Controller — set expectations for a manual identity/DNS cutover from the start, don't discover this mid-project.

**7. After transfer, spot-check ACL fidelity directly rather than trusting "job succeeded":**
```powershell
icacls <SourcePath> /save source-acl.txt /t
icacls <DestinationPath> /save dest-acl.txt /t
# Diff the two files — functionally-identical-but-reordered ACLs are the DFSR-preseeding trap
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Pre-Migration / Environment Readiness

1. Confirm orchestrator OS version and WAC/SMS extension currency.
2. Confirm migration account rights across all four pairings.
3. Confirm firewall rules on all three roles.
4. Confirm `LongPathsEnabled` and patch level (`KB4490481`, `KB4512534`) up front — cheaper to fix before a job starts than to re-run after a partial failure.
5. Confirm whether any source is a Domain Controller and set cutover expectations accordingly.

### Phase 2: Inventory Failures

1. Pull the SMS Admin event log for the specific error code, not just the WAC summary.
2. `0x800705AA`/path errors → long path support + invalid character scan (Fix 2 in the B runbook).
3. Confirm WMI (port 135) reachability specifically — inventory relies on it more heavily than transfer does.

### Phase 3: Transfer Failures or Fidelity Gaps

1. `0x9044` outright failure → firewall/reachability first (Fix 3).
2. Files present but permission-stripped → NTFS/share ACL reconciliation via Robocopy `/COPYALL /SEC` + share registry export/import (Fix 1).
3. Files silently MISSING with zero UI error → Proxy Debug log for the `(5) Access is denied` backup-privilege signature (Fix 7) — don't assume "transfer succeeded" from the UI alone on an unpatched build.
4. Planning to preseed DFSR from this data → confirm `KB4512534` BEFORE transfer, not after (Fix 8) — this cannot be corrected retroactively on already-transferred files.

### Phase 4: Cutover Failures

1. Confirm source ProductType first — if `2`, stop troubleshooting cutover and switch to a manual identity/DNS plan (Fix 6).
2. "Token filter policy" access-denied error → patch level, not a permissions investigation (Fix 5).
3. Cross-domain source/destination → expect and plan for the DNS/FQDN mismatch rather than treating it as a bug.

### Phase 5: Post-Cutover / Downstream Issues

1. DFSR re-replicating everything after using SMS to preseed → confirm this is the ACL-ordering defect (patch level + `icacls` comparison) rather than a DFSR-side misconfiguration — see `DFS/Troubleshooting/Replication/Replication-A.md` for the DFSR half of this investigation.
2. Source server still needed for anything post-cutover → remember it's in a maintenance state, not deleted; files are still physically present, just inaccessible under the identity it no longer owns.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Standard single-server migration with cutover (same domain, non-DC source)</summary>

```powershell
# 1. On the destination (WS2019+): install the proxy service for 2x transfer performance
Install-WindowsFeature -Name Storage-Migration-Service-Proxy    # or via WAC: Roles and features → Storage Migration Service Proxy

# 2. Confirm firewall/account prerequisites (see Validation Steps 2-3)

# 3. Run Inventory → Transfer → Cutover through Windows Admin Center's Storage Migration Service tool,
#    using the destination as its own orchestrator since this is a single-server migration
```
**Verify:**
```powershell
Get-Service "Storage Migration Service Proxy"
(Get-CimInstance Win32_OperatingSystem).ProductType   # confirm non-DC before promising cutover
```
**Rollback:** cutover has no built-in "undo" — the source remains fully intact in its maintenance state, so recovery is: rename/re-IP the source back to its original identity manually, and treat the destination as the one to decommission if the migration needs to be reversed.

</details>

<details><summary>Playbook 2 — Multi-server migration with a dedicated orchestrator</summary>

```powershell
# 1. Stand up a dedicated orchestrator (WS2019+), separate from any source or destination
# 2. Confirm the migration account is admin on EVERY source+orchestrator and destination+orchestrator pairing
# 3. Confirm the ONE inbound rule on the orchestrator itself
Get-NetFirewallRule -DisplayName "File and Printer Sharing (SMB-In)" | Enable-NetFirewallRule

# 4. Batch-inventory all sources first, review results, THEN batch-transfer, THEN batch-cutover
#    (staging phases across the whole batch avoids one server's fixable error blocking the others)
```
**Verify:** re-run Validation Steps 2-3 against each new source/destination pair added to the batch before including it in a Transfer or Cutover run.

**Rollback:** each source/destination pair rolls back independently per Playbook 1's logic — a multi-server batch failure on one pair doesn't require unwinding the others.

</details>

<details><summary>Playbook 3 — Migrating a Domain Controller's file data (SBS/Essentials source) without SMS cutover</summary>

```powershell
# 1. Confirm this really is a DC before planning around it
(Get-CimInstance Win32_OperatingSystem).ProductType   # 2 = DC

# 2. Run Inventory + Transfer normally through SMS — fully supported for a DC source
# 3. DO NOT attempt Cutover — it is not supported and will not complete

# 4. Handle identity/DNS manually:
#    a. Properly demote the source DC first (never just power it off)
Uninstall-ADDSDomainController -DemoteOperationMasterRole -RemoveApplicationPartitions

#    b. Then rename/re-IP the destination and update DNS records to match the retired
#       identity, if transparent client redirection is still the goal
Rename-Computer -NewName <OldSourceName> -Force -Restart
```
**Rollback:** if demotion hasn't happened yet, this playbook is fully reversible up to that point — simply don't proceed past Inventory/Transfer. Once `Uninstall-ADDSDomainController` runs, treat it like any other DC decommission (no SMS-specific rollback exists).

</details>

<details><summary>Playbook 4 — Pre-flight for an SMS-to-DFSR-preseed pipeline</summary>

Use when SMS-transferred data will be used to preseed a new DFS Replication member via database cloning — the ACL-ordering defect makes patch-level verification mandatory BEFORE transfer, not optional.

```powershell
# 1. Confirm patch level on orchestrator/proxy BEFORE running any transfer
Get-HotFix -Id KB4512534 -ErrorAction SilentlyContinue

# 2. If missing, patch first — this cannot be fixed retroactively on already-transferred files
# 3. Run the SMS transfer as normal once patched
# 4. Spot-check ACL entry order on a sample of files before proceeding to DFSR cloning
icacls <SourceSample> /save source.txt /t
icacls <DestSample> /save dest.txt /t
# 5. Proceed to DFS Replication's own database-cloning steps — see Replication-A.md
```
**Rollback:** if the transfer already happened on an unpatched build and DFSR re-replication has already started, there's no partial-rollback path — either accept the one-time full re-replication cost or re-run the SMS transfer after patching and re-clone from that corrected copy.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Storage Migration Service evidence for escalation
.NOTES     Run as admin on the ORCHESTRATOR. Run a second, targeted pass on the specific
           source/destination pair if the issue is transfer-fidelity-specific.
#>

$OutputDir = "C:\Temp\SMS-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Service state (orchestrator + proxy if local)
Get-Service -Name "Storage Migration Service*" | Select-Object Name, Status, StartType |
    Export-Csv "$OutputDir\SMS-ServiceState.csv" -NoTypeInformation

# 2. SMS Admin event log
Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService/Admin" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$OutputDir\SMS-AdminLog.csv" -NoTypeInformation

# 3. Proxy Debug log (if proxy is local to this box)
Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService-Proxy/Debug" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$OutputDir\SMS-ProxyDebugLog.csv" -NoTypeInformation

# 4. Patch level for the two documented ACL-fidelity defects
Get-HotFix -Id KB4490481, KB4512534 -ErrorAction SilentlyContinue |
    Export-Csv "$OutputDir\SMS-RelevantHotfixes.csv" -NoTypeInformation

# 5. Long path support state
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\LongPathsEnabled.txt"

# 6. Firewall rule state (orchestrator role set; re-run targeted checks on source/destination separately)
Get-NetFirewallRule -DisplayName "File and Printer Sharing (SMB-In)","Netlogon Service (NP-In)","Windows Management Instrumentation (DCOM-In)","Windows Management Instrumentation (WMI-In)" |
    Select-Object DisplayName, Enabled, Profile, Direction |
    Export-Csv "$OutputDir\SMS-FirewallRules.csv" -NoTypeInformation

# 7. Domain Controller check (relevant if cutover is in scope)
(Get-CimInstance Win32_OperatingSystem) | Select-Object Caption, ProductType |
    Export-Csv "$OutputDir\OSProductType.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Service state
Get-Service -Name "Storage Migration Service*"

# SMS event logs
Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService/Admin" -MaxEvents 30
Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService-Proxy/Debug" -MaxEvents 50

# PowerShell-native transfer log pull (bypasses WAC UI timeout)
Get-SmsState -Name <jobName> -TransferFileDetail -ComputerName <sourceFQDN> | Export-Csv log.csv
Get-SmsState -Name <jobName> -TransferFileDetail -ErrorsOnly -ComputerName <sourceFQDN> | Export-Csv errlog.csv

# Domain Controller check (cutover eligibility)
(Get-CimInstance Win32_OperatingSystem).ProductType

# Long path support
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f

# Patch-level check for the two documented ACL-fidelity defects
Get-HotFix -Id KB4490481, KB4512534

# Firewall rules (source/destination)
Get-NetFirewallRule -DisplayName "File and Printer Sharing (SMB-In)","Netlogon Service (NP-In)","Windows Management Instrumentation (DCOM-In)","Windows Management Instrumentation (WMI-In)"

# Share-permission export/import (registry, separate from NTFS ACLs)
reg export "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Shares" shares.reg

# ACL fidelity comparison (DFSR-preseed pre-flight)
icacls <Path> /save acl-export.txt /t

# Manual reconciliation copy preserving full ACLs/security streams
robocopy <Source> <Destination> /MIR /COPYALL /SEC /R:3 /W:5 /LOG:robocopy.log
```

---

## 🎓 Learning Pointers

- **SMS's cutover restriction on Domain Controllers is absolute and includes editions that don't look like DCs.** SBS 2003/2008/2011 and every Windows Server Essentials release are domain controllers under the hood. A migration plan promising a fully automated identity cutover needs this checked (`ProductType`) at the scoping stage, not discovered after Inventory and Transfer have already completed. [MS Docs: Storage Migration Service overview](https://learn.microsoft.com/en-us/windows-server/storage/storage-migration-service/overview)

- **The two documented ACL-fidelity defects (KB4490481, KB4512534) fail silently in different, easy-to-miss ways.** The backup-privilege defect drops files with zero UI error — only the Proxy Debug log shows it. The ACL-ordering defect doesn't affect the destination's usability at all; it only surfaces downstream, as a mass DFSR re-replication event, potentially days or weeks after the SMS transfer itself. Confirming patch level BEFORE a transfer, especially one feeding into DFSR preseeding, is cheap insurance against both.

- **The migration account's admin-rights requirement is really four separate requirements, not two.** Source+orchestrator and destination+orchestrator are evaluated independently — a scoped least-privilege account that nails three out of four pairings produces confusing partial-success behavior that looks like a bug rather than an incomplete permission grant.

- **"Transfer succeeded" in the WAC UI is not the same claim as "every file and permission transferred correctly."** Both documented defects in this topic produce a UI that looks clean while data or permission fidelity is actually compromised — spot-checking with `icacls` comparisons or reviewing the Proxy Debug log directly is worth the extra few minutes on any migration where fidelity actually matters (which is effectively all of them).

- **SMS and Azure Migrate solve different problems that are easy to conflate.** SMS assumes a destination running a DIFFERENT (typically newer) OS and handles the file/identity migration; Azure Migrate assumes the goal is lifting an existing VM into Azure with no OS change. Recommending the wrong one wastes a client's migration-planning cycle. [MS Docs: About Azure Migrate](https://learn.microsoft.com/en-us/azure/migrate/migrate-services-overview)

- **This is one of a small number of topics in this repo where a defect in one Microsoft feature (SMS) only manifests as a problem in a completely separate feature (DFS Replication).** Cross-referencing `DFS/Troubleshooting/Replication/Replication-A.md` is essential here — an engineer who only reads SMS documentation, or only reads DFSR documentation, will each independently miss half of this specific failure mode.
