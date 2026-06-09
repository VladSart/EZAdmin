# SharePoint On-Premises to SPO Migration — Hotfix Runbook (Mode B: Ops)
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

Run these from the migration server or SharePoint admin workstation:

```powershell
# 1. Check SharePoint Migration Tool (SPMT) agent status
Get-Process -Name "Microsoft.SharePoint.MigrationTool*" -ErrorAction SilentlyContinue |
    Select-Object Name, Id, CPU, StartTime

# 2. Verify connectivity to SPO (must resolve and connect)
$spoTenant = "<tenant>.sharepoint.com"  # Replace with your tenant
Test-NetConnection -ComputerName $spoTenant -Port 443

# 3. Check migration user credentials are valid (Graph/SPO scope)
$token = (Invoke-RestMethod -Uri "https://login.microsoftonline.com/<tenantid>/oauth2/v2.0/token" `
    -Method POST -ContentType "application/x-www-form-urlencoded" `
    -Body "client_id=<clientid>&client_secret=<secret>&scope=https://graph.microsoft.com/.default&grant_type=client_credentials" 2>&1)
if ($token.access_token) { Write-Host "[OK] Token obtained" -ForegroundColor Green } else { Write-Host "[ERROR] Token failed: $($token.error_description)" -ForegroundColor Red }

# 4. Check migration container (Azure blob) accessibility
# In SPMT: Tasks > View task > Pipeline status — look for "Container" errors

# 5. Check source SP availability
$sourceSP = "<source-farm-url>"  # Replace
Invoke-WebRequest -Uri $sourceSP -UseDefaultCredentials -TimeoutSec 10 | Select-Object StatusCode
```

| Result | Meaning | Action |
|---|---|---|
| SPMT process not running | Migration tool crashed or not started | Restart SPMT; check Windows Event Log → Application for crash details |
| Port 443 blocked to SPO | Firewall/proxy blocking | Open ticket to network team; verify proxy bypass for `*.sharepoint.com` |
| Token failure: `invalid_client` | App registration issue | Re-create app registration in Entra ID with Sites.ReadWrite.All |
| Source SP 401/403 | Migration account lacks read access on source | Add migration service account to source farm as Site Collection Admin |
| Source SP timeout | Source farm unavailable | Check source farm health before migrating |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Source SharePoint Farm (on-prem)
    │  Migration service account must have:
    │  - Farm Admin OR Site Collection Admin on source
    │  - Read access to all content being migrated
    ▼
Migration Server (SPMT installed)
    │  Requirements:
    │  - Windows 10/11 or Server 2016+ (64-bit)
    │  - .NET 4.7.2+
    │  - 8 GB RAM minimum (16 GB recommended for large migrations)
    │  - 150 GB local disk for temp files
    │  - SPMT agent: Microsoft.SharePoint.MigrationTool.exe
    ▼
Azure Blob Storage (SPMT staging container — Microsoft-managed)
    │  - SPMT uploads content here as encrypted chunks
    │  - Auto-provisioned; not visible in Azure portal
    │  - Requires outbound 443 to *.blob.core.windows.net
    ▼
SharePoint Online (destination)
    │  - Migration account must have: Site Collection Admin on target site
    │  - SharePoint Admin role in M365 tenant (for creating new site collections)
    │  - Storage quota sufficient for migrated content
    ▼
Entra ID / M365 Tenant
    │  - Migration app registration (if using app-only auth)
    │  - MFA exemption or Conditional Access exclusion for migration service account
    │  - SPO API not throttled (respect 429 responses)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Verify SPMT version and install**
```powershell
# Check installed SPMT version
$spmt = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object { $_.DisplayName -like "*Migration Tool*" } |
    Select-Object DisplayName, DisplayVersion, InstallDate
$spmt

# SPMT auto-updates — ensure you're on a recent version
# Current version: https://learn.microsoft.com/en-us/sharepointmigration/new-and-improved-features-in-the-sharepoint-migration-tool
```
Expected: SPMT installed, version 4.x or higher  
Bad: Not installed → download from https://aka.ms/SPMT-Install

**Step 2 — Check migration account permissions on source**
```powershell
# On the source SharePoint farm (run in SharePoint Management Shell)
Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue

$migAccount = "<domain\migrationaccount>"
$webApp = Get-SPWebApplication -Identity "http://<source-farm>"

# Check if account is Farm Admin
$farmAdmins = Get-SPFarm | Select-Object -ExpandProperty TimerService | 
    Select-Object -ExpandProperty Farm | Select-Object -ExpandProperty PermissionLevel
# Or check Site Collection Admin on target site collections
$site = Get-SPSite "http://<source-farm>/sites/<sitecollection>"
$site.RootWeb.SiteAdministrators | Select-Object LoginName
```
Expected: Migration account listed as Site Collection Admin  
Bad: Not listed → `Set-SPSite -Identity $site -SecondaryOwnerAlias $migAccount`

**Step 3 — Validate SPO destination site exists and migration account has access**
```powershell
# Connect to SPO (requires PnP.PowerShell or SPO Management Shell)
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"

# Check site exists
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<destination>"

# Check migration account is Site Collection Admin
Get-SPOUser -Site "https://<tenant>.sharepoint.com/sites/<destination>" |
    Where-Object { $_.LoginName -like "*migrationaccount*" }
```
Expected: Site exists, migration account returned as SiteCollectionAdmin or Owner  
Bad: Site not found → create it first; account missing → `Set-SPOUser -Site <url> -LoginName <account> -IsSiteCollectionAdmin $true`

**Step 4 — Inspect SPMT logs for the failing task**
```
SPMT log location: %AppData%\Microsoft\MigrationTool\Log\
Key log files:
  - MigrationScanAnalysis.log  (pre-scan errors)
  - worker_*.log               (per-task migration worker)
  - SPMigration_*.log          (main migration engine)
```
```powershell
$logPath = "$env:APPDATA\Microsoft\MigrationTool\Log"
Get-ChildItem $logPath -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name, LastWriteTime, Length

# Grep for errors in most recent worker log
$latestLog = Get-ChildItem $logPath -Filter "worker_*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content $latestLog.FullName | Where-Object { $_ -match "ERROR|WARN|fail|throttle|429" } | Select-Object -Last 50
```

**Step 5 — Check for throttling (HTTP 429)**
```powershell
# Search worker logs for throttling indicators
Get-ChildItem "$env:APPDATA\Microsoft\MigrationTool\Log" -Filter "*.log" |
    ForEach-Object { Select-String -Path $_.FullName -Pattern "429|Throttl|Too Many Requests" } |
    Select-Object -Last 20
```
Expected: No 429 responses, or occasional ones handled by SPMT retry  
Bad: Persistent 429 → lower parallelism in SPMT settings; schedule migration during off-peak hours (nights/weekends)

---
## Common Fix Paths

<details><summary>Fix 1 — Migration account blocked by MFA / Conditional Access</summary>

**Symptom:** SPMT fails with "Authentication failed" or hangs at login prompt.

**Cause:** MFA required or CA policy blocking non-interactive sign-in for migration account.

**Fix:**
1. In Entra admin center: Create a CA policy exclusion for the migration service account
2. OR use app-only authentication in SPMT (avoids interactive auth entirely):
   - Register an app in Entra: `App registrations` → New → grant `Sites.FullControl.All` (Application permission)
   - In SPMT settings → Authentication → App-only mode → enter Client ID and Secret
3. If using legacy auth: ensure "Allow access token (used for implicit flows)" is enabled on the app registration

```powershell
# Verify app registration has correct permissions
Connect-MgGraph -Scopes "Application.Read.All"
$app = Get-MgApplication -Filter "displayName eq 'SPMTMigrationApp'"
$app.RequiredResourceAccess | ForEach-Object {
    $_.ResourceAppId
    $_.ResourceAccess | Select-Object Type, Id
}
# Should include Sites.FullControl.All (Application type)
```

**Rollback:** Remove CA exclusion after migration completes.

</details>

<details><summary>Fix 2 — Large files failing (over 250 GB per file or path too long)</summary>

**Symptom:** Specific files fail in SPMT scan or migration with "File too large" or "Path too long" error.

**SPO limits:**
- Max file size: 250 GB (as of 2024)
- Max file path (URL): 400 characters
- Max filename length: 256 characters
- Blocked file types: `.tmp`, `.ds_store`, desktop.ini, thumbs.db (auto-skipped)

**Fix:**
```powershell
# Scan source for oversized files
$sourcePath = "\\<fileserver>\<share>"  # Replace with UNC path
Get-ChildItem $sourcePath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -gt 250GB } |
    Select-Object FullName, @{n='SizeGB';e={[math]::Round($_.Length/1GB,2)}} |
    Export-Csv C:\Temp\OversizedFiles.csv -NoTypeInformation

# Scan for long paths (> 260 chars for Windows, > 400 for SPO URL)
Get-ChildItem $sourcePath -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName.Length -gt 260 } |
    Select-Object FullName, @{n='PathLength';e={$_.FullName.Length}} |
    Export-Csv C:\Temp\LongPaths.csv -NoTypeInformation
```

**Resolution:** Work with content owners to rename/restructure before migrating. SPMT will log these as scan warnings — review `MigrationScanAnalysis.log`.

</details>

<details><summary>Fix 3 — SPO storage quota exceeded during migration</summary>

**Symptom:** Migration task fails partway through with "storage quota exceeded" or items stuck in "Failed" state.

**Fix:**
```powershell
# Check SPO tenant-wide storage
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"
Get-SPOTenant | Select-Object StorageQuota, StorageQuotaAllocated

# Check individual site quota
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<destination>" |
    Select-Object Url, StorageQuota, StorageUsageCurrent

# Increase site quota (values in MB)
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<destination>" -StorageQuota 1048576  # 1 TB
```

**Note:** Tenant-wide storage is pooled. If tenant is at capacity, purchase additional storage or archive existing content before migrating.

</details>

<details><summary>Fix 4 — Permissions not migrating (users show as "Unknown")</summary>

**Symptom:** After migration, SharePoint permissions show as "Unknown user" or permissions are missing entirely.

**Cause:** Users in source farm used NT accounts or claims not matched in Entra ID. SPMT maps permissions based on UPN matching.

**Fix:**
```powershell
# SPMT user mapping: create a CSV mapping source accounts to destination UPNs
# Format: SourceUser,TargetUser
# "DOMAIN\jsmith","jsmith@contoso.com"
# "DOMAIN\mgroup","migrated-group@contoso.com"

# In SPMT: Settings > User and group mapping > Upload mapping CSV
# This is done before running the migration task

# After migration: identify unmapped users
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<destination>" -Interactive
$allUsers = Get-PnPUser
$unmapped = $allUsers | Where-Object { $_.Title -match "Unknown\|i:0#.w" }
$unmapped | Export-Csv C:\Temp\UnmappedSPOUsers.csv -NoTypeInformation
```

**Best practice:** Run SPMT in scan-only mode first. Review `UserReport.csv` in SPMT output to identify all accounts needing mapping.

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — SharePoint On-Prem to SPO Migration Failure
=================================================================
Date/Time:          _______________
Raised by:          _______________
Severity:           _______________

SOURCE ENVIRONMENT
  Source Farm URL:          _______________
  Source SP Version:        _______________  (e.g., SP2016, SP2019)
  Migration service acct:   _______________
  
DESTINATION
  SPO Tenant:               _______________
  Destination Site URL:     _______________
  
SPMT VERSION:               _______________  (Help > About in SPMT UI)

ERROR OBSERVED
  Error message (exact):    _______________
  Error code (if shown):    _______________
  Failing task name:        _______________
  Number of failed items:   _______________  (from SPMT task report)
  
LOG FILES ATTACHED
  [ ] worker_*.log (most recent)
  [ ] SPMigration_*.log
  [ ] MigrationScanAnalysis.log
  
CONNECTIVITY TESTS
  Port 443 to *.sharepoint.com:   Pass / Fail
  Port 443 to *.blob.core.windows.net:  Pass / Fail
  Source SP reachable from migration server:  Pass / Fail

PERMISSIONS VERIFIED
  [ ] Migration account = Site Collection Admin on source site
  [ ] Migration account = Site Collection Admin on destination site
  [ ] CA exclusion in place for migration account
  [ ] Storage quota sufficient on destination

THROTTLING
  429 errors in logs:       Yes / No
  Migration time window:    _______________  (peak / off-peak)

PREVIOUS STATE
  Did this migration task ever succeed?   Yes / No
  When did it last work?                  _______________
  Recent changes:                         _______________
```

---
## 🎓 Learning Pointers

- **SPMT is the recommended Microsoft tool** for SharePoint on-prem to SPO migration — it handles most file library, list, and page migrations. For complex migrations (InfoPath forms, custom workflows, large media libraries), consider Migration Manager or third-party tools (Sharegate, AvePoint). See [SPMT documentation](https://learn.microsoft.com/en-us/sharepointmigration/introducing-the-sharepoint-migration-tool).

- **Classic SharePoint features don't exist in SPO** — classic workflows (SharePoint Designer 2010/2013 workflows) are deprecated in SPO. Users relying on these must be migrated to Power Automate flows before or after content migration. Plan for this in the project scope.

- **Pre-migration scan is non-negotiable** — always run SPMT in scan-only mode against the full source before migrating. The scan produces a detailed report of errors, warnings, file count, and total size. Without it, surprises (long paths, permissions complexity, oversized files) hit during live migration. See [SPMT scan](https://learn.microsoft.com/en-us/sharepointmigration/spmt-scan).

- **SPO throttling is real** — Microsoft throttles SPO API calls (HTTP 429). SPMT handles this automatically with exponential backoff, but large migrations during business hours can hit sustained throttling. Schedule bulk migrations for off-peak windows. See [SPO throttling guidance](https://learn.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online).

- **Versioning multiplies storage** — if source libraries have 50 versions per file and you migrate all versions, your SPO storage consumption can be 10-50x higher than the source file size. Use SPMT's "migrate versions" setting carefully and consider limiting to last N versions.

- **Delta migrations for cutover** — SPMT supports re-running a task to migrate only changes since the last run (delta/incremental migration). For minimal user downtime: migrate bulk content first, run a delta pass 24h before cutover, then a final delta pass at cutover weekend. This dramatically reduces downtime compared to a single big-bang migration.
