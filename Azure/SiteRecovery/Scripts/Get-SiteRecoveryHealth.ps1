<#
.SYNOPSIS
    Read-only fleet-wide health audit for Azure Site Recovery (Azure-to-Azure) protected items.

.DESCRIPTION
    Connects to a Recovery Services vault, sets the ASR vault context, and walks every
    fabric/protection-container pair to report replication health, protection state, RPO,
    last test failover status, and recent job failures for every protected item.

    Flags, per item:
      - ReplicationHealth not Normal/Healthy
      - RPOInSeconds above -RPOWarningThresholdSeconds (default 1500s / 25 min)
      - No completed test failover, or a test failover older than -TestFailoverStaleDays (default 180)
      - Any Failed job for that item within the last 3 days
      - Only crash-consistent recovery points present in the most recent 5 (app-consistency may be silently broken)

    Does not modify replication state, trigger failover, reprotect, or disable protection —
    read-only throughout. Requires an authenticated Az PowerShell session (Connect-AzAccount)
    with Az.RecoveryServices installed.

.PARAMETER VaultResourceGroupName
    Resource group containing the Recovery Services vault(s) to audit.

.PARAMETER VaultName
    Name of a specific Recovery Services vault to audit. If omitted, all vaults in the
    resource group are audited.

.PARAMETER RPOWarningThresholdSeconds
    RPO value, in seconds, above which an item is flagged even if ReplicationHealth still
    shows Normal/Healthy. Default 1500 (25 minutes).

.PARAMETER TestFailoverStaleDays
    Number of days since the last completed test failover before an item is flagged as
    stale/never-tested. Default 180 (Microsoft's own recommended 6-month cadence).

.PARAMETER OutputPath
    Folder to write the CSV report to. Default is the current directory.

.EXAMPLE
    .\Get-SiteRecoveryHealth.ps1 -VaultResourceGroupName rg-dr -VaultName vault-dr

.EXAMPLE
    .\Get-SiteRecoveryHealth.ps1 -VaultResourceGroupName rg-dr -RPOWarningThresholdSeconds 900 -TestFailoverStaleDays 90

.NOTES
    Requires: Az.RecoveryServices, Az.Accounts (Connect-AzAccount already run).
    Read-only. Windows PowerShell 5.1 compatible — no PowerShell 7-only operators used.
    Exports two CSVs: a fleet summary and a findings-only subset.
#>
#Requires -Modules Az.RecoveryServices

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VaultResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VaultName,

    [Parameter(Mandatory = $false)]
    [int]$RPOWarningThresholdSeconds = 1500,

    [Parameter(Mandatory = $false)]
    [int]$TestFailoverStaleDays = 180,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
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

Write-Status "Starting Azure Site Recovery health audit" "INFO"

# --- Preflight: resolve vault(s) ---
if ($VaultName) {
    $vaults = @(Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName -Name $VaultName)
} else {
    $vaults = @(Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName)
}

if ($vaults.Count -eq 0) {
    Write-Status "No Recovery Services vaults found in resource group '$VaultResourceGroupName'." "ERROR"
    return
}

Write-Status "Found $($vaults.Count) vault(s) to audit" "INFO"

$results = New-Object System.Collections.Generic.List[Object]

foreach ($vault in $vaults) {
    Write-Status "Auditing vault: $($vault.Name)" "INFO"

    try {
        Set-AzRecoveryServicesAsrVaultContext -Vault $vault | Out-Null
    } catch {
        Write-Status "Could not set vault context for '$($vault.Name)': $($_.Exception.Message)" "ERROR"
        continue
    }

    $fabrics = @()
    try {
        $fabrics = Get-AzRecoveryServicesAsrFabric -ErrorAction Stop
    } catch {
        Write-Status "No fabrics found or accessible in vault '$($vault.Name)' — skipping (likely not an ASR-enabled vault)." "WARN"
        continue
    }

    foreach ($fabric in $fabrics) {
        $containers = @()
        try {
            $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric -ErrorAction Stop
        } catch {
            Write-Status "Could not enumerate containers for fabric '$($fabric.Name)'." "WARN"
            continue
        }

        foreach ($container in $containers) {
            $items = @()
            try {
                $items = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container -ErrorAction Stop
            } catch {
                continue
            }

            foreach ($item in $items) {

                $findings = New-Object System.Collections.Generic.List[string]

                # Replication health check
                $health = $item.ReplicationHealth
                if ($health -and $health -notmatch "Normal|Healthy") {
                    $findings.Add("ReplicationHealth=$health") | Out-Null
                }

                # RPO check
                $rpoSeconds = $null
                try { $rpoSeconds = $item.ProviderSpecificDetails.RPOInSeconds } catch { $rpoSeconds = $null }
                if ($rpoSeconds -and [int]$rpoSeconds -gt $RPOWarningThresholdSeconds) {
                    $findings.Add("RPO ${rpoSeconds}s exceeds threshold ${RPOWarningThresholdSeconds}s") | Out-Null
                }

                # Test failover recency
                $lastTFO = $null
                try { $lastTFO = $item.ProviderSpecificDetails.LastTestFailoverStatus } catch { $lastTFO = $null }
                $lastTFOTime = $null
                try { $lastTFOTime = $item.ProviderSpecificDetails.LastTestFailoverTime } catch { $lastTFOTime = $null }
                if (-not $lastTFO -or $lastTFO -eq "None") {
                    $findings.Add("No test failover ever recorded") | Out-Null
                } elseif ($lastTFOTime) {
                    $daysSince = (New-TimeSpan -Start ([datetime]$lastTFOTime) -End (Get-Date)).Days
                    if ($daysSince -gt $TestFailoverStaleDays) {
                        $findings.Add("Last test failover $daysSince days ago (threshold $TestFailoverStaleDays)") | Out-Null
                    }
                }

                # Recovery point track check (crash-only vs app-consistent presence)
                $recentPoints = @()
                try {
                    $recentPoints = Get-AzRecoveryServicesAsrRecoveryPoint -ReplicationProtectedItem $item -ErrorAction SilentlyContinue |
                        Sort-Object RecoveryPointTime -Descending | Select-Object -First 5
                } catch { $recentPoints = @() }

                if ($recentPoints.Count -gt 0) {
                    $hasAppConsistent = $false
                    foreach ($rp in $recentPoints) {
                        if ($rp.RecoveryPointType -match "App") { $hasAppConsistent = $true }
                    }
                    if (-not $hasAppConsistent) {
                        $findings.Add("No app-consistent recovery point in most recent 5 — check VSS health") | Out-Null
                    }
                }

                # Recent failed jobs for this item (last 3 days)
                $recentFailedJobCount = 0
                try {
                    $recentFailedJobCount = (Get-AzRecoveryServicesAsrJob -ErrorAction SilentlyContinue |
                        Where-Object { $_.State -eq "Failed" -and $_.TargetObjectName -eq $item.FriendlyName -and $_.StartTime -gt (Get-Date).AddDays(-3) } |
                        Measure-Object).Count
                } catch { $recentFailedJobCount = 0 }
                if ($recentFailedJobCount -gt 0) {
                    $findings.Add("$recentFailedJobCount failed job(s) in last 3 days") | Out-Null
                }

                $results.Add([PSCustomObject]@{
                    VaultName            = $vault.Name
                    FabricName           = $fabric.Name
                    ContainerName        = $container.Name
                    VMFriendlyName       = $item.FriendlyName
                    ProtectionState      = $item.ProtectionState
                    ReplicationHealth    = $health
                    RPOInSeconds         = $rpoSeconds
                    LastTestFailoverStatus = $lastTFO
                    RecentFailedJobs3Days = $recentFailedJobCount
                    Findings             = ($findings -join '; ')
                    NeedsAttention       = [bool]($findings.Count -gt 0)
                }) | Out-Null
            }
        }
    }
}

# --- Report ---
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$summaryPath = Join-Path $OutputPath "SiteRecoveryHealth-Summary-$timestamp.csv"
$findingsPath = Join-Path $OutputPath "SiteRecoveryHealth-Findings-$timestamp.csv"

$results | Export-Csv -Path $summaryPath -NoTypeInformation
$results | Where-Object NeedsAttention | Export-Csv -Path $findingsPath -NoTypeInformation

$flaggedCount = ($results | Where-Object NeedsAttention | Measure-Object).Count
$totalCount = $results.Count

Write-Status "Audit complete: $totalCount protected item(s) checked, $flaggedCount flagged for attention" $(if ($flaggedCount -gt 0) { "WARN" } else { "OK" })
Write-Status "Summary report: $summaryPath" "INFO"
Write-Status "Findings-only report: $findingsPath" "INFO"

$results | Sort-Object NeedsAttention -Descending | Format-Table VaultName, VMFriendlyName, ProtectionState, ReplicationHealth, RPOInSeconds, Findings -AutoSize
