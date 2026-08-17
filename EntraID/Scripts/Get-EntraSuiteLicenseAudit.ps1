<#
.SYNOPSIS
    Audits a tenant's Microsoft Entra Suite / Global Secure Access licensing posture — what's
    purchased, what's assigned, and rough utilization signal for cost-allocation conversations.

.DESCRIPTION
    Read-only Microsoft Graph script for MSP licensing/cost-review engagements. Covers:
      - Tenant-wide inventory of Entra ID P1/P2, Entra Suite, and standalone Internet
        Access/Private Access SKUs, with consumed vs. enabled unit counts
      - Confirms the mandatory P1/P2 base is present before any Suite/standalone capability
        can function at all
      - Per-user Suite/standalone license assignment breakdown, split by UserType
        (Member vs. Guest, since guest GSA billing follows a Monthly Active User model
        rather than seat assignment)
      - Combined P1/P2 + Internet Access license count against the documented 50-license
        floor required for remote network (branch connectivity) to be enabled at all
      - Optional (-IncludeSignInActivity) cross-reference of Suite-licensed users against
        recent Global Secure Access Client sign-in activity, to approximate the
        "licensed but not actually using GSA" cohort that drives Suite over-licensing

    Does NOT cover:
      - Actual billing/invoice data (Graph does not expose real-time cost; this script reports
        license counts and assignment/activity signal only, not dollar amounts)
      - Guest MAU billing reconciliation (guest billing is usage-metered and reconciled by
        Microsoft directly — this script's sign-in-log cross-reference is a best-effort proxy,
        not an authoritative billing source)
      - Any license assignment, removal, or purchase action — fully read-only

.PARAMETER IncludeSignInActivity
    If set, cross-references Suite/standalone-licensed users against recent sign-in logs
    filtered to the Global Secure Access Client application, to flag licensed-but-inactive
    users. Requires the AuditLog.Read.All scope in addition to the base scopes.

.PARAMETER SignInLookbackDays
    Number of days of sign-in history to check when -IncludeSignInActivity is used.
    Defaults to 30.

.PARAMETER OutputPath
    Directory to write CSV exports to. Defaults to C:\EntraSuiteLicenseAudit_<timestamp>.

.EXAMPLE
    .\Get-EntraSuiteLicenseAudit.ps1
    Runs the base license inventory and per-user assignment audit.

.EXAMPLE
    .\Get-EntraSuiteLicenseAudit.ps1 -IncludeSignInActivity -SignInLookbackDays 60
    Also cross-references licensed users against 60 days of GSA Client sign-in activity.

.NOTES
    Requires: Microsoft.Graph PowerShell SDK, connected via Connect-MgGraph with at minimum
    User.Read.All and Organization.Read.All scopes (add AuditLog.Read.All for -IncludeSignInActivity).
    Run-as: Any account with directory read access to licenses, users, and (optionally) sign-in logs.
    Safe/unsafe: Fully read-only. No license assignment, removal, or tenant configuration is modified.
#>

[CmdletBinding()]
param(
    [switch]$IncludeSignInActivity,
    [int]$SignInLookbackDays = 30,
    [string]$OutputPath = "C:\EntraSuiteLicenseAudit_$(Get-Date -Format 'yyyyMMdd_HHmm')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
try {
    $context = Get-MgContext
    if (-not $context) { throw "Not connected." }
} catch {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'User.Read.All','Organization.Read.All' first (add 'AuditLog.Read.All' if using -IncludeSignInActivity)." "ERROR"
    exit 1
}

$requiredScopes = @("User.Read.All", "Organization.Read.All")
if ($IncludeSignInActivity) { $requiredScopes += "AuditLog.Read.All" }
$missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes }
if ($missingScopes) {
    Write-Status "Missing required scope(s): $($missingScopes -join ', '). Re-run Connect-MgGraph with these scopes included." "ERROR"
    exit 1
}

try {
    New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Status "Could not create output directory '$OutputPath': $($_.Exception.Message)" "ERROR"
    exit 1
}

Write-Status "Microsoft Entra Suite / Global Secure Access license audit starting..." "INFO"

$findings = New-Object System.Collections.Generic.List[Object]
function Add-Finding {
    param([string]$Area, [string]$Status, [string]$Detail)
    $findings.Add([PSCustomObject]@{ Area = $Area; Status = $Status; Detail = $Detail })
}

# ---------------------------------------------------------------------------
# 1. Tenant-wide SKU inventory
# ---------------------------------------------------------------------------
Write-Status "Enumerating subscribed SKUs..." "INFO"
$skus = Get-MgSubscribedSku -All | Select-Object SkuPartNumber, SkuId, ConsumedUnits,
    @{N = 'Enabled'; E = { $_.PrepaidUnits.Enabled } },
    @{N = 'Suspended'; E = { $_.PrepaidUnits.Suspended } }

$skus | Export-Csv (Join-Path $OutputPath "tenant-skus.csv") -NoTypeInformation

$p1p2Skus       = $skus | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM" }
$suiteSkus      = $skus | Where-Object { $_.SkuPartNumber -match "ENTRA_SUITE|ENTRAID_SUITE" }
$internetAccess = $skus | Where-Object { $_.SkuPartNumber -match "ENTRA_INTERNET_ACCESS|INTERNET_ACCESS" }
$privateAccess  = $skus | Where-Object { $_.SkuPartNumber -match "ENTRA_PRIVATE_ACCESS|PRIVATE_ACCESS" }

if ($p1p2Skus) {
    $p1p2Total = ($p1p2Skus | Measure-Object -Property Enabled -Sum).Sum
    Add-Finding "Base License" "OK" "Entra ID P1/P2 present — $p1p2Total total enabled units across $($p1p2Skus.Count) SKU(s). This is the mandatory base for all GSA/Suite capability."
} else {
    Add-Finding "Base License" "ERROR" "No Entra ID P1/P2 SKU found in this tenant. No GSA/Suite capability can function without this base license, regardless of any other SKU present."
}

if ($suiteSkus) {
    $suiteTotal = ($suiteSkus | Measure-Object -Property Enabled -Sum).Sum
    $suiteConsumed = ($suiteSkus | Measure-Object -Property ConsumedUnits -Sum).Sum
    Add-Finding "Suite License" "OK" "Microsoft Entra Suite present — $suiteConsumed of $suiteTotal enabled units consumed."
} else {
    Add-Finding "Suite License" "INFO" "No Microsoft Entra Suite SKU found. Tenant may be using standalone Internet Access/Private Access add-ons instead, or may have no GSA-beyond-P1/P2 capability at all."
}

if ($internetAccess) {
    Add-Finding "Internet Access (standalone)" "OK" "Standalone Microsoft Entra Internet Access SKU present — $(($internetAccess | Measure-Object -Property ConsumedUnits -Sum).Sum) of $(($internetAccess | Measure-Object -Property Enabled -Sum).Sum) enabled units consumed."
}
if ($privateAccess) {
    Add-Finding "Private Access (standalone)" "OK" "Standalone Microsoft Entra Private Access SKU present — $(($privateAccess | Measure-Object -Property ConsumedUnits -Sum).Sum) of $(($privateAccess | Measure-Object -Property Enabled -Sum).Sum) enabled units consumed."
}

if (-not $suiteSkus -and -not $internetAccess -and -not $privateAccess) {
    Add-Finding "GSA Capability" "WARN" "No Suite, Internet Access, or Private Access SKU found anywhere in the tenant. Only the free P1/P2-included Microsoft-traffic forwarding profile is available — full Internet Access (SWG) and Private Access (ZTNA) capability requires a purchase."
}

# ---------------------------------------------------------------------------
# 2. Remote network 50-license combined floor check
# ---------------------------------------------------------------------------
$combinedFloor = 0
if ($p1p2Skus) { $combinedFloor += ($p1p2Skus | Measure-Object -Property Enabled -Sum).Sum }
if ($internetAccess) { $combinedFloor += ($internetAccess | Measure-Object -Property Enabled -Sum).Sum }

if ($combinedFloor -ge 50) {
    Add-Finding "Remote Network Floor" "OK" "Combined P1/P2 + Internet Access enabled units = $combinedFloor (>= 50 required for remote network/branch connectivity to be enabled)."
} else {
    Add-Finding "Remote Network Floor" "WARN" "Combined P1/P2 + Internet Access enabled units = $combinedFloor — BELOW the documented 50-license floor. Remote network (branch connectivity) cannot be enabled until this tenant crosses that combined threshold."
}

# ---------------------------------------------------------------------------
# 3. Per-user license assignment, split by UserType
# ---------------------------------------------------------------------------
Write-Status "Enumerating per-user license assignment (this may take a while in large tenants)..." "INFO"

$targetSkuIds = @()
$targetSkuIds += $suiteSkus.SkuId
$targetSkuIds += $internetAccess.SkuId
$targetSkuIds += $privateAccess.SkuId

$licensedUsers = @()
if ($targetSkuIds.Count -gt 0) {
    $allUsers = Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, UserType, AssignedLicenses
    $licensedUsers = $allUsers | Where-Object {
        $userSkuIds = $_.AssignedLicenses.SkuId
        ($userSkuIds | Where-Object { $_ -in $targetSkuIds }).Count -gt 0
    } | Select-Object DisplayName, UserPrincipalName, UserType,
        @{N = 'AssignedGSASkuCount'; E = { ($_.AssignedLicenses.SkuId | Where-Object { $_ -in $targetSkuIds }).Count } }

    $licensedUsers | Export-Csv (Join-Path $OutputPath "gsa-suite-licensed-users.csv") -NoTypeInformation

    $memberCount = ($licensedUsers | Where-Object UserType -eq "Member").Count
    $guestCount  = ($licensedUsers | Where-Object UserType -eq "Guest").Count

    Add-Finding "User Assignment" "OK" "$($licensedUsers.Count) user(s) hold a Suite/Internet Access/Private Access license — $memberCount Member, $guestCount Guest."
    if ($guestCount -gt 0) {
        Add-Finding "Guest Billing" "WARN" "$guestCount guest(s) hold a per-seat-style license assignment for a GSA-related SKU. Remember guest GSA billing is Monthly-Active-User-based, not assignment-based — a formal assignment does not by itself determine what's billed. Cross-reference against actual sign-in activity (see -IncludeSignInActivity) before drawing cost conclusions."
    }
} else {
    Add-Finding "User Assignment" "INFO" "No Suite/Internet Access/Private Access SKU present in the tenant — skipping per-user assignment breakdown."
}

# ---------------------------------------------------------------------------
# 4. Optional: cross-reference against recent GSA Client sign-in activity
# ---------------------------------------------------------------------------
if ($IncludeSignInActivity -and $licensedUsers.Count -gt 0) {
    Write-Status "Cross-referencing licensed users against $SignInLookbackDays days of Global Secure Access Client sign-in activity..." "INFO"
    try {
        $startDate = (Get-Date).AddDays(-$SignInLookbackDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $filter = "createdDateTime ge $startDate and appDisplayName eq 'Global Secure Access Client'"
        $signIns = Get-MgAuditLogSignIn -Filter $filter -All -ErrorAction Stop
        $activeUpns = $signIns | Select-Object -ExpandProperty UserPrincipalName -Unique

        $inactiveLicensed = $licensedUsers | Where-Object { $_.UserPrincipalName -notin $activeUpns }
        $inactiveLicensed | Export-Csv (Join-Path $OutputPath "licensed-but-inactive-gsa-users.csv") -NoTypeInformation

        if ($inactiveLicensed.Count -gt 0) {
            $pct = [math]::Round(($inactiveLicensed.Count / $licensedUsers.Count) * 100, 1)
            Add-Finding "Utilization" "WARN" "$($inactiveLicensed.Count) of $($licensedUsers.Count) licensed users ($pct%) show NO Global Secure Access Client sign-in in the last $SignInLookbackDays days — see licensed-but-inactive-gsa-users.csv. This is the cohort most relevant to a Suite-vs-standalone-vs-base-only allocation review."
        } else {
            Add-Finding "Utilization" "OK" "All licensed users show recent Global Secure Access Client sign-in activity within the lookback window."
        }
    } catch {
        Add-Finding "Utilization" "WARN" "Could not query sign-in logs: $($_.Exception.Message). Confirm AuditLog.Read.All scope is granted."
    }
} elseif ($IncludeSignInActivity) {
    Write-Status "No GSA/Suite-licensed users found — skipping sign-in activity cross-reference." "INFO"
}

# ---------------------------------------------------------------------------
# Summary + export
# ---------------------------------------------------------------------------
$findings | Export-Csv (Join-Path $OutputPath "license-audit-summary.csv") -NoTypeInformation

Write-Host ""
Write-Status "=== Summary ===" "INFO"
$findings | ForEach-Object {
    Write-Status "$($_.Area): $($_.Detail)" $_.Status
}

$errorCount = ($findings | Where-Object Status -eq "ERROR").Count
$warnCount  = ($findings | Where-Object Status -eq "WARN").Count

Write-Host ""
if ($errorCount -gt 0) {
    Write-Status "$errorCount blocking finding(s) — see summary above." "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "$warnCount finding(s) worth review — see summary above." "WARN"
} else {
    Write-Status "No blocking or notable findings." "OK"
}

Write-Status "Full results written to: $OutputPath" "INFO"
Write-Status "NOTE: this script reports license counts and assignment/activity signal only — it does not report actual billed cost. Guest GSA billing in particular is Monthly-Active-User-metered by Microsoft directly; treat the sign-in cross-reference as a proxy, not an authoritative billing figure." "INFO"
