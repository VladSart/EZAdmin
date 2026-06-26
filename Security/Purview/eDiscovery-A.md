# eDiscovery — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**Covers:**
- Microsoft Purview eDiscovery (Core) and eDiscovery (Premium) — formerly Advanced eDiscovery
- Case hold policy distribution to Exchange Online, SharePoint Online, OneDrive, Teams
- Content search, KQL query construction, and export workflow
- Role and permission troubleshooting for compliance admins and legal teams
- Graph eDiscovery API (`/v1.0/compliance/ediscovery`) as a modern alternative to ClickOnce

**Does not cover:**
- On-premises Exchange eDiscovery (In-Place eDiscovery via EAC — deprecated)
- Litigation holds (covered separately; different mechanism, same preservation outcome)
- Purview Communication Compliance or Insider Risk (see their own runbooks)

**Assumed:** You have Global Admin or Compliance Admin access and can connect to Security & Compliance PowerShell:
```powershell
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>
```

---
## How It Works

<details><summary>Full architecture — eDiscovery end to end</summary>

### The Two Products

**eDiscovery (Core)**
Available in M365 Business Premium, E3, and above. Provides:
- Case-based organisation (cases scoped to legal matters)
- Case holds — preserves content in Exchange, SharePoint, OneDrive, Teams
- Content Search — KQL-based queries across all workloads
- Export — PST or individual messages; requires Windows ClickOnce export tool

**eDiscovery (Premium)**
Requires E5 or the M365 E5 Compliance add-on. Adds:
- Custodian management — link a legal hold to specific people
- Review sets — cloud-based document review without export tool
- Analytics — near-duplicate detection, email threading, themes
- Predictive coding (relevance scoring using machine learning)
- Graph API access to all case objects
- Teams conversation threading (Premium correctly reconstructs chat threads; Core shows raw messages)

---

### How Case Holds Work (Exchange internals)

When a case hold is applied to a mailbox, the Managed Folder Assistant (MFA) instructs Exchange to set `InPlaceHolds` on the mailbox. Items become immovable from the Recoverable Items subtree:

```
User mailbox (Inbox, Sent, etc.)
  └── Recoverable Items (hidden, quota 30GB for hold mailboxes)
        ├── Deletions      ← soft-deleted items land here
        ├── Purges         ← items purged from Deletions land here
        ├── DiscoveryHolds ← items held by eDiscovery/litigation hold copy here
        └── Versions       ← modification snapshots for holds with date ranges
```

When a user deletes a message:
1. It moves to Deletions subfolder (recoverable by user via Recover Deleted Items)
2. If the item matches a hold query (or hold is non-query-based), the MFA copies it to DiscoveryHolds before the retention timer expires
3. The item cannot be permanently purged while the hold is active

**Propagation:** Hold distribution is not instantaneous. The compliance engine queues the hold, and individual mailbox servers process it asynchronously — typically 1–24 hours. `Status = Pending` is normal for fresh holds.

---

### How Content Search Works

Content Search uses a distributed query engine that fans out to:
- **Exchange Online**: searches primary and archive mailboxes, recoverable items, inactive mailboxes
- **SharePoint Online**: document libraries, lists (limited), OneNote
- **OneDrive for Business**: user drives
- **Microsoft Teams**: Teams conversations (backed by hidden Exchange mailboxes), channel files (SPO)
- **Yammer/Viva Engage**: if M365 Connected Groups used

The query language is **KQL (Keyword Query Language)**:
```
# Message properties
from:sender@domain.com
to:recipient@domain.com
subject:"project phoenix"
received:2024-01-01..2024-12-31
hasattachment:true

# Document properties (SharePoint/OneDrive)
author:"Jane Smith"
filetype:docx
created:2024-01-01..2024-12-31
title:"budget"

# Combine
(from:cfo@company.com OR from:ceo@company.com) AND received:2024-01-01.. AND subject:"acquisition"
```

**Unindexed items:** Items that can't be indexed (corrupted, encrypted, unsupported file type) are returned as "unindexed items" when `Scope = BothIndexedAndUnindexedItems`. Always include unindexed items in legal holds exports — opposing counsel will ask.

---

### Export Mechanics

Export is a two-step process:
1. **New-ComplianceSearchAction -Export**: Creates an export job that stages content in a temporary Azure Blob (Microsoft-managed). Runs in the background.
2. **Download via export tool**: A Windows ClickOnce application (`microsoft.office.client.discovery.unifiedexporttool.application`) downloads the staged content.

The staging blob expires after **30 days** — after that the export must be recreated.

**PST vs loose files:**
- `PerUserPst`: one PST per mailbox — best for mail-heavy cases
- `SinglePst`: all content in one PST — problematic for large cases (PST corruption risk >50GB)
- `IndividualMessage`: loose `.msg` files — best for document-heavy cases or Review Set import

**eDiscovery Premium alternative:** Review sets avoid the export tool entirely. Content is loaded into a cloud-hosted review set where reviewers can tag, annotate, and redact. Export from a review set uses the same export tool, but the review set itself is the primary workflow.

</details>

---
## Dependency Stack

```
Microsoft Purview Compliance Center
  └── eDiscovery Role Group assignment
        ├── eDiscovery Administrator  → sees ALL cases tenant-wide
        ├── eDiscovery Manager        → sees only cases they're added to
        └── Individual roles (if custom RG):
              Case Management | Compliance Search | Hold | Export
              Preview | Review | RMS Decrypt | Search And Purge
                │
                ▼
        eDiscovery Case (Core or Premium)
              ├── Case Members → controls access within the case
              ├── Case Hold Policy
              │     ├── Exchange locations (mailboxes, distribution groups)
              │     ├── SharePoint/OneDrive locations (site URLs)
              │     └── Case Hold Rule → optional KQL filter + retention duration
              │           │
              │           ▼
              │     Exchange Online Managed Folder Assistant
              │           └── InPlaceHolds on mailbox object
              │                 └── Recoverable Items / DiscoveryHolds
              │
              ├── Content Search
              │     ├── Locations (Exchange, SPO, OD, Teams, Yammer)
              │     ├── KQL Query
              │     └── Distributed search engine → index per workload
              │           └── Results: estimated count, size, unindexed items
              │
              └── Export Action (ComplianceSearchAction)
                    ├── Azure Blob staging (Microsoft-managed, 30-day expiry)
                    └── ClickOnce Export Tool (Windows, .NET 4.5+)
                          └── PST / loose .msg files / ZIP

eDiscovery Premium adds:
  ├── Custodians (persons under legal hold)
  │     └── Additional data sources: mailbox + OneDrive + Teams + Yammer
  ├── Review Sets (cloud document review environment)
  │     ├── Analytics (near-dupe, email threading, themes)
  │     ├── Predictive Coding (relevance ML)
  │     └── Annotations / Redactions
  └── Graph eDiscovery API
        └── /v1.0/compliance/ediscovery/*
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| "You don't have permission to view this case" | User not in eDiscovery Manager role group, or not a case member | `Get-RoleGroupMember -Identity "eDiscovery Manager"` |
| Case hold `Status = Error` | One or more locations unreachable (deleted mailbox/site) | `$hold \| Select -ExpandProperty ExchangeLocationException` |
| Case hold `Status = Pending` for >48 hrs | Distribution backlog (unusual); large number of locations | Check Service Health dashboard for Compliance issues |
| Content search `Status = Failed` | Invalid KQL syntax, inaccessible location, search timeout | `Get-ComplianceSearch \| Select -ExpandProperty Errors` |
| Search returns 0 items but content definitely exists | Wrong location selected; date range mismatch; KQL too narrow | Broaden query; confirm mailbox address is correct |
| Export `Status = Failed` | Azure blob issue; export key expired; re-run required | Delete and recreate `ComplianceSearchAction` |
| Export tool won't install | Browser compatibility; .NET version; ClickOnce blocked | Use Edge in IE mode; run as admin; check AppLocker |
| Export tool installs but stalls at 0% | Network firewall blocking Azure Blob endpoints | Check `*.blob.core.windows.net` and `*.protection.outlook.com` connectivity |
| User deletes content but it appears preserved in search | Hold working correctly — content is in DiscoveryHolds | Expected behaviour; explain to legal team |
| User deletes content and it's gone despite hold | Hold not yet propagated (< 24 hrs); or hold targeted wrong mailbox | Verify `InPlaceHolds` on mailbox; check `ExchangeLocation` list |
| Teams content missing from search | Teams uses Exchange-backed mailboxes; search must include those | Include group mailbox and user mailbox; Premium required for threading |
| Inactive mailbox not searchable | Inactive mailbox not added to hold/search locations | Add by primary SMTP: `-ExchangeLocation <SMTP>` |

---
## Validation Steps

**Step 1 — Confirm role group membership**
```powershell
$user = "<USER_UPN>"
foreach ($rg in @("eDiscovery Manager","eDiscovery Administrator","Organization Management","Compliance Administrator")) {
    $member = Get-RoleGroupMember -Identity $rg -ErrorAction SilentlyContinue |
              Where-Object { $_.PrimarySmtpAddress -eq $user }
    if ($member) { Write-Host "$rg : MEMBER" -ForegroundColor Green }
    else          { Write-Host "$rg : not a member" -ForegroundColor Yellow }
}
```
Expected: user is a member of `eDiscovery Manager` or `eDiscovery Administrator`.

**Step 2 — Validate hold distribution**
```powershell
$case = "<CASE_NAME>"
$policy = Get-CaseHoldPolicy -Case $case
$policy | Select Name, Status, IsEnabled, EnabledDate,
                ExchangeLocation, SharePointLocation | Format-List

# Verify hold is set on the mailbox object itself
$mailbox = "<MAILBOX_UPN>"
(Get-Mailbox $mailbox -ErrorAction SilentlyContinue).InPlaceHolds
# Should include a GUID starting with "UniH" (eDiscovery hold) or "mbx" (litigation hold)
```
Expected: `Status = Enabled`, `InPlaceHolds` contains the hold GUID.

**Step 3 — Validate content is being preserved**
```powershell
$searchName = "HoldVerify_$(Get-Random)"
New-ComplianceSearch -Name $searchName `
    -ExchangeLocation "<MAILBOX_UPN>" `
    -ContentMatchQuery "received:01/01/2020..$(Get-Date -Format MM/dd/yyyy)"
Start-ComplianceSearch -Identity $searchName

# Poll status (should move from NotStarted → InProgress → Completed)
do {
    $s = Get-ComplianceSearch -Identity $searchName
    Write-Host "Status: $($s.Status) | Items: $($s.Items) | Size: $($s.Size)"
    Start-Sleep 10
} while ($s.Status -ne "Completed")

# Cleanup
Remove-ComplianceSearch -Identity $searchName -Confirm:$false
```
Expected: `Status = Completed`, `Items > 0` if mailbox has content in the date range.

**Step 4 — Validate export readiness**
```powershell
Get-ComplianceSearchAction -Export |
    Select Name, Status, JobStartTime, JobEndTime, ExportSizeInBytes |
    Format-Table

# Confirm export key is still valid (< 30 days old)
$export = Get-ComplianceSearchAction -Identity "<SEARCH_NAME>_Export"
$age = (Get-Date) - $export.JobStartTime
if ($age.Days -gt 29) { Write-Warning "Export is expired — recreate it" }
```
Expected: `Status = Completed`, export age < 30 days.

**Step 5 — Verify Teams content is included**
```powershell
# Teams channel messages are stored in a group/shared mailbox
# Teams chat (1:1 and group) are stored in individual user mailboxes

# Find the Teams group mailbox for a Team
Get-UnifiedGroup -Identity "<TEAM_DISPLAY_NAME>" | Select PrimarySmtpAddress
# Add this address to ExchangeLocation in your search
```

---
## Troubleshooting Steps by Phase

### Phase 1 — Access & Permissions

**Problem: eDiscovery Manager can't see a specific case**
The eDiscovery Manager role allows a user to manage cases they are a member of. They do NOT see all cases automatically.

```powershell
# Add user as a case member
Add-ComplianceCaseMember -Case "<CASE_NAME>" -Member "<USER_UPN>"
```

**Problem: Custom role group missing required permissions**
Legal teams often need a custom role group. Minimum roles for full eDiscovery workflow:
```powershell
$requiredRoles = @(
    "Case Management",
    "Compliance Search",
    "Hold",
    "Export",
    "Preview",
    "Review",
    "RMS Decrypt"
)
New-RoleGroup -Name "Legal-eDiscovery" -Roles $requiredRoles -Members "<USER_UPN1>","<USER_UPN2>"
```

---

### Phase 2 — Hold Distribution Failures

**Problem: Hold Status = Error on specific Exchange locations**

```powershell
$case   = "<CASE_NAME>"
$policy = Get-CaseHoldPolicy -Case $case

# Surface failed locations
$policy.ExchangeLocationException
$policy.SharePointLocationException

# Common cause: mailbox deleted, renamed, or migrated
# Verify the mailbox exists:
Get-Mailbox -Identity "<FAILED_ADDRESS>" -ErrorAction SilentlyContinue

# If deleted, remove from hold policy:
Set-CaseHoldPolicy -Identity $policy.Name `
    -RemoveExchangeLocation "<FAILED_ADDRESS>" `
    -RetryDistribution
```

**Problem: Guest/external mailboxes not holdable**

External users' mailboxes live in their own tenant — you can only hold content that lives in YOUR tenant. For external collaboration content:
- Hold the Teams channel mailbox (group mailbox) — captures channel messages
- Hold the individual user's mailbox for chat messages they sent from within your tenant
- You cannot hold content that is solely in the external user's tenant

---

### Phase 3 — Content Search Failures

**Problem: Search fails with KQL syntax error**

```powershell
# Common KQL mistakes
# WRONG — don't use smart quotes
subject:"project alpha"  # ← these are NOT standard double quotes in some editors

# WRONG — AND/OR must be uppercase
from:user@domain.com and received:2024-01-01..  # ← lowercase operators fail silently

# WRONG — date format issues
received:01-01-2024..12-31-2024  # ← must use / or ISO format
received:2024-01-01..2024-12-31  # ← correct ISO
received:01/01/2024..12/31/2024  # ← correct US format

# CORRECT example
from:cfo@company.com AND received:2024-01-01..2024-12-31 AND subject:"merger"
```

**Problem: Search times out on large mailboxes**
```powershell
# Narrow the search scope progressively
# 1. Add a tighter date range
# 2. Target specific senders/recipients
# 3. Add hasattachment:true to reduce scope
# 4. Break into multiple smaller searches by date segment

$searches = @(
    @{ Name="Search_Q1"; Query="received:2024-01-01..2024-03-31" },
    @{ Name="Search_Q2"; Query="received:2024-04-01..2024-06-30" },
    @{ Name="Search_Q3"; Query="received:2024-07-01..2024-09-30" },
    @{ Name="Search_Q4"; Query="received:2024-10-01..2024-12-31" }
)
foreach ($s in $searches) {
    New-ComplianceSearch -Name $s.Name `
        -ExchangeLocation "<MAILBOX_UPN>" `
        -ContentMatchQuery $s.Query
    Start-ComplianceSearch -Identity $s.Name
}
```

---

### Phase 4 — Export Issues

**Problem: Export tool won't install (ClickOnce blocked)**

The eDiscovery Export Tool uses ClickOnce technology, which requires:
- Windows OS (no macOS support)
- Internet Explorer or Microsoft Edge in IE compatibility mode (legacy requirement)
- .NET Framework 4.5 or higher
- The user must have local admin rights (or ClickOnce trusted publisher configured)

```powershell
# Verify .NET version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" |
    Select-Object Release, Version
# Release >= 379893 = .NET 4.5.2

# Check IE mode in Edge: edge://settings/defaultbrowser → add compliance.microsoft.com to IE mode sites
```

**Modern alternative:** If ClickOnce is a blocker in your environment:
1. Use **eDiscovery Premium review sets** — review and tag documents in-browser without ever exporting
2. Use the **Microsoft Graph eDiscovery API** for programmatic export workflows (requires Premium)

```powershell
# Example: Create a review set via Graph (requires Premium + app registration with eDiscovery.ReadWrite.All)
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
$body = @{ displayName = "ReviewSet_LegalMatter_001" } | ConvertTo-Json
Invoke-RestMethod -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/compliance/ediscovery/cases/<CASE_ID>/reviewSets" `
    -Headers $headers -Body $body
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — End-to-end case setup for a new legal matter</summary>

```powershell
# 1. Create the case
$caseName = "Matter_2024_ContractDispute"
New-ComplianceCase -Name $caseName -CaseType AdvancedEdiscovery  # or "Core" for Core eDiscovery

# 2. Add legal team as members
$legalTeam = @("<ATTORNEY1_UPN>","<PARALEGAL1_UPN>")
foreach ($member in $legalTeam) {
    Add-ComplianceCaseMember -Case $caseName -Member $member
}

# 3. Create a hold on custodian mailboxes
$custodians = @("<CUSTODIAN1_UPN>","<CUSTODIAN2_UPN>")
New-CaseHoldPolicy -Name "${caseName}_Hold" `
    -Case $caseName `
    -ExchangeLocation $custodians

# 4. Add a hold rule (query-based — only hold relevant content)
New-CaseHoldRule -Name "${caseName}_HoldRule" `
    -Policy "${caseName}_Hold" `
    -ContentMatchQuery "received:2023-01-01.. AND (subject:`"contract`" OR subject:`"agreement`")"

# 5. Create a content search
New-ComplianceSearch -Name "${caseName}_Search" `
    -Case $caseName `
    -ExchangeLocation $custodians `
    -ContentMatchQuery "received:2023-01-01.. AND (subject:`"contract`" OR subject:`"agreement`")"
Start-ComplianceSearch -Identity "${caseName}_Search"

# 6. Monitor search
do {
    $s = Get-ComplianceSearch -Identity "${caseName}_Search"
    Write-Host "$(Get-Date -Format HH:mm:ss) Status: $($s.Status) | Items: $($s.Items)"
    Start-Sleep 30
} while ($s.Status -ne "Completed")
```

**Rollback:** To release a hold:
```powershell
# Disable the hold (preserves the policy for potential re-activation)
Set-CaseHoldPolicy -Identity "${caseName}_Hold" -Enabled $false

# Or close the case (holds are automatically disabled when case is closed)
Set-ComplianceCase -Identity $caseName -Status Closed
```

</details>

<details><summary>Playbook 2 — Audit all active holds in the tenant</summary>

```powershell
# Requires eDiscovery Administrator role
$allCases = Get-ComplianceCase -State All

$report = foreach ($case in $allCases) {
    $holds = Get-CaseHoldPolicy -Case $case.Name -ErrorAction SilentlyContinue
    foreach ($hold in $holds) {
        [PSCustomObject]@{
            CaseName       = $case.Name
            CaseStatus     = $case.Status
            HoldName       = $hold.Name
            HoldEnabled    = $hold.IsEnabled
            HoldStatus     = $hold.Status
            ExchangeCount  = ($hold.ExchangeLocation | Measure-Object).Count
            SharePointCount= ($hold.SharePointLocation | Measure-Object).Count
            EnabledDate    = $hold.EnabledDate
        }
    }
}
$report | Sort-Object CaseName | Format-Table -AutoSize
$report | Export-Csv "C:\Temp\eDiscovery_HoldAudit_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
Write-Host "Report saved to C:\Temp"
```

</details>

<details><summary>Playbook 3 — Verify specific mailbox content is preserved</summary>

```powershell
param(
    [string]$MailboxUPN,
    [string]$CaseName,
    [string]$AdminUPN
)

Connect-IPPSSession -UserPrincipalName $AdminUPN

# Check hold distribution
$hold = Get-CaseHoldPolicy -Case $CaseName
Write-Host "Hold Status: $($hold.Status)"

# Check InPlaceHolds on the mailbox
Connect-ExchangeOnline -UserPrincipalName $AdminUPN
$mailbox = Get-Mailbox -Identity $MailboxUPN
Write-Host "InPlaceHolds on mailbox:"
$mailbox.InPlaceHolds | ForEach-Object { Write-Host "  $_" }

# Map GUID to hold policy
foreach ($holdGuid in $mailbox.InPlaceHolds) {
    $clean = $holdGuid -replace "^UniH",""
    $match = Get-CaseHoldPolicy -Identity $clean -ErrorAction SilentlyContinue
    if ($match) {
        Write-Host "  → Matched hold: $($match.Name) in case: $CaseName" -ForegroundColor Green
    }
}
```

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect eDiscovery evidence for escalation to Microsoft Support
.NOTES     Run as Compliance Admin; outputs to C:\Temp\eDiscovery_Evidence\
#>

Connect-IPPSSession -UserPrincipalName "<ADMIN_UPN>"

$outDir = "C:\Temp\eDiscovery_Evidence_$(Get-Date -Format yyyyMMdd_HHmm)"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# 1. All cases
Get-ComplianceCase -State All |
    Select Name, Status, CaseType, CreatedDateTime, ClosedDateTime |
    Export-Csv "$outDir\Cases.csv" -NoTypeInformation

# 2. All hold policies and their locations
$allCases = Get-ComplianceCase -State All
$holdData = foreach ($case in $allCases) {
    Get-CaseHoldPolicy -Case $case.Name -ErrorAction SilentlyContinue |
        Select @{n="Case";e={$case.Name}}, Name, Status, IsEnabled, EnabledDate,
               ExchangeLocation, SharePointLocation,
               ExchangeLocationException, SharePointLocationException
}
$holdData | Export-Csv "$outDir\HoldPolicies.csv" -NoTypeInformation

# 3. All content searches
Get-ComplianceSearch |
    Select Name, Status, Items, Size, JobProgress, ContentMatchQuery,
           ExchangeLocation, SharePointLocation |
    Export-Csv "$outDir\ContentSearches.csv" -NoTypeInformation

# 4. Recent export jobs
Get-ComplianceSearchAction -Export |
    Select Name, Status, JobStartTime, JobEndTime, ExportSizeInBytes |
    Export-Csv "$outDir\Exports.csv" -NoTypeInformation

# 5. Role group memberships
foreach ($rg in @("eDiscovery Manager","eDiscovery Administrator")) {
    Get-RoleGroupMember -Identity $rg |
        Select Name, PrimarySmtpAddress |
        Export-Csv "$outDir\RoleGroup_$($rg -replace ' ','_').csv" -NoTypeInformation
}

Write-Host "Evidence collected to $outDir" -ForegroundColor Green
Write-Host "Compress and attach to Microsoft support ticket"
Compress-Archive -Path $outDir -DestinationPath "$outDir.zip"
Write-Host "ZIP: $outDir.zip"
```

---
## Command Cheat Sheet

```powershell
# --- SESSION ---
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>

# --- CASES ---
Get-ComplianceCase -State All                          # All cases incl. closed
New-ComplianceCase -Name "<NAME>" -CaseType Core       # Create Core case
Set-ComplianceCase -Identity "<NAME>" -Status Closed   # Close a case
Set-ComplianceCase -Identity "<NAME>" -Status Active   # Reopen a case

# --- MEMBERS ---
Add-ComplianceCaseMember -Case "<CASE>" -Member "<UPN>"
Get-ComplianceCaseMember -Case "<CASE>"

# --- HOLDS ---
Get-CaseHoldPolicy -Case "<CASE>"
New-CaseHoldPolicy -Name "<HOLD>" -Case "<CASE>" -ExchangeLocation @("<UPN1>","<UPN2>")
Set-CaseHoldPolicy -Identity "<HOLD>" -RetryDistribution
Set-CaseHoldPolicy -Identity "<HOLD>" -Enabled $false  # Release hold
New-CaseHoldRule -Name "<RULE>" -Policy "<HOLD>" -ContentMatchQuery "<KQL>"

# --- SEARCH ---
New-ComplianceSearch -Name "<NAME>" -ExchangeLocation "<UPN>" -ContentMatchQuery "<KQL>"
Start-ComplianceSearch -Identity "<NAME>"
Get-ComplianceSearch -Identity "<NAME>" | Select Status,Items,Size
Stop-ComplianceSearch -Identity "<NAME>"
Remove-ComplianceSearch -Identity "<NAME>" -Confirm:$false

# --- EXPORT ---
New-ComplianceSearchAction -SearchName "<NAME>" -Export `
    -ExchangeArchiveFormat PerUserPst -EnableDedupe $true `
    -Scope BothIndexedAndUnindexedItems
Get-ComplianceSearchAction -Identity "<NAME>_Export"
Remove-ComplianceSearchAction -Identity "<NAME>_Export" -Confirm:$false

# --- ROLE GROUPS ---
Get-RoleGroupMember -Identity "eDiscovery Manager"
Add-RoleGroupMember -Identity "eDiscovery Manager" -Member "<UPN>"

# --- MAILBOX HOLD VERIFICATION ---
(Get-Mailbox "<UPN>").InPlaceHolds
```

---
## 🎓 Learning Pointers

- **Why holds take up to 24 hours to propagate**: Exchange processes hold changes via the Managed Folder Assistant (MFA), which runs on a per-mailbox-database schedule. The MFA isn't triggered instantly — it's a background job. For urgent preservation, apply litigation hold immediately (`Set-Mailbox -LitigationHoldEnabled $true`) while the case hold propagates. The content is then doubly protected. [MS Docs — How holds work](https://learn.microsoft.com/en-us/purview/ediscovery-how-content-is-identified-for-holds-in-ediscovery-cases)
- **KQL is case-sensitive for operators, not values**: `AND`, `OR`, `NOT` must be uppercase. Property names (`from:`, `subject:`, `received:`) are case-insensitive. Quoting multi-word phrases is mandatory — `subject:project phoenix` is parsed as `subject:project AND phantom:None`, not a phrase search. Use `subject:"project phoenix"`. [KQL syntax reference](https://learn.microsoft.com/en-us/purview/ediscovery-keyword-queries-and-search-conditions)
- **Unindexed items are a legal risk**: Any export for legal proceedings should include unindexed items. A document that failed to index (encrypted, corrupted, unsupported format) could be the most relevant evidence. Always use `-Scope BothIndexedAndUnindexedItems`. [MS Docs — Unindexed items](https://learn.microsoft.com/en-us/purview/ediscovery-investigating-partially-indexed-items)
- **eDiscovery Premium review sets vs export**: For matters with >10,000 documents, exporting PSTs and giving them to legal is inefficient. Review sets let attorneys tag documents as responsive/non-responsive, apply redactions, and build production sets — all in the browser. This is the modern workflow and avoids the ClickOnce dependency entirely. The cost of E5 Compliance often pays for itself in reduced legal review hours.
- **Teams content reconstruction requires Premium**: Core eDiscovery returns Teams messages as individual items without threading context. Legal teams find this confusing. Premium eDiscovery (E5) reconstructs the full conversation thread, showing the message in context with surrounding conversation — which is what courts and regulators expect. [Teams eDiscovery](https://learn.microsoft.com/en-us/microsoftteams/ediscovery-investigation)
- **Audit log integration**: Every eDiscovery action — case creation, hold application, search execution, export download — is recorded in the Unified Audit Log under the `eDiscovery` category. This audit trail is your evidence of defensible process. Pull it with `Search-UnifiedAuditLog -RecordType ComplianceSearchAndPurge -StartDate <DATE> -EndDate <DATE>`. [Audit log for eDiscovery](https://learn.microsoft.com/en-us/purview/ediscovery-search-the-audit-log)
