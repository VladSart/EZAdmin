<#
.SYNOPSIS
    Audits Microsoft Defender predictive shielding activity — active hardening actions
    (GPO Hardening, SafeBoot Hardening, Contain User), the incidents that triggered them,
    and tenant-level readiness (licensing, feature enablement).

.DESCRIPTION
    Predictive shielding (Preview, as of this writing) has no dedicated configuration
    cmdlet or Graph endpoint of its own — it is an autonomous extension of automatic
    attack disruption with no admin-authored policy object. This script is therefore
    scoped honestly around what is actually confirmed-readable:

    - Tenant licensing readiness (Defender for Endpoint Plan 2 / Defender for Business SKU presence)
    - Recent security incidents via Microsoft Graph Security API (/security/incidents)
    - Advanced Hunting query execution via the Graph Security API's runHuntingQuery action,
      against the DisruptionAndResponseEvents table, for GpoPrevention/SafebootPrevention
      policy state and block events

    It does NOT and cannot: read the "Predictive Shielding" tag directly (tag-based
    incident filtering is a portal UI feature, not a documented Graph query filter —
    this script instead returns recent incidents and leaves tag correlation to the
    operator via the portal), enable/disable/configure predictive shielding (no
    documented write surface exists), or undo a hardening action (portal/Action-center
    only, per Microsoft's own documentation).

    Requires: Microsoft.Graph.Authentication module, and an app/delegated identity with
    SecurityEvents.Read.All, ThreatHunting.Read.All, and Organization.Read.All scopes.

.PARAMETER DeviceId
    Optional. Filter Advanced Hunting results to a specific MDE DeviceId.

.PARAMETER LookbackDays
    How many days back to query for incidents and hardening events. Default: 7.

.PARAMETER ExportPath
    Full path for CSV export of hardening events found. Defaults to
    $env:TEMP\PredictiveShielding-Audit-<date>.csv.

.PARAMETER SkipHuntingQuery
    Skip the Advanced Hunting call (useful if ThreatHunting.Read.All is not granted —
    the script will still return licensing and incident-list data).

.EXAMPLE
    # Full tenant sweep, last 7 days
    .\Get-PredictiveShieldingAudit.ps1

.EXAMPLE
    # Check a specific device, last 30 days
    .\Get-PredictiveShieldingAudit.ps1 -DeviceId "a1b2c3d4e5f6..." -LookbackDays 30

.EXAMPLE
    # Licensing/incident check only, no hunting query permission available
    .\Get-PredictiveShieldingAudit.ps1 -SkipHuntingQuery

.NOTES
    Read-only. Makes no configuration changes and cannot undo any predictive shielding
    action — undo is portal/Action-center-only per Microsoft's current documentation.
    Run as any account with the Graph scopes above; no local admin/RunAsAdministrator
    requirement, since this is a cloud-API-only script.
#>

[CmdletBinding()]
param(
    [string]$DeviceId,

    [int]$LookbackDays = 7,

    [string]$ExportPath = "$env:TEMP\PredictiveShielding-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    [switch]$SkipHuntingQuery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Predictive Shielding audit starting — lookback: $LookbackDays day(s)"

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "ERROR"
    return
}

$scopes = @("SecurityEvents.Read.All", "Organization.Read.All")
if (-not $SkipHuntingQuery) { $scopes += "ThreatHunting.Read.All" }

try {
    Connect-MgGraph -Scopes $scopes -NoWelcome -ErrorAction Stop
    Write-Status "Connected to Microsoft Graph" "OK"
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ---------------------------------------------------------------------------
# 1. Licensing readiness — Defender for Endpoint Plan 2 / Defender for Business
# ---------------------------------------------------------------------------
Write-Status "Checking Defender for Endpoint / Defender for Business licensing..."

$relevantSkuPattern = "DEFENDER|ATP|MDATP|EMSPREMIUM|SPE_E5|SPE_F5_SECCOMP|DFB|MICROSOFT_365_E5_SECURITY"
$licenseFound = $false

try {
    $skus = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/subscribedSkus" -ErrorAction Stop
    $relevantSkus = $skus.value | Where-Object { $_.skuPartNumber -match $relevantSkuPattern }

    if ($relevantSkus) {
        $licenseFound = $true
        Write-Status "Qualifying license SKU(s) found — predictive shielding is licensable in this tenant" "OK"
        $relevantSkus | ForEach-Object {
            [PSCustomObject]@{
                SkuPartNumber = $_.skuPartNumber
                ConsumedUnits = $_.consumedUnits
                PrepaidUnits  = $_.prepaidUnits.enabled
            }
        } | Format-Table -AutoSize
    } else {
        Write-Status "No SKU matched the expected Defender for Endpoint P2 / Defender for Business pattern. Verify manually — SKU naming varies and this pattern match is a best-effort heuristic, not an authoritative license check." "WARN"
    }
} catch {
    Write-Status "Could not read subscribedSkus: $($_.Exception.Message)" "WARN"
}

# ---------------------------------------------------------------------------
# 2. Recent security incidents (tag-based "Predictive Shielding" filtering is
#    portal-UI-only — this returns recent incidents for manual/visual cross-
#    reference against the portal's tag filter, not an authoritative tag match)
# ---------------------------------------------------------------------------
Write-Status "Retrieving recent security incidents (last $LookbackDays day(s))..."

$sinceDate = (Get-Date).AddDays(-$LookbackDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
$incidents = @()

try {
    $uri = "https://graph.microsoft.com/v1.0/security/incidents?`$filter=createdDateTime ge $sinceDate&`$top=50&`$orderby=createdDateTime desc"
    $result = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    $incidents = $result.value

    if ($incidents.Count -gt 0) {
        Write-Status "$($incidents.Count) incident(s) found in the lookback window — cross-check each against the portal's 'Predictive Shielding' tag filter to confirm relevance" "OK"
        $incidents | Select-Object id, displayName, severity, status, createdDateTime |
            Sort-Object createdDateTime -Descending | Format-Table -AutoSize
    } else {
        Write-Status "No incidents found in the lookback window." "OK"
    }
} catch {
    Write-Status "Could not read security incidents: $($_.Exception.Message)" "WARN"
}

# ---------------------------------------------------------------------------
# 3. Advanced Hunting — GPO/SafeBoot hardening policy state and block events
# ---------------------------------------------------------------------------
$hardeningEvents = @()

if (-not $SkipHuntingQuery) {
    Write-Status "Running Advanced Hunting query against DisruptionAndResponseEvents..."

    $deviceFilter = if ($DeviceId) { "| where DeviceId == `"$DeviceId`"" } else { "" }

    $kql = @"
DisruptionAndResponseEvents
| where PolicyName in ("GpoPrevention","SafebootPrevention")
| where Timestamp > ago(${LookbackDays}d)
$deviceFilter
| project Timestamp, DeviceId, DeviceName, PolicyName, ReportType, IsPolicyOn, DomainName
| order by Timestamp desc
"@

    $body = @{ Query = $kql } | ConvertTo-Json

    try {
        $huntResult = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/security/runHuntingQuery" -Body $body -ContentType "application/json" -ErrorAction Stop
        $hardeningEvents = $huntResult.results

        if ($hardeningEvents -and $hardeningEvents.Count -gt 0) {
            Write-Status "$($hardeningEvents.Count) hardening-related event(s) found" "OK"

            $activePolicies = $hardeningEvents | Where-Object { $_.ReportType -eq "PolicyUpdated" -and $_.IsPolicyOn -eq "1" }
            $blockedEvents  = $hardeningEvents | Where-Object { $_.ReportType -eq "Prevented" }

            if ($activePolicies) {
                Write-Status "$($activePolicies.Count) device(s) currently show an ACTIVE hardening policy:" "WARN"
                $activePolicies | Select-Object Timestamp, DeviceName, DeviceId, PolicyName | Format-Table -AutoSize
            }

            if ($blockedEvents) {
                Write-Status "$($blockedEvents.Count) actual BLOCK event(s) recorded (the control fired, not just configured):" "WARN"
                $blockedEvents | Select-Object Timestamp, DeviceName, DeviceId, PolicyName | Format-Table -AutoSize
            }

            $hardeningEvents | Export-Csv -Path $ExportPath -NoTypeInformation
            Write-Status "Hardening event detail exported to: $ExportPath" "OK"
        } else {
            Write-Status "No GPO/SafeBoot hardening events found in the lookback window — no predictive shielding hardening currently active or recently triggered." "OK"
        }
    } catch {
        Write-Status "Advanced Hunting query failed: $($_.Exception.Message). Confirm ThreatHunting.Read.All scope is granted, or re-run with -SkipHuntingQuery." "WARN"
    }
} else {
    Write-Status "Skipping Advanced Hunting query (-SkipHuntingQuery specified)." "INFO"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "===== SUMMARY =====" "INFO"
Write-Status "Licensing:            $(if ($licenseFound) { 'Qualifying SKU found' } else { 'NOT CONFIRMED — verify manually' })" $(if ($licenseFound) { "OK" } else { "WARN" })
Write-Status "Incidents (window):   $($incidents.Count)"
if (-not $SkipHuntingQuery) {
    Write-Status "Hardening events:     $($hardeningEvents.Count)"
}
Write-Status "Manual step required: cross-reference incidents above against security.microsoft.com > Incidents, filtered by the 'Predictive Shielding' tag — tag-level filtering is not exposed via Graph as of this writing." "WARN"
Write-Status "Reminder: this script cannot undo any hardening action. Undo is portal/Action-center-only — see PredictiveShielding-B.md Fix 5." "INFO"
