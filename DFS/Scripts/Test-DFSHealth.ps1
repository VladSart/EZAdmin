<#
.SYNOPSIS
    Comprehensive DFS health check — namespace targets, replication backlog, service state, event errors.

.DESCRIPTION
    Runs a full diagnostic sweep across all DFS Namespace roots and Replication Groups
    visible from this machine. Outputs a colour-coded console report and optionally
    exports a CSV evidence bundle.

    Covers:
    - DFSR and DFS service state on all members
    - Namespace root target availability
    - Folder target state (Online/Offline)
    - Replication backlog per connection
    - Staging quota utilisation
    - Recent error/warning events from DFS Replication log

.PARAMETER ExportPath
    Optional. Path to export CSV reports. Defaults to $env:TEMP\DFSHealthCheck-<date>

.PARAMETER DomainNamespace
    Optional. Specific namespace root to check (e.g. \\contoso.com\files).
    If omitted, discovers all domain-based namespaces.

.PARAMETER MaxBacklogWarning
    Files in backlog before flagging as WARNING. Default: 100.

.PARAMETER MaxBacklogError
    Files in backlog before flagging as ERROR. Default: 1000.

.EXAMPLE
    .\Test-DFSHealth.ps1

.EXAMPLE
    .\Test-DFSHealth.ps1 -DomainNamespace "\\contoso.com\files" -ExportPath "C:\Tickets\DFS-check"

.NOTES
    Requires: RSAT-DFS-Mgmt-Con, DFSR PowerShell module
    Run as: Domain Admin or equivalent
    Safe to run multiple times — read-only, no changes made
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ExportPath = "$env:TEMP\DFSHealthCheck-$(Get-Date -Format 'yyyyMMdd-HHmm')",
    [string]$DomainNamespace = "",
    [int]$MaxBacklogWarning = 100,
    [int]$MaxBacklogError   = 1000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Helpers ---

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "INFO"    { "Cyan" }
        default   { "White" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Test-RemoteService {
    param([string]$ComputerName, [string]$ServiceName)
    try {
        $svc = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
        return $svc.Status.ToString()
    } catch {
        return "UNREACHABLE"
    }
}

#endregion

#region --- Setup ---

New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
$results = [System.Collections.Generic.List[PSObject]]::new()

Write-Status "DFS Health Check started — $(Get-Date)" "INFO"
Write-Status "Export path: $ExportPath" "INFO"
Write-Host ""

#endregion

#region --- 1. Discover namespaces ---

Write-Host "=== NAMESPACE HEALTH ===" -ForegroundColor Magenta

$namespaces = if ($DomainNamespace) {
    @($DomainNamespace)
} else {
    try {
        (Get-DfsnRoot -ErrorAction Stop).Path
    } catch {
        Write-Status "Could not enumerate namespace roots — specify -DomainNamespace manually" "WARN"
        @()
    }
}

foreach ($ns in $namespaces) {
    Write-Status "Namespace: $ns" "INFO"

    # Root targets
    try {
        $rootTargets = Get-DfsnRootTarget -Path $ns -ErrorAction Stop
        foreach ($rt in $rootTargets) {
            $serviceState = Test-RemoteService -ComputerName ($rt.TargetPath -split "\\")[2] -ServiceName "Dfs"
            $status = if ($rt.State -eq "Online" -and $serviceState -eq "Running") { "OK" }
                      elseif ($rt.State -ne "Online") { "ERROR" }
                      else { "WARN" }

            Write-Status "  Root target: $($rt.TargetPath) | DFS state: $($rt.State) | Service: $serviceState" $status

            $results.Add([PSCustomObject]@{
                Type        = "NamespaceRootTarget"
                Namespace   = $ns
                Target      = $rt.TargetPath
                State       = $rt.State
                Service     = $serviceState
                Status      = $status
            })
        }
    } catch {
        Write-Status "  Failed to get root targets: $($_.Exception.Message)" "ERROR"
    }

    # Folder targets
    try {
        $folders = Get-DfsnFolder -Path $ns -ErrorAction Stop
        $offlineCount = 0
        foreach ($folder in $folders) {
            $targets = Get-DfsnFolderTarget -Path $folder.Path -ErrorAction SilentlyContinue
            foreach ($t in $targets) {
                if ($t.State -ne "Online") {
                    $offlineCount++
                    Write-Status "  OFFLINE target: $($t.TargetPath) for $($folder.Path)" "ERROR"
                    $results.Add([PSCustomObject]@{
                        Type      = "FolderTarget"
                        Namespace = $ns
                        Folder    = $folder.Path
                        Target    = $t.TargetPath
                        State     = $t.State
                        Status    = "ERROR"
                    })
                }
            }
        }
        if ($offlineCount -eq 0) {
            Write-Status "  All $($folders.Count) folder targets online" "OK"
        }
    } catch {
        Write-Status "  Failed to enumerate folders: $($_.Exception.Message)" "WARN"
    }
}

#endregion

#region --- 2. Replication group health ---

Write-Host ""
Write-Host "=== REPLICATION GROUP HEALTH ===" -ForegroundColor Magenta

try {
    $groups = Get-DfsrGroup -ErrorAction Stop

    foreach ($group in $groups) {
        Write-Status "Replication group: $($group.GroupName)" "INFO"

        $connections = Get-DfsrConnection -GroupName $group.GroupName -ErrorAction SilentlyContinue
        $folders     = Get-DfsrFolder -GroupName $group.GroupName -ErrorAction SilentlyContinue

        foreach ($conn in $connections) {
            if (-not $conn.Enabled) {
                Write-Status "  Connection DISABLED: $($conn.SourceComputerName) → $($conn.DestinationComputerName)" "WARN"
                continue
            }

            foreach ($folder in $folders) {
                try {
                    $backlog = Get-DfsrBacklog `
                        -GroupName $group.GroupName `
                        -FolderName $folder.FolderName `
                        -SourceComputerName $conn.SourceComputerName `
                        -DestinationComputerName $conn.DestinationComputerName `
                        -ErrorAction Stop | Measure-Object

                    $count  = $backlog.Count
                    $status = if ($count -eq 0) { "OK" }
                              elseif ($count -lt $MaxBacklogWarning) { "OK" }
                              elseif ($count -lt $MaxBacklogError) { "WARN" }
                              else { "ERROR" }

                    $msg = "  Backlog [$($folder.FolderName)] $($conn.SourceComputerName) → $($conn.DestinationComputerName): $count files"
                    Write-Status $msg $status

                    $results.Add([PSCustomObject]@{
                        Type        = "ReplicationBacklog"
                        Group       = $group.GroupName
                        Folder      = $folder.FolderName
                        Source      = $conn.SourceComputerName
                        Destination = $conn.DestinationComputerName
                        BacklogCount = $count
                        Status      = $status
                    })
                } catch {
                    Write-Status "  Could not get backlog for $($folder.FolderName) $($conn.SourceComputerName)→$($conn.DestinationComputerName): $($_.Exception.Message)" "WARN"
                }
            }
        }

        # Staging quota check
        $memberships = Get-DfsrMembership -GroupName $group.GroupName -ErrorAction SilentlyContinue
        foreach ($m in $memberships) {
            if ($m.StagingPathQuotaInMB -lt 8192) {
                Write-Status "  Low staging quota: $($m.ComputerName) has $($m.StagingPathQuotaInMB) MB (recommend ≥8192 MB)" "WARN"
            }
        }
    }
} catch {
    Write-Status "Could not enumerate replication groups: $($_.Exception.Message)" "WARN"
}

#endregion

#region --- 3. Recent DFS error events ---

Write-Host ""
Write-Host "=== RECENT DFS EVENTS (Errors + Warnings, last 4 hours) ===" -ForegroundColor Magenta

try {
    $cutoff = (Get-Date).AddHours(-4)
    $events = Get-WinEvent -LogName "DFS Replication" -ErrorAction Stop |
        Where-Object { $_.TimeCreated -ge $cutoff -and $_.Level -le 3 }

    if ($events.Count -eq 0) {
        Write-Status "No errors or warnings in DFS Replication log in the last 4 hours" "OK"
    } else {
        Write-Status "$($events.Count) error/warning events found:" "WARN"
        $events | Select-Object TimeCreated, Id, LevelDisplayName, Message |
            Format-Table -Wrap -AutoSize
    }

    $events | Export-Csv "$ExportPath\dfs-events.csv" -NoTypeInformation
} catch {
    Write-Status "Could not read DFS Replication event log: $($_.Exception.Message)" "WARN"
}

#endregion

#region --- 4. Export and summary ---

$results | Export-Csv "$ExportPath\dfs-health-results.csv" -NoTypeInformation

$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count
$okCount    = ($results | Where-Object { $_.Status -eq "OK" }).Count

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Magenta
Write-Status "OK:      $okCount" "OK"
Write-Status "WARNING: $warnCount" "WARN"
Write-Status "ERROR:   $errorCount" "ERROR"
Write-Status "Full report: $ExportPath\dfs-health-results.csv" "INFO"

if ($errorCount -gt 0) {
    Write-Host ""
    Write-Host "ERRORS FOUND — action required:" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq "ERROR" } | Format-Table -AutoSize
}

#endregion
