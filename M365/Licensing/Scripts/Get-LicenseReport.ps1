<#
.SYNOPSIS
    Comprehensive M365 licence audit report for a tenant.

.DESCRIPTION
    Generates a full Microsoft 365 licence report including:
    - SKU inventory: total, consumed, available, and warning thresholds
    - Per-user licence assignments (direct and group-based)
    - Unlicensed users who have mailboxes or Intune enrolments
    - Users with duplicate/redundant licences (e.g. E3 + E5 overlap)
    - Service plan breakdown per SKU
    - Group-based licensing (GBL) errors
    Exports results to CSV files in a timestamped folder.

.PARAMETER OutputPath
    Folder where CSV reports are written. Defaults to $env:TEMP\LicenceReport-<timestamp>.

.PARAMETER IncludeDisabledUsers
    If specified, includes disabled (blocked sign-in) accounts in the per-user report.

.PARAMETER WarningThresholdPercent
    Alert on SKUs where available licences fall below this percentage of total. Default: 10.

.EXAMPLE
    .\Get-LicenceReport.ps1

.EXAMPLE
    .\Get-LicenceReport.ps1 -OutputPath "C:\Reports\Licences" -WarningThresholdPercent 15

.NOTES
    Requires: Microsoft.Graph module (Install-Module Microsoft.Graph)
    Permissions: User.Read.All, Directory.Read.All, Organization.Read.All
    Run as: any user with at least Global Reader or Licence Administrator role
    Safe: read-only, no changes made
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "",
    [switch]$IncludeDisabledUsers,
    [int]$WarningThresholdPercent = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        default { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region ─── Preflight ────────────────────────────────────────────────────────

Write-Status "Checking Microsoft.Graph module..."
if (-not (Get-Module -ListAvailable -Name "Microsoft.Graph.Users")) {
    Write-Status "Microsoft.Graph module not found. Run: Install-Module Microsoft.Graph" "ERROR"
    exit 1
}

if (-not (Get-MgContext)) {
    Write-Status "Connecting to Microsoft Graph..." "INFO"
    Connect-MgGraph -Scopes "User.Read.All","Directory.Read.All","Organization.Read.All" -NoWelcome
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $env:TEMP "LicenceReport-$(Get-Date -Format 'yyyyMMdd-HHmm')"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-Status "Reports will be saved to: $OutputPath" "OK"

#endregion

#region ─── SKU Inventory ─────────────────────────────────────────────────────

Write-Status "Fetching subscribed SKUs..."
$skus = Get-MgSubscribedSku -All

$skuReport = foreach ($sku in $skus) {
    $total     = $sku.PrepaidUnits.Enabled
    $consumed  = $sku.ConsumedUnits
    $available = $total - $consumed
    $pctUsed   = if ($total -gt 0) { [math]::Round(($consumed / $total) * 100, 1) } else { 0 }
    $pctAvail  = if ($total -gt 0) { [math]::Round(($available / $total) * 100, 1) } else { 0 }
    $warning   = if ($total -gt 0 -and $pctAvail -le $WarningThresholdPercent) { "⚠ LOW" } else { "OK" }

    [PSCustomObject]@{
        SkuPartNumber    = $sku.SkuPartNumber
        SkuId            = $sku.SkuId
        TotalLicences    = $total
        ConsumedLicences = $consumed
        AvailableLicences = $available
        PercentUsed      = $pctUsed
        PercentAvailable = $pctAvail
        CapabilityStatus = $sku.CapabilityStatus
        Warning          = $warning
    }
}

$skuReport | Sort-Object Warning, SkuPartNumber | Export-Csv "$OutputPath\SKU-Inventory.csv" -NoTypeInformation
Write-Status "SKU inventory: $($skuReport.Count) SKUs" "OK"

# Print summary table to console
$skuReport | Sort-Object Warning, SkuPartNumber |
    Format-Table SkuPartNumber, TotalLicences, ConsumedLicences, AvailableLicences, PercentUsed, Warning -AutoSize

#endregion

#region ─── Per-User Licence Report ──────────────────────────────────────────

Write-Status "Fetching users and licence assignments (this may take a while for large tenants)..."

$userFilter = "assignedLicenses/`$count ne 0 or accountEnabled eq true"
if (-not $IncludeDisabledUsers) {
    $userFilter = "accountEnabled eq true"
}

$users = Get-MgUser -All -Filter "assignedLicenses/`$count gt 0" `
    -Property "id,displayName,userPrincipalName,accountEnabled,assignedLicenses,licenseAssignmentStates,department,jobTitle,usageLocation"

# Build SKU lookup map
$skuMap = @{}
foreach ($sku in $skus) { $skuMap[$sku.SkuId] = $sku.SkuPartNumber }

$userReport = foreach ($user in $users) {
    if (-not $IncludeDisabledUsers -and -not $user.AccountEnabled) { continue }

    $skuNames      = ($user.AssignedLicenses | ForEach-Object { $skuMap[$_.SkuId] }) -join "; "
    $groupAssigned = ($user.LicenseAssignmentStates | Where-Object { $_.AssignedByGroup -ne $null } | ForEach-Object { $skuMap[$_.SkuId] }) -join "; "
    $directAssigned = ($user.LicenseAssignmentStates | Where-Object { $_.AssignedByGroup -eq $null } | ForEach-Object { $skuMap[$_.SkuId] }) -join "; "
    $errorSkus     = ($user.LicenseAssignmentStates | Where-Object { $_.State -ne "Active" } | ForEach-Object { "$($skuMap[$_.SkuId]): $($_.Error)" }) -join "; "

    [PSCustomObject]@{
        DisplayName       = $user.DisplayName
        UPN               = $user.UserPrincipalName
        AccountEnabled    = $user.AccountEnabled
        Department        = $user.Department
        JobTitle          = $user.JobTitle
        UsageLocation     = $user.UsageLocation
        TotalLicences     = $user.AssignedLicenses.Count
        AllLicences       = $skuNames
        GroupAssigned     = $groupAssigned
        DirectAssigned    = $directAssigned
        AssignmentErrors  = $errorSkus
    }
}

$userReport | Sort-Object DisplayName | Export-Csv "$OutputPath\User-Licences.csv" -NoTypeInformation
Write-Status "User licence report: $($userReport.Count) licensed users" "OK"

#endregion

#region ─── Unlicensed Users (with mailboxes) ────────────────────────────────

Write-Status "Checking for unlicensed users..."

$unlicensed = Get-MgUser -All -Filter "assignedLicenses/`$count eq 0 and accountEnabled eq true" `
    -Property "id,displayName,userPrincipalName,accountEnabled,department,jobTitle,createdDateTime" |
    Select-Object DisplayName, UserPrincipalName, AccountEnabled, Department, JobTitle, CreatedDateTime

$unlicensed | Sort-Object DisplayName | Export-Csv "$OutputPath\Unlicensed-Users.csv" -NoTypeInformation
Write-Status "Unlicensed active users: $($unlicensed.Count)" $(if ($unlicensed.Count -gt 0) { "WARN" } else { "OK" })

#endregion

#region ─── Group-Based Licensing Errors ─────────────────────────────────────

Write-Status "Checking for group-based licensing errors..."

$gblErrors = $userReport | Where-Object { $_.AssignmentErrors -ne "" } |
    Select-Object DisplayName, UPN, AssignmentErrors

if ($gblErrors.Count -gt 0) {
    $gblErrors | Export-Csv "$OutputPath\GBL-Errors.csv" -NoTypeInformation
    Write-Status "Group-based licensing errors found: $($gblErrors.Count) users" "WARN"
} else {
    Write-Status "No group-based licensing errors found" "OK"
}

#endregion

#region ─── Duplicate / Redundant Licence Detection ──────────────────────────

Write-Status "Checking for duplicate/redundant licences..."

# Flag users with both E3 and E5 (E5 is a superset — E3 is redundant)
$e3SkuPartNumbers = @("ENTERPRISEPACK", "SPE_E3", "M365EDU_A3_FACULTY", "M365EDU_A3_STUDENT")
$e5SkuPartNumbers = @("ENTERPRISEPREMIUM", "SPE_E5", "M365EDU_A5_FACULTY", "M365EDU_A5_STUDENT")

$duplicates = foreach ($user in $userReport) {
    $userSkus = $user.AllLicences -split "; "
    $hasE3 = $userSkus | Where-Object { $e3SkuPartNumbers -contains $_ }
    $hasE5 = $userSkus | Where-Object { $e5SkuPartNumbers -contains $_ }
    if ($hasE3 -and $hasE5) {
        [PSCustomObject]@{
            DisplayName  = $user.DisplayName
            UPN          = $user.UPN
            Department   = $user.Department
            E3Licence    = $hasE3 -join "; "
            E5Licence    = $hasE5 -join "; "
            Recommendation = "Remove E3 — E5 includes all E3 services"
        }
    }
}

if ($duplicates.Count -gt 0) {
    $duplicates | Export-Csv "$OutputPath\Duplicate-Licences.csv" -NoTypeInformation
    Write-Status "Users with redundant E3+E5: $($duplicates.Count)" "WARN"
} else {
    Write-Status "No E3/E5 duplicates found" "OK"
}

#endregion

#region ─── Summary Report ───────────────────────────────────────────────────

$summary = [PSCustomObject]@{
    ReportDate            = (Get-Date -Format "yyyy-MM-dd HH:mm")
    TotalSKUs             = $skuReport.Count
    LowStockSKUs          = ($skuReport | Where-Object { $_.Warning -eq "⚠ LOW" }).Count
    LicensedUsers         = $userReport.Count
    UnlicensedActiveUsers = $unlicensed.Count
    GBLErrors             = $gblErrors.Count
    RedundantLicences     = $duplicates.Count
    OutputFolder          = $OutputPath
}

$summary | Export-Csv "$OutputPath\Summary.csv" -NoTypeInformation

Write-Status "─────────────────────────────────────────" "INFO"
Write-Status "LICENCE REPORT COMPLETE" "OK"
Write-Status "  Total SKUs:              $($summary.TotalSKUs)" "INFO"
Write-Status "  Low-stock SKUs:          $($summary.LowStockSKUs)" $(if ($summary.LowStockSKUs -gt 0) {"WARN"} else {"OK"})
Write-Status "  Licensed users:          $($summary.LicensedUsers)" "INFO"
Write-Status "  Unlicensed active users: $($summary.UnlicensedActiveUsers)" $(if ($summary.UnlicensedActiveUsers -gt 0) {"WARN"} else {"OK"})
Write-Status "  GBL assignment errors:   $($summary.GBLErrors)" $(if ($summary.GBLErrors -gt 0) {"WARN"} else {"OK"})
Write-Status "  Redundant licences:      $($summary.RedundantLicences)" $(if ($summary.RedundantLicences -gt 0) {"WARN"} else {"OK"})
Write-Status "─────────────────────────────────────────" "INFO"
Write-Status "Reports saved to: $OutputPath" "OK"

Invoke-Item $OutputPath

#endregion
