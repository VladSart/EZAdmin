<#
.SYNOPSIS
    Audits Conditional Access policies that use Device Filters — flags mode/expression risk, orphaned
    extensionAttribute targeting, and Autopilot physicalIds coverage.

.DESCRIPTION
    Tenant-wide read-only audit that automates the manual checks in CA-Filters-B.md's Triage/Diagnosis
    flow and CA-Filters-A.md's Validation Steps, so an engineer doesn't have to open each policy in the
    portal and manually cross-reference device attributes one at a time.

    For every enabled or report-only CA policy with a device filter condition, flags:
    - EXCLUDE_ALL_MATCH    Exclude-mode filter whose rule matches zero devices in the tenant right now —
                            usually means the filter is dead weight (attribute never set) rather than an
                            active carve-out, per CA-Filters-A.md's "extensionAttributes are manual" note
    - INCLUDE_ZERO_MATCH   Include-mode filter matching zero devices — the policy currently applies to
                            nobody; either intentional staging or a silent misconfiguration
    - STALE_EXTATTR_TARGET Filter references extensionAttribute1-15 but no device in the tenant has that
                            attribute populated at all — the attribute was likely never rolled out via
                            Fix 1's bulk-tag pattern
    - REPORT_ONLY          Policy is still in enabledForReportingButNotEnforced — flagged as informational
                            so it isn't mistaken for an active control during an access-denied investigation
    - AUTOPILOT_FILTER_LOW_COVERAGE
                            Filter targets device.physicalIds ZTDID (Autopilot) but fewer than a configurable
                            percentage of tenant devices have physicalIds populated — suggests the filter
                            will under-match against the intended fleet

    Also produces a companion "orphaned extensionAttribute" report: any extensionAttribute value in active
    use by a CA filter that is not currently set on ANY device object, for proactive cleanup before the
    next fleet re-image cycle silently drops the attribute.

    Does NOT create, modify, enable, or disable any CA policy or device attribute — see CA-Filters-B.md
    Common Fix Paths / CA-Filters-A.md Remediation Playbooks for the corresponding fixes once a flagged
    policy is confirmed.

.PARAMETER PolicyName
    Optional filter — only audit CA policies whose display name matches this wildcard pattern.
    Default: all policies with a device filter condition.

.PARAMETER AutopilotCoverageWarningPercent
    If a policy's filter targets Autopilot physicalIds and fewer than this percentage of all devices in
    the tenant have any physicalIds populated, flag AUTOPILOT_FILTER_LOW_COVERAGE. Default: 50.

.PARAMETER OutputPath
    Path for CSV export of the full per-policy audit. Defaults to
    .\CADeviceFilterAudit_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-CADeviceFilterAudit.ps1

.EXAMPLE
    .\Get-CADeviceFilterAudit.ps1 -PolicyName "*PAW*" -AutopilotCoverageWarningPercent 60

.NOTES
    Requires: Microsoft.Graph.Authentication module.
    Requires Graph scopes: Policy.Read.All, Device.Read.All
    Safe: Yes — fully read-only against Microsoft Graph.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PolicyName = "*",

    [Parameter(Mandatory = $false)]
    [int]$AutopilotCoverageWarningPercent = 50,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\CADeviceFilterAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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

# ---------------------------------------------------------------------------
# PREFLIGHT
# ---------------------------------------------------------------------------
Write-Status "===== PREFLIGHT =====" "OK"
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Module 'Microsoft.Graph.Authentication' not found. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "ERROR"
    throw "Missing required module: Microsoft.Graph.Authentication"
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Microsoft Graph. Connecting..." "WARN"
        Connect-MgGraph -Scopes "Policy.Read.All", "Device.Read.All" | Out-Null
    }
    else {
        Write-Status "Connected to Graph as $($context.Account) (tenant $($context.TenantId))" "OK"
    }
}
catch {
    Write-Status "Failed to establish Graph connection: $($_.Exception.Message)" "ERROR"
    throw
}

# ---------------------------------------------------------------------------
# DETECT — policies with device filters
# ---------------------------------------------------------------------------
Write-Status "===== COLLECTING CA POLICIES WITH DEVICE FILTERS =====" "OK"
try {
    $allPolicies = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies").value
}
catch {
    Write-Status "Failed to query conditionalAccess/policies: $($_.Exception.Message)" "ERROR"
    throw
}

$filterPolicies = $allPolicies | Where-Object {
    $_.displayName -like $PolicyName -and $_.conditions.devices.deviceFilter.rule
}

if (-not $filterPolicies -or $filterPolicies.Count -eq 0) {
    Write-Status "No CA policies with a device filter condition found matching '$PolicyName'." "WARN"
    return
}
Write-Status "Found $($filterPolicies.Count) CA polic$(if ($filterPolicies.Count -eq 1) {'y'} else {'ies'}) with device filters." "OK"

# ---------------------------------------------------------------------------
# DETECT — full device inventory (for match/coverage checks)
# ---------------------------------------------------------------------------
Write-Status "Retrieving device inventory for filter-match evaluation (this may take a moment on large tenants)..."
try {
    $allDevices = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices?`$select=id,displayName,operatingSystem,trustType,isCompliant,isManaged,physicalIds,extensionAttributes&`$top=999").value
}
catch {
    Write-Status "Failed to query devices: $($_.Exception.Message)" "ERROR"
    throw
}
Write-Status "Retrieved $($allDevices.Count) device object(s)." "OK"

$totalDevices = [math]::Max($allDevices.Count, 1)
$devicesWithPhysicalIds = @($allDevices | Where-Object { $_.physicalIds -and $_.physicalIds.Count -gt 0 })
$autopilotCoveragePct = [math]::Round(($devicesWithPhysicalIds.Count / $totalDevices) * 100, 1)

# Build a set of extensionAttribute values actually populated across the fleet, keyed by attribute name
$extAttrPopulated = @{}
foreach ($i in 1..15) {
    $attrName = "extensionAttribute$i"
    $extAttrPopulated[$attrName] = @($allDevices | Where-Object {
        $_.extensionAttributes -and $_.extensionAttributes.$attrName
    }).Count
}

# ---------------------------------------------------------------------------
# EXECUTE — per-policy evaluation
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
$orphanedAttrs = [System.Collections.Generic.HashSet[string]]::new()

foreach ($policy in $filterPolicies) {
    $flags = [System.Collections.Generic.List[string]]::new()
    $filter = $policy.conditions.devices.deviceFilter
    $rule = [string]$filter.rule
    $mode = [string]$filter.mode

    if ($policy.state -eq "enabledForReportingButNotEnforced") {
        $flags.Add("REPORT_ONLY")
    }

    # Referenced extensionAttribute detection
    $referencedAttrs = [regex]::Matches($rule, "extensionAttribute(\d{1,2})") |
        ForEach-Object { "extensionAttribute$($_.Groups[1].Value)" } | Select-Object -Unique

    foreach ($attr in $referencedAttrs) {
        if ($extAttrPopulated.ContainsKey($attr) -and $extAttrPopulated[$attr] -eq 0) {
            $flags.Add("STALE_EXTATTR_TARGET:$attr")
            [void]$orphanedAttrs.Add($attr)
        }
    }

    # Autopilot physicalIds targeting + coverage check
    if ($rule -match "physicalIds" -and $rule -match "ZTDID") {
        if ($autopilotCoveragePct -lt $AutopilotCoverageWarningPercent) {
            $flags.Add("AUTOPILOT_FILTER_LOW_COVERAGE:${autopilotCoveragePct}pct")
        }
    }

    # Approximate match-count estimation for the two most common simple patterns:
    #   device.extensionAttributeN -eq "value"   and   device.physicalIds -any (_ -startsWith "[ZTDID]")
    $estimatedMatches = $null
    $eqMatch = [regex]::Match($rule, 'extensionAttribute(\d{1,2})\s*-eq\s*"([^"]+)"')
    if ($eqMatch.Success) {
        $attrName = "extensionAttribute$($eqMatch.Groups[1].Value)"
        $value = $eqMatch.Groups[2].Value
        $estimatedMatches = @($allDevices | Where-Object {
            $_.extensionAttributes -and $_.extensionAttributes.$attrName -eq $value
        }).Count
    }
    elseif ($rule -match "physicalIds" -and $rule -match "ZTDID") {
        $estimatedMatches = $devicesWithPhysicalIds.Count
    }

    if ($null -ne $estimatedMatches) {
        if ($mode -eq "exclude" -and $estimatedMatches -eq 0) {
            $flags.Add("EXCLUDE_ALL_MATCH")
        }
        elseif ($mode -eq "include" -and $estimatedMatches -eq 0) {
            $flags.Add("INCLUDE_ZERO_MATCH")
        }
    }

    $results.Add([PSCustomObject]@{
        PolicyName        = $policy.displayName
        PolicyId          = $policy.id
        State             = $policy.state
        FilterMode        = $mode
        FilterRule        = $rule
        EstimatedMatches  = $estimatedMatches
        ReferencedExtAttrs = ($referencedAttrs -join "; ")
        Flags             = ($flags -join "; ")
    })
}

# ---------------------------------------------------------------------------
# VALIDATE / REPORT
# ---------------------------------------------------------------------------
$flagged = @($results | Where-Object { $_.Flags -ne "" })

Write-Host ""
Write-Status "===== CA DEVICE FILTER AUDIT SUMMARY =====" "OK"
Write-Status "Total device-filter policies audited: $($results.Count)"
Write-Status "Devices in tenant: $totalDevices | With physicalIds (Autopilot): $($devicesWithPhysicalIds.Count) ($autopilotCoveragePct%)"
Write-Status "Flagged policies: $($flagged.Count)" $(if ($flagged.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "  EXCLUDE_ALL_MATCH:              $(@($results | Where-Object {$_.Flags -like '*EXCLUDE_ALL_MATCH*'}).Count)"
Write-Status "  INCLUDE_ZERO_MATCH:              $(@($results | Where-Object {$_.Flags -like '*INCLUDE_ZERO_MATCH*'}).Count)"
Write-Status "  STALE_EXTATTR_TARGET:            $(@($results | Where-Object {$_.Flags -like '*STALE_EXTATTR_TARGET*'}).Count)"
Write-Status "  AUTOPILOT_FILTER_LOW_COVERAGE:   $(@($results | Where-Object {$_.Flags -like '*AUTOPILOT_FILTER_LOW_COVERAGE*'}).Count)"
Write-Status "  REPORT_ONLY (informational):     $(@($results | Where-Object {$_.Flags -like '*REPORT_ONLY*'}).Count)"

if ($flagged.Count -gt 0) {
    $flagged | Format-Table PolicyName, FilterMode, EstimatedMatches, Flags -AutoSize -Wrap
}

if ($orphanedAttrs.Count -gt 0) {
    Write-Host ""
    Write-Status "Orphaned extensionAttributes referenced by CA filters but set on zero devices: $($orphanedAttrs -join ', ')" "WARN"
    Write-Status "See CA-Filters-A.md Fix 1 for the bulk-tag pattern to populate these before relying on the filter." "INFO"
}

try {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Full report exported to: $OutputPath" "OK"
}
catch {
    Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
}

Write-Status "Done." "OK"
