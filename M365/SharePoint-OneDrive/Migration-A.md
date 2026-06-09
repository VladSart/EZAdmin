# SharePoint On-Premises to SPO Migration — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers migration of content from SharePoint 2013/2016/2019/SE on-premises to SharePoint Online (SPO) using the SharePoint Migration Tool (SPMT) or SharePoint Migration API (SPMT API / Migration Manager). Also covers common Mover / third-party tool issues and post-migration validation.

**Out of scope:** SharePoint Framework (SPFx) app migration, InfoPath forms migration (deprecated), SharePoint 2010 migration (requires two-hop via 2013/2016 first).

**Assumptions:**
- Microsoft 365 tenant with SPO licences provisioned
- SPMT or Migration Manager agent installed on an on-premises Windows Server (2016+)
- PnP PowerShell module and SharePoint Online Management Shell installed
- Global Admin or SharePoint Admin role, plus Site Collection Admin on source

---

## How It Works

<details><summary>Full architecture — SPMT and SPO migration pipeline</summary>

Microsoft's migration framework has two layers: the **SPMT agent** (on-premises side) and the **Migration API** (SPO cloud side).

```
┌──────────────────────────────────────────────────────────────┐
│                   On-Premises Environment                    │
│                                                              │
│  SharePoint Farm ──► SPMT Agent ──► Azure Blob (staging)     │
│  (or file share)    (Windows Srv)   (temp Microsoft-owned)   │
└──────────────────────────────────────────────────────────────┘
                              │
                    Migration API (HTTPS/443)
                              │
┌──────────────────────────────────────────────────────────────┐
│                   Microsoft 365 Tenant                       │
│                                                              │
│  SPO Migration API ──► SPO Site Collection ──► Storage       │
│  (ingestion service)   (target library)       (SPO blob)     │
└──────────────────────────────────────────────────────────────┘
```

**Process phases:**
1. **Scan:** SPMT scans source (SP farm or file share), identifies content, generates pre-migration assessment report. Flags: unsupported file types, path length violations, permission inheritance breaks, InfoPath dependencies.
2. **Package:** SPMT packages content into migration packages (ZIP + XML manifest). Packages are staged in Azure Blob Storage (temporary, Microsoft-managed, automatically cleaned up).
3. **Import:** SPO Migration API reads packages from Azure Blob and imports into target SPO site. This is asynchronous — agent submits jobs and polls for completion.
4. **Validation:** SPMT generates post-migration report with success/failure/warning counts.

**Key limits (as of 2025):**
| Limit | Value |
|-------|-------|
| Max file size | 250 GB |
| Max file path length | 400 characters (SharePoint URL limit) |
| Max items per library | 30 million |
| SPMT concurrent migration jobs | 10 per agent |
| Files with restricted characters | `/` `\` `"` `#` `%` `*` `:` `<` `>` `?` `{` `}` `~` |
| Max site collection size recommended for single job | 1 TB |

**Permission migration behaviour:**
- SharePoint groups are migrated as SharePoint groups in SPO
- Individual user permissions: migrated by UPN. If UPN mismatch (on-prem vs. Entra ID UPN), permissions drop silently — this is the #1 permissions issue
- Unique permissions on individual items: migrated only if **Preserve permissions** is selected (slower)
- Azure AD groups (M365/security): must already exist in SPO; SPMT maps by group name

</details>

---

## Dependency Stack

```
Source: SharePoint Farm (SP2013/2016/2019/SE)
  │
  ├── Farm service account (read access to content DBs)
  ├── Source site collection admin account
  └── Network path accessible from SPMT agent host
          │
SPMT Agent (on Windows Server)
  ├── .NET Framework 4.8
  ├── Visual C++ Redistributable 2015-2022
  ├── Outbound HTTPS (443) to *.sharepoint.com, *.blob.core.windows.net
  ├── Outbound HTTPS (443) to login.microsoftonline.com
  └── Sufficient disk for temp packages (recommend 2× source size free)
          │
Azure Blob Storage (Microsoft-managed staging)
  └── Automatically provisioned per migration job
          │
SPO Migration API
  ├── SharePoint Admin role in tenant
  ├── Target site collection exists (or auto-create enabled)
  └── Storage quota available in target SPO
          │
Target: SharePoint Online Site Collection
  ├── Document libraries pre-created (or auto-created)
  ├── Users exist in Entra ID with matching UPN
  └── SPO storage quota not exceeded
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-----------------|-------|
| Migration stuck at "Scanning" | SPMT agent can't reach source SP farm | Network/firewall, farm account permissions |
| "Access denied" on items in report | Source account not site collection admin | Verify with `Get-SPSite` on-prem |
| Post-migration missing permissions | UPN mismatch on-prem vs. Entra ID | Run `Get-MigrationUserMappingReport` |
| Files skipped: "Invalid characters" | Filename contains `#`, `%`, `*`, etc. | Pre-scan with SPMT assessment |
| Files skipped: "Path too long" | SharePoint URL > 400 chars | Restructure folders pre-migration |
| Migration completes but content missing | Target library exceeded item limit | Check items/library count in SPO |
| Large file migration fails | File > 250 GB | Manual upload or break into segments |
| "Quota exceeded" error | SPO storage quota exhausted | Increase quota or clean up target |
| Metadata not migrated | Columns don't exist in target library | Pre-create columns or use SPMT auto-mapping |
| Managed metadata terms broken | Term store not synced | Export/import term store before migration |
| Version history missing | Version history not included in SPMT settings | Enable "Migrate all versions" in SPMT |

---

## Validation Steps

**1. Pre-migration — assess source with SPMT**
```powershell
# Run SPMT in assessment mode (GUI)
# Or use SPMT PowerShell module
Import-Module Microsoft.SharePoint.MigrationTool.PowerShell

$sourceUrl = "http://<on-prem-sharepoint>/sites/<sitename>"
$targetUrl = "https://<tenant>.sharepoint.com/sites/<targetsite>"
$spoCred = Get-Credential  # M365 admin

Register-SPMTMigration -SPOCredential $spoCred -Force
Add-SPMTTask -SharePointSourceSiteUrl $sourceUrl -TargetSiteUrl $targetUrl -TargetList "Documents" -SharePointSourceList "Documents"
Start-SPMTMigration -NoShow  # run in background
```

**2. Validate SPMT agent connectivity to SPO**
```powershell
# Test SPO endpoints from agent host
$endpoints = @(
    "login.microsoftonline.com",
    "<tenant>.sharepoint.com",
    "<tenant>-my.sharepoint.com",
    "<tenant>.blob.core.windows.net"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443
    Write-Host "$ep : $($result.TcpTestSucceeded)" -ForegroundColor $(if ($result.TcpTestSucceeded) {"Green"} else {"Red"})
}
```

**3. Post-migration — verify item counts**
```powershell
# Install PnP PowerShell: Install-Module PnP.PowerShell
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<targetsite>" -Interactive

$list = Get-PnPList -Identity "Documents"
Write-Host "Items in target library: $($list.ItemCount)" -ForegroundColor Cyan

# Compare to source (run on-prem with SharePoint snap-in)
# Get-SPWeb "http://<source>/sites/<site>" | Select-Object Url, @{N="Items";E={($_.Lists["Documents"]).ItemCount}}
```

**4. Post-migration — verify permissions**
```powershell
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<targetsite>" -Interactive

# Check role assignments on site
Get-PnPSiteCollectionAdmin | Select-Object LoginName, Title

# Check specific user
$user = Get-PnPUser | Where-Object {$_.LoginName -like "*<upn>*"}
Write-Host "User found: $($user.Title) / $($user.LoginName)"

# Check library permissions
$perms = Get-PnPListPermissions -Identity "Documents"
$perms | Select-Object Member, Roles | Format-Table
```

**5. Validate migrated metadata**
```powershell
# Check that custom columns exist in target
$fields = Get-PnPField -List "Documents" | Where-Object {$_.Hidden -eq $false -and $_.ReadOnlyField -eq $false}
$fields | Select-Object InternalName, Title, TypeDisplayName | Format-Table
```

---

## Troubleshooting Steps by Phase

### Phase 1 — Pre-Migration Assessment Failures

1. **SPMT can't connect to source SP farm:**
   - Confirm source URL resolves from agent host (ping / nslookup)
   - Confirm source account has Site Collection Admin on source
   - Check Windows Auth / NTLM is allowed on source IIS site (SPMT does not support Kerberos-only sources by default)
   - Try accessing source URL from IE on agent host to validate auth chain

2. **Assessment reports many "unsupported" items:**
   ```powershell
   # Count files with restricted characters in source (file share migration)
   $badChars = '#', '%', '*', ':', '<', '>', '?', '{', '}', '~', '"'
   Get-ChildItem "<source path>" -Recurse -File | Where-Object {
       $name = $_.Name
       $badChars | Where-Object {$name -contains $_}
   } | Select-Object FullName | Export-Csv "C:\Temp\BadCharFiles.csv" -NoTypeInformation
   ```

3. **Path length violations:**
   ```powershell
   # Find files where full path > 260 chars (or > 400 when in SPO URL context)
   Get-ChildItem "<source path>" -Recurse -File | Where-Object {
       $_.FullName.Length -gt 260
   } | Select-Object FullName, @{N="Length";E={$_.FullName.Length}} |
       Export-Csv "C:\Temp\LongPathFiles.csv" -NoTypeInformation
   ```

### Phase 2 — Migration Job Failures

1. **Job stuck / not progressing:**
   - Check SPMT agent log: `%AppData%\Microsoft\MigrationToolStorage\Logs\`
   - Check for throttling: SPO throttles heavy migration jobs. Retry logic is built into SPMT — wait and resume.
   - Confirm agent host disk space: `Get-PSDrive C | Select-Object Used, Free`

2. **"Forbidden" error mid-migration:**
   - SPMT session token expired (>24h migration). Re-authenticate and resume job.
   - Target site collection permissions changed mid-run.

3. **Large file failures:**
   ```powershell
   # Identify files > 5 GB in source (these need special handling / pre-staging)
   Get-ChildItem "<source path>" -Recurse -File | Where-Object {$_.Length -gt 5GB} |
       Select-Object FullName, @{N="SizeGB";E={[math]::Round($_.Length/1GB,2)}} |
       Export-Csv "C:\Temp\LargeFiles.csv" -NoTypeInformation
   ```

### Phase 3 — Post-Migration Issues

1. **Users can't access migrated content:**
   - Verify user exists in Entra ID with correct UPN: `Get-AzureADUser -SearchString "<name>"`
   - Check if user was added to SPO during migration: `Get-PnPUser | Where-Object {$_.LoginName -like "*<upn>*"}`
   - UPN mapping: if on-prem UPN ≠ M365 UPN, configure identity mapping file in SPMT:
     ```
     # mapping.csv format:
     # SourceUserAccountName,TargetUserAccountName
     # domain\jsmith,jsmith@contoso.com
     ```

2. **Managed metadata columns showing as text:**
   - Term store was not migrated before content. Fix: export term groups from on-prem, import to SPO term store, then re-run metadata column migration.
   ```powershell
   # Export term group from on-prem (requires SP Management Shell)
   Export-SPMetadataWebServiceProxySettings -Identity "https://<source>" -Out "C:\Temp\terms.xml"
   
   # Import to SPO (PnP PowerShell)
   Connect-PnPOnline -Url "https://<tenant>.sharepoint.com" -Interactive
   Import-PnPTermGroupFromXml -Path "C:\Temp\terms.xml"
   ```

3. **Version history not present:**
   - Verify SPMT setting "Migrate file version history" was enabled. If not, versions were not migrated — this cannot be retroactively added without a re-migration.
   - Check current version count: `Get-PnPListItem -List "Documents" | Select-Object Id, @{N="Versions";E={$_.FieldValues["_UIVersionString"]}}`

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Resolve UPN mismatch / permission drop</summary>

**When to use:** Users report access denied on migrated content; permissions were set in source but not carried over.

```powershell
# Step 1: Build a UPN mapping CSV
# Format: SourceUserAccountName,TargetUserAccountName
# Example: contoso\jsmith,jsmith@contoso.com

# Step 2: Apply mapping in SPMT (GUI: Settings → User mapping)
# Or via PowerShell during task setup:
# Add-SPMTTask ... -UserMappingFile "C:\Temp\usermapping.csv"

# Step 3: After migration, manually fix missed permissions via PnP
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<site>" -Interactive

# Add user with correct permissions
Set-PnPListPermission -Identity "Documents" -User "jsmith@contoso.com" -AddRole "Contribute"

# Or re-run permission migration only (SPMT supports incremental runs)
```

</details>

<details>
<summary>Fix 2 — Re-migrate failed/skipped items</summary>

**When to use:** Post-migration report shows skipped items due to transient errors (throttling, timeout) — not structural issues like bad characters.

```powershell
# SPMT supports incremental migration — re-running the same job will only migrate
# items not yet successfully migrated. Simply:
# 1. Open SPMT
# 2. Load the saved migration task (or re-create with same source/target)
# 3. Run — SPMT skips already-migrated items (by last-modified timestamp comparison)

# To force re-migration of all items (e.g. if you need to refresh content):
# In SPMT Settings → Advanced → set "Migrate only new and changed files" = Off
# WARNING: This re-uploads everything — use only if needed
```

</details>

<details>
<summary>Fix 3 — Fix managed metadata column values post-migration</summary>

**When to use:** Managed metadata columns migrated as free-text instead of being wired to term store.

```powershell
# Step 1: Ensure term store is in SPO with correct groups/sets
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com" -Interactive
Get-PnPTermGroup | Select-Object Name, Id

# Step 2: Re-wire the column to the correct term set
# You need the list, field internal name, and term set ID
$termSetId = "<GUID of term set>"
$field = Get-PnPField -List "Documents" -Identity "Department"

# Modify field XML to point to correct term set
# This is complex — use PnP provisioning or CSOM for production re-wiring
# Reference: https://learn.microsoft.com/en-us/sharepoint/dev/sp-add-ins/complete-basic-operations-using-sharepoint-client-library-code
```

</details>

<details>
<summary>Fix 4 — Increase SPO storage quota</summary>

**When to use:** Migration fails with "quota exceeded" or SPO site storage bar is at 100%.

```powershell
# Check current storage quota for all site collections
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"
Get-SPOSite -Limit All | Select-Object Url, StorageQuota, StorageUsageCurrent |
    Sort-Object StorageUsageCurrent -Descending | Format-Table

# Increase quota on specific site (in MB)
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<site>" -StorageQuota 102400  # 100 GB

# Check tenant-level total storage available
Get-SPOTenant | Select-Object StorageQuota, StorageQuotaAllocated
```

</details>

---

## Evidence Pack

```powershell
# Run from SPMT agent host — collects migration evidence for ticket escalation
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$outputDir = "C:\Temp\SPOMigration-Evidence-$timestamp"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Connectivity test to SPO endpoints
$endpoints = @(
    "login.microsoftonline.com",
    "<tenant>.sharepoint.com",
    "<tenant>-admin.sharepoint.com",
    "<tenant>.blob.core.windows.net"
)
$connResults = foreach ($ep in $endpoints) {
    $r = Test-NetConnection -ComputerName $ep -Port 443
    [PSCustomObject]@{Endpoint=$ep; TcpSuccess=$r.TcpTestSucceeded; PingSuccess=$r.PingSucceeded}
}
$connResults | Export-Csv "$outputDir\connectivity.csv" -NoTypeInformation

# SPMT log files (copy last 5)
$spmtLogDir = "$env:APPDATA\Microsoft\MigrationToolStorage\Logs"
if (Test-Path $spmtLogDir) {
    Get-ChildItem $spmtLogDir -Filter "*.log" | Sort-Object LastWriteTime -Descending |
        Select-Object -First 5 | Copy-Item -Destination $outputDir
}

# System info for agent host
Get-ComputerInfo | Select-Object CsName, OsName, OsVersion, WindowsProductName |
    Export-Csv "$outputDir\agenthost.csv" -NoTypeInformation

# Available disk space
Get-PSDrive -PSProvider FileSystem | Select-Object Name, Used, Free |
    Export-Csv "$outputDir\diskspace.csv" -NoTypeInformation

# SPO target site info (requires PnP)
try {
    Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<targetsite>" -Interactive
    Get-PnPSite | Select-Object Url, StorageQuota, StorageUsage | Export-Csv "$outputDir\targetsite.csv" -NoTypeInformation
    Get-PnPList | Select-Object Title, ItemCount, DefaultViewUrl | Export-Csv "$outputDir\targetlists.csv" -NoTypeInformation
} catch {
    Write-Warning "PnP connection failed: $_"
}

Write-Host "Evidence at: $outputDir" -ForegroundColor Green
Compress-Archive -Path $outputDir -DestinationPath "C:\Temp\SPOMigration-Evidence-$timestamp.zip" -Force
Write-Host "Archive: C:\Temp\SPOMigration-Evidence-$timestamp.zip" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Connect to SPO admin | `Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"` |
| List all site collections | `Get-SPOSite -Limit All` |
| Get site storage usage | `Get-SPOSite -Identity <url> \| Select StorageQuota, StorageUsageCurrent` |
| Set site storage quota | `Set-SPOSite -Identity <url> -StorageQuota <MB>` |
| Connect PnP to site | `Connect-PnPOnline -Url <siteurl> -Interactive` |
| Get list item count | `(Get-PnPList -Identity "Documents").ItemCount` |
| Get site admins | `Get-PnPSiteCollectionAdmin` |
| Get all users in site | `Get-PnPUser` |
| Set user permission | `Set-PnPListPermission -Identity <list> -User <upn> -AddRole <role>` |
| Export term group | PnP: `Export-PnPTermGroupToXml -Identity <group> -Out <file>` |
| Import term group | PnP: `Import-PnPTermGroupFromXml -Path <file>` |
| Get SPMT log location | `%AppData%\Microsoft\MigrationToolStorage\Logs\` |
| Check tenant storage | `Get-SPOTenant \| Select StorageQuota, StorageQuotaAllocated` |
| Test SPO connectivity | `Test-NetConnection <tenant>.sharepoint.com -Port 443` |

---

## 🎓 Learning Pointers

- **UPN mismatch is migration enemy #1.** Hybrid environments often have on-prem UPNs (user@domain.local) that don't match M365 UPNs (user@contoso.com). Always audit UPN alignment before migration starts — not after. Run `Get-ADUser -Filter * -Properties UserPrincipalName, Mail | Compare-Object` before committing to the migration schedule. See: [Plan identity mapping for SharePoint migration](https://learn.microsoft.com/en-us/sharepointmigration/plan-to-do-pre-migration-steps)

- **The "250 GB file limit" is a hard ceiling, not a soft suggestion.** Files above this can't be migrated by SPMT at all. Identify them in the pre-scan and plan manual upload via OneDrive sync client for these edge cases. See: [SPMT limits and limitations](https://learn.microsoft.com/en-us/sharepointmigration/spmt-limits)

- **Version history migration dramatically increases migration time.** A library with 50,000 items and 10 versions each means 500,000 blobs to transfer. Agree with stakeholders on version strategy (e.g., migrate only last 5 versions) before starting large jobs. See: [SPMT Settings: Migrate file version history](https://learn.microsoft.com/en-us/sharepointmigration/spmt-settings)

- **Managed metadata must be term-store-first.** If you migrate content before the term store is available in SPO, managed metadata column values become free text and are extremely difficult to re-associate programmatically. Always migrate/recreate the term store before running content migration. See: [Import a term set from a CSV file (SharePoint Online)](https://support.microsoft.com/en-us/office/import-a-term-set-using-a-csv-file-168fbc86-7fce-4288-9a1f-b83fc3921c18)

- **Migration Manager (successor to SPMT) handles scale better.** For >1 TB migrations or multi-site farms, use Migration Manager with distributed agents across multiple machines. SPMT is single-agent; Migration Manager orchestrates a fleet. See: [Migration Manager overview](https://learn.microsoft.com/en-us/sharepointmigration/mm-get-started)

- **Post-migration access reviews are mandatory.** Broken inheritance, dropped unique permissions, and orphaned users are all possible outcomes even after a "successful" migration. Schedule a structured permissions review 24h post-migration using `Get-PnPListPermissions` scans, not just spot checks. See: [SharePoint permissions and sharing documentation](https://learn.microsoft.com/en-us/sharepoint/security-for-sharepoint-server/security-for-sharepoint-server)
