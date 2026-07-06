<#
.SYNOPSIS
    Reports Azure Files share health: quota/usage, identity-based auth configuration,
    network access rules, and RBAC role assignments for a storage account.

.DESCRIPTION
    Connects to Azure and produces a health report covering:
      - Storage account SKU/kind and network firewall configuration
      - Identity-based auth model (None / AADKERB / AD DS)
      - Per-share quota vs actual usage
      - RBAC role assignments scoped to "Storage File Data" roles
      - Optional: SMB connectivity test to the storage account from the machine running this script

    Does not modify anything. Safe to run at any time.

.PARAMETER ResourceGroupName
    Resource group containing the storage account.

.PARAMETER StorageAccountName
    Name of the storage account to inspect.

.PARAMETER ShareName
    Optional. If provided, restricts the quota/usage check to this share only.
    If omitted, reports on all file shares in the account.

.PARAMETER TestConnectivity
    Switch. If set, runs a Test-NetConnection against <StorageAccountName>.file.core.windows.net on port 445
    from the machine running this script.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\AzureFilesHealth_<timestamp>.csv.

.EXAMPLE
    .\Get-AzureFileShareHealth.ps1 -ResourceGroupName 'rg-storage-prod' -StorageAccountName 'stcontosofiles'

.EXAMPLE
    .\Get-AzureFileShareHealth.ps1 -ResourceGroupName 'rg-storage-prod' -StorageAccountName 'stcontosofiles' `
        -ShareName 'profiles' -TestConnectivity

.NOTES
    Requires: Az.Storage, Az.Accounts, Az.Resources modules
    Install:  Install-Module Az.Storage, Az.Accounts, Az.Resources -Scope CurrentUser
    Permissions: Reader (or higher) on the storage account
    Safe to run: Read-only. No shares, ACLs, or accounts are modified.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$StorageAccountName,
    [string]$ShareName,
    [switch]$TestConnectivity,
    [string]$ExportPath = "C:\Temp\AzureFilesHealth_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region — Preflight
Write-Status "Azure Files Share Health Reporter" "INFO"
Write-Status "=================================" "INFO"

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

#region — Storage account overview
Write-Status "Retrieving storage account: $StorageAccountName" "INFO"
try {
    $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
} catch {
    Write-Status "Failed to retrieve storage account: $_" "ERROR"
    throw
}

Write-Status "SKU: $($sa.Sku.Name) | Kind: $($sa.Kind)" "OK"

$authOptions = $sa.AzureFilesIdentityBasedAuth
$authModel = if ($authOptions -and $authOptions.DirectoryServiceOptions) { $authOptions.DirectoryServiceOptions } else { "None" }
$authColour = if ($authModel -eq "None") { "WARN" } else { "OK" }
Write-Status "Identity-based auth model: $authModel" $authColour
if ($authModel -eq "None") {
    Write-Status "  --> Only the storage account key will work. No per-user identity or NTFS ACL enforcement." "WARN"
}

try {
    $netRules = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    Write-Status "Network default action: $($netRules.DefaultAction) | VNet rules: $($netRules.VirtualNetworkRules.Count) | IP rules: $($netRules.IpRules.Count)" "INFO"
} catch {
    Write-Status "Could not read network rule set: $_" "WARN"
}

try {
    $peConnections = Get-AzPrivateEndpointConnection -ResourceGroupName $ResourceGroupName `
        -ServiceName $StorageAccountName -PrivateLinkServiceType Microsoft.Storage -ErrorAction SilentlyContinue
    if ($peConnections) {
        Write-Status "Private Endpoint connections: $($peConnections.Count)" "INFO"
    } else {
        Write-Status "No Private Endpoint connections found — account likely uses public endpoint" "INFO"
    }
} catch {
    Write-Status "Could not check Private Endpoint connections: $_" "WARN"
}
#endregion

#region — RBAC assignments
Write-Status "Checking RBAC role assignments (Storage File Data *)..." "INFO"
$rbacReport = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $roles = Get-AzRoleAssignment -Scope $sa.Id | Where-Object { $_.RoleDefinitionName -like "Storage File Data*" }
    if ($roles) {
        foreach ($r in $roles) {
            $rbacReport.Add([PSCustomObject]@{
                Type      = "RBAC"
                Principal = $r.DisplayName
                Role      = $r.RoleDefinitionName
                Scope     = $r.Scope
            })
            Write-Host "  $($r.DisplayName) -> $($r.RoleDefinitionName)"
        }
    } else {
        Write-Status "No 'Storage File Data' RBAC assignments found at the account scope. Check share-level scopes too." "WARN"
    }
} catch {
    Write-Status "Could not read RBAC assignments: $_" "WARN"
}
#endregion

#region — Share quota/usage
Write-Status "Checking file share quota and usage..." "INFO"
$shareReport = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    if ($ShareName) {
        $shares = @(Get-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $ShareName)
    } else {
        $shares = Get-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName
    }
} catch {
    Write-Status "Failed to enumerate shares: $_" "ERROR"
    throw
}

foreach ($share in $shares) {
    try {
        $stats = Get-AzRmStorageShareStats -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName -Name $share.Name -ErrorAction SilentlyContinue
        $usedGiB = if ($stats) { [math]::Round($stats.ShareUsageBytes / 1GB, 2) } else { -1 }
        $quotaGiB = $share.QuotaGiB
        $pctUsed  = if ($quotaGiB -gt 0 -and $usedGiB -ge 0) { [math]::Round(($usedGiB / $quotaGiB) * 100, 1) } else { -1 }

        $statusIcon = if ($pctUsed -ge 90) { "🔴" } elseif ($pctUsed -ge 75) { "⚠️" } else { "✅" }

        $entry = [PSCustomObject]@{
            ShareName    = $share.Name
            QuotaGiB     = $quotaGiB
            UsedGiB      = $usedGiB
            PercentUsed  = $pctUsed
            Status       = "$statusIcon"
            Protocol     = $share.EnabledProtocol
            AccessTier   = $share.AccessTier
        }
        $shareReport.Add($entry)
        Write-Host "  $statusIcon $($share.Name): $usedGiB / $quotaGiB GiB ($pctUsed%)"
    } catch {
        Write-Status "  Could not get stats for share $($share.Name): $_" "WARN"
    }
}
#endregion

#region — Optional connectivity test
if ($TestConnectivity) {
    Write-Status "Testing SMB connectivity to $StorageAccountName.file.core.windows.net:445..." "INFO"
    $fqdn = "$StorageAccountName.file.core.windows.net"
    try {
        $test = Test-NetConnection -ComputerName $fqdn -Port 445 -WarningAction SilentlyContinue
        if ($test.TcpTestSucceeded) {
            Write-Status "Port 445 reachable from this machine." "OK"
        } else {
            Write-Status "Port 445 NOT reachable. Direct SMB mount will fail from this network — consider Azure File Sync or a Private Endpoint + VPN path." "ERROR"
        }
        $dns = Resolve-DnsName $fqdn -ErrorAction SilentlyContinue
        Write-Status "DNS resolves to: $($dns.IPAddress -join ', ')" "INFO"
    } catch {
        Write-Status "Connectivity test failed: $_" "WARN"
    }
}
#endregion

#region — Export and summary
Write-Status "" "INFO"
Write-Status "=== SUMMARY ===" "INFO"
Write-Status "Storage Account: $StorageAccountName | Auth Model: $authModel" "INFO"
Write-Status "Shares checked: $($shareReport.Count)" "INFO"

$nearQuota = $shareReport | Where-Object { $_.PercentUsed -ge 75 }
if ($nearQuota) {
    Write-Status "Shares approaching quota (>=75%):" "WARN"
    $nearQuota | Format-Table -AutoSize
}

$combined = @()
$combined += $shareReport | ForEach-Object { $_ | Add-Member -NotePropertyName ReportType -NotePropertyValue "Share" -PassThru }
$combined += $rbacReport | ForEach-Object { $_ | Add-Member -NotePropertyName ReportType -NotePropertyValue "RBAC" -PassThru }

$combined | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" "OK"
#endregion
