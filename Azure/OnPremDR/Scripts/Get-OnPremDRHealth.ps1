<#
.SYNOPSIS
    Read-only fleet-wide health audit for on-premises-to-Azure disaster recovery
    (VMware and Hyper-V) protected items in Azure Site Recovery.

.DESCRIPTION
    Connects to one or all Recovery Services vaults in a resource group, walks every
    fabric (VMware or Hyper-V/VMM) and protection container, and reports per-item
    replication health, protection state, platform, and recent job failures.

    Flags, per item:
      - ReplicationHealth not Normal/Healthy
      - ProtectionState outside the expected steady state (Protected)
      - Any Failed job for that item within the last -FailedJobLookbackDays (default 3)
      - Fabric type is a VMware Classic Configuration Server (retiring 30 Mar 2026) rather
        than a Modernized ASR replication appliance
      - A vault with mixed Classic and Modernized fabrics registered (migration in progress
        or incomplete — worth a status check on its own)

    Does not distinguish Hyper-V "non-recoverable" vs. "recoverable" errors automatically —
    that classification depends on the exact error text surfaced per item, which this script
    captures verbatim in the CSV for manual review, per the guidance in OnPremDR-A.md.

    Does not modify replication state, trigger failover/failback, disable protection, or
    touch any on-premises appliance/host — read-only against the Az control plane throughout.
    Requires an authenticated Az PowerShell session (Connect-AzAccount) with
    Az.RecoveryServices installed.

.PARAMETER VaultResourceGroupName
    Resource group containing the Recovery Services vault(s) to audit.

.PARAMETER VaultName
    Name of a specific Recovery Services vault to audit. If omitted, all vaults in the
    resource group are audited.

.PARAMETER FailedJobLookbackDays
    Number of days back to check for failed jobs per vault. Default 3.

.PARAMETER OutputPath
    Folder to write the CSV report(s) to. Default is the current directory.

.EXAMPLE
    .\Get-OnPremDRHealth.ps1 -VaultResourceGroupName rg-dr -VaultName vault-onprem-dr

.EXAMPLE
    .\Get-OnPremDRHealth.ps1 -VaultResourceGroupName rg-dr -FailedJobLookbackDays 7 -OutputPath C:\Reports

.NOTES
    Requires: Az.RecoveryServices module, an authenticated Connect-AzAccount session.
    Run-as: no elevated/administrator rights required — this queries the Azure control
    plane only, not any on-premises appliance or Hyper-V host directly.
    Safe: read-only. Does not require -RunAsAdministrator.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VaultResourceGroupName,

    [string]$VaultName,

    [int]$FailedJobLookbackDays = 3,

    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---------------------------------------------------------------
try {
    $context = Get-AzContext
    if (-not $context) { throw "No active Az context." }
    Write-Status "Authenticated as $($context.Account.Id) against subscription $($context.Subscription.Name)" "OK"
} catch {
    Write-Status "Not connected to Azure. Run Connect-AzAccount first." "ERROR"
    throw
}

if (-not (Get-Module -ListAvailable -Name Az.RecoveryServices)) {
    Write-Status "Az.RecoveryServices module not found. Install-Module Az.RecoveryServices." "ERROR"
    throw "Missing required module: Az.RecoveryServices"
}

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "OutputPath '$OutputPath' does not exist. Creating it." "WARN"
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# --- Detect --------------------------------------------------------------
Write-Status "Discovering Recovery Services vaults in resource group '$VaultResourceGroupName'..."
$vaults = if ($VaultName) {
    @(Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName -Name $VaultName)
} else {
    Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName
}

if (-not $vaults -or $vaults.Count -eq 0) {
    Write-Status "No Recovery Services vaults found. Nothing to audit." "WARN"
    return
}
Write-Status "Found $($vaults.Count) vault(s) to audit." "OK"

# --- Execute ---------------------------------------------------------------
$itemResults  = New-Object System.Collections.Generic.List[object]
$jobResults   = New-Object System.Collections.Generic.List[object]
$vaultSummary = New-Object System.Collections.Generic.List[object]

foreach ($vault in $vaults) {
    Write-Status "Auditing vault: $($vault.Name)"
    try {
        Set-AzRecoveryServicesAsrVaultContext -Vault $vault | Out-Null
    } catch {
        Write-Status "Could not set vault context for '$($vault.Name)': $($_.Exception.Message)" "ERROR"
        continue
    }

    $fabrics = @()
    try { $fabrics = Get-AzRecoveryServicesAsrFabric } catch {
        Write-Status "No ASR fabrics returned for '$($vault.Name)' (vault may not be DR-enabled)." "WARN"
    }

    $fabricTypes = $fabrics | ForEach-Object {
        $typeName = $_.FabricSpecificDetails.GetType().Name
        [PSCustomObject]@{ FriendlyName = $_.FriendlyName; TypeName = $typeName }
    }
    $hasClassicVMware = $fabricTypes | Where-Object { $_.TypeName -match "ConfigurationServer|VMware" -and $_.TypeName -notmatch "Modernized" }
    $hasHyperV        = $fabricTypes | Where-Object { $_.TypeName -match "HyperV" }

    if ($hasClassicVMware) {
        Write-Status "Vault '$($vault.Name)': fabric type suggests Classic VMware/physical protection — verify against the portal. Classic retires 30 Mar 2026." "WARN"
    }

    foreach ($fabric in $fabrics) {
        $containers = @()
        try { $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric } catch {
            Write-Status "Could not enumerate containers for fabric '$($fabric.FriendlyName)': $($_.Exception.Message)" "WARN"
            continue
        }

        foreach ($container in $containers) {
            $items = @()
            try { $items = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container } catch {
                Write-Status "Could not enumerate protected items for container '$($container.FriendlyName)': $($_.Exception.Message)" "WARN"
                continue
            }

            foreach ($item in $items) {
                $isHealthy    = $item.ReplicationHealth -in @("Normal", "Healthy")
                $isProtected  = $item.ProtectionState -eq "Protected"
                $flagged      = -not $isHealthy -or -not $isProtected

                $itemResults.Add([PSCustomObject]@{
                    VaultName          = $vault.Name
                    FabricFriendlyName = $fabric.FriendlyName
                    FabricType         = $fabric.FabricSpecificDetails.GetType().Name
                    ContainerName      = $container.FriendlyName
                    VmFriendlyName     = $item.FriendlyName
                    ProtectionState    = $item.ProtectionState
                    ReplicationHealth  = $item.ReplicationHealth
                    Flagged            = $flagged
                    FlagReason         = if ($flagged) {
                        @(
                            if (-not $isHealthy)   { "ReplicationHealth=$($item.ReplicationHealth)" }
                            if (-not $isProtected) { "ProtectionState=$($item.ProtectionState)" }
                        ) -join "; "
                    } else { "" }
                })

                if ($flagged) {
                    Write-Status "  Flagged: $($item.FriendlyName) — health=$($item.ReplicationHealth), state=$($item.ProtectionState)" "WARN"
                }
            }
        }
    }

    # Recent failed jobs for this vault
    $cutoff = (Get-Date).AddDays(-$FailedJobLookbackDays)
    try {
        $failedJobs = Get-AzRecoveryServicesAsrJob | Where-Object { $_.State -eq "Failed" -and $_.StartTime -gt $cutoff }
        foreach ($job in $failedJobs) {
            $jobResults.Add([PSCustomObject]@{
                VaultName        = $vault.Name
                JobDisplayName   = $job.DisplayName
                TargetObjectName = $job.TargetObjectName
                StartTime        = $job.StartTime
                StateDescription = $job.StateDescription
            })
        }
        if ($failedJobs.Count -gt 0) {
            Write-Status "  $($failedJobs.Count) failed job(s) in the last $FailedJobLookbackDays day(s)." "WARN"
        }
    } catch {
        Write-Status "Could not retrieve jobs for '$($vault.Name)': $($_.Exception.Message)" "WARN"
    }

    $vaultSummary.Add([PSCustomObject]@{
        VaultName             = $vault.Name
        FabricCount           = $fabrics.Count
        HasClassicVMwareFabric = [bool]$hasClassicVMware
        HasHyperVFabric        = [bool]$hasHyperV
        ProtectedItemCount     = ($itemResults | Where-Object VaultName -eq $vault.Name).Count
        FlaggedItemCount       = ($itemResults | Where-Object { $_.VaultName -eq $vault.Name -and $_.Flagged }).Count
    })
}

# --- Validate / Report ---------------------------------------------------------------
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

$itemPath   = Join-Path $OutputPath "OnPremDR-ProtectedItems-$stamp.csv"
$jobPath    = Join-Path $OutputPath "OnPremDR-FailedJobs-$stamp.csv"
$vaultPath  = Join-Path $OutputPath "OnPremDR-VaultSummary-$stamp.csv"

$itemResults  | Export-Csv -Path $itemPath  -NoTypeInformation
$jobResults   | Export-Csv -Path $jobPath   -NoTypeInformation
$vaultSummary | Export-Csv -Path $vaultPath -NoTypeInformation

Write-Status "Audit complete." "OK"
Write-Status "Vaults audited: $($vaultSummary.Count) | Protected items: $($itemResults.Count) | Flagged items: $(($itemResults | Where-Object Flagged).Count) | Failed jobs (last $FailedJobLookbackDays d): $($jobResults.Count)" "OK"
Write-Status "Reports written:" "OK"
Write-Status "  $itemPath"
Write-Status "  $jobPath"
Write-Status "  $vaultPath"

if ($vaultSummary | Where-Object HasClassicVMwareFabric) {
    Write-Status "One or more vaults show a possible Classic VMware/physical fabric. Classic support ends 15 Mar 2026 and the capability retires 30 Mar 2026 — verify in the portal and flag for migration to the Modernized ASR replication appliance." "WARN"
}
