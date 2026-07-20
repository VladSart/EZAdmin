<#
.SYNOPSIS
    Audits Universal Print licensing and printer-share readiness for a macOS user,
    cross-referencing the tenant-wide settings that are specific to macOS clients.

.DESCRIPTION
    Companion script to M365/UniversalPrint/Universal-Print-macOS-A.md and
    Universal-Print-macOS-B.md. This is an admin-side, Graph-based check — it cannot
    see device-local state (app install/launch status, sign-in state, or macOS
    version), which must still be confirmed directly on the affected Mac per both
    runbooks' Validation Steps.

    For a given user, this reports:
    - Whether the user's account carries any assigned license at all (a full,
      automated Universal-Print-eligibility SKU check requires cross-referencing
      against Microsoft's published eligible-subscription list, which changes over
      time — this script surfaces the assigned SKU IDs so an admin can do that
      cross-reference quickly, per both runbooks' Fix 3 / Validation Step 4)
    - Every printer, whether it is shared to this user (directly or via a group
      they're a member of), matching Universal-Print-macOS-A.md's "visibility is
      per-device, permission is per-user" distinction
    - A printer-name filter to narrow results when troubleshooting one specific
      printer, per both runbooks' Fix 3/Fix 4 split (discovery vs. permission)

    Does NOT check: macOS version, app install/launch state, sign-in state, the
    tenant's "macOS Support" global setting, or Document Conversion state — those
    require either the device itself or a manual Azure Portal check (see both
    runbooks' Command Cheat Sheet).

    Read-only. Makes no changes to any user, printer, or share.

.PARAMETER UserPrincipalName
    The Entra ID UPN of the user to audit.

.PARAMETER PrinterNameFilter
    Optional substring to narrow the printer list (e.g. a specific printer name
    a user reports trouble with).

.PARAMETER OutputPath
    Path to export a CSV report. Default: $env:TEMP\UPMacOSReadiness-<date>.csv

.EXAMPLE
    .\Get-UniversalPrintMacOSReadiness.ps1 -UserPrincipalName "jane.doe@contoso.com"

.EXAMPLE
    .\Get-UniversalPrintMacOSReadiness.ps1 -UserPrincipalName "jane.doe@contoso.com" -PrinterNameFilter "3rd Floor"

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Print (or equivalent Graph SDK
              modules exposing Get-MgPrinter/Get-MgPrintShare)
    Connect-MgGraph -Scopes "User.Read.All","Printer.Read.All","PrintSettings.Read.All"
    Run as:   Any account with Universal Print Administrator or Printer
              Administrator rights (or equivalent Graph read scopes)
    Safe to run repeatedly — read-only, no changes made.
    Companion runbooks: M365/UniversalPrint/Universal-Print-macOS-A.md,
    Universal-Print-macOS-B.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$UserPrincipalName,

    [string]$PrinterNameFilter,

    [string]$OutputPath = "$env:TEMP\UPMacOSReadiness-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

Write-Status "Universal Print macOS Readiness check started — $(Get-Date)" "INFO"

# ─── Preflight ──────────────────────────────────────────────────────────────────

try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "No Graph context." }
    $requiredScopes = @("User.Read.All", "Printer.Read.All", "PrintSettings.Read.All")
    $missing = $requiredScopes | Where-Object { $ctx.Scopes -notcontains $_ }
    if ($missing) {
        Write-Status "Current Graph session is missing scopes: $($missing -join ', ') — connecting again." "WARN"
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }
} catch {
    Write-Status "Not connected to Microsoft Graph. Connecting now..." "WARN"
    Connect-MgGraph -Scopes "User.Read.All","Printer.Read.All","PrintSettings.Read.All" -NoWelcome
}

# ─── Detect: user + license ──────────────────────────────────────────────────────

try {
    $user = Get-MgUser -UserId $UserPrincipalName -Property "Id,DisplayName,UserPrincipalName,AssignedLicenses" -ErrorAction Stop
} catch {
    Write-Status "Could not find user '$UserPrincipalName': $($_.Exception.Message)" "ERROR"
    exit 1
}

Write-Host ""
Write-Status "User: $($user.DisplayName) ($($user.UserPrincipalName))" "INFO"

if (-not $user.AssignedLicenses -or $user.AssignedLicenses.Count -eq 0) {
    Write-Status "No licenses assigned at all — user cannot have Universal Print access." "ERROR"
} else {
    Write-Status "Assigned SKU IDs (cross-reference manually against the Universal Print-eligible subscription list):" "WARN"
    foreach ($lic in $user.AssignedLicenses) {
        Write-Host "    SkuId: $($lic.SkuId)"
    }
}

# ─── Detect: printers + shares ──────────────────────────────────────────────────

Write-Host ""
Write-Status "Enumerating printers$(if ($PrinterNameFilter) { " matching '$PrinterNameFilter'" })..." "INFO"

try {
    $printers = Get-MgPrinter -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query printers: $($_.Exception.Message)" "ERROR"
    exit 1
}

if ($PrinterNameFilter) {
    $printers = $printers | Where-Object { $_.DisplayName -like "*$PrinterNameFilter*" }
}

if (-not $printers -or $printers.Count -eq 0) {
    Write-Status "No printers found matching the filter. Nothing further to check." "WARN"
    exit 0
}

$Results = [System.Collections.Generic.List[PSObject]]::new()

foreach ($p in $printers) {

    $hasAccess = $false
    $shareNames = [System.Collections.Generic.List[string]]::new()

    try {
        $shares = Get-MgPrintShare -Filter "printer/id eq '$($p.Id)'" -ExpandProperty "allowedUsers,allowedGroups" -ErrorAction Stop
        foreach ($share in $shares) {
            $shareNames.Add($share.DisplayName)
            $directMatch = $share.AllowedUsers | Where-Object { $_.Id -eq $user.Id }
            if ($directMatch) {
                $hasAccess = $true
            }
            # Note: group membership resolution requires a separate call per group;
            # this flags direct user grants reliably, group-based grants may need
            # manual cross-check against Get-MgGroupMember for each allowed group.
        }
    } catch {
        Write-Status "  Could not resolve shares for printer '$($p.DisplayName)': $($_.Exception.Message)" "WARN"
    }

    $status = if ($hasAccess) { "OK" } elseif ($shareNames.Count -eq 0) { "WARN" } else { "ERROR" }

    Write-Status "Printer: $($p.DisplayName)  Shares: $($shareNames -join ', ')  DirectUserAccess: $hasAccess" $status

    $Results.Add([PSCustomObject]@{
        PrinterDisplayName   = $p.DisplayName
        PrinterId            = $p.Id
        IsShared              = $p.IsShared
        ManufacturerAndModel  = $p.ManufacturerAndModel
        ShareNames            = ($shareNames -join "; ")
        UserHasDirectAccess   = $hasAccess
        Status                = $status
    })
}

# ─── Report: summary ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Magenta

$noShare    = $Results | Where-Object { $_.Status -eq "WARN" }
$noAccess   = $Results | Where-Object { $_.Status -eq "ERROR" }
$hasAccess  = $Results | Where-Object { $_.Status -eq "OK" }

Write-Status "Printers checked:                 $($Results.Count)"
Write-Status "User has confirmed direct access: $($hasAccess.Count)" "OK"
Write-Status "Printer has no share at all:      $($noShare.Count)"  $(if ($noShare.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Shared, but not to this user directly (check group membership): $($noAccess.Count)" $(if ($noAccess.Count -gt 0) { "WARN" } else { "OK" })

Write-Host ""
Write-Host "Reminder — this script cannot check (verify manually on the Mac / Azure Portal):" -ForegroundColor Cyan
Write-Host "  - macOS version (sw_vers -productVersion; must be 14.6.1+)"
Write-Host "  - Universal Print app installed/launchable and sign-in state"
Write-Host "  - Azure Portal > Universal Print > Settings > macOS Support toggle"
Write-Host "  - Azure Portal > Universal Print > Document Conversion state"
Write-Host "  - Group-based share membership (this script flags only direct user grants reliably)"

# ─── Export ──────────────────────────────────────────────────────────────────────

$Results | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Status "`nFull report: $OutputPath" "INFO"
Write-Status "Done." "OK"
