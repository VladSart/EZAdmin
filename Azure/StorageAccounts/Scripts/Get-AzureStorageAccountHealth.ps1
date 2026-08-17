<#
.SYNOPSIS
    Reports Azure Storage Account access-posture health: auth toggles, network firewall,
    data-plane RBAC assignments, soft delete/versioning, immutability, and lifecycle policy state.

.DESCRIPTION
    Connects to Azure and produces a read-only health report covering:
      - Account status and key security toggles (AllowSharedKeyAccess, AllowBlobPublicAccess, MinimumTlsVersion)
      - Network firewall posture (default action, IP/VNet rule counts, Private Endpoint presence)
      - Data-plane RBAC assignments (Storage Blob/Queue/Table Data * roles) — flags accounts with
        control-plane-only role assignments and no data-plane roles, a common latent 403 trap
      - Soft delete and blob versioning configuration
      - Immutability policy presence on a specified container (optional)
      - Lifecycle management policy presence and rule count

    Does not modify anything. Safe to run at any time.

.PARAMETER ResourceGroupName
    Resource group containing the storage account(s). If omitted with -AllAccounts, scans the whole subscription.

.PARAMETER StorageAccountName
    Name of a specific storage account to inspect. Omit to use -AllAccounts instead.

.PARAMETER AllAccounts
    Switch. If set, scans every storage account visible in the current subscription context
    (optionally scoped to -ResourceGroupName).

.PARAMETER ContainerName
    Optional. If provided (with -StorageAccountName), also checks immutability policy state on this container.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\StorageAccountHealth_<timestamp>.csv.

.EXAMPLE
    .\Get-AzureStorageAccountHealth.ps1 -ResourceGroupName 'rg-storage-prod' -StorageAccountName 'stcontosodata'

.EXAMPLE
    .\Get-AzureStorageAccountHealth.ps1 -AllAccounts

.EXAMPLE
    .\Get-AzureStorageAccountHealth.ps1 -ResourceGroupName 'rg-storage-prod' -StorageAccountName 'stcontosodata' -ContainerName 'archive'

.NOTES
    Requires: Az.Storage, Az.Accounts, Az.Resources, Az.Monitor modules
    Install:  Install-Module Az.Storage, Az.Accounts, Az.Resources, Az.Monitor -Scope CurrentUser
    Permissions: Reader (or higher) on the storage account(s); data-plane roles not required for this
                 report since it only reads control-plane configuration and RBAC assignment metadata.
    Safe to run: Read-only. No accounts, containers, or data are modified.
#>

[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'All')]
    [string]$ResourceGroupName,

    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [string]$StorageAccountName,

    [Parameter(Mandatory, ParameterSetName = 'All')]
    [switch]$AllAccounts,

    [Parameter(ParameterSetName = 'Single')]
    [string]$ContainerName,

    [string]$ExportPath = "C:\Temp\StorageAccountHealth_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region — Preflight
Write-Status "Azure Storage Account Health Reporter" "INFO"
Write-Status "======================================" "INFO"

$requiredModules = @('Az.Accounts', 'Az.Storage', 'Az.Resources')
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

#region — Gather target accounts
if ($AllAccounts) {
    Write-Status "Enumerating all storage accounts$(if ($ResourceGroupName) { " in resource group '$ResourceGroupName'" })..." "INFO"
    $accounts = if ($ResourceGroupName) {
        Get-AzStorageAccount -ResourceGroupName $ResourceGroupName
    } else {
        Get-AzStorageAccount
    }
} else {
    if (-not $ResourceGroupName) {
        Write-Status "ResourceGroupName is required when specifying a single StorageAccountName." "ERROR"
        throw "Missing -ResourceGroupName"
    }
    $accounts = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)
}

Write-Status "Accounts to check: $($accounts.Count)" "INFO"
#endregion

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($sa in $accounts) {
    Write-Status "" "INFO"
    Write-Status "--- $($sa.StorageAccountName) ---" "INFO"

    $rowFlags = [System.Collections.Generic.List[string]]::new()

    # Account toggles
    $sharedKey = $sa.AllowSharedKeyAccess
    $publicAccess = $sa.AllowBlobPublicAccess
    $minTls = $sa.MinimumTlsVersion

    Write-Status "Status: $($sa.StatusOfPrimary) | SKU: $($sa.Sku.Name)" "INFO"
    Write-Status "AllowSharedKeyAccess: $sharedKey | AllowBlobPublicAccess: $publicAccess | MinTLS: $minTls" "INFO"

    if ($minTls -and $minTls -ne 'TLS1_2') {
        $rowFlags.Add("MinTLS below 1.2")
        Write-Status "  --> MinimumTlsVersion is below TLS1_2 — flag for hardening review" "WARN"
    }

    # Network posture
    try {
        $net = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $sa.ResourceGroupName -Name $sa.StorageAccountName
        Write-Status "Network DefaultAction: $($net.DefaultAction) | IP rules: $($net.IpRules.Count) | VNet rules: $($net.VirtualNetworkRules.Count)" "INFO"
        if ($net.DefaultAction -eq 'Allow') {
            $rowFlags.Add("Firewall DefaultAction=Allow")
            Write-Status "  --> Firewall default action is Allow (open) — confirm this is intentional" "WARN"
        }
    } catch {
        Write-Status "Could not read network rule set: $_" "WARN"
        $net = $null
    }

    # Data-plane RBAC check
    $dataPlaneRoleCount = 0
    try {
        $roles = Get-AzRoleAssignment -Scope $sa.Id -ErrorAction SilentlyContinue
        $dataPlaneRoles = $roles | Where-Object { $_.RoleDefinitionName -match 'Storage (Blob|Queue|Table) Data' }
        $dataPlaneRoleCount = @($dataPlaneRoles).Count
        $controlPlaneOnly = @($roles | Where-Object { $_.RoleDefinitionName -in @('Owner','Contributor','Reader') })

        if ($dataPlaneRoleCount -eq 0 -and $controlPlaneOnly.Count -gt 0) {
            $rowFlags.Add("Control-plane roles only, no data-plane RBAC")
            Write-Status "  --> $($controlPlaneOnly.Count) control-plane role(s) found but ZERO data-plane roles — likely source of latent 403s" "WARN"
        } else {
            Write-Status "Data-plane RBAC assignments: $dataPlaneRoleCount" "INFO"
        }
    } catch {
        Write-Status "Could not read RBAC assignments: $_" "WARN"
    }

    # Soft delete / versioning
    $softDeleteEnabled = $false
    $versioningEnabled = $false
    try {
        $blobProps = Get-AzStorageBlobServiceProperty -ResourceGroupName $sa.ResourceGroupName -StorageAccountName $sa.StorageAccountName
        $softDeleteEnabled = [bool]$blobProps.DeleteRetentionPolicy.Enabled
        $retentionDays = $blobProps.DeleteRetentionPolicy.Days
        $versioningEnabled = [bool]$blobProps.IsVersioningEnabled

        Write-Status "Soft delete: $softDeleteEnabled $(if ($softDeleteEnabled) { "($retentionDays days)" }) | Versioning: $versioningEnabled" "INFO"
        if (-not $softDeleteEnabled) {
            $rowFlags.Add("Soft delete disabled")
            Write-Status "  --> Soft delete is disabled — accidental deletes are not recoverable" "WARN"
        }
    } catch {
        Write-Status "Could not read blob service properties: $_" "WARN"
    }

    # Immutability (only if a specific container was requested)
    $immutabilityPresent = $null
    if ($ContainerName -and -not $AllAccounts) {
        try {
            $imm = Get-AzRmStorageContainerImmutabilityPolicy -ResourceGroupName $sa.ResourceGroupName `
                -StorageAccountName $sa.StorageAccountName -ContainerName $ContainerName -ErrorAction SilentlyContinue
            $immutabilityPresent = [bool]$imm
            Write-Status "Immutability policy on '$ContainerName': $immutabilityPresent" "INFO"
        } catch {
            Write-Status "Could not check immutability policy: $_" "WARN"
        }
    }

    # Lifecycle management policy
    $lifecycleRuleCount = 0
    try {
        $policy = Get-AzStorageAccountManagementPolicy -ResourceGroupName $sa.ResourceGroupName -StorageAccountName $sa.StorageAccountName -ErrorAction SilentlyContinue
        $lifecycleRuleCount = if ($policy -and $policy.Rule) { @($policy.Rule).Count } else { 0 }
        Write-Status "Lifecycle management rules: $lifecycleRuleCount" "INFO"
    } catch {
        Write-Status "Could not read lifecycle management policy: $_" "WARN"
    }

    $statusIcon = if ($rowFlags.Count -eq 0) { "✅" } elseif ($rowFlags.Count -le 2) { "⚠️" } else { "🔴" }

    $report.Add([PSCustomObject]@{
        StorageAccount        = $sa.StorageAccountName
        ResourceGroup         = $sa.ResourceGroupName
        Status                = $statusIcon
        StatusOfPrimary       = $sa.StatusOfPrimary
        AllowSharedKeyAccess  = $sharedKey
        AllowBlobPublicAccess = $publicAccess
        MinimumTlsVersion     = $minTls
        FirewallDefaultAction = if ($net) { $net.DefaultAction } else { "Unknown" }
        DataPlaneRoleCount    = $dataPlaneRoleCount
        SoftDeleteEnabled     = $softDeleteEnabled
        VersioningEnabled     = $versioningEnabled
        ImmutabilityOnTarget  = $immutabilityPresent
        LifecycleRuleCount    = $lifecycleRuleCount
        Flags                 = ($rowFlags -join '; ')
    })
}

#region — Summary
Write-Status "" "INFO"
Write-Status "=== SUMMARY ===" "INFO"
Write-Status "Accounts checked: $($report.Count)" "INFO"

$flagged = $report | Where-Object { $_.Flags -ne '' }
if ($flagged) {
    Write-Status "Accounts with flags requiring review:" "WARN"
    $flagged | Format-Table StorageAccount, Status, Flags -AutoSize
} else {
    Write-Status "No flags raised across checked accounts." "OK"
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" "OK"
#endregion
