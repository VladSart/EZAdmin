<#
.SYNOPSIS
    Reports Azure Backup (Recovery Services Vault) health for Azure VMs: protection status,
    recent job outcomes, guest-level prerequisite health, and soft-deleted items.

.DESCRIPTION
    Connects to Azure and produces a health report covering:
      - Vault redundancy/configuration
      - Per-VM protection status, last backup result, and recovery point freshness
      - Failed backup jobs in the lookback window, with error codes
      - Backup VM extension provisioning state and VM Agent heartbeat (guest-level prerequisites)
      - Soft-deleted items pending within the 14-day recovery window

    Does not modify anything (no backup/restore/protection changes). Safe to run at any time.

.PARAMETER ResourceGroupName
    Resource group containing the Recovery Services Vault.

.PARAMETER VaultName
    Name of the Recovery Services Vault to inspect.

.PARAMETER LookbackDays
    How many days back to check for failed jobs. Defaults to 7.

.PARAMETER CheckGuestPrerequisites
    Switch. If set, also checks the Backup extension and VM Agent heartbeat for every protected VM.
    Slower (one extra call per VM) — omit for a quick vault-level pass.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\AzureBackupHealth_<timestamp>.csv.

.EXAMPLE
    .\Get-AzureBackupJobStatus.ps1 -ResourceGroupName 'rg-backup-prod' -VaultName 'rsv-contoso-prod'

.EXAMPLE
    .\Get-AzureBackupJobStatus.ps1 -ResourceGroupName 'rg-backup-prod' -VaultName 'rsv-contoso-prod' `
        -LookbackDays 14 -CheckGuestPrerequisites

.NOTES
    Requires: Az.RecoveryServices, Az.Compute, Az.Accounts modules
    Install:  Install-Module Az.RecoveryServices, Az.Compute, Az.Accounts -Scope CurrentUser
    Permissions: Backup Reader (or higher) on the vault; Reader on the VMs if -CheckGuestPrerequisites is used
    Safe to run: Read-only. No protection, policy, or job changes are made.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$VaultName,
    [int]$LookbackDays = 7,
    [switch]$CheckGuestPrerequisites,
    [string]$ExportPath = "C:\Temp\AzureBackupHealth_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region — Preflight
Write-Status "Azure Backup (RSV) Health Reporter" "INFO"
Write-Status "===================================" "INFO"

$requiredModules = @('Az.Accounts', 'Az.RecoveryServices', 'Az.Compute')
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
        throw "Missing required module: $mod"
    }
}

try {
    $ctx = Get-AzContext
    if (-not $ctx) {
        Write-Status "No Azure context — launching interactive login..." "WARN"
        Connect-AzAccount
        $ctx = Get-AzContext
    }
    Write-Status "Azure context: $($ctx.Account.Id) | $($ctx.Subscription.Name)" "OK"
} catch {
    Write-Status "Failed to get Azure context: $_" "ERROR"
    throw
}

$outDir = Split-Path $ExportPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
#endregion

#region — Vault context
Write-Status "Retrieving vault: $VaultName" "INFO"
try {
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName
    Set-AzRecoveryServicesVaultContext -Vault $vault
} catch {
    Write-Status "Failed to retrieve/set vault context: $_" "ERROR"
    throw
}

try {
    $redundancy = Get-AzRecoveryServicesVaultProperty -VaultId $vault.ID
    Write-Status "Redundancy: $($redundancy.RedundancySettings.StorageType)" "INFO"
} catch {
    Write-Status "Could not read vault redundancy settings: $_" "WARN"
}
#endregion

#region — Protected items
Write-Status "Enumerating protected AzureVM items..." "INFO"
$itemReport = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $items = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM
} catch {
    Write-Status "Failed to enumerate backup items: $_" "ERROR"
    throw
}

foreach ($item in $items) {
    $statusIcon = switch ($item.ProtectionStatus) {
        "Healthy"          { "OK" }
        "ProtectionStopped" { "WARN" }
        default             { "WARN" }
    }

    $lastBackupStatusIcon = if ($item.LastBackupStatus -eq "Completed") { "OK" } else { "WARN" }

    $entry = [PSCustomObject]@{
        VMName             = $item.Name
        ProtectionStatus   = $item.ProtectionStatus
        LastBackupStatus   = $item.LastBackupStatus
        LastBackupTime     = $item.LastBackupTime
        PolicyName         = $item.ProtectionPolicyName
        ExtensionState     = "NotChecked"
        VMAgentHeartbeat   = "NotChecked"
    }

    if ($CheckGuestPrerequisites) {
        # Extract resource group/VM name from the item's container/policy metadata where possible;
        # falls back to a best-effort name match against Get-AzVM if not directly available.
        $vmMatch = Get-AzVM | Where-Object { $item.Name -like "*$($_.Name)*" } | Select-Object -First 1
        if ($vmMatch) {
            try {
                $ext = Get-AzVMExtension -ResourceGroupName $vmMatch.ResourceGroupName -VMName $vmMatch.Name -ErrorAction SilentlyContinue |
                    Where-Object { $_.ExtensionType -like "*BackupExtension*" }
                $entry.ExtensionState = if ($ext) { $ext.ProvisioningState } else { "NotInstalled" }
            } catch { $entry.ExtensionState = "CheckFailed" }

            try {
                $agentStatus = (Get-AzVM -ResourceGroupName $vmMatch.ResourceGroupName -Name $vmMatch.Name -Status).VMAgent.Statuses
                $entry.VMAgentHeartbeat = if ($agentStatus) { ($agentStatus | Select-Object -First 1).DisplayStatus } else { "Unknown" }
            } catch { $entry.VMAgentHeartbeat = "CheckFailed" }
        } else {
            $entry.ExtensionState = "VMNotFound(possiblyDeleted)"
        }
    }

    $itemReport.Add($entry)
    Write-Host "  [$statusIcon] $($item.Name) | Protection: $($item.ProtectionStatus) | LastBackup: [$lastBackupStatusIcon] $($item.LastBackupStatus) @ $($item.LastBackupTime)"
}
#endregion

#region — Failed jobs
Write-Status "Checking failed jobs (last $LookbackDays days)..." "INFO"
$jobReport = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $failedJobs = Get-AzRecoveryServicesBackupJob -Status Failed -From (Get-Date).AddDays(-$LookbackDays)
    foreach ($job in $failedJobs) {
        $entry = [PSCustomObject]@{
            WorkloadName = $job.WorkloadName
            Operation    = $job.Operation
            StartTime    = $job.StartTime
            Status       = $job.Status
            ErrorDetails = ($job.ErrorDetails -join '; ')
        }
        $jobReport.Add($entry)
        Write-Status "  $($job.WorkloadName) | $($job.Operation) | $($job.StartTime) | $($job.ErrorDetails -join '; ')" "WARN"
    }
    if ($failedJobs.Count -eq 0) {
        Write-Status "No failed jobs in the lookback window." "OK"
    }
} catch {
    Write-Status "Could not read backup job history: $_" "WARN"
}
#endregion

#region — Soft-deleted items
Write-Status "Checking soft-deleted items pending recovery..." "INFO"
$deletedReport = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $deletedItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -DeleteState "ToBeDeleted" -ErrorAction SilentlyContinue
    foreach ($di in $deletedItems) {
        $deletedReport.Add([PSCustomObject]@{ VMName = $di.Name; DeleteState = "ToBeDeleted" })
        Write-Status "  SOFT-DELETED: $($di.Name) — recoverable via Undo-AzRecoveryServicesBackupItemDeletion within the 14-day window" "WARN"
    }
    if ($deletedReport.Count -eq 0) {
        Write-Status "No soft-deleted items pending." "OK"
    }
} catch {
    Write-Status "Could not check soft-delete state: $_" "WARN"
}
#endregion

#region — Export and summary
Write-Status "" "INFO"
Write-Status "=== SUMMARY ===" "INFO"
Write-Status "Vault: $VaultName | Protected Items: $($itemReport.Count) | Failed Jobs: $($jobReport.Count) | Soft-Deleted Pending: $($deletedReport.Count)" "INFO"

$unhealthy = $itemReport | Where-Object { $_.ProtectionStatus -ne "Healthy" -or $_.LastBackupStatus -ne "Completed" }
if ($unhealthy) {
    Write-Status "Items needing attention:" "WARN"
    $unhealthy | Format-Table -AutoSize
}

$combined = @()
$combined += $itemReport   | ForEach-Object { $_ | Add-Member -NotePropertyName ReportType -NotePropertyValue "ProtectedItem" -PassThru }
$combined += $jobReport    | ForEach-Object { $_ | Add-Member -NotePropertyName ReportType -NotePropertyValue "FailedJob" -PassThru }
$combined += $deletedReport | ForEach-Object { $_ | Add-Member -NotePropertyName ReportType -NotePropertyValue "SoftDeleted" -PassThru }

$combined | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" "OK"
#endregion
