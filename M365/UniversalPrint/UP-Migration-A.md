# Universal Print Migration (On-Premises Print Server → Universal Print) — Reference Runbook (Mode A: Deep Dive)
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

**Covers:** planning and executing a migration OFF an on-premises Windows print server infrastructure and ONTO Microsoft Universal Print — printer eligibility assessment (Universal Print ready vs. Connector-required), Connector deployment and sizing, license/role assignment, bulk printer registration and sharing (Graph/PowerShell), replacing the client-side deployment mechanism (GPO/logon-script/deprecated `PrintProvisioning.exe` + `printers.csv` → Intune Settings Catalog Printer Provisioning / UniversalPrint CSP), cutover sequencing, and the decommission/rollback window for the legacy print server.

**Does not cover:**
- Steady-state Universal Print operation once migration is complete (connector health, job troubleshooting, share management day-to-day) — see `Universal-Print-A.md`/`Universal-Print-B.md`
- Migrating printers from one on-premises Windows print server to ANOTHER on-premises print server (i.e., not eliminating the server) — see `Windows/Troubleshooting/PrintServerMigration-A.md`/`-B.md`
- The native Universal Print Mac App and macOS-side migration considerations — see `Universal-Print-macOS-A.md`/`-B.md`
- Deep Universal Print Connector internals beyond what's needed to make migration sizing/placement decisions — see `Universal-Print-A.md` for the full connector architecture

**Assumed role:** Global Administrator, Printer Administrator, or Printer Technician in Entra ID, plus local admin on any server hosting a Connector.

**Prerequisites:**
- Universal Print entitlement confirmed in the tenant (bundled with many Microsoft 365/Windows subscriptions — verify rather than assume; see Command Cheat Sheet)
- Inventory of the existing print server's queues, drivers, ports, and current deployment mechanism (GPO Group Policy Preference, logon script, or legacy tool)
- Windows 11 (1903+) or macOS Ventura 13.3+ on client endpoints for native Universal Print printing
- For Connector-based printers: a host meeting the Connector prerequisites (see Dependency Stack)

---

## How It Works

<details><summary>Full architecture — legacy print server model vs. Universal Print model, and the migration bridge between them</summary>

### The on-premises model being replaced

A traditional Windows print server centralizes three things: the **spooler** (queue management), the **driver store** (per-architecture driver binaries), and **identity/authorization** (share-level ACLs tied to AD DS, printers published to AD DS for discovery). Clients reach it two ways — a persistent UNC connection (`\\printserver\printername`) established via GPO Group Policy Preference, logon script, or manual `net use`/`Add-Printer`, or (in older or unmanaged environments) the now-deprecated `PrintProvisioning.exe` + `printers.csv` bulk-deployment tool. All of this requires clients to be on the corporate network or VPN, and requires drivers to be installed and kept current on both the server and every client.

### The Universal Print model

Universal Print eliminates the print server entirely for printers that don't need one. It replaces the three legacy pillars with:
- **Queue management** — moved to the Universal Print cloud service, running on the same infrastructure as Exchange/Teams/Office
- **"Drivers"** — eliminated in the traditional sense. Universal Print speaks the Mopria/IPP INFRA standard directly to the printer. Manufacturers can still expose advanced, differentiated functionality through a **Print Support App (PSA)**, but PSAs are optional and not required for baseline printing
- **Identity/authorization** — moved to Entra ID. Printers are objects in Entra ID; sharing and permissions are managed the same way as any other Entra-governed resource, replacing AD DS printer publication and NTFS/share ACLs

Because print jobs and management traffic travel outbound over HTTPS to a small, fixed set of Microsoft endpoints, Universal Print requires **no inbound firewall rules and no VPN** — a materially different network posture from a traditional print server, and one of the strongest cost/complexity arguments for migrating.

### The migration bridge: two printer classes

Every physical printer being migrated falls into exactly one of two classes, decided once and rarely revisited:

1. **Universal Print ready** — the printer's own firmware has been updated by the manufacturer to register with and communicate directly with the Universal Print cloud service. No on-premises component is required for this printer, ever, after registration. Registration happens through the printer's own admin interface (not a Microsoft tool), following the manufacturer's instructions.
2. **Connector-required** — for printers that are not (yet, or ever going to be) Universal Print ready. The **Universal Print Connector** is a lightweight Windows service installed on an always-on host (physical, VM, or Azure VM) inside the network boundary. It acts as a proxy: it discovers locally-attached/network printers using the driver already present on that host, and relays jobs between the Universal Print cloud service and the physical printer. The Connector host becomes the new (much smaller) analog of the old print server for exactly those printers — it is a single point of failure for everything registered behind it, which is the primary reason Connector sizing and placement matter (see Dependency Stack).

### Migration steps (per Microsoft's published sequence)

1. **Get access** — confirm/assign Universal Print licenses to printing users and an eligible admin role (Global Administrator, Printer Administrator, or Printer Technician) to the people managing the migration
2. **Check prerequisites** — client OS versions, outbound endpoint reachability
3. **Determine connection method per printer** — Universal Print ready vs. Connector, checked against the manufacturer's published Universal Print ready model list
4. **Install Connector(s)** where needed, sized per the printer count and job volume expected
5. **Register printers** — direct (UP-ready) or via Connector
6. **Configure printer settings** — defaults, location metadata, secure release if desired
7. **Share printers** — a distinct step from registration; controls who can discover and use each printer
8. **(Optional) Deploy via Intune** — Settings Catalog Printer Provisioning policy for a seamless, no-user-action installation experience
9. **Communicate to users** — what's different (no VPN needed, job-based reporting instead of page-based, etc.)
10. **Monitor the rollout** — usage/job volume against license entitlement, printer health, known-issue tracking

</details>

---

## Dependency Stack

```
Bottom of stack — Tenant & identity prerequisites
──────────────────────────────────────────────────
Universal Print license entitlement (bundled with many Microsoft 365 / Windows
subscriptions — verify via Get-MgSubscribedSku, don't assume)
        │
Entra ID role for the migration operator: Global Administrator, Printer
Administrator, or Printer Technician (least-privilege: avoid Global Admin
for routine migration work)
        │
Middle of stack — Per-printer connectivity decision
──────────────────────────────────────────────────
        ├── UP-ready path: printer firmware registers directly with the
        │   Universal Print cloud service over outbound HTTPS 443 to a
        │   small fixed endpoint set (print/register/discovery/notification/
        │   graph.print.microsoft.com + login.microsoftonline.com)
        │
        └── Connector path: Windows 11 64-bit (22631+) or Windows Server
            2025+ recommended host (Server 2019 supported but discouraged
            and being phased out; Server 2016 has a documented lower job
            success rate) — running 24x7, sleep/hibernate disabled,
            .NET Framework 4.8+, always-on internet connectivity
                │
                Connector sizing (memory-bound): ~700MB RAM consumed per
                100 registered printers, plus overhead under load
                  Standard_B2s  (2 vCPU / 4GB)  → ~150 printers recommended max
                  Standard_B2ms (2 vCPU / 8GB)  → ~600 printers recommended max
                │
                Connector registers each printer's queue with the cloud
                service; one Connector = one point of failure for every
                printer behind it — multiple Connectors recommended for
                large or geographically distributed printer fleets
        │
Upper-middle of stack — Registration, sharing, permissions
──────────────────────────────────────────────────
Printer registered as an Entra ID-backed object (print/printers)
        │
Printer SHARED (print/shares) — a distinct object and a distinct step;
registration alone is invisible to end users
        │
Users/groups granted access to the share (allowedUsers/allowedGroups, or
"Allow all users" for tenant-wide printers)
        │
Top of stack — Client delivery mechanism (this is what actually changes for
end users, and what a migration project spends most of its execution time on)
──────────────────────────────────────────────────
RETIRED: GPO Group Policy Preference printer deployment / logon-script UNC
mapping / deprecated PrintProvisioning.exe + printers.csv tool
        │
REPLACED BY: Intune Settings Catalog "Printer Provisioning" policy
(uses the UniversalPrint CSP) — requires target device to be Microsoft
Entra Joined or Hybrid Entra Joined; Workplace-registered (BYOD) devices
are explicitly out of scope for Intune-delivered Universal Print policies
        │
Cutover: legacy print server queues unpublished from AD DS, legacy GPO/
logon-script mechanism unassigned, old server kept online-but-disconnected
for a validation window before final decommission
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No printers appear in the Universal Print portal despite "migration complete" | Licensing not assigned, or wrong admin role used during setup | `Get-MgSubscribedSku` for `UNIVERSAL_PRINT`; confirm operator's Entra role |
| A specific printer can't be found on the UP-ready model list and no Connector exists for it | Eligibility decision was never made for this printer — migration gap, not a fault | Check `https://aka.ms/UPPrinterList`; confirm Connector deployment plan covers this printer |
| Printer registered (visible to admins) but no user can find it to install | Registration completed but sharing step skipped | `Get-MgPrintShare` returns nothing for the printer's ID |
| Users see two entries for the same physical printer | Legacy print-server-published queue not unpublished/removed during cutover | `Get-Printer \| Where Published` on the legacy server; GPO printer item still present |
| Intune reports policy success but the printer never installs on the device | Device is Workplace-registered (BYOD), out of Intune UP-policy scope by design | `dsregcmd /status` — `WorkplaceJoined: YES` with `AzureAdJoined: NO` |
| Print job succeeds from the UP portal test but fails/hangs from real clients | Print Support App conflict or Connector-host driver issue introduced during cutover | Check installed PSAs on the Connector host (`Get-AppxPackage`) |
| Connector host intermittently fails jobs with no obvious cause, host is Windows Server 2016 | Documented lower job-success-rate issue on Server 2016 | Confirm host OS version; apply KB5003638 mitigation or upgrade host |
| Connector enumeration and job delivery are noticeably slow after registering many printers | Connector host undersized for the printer count now registered | Check host memory usage against the ~700MB/100-printers baseline |
| A Connector-registered printer stops printing after being "swapped" to a newly UP-ready registration | Known Windows client-side issue after swapping a Connector printer to a UP-ready registration for the same physical device | Restart the client machine, or remove/re-add the printer (Windows < 22H2) |
| Users on Windows 11 with printers originally installed on Windows 10 suddenly can't print after a recent cumulative update | Regression in KB5083769+ affecting per-system-installed UP printers | Run `Convert-UpPrinterToPerUser.ps1 -Detect` on the affected device |
| Migration is mid-flight and needs to pause/reverse | Depends entirely on whether the old print server's queues have already been deleted/unpublished | If not yet unpublished, simply re-enable the legacy GPO/logon-script mechanism; if queues are gone, rollback means restoring from the print server's own backup, not a Universal Print operation |

---

## Validation Steps

1. **Confirm tenant-level entitlement before planning printer counts against it:**
   ```powershell
   Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "UNIVERSAL_PRINT" } |
       Select-Object SkuPartNumber, ConsumedUnits, @{N='Enabled';E={($_.PrepaidUnits).Enabled}}
   ```
   Good: at least one enabled plan, `ConsumedUnits` tracking the migrating population. Bad: no matching SKU returned — licensing must be purchased/assigned before migration work continues.

2. **Confirm the eligibility decision matches what was actually deployed, per printer:**
   ```powershell
   Get-MgPrintPrinter -All | Select-Object DisplayName, HasPhysicalDevice, Manufacturer, Model
   ```
   Good: every printer in the migration plan appears exactly once. Bad: a printer that should be Connector-registered shows registered twice (once from an earlier failed attempt), or a printer expected to be UP-ready isn't listed at all.

3. **Confirm registration AND sharing both exist for every migrated printer:**
   ```powershell
   $printers = Get-MgPrintPrinter -All
   $shares   = Get-MgPrintShare -All
   $printers | Where-Object { $_.Id -notin $shares.PrinterId } | Select-Object DisplayName
   ```
   Good: empty result (every registered printer has a share). Bad: any printer listed — it's registered but invisible to users.

4. **Confirm the Connector host meets sizing recommendations before it becomes a support burden:**
   ```powershell
   # On the Connector host
   Get-CimInstance Win32_OperatingSystem | Select-Object FreePhysicalMemory, TotalVisibleMemorySize
   (Get-Service "Universal Print Connector Host Service").Status
   ```
   Good: comfortable headroom against the ~700MB-per-100-printers baseline, service `Running`. Bad: memory usage above ~90% of total, or the service not running at all.

5. **Confirm the client delivery mechanism has actually cut over, not just been added alongside the old one:**
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\UniversalPrint" -ErrorAction SilentlyContinue
   gpresult /r | Select-String "Printer"
   dsregcmd /status | Select-String "AzureAdJoined|WorkplaceJoined"
   ```
   Good: UniversalPrint CSP key present, no printer-related GPO applying, device Entra Joined or Hybrid Entra Joined. Bad: both old and new mechanisms present (duplicate printer risk), or the device is Workplace-registered (Intune UP policy silently won't apply).

6. **Confirm end-to-end job delivery from a genuinely migrated client**, not just portal-side status:
   ```powershell
   Get-Printer -Name "<MigratedPrinterName>" | Out-Printer
   Get-MgPrintPrinterJob -PrinterId "<PrinterId>" | Select-Object Id, State, CreatedDateTime
   ```
   Good: job state progresses to `completed`. Bad: job stuck in `processing`/`aborted` — investigate the Connector host or PSA next.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Pre-Migration Assessment**
- Inventory every printer on the legacy print server: `Get-Printer` on the source, capturing name, driver, port type, and current share/publish state
- Cross-reference every model against the Universal Print ready list (manual step — `https://aka.ms/UPPrinterList`); split the inventory into "direct" and "Connector-required" buckets
- Identify the current client delivery mechanism (GPO Group Policy Preference, logon script, or the deprecated `PrintProvisioning.exe`/`printers.csv` tool) — this determines how much rework the client-side rollout requires
- Confirm Universal Print licensing covers the full user population expected to print, and that print job volume (not page volume) has been estimated against the plan's included job allowance

**Phase 2 — Pilot**
- Migrate a small representative subset: at least one UP-ready printer and one Connector-registered printer, across at least one Entra Joined and one Hybrid Entra Joined device
- Validate end-to-end printing, Intune policy delivery, and — critically — that the OLD delivery mechanism doesn't still apply to pilot devices (duplicate printer check)
- Confirm Connector host sizing assumptions hold under real job volume, not just registration count

**Phase 3 — Bulk Registration & Sharing**
- Deploy additional Connector hosts if the pilot's printer-per-host ratio approaches the sizing guidance (~150 for a B2s-class host, ~600 for B2ms-class)
- Register and share printers in batches, verifying each batch with the Validation Steps above before moving to the next — catching an unshared batch of 5 printers is cheap; catching it after 200 are unshared is not
- Assign share permissions using groups rather than individual users wherever the legacy environment's ACL model allows a clean mapping

**Phase 4 — Client Deployment**
- Build and assign the Intune Settings Catalog Printer Provisioning policy (UniversalPrint CSP) to the pilot-validated device population
- Confirm every targeted device is Entra Joined or Hybrid Entra Joined before assignment — Workplace-registered devices will show policy "success" with no actual effect
- Stage the removal of the legacy GPO/logon-script mechanism to happen close to (not weeks before or after) the Intune policy's effective rollout, to minimize the coexistence window where duplicate printers confuse users

**Phase 5 — Cutover & Decommission**
- Unpublish/remove legacy print server queues from AD DS and GPO once the new mechanism is confirmed working for the affected population
- Keep the legacy print server running but **disconnected from production print traffic** (not powered off) for a validation window — the same low-cost rollback pattern used in server-to-server print migrations
- After the validation window closes with no regressions reported, proceed with the print server's normal decommission process (see `Windows/Troubleshooting/PrintServerMigration-A.md` for anything server-specific, if the box is being repurposed rather than retired)

---

## Remediation Playbooks

<details><summary>Playbook 1 — Printer eligibility triage and Connector sizing plan</summary>

**Goal:** produce a per-printer migration plan before touching production deployment.

```powershell
# Pull the full legacy print server inventory
$legacyPrinters = Get-Printer -ComputerName <legacyServerName> |
    Select-Object Name, DriverName, PortName, Shared, Published

# Export for manual cross-reference against https://aka.ms/UPPrinterList
$legacyPrinters | Export-Csv -Path "C:\Migration\LegacyPrinterInventory.csv" -NoTypeInformation

# After manual classification, estimate Connector host count needed
# (rule of thumb: printer count / 150 for B2s-class hosts, / 600 for B2ms-class)
$connectorRequiredCount = ($legacyPrinters | Where-Object { $_.Name -in $connectorRequiredList }).Count
[Math]::Ceiling($connectorRequiredCount / 150)   # minimum B2s-class hosts needed
```
Document the direct/Connector split and host count as the migration plan's foundation — revisiting this mid-migration because a Connector host is overloaded is expensive rework.

**Rollback:** N/A — this is a read-only planning step.

</details>

<details><summary>Playbook 2 — Bulk registration, sharing, and permission assignment via Graph</summary>

**Goal:** register and share a batch of printers with consistent permissions, scriptable and auditable.

```powershell
Connect-MgGraph -Scopes "Printer.ReadWrite.All","PrinterShare.ReadWrite.All"

# For Connector-registered printers, registration itself happens through the Connector
# app UI (there's no Graph endpoint that performs physical-printer registration) —
# this script picks up AFTER registration, for sharing and permissions at scale.

$printersToShare = Get-MgPrintPrinter -All | Where-Object { -not $_.IsShared }

foreach ($printer in $printersToShare) {
    $share = New-MgPrintShare -BodyParameter @{
        displayName = $printer.DisplayName
        printer     = @{ id = $printer.Id }
    }

    # Grant access to a group rather than individual users
    New-MgPrintShareAllowedGroupByRef -PrintShareId $share.Id -BodyParameter @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/groups/<GroupObjectId>"
    }

    Write-Host "Shared: $($printer.DisplayName) -> $($share.Id)"
}
```
Run against a small batch first and validate with the Validation Steps section before scaling to the full inventory.

**Rollback:** `Remove-MgPrintShare -PrintShareId <ShareId>` per printer unshares without touching the underlying registration; re-share when ready.

</details>

<details><summary>Playbook 3 — Migrating client deployment from legacy GPO/PrintProvisioning to Intune Settings Catalog</summary>

**Goal:** replace the old client-side delivery mechanism cleanly, avoiding a prolonged coexistence window.

1. In Intune admin center: **Devices → Manage devices → Configuration → Create → New policy** — Platform: Windows 10 and later, Profile type: Settings catalog
2. Add the **Printer Provisioning** setting; for each printer, set Action = Install and supply the printer's **Cloud Device ID**, **Printer Shared ID**, and **Printer Shared Name** (obtained from the Universal Print portal — Get-MgPrintPrinter/Get-MgPrintShare for the IDs)
3. Assign to the pilot-validated Entra Joined/Hybrid Entra Joined device group
4. Confirm delivery via Intune device configuration reporting, then confirm the printer actually installs on a real pilot device
5. Only once confirmed: remove the legacy GPO Group Policy Preference printer item (or disable the deprecated `printers.csv`-driven scheduled task, if that's what's in use) for the same device scope

```powershell
# Sanity check on a client after policy assignment
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\UniversalPrint" -ErrorAction SilentlyContinue
```
**Rollback:** Re-enable the legacy GPO item / re-link the GPO for the affected OU if the Intune policy needs to be paused — safe at any point before the legacy print server itself is decommissioned.

</details>

<details><summary>Playbook 4 — Windows Server 2016 Connector host job-success-rate mitigation</summary>

**Goal:** resolve the documented lower print-success-rate issue on Windows Server 2016 Connector hosts, common when a migration reuses an existing older print server box as the Connector host.

```powershell
# Option A (preferred): upgrade the Connector host OS to Windows Server 2022 or later

# Option B: apply KB5003638 or later, then enable the required feature override
# From an elevated Command Prompt on the Connector host:
reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides /v 2611563147 /t REG_DWORD /d 1 /f
Restart-Computer
```
Option C (if neither is feasible): host the Connector and its printers on a Windows 10 20H2+ machine instead of Server 2016.

**Rollback:** The registry override is narrowly scoped to this feature; removing the key and rebooting reverts the change if it causes an unrelated issue (unlikely, but consistent with the general principle of not leaving unexplained mitigations undocumented).

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Universal Print migration evidence for escalation — licensing, printer
    registration/sharing gaps, and client delivery-mechanism state.
#>
param(
    [string]$OutputPath = "."
)

Connect-MgGraph -Scopes "Printer.Read.All","PrinterShare.Read.All","Organization.Read.All" -NoWelcome

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Licensing
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "UNIVERSAL_PRINT" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N='Enabled';E={($_.PrepaidUnits).Enabled}} |
    Export-Csv -Path (Join-Path $OutputPath "UPMigration-Licensing-$stamp.csv") -NoTypeInformation

# Registered-but-unshared printers (the #1 migration support gap)
$printers = Get-MgPrintPrinter -All
$shares   = Get-MgPrintShare -All
$printers | Where-Object { $_.Id -notin $shares.PrinterId } |
    Select-Object DisplayName, Id, Manufacturer, Model |
    Export-Csv -Path (Join-Path $OutputPath "UPMigration-UnsharedPrinters-$stamp.csv") -NoTypeInformation

# Full printer/share inventory for cross-reference against the legacy print server list
$printers | Select-Object DisplayName, Id, IsShared, HasPhysicalDevice |
    Export-Csv -Path (Join-Path $OutputPath "UPMigration-PrinterInventory-$stamp.csv") -NoTypeInformation

Write-Host "Evidence written to $OutputPath (3 files, stamp $stamp)"
Write-Host "NOTE: run Get-ItemProperty on 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\UniversalPrint'"
Write-Host "and dsregcmd /status on the AFFECTED CLIENT DEVICE separately — those checks are local, not tenant-wide."
```

---

## Command Cheat Sheet

| Task | Method |
|---|---|
| Check Universal Print licensing in the tenant | `Get-MgSubscribedSku \| Where ServicePlans -match "UNIVERSAL_PRINT"` |
| List all registered printers | Graph: `GET /v1.0/print/printers` or `Get-MgPrintPrinter -All` |
| List all shares | Graph: `GET /v1.0/print/shares` or `Get-MgPrintShare -All` |
| Create a share for a registered printer | `New-MgPrintShare -BodyParameter @{ printer = @{ id = <PrinterId> } }` |
| Grant a group access to a share | `New-MgPrintShareAllowedGroupByRef -PrintShareId <Id> -BodyParameter @{ "@odata.id" = "<GroupUri>" }` |
| Inventory legacy print server queues | `Get-Printer -ComputerName <legacyServer>` |
| Check legacy GPO printer deployment on a client | `gpresult /r \| Select-String Printer` |
| Check Intune UniversalPrint CSP delivery on a client | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\UniversalPrint"` |
| Check client device join type (Intune UP policy eligibility) | `dsregcmd /status` |
| Check Connector host service state | `Get-Service "Universal Print Connector Host Service"` |
| Check Connector host memory headroom | `Get-CimInstance Win32_OperatingSystem \| Select FreePhysicalMemory,TotalVisibleMemorySize` |
| Test print an actual job | `Get-Printer -Name <name> \| Out-Printer` |
| Check a print job's state | `Get-MgPrintPrinterJob -PrinterId <Id>` |
| Detect the KB5083769 per-system printer regression | `Convert-UpPrinterToPerUser.ps1 -Detect` (from Microsoft's universal-print-resources GitHub repo) |
| Test outbound connectivity to the Universal Print service | `Test-NetConnection -ComputerName print.print.microsoft.com -Port 443` |

---

## 🎓 Learning Pointers

- **The migration is fundamentally an identity and network-model change, not a printer-by-printer technical migration.** Print queues move from AD DS/NTFS-ACL-governed objects on a server to Entra ID-governed cloud objects; client connectivity moves from "must be on the network/VPN" to "outbound HTTPS from anywhere." Framing the project this way to stakeholders explains both the security benefits and the reason a straight lift-and-shift mental model undersells what's actually changing. [MS Docs — Migrating to Universal Print from an on-premises solution](https://learn.microsoft.com/en-us/universal-print/migrating-from-on-prem) (ms.date 2024-03-15, updated 2025-02-07)

- **Registration and sharing are separate objects for a reason: it lets admins stage a migration (register everything, validate quietly) before exposing anything to end users.** Use that separation deliberately during a phased rollout rather than treating the two-step process as friction to route around.

- **The PrintProvisioning.exe + printers.csv tool is explicitly deprecated in current Microsoft guidance — new migrations should build directly on the Intune Settings Catalog Printer Provisioning profile (UniversalPrint CSP) and skip the older tool entirely**, even if older internal documentation or a legacy vendor guide still references it. [MS Docs — Create a Universal Print policy in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/configure-universal-print) (ms.date 2026-05-13, updated 2026-07-01)

- **Connector sizing is a memory-bound planning exercise, not a guess.** Microsoft's own tested baseline (~700MB per 100 registered printers, ~150 printers recommended max on a 4GB host, ~600 on an 8GB host) should directly drive how many Connector hosts a migration plan provisions — undersizing shows up as slow, flaky printing weeks after go-live, which is a much harder problem to diagnose than it is to plan around up front. [MS Docs — How many printers can the Connector support?](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-connector-how-many-printers)

- **The broader Windows printing platform shift reinforces the timing case for this migration.** Since January 15, 2026, Windows Update no longer auto-publishes new third-party V3/V4 legacy printer drivers for Windows 11/Windows Server 2025+, with Windows' internal driver-ranking logic set to prefer the built-in IPP Class Driver from July 1, 2026, and third-party driver updates via Windows Update largely ending July 1, 2027 (industry-reported timeline; no single consolidated MS Learn landing page for this policy exists as of this run — corroborated across multiple technical outlets covering Microsoft's official announcement). Universal Print's driverless Mopria/IPP model sidesteps this transition entirely rather than requiring driver-currency remediation on a legacy print server that's slated for retirement anyway.

- **Known client-side regressions can look like a migration defect when they're actually a Windows servicing issue.** The KB5083769+ per-system-vs-per-user Universal Print installation regression, and the printing-fails-after-swap issue when converting a Connector-registered printer to a UP-ready registration, are both documented Microsoft known issues with specific detection scripts and mitigations — check the known-issues list before assuming a migration step was done wrong. [MS Docs — Universal Print Known Issues](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-known-issues) (ms.date 2026-07-30)
