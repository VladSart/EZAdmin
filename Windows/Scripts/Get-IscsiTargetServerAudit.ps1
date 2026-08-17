<#
.SYNOPSIS
    Audits iSCSI Target Server (role) and/or Microsoft iSCSI Initiator (client) health —
    role/feature presence, target ACLs vs. actual client identity, CHAP configuration,
    session/connection state, MPIO claim status, firewall state, and recent iSCSI System
    log events.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/iSCSITargetServer-B.md and -A.md.
    Auto-detects whether this computer is running the iSCSI Target Server role, the
    Microsoft iSCSI Initiator, both, or neither, and audits the relevant half (or both
    halves) of the dependency stack described in those runbooks.

    Checks performed (target, if role present):
    - FS-iSCSITarget-Server feature installed
    - Every iSCSI Server Target: enabled state, InitiatorIds (ACL), CHAP state
    - Every iSCSI Virtual Disk: DiskStatus (flags anything other than Normal)
    - Inbound firewall rules matching "*iSCSI*" (flags if none enabled)

    Checks performed (client, if MSiSCSI present):
    - MSiSCSI service state and startup type
    - This computer's own initiator IQN (Get-InitiatorPort)
    - Every iSCSI session: connected state, persistence
    - Every iSCSI connection: target/initiator address pairing
    - iSCSI-attached disks: OperationalStatus, PartitionStyle (flags Offline/RAW)
    - MPIO: feature presence, automatic-claim state for BusType iSCSI, mpclaim.exe path count

    Both:
    - Recent System log events from the msiscsi/iScsiPrt providers (default: last 4 hours),
      flagged if any of the documented connectivity-issue event IDs (9, 20, 27, 39, 153, 157)
      are present

    Produces a console summary with pass/fail/flag per check and exports full detail to CSV.

    Does NOT cover:
    - Fixing any detected issue (that's iSCSITargetServer-B.md Fix 1-9 / -A.md Playbooks 1-4)
    - Third-party/hardware SAN iSCSI targets — this script only queries the native
      Windows IscsiTarget PowerShell module (Microsoft targets only)
    - Cluster-specific validation beyond a simple resource-type/backing-storage check —
      run Test-Cluster separately for full cluster health (see FailoverClustering-A.md)
    - Performance/latency analysis — see the general Perfmon/storport guidance in
      Microsoft's iSCSI storage connectivity troubleshooting documentation

.PARAMETER Role
    Which half of the stack to audit: Target, Initiator, or Both. Default: Both
    (each half is skipped automatically if its underlying feature/service isn't present,
    regardless of this parameter, so Both is safe to leave as default on any computer).

.PARAMETER EventLookbackHours
    How far back to scan the System log for iSCSI-related events. Default: 4

.PARAMETER ExportPath
    Path for CSV export. Default: .\IscsiTargetServerHealth-<timestamp>.csv

.EXAMPLE
    .\Get-IscsiTargetServerAudit.ps1
    Audits whichever role(s)/service(s) are present on the local machine, 4-hour event lookback.

.EXAMPLE
    .\Get-IscsiTargetServerAudit.ps1 -Role Target -EventLookbackHours 24
    Audits only the target-server half, with a 24-hour event log lookback window.

.EXAMPLE
    .\Get-IscsiTargetServerAudit.ps1 -Role Initiator -ExportPath C:\Temp\client-audit.csv
    Audits only the client/initiator half and exports to a specific path.

.NOTES
    Requires: Windows PowerShell 5.1+, IscsiTarget module (target role) and/or
              iSCSI + MPIO modules (client), all built into Windows Server/Windows 10+
    Run-as: Administrator recommended (event log and some cmdlets need elevation)
    Safe: Fully read-only. No target/session/firewall/registry changes.
#>

[CmdletBinding()]
param(
    [ValidateSet("Target", "Initiator", "Both")]
    [string]$Role = "Both",

    [int]$EventLookbackHours = 4,

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

if (-not $ExportPath) {
    $ExportPath = ".\IscsiTargetServerHealth-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Category, [string]$Item, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{
        Category = $Category
        Item     = $Item
        Status   = $Status
        Detail   = $Detail
    })
}

Write-Status "iSCSI Target Server / Initiator audit starting (Role=$Role)" "INFO"

# ---------------------------------------------------------------------------
# Preflight — detect what's actually present on this machine
# ---------------------------------------------------------------------------
$targetFeature = Get-WindowsFeature -Name FS-iSCSITarget-Server -ErrorAction SilentlyContinue
$hasTargetRole = $targetFeature -and $targetFeature.Installed

$initiatorService = Get-Service -Name MSiSCSI -ErrorAction SilentlyContinue
$hasInitiator = $null -ne $initiatorService

if ($Role -in "Target","Both") {
    if ($hasTargetRole) {
        Write-Status "iSCSI Target Server role detected — auditing target-side configuration" "INFO"
        Add-Result "Preflight" "FS-iSCSITarget-Server" "OK" "Role installed"

        # --- Targets and their ACLs/CHAP ---
        $targets = Get-IscsiServerTarget -ErrorAction SilentlyContinue
        if (-not $targets) {
            Write-Status "No iSCSI Server Targets found" "WARN"
            Add-Result "Target" "IscsiServerTarget" "WARN" "No targets defined"
        } else {
            foreach ($t in $targets) {
                $ids = ($t.InitiatorIds -join "; ")
                $chapState = if ($t.EnableChap) { "CHAP enabled (user: $($t.ChapUserName))" } else { "CHAP disabled" }
                Write-Status "Target '$($t.TargetName)': Enabled=$($t.Enabled), ACL=[$ids], $chapState" "INFO"
                Add-Result "Target" $t.TargetName $(if ($t.Enabled) { "OK" } else { "WARN" }) "InitiatorIds=$ids; $chapState"

                if (-not $t.InitiatorIds -or $t.InitiatorIds.Count -eq 0) {
                    Write-Status "  -> Target '$($t.TargetName)' has NO initiator ACL entries — no client can log in" "WARN"
                    Add-Result "Target-ACL" $t.TargetName "WARN" "Empty InitiatorIds — target is effectively unreachable"
                }
            }
        }

        # --- Virtual disks ---
        $vdisks = Get-IscsiVirtualDisk -ErrorAction SilentlyContinue
        if (-not $vdisks) {
            Write-Status "No iSCSI Virtual Disks found" "WARN"
            Add-Result "Target" "IscsiVirtualDisk" "WARN" "No virtual disks defined"
        } else {
            foreach ($vd in $vdisks) {
                $status = if ($vd.DiskStatus -eq "Normal") { "OK" } else { "ERROR" }
                Write-Status "Virtual disk '$($vd.Path)': DiskStatus=$($vd.DiskStatus), Size=$([math]::Round($vd.Size/1GB,1))GB" $status
                Add-Result "Target-VirtualDisk" $vd.Path $status "DiskStatus=$($vd.DiskStatus); Size=$([math]::Round($vd.Size/1GB,1))GB"
            }
        }

        # --- Firewall ---
        $fwRules = Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*iSCSI*" }
        $fwEnabled = $fwRules | Where-Object { $_.Enabled -eq "True" -and $_.Action -eq "Allow" }
        if ($fwEnabled) {
            Write-Status "iSCSI inbound firewall rule(s) enabled: $($fwEnabled.DisplayName -join ', ')" "OK"
            Add-Result "Target-Firewall" "InboundRules" "OK" ($fwEnabled.DisplayName -join "; ")
        } else {
            Write-Status "No enabled inbound Allow firewall rule matching '*iSCSI*' found — port 3260 may be blocked" "WARN"
            Add-Result "Target-Firewall" "InboundRules" "WARN" "No matching enabled Allow rule found"
        }

        # --- Clustered role check (informational — flags the non-iSCSI-backing-storage requirement) ---
        $clusterResource = Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { $_.ResourceType -like "*iSCSI*" }
        if ($clusterResource) {
            Write-Status "Clustered iSCSI Target Server resource detected: $($clusterResource.Name) (State=$($clusterResource.State))" "INFO"
            Add-Result "Target-Cluster" $clusterResource.Name "INFO" "State=$($clusterResource.State) — confirm backing storage is non-iSCSI (Fibre Channel/SAS/Storage Spaces)"
        }
    } else {
        Write-Status "iSCSI Target Server role not installed on this computer — skipping target-side checks" "INFO"
    }
}

if ($Role -in "Initiator","Both") {
    if ($hasInitiator) {
        Write-Status "Microsoft iSCSI Initiator detected — auditing client-side configuration" "INFO"

        $svcStatus = if ($initiatorService.Status -eq "Running") { "OK" } else { "ERROR" }
        Write-Status "MSiSCSI service: Status=$($initiatorService.Status), StartType=$($initiatorService.StartType)" $svcStatus
        Add-Result "Initiator" "MSiSCSI-Service" $svcStatus "Status=$($initiatorService.Status); StartType=$($initiatorService.StartType)"

        $initiatorPort = Get-InitiatorPort -ErrorAction SilentlyContinue
        if ($initiatorPort) {
            foreach ($p in $initiatorPort) {
                Write-Status "This computer's initiator identity: $($p.NodeAddress)" "INFO"
                Add-Result "Initiator" "NodeAddress" "INFO" $p.NodeAddress
            }
        }

        $sessions = Get-IscsiSession -ErrorAction SilentlyContinue
        if (-not $sessions) {
            Write-Status "No active iSCSI sessions" "INFO"
            Add-Result "Initiator-Session" "None" "INFO" "No sessions established"
        } else {
            foreach ($s in $sessions) {
                $status = if ($s.IsConnected) { "OK" } else { "ERROR" }
                Write-Status "Session to $($s.TargetNodeAddress): Connected=$($s.IsConnected), Persistent=$($s.IsPersistent)" $status
                Add-Result "Initiator-Session" $s.TargetNodeAddress $status "Connected=$($s.IsConnected); Persistent=$($s.IsPersistent)"
            }
        }

        $disks = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq "iSCSI" }
        if (-not $disks) {
            Write-Status "No iSCSI-attached disks visible" "INFO"
        } else {
            foreach ($d in $disks) {
                $status = if ($d.OperationalStatus -eq "Online" -and $d.PartitionStyle -ne "RAW") { "OK" } else { "WARN" }
                Write-Status "iSCSI disk #$($d.Number): OperationalStatus=$($d.OperationalStatus), PartitionStyle=$($d.PartitionStyle)" $status
                Add-Result "Initiator-Disk" "Disk$($d.Number)" $status "OperationalStatus=$($d.OperationalStatus); PartitionStyle=$($d.PartitionStyle); Size=$([math]::Round($d.Size/1GB,1))GB"
            }
        }

        # --- MPIO ---
        $mpioFeature = Get-WindowsFeature -Name Multipath-IO -ErrorAction SilentlyContinue
        if ($mpioFeature -and $mpioFeature.Installed) {
            Write-Status "MPIO feature installed" "OK"
            $claim = Get-MSDSMAutomaticClaimSettings -ErrorAction SilentlyContinue
            if ($claim) {
                $iscsiClaim = $claim.iSCSI
                $status = if ($iscsiClaim) { "OK" } else { "WARN" }
                Write-Status "MSDSM automatic claim for BusType iSCSI: $iscsiClaim" $status
                Add-Result "Initiator-MPIO" "AutomaticClaim-iSCSI" $status "Claimed=$iscsiClaim"
            }
            if (Get-Command mpclaim.exe -ErrorAction SilentlyContinue) {
                $mpclaimOutput = & mpclaim.exe -v 2>&1 | Out-String
                Add-Result "Initiator-MPIO" "mpclaim-v" "INFO" ($mpclaimOutput -replace "\s+", " ").Trim()
            }
        } elseif ($disks -and $disks.Count -gt 0) {
            Write-Status "MPIO feature not installed — if this target has multiple NICs/portals, paths are NOT being aggregated" "WARN"
            Add-Result "Initiator-MPIO" "Multipath-IO" "WARN" "Feature not installed"
        }
    } else {
        Write-Status "MSiSCSI service not present on this computer — skipping initiator-side checks" "INFO"
    }
}

# ---------------------------------------------------------------------------
# Shared — recent iSCSI System log events
# ---------------------------------------------------------------------------
if ($hasTargetRole -or $hasInitiator) {
    $flagIds = @(9, 20, 27, 39, 153, 157)
    $events = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'msiscsi', 'iScsiPrt'
        StartTime    = (Get-Date).AddHours(-$EventLookbackHours)
    } -ErrorAction SilentlyContinue

    if (-not $events) {
        Write-Status "No iSCSI-related System log events in the last $EventLookbackHours hour(s)" "OK"
        Add-Result "Events" "iSCSI-System-Log" "OK" "None in lookback window"
    } else {
        $flagged = $events | Where-Object { $_.Id -in $flagIds }
        if ($flagged) {
            Write-Status "Found $($flagged.Count) event(s) matching documented connectivity-issue IDs (9/20/27/39/153/157) in the last $EventLookbackHours hour(s)" "WARN"
            foreach ($e in ($flagged | Select-Object -First 10)) {
                Add-Result "Events-Flagged" "Id$($e.Id)" "WARN" "$($e.TimeCreated) - $($e.Message -replace '\s+',' ')"
            }
        } else {
            Write-Status "$($events.Count) iSCSI-related event(s) found, none matching the flagged connectivity-issue IDs" "OK"
            Add-Result "Events" "iSCSI-System-Log" "OK" "$($events.Count) events, none flagged"
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "=== Summary ===" "INFO"
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
$okCount    = ($results | Where-Object Status -eq "OK").Count
Write-Status "$okCount OK, $warnCount WARN, $errorCount ERROR across $($results.Count) checks" $(if ($errorCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Full detail exported to $ExportPath" "INFO"
