<#
.SYNOPSIS
    Scans a downloaded Microsoft Entra ID Company Branding / Branding Themes custom CSS
    file for use of the layout and positioning properties Microsoft is retiring
    (Stage 1: new usage blocked 2026-07-21; Stage 2: global retirement late Oct 2026 /
    Act by 2026-10-26, per Message Center MC1458474).

.DESCRIPTION
    Companion script to EntraID/Troubleshooting/BrandingCSSRetirement-B.md and -A.md.

    Custom CSS content has no Graph-queryable structured representation - the file must
    be downloaded from the Entra admin center (Company branding -> Edit -> Layout ->
    Custom CSS -> Download, or the equivalent per-application Branding themes path) and
    inspected directly. This script performs that inspection:

    - Pattern-matches the file's content against the FULL retired-property list from
      MC1458474 (which expands on the earlier, shorter MC1435782 list)
    - Reports each retired property found, with the matching line number and content
      for quick location in the source file
    - Distinguishes a clean file (no retired properties - no action needed) from one
      requiring remediation before the Stage 2 cutover
    - Optionally checks organization branding configuration existence via Graph, if
      -CheckGraphConfig is supplied, purely as a companion sanity check

    Does NOT cover:
    - Actually downloading the CSS file - that remains a manual portal step (no Graph
      endpoint exposes CSS file content programmatically as of this writing)
    - Editing or re-uploading corrected CSS - this script is read-only / reporting only
    - Branding themes discovery (enumerating which Enterprise Applications have a
      custom sign-in configured) - run this script once per downloaded CSS file,
      across both Company branding and each Branding theme in use

.PARAMETER CssFilePath
    Path to a downloaded custom CSS file to scan. Required.

.PARAMETER CheckGraphConfig
    If supplied, also queries Get-MgOrganizationBranding as a companion sanity check
    that a branding configuration exists in the connected tenant. Requires a prior
    Connect-MgGraph -Scopes "Organization.Read.All".

.PARAMETER ExportPath
    Path for CSV export of findings. Default: .\BrandingCSSRetirementAudit-<timestamp>.csv

.EXAMPLE
    .\Get-BrandingCSSRetirementAudit.ps1 -CssFilePath "C:\temp\company-branding.css"
    Scans the downloaded CSS file and reports any retired properties found.

.EXAMPLE
    .\Get-BrandingCSSRetirementAudit.ps1 -CssFilePath "C:\temp\app-theme.css" -CheckGraphConfig
    Also confirms the tenant has a branding configuration via Graph as a sanity check.

.NOTES
    Requires: no modules for the core CSS scan (pure text parsing).
    Microsoft.Graph.Identity.DirectoryManagement module only if -CheckGraphConfig is used
    (Connect-MgGraph -Scopes "Organization.Read.All" first).
    Read-only. Makes no changes to any branding configuration.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CssFilePath,

    [switch]$CheckGraphConfig,

    [string]$ExportPath = ".\BrandingCSSRetirementAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path -Path $CssFilePath)) {
    Write-Status "CSS file not found at '$CssFilePath'. Download it first: Entra admin center -> Company branding -> Edit -> Layout -> Custom CSS -> Download." "ERROR"
    return
}

# Full retired-property list per MC1458474 (supersedes the shorter MC1435782 list)
$RetiredProperties = @(
    "offset", "offset-path", "offset-distance",
    "margin-block", "margin-block-start", "margin-block-end",
    "margin-inline", "margin-inline-start", "margin-inline-end",
    "order",
    "grid-area", "grid-column", "grid-column-start", "grid-column-end",
    "grid-row", "grid-row-start", "grid-row-end",
    "isolation",
    "overflow-x", "overflow-y", "overflow-block", "overflow-inline",
    "content-visibility",
    "clip",
    "mask", "mask-image",
    "-webkit-mask", "-webkit-mask-image"
)

Write-Status "Scanning $CssFilePath against $($RetiredProperties.Count) retired CSS properties (MC1458474 list)..." "INFO"

$lines = Get-Content -Path $CssFilePath
$results = [System.Collections.Generic.List[object]]::new()
$lineNum = 0

foreach ($line in $lines) {
    $lineNum++
    foreach ($prop in $RetiredProperties) {
        # Match the property as a CSS declaration property name: optional leading whitespace,
        # the exact property name, then a colon - avoids false-positives on unrelated properties
        # that merely contain the substring (e.g. "margin" alone would over-match "margin-top").
        if ($line -match "(?i)(^|\s|;|\{)\s*$([regex]::Escape($prop))\s*:") {
            $results.Add([PSCustomObject]@{
                LineNumber   = $lineNum
                Property     = $prop
                LineContent  = $line.Trim()
                Recommendation = "Retired - remove or redesign using a non-retired property before the late-Oct-2026 (Act by 2026-10-26) cutover"
            })
        }
    }
}

if ($results.Count -eq 0) {
    Write-Status "No retired properties found in '$CssFilePath'. This file appears clean for the current (MC1458474) retirement list." "OK"
    $results.Add([PSCustomObject]@{
        LineNumber     = $null
        Property       = "(none found)"
        LineContent    = $null
        Recommendation = "No action needed for this file against the current retired-property list. Re-check when the broader 2027 full-CSS-retirement milestone is announced."
    })
} else {
    $uniqueProps = $results.Property | Where-Object { $_ -ne "(none found)" } | Select-Object -Unique
    Write-Status "Found $($results.Count) occurrence(s) across $($uniqueProps.Count) distinct retired propert$(if ($uniqueProps.Count -eq 1) { 'y' } else { 'ies' }): $($uniqueProps -join ', ')" "WARN"
    Write-Status "Remediation required before the late-Oct-2026 (Act by 2026-10-26) cutover — see BrandingCSSRetirement-B.md Fix 1." "WARN"
}

# ── Optional Graph companion check ────────────────────────────────────────────────
if ($CheckGraphConfig) {
    Write-Status "Checking organization branding configuration via Graph (companion sanity check)..." "INFO"
    try {
        $orgId = (Get-MgOrganization -ErrorAction Stop).Id
        $branding = Get-MgOrganizationBranding -OrganizationId $orgId -ErrorAction Stop
        if ($branding) {
            Write-Status "Branding configuration confirmed present for organization $orgId." "OK"
        } else {
            Write-Status "No branding configuration returned - confirm this CSS file is actually in active use." "WARN"
        }
    } catch {
        Write-Status "Graph check failed - confirm Connect-MgGraph -Scopes 'Organization.Read.All' has run. Error: $($_.Exception.Message)" "ERROR"
    }
}

# ── Export ──────────────────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full results exported to $ExportPath" "OK"

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Scanned file: $CssFilePath" -ForegroundColor DarkGray
Write-Host "Reminder: run this once per CSS file — Company branding and each Branding theme are" -ForegroundColor DarkGray
Write-Host "configured and downloaded separately, even though they share the same retired-property list." -ForegroundColor DarkGray
$results | Format-Table -AutoSize
