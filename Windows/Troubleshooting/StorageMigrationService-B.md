# Storage Migration Service — Hotfix Runbook (Mode B: Ops)
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
# 1. Is the orchestrator's Storage Migration Service actually running?
Get-Service -Name "Storage Migration Service*" -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType

# 2. Is the destination proxy service installed? (WS2019+ only — big perf/behavior difference if missing)
Get-Service -Name "Storage Migration Service Proxy" -ErrorAction SilentlyContinue | Select-Object Name, Status

# 3. What does the SMS event log actually say failed? (this is almost always more specific than the WAC UI)
Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService/Admin" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message

# 4. Basic reachability to source/destination from the orchestrator (WMI/DCOM + SMB are the two that matter)
Test-NetConnection -ComputerName <SourceOrDestFQDN> -Port 135   # WMI/DCOM
Test-NetConnection -ComputerName <SourceOrDestFQDN> -Port 445   # SMB

# 5. Is this actually a domain-controller source? (SMS can inventory/transfer but will NEVER cut over from a DC)
(Get-CimInstance Win32_OperatingSystem).ProductType   # 2 = Domain Controller
```

| If | Then |
|----|------|
| Job fails with "Access is denied" (Event 5000/45062) on specific files | NTFS/share permission or migration-account privilege gap → **Fix 1** |
| Inventory "partially succeeded" or fails with `0x800705AA` / long-path errors | Long path support / invalid filename characters → **Fix 2** |
| Transfer fails "Couldn't transfer storage on any of the endpoints" (`0x9044`) | Orchestrator can't reach source/destination — firewall or missing role/feature → **Fix 3** |
| Source is Windows Server 2008 R2 and nothing transfers | Source isn't fully patched — SMS on 2008 R2 requires current updates → **Fix 4** |
| Cutover validation fails "Access is denied for the token filter policy" | Old, pre-KB4512534 Windows Admin Center/SMS build — patch, don't fight it → **Fix 5** |
| Cutover greyed out / fails immediately for a source you expected to migrate | Source is a Domain Controller (SBS/Essentials editions ARE DCs) — cutover is architecturally blocked → **Fix 6** |
| Certain files silently don't transfer, no error in the UI | A user removed the Administrators group's NTFS permission on those files — proxy backup-privilege defect on unpatched builds → **Fix 7** |
| DFS Replication re-replicates every file after using SMS to preseed a new DFSR member | ACL ordering differs byte-for-byte after SMS transfer, so the DFSR hash doesn't match — pre-KB4512534 defect → **Fix 8** |
| Download of the transfer/errors CSV times out in Windows Admin Center | WCF operation timeout (1 min default) too short for a very large file count → **Fix 9** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Orchestrator server (Windows Server 2019+) running the Storage Migration Service
   - If migrating only ONE server, destination can double as orchestrator
   - If migrating several servers, use a dedicated orchestrator
        │
Windows Admin Center (latest) + latest SMS extension, pointed at the orchestrator
   (WAC UI is versioned separately from the in-OS service — an old WAC build can
   fail to even show the SMS tool against an otherwise-healthy orchestrator)
        │
Migration account: local/domain admin on BOTH source and orchestrator, AND on
BOTH destination and orchestrator (two separate admin-rights requirements)
        │
Inbound firewall rules open on the right computers
   Orchestrator: File and Printer Sharing (SMB-In)
   Source AND destination: SMB-In, Netlogon (NP-In), WMI (DCOM-In), WMI (WMI-In)
        │
Destination running Windows Server 2019+ with the Storage Migration Service
Proxy service installed (auto-opens its own firewall ports) — this is what
DOUBLES transfer performance vs. an older/proxy-less destination
        │
INVENTORY phase — enumerates files, shares, and security config on the source(s)
        │
TRANSFER phase — proxy-mediated copy of data + NTFS/share permissions to destination
   (source files are NEVER deleted or modified — always non-destructive)
        │
[OPTIONAL] CUTOVER phase — destination assumes the source's name/IP identity
   BLOCKED entirely if source is a Domain Controller (inventory/transfer still work)
   Same-domain source+destination required to avoid post-cutover DNS/FQDN mismatch
   Source enters a maintenance/offline state after cutover — files remain, just inaccessible
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the orchestrator and (if present) proxy services are actually running:**
```powershell
Get-Service -Name "Storage Migration Service*" | Select-Object Name, Status, StartType
```
Expected: `Storage Migration Service` = `Running` on the orchestrator. A proxy service showing `Stopped` on the destination isn't necessarily a failure — it's only installed/relevant on Windows Server 2019+ destinations.

**2. Pull the actual SMS event log, not just the WAC UI summary:**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService/Admin" -MaxEvents 30 |
    Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap
```
The WAC UI frequently shows a generic "Couldn't transfer storage" while this log has the real error code (`0x9044`, `0x800705AA`, specific Win32 error) underneath it.

**3. Confirm the migration account's admin rights on all four roles it needs them on:**
```powershell
# Run against source, destination, AND orchestrator — the account needs
# admin rights on source+orchestrator AND separately on destination+orchestrator
net localgroup Administrators
```
A migration account that's admin on source/destination but NOT on the orchestrator (or vice versa) produces confusing partial-success/partial-failure behavior, not a clean single error.

**4. Confirm network reachability for the specific ports SMS actually uses:**
```powershell
Test-NetConnection -ComputerName <target> -Port 135   # WMI/DCOM (inventory)
Test-NetConnection -ComputerName <target> -Port 445   # SMB (transfer)
```
`135` failing points at the WMI (DCOM-In) firewall rule being missing/blocked; `445` failing points at SMB-In.

**5. Confirm long path support if the failure mentions paths or a large file count:**
```powershell
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue
```
Expected: `1`. If `0` or absent, any source path over 260 characters fails inventory/transfer with a path-related error that looks unrelated to its actual cause.

**6. If cutover is the failing phase specifically, confirm the source isn't a Domain Controller:**
```powershell
(Get-CimInstance Win32_OperatingSystem).ProductType
```
`2` = Domain Controller. SMS can inventory and transfer data from a DC (including Windows SBS/Server Essentials editions, which ARE domain controllers even though they don't look like one) but **cannot cut over from one, full stop** — this isn't a bug to troubleshoot further.

**7. If files are silently missing post-transfer with no UI error, check the proxy debug log directly:**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService-Proxy/Debug" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -eq "Error" } | Select-Object TimeCreated, Message
```
Look specifically for `(5) Access is denied` on individual file paths — this is the signature of the backup-privilege defect (Fix 7), not a generic permissions issue.

---

## Common Fix Paths

<details><summary>Fix 1 — "Access is denied" on specific files/shares during transfer</summary>

**Symptom:** Event ID 5000/1069/45062, or files transfer without their original NTFS permissions.

```powershell
# Preserve full NTFS ACLs and security streams during a manual reconciliation copy
robocopy <Source> <Destination> /MIR /COPYALL /SEC /R:3 /W:5 /LOG:robocopy.log
```
Run as an account with SYSTEM-equivalent rights on both sides. Then verify and, if needed, re-export the share-level (not NTFS) permissions separately — these are stored in the registry, not on the file system:
```console
:: On the SOURCE
reg export "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Shares" shares.reg

:: On the DESTINATION, after import, restart LanmanServer (or reboot)
Restart-Service LanmanServer -Force
```

**Rollback:** N/A — this only re-applies permissions; it doesn't remove existing destination data.

</details>

<details><summary>Fix 2 — Long path / invalid character errors during inventory or transfer</summary>

**Symptom:** `0x800705AA`, "partially succeeded," or path-related errors during inventory.

```console
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
```
Restart the orchestrator (and destination, if the proxy service is installed there) after setting this — it does not take effect live.

Then find invalid filenames/characters that will still fail regardless of long-path support:
```powershell
Get-ChildItem -Path <SourcePath> -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '[<>:"/\\|?\*]' }
```

**Rollback:**
```console
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 0 /f
```

</details>

<details><summary>Fix 3 — "Couldn't transfer storage on any of the endpoints" (0x9044)</summary>

**Symptom:** Whole job fails, event log shows `Error: 36931` / "Guidance: Check the detailed error and make sure the transfer requirements are met."

```powershell
# Confirm the four inbound rules on SOURCE and DESTINATION
Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" | Where-Object Direction -eq Inbound | Select-Object DisplayName, Enabled
Get-NetFirewallRule -DisplayName "Netlogon Service (NP-In)" | Select-Object Enabled
Get-NetFirewallRule -DisplayName "Windows Management Instrumentation (DCOM-In)","Windows Management Instrumentation (WMI-In)" | Select-Object DisplayName, Enabled

# Confirm the ONE inbound rule on the ORCHESTRATOR
Get-NetFirewallRule -DisplayName "File and Printer Sharing (SMB-In)" | Select-Object Enabled
```
If everything above is enabled and this still fails, confirm the migration account is genuinely admin on the pair being contacted (Diagnosis Step 3) — a rejected credential can surface as this same generic transport-layer error.

**Rollback:** N/A — firewall rules only enabled, not created/removed.

</details>

<details><summary>Fix 4 — Windows Server 2008 R2 source transfers nothing</summary>

**Symptom:** Error `0x9044` specifically from a 2008 R2 source, everything else checks out.

This is expected if the source isn't fully patched. Install every Critical/Important Windows Update on the 2008 R2 box first — SMS on that OS generation depends on fixes shipped after RTM, and there is no SMS-specific patch to install instead of the OS baseline.

**Rollback:** N/A — this is a patching prerequisite, not a reversible change.

</details>

<details><summary>Fix 5 — Cutover validation: "Access is denied for the token filter policy on destination computer"</summary>

**Symptom:** Exact error text above during cutover validation, correct local admin credentials confirmed on both ends.

This was a defect fixed in [KB4512534](https://support.microsoft.com/help/4512534/windows-10-update-kb4512534). Install that update (or later cumulative update covering it) on the orchestrator and destination — there is no workaround config change, only the patch.

**Rollback:** N/A — this is a bug fix, not a configuration to revert.

</details>

<details><summary>Fix 6 — Cutover fails/greyed out because the source is a Domain Controller</summary>

**Symptom:** Cutover is unavailable or fails immediately; inventory and transfer worked fine.

```powershell
(Get-CimInstance Win32_OperatingSystem).ProductType   # returns 2
```
If this returns `2`, **cutover from this source is not supported, by design, at all** — including Windows SBS 2003/2008/2011 and Windows Server Essentials editions, which are domain controllers even though they're marketed/administered as simple file/app servers. SMS can still fully inventory and transfer the data; you just have to handle the identity/DNS cutover manually (rename/re-IP the new server, update DNS, decommission the DC properly via `dcpromo`/`Uninstall-ADDSDomainController`) rather than relying on SMS's automated cutover step.

**Rollback:** N/A — architectural limitation, not a setting.

</details>

<details><summary>Fix 7 — Specific files silently fail to transfer, error 5 "Access is denied" in the proxy debug log</summary>

**Symptom:** Proxy debug log shows `Transfer error for \\server\share\file: (5) Access is denied` for files where a user previously removed the Administrators group's permission — no error surfaces in the WAC UI, files are just missing.

```powershell
# Confirm the fix is needed: proxy log shows the (5) Access is denied signature
Get-WinEvent -LogName "Microsoft-Windows-StorageMigrationService-Proxy/Debug" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "Access is denied" }
```
This is a code defect (backup privilege wasn't being invoked by the proxy) fixed in [KB4490481](https://support.microsoft.com/help/4490481/windows-10-update-kb4490481). Install it on the orchestrator AND on the destination if the proxy service is installed there. Also confirm the migration accounts genuinely have local admin rights on all four required computer pairs (Diagnosis Step 3) — this defect specifically affected accounts that otherwise had correct rights.

**Rollback:** N/A — bug fix.

</details>

<details><summary>Fix 8 — DFS Replication re-replicates everything after SMS-based preseeding</summary>

**Symptom:** Files transferred via SMS to a new DFSR member, then DFSR preseeding/database cloning configured against it — every file shows a hash mismatch and gets re-replicated from scratch, even though data/size/attributes all match.

This is a pre-[KB4512534](https://support.microsoft.com/help/4512534/windows-10-update-kb4512534) defect where SMS writes NTFS ACL entries in a different **order** than the source, even though the resulting ACL is functionally identical — DFSR's clone hash is order-sensitive, so it flags a mismatch and re-replicates everything, discarding the entire benefit of preseeding.

```powershell
# Confirm this is the order-only difference (compare against a source file's ACL export)
icacls <SourcePath> /save source-acl.txt /t
icacls <DestinationPath> /save dest-acl.txt /t
```
**Fix:** install KB4512534 (or later, on WS2019+) on the orchestrator/proxy BEFORE running the SMS transfer — this is a pre-transfer prerequisite, not something that can be corrected after the fact on already-transferred files. If the transfer already happened on an unpatched build, the practical path is a fresh SMS transfer after patching, or accepting the one-time full DFSR re-replication cost. See `DFS/Troubleshooting/Replication/Replication-A.md` for DFSR's own preseeding/cloning validation steps.

**Rollback:** N/A — patch-then-retransfer, not a reversible setting.

</details>

<details><summary>Fix 9 — Transfer/errors CSV download times out in Windows Admin Center</summary>

**Symptom:** Error mentioning `net.tcp://localhost:28940/sms/service/...` and "did not receive a reply within the configured timeout (00:01:00)."

```powershell
# On the ORCHESTRATOR — raise the WCF send timeout (default 1 minute) in the SMS service config
# Edit %SYSTEMROOT%\SMS\Microsoft.StorageMigration.Service.exe.config, change sendTimeout to "10:00:00"
Restart-Service "Storage Migration Service"

# Also raise the PowerShell-side operation timeout via registry (create if absent)
New-Item -Path "HKLM:\Software\Microsoft\SMSPowershell" -Force | Out-Null
New-ItemProperty -Path "HKLM:\Software\Microsoft\SMSPowershell" -Name "WcfOperationTimeoutInMinutes" -PropertyType DWord -Value 600 -Force
```
If Windows Admin Center still can't pull the CSV after this, get it directly via PowerShell on the orchestrator instead:
```powershell
Get-SmsState -Name <jobName> -TransferFileDetail -ComputerName <sourceFQDN> | Export-Csv -Path log.csv
Get-SmsState -Name <jobName> -TransferFileDetail -ErrorsOnly -ComputerName <sourceFQDN> | Export-Csv -Path errlog.csv
```

**Rollback:** revert `sendTimeout` to `00:01:00` in the config file and remove the `WcfOperationTimeoutInMinutes` registry value once the large-job download is no longer needed.

</details>

---

## Escalation Evidence

```
=== Storage Migration Service Failure — Ticket Evidence ===

Date/Time:                      _______________
Orchestrator server:            _______________
Source server(s):               _______________
Destination server(s):          _______________
Job phase that failed:          _______________  (Inventory / Transfer / Cutover)
Source is a Domain Controller?: _______________  (Get-CimInstance Win32_OperatingSystem ProductType)

--- Commands Run ---
Storage Migration Service status (orchestrator):     _______________
Storage Migration Service Proxy status (destination): _______________
SMS Admin event log — top error Event ID/message:    _______________
Proxy Debug log — any "(5) Access is denied" hits:    _______________
Firewall rules confirmed (SMB-In/NP-In/DCOM-In/WMI-In): _______________
LongPathsEnabled registry value:                       _______________

--- Scenario ---
[ ] Inventory fails/partially succeeds
[ ] Transfer fails outright (0x9044 or similar)
[ ] Transfer "succeeds" but specific files are missing/permission-stripped
[ ] Cutover validation fails
[ ] Cutover unavailable — source suspected to be a DC
[ ] Downstream DFSR re-replication after SMS preseed

--- Steps Taken ---
[ ] Verified migration account admin rights on all 4 required computer pairs
[ ] Verified inbound firewall rules on source/destination/orchestrator
[ ] Verified LongPathsEnabled + scanned for invalid filenames
[ ] Confirmed current cumulative update level on all machines involved
[ ] Checked SMS Admin log AND Proxy Debug log (not just the WAC UI summary)
```

---

## 🎓 Learning Pointers

- **SMS is a three-phase, non-destructive tool — Inventory, Transfer, and an OPTIONAL Cutover.** Source files are never deleted or modified by SMS itself; even a fully "migrated" server still has its original data sitting on it afterward (in a maintenance/offline state post-cutover). Panic about "did SMS delete anything on the source" is almost always unfounded — check the destination and the job log first. [MS Docs: Storage Migration Service overview](https://learn.microsoft.com/en-us/windows-server/storage/storage-migration-service/overview)

- **The migration account needs admin rights on FOUR pairings, not two.** Admin on source+orchestrator is a separate requirement from admin on destination+orchestrator — a single "domain admin" account satisfies both trivially, but a scoped/least-privilege migration account easily misses one pairing and produces confusing partial failures rather than a clean single error.

- **Cutover is permanently unsupported from any Domain Controller — including SBS and Server Essentials editions that don't visually present as one.** This is architectural, not a bug to chase. Inventory and Transfer still work fine from a DC; only the automated identity-swap step is blocked. Plan a manual DNS/identity cutover for these sources from the start rather than discovering the limitation mid-project.

- **The WAC UI's error summary is frequently too generic to act on — always pull the actual SMS Admin event log and, for missing-file mysteries, the Proxy Debug log too.** The Proxy Debug log in particular is where the exact failing file path and Win32 error code show up; the UI just says "some files couldn't transfer."

- **If this environment also uses DFS Replication, know about the KB4512534 preseeding interaction before combining the two tools.** Using SMS to seed a new DFSR member on an unpatched build produces an ACL-ordering difference that looks cosmetically identical but fails DFSR's hash comparison, discarding the entire point of preseeding (avoiding a full initial replication). See `DFS/Troubleshooting/Replication/Replication-A.md` for the DFSR side of validating a clone/preseed operation. [MS Docs: Storage Migration Service known issues](https://learn.microsoft.com/en-us/windows-server/storage/storage-migration-service/known-issues)

- **A destination running Windows Server 2019+ WITH the proxy service installed transfers roughly twice as fast as one without it** — installing the proxy also auto-opens its own required firewall ports, so it's rarely worth skipping even for a one-off single-server migration.
