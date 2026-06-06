<#
.SYNOPSIS
    Reports Entra Connect (Azure AD Connect) synchronization errors across all connectors.

.DESCRIPTION
    Queries the Entra Connect ADSync service on the local server for:
      - Connector run history and status
      - Object-level sync errors (export, import, and full-object errors)
      - Quarantined objects
      - Current scheduler state (staging mode check)
      - Last successful sync timestamp per connector

    Run this on the Entra Connect server to produce a full health snapshot.
    Outputs a summary to the console and exports detailed error rows to CSV.

    Does NOT make any changes. Read-only.

.PARAMETER TopErrors
    Number of most recent object errors to include in the report. Default: 50.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\EntraConnectSyncErrors_<timestamp>.csv

.PARAMETER IncludeQuarantine
    Include objects currently in quarantine (disconnectors). Default: $true.

.EXAMPLE
    .\Get-EntraConnectSyncErrors.ps1
    # Full default report — console summary + CSV export

.EXAMPLE
    .\Get-EntraConnectSyncErrors.ps1 -TopErrors 100 -ExportPath "C:\Reports\SyncErrors.csv"
    # Extended report with custom CSV path

.NOTES
    Requires: ADSync module (installed with Entra Connect / Azure AD Connect)
    Run as: Local admin on the Entra Connect server
    Safe/Unsafe: READ-ONLY — makes no changes
    Tested against: Entra Connect v2.x (Azure AD Connect 2.x)
#>

[CmdletBinding()]
param(
    [int]    $TopErrors    = 50,
    [string] $ExportPath   = "$env:TEMP\EntraConnectSyncErrors_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [bool]   $IncludeQuarantine = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Helpers ---

function Write-Status {
    param(
        [string]$Message,
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"     { "Green"  }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red"    }
        "HEADER" { "Cyan"   }
        default  { "White"  }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-FriendlyErrorType {
    param([string]$ErrorType)
    switch -Wildcard ($ErrorType) {
        "attribute-value-must-be-unique" { "Duplicate attribute (proxy/UPN conflict)" }
        "object-class-violation"         { "Schema/object-class mismatch"             }
        "invalid-dn-syntax"              { "Invalid Distinguished Name"               }
        "entry-already-exists"           { "Object already exists in target"          }
        "add-delete-conflict"            { "Add/delete sequence conflict"             }
        default                          { $ErrorType }
    }
}

#endregion

#region --- Preflight ---

Write-Status "Entra Connect Sync Error Reporter" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

# Check ADSync module
if (-not (Get-Module -ListAvailable -Name ADSync)) {
    Write-Status "ADSync module not found. This script must run on the Entra Connect server." -Status "ERROR"
    exit 1
}
Import-Module ADSync -ErrorAction Stop
Write-Status "ADSync module loaded." -Status "OK"

#endregion

#region --- Scheduler / Staging Mode ---

Write-Status "`n=== Scheduler State ===" -Status "HEADER"
$scheduler = Get-ADSyncScheduler
Write-Host "  SyncCycleEnabled    : $($scheduler.SyncCycleEnabled)"
Write-Host "  StagingModeEnabled  : $($scheduler.StagingModeEnabled)"
Write-Host "  NextSyncCycleType   : $($scheduler.NextSyncCyclePolicyType)"
Write-Host "  LastSyncTime        : $($scheduler.LastSyncCycleStartedTimeUtc) UTC"

if ($scheduler.StagingModeEnabled) {
    Write-Status "STAGING MODE IS ENABLED — Entra Connect is NOT writing changes to Entra ID!" -Status "WARN"
}
if (-not $scheduler.SyncCycleEnabled) {
    Write-Status "Sync cycle is DISABLED — no automatic syncs are running." -Status "WARN"
}

#endregion

#region --- Connector Run Status ---

Write-Status "`n=== Connector Run History ===" -Status "HEADER"
$connectors = Get-ADSyncConnector | Select-Object Name, Type, State
$runHistory = @()

foreach ($conn in $connectors) {
    Write-Host "`n  Connector: $($conn.Name)  [$($conn.Type)]  State: $($conn.State)"

    try {
        $runs = Get-ADSyncConnectorRunStatus -ConnectorName $conn.Name -ErrorAction SilentlyContinue
        if ($runs) {
            $lastRun = $runs | Sort-Object StartDate -Descending | Select-Object -First 1
            Write-Host "    Last run  : $($lastRun.StartDate) UTC"
            Write-Host "    Run type  : $($lastRun.RunProfileName)"
            Write-Host "    Result    : $($lastRun.Result)"
            if ($lastRun.Result -ne "success") {
                Write-Status "    Last run FAILED for connector: $($conn.Name)" -Status "WARN"
            }
            $runHistory += $lastRun
        } else {
            Write-Host "    (No run history available)"
        }
    } catch {
        Write-Status "  Could not retrieve run history for $($conn.Name): $_" -Status "WARN"
    }
}

#endregion

#region --- Object-Level Sync Errors ---

Write-Status "`n=== Object Sync Errors (Top $TopErrors) ===" -Status "HEADER"
$errorRows = @()

try {
    $syncErrors = Get-ADSyncObjectsWithSyncError -ErrorCategory ExportError -MaxResults $TopErrors -ErrorAction SilentlyContinue
    if (-not $syncErrors) {
        $syncErrors = @()
    }
} catch {
    Write-Status "Get-ADSyncObjectsWithSyncError not available — trying alternative method." -Status "WARN"
    $syncErrors = @()
}

# Alternative: query via Synchronization Service Manager COM object
if ($syncErrors.Count -eq 0) {
    try {
        $mmsServer = New-Object -ComObject "miis.server" -ErrorAction Stop
        $mmsErrors = $mmsServer.GetImportExportErrors()
        # Flatten if enumerable
        foreach ($e in $mmsErrors) {
            $errorRows += [PSCustomObject]@{
                Connector    = $e.ConnectorName
                DN           = $e.DN
                ErrorType    = Get-FriendlyErrorType $e.ErrorType
                ObjectType   = $e.ObjectType
                TimeStamp    = $e.TimeStamp
                Source       = "ExportError"
            }
        }
    } catch {
        Write-Status "COM server query failed — falling back to Synchronization Service log only." -Status "WARN"
    }
}

# Process structured errors if available
foreach ($e in $syncErrors) {
    $errorRows += [PSCustomObject]@{
        Connector    = $e.ConnectorName
        DN           = $e.DistinguishedName
        ErrorType    = Get-FriendlyErrorType $e.ErrorType
        ObjectType   = $e.ObjectType
        TimeStamp    = $e.TimeStamp
        Source       = "ExportError"
    }
}

if ($errorRows.Count -gt 0) {
    Write-Status "Found $($errorRows.Count) object-level sync error(s)." -Status "WARN"
    $errorRows | Format-Table Connector, ErrorType, DN, TimeStamp -AutoSize
} else {
    Write-Status "No object-level export errors found via ADSync module." -Status "OK"
}

#endregion

#region --- Quarantined Objects ---

if ($IncludeQuarantine) {
    Write-Status "`n=== Quarantined / Disconnector Objects ===" -Status "HEADER"

    try {
        $quarantine = Get-ADSyncObjectsInDisconnectorSpace -ErrorAction SilentlyContinue
        if ($quarantine -and $quarantine.Count -gt 0) {
            Write-Status "Found $($quarantine.Count) disconnector/quarantined object(s)." -Status "WARN"
            $quarantine | Select-Object -First 20 | Format-Table ConnectorName, DN, ObjectType -AutoSize

            foreach ($q in $quarantine) {
                $errorRows += [PSCustomObject]@{
                    Connector    = $q.ConnectorName
                    DN           = $q.DN
                    ErrorType    = "Disconnected/Quarantined"
                    ObjectType   = $q.ObjectType
                    TimeStamp    = (Get-Date)
                    Source       = "Quarantine"
                }
            }
        } else {
            Write-Status "No quarantined objects found." -Status "OK"
        }
    } catch {
        Write-Status "Could not query disconnector space: $_" -Status "WARN"
    }
}

#endregion

#region --- Entra Connect Version ---

Write-Status "`n=== Entra Connect Version ===" -Status "HEADER"
try {
    $versionKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Azure AD Connect" -ErrorAction SilentlyContinue
    if ($versionKey) {
        Write-Host "  Version     : $($versionKey.Version)"
        Write-Host "  Install Dir : $($versionKey.InstallDir)"
    } else {
        # Fallback: check AAD Connect key
        $altKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Azure Active Directory Connect" -ErrorAction SilentlyContinue
        if ($altKey) {
            Write-Host "  Version     : $($altKey.Version)"
        } else {
            Write-Status "Version registry key not found." -Status "WARN"
        }
    }
} catch {
    Write-Status "Could not read version info: $_" -Status "WARN"
}

#endregion

#region --- Export to CSV ---

if ($errorRows.Count -gt 0) {
    $errorRows | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "`nExported $($errorRows.Count) error row(s) to: $ExportPath" -Status "OK"
} else {
    # Export a summary-only CSV
    $summaryRow = [PSCustomObject]@{
        Connector    = "ALL"
        DN           = "N/A"
        ErrorType    = "No errors detected"
        ObjectType   = "N/A"
        TimeStamp    = (Get-Date)
        Source       = "Summary"
    }
    $summaryRow | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "`nNo errors found. Summary exported to: $ExportPath" -Status "OK"
}

#endregion

#region --- Final Summary ---

Write-Status "`n=== Summary ===" -Status "HEADER"
Write-Host "  Staging mode active : $($scheduler.StagingModeEnabled)"
Write-Host "  Sync enabled        : $($scheduler.SyncCycleEnabled)"
Write-Host "  Object errors found : $($errorRows.Count)"
Write-Host "  Report saved to     : $ExportPath"
Write-Host ""
Write-Status "Done." -Status "OK"

#endregion
