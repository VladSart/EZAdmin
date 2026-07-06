<#
.SYNOPSIS
    Fleet-wide Group Policy Analytics coverage report via Graph — automates the manual
    "upload GPO XML, click into each one, export CSV" workflow in GP-to-CSP-A.md Phase 1
    across every GPO already imported into Intune's Group Policy Analytics.

.DESCRIPTION
    GP-to-CSP-A.md Phase 1 describes exporting GPOs to XML and uploading them to Intune's
    Group Policy Analytics tool one at a time, then manually reviewing each GPO's
    Supported / Not Supported / Deprecated breakdown in the portal. That's fine for a
    single GPO, but there's no fast way to answer "across all the GPOs we've already
    imported, what percentage of settings are actually migratable, and which specific
    settings show up as gaps most often" without clicking through every report.

    This script uses Microsoft Graph's groupPolicyMigrationReports API to:
    - Enumerate every GPO already imported into Group Policy Analytics
      (groupPolicyMigrationReports — one per imported GPO)
    - For each, pull the individual setting mappings (groupPolicySettingMappings) and
      classify each setting as Mapped (has at least one non-empty mdmSettingInfo entry —
      i.e. a CSP equivalent exists) or Unmapped (no MDM equivalent found)
    - Compute a per-GPO migration-readiness percentage
    - Aggregate unmapped setting names across ALL GPOs tenant-wide, so recurring gaps
      (e.g. the same unsupported Administrative Template setting reused across many
      GPOs) surface as a single prioritized list instead of being buried per-GPO —
      directly feeding GP-to-CSP-A.md Phase 1b's "identify settings with no CSP
      equivalent" step and Playbook 2's remediation-script gap-filling decision

    Exports a per-GPO summary CSV and a tenant-wide unmapped-settings-frequency CSV, and
    prints a colour-coded console summary of the least-migratable GPOs and the most
    common recurring gaps.

    Does NOT cover (requires the GPO to already be imported — see GP-to-CSP-A.md Phase 1a):
    - Exporting GPOs from GPMC / uploading new XML to Group Policy Analytics
    - Actually building the replacement Settings Catalog / OMA-URI / ADMX profiles
      (GP-to-CSP-A.md Phase 2-5)
    - Per-device MDMWinsOverGP or CSP application state (see GP-to-CSP-A.md Playbook 3
      / Evidence Pack, which is device-local)

.PARAMETER GpoNameFilter
    Wildcard filter on imported GPO display name (e.g. "*Security*"). Default "*" (all
    imported GPOs).

.PARAMETER MinReadinessPctThreshold
    GPOs with a migration-readiness percentage at or below this value are flagged in the
    console warning summary as priority review candidates. Default: 60.

.PARAMETER OutputPath
    Directory for CSV export. Default: C:\Temp\GPtoCSPCoverage-<timestamp>\

.EXAMPLE
    .\Get-GPtoCSPCoverageReport.ps1

.EXAMPLE
    .\Get-GPtoCSPCoverageReport.ps1 -GpoNameFilter "*Baseline*" -MinReadinessPctThreshold 75

.NOTES
    Requires: Microsoft.Graph.DeviceManagement module (or Microsoft.Graph meta-module)
    Permissions: DeviceManagementConfiguration.Read.All
    Safe: Read-only — does not import, modify, or delete any Group Policy Analytics
          reports or Intune configuration profiles
    Cross-references: Intune/Troubleshooting/GP-to-CSP-A.md (Phase 1 GPO Analysis and
                       Export, Playbook 2 Remediation-Script gap fill) and
                       GP-to-CSP-B.md (Learning Pointers on GP Analytics usage)
#>

[CmdletBinding()]
param(
    [string]$GpoNameFilter = "*",

    [double]$MinReadinessPctThreshold = 60,

    [string]$OutputPath = "C:\Temp\GPtoCSPCoverage-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ── Preflight ────────────────────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.DeviceManagement)) {
    Write-Status "Microsoft.Graph.DeviceManagement module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser" "ERROR"
    exit 1
}

try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) { throw "No active Graph session" }
    Write-Status "Using existing Graph session: $($context.Account)" "OK"
} catch {
    Write-Status "Connecting to Graph (DeviceManagementConfiguration.Read.All)..." "INFO"
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# ── Step 1: Enumerate imported GPO migration reports ───────────────────────
Write-Status "Enumerating imported Group Policy Analytics reports..." "INFO"

$reports = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $migrationReports = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/groupPolicyMigrationReports?`$select=id,groupPolicyObjectId,groupPolicyObjectName,ouDistinguishedName,uploadedDateTime" |
        Select-Object -ExpandProperty value

    foreach ($r in $migrationReports) {
        if ($r.groupPolicyObjectName -like $GpoNameFilter) {
            $reports.Add([PSCustomObject]@{
                Id          = $r.id
                GpoName     = $r.groupPolicyObjectName
                OuPath      = $r.ouDistinguishedName
                UploadedAt  = $r.uploadedDateTime
            })
        }
    }
} catch {
    Write-Status "Could not enumerate groupPolicyMigrationReports: $($_.Exception.Message)" "ERROR"
    Write-Status "If this tenant has never imported a GPO into Group Policy Analytics, this list will be empty — see GP-to-CSP-A.md Phase 1a." "WARN"
    exit 1
}

if ($reports.Count -eq 0) {
    Write-Status "No imported GPO reports matched filter '$GpoNameFilter'. Exiting." "ERROR"
    Write-Status "Import GPOs first via Intune portal: Devices > Group Policy Analytics > Import (GP-to-CSP-A.md Phase 1a)." "INFO"
    exit 1
}

Write-Status "Found $($reports.Count) imported GPO report(s) matching filter." "OK"

# ── Step 2: Pull per-setting mappings for each GPO ──────────────────────────
$gpoSummary       = [System.Collections.Generic.List[PSCustomObject]]::new()
$unmappedSettings = [System.Collections.Generic.List[PSCustomObject]]::new()
$i = 0

foreach ($report in $reports) {
    $i++
    Write-Status "[$i/$($reports.Count)] Reading setting mappings for: $($report.GpoName)" "INFO"

    $mappings = $null
    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyMigrationReports/$($report.Id)/groupPolicySettingMappings" +
               "?`$expand=mdmSettingInfo&`$select=id,groupPolicySettingId"
        $mappings = Invoke-MgGraphRequest -Method GET -Uri $uri | Select-Object -ExpandProperty value
    } catch {
        Write-Status "  Could not pull setting mappings for '$($report.GpoName)': $($_.Exception.Message)" "WARN"
        continue
    }

    if (-not $mappings -or $mappings.Count -eq 0) {
        Write-Status "  No settings returned for '$($report.GpoName)' — report may still be processing" "WARN"
        continue
    }

    $mappedCount   = 0
    $unmappedCount = 0

    foreach ($m in $mappings) {
        $hasMdmMapping = $m.mdmSettingInfo -and $m.mdmSettingInfo.Count -gt 0

        if ($hasMdmMapping) {
            $mappedCount++
        } else {
            $unmappedCount++
            $unmappedSettings.Add([PSCustomObject]@{
                GpoName        = $report.GpoName
                SettingId      = $m.groupPolicySettingId
            })
        }
    }

    $totalSettings = $mappedCount + $unmappedCount
    $readinessPct  = if ($totalSettings -gt 0) { [math]::Round(($mappedCount / $totalSettings) * 100, 1) } else { 0 }

    $gpoSummary.Add([PSCustomObject]@{
        GpoName         = $report.GpoName
        OuPath          = $report.OuPath
        UploadedAt      = $report.UploadedAt
        TotalSettings   = $totalSettings
        MappedCount     = $mappedCount
        UnmappedCount   = $unmappedCount
        ReadinessPct    = $readinessPct
    })

    $statusLevel = if ($readinessPct -le $MinReadinessPctThreshold) { "WARN" } else { "OK" }
    Write-Status "  $($report.GpoName): $readinessPct% migratable ($mappedCount/$totalSettings settings mapped)" $statusLevel
}

# ── Step 3: Aggregate recurring unmapped settings tenant-wide ──────────────
$recurringGaps = $unmappedSettings | Group-Object SettingId | Sort-Object Count -Descending |
    Select-Object @{N='SettingId';E={$_.Name}}, Count, @{N='SeenInGpos';E={($_.Group.GpoName | Select-Object -Unique) -join '; '}}

# ── Export ────────────────────────────────────────────────────────────────
$summaryCsv = Join-Path $OutputPath "GpoReadinessSummary.csv"
$gapsCsv    = Join-Path $OutputPath "RecurringUnmappedSettings.csv"
$rawCsv     = Join-Path $OutputPath "AllUnmappedSettings.csv"

$gpoSummary       | Sort-Object ReadinessPct | Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8
$recurringGaps    | Export-Csv -Path $gapsCsv -NoTypeInformation -Encoding UTF8
$unmappedSettings | Export-Csv -Path $rawCsv -NoTypeInformation -Encoding UTF8

Write-Status "Per-GPO readiness summary: $summaryCsv" "OK"
Write-Status "Recurring unmapped settings (tenant-wide): $gapsCsv" "OK"
Write-Status "All unmapped settings (raw, per-GPO): $rawCsv" "OK"

Write-Host "`n=== Least Migration-Ready GPOs ===" -ForegroundColor Cyan
$gpoSummary | Sort-Object ReadinessPct | Select-Object -First 10 |
    Format-Table GpoName, TotalSettings, MappedCount, UnmappedCount, ReadinessPct -AutoSize

Write-Host "`n=== Most Common Recurring Gaps (no CSP equivalent, seen across multiple GPOs) ===" -ForegroundColor Cyan
$recurringGaps | Select-Object -First 10 | Format-Table SettingId, Count, SeenInGpos -AutoSize

$priorityGpos = $gpoSummary | Where-Object { $_.ReadinessPct -le $MinReadinessPctThreshold }
if ($priorityGpos) {
    Write-Status "$($priorityGpos.Count) GPO(s) at or below $MinReadinessPctThreshold% readiness — review these first before scheduling a migration wave" "WARN"
} else {
    Write-Status "All imported GPOs are above $MinReadinessPctThreshold% migration readiness." "OK"
}

Write-Host "`nRecurring gaps at the top of RecurringUnmappedSettings.csv are strong candidates for a" -ForegroundColor DarkGray
Write-Host "shared Remediation script (GP-to-CSP-A.md Playbook 2) rather than per-GPO one-off handling." -ForegroundColor DarkGray
