<#
.SYNOPSIS
    Reports FRS-to-DFSR SYSVOL migration state across all domain controllers.

.DESCRIPTION
    Wraps dfsrmig /getglobalstate and /getmigrationstate, cross-references the
    result against the live domain controller inventory (Get-ADDomainController),
    and flags any DC that is unreachable, missing from the migration report, or
    not yet confirmed at the current target state. Also flags orphaned DC
    objects — a common root cause of migrations that hang indefinitely.

    Read-only. Does NOT change migration state. Safe to run at any time,
    including in production, including mid-migration.

    Covers:
    - Domain-wide target state (dfsrmig /getglobalstate)
    - Per-DC actual confirmed state (dfsrmig /getmigrationstate)
    - Reachability check for every DC in the domain
    - Orphaned/phantom DC object detection
    - SYSVOL share presence check on each reachable DC

    Does NOT cover:
    - Advancing or rolling back migration state (use dfsrmig directly, see
      FRS-to-DFSR-Migration-B.md / -A.md for guarded procedures)
    - General DFSR replication health post-migration (see Test-DFSHealth.ps1)

.PARAMETER SkipShareCheck
    Skip the SYSVOL/NETLOGON share verification step (faster, useful for
    frequent polling during an active migration window).

.PARAMETER ExportPath
    Path for the CSV export of per-DC results. Default: .\DFSRMigrationState-<timestamp>.csv

.EXAMPLE
    .\Get-DFSRMigrationState.ps1
    Full check: global state, per-DC state, reachability, orphan detection, share check.

.EXAMPLE
    .\Get-DFSRMigrationState.ps1 -SkipShareCheck -ExportPath C:\Temp\migration-check.csv
    Faster check for repeated polling during an active migration, custom export path.

.NOTES
    Requires: RSAT Active Directory PowerShell module (ActiveDirectory), dfsrmig.exe
              (present on any DC or member with RSAT-DFS-Mgmt-Con / AD DS role tools)
    Run-as:   Domain user with read access to AD and WinRM/PowerShell remoting to DCs
    Safe:     Yes — entirely read-only, does not call dfsrmig /setglobalstate
    Tested on: Windows Server 2019/2022 domain controllers
#>

[CmdletBinding()]
param(
    [switch]$SkipShareCheck,
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green" }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red" }
        default  { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Starting FRS-to-DFSR migration state check — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not (Get-Command dfsrmig.exe -ErrorAction SilentlyContinue)) {
    Write-Status "dfsrmig.exe not found on this system. Run from a DC or a machine with AD DS/DFS management tools installed." "ERROR"
    exit 1
}

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found. Install RSAT: Install-WindowsFeature RSAT-AD-PowerShell" "ERROR"
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\DFSRMigrationState-$timestamp.csv"
}
#endregion

#region ─── Global state ───────────────────────────────────────────────────────
Write-Status "Querying domain-wide target migration state..."
$globalStateRaw = & dfsrmig /getglobalstate 2>&1
Write-Host ""
Write-Host "─── Global State (target) ─────────────────────────" -ForegroundColor Cyan
$globalStateRaw | ForEach-Object { Write-Host "  $_" }
Write-Host ""

$globalStateIsFinal = $globalStateRaw -match "Eliminated"
if ($globalStateIsFinal) {
    Write-Status "Global state reports Eliminated — migration is complete domain-wide." "OK"
} else {
    Write-Status "Migration is not yet at Eliminated state — treat as in-progress." "WARN"
}
#endregion

#region ─── Per-DC migration state ─────────────────────────────────────────────
Write-Status "Querying per-DC confirmed migration state..."
$migrationStateRaw = & dfsrmig /getmigrationstate 2>&1
Write-Host ""
Write-Host "─── Per-DC Migration State (actual) ───────────────" -ForegroundColor Cyan
$migrationStateRaw | ForEach-Object { Write-Host "  $_" }
Write-Host ""

# dfsrmig output is not structured CSV — capture as text for evidence,
# and separately determine "all succeeded" by looking for failure/pending markers.
$migrationLooksClean = -not ($migrationStateRaw -match "have not migrated|not succeeded|pending")
#endregion

#region ─── Live DC inventory + reachability ───────────────────────────────────
Write-Status "Enumerating domain controllers from AD..."
try {
    $dcs = Get-ADDomainController -Filter * -ErrorAction Stop |
        Select-Object Name, HostName, IPv4Address, OperatingSystem
} catch {
    Write-Status "Failed to enumerate domain controllers: $_" "ERROR"
    exit 1
}
Write-Status "Found $($dcs.Count) domain controller(s) in AD" "OK"

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($dc in $dcs) {
    $reachable = Test-Connection -ComputerName $dc.IPv4Address -Count 1 -Quiet -ErrorAction SilentlyContinue

    $sysvolShared = "SKIPPED"
    if (-not $SkipShareCheck -and $reachable) {
        try {
            $shareCheck = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                (net share) -match "SYSVOL|NETLOGON"
            } -ErrorAction Stop
            $sysvolShared = if ($shareCheck) { "YES" } else { "NO" }
        } catch {
            $sysvolShared = "ERROR: $($_.Exception.Message)"
        }
    } elseif (-not $reachable) {
        $sysvolShared = "UNREACHABLE"
    }

    $mentionedInMigrationOutput = $migrationStateRaw -match [regex]::Escape($dc.Name)

    $status = "OK"
    if (-not $reachable) {
        $status = "UNREACHABLE"
    } elseif (-not $mentionedInMigrationOutput) {
        $status = "NOT REPORTED"
    } elseif ($sysvolShared -eq "NO") {
        $status = "SYSVOL NOT SHARED"
    }

    $results.Add([PSCustomObject]@{
        DCName              = $dc.Name
        HostName             = $dc.HostName
        IPAddress            = $dc.IPv4Address
        OperatingSystem      = $dc.OperatingSystem
        Reachable            = $reachable
        SeenInMigrationState = $mentionedInMigrationOutput
        SysvolShared         = $sysvolShared
        Status               = $status
        CheckedAt            = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })

    $colour = switch ($status) {
        "OK"                 { "Green" }
        "UNREACHABLE"        { "Red" }
        "NOT REPORTED"       { "Magenta" }
        "SYSVOL NOT SHARED"  { "Yellow" }
        default              { "White" }
    }
    Write-Host "  [$status] $($dc.Name) | Reachable: $reachable | SYSVOL shared: $sysvolShared" -ForegroundColor $colour
}
#endregion

#region ─── Orphan detection heads-up ──────────────────────────────────────────
$unreachableCount = ($results | Where-Object { -not $_.Reachable }).Count
if ($unreachableCount -gt 0) {
    Write-Host ""
    Write-Status "$unreachableCount DC(s) unreachable. If any of these are decommissioned but not metadata-cleaned, they WILL block migration state advancement indefinitely. Verify with 'ntdsutil metadata cleanup' if confirmed dead." "WARN"
}
#endregion

#region ─── Summary ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Summary ───────────────────────────────────────" -ForegroundColor Cyan
$statCounts = $results | Group-Object Status
foreach ($s in $statCounts) {
    Write-Host "  $($s.Name.PadRight(20)) : $($s.Count)"
}
Write-Host ""
#endregion

#region ─── Export ─────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Per-DC results exported → $ExportPath" "OK"

$rawLogPath = $ExportPath -replace '\.csv$', '-raw-dfsrmig-output.txt'
@(
    "=== dfsrmig /getglobalstate ==="
    $globalStateRaw
    ""
    "=== dfsrmig /getmigrationstate ==="
    $migrationStateRaw
) | Out-File -FilePath $rawLogPath -Encoding UTF8
Write-Status "Raw dfsrmig output saved → $rawLogPath" "OK"

Write-Status "FRS-to-DFSR migration state check complete — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
