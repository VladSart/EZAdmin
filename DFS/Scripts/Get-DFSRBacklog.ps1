<#
.SYNOPSIS
    Reports DFS Replication backlog between all replication group members.

.DESCRIPTION
    Queries all DFSR replication groups and connections in the domain, then calls
    Get-DfsrBacklog for each sending/receiving member pair. Outputs a summary table
    and exports detailed results to CSV.

    Does NOT modify any replication configuration. Safe to run in production.

    Covers:
    - All replication groups (including SYSVOL if domain-joined)
    - All replicated folders within each group
    - Backlog count per connection (bidirectional)
    - Highlights connections where backlog exceeds a configurable threshold
    - Flags members that are unreachable

    Does NOT cover:
    - DFS Namespace health (see Test-DFSHealth.ps1)
    - Replication conflict resolution
    - Staging quota analysis

.PARAMETER ReplicationGroupName
    Optional. Filter to a specific replication group. If omitted, all groups are checked.

.PARAMETER WarnThreshold
    Backlog count that triggers a WARN status. Default: 100.

.PARAMETER CriticalThreshold
    Backlog count that triggers an ERROR status. Default: 500.

.PARAMETER ExportPath
    Path for the CSV export. Default: .\DFSRBacklog-<timestamp>.csv

.PARAMETER MaxBacklogSample
    Maximum backlog file entries to retrieve per connection (passed to Get-DfsrBacklog).
    Default: 100. Increase for deeper investigation (can be slow on large backlogs).

.EXAMPLE
    .\Get-DFSRBacklog.ps1
    Checks all replication groups and exports results.

.EXAMPLE
    .\Get-DFSRBacklog.ps1 -ReplicationGroupName "Finance-Data" -WarnThreshold 50

.NOTES
    Requires: DFSR PowerShell module (RSAT-DFS-Mgmt-Con feature)
    Run-as: Domain user with read access to DFSR WMI on all members
    Safe: Yes — read-only queries only
    Tested on: Windows Server 2019/2022 with DFSR
#>

[CmdletBinding()]
param(
    [string]$ReplicationGroupName,
    [int]$WarnThreshold    = 100,
    [int]$CriticalThreshold = 500,
    [string]$ExportPath,
    [int]$MaxBacklogSample  = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"  # Don't stop on unreachable members

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
Write-Status "Starting DFSR backlog check — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# Verify DFSR module
if (-not (Get-Module -ListAvailable -Name DFSR)) {
    Write-Status "DFSR module not found. Install RSAT: Install-WindowsFeature RSAT-DFS-Mgmt-Con" "ERROR"
    exit 1
}
Import-Module DFSR -ErrorAction Stop

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\DFSRBacklog-$timestamp.csv"
}
#endregion

#region ─── Discover replication groups ───────────────────────────────────────
Write-Status "Discovering replication groups..."

try {
    $getGroupParams = @{}
    if ($ReplicationGroupName) { $getGroupParams['GroupName'] = $ReplicationGroupName }
    $groups = Get-DfsReplicationGroup @getGroupParams -ErrorAction Stop
} catch {
    Write-Status "Failed to enumerate replication groups: $_" "ERROR"
    exit 1
}

if (-not $groups) {
    Write-Status "No replication groups found (filter: '$ReplicationGroupName')" "WARN"
    exit 0
}

Write-Status "Found $($groups.Count) replication group(s)" "OK"
#endregion

#region ─── Check backlog per group / folder / connection ─────────────────────
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($group in $groups) {
    Write-Status "Processing group: $($group.GroupName)"

    # Get replicated folders
    try {
        $folders = Get-DfsReplicatedFolder -GroupName $group.GroupName -ErrorAction Stop
    } catch {
        Write-Status "  Could not get replicated folders for '$($group.GroupName)': $_" "WARN"
        continue
    }

    # Get members
    try {
        $members = Get-DfsrMember -GroupName $group.GroupName -ErrorAction Stop
    } catch {
        Write-Status "  Could not get members for '$($group.GroupName)': $_" "WARN"
        continue
    }

    # Get connections (each connection = one sending member → one receiving member)
    try {
        $connections = Get-DfsrConnection -GroupName $group.GroupName -ErrorAction Stop
    } catch {
        Write-Status "  Could not get connections for '$($group.GroupName)': $_" "WARN"
        continue
    }

    foreach ($folder in $folders) {
        foreach ($conn in $connections) {
            # Skip disabled connections
            if (-not $conn.Enabled) {
                Write-Verbose "  Skipping disabled connection: $($conn.SourceComputerName) → $($conn.DestinationComputerName)"
                continue
            }

            $sendingMember    = $conn.SourceComputerName
            $receivingMember  = $conn.DestinationComputerName

            Write-Verbose "  Checking: $sendingMember → $receivingMember / $($folder.FolderName)"

            $backlogCount = $null
            $errorMsg     = $null
            $statusLabel  = "OK"

            try {
                $backlog = Get-DfsrBacklog `
                    -GroupName             $group.GroupName `
                    -FolderName            $folder.FolderName `
                    -SourceComputerName    $sendingMember `
                    -DestinationComputerName $receivingMember `
                    -Verbose:$false `
                    -ErrorAction Stop | Select-Object -First $MaxBacklogSample

                $backlogCount = ($backlog | Measure-Object).Count

                if ($backlogCount -ge $CriticalThreshold) {
                    $statusLabel = "CRITICAL"
                } elseif ($backlogCount -ge $WarnThreshold) {
                    $statusLabel = "WARN"
                }

            } catch {
                $errorMsg    = $_.Exception.Message
                $statusLabel = "UNREACHABLE"
            }

            $row = [PSCustomObject]@{
                Group            = $group.GroupName
                ReplicatedFolder = $folder.FolderName
                SendingMember    = $sendingMember
                ReceivingMember  = $receivingMember
                BacklogCount     = if ($null -ne $backlogCount) { $backlogCount } else { "N/A" }
                Status           = $statusLabel
                Note             = if ($backlogCount -ge $MaxBacklogSample) { "Capped at $MaxBacklogSample — actual backlog may be larger" } elseif ($errorMsg) { $errorMsg } else { "" }
                CheckedAt        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }

            $results.Add($row)

            $colour = switch ($statusLabel) {
                "OK"          { "Green"  }
                "WARN"        { "Yellow" }
                "CRITICAL"    { "Red"    }
                "UNREACHABLE" { "Magenta"}
                default       { "White"  }
            }
            Write-Host "  [$statusLabel] $sendingMember → $receivingMember | $($folder.FolderName) | Backlog: $(if ($null -ne $backlogCount) { $backlogCount } else { 'N/A' })" -ForegroundColor $colour
        }
    }
}
#endregion

#region ─── Summary ───────────────────────────────────────────────────────────
Write-Host "`n─── Backlog Summary ───────────────────────────────" -ForegroundColor Cyan

$statCounts = $results | Group-Object Status
foreach ($s in $statCounts) {
    $colour = switch ($s.Name) {
        "OK"          { "Green"  }
        "WARN"        { "Yellow" }
        "CRITICAL"    { "Red"    }
        "UNREACHABLE" { "Magenta"}
        default       { "White"  }
    }
    Write-Host "  $($s.Name.PadRight(12)) : $($s.Count)" -ForegroundColor $colour
}

$problemRows = $results | Where-Object { $_.Status -in @("WARN","CRITICAL","UNREACHABLE") }
if ($problemRows) {
    Write-Host "`n─── Problem Connections ───────────────────────────" -ForegroundColor Yellow
    $problemRows | Format-Table Group, ReplicatedFolder, SendingMember, ReceivingMember, BacklogCount, Status, Note -AutoSize
}

Write-Host ""
#endregion

#region ─── Export ────────────────────────────────────────────────────────────
if ($results.Count -gt 0) {
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "Results exported → $ExportPath" "OK"
} else {
    Write-Status "No results collected — nothing exported." "WARN"
}

Write-Status "DFSR backlog check complete — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
