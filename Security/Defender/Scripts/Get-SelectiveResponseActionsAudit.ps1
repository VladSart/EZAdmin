<#
.SYNOPSIS
    Audits Microsoft Defender for Endpoint device population for Selective Response
    Actions (restricted security operations) state — which devices are Restricted vs
    Full, which capability categories are limited, and tenant-level feature readiness.

.DESCRIPTION
    Selective Response Actions has no dedicated configuration cmdlet or Graph write
    surface — the mode is set once at onboarding via the Defender deployment tool (DDT)
    and cannot be changed in place. This script is scoped honestly around what is
    actually confirmed-readable via Microsoft Graph:

    - Tenant-wide device inventory via /security/machines (or /machines depending on
      API version reachable in the tenant), surfacing each device's onboarding status
    - Best-effort restriction-state read via Advanced Hunting (runHuntingQuery against
      DeviceInfo's RestrictedDeviceSecurityOperations column), since no dedicated
      /machines property for this exists in the general Machine resource as of this
      writing
    - A per-device summary of which capability category (if any) is limited

    It does NOT and cannot: enable/disable the tenant feature switch (portal-only,
    Settings > Endpoints > Advanced features), generate or apply a DDT onboarding
    package, change an already-onboarded device's restriction state (no write surface
    exists — requires offboard + re-onboard per Microsoft's own documented procedure),
    or read the tenant feature-switch state itself (not exposed via Graph; verify
    manually in the portal).

    Requires: Microsoft.Graph.Authentication module, and an app/delegated identity with
    Machine.Read.All and ThreatHunting.Read.All scopes.

.PARAMETER LookbackDays
    How many days of DeviceInfo history to scan via Advanced Hunting when resolving
    restriction state per device. Default: 3 (DeviceInfo is a near-daily snapshot
    table; 3 days gives resilience against a missed daily heartbeat without going stale).

.PARAMETER DeviceName
    Optional. Filter results to a single device by name (case-insensitive, partial match).

.PARAMETER ExportPath
    Full path for CSV export of the per-device restriction inventory. Defaults to
    $env:TEMP\SelectiveResponseActions-Audit-<date>.csv.

.PARAMETER SkipHuntingQuery
    Skip the Advanced Hunting call (useful if ThreatHunting.Read.All is not granted —
    the script will still report basic device inventory without restriction detail).

.EXAMPLE
    .\Get-SelectiveResponseActionsAudit.ps1
    Audits all onboarded devices tenant-wide and exports a CSV.

.EXAMPLE
    .\Get-SelectiveResponseActionsAudit.ps1 -DeviceName "DC01" -LookbackDays 7

.NOTES
    Read-only. Does not modify onboarding state, tenant settings, or any device.
    Run as an account with the Graph scopes above (interactive or app-only).
    No PowerShell/Graph write cmdlet exists for this feature as of this writing —
    changes require the Defender portal (package generation) and standard MDE
    offboard/re-onboard procedures.
#>
[CmdletBinding()]
param(
    [int]$LookbackDays = 3,
    [string]$DeviceName,
    [string]$ExportPath = "$env:TEMP\SelectiveResponseActions-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    [switch]$SkipHuntingQuery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Selective Response Actions audit starting (lookback: $LookbackDays days)" "INFO"

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "ERROR"
    return
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Microsoft Graph. Connecting with required scopes..." "WARN"
        Connect-MgGraph -Scopes "Machine.Read.All", "ThreatHunting.Read.All" -NoWelcome
    }
    else {
        Write-Status "Connected to Graph as $($context.Account) (tenant: $($context.TenantId))" "OK"
    }
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ---------------------------------------------------------------------------
# Step 1 — Device inventory (best-effort onboarding-status baseline)
# ---------------------------------------------------------------------------
Write-Status "Pulling device inventory from Microsoft Graph Security API..." "INFO"

$devices = [System.Collections.Generic.List[object]]::new()
try {
    $uri = "https://graph.microsoft.com/v1.0/security/machines?`$top=999"
    if ($DeviceName) {
        $uri += "&`$filter=contains(computerDnsName,'$DeviceName')"
    }
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        foreach ($m in $response.value) { $devices.Add($m) }
        $uri = $response.'@odata.nextLink'
    } while ($uri)
    Write-Status "Retrieved $($devices.Count) device record(s)." "OK"
}
catch {
    Write-Status "Device inventory read failed — the /security/machines endpoint availability varies by tenant API version. Error: $($_.Exception.Message)" "WARN"
    Write-Status "Continuing with Advanced Hunting only, if not skipped." "WARN"
}

# ---------------------------------------------------------------------------
# Step 2 — Restriction state via Advanced Hunting (DeviceInfo.RestrictedDeviceSecurityOperations)
# ---------------------------------------------------------------------------
$restrictionMap = @{}

if (-not $SkipHuntingQuery) {
    Write-Status "Querying Advanced Hunting for restriction state (DeviceInfo)..." "INFO"

    $kql = @"
DeviceInfo
| where Timestamp > ago(${LookbackDays}d)
| summarize arg_max(Timestamp, DeviceName, RestrictedDeviceSecurityOperations) by DeviceId
| project DeviceId, DeviceName, RestrictedDeviceSecurityOperations, Timestamp
"@

    try {
        $body = @{ Query = $kql } | ConvertTo-Json
        $huntResult = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/security/runHuntingQuery" `
            -Body $body -ContentType "application/json"

        foreach ($row in $huntResult.results) {
            $restrictionMap[$row.DeviceId] = [PSCustomObject]@{
                DeviceName             = $row.DeviceName
                RestrictedCapabilities = $row.RestrictedDeviceSecurityOperations
                SnapshotTimestamp      = $row.Timestamp
            }
        }
        Write-Status "Resolved restriction state for $($restrictionMap.Count) device(s) via Advanced Hunting." "OK"
    }
    catch {
        Write-Status "Advanced Hunting query failed (check ThreatHunting.Read.All scope). Error: $($_.Exception.Message)" "WARN"
        Write-Status "Falling back to inventory-only output — restriction detail will show as 'Unknown'." "WARN"
    }
}
else {
    Write-Status "Skipping Advanced Hunting query per -SkipHuntingQuery." "INFO"
}

# ---------------------------------------------------------------------------
# Step 3 — Build combined report
# ---------------------------------------------------------------------------
$report = [System.Collections.Generic.List[object]]::new()

if ($devices.Count -gt 0) {
    foreach ($d in $devices) {
        $restriction = $restrictionMap[$d.id]
        $isRestricted = $null -ne $restriction -and -not [string]::IsNullOrWhiteSpace($restriction.RestrictedCapabilities)

        $report.Add([PSCustomObject]@{
            DeviceName             = $d.computerDnsName
            DeviceId               = $d.id
            SecurityOperationsMode = if ($restriction) { if ($isRestricted) { "Restricted" } else { "Full" } } else { "Unknown (no AH data)" }
            RestrictedCapabilities = if ($restriction) { $restriction.RestrictedCapabilities } else { "N/A" }
            OSPlatform             = $d.osPlatform
            LastSeen               = $d.lastSeen
            SnapshotTimestamp      = if ($restriction) { $restriction.SnapshotTimestamp } else { $null }
        })
    }
}
elseif ($restrictionMap.Count -gt 0) {
    # Inventory call failed but Advanced Hunting succeeded — report from AH alone
    foreach ($id in $restrictionMap.Keys) {
        $r = $restrictionMap[$id]
        $isRestricted = -not [string]::IsNullOrWhiteSpace($r.RestrictedCapabilities)
        $report.Add([PSCustomObject]@{
            DeviceName             = $r.DeviceName
            DeviceId               = $id
            SecurityOperationsMode = if ($isRestricted) { "Restricted" } else { "Full" }
            RestrictedCapabilities = if ($isRestricted) { $r.RestrictedCapabilities } else { "N/A" }
            OSPlatform             = "Unknown (inventory call failed)"
            LastSeen               = $null
            SnapshotTimestamp      = $r.SnapshotTimestamp
        })
    }
}
else {
    Write-Status "No data retrieved from either source — nothing to report." "ERROR"
    return
}

# ---------------------------------------------------------------------------
# Step 4 — Report + export
# ---------------------------------------------------------------------------
$restrictedCount = ($report | Where-Object { $_.SecurityOperationsMode -eq "Restricted" }).Count
$fullCount       = ($report | Where-Object { $_.SecurityOperationsMode -eq "Full" }).Count
$unknownCount    = ($report | Where-Object { $_.SecurityOperationsMode -like "Unknown*" }).Count

Write-Status "Summary: $restrictedCount Restricted, $fullCount Full, $unknownCount Unknown (of $($report.Count) devices)" "INFO"

if ($restrictedCount -gt 0) {
    Write-Status "Restricted-mode devices found — remember: capability changes require offboard + re-onboard, no in-place edit exists." "WARN"
}

$report | Sort-Object SecurityOperationsMode, DeviceName | Format-Table -AutoSize

$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Exported full report to $ExportPath" "OK"

Write-Status "Note: tenant feature-switch state (Advanced features > 'Allow restricted security operations during onboarding') is not exposed via Graph — verify manually in the Defender portal if needed." "INFO"
