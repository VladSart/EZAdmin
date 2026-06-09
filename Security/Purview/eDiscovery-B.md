# eDiscovery — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>

# 2. Check active cases and holds
Get-ComplianceCase | Select Name, Status, CaseType, CreatedDateTime | Format-Table

# 3. Check a specific case hold status
Get-CaseHoldPolicy -Case "<CASE_NAME>" | Select Name, Status, IsEnabled, EnabledDate | Format-Table

# 4. Check content search status
Get-ComplianceSearch | Select Name, Status, JobProgress, ContentMatchQuery | Format-Table

# 5. Check export job status
Get-ComplianceSearchAction | Select Name, Status, JobStartTime, JobEndTime | Format-Table
```

| Output | Interpretation | Next Step |
|--------|---------------|-----------|
| `Get-ComplianceCase` errors with permissions | User lacks eDiscovery role | [Fix 1 — Assign eDiscovery Roles](#fix-1--assign-ediscovery-roles) |
| Case hold `Status = Error` | Hold distribution failed | [Fix 2 — Remediate Failed Case Hold](#fix-2--remediate-failed-case-hold) |
| Search `Status = Failed` | Query error or location error | [Fix 3 — Fix Failed Content Search](#fix-3--fix-failed-content-search) |
| Export `Status = Failed` | Export credential expired or storage full | [Fix 4 — Retry Failed Export](#fix-4--retry-failed-export) |
| Case hold enabled but mailbox content still deletable | Hold not yet distributed (propagation delay) | Wait 24–48 hrs; check `EnabledDate` |
| `Get-ComplianceCase` returns nothing | Case was accidentally deleted, or wrong region | [Fix 5 — Investigate Missing Case](#fix-5--investigate-missing-case) |

---
## Dependency Cascade

<details><summary>What must be true for eDiscovery to function</summary>

```
Microsoft Purview Compliance Center
  └── eDiscovery Role Group (or custom role)
        ├── Reviewer / eDiscovery Manager / eDiscovery Administrator
        └── Required roles: Case Management, Compliance Search, Hold, Export
              │
              ▼
        eDiscovery Case (Core or Premium)
              ├── Members → only case members can see case content
              ├── Case Hold Policy → targets: mailboxes, sites, Teams
              │     └── Hold Rules → can be query-based or full-content
              │           └── Propagation to Exchange (up to 24 hrs)
              │                 └── Items moved to DiscoveryHolds in Recoverable Items
              └── Content Search
                    ├── Query (KQL — keyword, date, sender, etc.)
                    ├── Locations (Exchange, SharePoint, Teams, etc.)
                    └── Export Job
                          └── Download via eDiscovery Export Tool (ClickOnce)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Verify role assignment**
```powershell
# Check which role groups the user belongs to
$user = "<USER_UPN>"
Get-RoleGroupMember -Identity "eDiscovery Manager" | Where-Object { $_.PrimarySmtpAddress -eq $user }
Get-RoleGroupMember -Identity "eDiscovery Administrator" | Where-Object { $_.PrimarySmtpAddress -eq $user }
```
- `eDiscovery Manager` → can see and manage only their own cases
- `eDiscovery Administrator` → can see ALL cases in the tenant; use sparingly

**Step 2 — Verify hold distribution to Exchange**
```powershell
# Check hold policy details
$case = "<CASE_NAME>"
Get-CaseHoldPolicy -Case $case | Select Name, Status, IsEnabled,
    ExchangeLocation, SharePointLocation | Format-List

# Check hold rule (query-based holds)
Get-CaseHoldRule -Policy (Get-CaseHoldPolicy -Case $case).Name |
    Select ContentMatchQuery, RetentionDuration | Format-List
```
- `Status = Pending` = still distributing (normal for first 24 hrs)
- `Status = Error` = one or more locations failed — check individual locations

**Step 3 — Verify content is actually being held**
```powershell
# Run a compliance search targeting the held mailbox to confirm content is present
New-ComplianceSearch -Name "HoldVerify_$(Get-Date -Format yyyyMMdd)" `
    -ExchangeLocation "<MAILBOX_ADDRESS>" `
    -ContentMatchQuery "received:01/01/2020..$(Get-Date -Format MM/dd/yyyy)"
Start-ComplianceSearch -Identity "HoldVerify_$(Get-Date -Format yyyyMMdd)"
# Check status after a few minutes:
Get-ComplianceSearch -Identity "HoldVerify_$(Get-Date -Format yyyyMMdd)" |
    Select Status, Items, Size
```

**Step 4 — Validate export is accessible**
```powershell
# List recent exports and their status
Get-ComplianceSearchAction -Export |
    Select Name, Status, JobStartTime, JobEndTime, ExportSizeInBytes | Format-Table
```
- Download requires the **eDiscovery Export Tool** (Windows only, ClickOnce)
- Get the export key from Compliance Center → the case → Exports tab → click the export name

---
## Common Fix Paths

<details><summary>Fix 1 — Assign eDiscovery Roles</summary>

**Symptom:** User gets "You don't have permission to view this case" or cmdlets return access denied.

```powershell
# Add user to eDiscovery Manager role group (standard - can only see their own cases)
Add-RoleGroupMember -Identity "eDiscovery Manager" -Member "<USER_UPN>"

# Verify
Get-RoleGroupMember -Identity "eDiscovery Manager" | Select Name, PrimarySmtpAddress

# For custom roles, add individual roles to a custom role group:
$roles = @("Case Management","Compliance Search","Hold","Export","Review","RMS Decrypt","Search And Purge")
# Create or update a custom role group in Compliance Center UI
# Or via PowerShell:
New-RoleGroup -Name "Custom-eDiscovery" -Roles $roles -Members "<USER_UPN>"
```

**Note:** Role propagation takes 30–60 minutes. User must sign out and back in to the Compliance Center.

</details>

<details><summary>Fix 2 — Remediate Failed Case Hold</summary>

**Symptom:** `Get-CaseHoldPolicy` shows `Status = Error` on one or more locations.

```powershell
$case = "<CASE_NAME>"
$holdPolicy = Get-CaseHoldPolicy -Case $case

# Get detailed error info
$holdPolicy | Select -ExpandProperty ExchangeLocationException
$holdPolicy | Select -ExpandProperty SharePointLocationException

# Common causes:
# - Mailbox was deleted → remove from hold locations
# - Site was deleted → remove from hold locations
# - Mailbox is on litigation hold from different admin (not an error, just redundant)

# To remove a failed location and re-distribute the hold:
Set-CaseHoldPolicy -Identity $holdPolicy.Name `
    -RemoveExchangeLocation "<FAILED_MAILBOX>" `
    -RetryDistribution

# Force re-distribution across all locations
Set-CaseHoldPolicy -Identity $holdPolicy.Name -RetryDistribution
```

**After:** Wait 1–2 hours, then re-check `Status`. It should move from `Pending` back to `Enabled`.

</details>

<details><summary>Fix 3 — Fix Failed Content Search</summary>

**Symptom:** `Get-ComplianceSearch` shows `Status = Failed` or `JobProgress` stalled.

```powershell
$searchName = "<SEARCH_NAME>"

# Check detailed failure info
Get-ComplianceSearch -Identity $searchName | Select -ExpandProperty Errors

# Common causes:
# A) Query syntax error → test KQL query in Compliance Center search builder first
# B) Location not accessible → check if mailbox/site exists
# C) Search timed out (very large result set) → narrow the query

# Retry a failed search
Start-ComplianceSearch -Identity $searchName -RetryOnError

# If query is the problem, update and retry
Set-ComplianceSearch -Identity $searchName `
    -ContentMatchQuery "received:01/01/2024..12/31/2024 AND from:<SENDER_EMAIL>"
Start-ComplianceSearch -Identity $searchName
```

**KQL quick reference:**
```
# Date range
received:2024-01-01..2024-12-31

# Sender
from:user@domain.com

# Subject keyword
subject:"project alpha"

# File type (SharePoint/OneDrive)
filetype:xlsx

# Combine
from:user@domain.com AND received:2024-01-01..2024-12-31 AND subject:"confidential"
```

</details>

<details><summary>Fix 4 — Retry Failed Export</summary>

**Symptom:** Export shows `Status = Failed` or download won't start.

```powershell
$searchName = "<SEARCH_NAME>"

# Check existing export action
Get-ComplianceSearchAction -Identity "${searchName}_Export" | Select Status, JobEndTime

# Delete failed export action and recreate
Remove-ComplianceSearchAction -Identity "${searchName}_Export" -Confirm:$false

# Recreate export action
New-ComplianceSearchAction -SearchName $searchName -Export `
    -ExchangeArchiveFormat PerUserPst `
    -SharePointArchiveFormat IndividualMessage `
    -EnableDedupe $true `
    -Scope BothIndexedAndUnindexedItems
```

**Export download issues:**
- Tool requires Internet Explorer or Edge in IE compatibility mode (legacy ClickOnce requirement)
- If export tool won't install: run as administrator, check .NET 4.5+ is installed
- Alternative: Use **Microsoft Purview eDiscovery (Premium)** review sets — avoids the export tool entirely for large cases

</details>

<details><summary>Fix 5 — Investigate Missing Case</summary>

**Symptom:** A case you know existed is no longer visible.

```powershell
# Check all cases including closed ones
Get-ComplianceCase -State All | Select Name, Status, CreatedDateTime, ClosedDateTime | Format-Table

# A closed case is not deleted — reopen it
Set-ComplianceCase -Identity "<CASE_NAME>" -Status Active

# If case truly doesn't appear (requires eDiscovery Administrator role):
# eDiscovery Admins can see ALL cases regardless of membership
# Regular eDiscovery Managers only see cases they're members of
# → Check if you need to be added as a case member
```

</details>

---
## Escalation Evidence

```
TICKET ESCALATION: eDiscovery Issue
=====================================
Admin UPN:              ___________________________
Case name:              ___________________________
Case type:              Core eDiscovery / Premium eDiscovery
Issue type:             Hold / Search / Export / Permissions
Hold policy status:     Enabled / Pending / Error
Failed locations:       ___________________________
Search status:          ___________________________
Export status:          ___________________________
Error message (exact):  ___________________________
Role groups assigned:   ___________________________
Date issue started:     ___________________________
Compliance Center URL:  https://compliance.microsoft.com
Support path:           Microsoft 365 Admin → Support → New service request
                        (eDiscovery issues require Compliance support, not Exchange)
```

---
## 🎓 Learning Pointers

- **Core vs Premium eDiscovery**: Core eDiscovery (included in most M365 plans) supports basic search, hold, and export. Premium eDiscovery (E5 or add-on) adds custodian management, review sets, analytics, predictive coding, and Teams conversation threading. If you're doing serious litigation response, Premium is worth the cost — the review set workflow alone eliminates the export tool dependency. [MS Docs — eDiscovery overview](https://learn.microsoft.com/en-us/purview/ediscovery)
- **eDiscovery holds vs litigation holds**: Both preserve content. eDiscovery holds are tied to a case — they disappear if the case is deleted. Litigation holds persist on the mailbox independently. For long-running legal matters, litigation hold is more resilient; for scoped investigations, eDiscovery case holds are better audited.
- **The ClickOnce export tool trap**: The legacy export tool requires Windows + specific browser settings. Many organisations are blocked because their users are on locked-down browsers or macOS. Plan: use eDiscovery Premium review sets, or use the Microsoft Graph eDiscovery API (`/v1.0/compliance/ediscovery`) for programmatic export. [Graph eDiscovery API](https://learn.microsoft.com/en-us/graph/api/resources/ediscovery-ediscoveryapioverview)
- **Propagation delays are real**: A new case hold takes up to 24 hours to fully distribute to all Exchange and SharePoint locations. During this window, the hold is `Pending` — content is NOT yet preserved. For urgent preservation, use PowerShell to set litigation hold immediately while the case hold propagates.
- **Search all vs search specific**: Default `ExchangeLocation = All` searches the entire tenant. Scope searches narrowly for performance and to avoid privilege/access issues with sensitive mailboxes. Always confirm search scope with the legal team before running.
- **eDiscovery audit trail**: All eDiscovery actions (case creation, hold application, search, export) are logged in the Unified Audit Log. Search via Compliance Center → Audit → filter on `eDiscovery` activities. This is your evidence that due diligence was performed during legal holds. [MS Docs — eDiscovery audit log](https://learn.microsoft.com/en-us/purview/ediscovery-search-the-audit-log)
