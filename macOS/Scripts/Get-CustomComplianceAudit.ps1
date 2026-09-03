<#
.SYNOPSIS
    Admin-side Graph audit of Intune Custom Compliance Settings for macOS devices.

.DESCRIPTION
    Custom Compliance Settings (JSON rules + a platform-specific discovery script) shipped
    first for Windows, then Linux, and are now documented as supporting macOS as a third
    platform. This script is a READ-ONLY reporting aid for admins auditing macOS custom
    compliance coverage across a tenant. It does NOT and CANNOT:
      - Run or validate discovery script content or logic
      - Confirm a script's Bash exit code or STDOUT JSON is well-formed (that requires
        running the script on a real Mac — see the companion runbook's Validation Steps)
      - Distinguish "Error" states caused by exit-code failures from those caused by
        malformed JSON — Intune's compliance state does not separate these at the API level

    What it DOES do:
      - Enumerates macOS-targeted compliance policies and flags which ones reference
        custom compliance settings (heuristic: policy contains a scheduled/custom rule
        reference) vs. built-in-only policies
      - Reports per-device compliance state for macOS devices, filtered to policies with
        custom settings, to give a fleet-wide view of Error/NonCompliant/Compliant counts
      - Flags devices stuck in "Unknown"/"Not evaluated" beyond a configurable staleness
        threshold, which is the most common signal of an agent-health problem rather than
        a script-logic problem

.PARAMETER StalenessDays
    Number of days since LastSyncDateTime beyond which a device is flagged as stale.
    Default: 3.

.PARAMETER ExportPath
    Folder to write CSV output to. Default: current directory.

.EXAMPLE
    .\Get-CustomComplianceAudit.ps1 -StalenessDays 5 -ExportPath "C:\Reports"

.NOTES
    Requires: Microsoft.Graph PowerShell SDK (Install-Module Microsoft.Graph)
    Scopes:   DeviceManagementConfiguration.Read.All, DeviceManagementManagedDevices.Read.All
    Safe/unsafe: Fully read-only. Makes no configuration changes.
#>

[CmdletBinding()]
param(
    [int]$StalenessDays = 3,
    [string]$ExportPath = "."
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
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Graph. Connecting..." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All"
    }
} catch {
    Write-Status "Failed to establish Graph context: $_" "ERROR"
    exit 1
}

if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"

# ---------------------------------------------------------------------------
# Step 1 — Enumerate compliance policies and flag ones with custom settings
# ---------------------------------------------------------------------------
Write-Status "Enumerating compliance policies..."

$allPolicies = @()
try {
    $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?`$top=100"
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        $allPolicies += $resp.value
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
} catch {
    Write-Status "Failed to enumerate compliance policies: $_" "ERROR"
    exit 1
}

# Heuristic: macOS custom-compliance-capable policy types carry
# "macOSCompliancePolicy" in their @odata.type and may reference a linked
# device compliance script via deviceCompliancePolicyScript scheduled actions
# or a customComplianceRequiredPasswordType-style property set. Graph does not
# expose a single boolean "usesCustomCompliance" flag as of this writing, so
# this is reported as a candidate list for manual confirmation in the portal,
# not an authoritative yes/no.
$macPolicies = $allPolicies | Where-Object { $_.'@odata.type' -match 'macOS' }

Write-Status "Found $($macPolicies.Count) macOS compliance policies (of $($allPolicies.Count) total across all platforms)" "OK"

$policyReport = $macPolicies | ForEach-Object {
    [PSCustomObject]@{
        PolicyId          = $_.id
        DisplayName       = $_.displayName
        ODataType         = $_.'@odata.type'
        CreatedDateTime   = $_.createdDateTime
        LastModified      = $_.lastModifiedDateTime
        LikelyCustomRules = if ($_.PSObject.Properties.Name -contains 'customComplianceRequiredPasswordType') { "Possible - verify in portal" } else { "Verify in portal (not detectable via listed properties)" }
    }
}

$policyReport | Export-Csv -Path (Join-Path $ExportPath "macOS-CustomCompliance-Policies-$timestamp.csv") -NoTypeInformation
Write-Status "Policy candidate list exported. NOTE: Graph does not expose a reliable custom-vs-built-in-only flag; confirm each policy's Custom Compliance settings tab in the Intune portal directly." "WARN"

# ---------------------------------------------------------------------------
# Step 2 — Per-device compliance state for macOS devices
# ---------------------------------------------------------------------------
Write-Status "Enumerating managed macOS devices..."

$allDevices = @()
try {
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'macOS'&`$top=100"
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        $allDevices += $resp.value
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
} catch {
    Write-Status "Failed to enumerate macOS devices: $_" "ERROR"
    exit 1
}

Write-Status "Found $($allDevices.Count) managed macOS devices" "OK"

$staleThreshold = (Get-Date).AddDays(-$StalenessDays)

$deviceReport = $allDevices | ForEach-Object {
    $lastSync = $null
    [void][DateTime]::TryParse($_.lastSyncDateTime, [ref]$lastSync)
    [PSCustomObject]@{
        DeviceName        = $_.deviceName
        ManagedDeviceId   = $_.id
        ComplianceState   = $_.complianceState
        OSVersion         = $_.osVersion
        LastSyncDateTime  = $_.lastSyncDateTime
        StaleBeyondThreshold = if ($lastSync -and $lastSync -lt $staleThreshold) { $true } else { $false }
    }
}

$deviceReport | Export-Csv -Path (Join-Path $ExportPath "macOS-CustomCompliance-DeviceState-$timestamp.csv") -NoTypeInformation

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$errorCount      = ($deviceReport | Where-Object { $_.ComplianceState -eq 'error' }).Count
$nonCompliant    = ($deviceReport | Where-Object { $_.ComplianceState -eq 'nonCompliant' }).Count
$compliant       = ($deviceReport | Where-Object { $_.ComplianceState -eq 'compliant' }).Count
$unknownState    = ($deviceReport | Where-Object { $_.ComplianceState -eq 'unknown' -or $_.ComplianceState -eq 'notEvaluated' }).Count
$staleDevices    = ($deviceReport | Where-Object { $_.StaleBeyondThreshold }).Count

Write-Host ""
Write-Status "=== macOS Compliance Summary ===" "INFO"
Write-Status "Compliant:      $compliant" "OK"
Write-Status "NonCompliant:   $nonCompliant" "WARN"
Write-Status "Error:          $errorCount" "ERROR"
Write-Status "Unknown/NotEvaluated: $unknownState" "WARN"
Write-Status "Stale (no sync in $StalenessDays+ days): $staleDevices" "WARN"
Write-Host ""

if ($errorCount -gt 0) {
    Write-Status "Devices in Error state most commonly indicate a discovery-script exit-code or JSON-formatting problem, NOT a genuinely non-compliant setting. See CustomCompliance-A.md / -B.md 'Dual-contract gotcha' before assuming these devices are actually out of policy." "WARN"
}

if ($staleDevices -gt 0) {
    Write-Status "Stale devices should be checked for Intune Agent health (/Library/Intune/Microsoft Intune Agent.app) before assuming a script problem — a device that hasn't synced can't have evaluated any new custom compliance rules." "WARN"
}

Write-Status "Reports written to: $ExportPath" "OK"
