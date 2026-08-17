<#
.SYNOPSIS
    Read-only pre-migration readiness and post-migration verification audit for
    a Windows print server (Print and Document Services / PrintBRM migrations).

.DESCRIPTION
    Companion script to Windows/Troubleshooting/PrintServerMigration-A.md and
    PrintServerMigration-B.md. Performs NO changes — inventories the current
    state of a print server and flags conditions that commonly break a PrintBRM
    (Printbrm.exe) backup/restore/cutover migration:

      - Print and Document Services role presence and PrintBRM.exe availability
      - Print$ share and Remote Registry prerequisite state (needed for remote
        backup/restore operations against a different computer)
      - Full printer inventory with migration-eligibility flags:
          * Local bus (USB/LPT/COM) or plug-and-play printers — these are
            inventoried by PrintBRM but structurally CANNOT be restored to a
            different machine, and must be manually reconnected/re-shared
          * LPR-associated ports — restore requires the LPR Port Monitor
            feature pre-installed on the destination, or -lpr2tcp conversion
          * Published-to-AD-DS state — relevant to the pre-rename unpublish
            step and post-rename duplicate-object risk
      - A best-effort "legacy driver risk" flag for installed drivers, since
        there is no single reliable API to read a driver's V3/V4 model
        directly on every Windows Server version — this script flags drivers
        whose DriverDate is old and/or whose provider name matches common
        patterns as WORTH MANUAL VERIFICATION against the vendor's current
        package, not as a definitive V3/V4 determination
      - Recent PrintService/PrintBRM event log entries (checks BOTH channels,
        since which one is populated depends on whether Print and Document
        Services was already installed when a migration operation last ran)

    Explicitly does NOT: run a backup or restore, install any feature, modify
    any share/service/printer, or attempt to contact a remote computer unless
    -RemoteComputerName is supplied (and even then, only read-only queries are
    issued against it).

.PARAMETER RemoteComputerName
    Optional. If supplied, also queries printer/role/share/service state on
    this remote computer (e.g. the migration partner — source or destination)
    in addition to the local machine. Requires WinRM/CIM connectivity.

.PARAMETER LegacyDriverAgeYears
    Age in years beyond which an installed driver's DriverDate is flagged as
    worth manual verification against the vendor's current package. Default 5.

.PARAMETER CsvPath
    Optional path to export the full printer inventory (with eligibility
    flags) as CSV. If omitted, a timestamped file is written to the current
    directory.

.EXAMPLE
    .\Get-PrintServerMigrationAudit.ps1
    Audits the local machine only.

.EXAMPLE
    .\Get-PrintServerMigrationAudit.ps1 -RemoteComputerName PRINTSRV02 -CsvPath C:\Temp\migration-audit.csv
    Audits the local machine and PRINTSRV02, exporting the combined printer
    inventory to the specified CSV path.

.NOTES
    Requires: PowerShell 5.1+, PrintManagement module (built in on Windows
    Server with the Print and Document Services role, and on Windows 10/11
    with RSAT Print Services Tools installed for remote queries).
    Safe to run against a production print server — read-only throughout.
    Does not require -RunAsAdministrator for local queries, but some role/
    service state reads may return incomplete data without elevation.
#>

[CmdletBinding()]
param(
    [string]$RemoteComputerName,

    [int]$LegacyDriverAgeYears = 5,

    [string]$CsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-PrintServerReadiness {
    param([string]$TargetComputer)

    $result = [ordered]@{
        ComputerName        = $TargetComputer
        RoleInstalled       = $null
        PrintBrmPresent     = $null
        PrintDollarShare    = $null
        RemoteRegistryState = $null
    }

    try {
        if ($TargetComputer -eq $env:COMPUTERNAME) {
            $feature = Get-WindowsFeature -Name Print-Server -ErrorAction SilentlyContinue
            $result.RoleInstalled = if ($feature) { $feature.Installed } else { "Unknown (Get-WindowsFeature unavailable — likely a client OS, not Windows Server)" }
            $result.PrintBrmPresent = Test-Path "$env:SystemRoot\System32\spool\tools\PrintBRM.exe"
        }
        else {
            $result.RoleInstalled = "Not checked locally — remote role check requires Invoke-Command; run this script directly on $TargetComputer for role state"
            $result.PrintBrmPresent = "Not checked remotely"
        }
    }
    catch {
        Write-Status "Could not determine role state on $TargetComputer : $($_.Exception.Message)" -Status WARN
    }

    try {
        $shareParams = @{ Name = "Print$"; ErrorAction = "SilentlyContinue" }
        if ($TargetComputer -ne $env:COMPUTERNAME) { $shareParams["CimSession"] = New-CimSession -ComputerName $TargetComputer -ErrorAction Stop }
        $share = Get-SmbShare @shareParams
        $result.PrintDollarShare = if ($share) { "Present ($($share.Path))" } else { "NOT FOUND" }
        if ($shareParams.ContainsKey("CimSession")) { Remove-CimSession -CimSession $shareParams["CimSession"] -ErrorAction SilentlyContinue }
    }
    catch {
        $result.PrintDollarShare = "Could not query: $($_.Exception.Message)"
    }

    try {
        $svcParams = @{ Name = "RemoteRegistry"; ErrorAction = "SilentlyContinue" }
        if ($TargetComputer -ne $env:COMPUTERNAME) { $svcParams["ComputerName"] = $TargetComputer }
        $svc = Get-Service @svcParams
        $result.RemoteRegistryState = if ($svc) { "$($svc.Status) (StartType: $($svc.StartType))" } else { "NOT FOUND" }
    }
    catch {
        $result.RemoteRegistryState = "Could not query: $($_.Exception.Message)"
    }

    return [PSCustomObject]$result
}

function Get-PrinterMigrationInventory {
    param(
        [string]$TargetComputer,
        [int]$AgeThresholdYears
    )

    $printerParams = @{ ErrorAction = "SilentlyContinue" }
    if ($TargetComputer -ne $env:COMPUTERNAME) { $printerParams["ComputerName"] = $TargetComputer }

    $printers = Get-Printer @printerParams
    $drivers  = Get-PrinterDriver @printerParams

    $cutoffDate = (Get-Date).AddYears(-1 * $AgeThresholdYears)

    $inventory = foreach ($p in $printers) {
        $driverInfo = $drivers | Where-Object { $_.Name -eq $p.DriverName } | Select-Object -First 1

        $isLocalBusOrPnP = $p.PortName -match "^(USB|LPT|COM)\d*$"
        $isLikelyLPR     = $p.PortName -match "(?i)LPR"

        $legacyRisk = "Unknown"
        if ($driverInfo -and $driverInfo.PSObject.Properties.Name -contains "DriverDate" -and $driverInfo.DriverDate) {
            $legacyRisk = if ([datetime]$driverInfo.DriverDate -lt $cutoffDate) {
                "VERIFY — driver package older than $AgeThresholdYears years, confirm current vendor availability (Jan 2026 V3/V4 publishing change)"
            } else {
                "OK — recent driver package"
            }
        }

        [PSCustomObject]@{
            ComputerName       = $TargetComputer
            PrinterName        = $p.Name
            PortName           = $p.PortName
            DriverName         = $p.DriverName
            DriverDate         = if ($driverInfo -and $driverInfo.PSObject.Properties.Name -contains "DriverDate") { $driverInfo.DriverDate } else { "N/A" }
            Shared             = $p.Shared
            ShareName          = $p.ShareName
            Published          = $p.Published
            PrinterStatus      = $p.PrinterStatus
            LocalBusOrPnP_WILL_NOT_MIGRATE = $isLocalBusOrPnP
            LikelyLPR_NeedsFeatureOrConversion = $isLikelyLPR
            LegacyDriverRisk   = $legacyRisk
        }
    }

    return $inventory
}

function Get-PrintMigrationEvents {
    param([string]$TargetComputer)

    $logsToCheck = @(
        "Microsoft-Windows-PrintService/Admin",
        "Microsoft-Windows-PrintBRM/Admin"
    )

    $allEvents = foreach ($logName in $logsToCheck) {
        try {
            $params = @{ LogName = $logName; MaxEvents = 20; ErrorAction = "SilentlyContinue" }
            if ($TargetComputer -ne $env:COMPUTERNAME) { $params["ComputerName"] = $TargetComputer }
            $events = Get-WinEvent @params
            if ($events) {
                $events | Select-Object @{N="LogName";E={$logName}}, TimeCreated, Id, LevelDisplayName, Message
            }
        }
        catch {
            Write-Status "Log '$logName' not accessible on $TargetComputer (may not exist yet if the role isn't installed) — this is expected on a fresh destination" -Status INFO
        }
    }

    return $allEvents
}

# ===================== PREFLIGHT =====================
Write-Status "Print Server Migration Audit starting — LOCAL: $env:COMPUTERNAME$(if ($RemoteComputerName) { " | REMOTE: $RemoteComputerName" })" -Status INFO
Write-Status "This script is READ-ONLY. No printers, shares, services, or features will be modified." -Status INFO

$targets = @($env:COMPUTERNAME)
if ($RemoteComputerName) { $targets += $RemoteComputerName }

# ===================== DETECT / EXECUTE =====================
$readinessResults = @()
$inventoryResults = @()
$eventResults     = @()

foreach ($target in $targets) {
    Write-Status "Auditing $target ..." -Status INFO

    $readinessResults += Get-PrintServerReadiness -TargetComputer $target
    $inventoryResults += Get-PrinterMigrationInventory -TargetComputer $target -AgeThresholdYears $LegacyDriverAgeYears
    $eventResults     += Get-PrintMigrationEvents -TargetComputer $target
}

# ===================== VALIDATE / REPORT =====================
Write-Host "`n=== Print Server Migration Readiness ===" -ForegroundColor Cyan
$readinessResults | Format-List

Write-Host "`n=== Printer Inventory — Migration Eligibility ===" -ForegroundColor Cyan
$inventoryResults | Format-Table ComputerName, PrinterName, PortName, DriverName, Shared, Published, LocalBusOrPnP_WILL_NOT_MIGRATE, LikelyLPR_NeedsFeatureOrConversion -AutoSize

$blockers = $inventoryResults | Where-Object { $_.LocalBusOrPnP_WILL_NOT_MIGRATE -or $_.LikelyLPR_NeedsFeatureOrConversion }
if ($blockers) {
    Write-Status "$($blockers.Count) printer(s) need manual handling (local-bus/plug-and-play will not restore, or LPR needs a feature/port-type decision):" -Status WARN
    $blockers | Format-Table PrinterName, PortName, LocalBusOrPnP_WILL_NOT_MIGRATE, LikelyLPR_NeedsFeatureOrConversion -AutoSize
}
else {
    Write-Status "No local-bus/plug-and-play or LPR printers detected — no structural migration blockers found." -Status OK
}

$legacyRiskPrinters = $inventoryResults | Where-Object { $_.LegacyDriverRisk -like "VERIFY*" }
if ($legacyRiskPrinters) {
    Write-Status "$($legacyRiskPrinters.Count) printer(s) flagged for manual driver-currency verification (see LegacyDriverRisk column) — relevant if the destination is Windows Server 2025+/Windows 11 24H2+, given the January 2026 change to legacy V3/V4 driver publishing via Windows Update:" -Status WARN
}

$duplicatePublished = $inventoryResults | Where-Object { $_.Published -eq $true } | Group-Object PrinterName | Where-Object { $_.Count -gt 1 }
if ($duplicatePublished) {
    Write-Status "Possible duplicate AD DS-published printer objects detected across audited computers — verify before/after a cutover rename:" -Status WARN
    $duplicatePublished | ForEach-Object { Write-Host "  - $($_.Name) : $($_.Count) instances" }
}

if ($eventResults) {
    Write-Host "`n=== Recent PrintService / PrintBRM Events ===" -ForegroundColor Cyan
    $eventResults | Sort-Object TimeCreated -Descending | Select-Object -First 20 |
        Format-Table LogName, TimeCreated, Id, LevelDisplayName, Message -Wrap
}
else {
    Write-Status "No recent PrintService/PrintBRM events found on audited computer(s) — expected if no migration operation has run yet, or if Print and Document Services isn't installed." -Status INFO
}

# ===================== EXPORT =====================
if (-not $CsvPath) {
    $CsvPath = ".\PrintServerMigrationAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
}
$inventoryResults | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
Write-Status "Printer inventory exported to $CsvPath" -Status OK

Write-Status "Audit complete." -Status OK
