<#
.SYNOPSIS
    Audits Microsoft Purview sensitivity label coverage — label publishing,
    auto-labeling policies, and SharePoint/OneDrive site-level integration.

.DESCRIPTION
    Connects to Exchange Online / Security & Compliance PowerShell (IPPS session)
    and, optionally, SharePoint Online, to report on:
      - All published sensitivity labels and their priority order
      - Label policies and which labels/locations each one covers
      - Auto-labeling policies (client-side and service-side) and their mode
        (TestWithoutNotifications / TestWithNotifications / Enable)
      - Whether SPO tenant-level sensitivity label integration is enabled
        (required for auto-labeling on SharePoint/OneDrive at the item level)
      - Flags labels that exist but are not in any published policy (unreachable
        to end users) and auto-labeling policies stuck in test mode
    Exports a CSV report. Read-only — makes no label, policy, or SPO changes.

.PARAMETER AdminUPN
    UPN used to establish the IPPS (Security & Compliance) session.

.PARAMETER CheckSharePointIntegration
    Also connect to SharePoint Online and check tenant-level sensitivity label
    integration (EnableAIPIntegration). Requires -SPOAdminUrl. Default: $false.

.PARAMETER SPOAdminUrl
    SharePoint Online admin center URL, e.g. https://contoso-admin.sharepoint.com.
    Required only if -CheckSharePointIntegration is set.

.PARAMETER OutputPath
    Where to save the CSV report. Default: C:\Temp\SensitivityLabel-Coverage-<date>.csv

.EXAMPLE
    .\Get-SensitivityLabelCoverage.ps1 -AdminUPN admin@contoso.com

.EXAMPLE
    .\Get-SensitivityLabelCoverage.ps1 -AdminUPN admin@contoso.com -CheckSharePointIntegration -SPOAdminUrl https://contoso-admin.sharepoint.com

.NOTES
    Requires: ExchangeOnlineManagement module (Connect-IPPSSession), optionally Microsoft.Online.SharePoint.PowerShell
    Run as:   Account with Compliance Administrator or Information Protection Admin role
    Safe:     Read-only. No label, label policy, or SPO tenant setting is modified.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdminUPN,

    [bool]$CheckSharePointIntegration = $false,
    [string]$SPOAdminUrl = "",
    [string]$OutputPath = "C:\Temp\SensitivityLabel-Coverage-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "SKIP"  { "DarkGray" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

Write-Host "`n=== Sensitivity Label Coverage Audit ===" -ForegroundColor Cyan
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

# ─────────────────────────────────────────────
# PREFLIGHT
# ─────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Status "ExchangeOnlineManagement module not found. Install with: Install-Module ExchangeOnlineManagement -Scope CurrentUser" "ERROR"
    exit 1
}

try {
    Write-Status "Connecting to Security & Compliance (IPPS session) as $AdminUPN..." "INFO"
    Connect-IPPSSession -UserPrincipalName $AdminUPN -ShowBanner:$false
} catch {
    Write-Status "Failed to connect to IPPS session: $_" "ERROR"
    exit 1
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Category, [string]$Item, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Category = $Category
        Item     = $Item
        Status   = $Status
        Detail   = $Detail
    })
    Write-Status "$Category | $Item — $Detail" $Status
}

# ─────────────────────────────────────────────
# 1. LABELS
# ─────────────────────────────────────────────
Write-Host "--- Sensitivity Labels ---" -ForegroundColor Cyan

try {
    $labels = Get-Label | Sort-Object Priority
} catch {
    Write-Status "Failed to retrieve labels: $_" "ERROR"
    exit 1
}

if (-not $labels -or $labels.Count -eq 0) {
    Write-Status "No sensitivity labels found in this tenant." "WARN"
    exit 0
}

Write-Status "Retrieved $($labels.Count) label(s)" "OK"

foreach ($label in $labels) {
    $state = if ($label.IsActive) { "OK" } else { "WARN" }
    Add-Result "Label" $label.Name $state "Priority: $($label.Priority)  Active: $($label.IsActive)  GUID: $($label.Guid)"
}

# ─────────────────────────────────────────────
# 2. LABEL POLICIES (publishing)
# ─────────────────────────────────────────────
Write-Host "`n--- Label Policies (Publishing) ---" -ForegroundColor Cyan

try {
    $labelPolicies = Get-LabelPolicy
} catch {
    Write-Status "Failed to retrieve label policies: $_" "WARN"
    $labelPolicies = @()
}

$labelsInAnyPolicy = @{}
foreach ($policy in $labelPolicies) {
    $locations = @()
    foreach ($locProp in @("ExchangeLocation", "SharePointLocation", "OneDriveLocation", "ModernGroupLocation")) {
        if ($policy.PSObject.Properties.Name -contains $locProp -and $policy.$locProp) {
            $locations += "$locProp=$($policy.$locProp -join ',')"
        }
    }
    Add-Result "Label Policy" $policy.Name "OK" "Labels: $($policy.Labels -join ', ')  Locations: $($locations -join '; ')"

    foreach ($lbl in $policy.Labels) {
        $labelsInAnyPolicy[$lbl] = $true
    }
}

if ($labelPolicies.Count -eq 0) {
    Add-Result "Label Policy" "None" "ERROR" "No label policies found — labels exist but are not published to any user or location"
}

# Flag labels not covered by any published policy
foreach ($label in $labels) {
    $covered = $labelsInAnyPolicy.ContainsKey($label.Name) -or $labelsInAnyPolicy.ContainsKey($label.Guid.ToString())
    if (-not $covered) {
        Add-Result "Coverage Gap" $label.Name "WARN" "Label exists but is not included in any published Label Policy — unreachable by end users in Office apps"
    }
}

# ─────────────────────────────────────────────
# 3. AUTO-LABELING POLICIES
# ─────────────────────────────────────────────
Write-Host "`n--- Auto-Labeling Policies ---" -ForegroundColor Cyan

try {
    $autoPolicies = Get-AutoSensitivityLabelPolicy
} catch {
    Write-Status "Failed to retrieve auto-labeling policies: $_" "WARN"
    $autoPolicies = @()
}

if ($autoPolicies.Count -eq 0) {
    Add-Result "Auto-Labeling" "None configured" "INFO" "No auto-labeling policies found — all labeling is manual/user-driven"
} else {
    foreach ($autoPolicy in $autoPolicies) {
        $mode = $autoPolicy.Mode
        $status = switch ($mode) {
            "Enable"                       { "OK" }
            "TestWithNotifications"        { "WARN" }
            "TestWithoutNotifications"     { "WARN" }
            default                        { "INFO" }
        }
        $detail = "Mode: $mode  Workload: $($autoPolicy.Workload -join ', ')"
        if ($mode -ne "Enable") {
            $detail += "  — still in test mode; will not apply labels to production content until enabled"
        }
        Add-Result "Auto-Labeling" $autoPolicy.Name $status $detail
    }
}

# ─────────────────────────────────────────────
# 4. SHAREPOINT INTEGRATION (optional)
# ─────────────────────────────────────────────
if ($CheckSharePointIntegration) {
    Write-Host "`n--- SharePoint Online Integration ---" -ForegroundColor Cyan

    if ($SPOAdminUrl -eq "") {
        Add-Result "SPO Integration" "Check skipped" "SKIP" "-CheckSharePointIntegration set but -SPOAdminUrl not provided"
    } elseif (-not (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
        Add-Result "SPO Integration" "Check skipped" "SKIP" "Microsoft.Online.SharePoint.PowerShell module not installed"
    } else {
        try {
            Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking
            Connect-SPOService -Url $SPOAdminUrl
            $tenant = Get-SPOTenant
            if ($tenant.EnableAIPIntegration) {
                Add-Result "SPO Integration" "EnableAIPIntegration" "OK" "Sensitivity label integration is enabled tenant-wide for SharePoint/OneDrive"
            } else {
                Add-Result "SPO Integration" "EnableAIPIntegration" "ERROR" "Sensitivity label integration is DISABLED — labels cannot be applied to SPO/OneDrive files at the item level. Enable with Set-SPOTenant -EnableAIPIntegration `$true"
            }
        } catch {
            Add-Result "SPO Integration" "Connection" "WARN" "Could not connect to SPO admin center: $_"
        }
    }
} else {
    Add-Result "SPO Integration" "Check skipped" "SKIP" "-CheckSharePointIntegration not set"
}

# ─────────────────────────────────────────────
# REPORT
# ─────────────────────────────────────────────
Write-Host "`n--- Generating Report ---" -ForegroundColor Cyan

$okCount    = ($results | Where-Object {$_.Status -eq "OK"}).Count
$warnCount  = ($results | Where-Object {$_.Status -eq "WARN"}).Count
$errorCount = ($results | Where-Object {$_.Status -eq "ERROR"}).Count
$infoCount  = ($results | Where-Object {$_.Status -eq "INFO" -or $_.Status -eq "SKIP"}).Count

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Status "Report saved to: $OutputPath" "OK"
Write-Host ""
Write-Host "=== Summary: OK: $okCount  WARN: $warnCount  ERROR: $errorCount  INFO/SKIP: $infoCount ===" -ForegroundColor Cyan
Write-Host "Labels audited: $($labels.Count)  Policies audited: $($labelPolicies.Count)  Auto-labeling policies: $($autoPolicies.Count)" -ForegroundColor Cyan

Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
