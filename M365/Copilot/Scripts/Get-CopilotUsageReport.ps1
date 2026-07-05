<#
.SYNOPSIS
    Reports Microsoft 365 Copilot license assignment, policy state, and usage readiness across the tenant.

.DESCRIPTION
    Generates a Copilot rollout/health report covering:
    - Users with the Microsoft 365 Copilot add-on SKU assigned
    - Whether each licensed user also has a valid base productivity SKU (E3/E5/Business Premium/Business Standard)
    - Users with Copilot licensed but missing a base SKU (broken mid-state — Copilot will not function)
    - Teams Copilot policy assignment summary
    - Copilot SKU pool consumption (total/consumed/available)
    Exports results to CSV files in a timestamped folder. Read-only — makes no changes.

.PARAMETER OutputPath
    Folder where CSV reports are written. Defaults to $env:TEMP\CopilotReport-<timestamp>.

.PARAMETER IncludeDisabledUsers
    If specified, includes disabled (blocked sign-in) accounts in the per-user report.

.EXAMPLE
    .\Get-CopilotUsageReport.ps1

.EXAMPLE
    .\Get-CopilotUsageReport.ps1 -OutputPath "C:\Reports\Copilot" -IncludeDisabledUsers

.NOTES
    Requires: Microsoft.Graph module (Install-Module Microsoft.Graph), MicrosoftTeams module
    Permissions: User.Read.All, Organization.Read.All, Directory.Read.All (Graph);
                 Teams Administrator or Global Reader (for Copilot policy read)
    Run as: any user with at least Global Reader
    Safe: read-only, no changes made
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "",
    [switch]$IncludeDisabledUsers
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

$teamsPolicyAvailable = $true
if (-not (Get-Module -ListAvailable -Name "MicrosoftTeams")) {
    Write-Status "MicrosoftTeams module not found — policy section will be skipped. Run: Install-Module MicrosoftTeams" "WARN"
    $teamsPolicyAvailable = $false
} else {
    try {
        if (-not (Get-CsTenant -ErrorAction SilentlyContinue)) {
            Write-Status "Connecting to Microsoft Teams..." "INFO"
            Connect-MicrosoftTeams | Out-Null
        }
    } catch {
        Write-Status "Could not connect to Microsoft Teams — policy section will be skipped. $($_.Exception.Message)" "WARN"
        $teamsPolicyAvailable = $false
    }
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $env:TEMP "CopilotReport-$(Get-Date -Format 'yyyyMMdd-HHmm')"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-Status "Reports will be saved to: $OutputPath" "OK"

#endregion

#region ─── SKU Inventory ─────────────────────────────────────────────────────

Write-Status "Fetching subscribed SKUs..."
$skus = Get-MgSubscribedSku -All

$baseSkuPattern = "SPE_E3|SPE_E5|SPB|O365_BUSINESS_PREMIUM|SPE_F1|EXCHANGESTANDARD"
$copilotSkus    = $skus | Where-Object { $_.SkuPartNumber -match "Microsoft_365_Copilot" }

if (-not $copilotSkus) {
    Write-Status "No Microsoft 365 Copilot SKU found in this tenant. Exiting." "ERROR"
    exit 1
}

$skuReport = foreach ($sku in $copilotSkus) {
    $total     = $sku.PrepaidUnits.Enabled
    $consumed  = $sku.ConsumedUnits
    $available = $total - $consumed
    $pctAvail  = if ($total -gt 0) { [math]::Round(($available / $total) * 100, 1) } else { 0 }

    [PSCustomObject]@{
        SkuPartNumber     = $sku.SkuPartNumber
        SkuId             = $sku.SkuId
        TotalLicences     = $total
        ConsumedLicences  = $consumed
        AvailableLicences = $available
        PercentAvailable  = $pctAvail
        CapabilityStatus  = $sku.CapabilityStatus
    }
}

$skuReport | Export-Csv "$OutputPath\Copilot-SKU-Pool.csv" -NoTypeInformation
Write-Status "Copilot SKU pool: $($skuReport.Count) SKU(s)" "OK"
$skuReport | Format-Table -AutoSize

#endregion

#region ─── Per-User Copilot Assignment & Health ─────────────────────────────

Write-Status "Fetching users with Copilot licenses (this may take a while for large tenants)..."

$copilotSkuIds = $copilotSkus.SkuId
$skuMap = @{}
foreach ($sku in $skus) { $skuMap[$sku.SkuId] = $sku.SkuPartNumber }

$users = Get-MgUser -All -Filter "assignedLicenses/`$count gt 0" `
    -Property "id,displayName,userPrincipalName,accountEnabled,assignedLicenses,licenseAssignmentStates,department"

$userReport = foreach ($user in $users) {
    if (-not $IncludeDisabledUsers -and -not $user.AccountEnabled) { continue }

    $assignedSkuIds = $user.AssignedLicenses.SkuId
    $hasCopilot = ($assignedSkuIds | Where-Object { $_ -in $copilotSkuIds }).Count -gt 0
    if (-not $hasCopilot) { continue }

    $hasBaseSku = ($assignedSkuIds | ForEach-Object { $skuMap[$_] }) -join ";" -match $baseSkuPattern
    $errorStates = ($user.LicenseAssignmentStates | Where-Object { $_.State -ne "Active" } |
        ForEach-Object { "$($skuMap[$_.SkuId]): $($_.Error)" }) -join "; "

    $healthStatus = if (-not $hasBaseSku) {
        "⚠ COPILOT WITHOUT BASE LICENSE"
    } elseif ($errorStates) {
        "⚠ LICENSE ASSIGNMENT ERROR"
    } else {
        "OK"
    }

    [PSCustomObject]@{
        DisplayName    = $user.DisplayName
        UPN            = $user.UserPrincipalName
        Department     = $user.Department
        AccountEnabled = $user.AccountEnabled
        HasBaseLicense = $hasBaseSku
        AssignmentErrors = $errorStates
        HealthStatus   = $healthStatus
    }
}

$userReport | Export-Csv "$OutputPath\Copilot-User-Health.csv" -NoTypeInformation
Write-Status "Copilot-licensed users found: $($userReport.Count)" "OK"

$brokenUsers = $userReport | Where-Object { $_.HealthStatus -ne "OK" }
if ($brokenUsers) {
    Write-Status "$($brokenUsers.Count) user(s) flagged with license issues:" "WARN"
    $brokenUsers | Format-Table DisplayName, UPN, HealthStatus -AutoSize
} else {
    Write-Status "No license health issues detected among Copilot users." "OK"
}

#endregion

#region ─── Teams Copilot Policy Summary ─────────────────────────────────────

if ($teamsPolicyAvailable) {
    Write-Status "Fetching Teams Copilot policy assignments..."
    try {
        $policies = Get-CsTeamsCopilotPolicy | Select-Object Identity, CopilotEnabled
        $policies | Export-Csv "$OutputPath\Copilot-Teams-Policies.csv" -NoTypeInformation
        $policies | Format-Table -AutoSize
    } catch {
        Write-Status "Could not retrieve Teams Copilot policies: $($_.Exception.Message)" "WARN"
    }
} else {
    Write-Status "Skipping Teams Copilot policy section (module unavailable)." "WARN"
}

#endregion

Write-Status "Report complete. Files written to: $OutputPath" "OK"
Get-ChildItem $OutputPath | Select-Object Name, Length | Format-Table -AutoSize
