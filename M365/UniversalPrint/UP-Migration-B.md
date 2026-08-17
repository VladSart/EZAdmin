# Universal Print Migration (On-Premises Print Server → Universal Print) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Triage

**This file is for problems that occur DURING a migration off an on-premises print server onto Universal Print (UP)** — eligibility, connector sizing, bulk registration, Intune deployment of the new policy, and cutover/decommission. If Universal Print itself is already the steady-state solution and something in it just broke, that's `Universal-Print-B.md`, not this file. If you're migrating between two on-prem print servers (not eliminating the server), that's `Windows/Troubleshooting/PrintServerMigration-B.md`.

```powershell
# 1. Is Universal Print actually licensed/enabled in this tenant, and does the operator have a UP admin role?
Connect-MgGraph -Scopes "Printer.Read.All","PrinterShare.Read.All"
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "UNIVERSAL_PRINT" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N='Enabled';E={($_.PrepaidUnits).Enabled}}

# 2. For the printer(s) in question: is this model actually "Universal Print ready", or does it need the Connector?
#    (Check https://aka.ms/UPPrinterList — there is no PowerShell cmdlet for this, it's a curated list)
#    If a connector is in play, confirm it's registered and reachable:
Get-Service "PrintServiceUniversal","Universal Print Connector Host Service" -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType

# 3. Was this printer actually registered AND shared? (registration ≠ visibility to users — two separate steps)
Get-MgPrintPrinter -PrinterId "<PrinterId>" | Select-Object DisplayName, IsShared
Get-MgPrintShare | Where-Object DisplayName -like "*<PrinterName>*" | Select-Object DisplayName, Id

# 4. Is the client's printer policy still the OLD delivery mechanism (GPO Group Policy Preference,
#    logon-script UNC mapping, or the deprecated PrintProvisioning tool + printers.csv) instead of
#    the current Intune Settings Catalog "Printer Provisioning" policy (UniversalPrint CSP)?
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\UniversalPrint" -ErrorAction SilentlyContinue

# 5. Is the client actually Entra ID Joined (or Hybrid Entra Joined)? Workplace-registered (BYOD)
#    devices cannot receive UP printers via Intune provisioning — this trips up more migrations than
#    any actual UP fault does.
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|WorkplaceJoined"
```

| What you see | What it means |
|---|---|
| No `UNIVERSAL_PRINT` service plan enabled, or `ConsumedUnits` = 0 | Licensing not assigned to the users/admins doing the migration — stop and fix licensing before anything else (Fix 1) |
| Printer isn't on the UP-ready list and no Connector service is running anywhere | Migration for this printer was never actually started — this isn't a break, it's an unfinished plan (Fix 2) |
| Printer shows registered (`Get-MgPrintPrinter` returns it) but `Get-MgPrintShare` returns nothing for it | Registered but never shared — invisible to every user regardless of permissions (Fix 3) |
| Users still print through the old print server after "migration complete" was declared | Legacy GPO Printer Preference / mapped UNC / logon script was never removed — old and new coexist and old usually wins (Fix 4) |
| Intune reports the printer policy assigned and succeeded, but the printer never appears on the device | Device is Workplace-registered (BYOD), not Entra Joined/Hybrid Entra Joined — Intune UP provisioning silently cannot target it (Fix 5) |
| Printer prints fine from the UP portal test but fails/hangs from an actual client | Connector-side driver or Print Support App conflict introduced during the cutover (Fix 6) |
| Two entries for the same physical printer show up for users (old print-server-published queue + new UP queue) | Old server printer wasn't unpublished/removed from the deployment mechanism before or during rollout — user confusion, not a technical fault (Fix 4) |

---

## Dependency Cascade

<details><summary>What must be true — migration path, both branches</summary>

```
Universal Print license assigned (users to print, admins to manage) +
Entra ID role: Global Administrator, Printer Administrator, or Printer Technician
        │
        ▼
Per-printer eligibility decision (this is made ONCE per physical printer, at
migration-plan time — getting it wrong is the #1 cause of migration rework)
        │
        ├── Printer model IS on the "Universal Print ready" list
        │     → Printer connects to Universal Print cloud service DIRECTLY
        │     → NO on-prem component required for this printer, ever, going forward
        │
        └── Printer model is NOT Universal Print ready
              → Universal Print Connector required (installed on an always-on
                Windows 11 / Windows Server 2019+ host — 2022/2025 recommended,
                2016 has a known lower job-success-rate issue)
              → Connector registers the printer's queue with the UP cloud service
              → Connector becomes a single point of failure for every printer behind it
        │
        ▼ (both branches converge here)
Printer registered with Universal Print (Entra ID object created for the printer)
        │
        ▼
Printer SHARED (a separate, explicit step — registration alone is invisible to users)
        │
        ▼
Users/groups granted access to the share
        │
        ▼
Client-side delivery mechanism REPLACED:
   OLD: GPO Group Policy Preference printer deployment / logon-script UNC mapping /
        deprecated PrintProvisioning.exe + printers.csv tool
   NEW: Intune Settings Catalog "Printer Provisioning" policy (UniversalPrint CSP) —
        requires the target device to be Entra Joined or Hybrid Entra Joined,
        NOT Workplace-registered (BYOD)
        │
        ▼
CUTOVER: old print server's queues unpublished from AD DS / removed from GPO,
old delivery mechanism policy unassigned — kept running (disconnected from
production traffic, not powered off) for a validation window before decommission
        │
        ▼
User prints — client → UP cloud service → (Connector → printer) OR (direct to
UP-ready printer) — same end state regardless of which branch was taken above
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm licensing and role before assuming anything technical is broken:**
```powershell
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "UNIVERSAL_PRINT" }
```
Expected: at least one enabled service plan with `ConsumedUnits` matching your migrating user population. If this is empty, nothing downstream will work — this is a licensing/procurement problem, not a technical fault.

**2. Confirm the eligibility decision was actually made and acted on for this printer:**
```powershell
Get-MgPrintPrinter | Where-Object DisplayName -like "*<PrinterName>*" | Select-Object DisplayName, HasPhysicalDevice, IsShared
```
Expected: the printer exists as a registered object. If it doesn't exist at all, migration for this specific printer hasn't started — check the Connector (if applicable) or confirm someone attempted direct registration.

**3. Confirm registration AND sharing (these are two separate objects, not one):**
```powershell
$printer = Get-MgPrintPrinter | Where-Object DisplayName -like "*<PrinterName>*"
Get-MgPrintShare | Where-Object { $_.PrinterId -eq $printer.Id }
```
Expected: a share object referencing the printer. A registered-but-unshared printer is invisible to every user regardless of how correctly everything else was done.

**4. Confirm the client's delivery mechanism is the NEW one, not a leftover of the old one:**
```powershell
# On a migrated client
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\UniversalPrint" -ErrorAction SilentlyContinue
gpresult /r | Select-String "Printer"
```
Expected: the UniversalPrint CSP key is present (Intune delivered it) and `gpresult` shows no printer-related GPO still applying. Both present at once is exactly the coexistence bug that confuses users during a migration.

**5. Confirm device join type before blaming Universal Print for a delivery failure:**
```powershell
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|WorkplaceJoined"
```
Expected: `AzureAdJoined : YES` or (`DomainJoined : YES` + `AzureAdJoined : YES` for Hybrid). `WorkplaceJoined : YES` alone means Intune UP provisioning cannot target this device — this is a device-enrollment gap, not a print fault.

**6. Only after the above pass: print an actual end-to-end test job:**
```powershell
Get-Printer -Name "<MigratedPrinterName>" | Out-Printer
```
Confirms the full chain (client → UP cloud → connector or direct printer) actually delivers a page, not just that the portal shows the printer as registered.

---

## Common Fix Paths

<details><summary>Fix 1 — Universal Print not licensed / role missing</summary>

**Symptom:** No `UNIVERSAL_PRINT` service plan shows enabled, or the operator can't see printers/connectors in the portal.

```powershell
# Confirm which SKUs in the tenant actually include Universal Print entitlement
Get-MgSubscribedSku | Select-Object SkuPartNumber, ServicePlans |
    Where-Object { $_.ServicePlans.ServicePlanName -contains "UNIVERSAL_PRINT_NO_ADDON" -or
                   $_.ServicePlans.ServicePlanName -contains "UNIVERSAL_PRINT" }

# Assign the eligible admin role
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"
$roleId = (Get-MgDirectoryRole -Filter "DisplayName eq 'Printer Administrator'").Id
New-MgDirectoryRoleMemberByRef -DirectoryRoleId $roleId -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/<UserObjectId>"
}
```
**Rollback:** N/A — assigning a license or a role is additive; remove the role assignment if granted in error (`Remove-MgDirectoryRoleMemberByRef`).

</details>

<details><summary>Fix 2 — Printer eligibility never actually decided/acted on</summary>

**Symptom:** Printer isn't registered, no Connector is running for it, and nobody can say whether it's supposed to be direct or Connector-based.

```powershell
# Check the printer against the UP-ready list is a manual step — there is no API for this.
# https://aka.ms/UPPrinterList

# If NOT UP-ready, deploy/verify a Connector host, then register via the Connector app UI
# (registration itself is done through the Connector application, not PowerShell)
Get-Service "Universal Print Connector Host Service" -ErrorAction SilentlyContinue

# If UP-ready, the printer's own admin/setup screen has the Universal Print enrollment option —
# check the vendor's manual; there is no centralized Microsoft tool that does this remotely
```
**Rollback:** N/A — this is completing an unfinished plan step, not undoing anything.

</details>

<details><summary>Fix 3 — Printer registered but never shared (invisible to users)</summary>

**Symptom:** Printer exists in the portal/Graph, admins can see it, but no user can find it to install.

```powershell
Connect-MgGraph -Scopes "PrinterShare.ReadWrite.All"
$printer = Get-MgPrintPrinter | Where-Object DisplayName -like "*<PrinterName>*"

New-MgPrintShare -BodyParameter @{
    displayName = "<ShareDisplayName>"
    printer     = @{ id = $printer.Id }
}

# Then grant access — either everyone, or a specific group
$share = Get-MgPrintShare | Where-Object DisplayName -eq "<ShareDisplayName>"
New-MgPrintShareAllowedGroupByRef -PrintShareId $share.Id -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/groups/<GroupObjectId>"
}
```
**Rollback:** `Remove-MgPrintShare -PrintShareId $share.Id` unshares it again — the underlying printer registration is untouched.

</details>

<details><summary>Fix 4 — Legacy delivery mechanism never removed (old and new printer both show up)</summary>

**Symptom:** Users see two entries for what should be one printer, or continue printing through the old print server despite the migration being "done."

```powershell
# On the print server / via GPMC: remove the Group Policy Preference printer item,
# or unpublish the shared printer from AD DS so it stops offering itself
Get-Printer | Where-Object { $_.Published } | Set-Printer -Published $false

# Force a policy refresh on affected clients so the GPO removal actually lands
gpupdate /force
```
This is the same "unpublish before rename" discipline as a server-to-server print migration — see `Windows/Troubleshooting/PrintServerMigration-B.md` Fix 6 for the AD DS duplicate-entry pattern this mirrors. Communicate the cutover date to users so they know which printer to expect to disappear.

**Rollback:** Re-publish the old printer (`Set-Printer -Published $true`) and re-add the GPO item if the cutover needs to be paused — safe as long as the print server itself hasn't been decommissioned yet.

</details>

<details><summary>Fix 5 — Device is Workplace-registered (BYOD), Intune UP policy can't target it</summary>

**Symptom:** Intune shows the printer provisioning policy as "succeeded" for the device, but the printer never installs.

```powershell
dsregcmd /status | Select-String "AzureAdJoined|WorkplaceJoined"
```
If `WorkplaceJoined : YES` and `AzureAdJoined : NO`, this device is out of scope for Intune-delivered Universal Print policies by design. Options: have the user install the printer manually from the Universal Print client experience (if licensed to do so), or re-enroll the device as Entra Joined/Hybrid Entra Joined if that's an option for this device class.

**Rollback:** N/A — this is a scoping clarification, not a change to revert.

</details>

<details><summary>Fix 6 — Printer works from the UP portal test but fails/hangs from a real client (post-cutover)</summary>

**Symptom:** `Get-MgPrintPrinterJob` shows successful test jobs from the portal, but real user print jobs stall or error.

```powershell
# On the Connector host, check for a competing Print Support App (PSA) auto-installed
# during driver cleanup as part of the cutover — a known issue for Xerox/Kyocera specifically
Get-AppxPackage | Where-Object { $_.Name -match "Xerox|Kyocera" }

# If found, remove it — PSAs installed alongside Connector-registered printers block printing
Get-AppxPackage -Name "*Xerox*" | Remove-AppxPackage
```
If the Connector host itself is Windows Server 2016, this is also the documented lower-job-success-rate known issue — upgrade the host to Windows Server 2022+ or apply KB5003638 with the registry mitigation (see `UP-Migration-A.md` Remediation Playbooks for the full fix).

**Rollback:** Reinstalling the PSA is non-destructive if removing it doesn't resolve the issue — it just re-introduces the original symptom.

</details>

---

## Escalation Evidence

```
=== Universal Print Migration Failure — Ticket Evidence ===

Date/Time:                                _______________
Printer / queue affected:                 _______________
Migration phase:                          _______________  (Eligibility / Registration / Sharing / Client Deployment / Cutover)
Direct (UP-ready) or Connector-based:      _______________
Connector host name (if applicable):       _______________

--- Commands Run ---
UNIVERSAL_PRINT service plan enabled?:     _______________
Printer registered (Get-MgPrintPrinter)?:  _______________
Printer shared (Get-MgPrintShare)?:        _______________
Device join type (dsregcmd /status):       _______________
Legacy GPO/printer policy still present?:  _______________

--- Scenario ---
[ ] Licensing/role missing
[ ] Printer eligibility never decided or acted on
[ ] Registered but not shared
[ ] Legacy delivery mechanism (GPO/logon script) not removed — duplicate printer
[ ] Device is Workplace-registered (BYOD), Intune policy can't target it
[ ] Portal test job succeeds but real client jobs fail (Connector/PSA/driver issue)
[ ] Cutover/decommission timing or rollback question

--- Steps Taken ---
[ ] Verified licensing and admin role
[ ] Confirmed printer eligibility (UP-ready vs. Connector) matches how it was actually deployed
[ ] Confirmed both registration AND sharing exist
[ ] Confirmed client device join type (Entra Joined / Hybrid / NOT Workplace-registered)
[ ] Confirmed old delivery mechanism (GPO/logon script/deprecated printers.csv tool) removed
```

---

## 🎓 Learning Pointers

- **Registration and sharing are two separate objects — treat them as two separate checks, every time.** A printer can be fully "migrated" from an infrastructure standpoint and still be invisible to every single user because the share step was skipped. This is the single most common migration-day support ticket. [MS Docs — Migrating to Universal Print from an on-premises solution](https://learn.microsoft.com/en-us/universal-print/migrating-from-on-prem)

- **The PrintProvisioning tool and printers.csv workflow are deprecated — use the Intune Settings Catalog "Printer Provisioning" profile (UniversalPrint CSP) for all new migrations.** If you inherit a migration project using the old tool, plan to re-platform the deployment mechanism, not just the printers. [MS Docs — Create a Universal Print policy in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/configure-universal-print)

- **Intune-delivered Universal Print policies only reach Entra Joined or Hybrid Entra Joined devices — Workplace-registered (BYOD) devices are out of scope by design.** Confirm device join type early in a migration pilot, not after a wave of "the printer never showed up" tickets.

- **A Connector host running Windows Server 2016 has a documented lower print job success rate** — upgrading to Windows Server 2022+ (or applying KB5003638 with its registry mitigation) before migration day avoids a wave of intermittent failures that look like a Universal Print problem but are a Connector-host OS issue. [MS Docs — Universal Print Known Issues](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-known-issues)

- **The old print server should stay running-but-disconnected for a validation window, not be powered off on cutover day.** This mirrors standard print server decommission practice and gives a clean, low-effort rollback path if the migration surfaces an issue after the fact — see `PrintServerMigration-B.md` for the equivalent pattern in a server-to-server migration.

- **Sizing the Connector matters before migration day, not after.** A Standard_B2s VM (2 vCPU/4GB) supports roughly 150 printers; a Standard_B2ms (2 vCPU/8GB) supports roughly 600 — memory usage scales at about 700MB per 100 registered printers. Undersizing shows up as slow printer enumeration and unreliable job delivery, not an outright failure. [MS Docs — How many printers can the Connector support?](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-connector-how-many-printers)
