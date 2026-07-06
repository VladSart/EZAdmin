<#
.SYNOPSIS
    Dual-mode health check for an on-prem-to-SPO migration: local SPMT agent state plus
    destination-side SPO readiness.

.DESCRIPTION
    Automates the manual checklist spread across Migration-B.md's Triage/Diagnosis steps and
    Migration-A.md's Validation Steps, in one pass:

    Local (SPMT agent host) mode — always runs, no parameters required beyond defaults:
    - SPMT install/version check (Migration-B.md Diagnosis Step 1)
    - Connectivity to every required endpoint: login.microsoftonline.com, the SPO tenant,
      the SPO admin URL, and *.blob.core.windows.net staging (Migration-A.md Validation Step 2)
    - SPMT worker log scan for ERROR/WARN/throttle signatures in the most recent log
      (Migration-B.md Diagnosis Steps 4-5)

    Destination (SPO) mode — runs when -TenantName and -SiteUrl are supplied (requires
    SharePoint Online Management Shell, Connect-SPOService):
    - Site existence + storage quota vs. current usage, flags QUOTA_RISK at a configurable
      percentage threshold (Fix 3 / Fix 4)
    - Migration account Site Collection Admin check on the destination site (Migration-B.md
      Diagnosis Step 3)

    Source pre-scan mode — runs when -SourcePath (a UNC path) is supplied:
    - Oversized files (>250 GB hard SPO ceiling) — flags OVERSIZED_FILE (Fix 2)
    - Long paths (>260 chars locally / approaching the 400-char SPO URL limit) — flags LONG_PATH
    - Restricted-character filenames (`# % * : < > ? { } ~ "`) — flags BAD_CHARACTERS

    Read-only across all three modes. Does not install SPMT, create sites, change quotas, or
    modify permissions.

.PARAMETER TenantName
    Your M365 tenant name (e.g. "contoso" for contoso.sharepoint.com). Enables SPO destination checks.

.PARAMETER SiteUrl
    Full destination site URL to check (e.g. https://contoso.sharepoint.com/sites/Finance).
    Required alongside -TenantName for the destination-side checks.

.PARAMETER MigrationAccountUpn
    UPN of the migration service account — checked for Site Collection Admin on the destination site.

.PARAMETER SourcePath
    Optional UNC path to the source content root, for the local pre-scan (oversized files, long
    paths, restricted characters).

.PARAMETER QuotaWarningPercent
    Percentage of storage quota consumed at which a site is flagged QUOTA_RISK. Default: 85.

.EXAMPLE
    # Local-only check from the SPMT agent host (no SPO/source params)
    .\Get-SharePointMigrationStatus.ps1 -TenantName "contoso"

.EXAMPLE
    # Full check: local + destination + source pre-scan
    .\Get-SharePointMigrationStatus.ps1 -TenantName "contoso" -SiteUrl "https://contoso.sharepoint.com/sites/Finance" -MigrationAccountUpn "svc-migration@contoso.com" -SourcePath "\\fileserver\FinanceShare"

.NOTES
    Requires (destination mode): Microsoft.Online.SharePoint.PowerShell module, SharePoint Admin role
    Install:  Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser
    Auth:     Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com" (interactive prompt)
    Run the local-mode portion directly on the SPMT agent host for accurate log/connectivity results.
    Companion runbooks: M365/SharePoint-OneDrive/Migration-A.md and Migration-B.md
#>

[CmdletBinding()]
param(
    [Parameter()][string]$TenantName,
    [Parameter()][string]$SiteUrl,
    [Parameter()][string]$MigrationAccountUpn,
    [Parameter()][string]$SourcePath,
    [Parameter()][ValidateRange(1,100)][int]$QuotaWarningPercent = 85
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $Colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $Colour
}

$Findings = [System.Collections.Generic.List[string]]::new()

# ─── LOCAL MODE: SPMT agent host ──────────────────────────────────────────────

Write-Status "=== Local SPMT agent checks ===" "OK"

Write-Status "Checking SPMT install/version..."
$Spmt = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "*Migration Tool*" } |
    Select-Object DisplayName, DisplayVersion, InstallDate

if ($Spmt) {
    Write-Status "SPMT found: $($Spmt.DisplayName) v$($Spmt.DisplayVersion)" "OK"
} else {
    Write-Status "SPMT not found on this host. Download: https://aka.ms/SPMT-Install" "WARN"
    $Findings.Add("SPMT_NOT_INSTALLED")
}

Write-Status "Testing connectivity to required endpoints..."
$Endpoints = [System.Collections.Generic.List[string]]::new()
$Endpoints.Add("login.microsoftonline.com")
if ($TenantName) {
    $Endpoints.Add("$TenantName.sharepoint.com")
    $Endpoints.Add("$TenantName-admin.sharepoint.com")
    $Endpoints.Add("$TenantName.blob.core.windows.net")
} else {
    Write-Status "  -TenantName not supplied — skipping tenant-specific endpoint checks." "WARN"
}

$ConnResults = foreach ($Ep in $Endpoints) {
    try {
        $R = Test-NetConnection -ComputerName $Ep -Port 443 -WarningAction SilentlyContinue
        [PSCustomObject]@{ Endpoint = $Ep; TcpSuccess = $R.TcpTestSucceeded }
    } catch {
        [PSCustomObject]@{ Endpoint = $Ep; TcpSuccess = $false }
    }
}
foreach ($C in $ConnResults) {
    if ($C.TcpSuccess) { Write-Status "  $($C.Endpoint) : reachable" "OK" }
    else { Write-Status "  $($C.Endpoint) : NOT reachable" "ERROR"; $Findings.Add("ENDPOINT_UNREACHABLE: $($C.Endpoint)") }
}

Write-Status "Scanning most recent SPMT worker log for errors/throttling..."
$SpmtLogDir = "$env:APPDATA\Microsoft\MigrationToolStorage\Logs"
if (-not (Test-Path $SpmtLogDir)) { $SpmtLogDir = "$env:APPDATA\Microsoft\MigrationTool\Log" }

$LogFindings = @()
if (Test-Path $SpmtLogDir) {
    $LatestWorkerLog = Get-ChildItem $SpmtLogDir -Filter "worker_*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($LatestWorkerLog) {
        $LogFindings = Get-Content $LatestWorkerLog.FullName -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "(?i)ERROR|WARN|fail|throttl|429" } | Select-Object -Last 50
        if ($LogFindings.Count -gt 0) {
            Write-Status "  Found $($LogFindings.Count) error/warn/throttle line(s) in $($LatestWorkerLog.Name)" "WARN"
            if ($LogFindings -match "(?i)429|throttl") { $Findings.Add("MIGRATION_THROTTLED") }
            $Findings.Add("WORKER_LOG_ERRORS: $($LogFindings.Count) lines")
        } else {
            Write-Status "  No error/warn/throttle lines found in most recent worker log." "OK"
        }
    } else {
        Write-Status "  No worker_*.log files found — no migration has run yet, or logs were cleared." "WARN"
    }
} else {
    Write-Status "  SPMT log directory not found at expected path(s)." "WARN"
}

# ─── DESTINATION MODE: SPO site checks ─────────────────────────────────────────

if ($TenantName -and $SiteUrl) {
    Write-Status "`n=== Destination SPO checks ===" "OK"

    if (-not (Get-Module -ListAvailable -Name "Microsoft.Online.SharePoint.PowerShell")) {
        Write-Status "Microsoft.Online.SharePoint.PowerShell module not found. Installing..." "WARN"
        Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop

    try {
        Connect-SPOService -Url "https://$TenantName-admin.sharepoint.com"
    } catch {
        Write-Status "Connect-SPOService failed: $_" "ERROR"
        $Findings.Add("SPO_CONNECT_FAILED")
    }

    if (Get-SPOTenant -ErrorAction SilentlyContinue) {
        try {
            $Site = Get-SPOSite -Identity $SiteUrl -ErrorAction Stop
            Write-Status "Site found: $($Site.Url)" "OK"

            $UsedPercent = if ($Site.StorageQuota -gt 0) { [math]::Round(($Site.StorageUsageCurrent / $Site.StorageQuota) * 100, 1) } else { 0 }
            Write-Status "  Storage: $($Site.StorageUsageCurrent) MB / $($Site.StorageQuota) MB ($UsedPercent%)"
            if ($UsedPercent -ge $QuotaWarningPercent) {
                Write-Status "  QUOTA_RISK: site is at $UsedPercent% of quota" "WARN"
                $Findings.Add("QUOTA_RISK: $($Site.Url) at $UsedPercent%")
            }

            if ($MigrationAccountUpn) {
                $SiteAdmin = Get-SPOUser -Site $SiteUrl -ErrorAction SilentlyContinue |
                    Where-Object { $_.LoginName -like "*$MigrationAccountUpn*" }
                if ($SiteAdmin -and $SiteAdmin.IsSiteAdmin) {
                    Write-Status "  Migration account '$MigrationAccountUpn' is a Site Collection Admin." "OK"
                } else {
                    Write-Status "  Migration account '$MigrationAccountUpn' is NOT a Site Collection Admin on this site." "ERROR"
                    $Findings.Add("MIGRATION_ACCOUNT_NOT_SITE_ADMIN")
                }
            }
        } catch {
            Write-Status "  Destination site not found or inaccessible: $_" "ERROR"
            $Findings.Add("DESTINATION_SITE_NOT_FOUND")
        }
    }
} else {
    Write-Status "`n(Skipping destination SPO checks — supply -TenantName and -SiteUrl to enable.)" "WARN"
}

# ─── SOURCE PRE-SCAN MODE ──────────────────────────────────────────────────────

if ($SourcePath) {
    Write-Status "`n=== Source pre-scan: $SourcePath ===" "OK"

    if (-not (Test-Path $SourcePath)) {
        Write-Status "Source path not accessible from this host." "ERROR"
        $Findings.Add("SOURCE_PATH_UNREACHABLE")
    } else {
        $AllFiles = Get-ChildItem $SourcePath -Recurse -File -ErrorAction SilentlyContinue

        $Oversized = $AllFiles | Where-Object { $_.Length -gt 250GB }
        $LongPaths = $AllFiles | Where-Object { $_.FullName.Length -gt 260 }
        $BadChars  = '#','%','*',':','<','>','?','{','}','~','"'
        $BadCharFiles = $AllFiles | Where-Object { $Name = $_.Name; $BadChars | Where-Object { $Name.Contains($_) } }

        Write-Status "  Files scanned      : $($AllFiles.Count)"
        Write-Status "  Oversized (>250GB) : $($Oversized.Count)" $(if ($Oversized.Count -gt 0) { "WARN" } else { "OK" })
        Write-Status "  Long paths (>260)  : $($LongPaths.Count)" $(if ($LongPaths.Count -gt 0) { "WARN" } else { "OK" })
        Write-Status "  Bad-character names: $($BadCharFiles.Count)" $(if ($BadCharFiles.Count -gt 0) { "WARN" } else { "OK" })

        if ($Oversized.Count -gt 0) { $Findings.Add("OVERSIZED_FILE: $($Oversized.Count) file(s)") }
        if ($LongPaths.Count -gt 0) { $Findings.Add("LONG_PATH: $($LongPaths.Count) file(s)") }
        if ($BadCharFiles.Count -gt 0) { $Findings.Add("BAD_CHARACTERS: $($BadCharFiles.Count) file(s)") }

        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        if ($Oversized.Count -gt 0) { $Oversized | Select-Object FullName, @{N='SizeGB';E={[math]::Round($_.Length/1GB,2)}} | Export-Csv "C:\Temp\SPOMigration-OversizedFiles-$Timestamp.csv" -NoTypeInformation }
        if ($LongPaths.Count -gt 0) { $LongPaths | Select-Object FullName, @{N='PathLength';E={$_.FullName.Length}} | Export-Csv "C:\Temp\SPOMigration-LongPaths-$Timestamp.csv" -NoTypeInformation }
        if ($BadCharFiles.Count -gt 0) { $BadCharFiles | Select-Object FullName | Export-Csv "C:\Temp\SPOMigration-BadCharFiles-$Timestamp.csv" -NoTypeInformation }
    }
} else {
    Write-Status "`n(Skipping source pre-scan — supply -SourcePath to enable.)" "WARN"
}

# ─── Report ───────────────────────────────────────────────────────────────────

Write-Status "`n═══════════════════════════════════════════════" "OK"
Write-Status "SHAREPOINT MIGRATION STATUS SUMMARY" "OK"
Write-Status "Total findings: $($Findings.Count)" $(if ($Findings.Count -gt 0) { "WARN" } else { "OK" })

if ($Findings.Count -gt 0) {
    $Findings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
} else {
    Write-Status "No issues detected across the modes that were run." "OK"
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$SummaryPath = "C:\Temp\SPOMigrationStatus-Summary-$Timestamp.csv"
$Findings | ForEach-Object { [PSCustomObject]@{ Finding = $_ } } | Export-Csv -Path $SummaryPath -NoTypeInformation
Write-Status "`nSummary exported to: $SummaryPath" "OK"
