<#
.SYNOPSIS
    Collects Windows Delivery Optimization configuration, peering stats, and cache health for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/DeliveryOptimization-B.md and DeliveryOptimization-A.md.
    Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
    - DoSvc service state
    - Effective DODownloadMode, DOGroupIdSource/DOGroupId, DOCacheHost, and cache size policy values
    - Recent per-file peer/cache/HTTP transfer stats (BytesFromPeers, BytesFromCacheServer, BytesFromHttp)
    - Delivery Optimization firewall rule state
    - Optional peer port 7680 reachability test against a specified peer
    - Optional Connected Cache endpoint reachability test (port 443) if DOCacheHost is configured

    Produces a console summary with pass/fail per check and exports full detail to CSV, plus a
    companion transfers CSV, so output can be pasted directly into the runbook's Escalation Evidence
    template. Flags the most common misdiagnosis pattern directly: zero peer bytes site-wide despite
    a "correct-looking" DODownloadMode, which usually means a port 7680 block, not a config problem.

    Does NOT cover:
    - Deploying or configuring Microsoft Connected Cache itself (Fix 6 / Playbook 2 in the runbook — infrastructure change, not a script action)
    - Changing DODownloadMode/GroupId/cache policy (that's Fix 2-5 in DeliveryOptimization-B.md — this script only detects)
    - WSUS/BranchCache — explicitly out of scope per the Mode A runbook's Scope & Assumptions

.PARAMETER PeerToTest
    IP or hostname of another device at the same site to test peer port 7680 reachability against.
    Optional — if omitted, peer reachability is not tested.

.PARAMETER CacheHostOverride
    Optional hostname/IP to test Connected Cache reachability against, if you want to test a candidate
    endpoint that isn't yet set in DOCacheHost policy. If omitted, the script uses the configured DOCacheHost value.

.PARAMETER ExportPath
    Path for CSV export. Default: .\DeliveryOptimizationDiagnostics-<timestamp>.csv
    A companion file with suffix ".transfers.csv" is written alongside it.

.EXAMPLE
    .\Get-DeliveryOptimizationDiagnostics.ps1
    Runs the full sweep without peer/cache-host reachability testing.

.EXAMPLE
    .\Get-DeliveryOptimizationDiagnostics.ps1 -PeerToTest 10.10.5.42
    Also tests port 7680 reachability against a known peer at the same site.

.NOTES
    Requires: Windows PowerShell 5.1+, Delivery Optimization cmdlets (built into Windows 10 1607+/Windows 11)
    Run-as: Standard user for most checks; Administrator recommended for full registry policy visibility
    Safe: Fully read-only. No policy values are changed, no service restarts performed.
    Tested on: Windows 10 21H2+, Windows 11, Intune-managed and GPO-managed.
#>

[CmdletBinding()]
param(
    [string]$PeerToTest,

    [string]$CacheHostOverride,

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

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Get-DeliveryOptimizationDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\DeliveryOptimizationDiagnostics-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "$Check — $Detail" $Status
}

$configPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
$policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
#endregion

#region ─── 1. DoSvc service state ──────────────────────────────────────────────
try {
    $doSvc = Get-Service -Name DoSvc -ErrorAction Stop
    if ($doSvc.Status -eq 'Running') {
        Add-Result "DoSvc" "OK" "Running (StartType: $($doSvc.StartType))"
    } else {
        Add-Result "DoSvc" "ERROR" "Status: $($doSvc.Status) — no peering or Connected Cache sourcing will occur until the service is running"
    }
} catch {
    Add-Result "DoSvc" "ERROR" "Could not query DoSvc: $_"
}
#endregion

#region ─── 2. Effective policy configuration ───────────────────────────────────
$downloadMode = $null
try {
    $cfg = Get-ItemProperty $configPath -ErrorAction Stop
    $downloadMode = $cfg.DODownloadMode
    $modeLabel = switch ($downloadMode) {
        0       { "HTTP Only (peering disabled)" }
        1       { "LAN (subnet-scoped peering)" }
        2       { "Group (Group ID-scoped peering)" }
        3       { "Internet (peers with unknown external clients)" }
        99      { "Simple/Bypass" }
        100     { "Simple/Bypass" }
        default { "Unknown/unset ($downloadMode)" }
    }

    if ($null -eq $downloadMode) {
        Add-Result "DODownloadMode" "WARN" "Value not present — device is using OS default (commonly Internet mode)"
    } elseif ($downloadMode -eq 0) {
        Add-Result "DODownloadMode" "WARN" "$modeLabel — confirm this is intentional; no bandwidth savings possible in this mode"
    } elseif ($downloadMode -eq 3) {
        Add-Result "DODownloadMode" "WARN" "$modeLabel — rarely appropriate for a managed enterprise fleet, review for compliance/security posture"
    } else {
        Add-Result "DODownloadMode" "OK" "$modeLabel"
    }

    if ($downloadMode -eq 2) {
        $groupIdSource = $cfg.DOGroupIdSource
        $groupId       = $cfg.DOGroupId
        if ([string]::IsNullOrWhiteSpace($groupId)) {
            Add-Result "DOGroupId" "ERROR" "Group mode set but no GroupId present — device is isolated into its own single-device group"
        } else {
            Add-Result "DOGroupId" "OK" "GroupIdSource=$groupIdSource, GroupId=$groupId — compare this value across other devices at the same site to confirm consistency"
        }
    }

    $cacheHost = $cfg.DOCacheHost
    if ($cacheHost) {
        Add-Result "DOCacheHost" "OK" "Connected Cache configured: $cacheHost"
    } else {
        Add-Result "DOCacheHost" "INFO" "No Connected Cache endpoint configured — first download of any content at a site will always traverse the WAN regardless of peering health"
    }

    $maxCache = $cfg.DOMaxCacheSize
    if ($null -eq $maxCache) {
        Add-Result "DOMaxCacheSize" "WARN" "No cache size cap set — on small-SSD devices this can contribute to low-disk-space issues around feature update rollouts"
    } else {
        Add-Result "DOMaxCacheSize" "OK" "Capped at $maxCache% of disk"
    }
} catch {
    Add-Result "DODownloadMode" "WARN" "Could not read effective DO config from $configPath : $_"
}
#endregion

#region ─── 3. Recent transfer stats (peer/cache/HTTP breakdown) ───────────────
$transferRows = @()
try {
    $transferRows = Get-DeliveryOptimizationStatus -Verbose -ErrorAction Stop |
        Select-Object FileId, Status, PercentPeerCaching, BytesFromPeers, BytesFromCacheServer, BytesFromHttp

    if ($transferRows -and $transferRows.Count -gt 0) {
        $totalPeerBytes  = ($transferRows | Measure-Object -Property BytesFromPeers -Sum).Sum
        $totalCacheBytes = ($transferRows | Measure-Object -Property BytesFromCacheServer -Sum).Sum
        $totalHttpBytes  = ($transferRows | Measure-Object -Property BytesFromHttp -Sum).Sum

        Add-Result "TransferHistory" "INFO" "$($transferRows.Count) tracked file(s) — PeerBytes=$totalPeerBytes, CacheServerBytes=$totalCacheBytes, HttpBytes=$totalHttpBytes"

        if ($totalPeerBytes -eq 0 -and $downloadMode -in 1,2 -and $transferRows.Count -gt 0) {
            Add-Result "PeeringActivity" "WARN" "DODownloadMode indicates peering should be active but BytesFromPeers is 0 across all tracked files — check port 7680 reachability before assuming a config problem"
        } elseif ($totalPeerBytes -gt 0) {
            Add-Result "PeeringActivity" "OK" "Peer transfers observed — peering is functioning"
        } else {
            Add-Result "PeeringActivity" "INFO" "No peer transfer data yet — normal if no recent large downloads occurred"
        }
    } else {
        Add-Result "TransferHistory" "INFO" "No transfer history available yet (no recent DO-eligible downloads on this device)"
    }
} catch {
    Add-Result "TransferHistory" "WARN" "Could not query Get-DeliveryOptimizationStatus: $_"
}
#endregion

#region ─── 4. Firewall rule state for peer traffic (port 7680) ────────────────
try {
    $fwRules = Get-NetFirewallRule -DisplayName "*Delivery Optimization*" -ErrorAction Stop
    $enabledRules = $fwRules | Where-Object { $_.Enabled -eq 'True' }
    if ($enabledRules -and $enabledRules.Count -gt 0) {
        Add-Result "DOFirewallRules" "OK" "$($enabledRules.Count) of $($fwRules.Count) built-in DO firewall rule(s) enabled"
    } else {
        Add-Result "DOFirewallRules" "WARN" "No enabled DO firewall rules found — peer traffic on port 7680 may be blocked"
    }
} catch {
    Add-Result "DOFirewallRules" "WARN" "Could not query DO firewall rules: $_"
}
#endregion

#region ─── 5. Optional peer port reachability test ────────────────────────────
if ($PeerToTest) {
    try {
        $peerTest = Test-NetConnection -ComputerName $PeerToTest -Port 7680 -WarningAction SilentlyContinue -ErrorAction Stop
        if ($peerTest.TcpTestSucceeded) {
            Add-Result "PeerPortReachability" "OK" "Port 7680 reachable to $PeerToTest"
        } else {
            Add-Result "PeerPortReachability" "ERROR" "Port 7680 NOT reachable to $PeerToTest — likely cause of zero peer transfers; check site firewall/switch ACLs"
        }
    } catch {
        Add-Result "PeerPortReachability" "WARN" "Could not test reachability to $PeerToTest : $_"
    }
} else {
    Add-Result "PeerPortReachability" "INFO" "No -PeerToTest supplied — skipped. Supply a peer IP/hostname at the same site to validate peering network path."
}
#endregion

#region ─── 6. Optional Connected Cache reachability test ──────────────────────
$cacheHostToTest = if ($CacheHostOverride) { $CacheHostOverride } else { $cacheHost }
if ($cacheHostToTest) {
    try {
        $cacheTest = Test-NetConnection -ComputerName $cacheHostToTest -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
        if ($cacheTest.TcpTestSucceeded) {
            Add-Result "ConnectedCacheReachability" "OK" "Port 443 reachable to Connected Cache endpoint $cacheHostToTest"
        } else {
            Add-Result "ConnectedCacheReachability" "ERROR" "Port 443 NOT reachable to $cacheHostToTest — MCC endpoint may be down or mis-registered"
        }
    } catch {
        Add-Result "ConnectedCacheReachability" "WARN" "Could not test reachability to $cacheHostToTest : $_"
    }
} else {
    Add-Result "ConnectedCacheReachability" "INFO" "No Connected Cache endpoint configured or supplied — skipped"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Delivery Optimization Diagnostics Summary ──────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Delivery Optimization config and peering look healthy on this device." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — cross-reference against DeliveryOptimization-B.md Fix 1-6." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"

if ($transferRows -and $transferRows.Count -gt 0) {
    $transfersPath = "$ExportPath.transfers.csv"
    $transferRows | Export-Csv -Path $transfersPath -NoTypeInformation -Encoding UTF8
    Write-Status "Transfer detail exported → $transfersPath" "OK"
}

Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
