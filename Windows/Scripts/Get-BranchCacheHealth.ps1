<#
.SYNOPSIS
    Audits BranchCache configuration and dependencies on the local machine — service mode,
    GPO policy alignment, SMB share hash publication, firewall rules, hosted-cache reachability,
    the Offline Files (CscService) dependency, and content-information version context.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/BranchCache-B.md and BranchCache-A.md.
    Runs in one pass everything the runbooks' triage and diagnosis steps ask for:
    - Current BranchCache service state and configured mode (Distributed/Hosted/Disabled)
    - GPO-managed BranchCache policy presence (registry-based, best-effort)
    - SMB share CachingMode inventory (if run on a file server) — flags shares NOT set for
      BranchCache hash publication, the most common "nothing caches" root cause
    - Firewall rule state for the BranchCache display group
    - Offline Files (CscService) state — the undocumented hard dependency for SMB caching
    - OS version/build (for V1 vs. V2 content-information context when comparing against a peer)
    - Optional hosted-cache-server reachability test

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's BranchCache-B.md Fix 1-7 / BranchCache-A.md Playbooks 1-4)
    - Delivery Optimization's own peer-caching health — see Get-DeliveryOptimizationDiagnostics.ps1
    - Remote/fleet-wide auditing — this is a single-machine diagnostic; BranchCache has no
      Graph/Intune API surface for centralized per-device state at scale

.PARAMETER HostedCacheServer
    Optional hosted cache server name/FQDN to test reachability against, if this client is
    (or should be) configured for hosted mode. If omitted, only local configuration is audited.

.PARAMETER ExportPath
    Path for CSV export. Default: .\BranchCacheHealth-<timestamp>.csv

.EXAMPLE
    .\Get-BranchCacheHealth.ps1
    Audits local BranchCache configuration only.

.EXAMPLE
    .\Get-BranchCacheHealth.ps1 -HostedCacheServer hostedcache01.contoso.com
    Audits local configuration AND tests reachability to the named hosted cache server.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended (registry policy reads and some service queries need elevation)
    Safe: Fully read-only. No mode changes, no firewall/service state changes, no cache flush.
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2016+
#>

[CmdletBinding()]
param(
    [string]$HostedCacheServer,

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
Write-Status "Get-BranchCacheHealth — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\BranchCacheHealth-$timestamp.csv"
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
#endregion

#region ─── 1. BranchCache service status and mode ─────────────────────────────
try {
    $statusRaw = netsh branchcache show status all 2>&1
    $statusText = $statusRaw -join "`n"

    if ($statusText -match 'Local Caching is disabled') {
        Add-Result "BranchCacheService" "ERROR" "Local Caching is disabled — BranchCache has never been turned on for this client"
    } elseif ($statusText -match 'Distributed Caching') {
        Add-Result "BranchCacheService" "OK" "Enabled — Distributed Cache mode"
    } elseif ($statusText -match 'Hosted Caching') {
        Add-Result "BranchCacheService" "OK" "Enabled — Hosted Cache mode"
    } else {
        Add-Result "BranchCacheService" "WARN" "Enabled but mode could not be parsed from netsh output — review manually"
    }
} catch {
    Add-Result "BranchCacheService" "ERROR" "Could not query BranchCache status via netsh: $_"
}
#endregion

#region ─── 2. GPO-managed BranchCache policy (registry-based, best-effort) ────
try {
    $gpoPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\BranchCache"
    if (Test-Path $gpoPath) {
        $gpoProps = Get-ItemProperty -Path $gpoPath -ErrorAction SilentlyContinue
        Add-Result "GPOManagedBranchCache" "INFO" "GPO policy key present — local netsh changes may be overridden on next refresh. Values: $($gpoProps | Out-String -Width 200)".Trim()
    } else {
        Add-Result "GPOManagedBranchCache" "INFO" "No GPO BranchCache policy registry key detected — local netsh configuration is authoritative on this box"
    }
} catch {
    Add-Result "GPOManagedBranchCache" "INFO" "Could not check GPO policy registry key: $_"
}
#endregion

#region ─── 3. Firewall rules ───────────────────────────────────────────────────
try {
    $rules = Get-NetFirewallRule -DisplayGroup "BranchCache*" -ErrorAction Stop
    if ($rules) {
        $disabledRules = $rules | Where-Object { $_.Enabled -ne 'True' }
        if ($disabledRules) {
            $names = ($disabledRules | Select-Object -ExpandProperty DisplayName) -join '; '
            Add-Result "Firewall" "WARN" "Disabled rule(s): $names"
        } else {
            Add-Result "Firewall" "OK" "$($rules.Count) BranchCache firewall rule(s) present, all enabled"
        }
    } else {
        Add-Result "Firewall" "ERROR" "No BranchCache firewall rules found — BranchCache was likely never enabled via the normal path"
    }
} catch {
    Add-Result "Firewall" "WARN" "Could not query BranchCache firewall rules: $_"
}
#endregion

#region ─── 4. SMB share hash publication (file server scenario) ───────────────
try {
    $shares = Get-SmbShare -ErrorAction Stop | Where-Object { $_.Name -notmatch '\$$' -and $_.Name -ne 'IPC$' }
    if ($shares) {
        $nonCached = $shares | Where-Object { $_.CachingMode -notin @('BranchCache') }
        if ($nonCached) {
            $shareList = ($nonCached | ForEach-Object { "$($_.Name)=$($_.CachingMode)" }) -join '; '
            Add-Result "SMBShareCaching" "WARN" "$($nonCached.Count) share(s) NOT set for BranchCache hash publication: $shareList"
        } else {
            Add-Result "SMBShareCaching" "OK" "All $($shares.Count) non-administrative share(s) set to BranchCache caching mode"
        }
        $shares | Select-Object Name, CachingMode, Path | Export-Csv -Path "$($ExportPath -replace '\.csv$','')-Shares.csv" -NoTypeInformation
    } else {
        Add-Result "SMBShareCaching" "INFO" "No non-administrative SMB shares found on this machine — not a file server, or no shares configured"
    }
} catch {
    Add-Result "SMBShareCaching" "INFO" "Could not enumerate SMB shares (expected on a client machine): $_"
}
#endregion

#region ─── 5. BranchCache role/feature inventory (server scenario) ────────────
try {
    $features = Get-WindowsFeature -Name *BranchCache* -ErrorAction Stop
    if ($features) {
        $installed = $features | Where-Object { $_.InstallState -eq 'Installed' }
        if ($installed) {
            $featList = ($installed | Select-Object -ExpandProperty Name) -join ', '
            Add-Result "BranchCacheFeatures" "OK" "Installed: $featList"
        } else {
            Add-Result "BranchCacheFeatures" "INFO" "No BranchCache-related Windows Server roles/features installed on this machine (expected on a client OS)"
        }
    }
} catch {
    Add-Result "BranchCacheFeatures" "INFO" "Get-WindowsFeature not available (expected on a client OS, not Windows Server): $_"
}
#endregion

#region ─── 6. Offline Files (CscService) dependency ───────────────────────────
try {
    $csc = Get-Service -Name CscService -ErrorAction Stop
    if ($csc.Status -eq 'Running') {
        Add-Result "OfflineFilesDependency" "OK" "CscService running — BranchCache SMB caching dependency satisfied"
    } else {
        Add-Result "OfflineFilesDependency" "ERROR" "CscService status: $($csc.Status) — BranchCache SMB caching will NOT function correctly until this is running (undocumented hard dependency)"
    }
} catch {
    Add-Result "OfflineFilesDependency" "WARN" "Could not query CscService: $_"
}
#endregion

#region ─── 7. OS version / content-information version context ───────────────
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $isV1Era = $os.Caption -match 'Windows 7|Server 2008 R2'
    $ciVersion = if ($isV1Era) { "V1 (fixed-size segments)" } else { "V2 (variable-size segments)" }
    Add-Result "ContentInfoVersion" "INFO" "$($os.Caption) → content-information $ciVersion. In distributed mode, this machine can only share a cache with peers on the SAME content-information version."
} catch {
    Add-Result "ContentInfoVersion" "INFO" "Could not determine OS version: $_"
}
#endregion

#region ─── 8. Local cache size/utilization ─────────────────────────────────────
try {
    $statusRaw = netsh branchcache show status all 2>&1
    $statusText = $statusRaw -join "`n"
    if ($statusText -match 'Current active cache size.*?:\s*(.+)') {
        Add-Result "LocalCacheSize" "INFO" "Current active cache size: $($Matches[1].Trim())"
    } else {
        Add-Result "LocalCacheSize" "INFO" "Could not parse cache size from netsh output — review 'netsh branchcache show status all' manually"
    }
} catch {
    Add-Result "LocalCacheSize" "INFO" "Could not read local cache size: $_"
}
#endregion

#region ─── 9. Optional hosted cache server reachability ───────────────────────
if ($HostedCacheServer) {
    try {
        $portTest = Test-NetConnection -ComputerName $HostedCacheServer -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
        if ($portTest.TcpTestSucceeded) {
            Add-Result "HostedCacheReachable-$HostedCacheServer" "OK" "TCP 443 reachable"
        } else {
            Add-Result "HostedCacheReachable-$HostedCacheServer" "ERROR" "TCP 443 NOT reachable — check firewall/routing to the hosted cache server"
        }
    } catch {
        Add-Result "HostedCacheReachable-$HostedCacheServer" "ERROR" "Reachability test failed: $_"
    }
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── BranchCache Health Summary ─────────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: BranchCache configuration looks healthy on this device." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see BranchCache-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
