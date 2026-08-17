<#
.SYNOPSIS
    Audits a tenant's readiness and in-progress state for migrating from an
    on-premises print server to Universal Print.

.DESCRIPTION
    Runs a Preflight -> Detect -> Execute -> Validate -> Report pass covering:
    - Universal Print licensing/entitlement in the tenant
    - Registered printers that are missing a share (invisible to users despite
      being "migrated")
    - Printer shares with no allowed users or groups assigned
    - A summary of registered-vs-shared counts to spot bulk-registration gaps

    This script is READ-ONLY against Microsoft Graph — it makes no changes to
    printers, shares, or permissions. It does not inventory the legacy
    on-premises print server itself (run Get-Printer directly against that
    server separately) and does not check client-side delivery mechanism state
    (GPO vs. Intune UniversalPrint CSP) or device join type — those are local,
    per-device checks documented in UP-Migration-A.md / UP-Migration-B.md.

    Output: console summary plus CSV exports for unshared printers, shares
    with no assigned access, and the full printer/share inventory.

.PARAMETER OutputPath
    Folder where CSV reports are saved. Default: C:\UPMigrationReport_<timestamp>

.PARAMETER SkipConnect
    Skip Connect-MgGraph (use when already connected in the current session
    with the required scopes).

.EXAMPLE
    .\Get-UPMigrationReadiness.ps1
    Run with defaults, connecting to Graph interactively and reporting to
    C:\UPMigrationReport_20260817_090000.

.EXAMPLE
    .\Get-UPMigrationReadiness.ps1 -OutputPath "C:\Reports\UPMigration" -SkipConnect
    Use an existing Graph session, write reports to a specific folder.

.NOTES
    Requires: Microsoft.Graph.Print / Microsoft.Graph PowerShell SDK
        (Install-Module Microsoft.Graph)
    Required Graph scopes: Printer.Read.All, PrinterShare.Read.All,
        Organization.Read.All
    Required role: Printer Administrator, Printer Technician, or Global Reader
    Run-as: any account holding one of the roles above — no local admin
        privilege required, this is a Graph-only, read-only script.
    Safe to run repeatedly and at any point during a migration project.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "C:\UPMigrationReport_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    [switch]$SkipConnect
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

# ------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------
Write-Status "Starting Universal Print migration readiness audit" "INFO"

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Print -ErrorAction SilentlyContinue) -and
    -not (Get-Module -ListAvailable -Name Microsoft.Graph -ErrorAction SilentlyContinue)) {
    Write-Status "Microsoft.Graph PowerShell SDK not found. Install with: Install-Module Microsoft.Graph" "ERROR"
    throw "Required module not installed."
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Status "Created output folder: $OutputPath" "OK"
}

if (-not $SkipConnect) {
    Write-Status "Connecting to Microsoft Graph (Printer.Read.All, PrinterShare.Read.All, Organization.Read.All)" "INFO"
    Connect-MgGraph -Scopes "Printer.Read.All", "PrinterShare.Read.All", "Organization.Read.All" -NoWelcome
}

$context = Get-MgContext
if (-not $context) {
    Write-Status "No active Graph session. Connect-MgGraph failed or was skipped without an existing session." "ERROR"
    throw "Not connected to Microsoft Graph."
}
Write-Status "Connected to tenant: $($context.TenantId) as $($context.Account)" "OK"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ------------------------------------------------------------------
# Detect — Licensing
# ------------------------------------------------------------------
Write-Status "Checking Universal Print licensing/entitlement" "INFO"

$upSkus = Get-MgSubscribedSku -All | Where-Object {
    $_.ServicePlans.ServicePlanName -match "UNIVERSAL_PRINT"
}

if (-not $upSkus) {
    Write-Status "No Universal Print service plan found in this tenant. Migration cannot proceed until licensing is assigned." "ERROR"
} else {
    foreach ($sku in $upSkus) {
        $enabledUnits = $sku.PrepaidUnits.Enabled
        Write-Status "SKU $($sku.SkuPartNumber): $($sku.ConsumedUnits) consumed of $enabledUnits enabled units" "OK"
    }
}

$upSkus |
    Select-Object SkuPartNumber, ConsumedUnits, @{N = 'EnabledUnits'; E = { $_.PrepaidUnits.Enabled } } |
    Export-Csv -Path (Join-Path $OutputPath "UPMigration-Licensing-$stamp.csv") -NoTypeInformation

# ------------------------------------------------------------------
# Detect — Printer / Share inventory
# ------------------------------------------------------------------
Write-Status "Retrieving printer inventory (this can take a while in large tenants)" "INFO"
$printers = @()
try {
    $printers = Get-MgPrintPrinter -All -ErrorAction Stop
} catch {
    Write-Status "Failed to retrieve printers: $($_.Exception.Message)" "ERROR"
}
Write-Status "Found $($printers.Count) registered printer(s)" "INFO"

Write-Status "Retrieving printer share inventory" "INFO"
$shares = @()
try {
    $shares = Get-MgPrintShare -All -ErrorAction Stop
} catch {
    Write-Status "Failed to retrieve printer shares: $($_.Exception.Message)" "ERROR"
}
Write-Status "Found $($shares.Count) printer share(s)" "INFO"

$sharedPrinterIds = $shares.PrinterId | Where-Object { $_ }

# ------------------------------------------------------------------
# Detect — Registered-but-unshared printers (the #1 migration gap)
# ------------------------------------------------------------------
$unsharedPrinters = $printers | Where-Object { $_.Id -notin $sharedPrinterIds }

if ($unsharedPrinters.Count -gt 0) {
    Write-Status "$($unsharedPrinters.Count) printer(s) are registered but NOT shared — invisible to users" "WARN"
} else {
    Write-Status "Every registered printer has at least one share" "OK"
}

$unsharedPrinters |
    Select-Object DisplayName, Id, Manufacturer, Model, HasPhysicalDevice |
    Export-Csv -Path (Join-Path $OutputPath "UPMigration-UnsharedPrinters-$stamp.csv") -NoTypeInformation

# ------------------------------------------------------------------
# Detect — Shares with no allowed users/groups assigned
# ------------------------------------------------------------------
Write-Status "Checking shares for missing access assignments (allowedUsers / allowedGroups)" "INFO"

$emptyShares = @()
foreach ($share in $shares) {
    try {
        $allowedUsers  = Get-MgPrintShareAllowedUser  -PrintShareId $share.Id -ErrorAction SilentlyContinue
        $allowedGroups = Get-MgPrintShareAllowedGroup -PrintShareId $share.Id -ErrorAction SilentlyContinue

        if (-not $allowedUsers -and -not $allowedGroups -and -not $share.AllowAllUsers) {
            $emptyShares += [PSCustomObject]@{
                DisplayName = $share.DisplayName
                Id          = $share.Id
                PrinterId   = $share.PrinterId
            }
        }
    } catch {
        Write-Status "Could not check access for share $($share.DisplayName): $($_.Exception.Message)" "WARN"
    }
}

if ($emptyShares.Count -gt 0) {
    Write-Status "$($emptyShares.Count) share(s) have NO users, groups, or 'allow all' configured — also invisible to users" "WARN"
} else {
    Write-Status "All shares have at least one access assignment" "OK"
}

$emptyShares | Export-Csv -Path (Join-Path $OutputPath "UPMigration-SharesWithNoAccess-$stamp.csv") -NoTypeInformation

# ------------------------------------------------------------------
# Report — Full inventory + summary
# ------------------------------------------------------------------
$printers |
    Select-Object DisplayName, Id, IsShared, HasPhysicalDevice, Manufacturer, Model |
    Export-Csv -Path (Join-Path $OutputPath "UPMigration-PrinterInventory-$stamp.csv") -NoTypeInformation

Write-Status "----------------------------------------------------" "INFO"
Write-Status "Summary" "INFO"
Write-Status "  Registered printers:        $($printers.Count)" "INFO"
Write-Status "  Printer shares:             $($shares.Count)" "INFO"
Write-Status "  Unshared printers:          $($unsharedPrinters.Count)" $(if ($unsharedPrinters.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "  Shares with no access:      $($emptyShares.Count)" $(if ($emptyShares.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "----------------------------------------------------" "INFO"
Write-Status "Reports written to: $OutputPath" "OK"
Write-Status "REMINDER: this script does not check client-side delivery mechanism (legacy GPO vs. Intune UniversalPrint CSP) or device join type — verify those separately per UP-Migration-B.md Triage steps 4-5." "INFO"
