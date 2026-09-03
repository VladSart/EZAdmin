<#
.SYNOPSIS
    Reports Intune-managed macOS fleet exposure to Apple's Intel Mac hardware retirement
    (macOS 26 Tahoe as the last major OS for the final 4 supported Intel models; macOS 27
    Golden Gate as Apple Silicon-only).

.DESCRIPTION
    Companion script to macOS/Troubleshooting/IntelMacRetirement-B.md and -A.md, covering
    the Track 1 (hardware retirement) side of that topic at fleet scale via Microsoft Graph.

    Queries the Intune-managed macOS device inventory and flags devices whose model
    identifier matches known Intel-era Mac hardware, using a best-effort model-identifier
    heuristic (see Limitations below), then further flags which of those are on macOS
    versions below/at/above the current macOS 26 Tahoe ceiling.

    This script does NOT and CANNOT:
    - Confirm chip architecture (Intel vs. Apple Silicon) with certainty from Graph alone.
      Microsoft Graph's managedDevices resource does not expose a direct CPU-architecture
      field for macOS devices; this script classifies devices using a model-identifier
      pattern heuristic and explicitly flags any model it cannot confidently classify.
      For a single device, the AUTHORITATIVE check is running
      `sysctl -n machdep.cpu.brand_string` locally on that Mac (see the companion runbooks'
      Triage/Validation steps) — treat this script's output as a fleet-planning starting
      point, not a certainty for any individual device.
    - Audit Intel-only (non-Universal) application exposure (Track 2 of the companion
      topic) — that requires a local `system_profiler SPApplicationsDataType` sweep per
      device, which has no Graph/Intune API equivalent as of this writing.
    - Trigger, schedule, or block any OS upgrade, enrollment, or device action — this is a
      read-only reporting tool.
    - Confirm the current macOS 26 Tahoe supported-model list with certainty — Apple's own
      published compatibility page is authoritative and should be cross-referenced against
      this script's flagged devices before finalizing any client-facing report.

.PARAMETER ExportPath
    Full path for CSV export. Defaults to $env:TEMP\IntelMacFleetAudit-<date>.csv.

.EXAMPLE
    .\Get-IntelMacFleetAudit.ps1
    Audits the tenant's Intune-managed macOS fleet for likely Intel Mac hardware exposure.

.NOTES
    Requires: Microsoft.Graph.Authentication PowerShell module
    Permissions needed (Graph): DeviceManagementManagedDevices.Read.All
    Recommended role: Read-only (Intune Read Only Operator or equivalent custom role).
    Fully read-only — safe to run in production at any time. Intended for recurring
    (e.g. quarterly) use as a hardware-refresh planning tracker.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ExportPath = "$env:TEMP\IntelMacFleetAudit-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "SECTION")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SECTION" { "Cyan" }
        default   { "White" }
    }
    $prefix = if ($Status -eq "SECTION") { "`n====" } else { "[$Status]" }
    Write-Host "$prefix $Message" -ForegroundColor $colour
}

#region Prerequisites
Write-Status "Checking prerequisites..." -Status SECTION

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph.Authentication" -Status ERROR
    exit 1
}

try {
    $ctx = Get-MgContext
    if (-not $ctx) {
        Write-Status "Connecting to Microsoft Graph (scope: DeviceManagementManagedDevices.Read.All)..." -Status INFO
        Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome
    }
    Write-Status "Connected as $((Get-MgContext).Account)" -Status OK
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Status ERROR
    exit 1
}
#endregion

#region Fetch macOS device inventory
Write-Status "Retrieving macOS managed device inventory..." -Status SECTION

try {
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'macOS'&`$top=999"
    $macDevices = @()
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        $macDevices += $resp.value
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
}
catch {
    Write-Status "Failed to query managed devices. Confirm DeviceManagementManagedDevices.Read.All is granted and admin-consented. Error: $($_.Exception.Message)" -Status ERROR
    exit 1
}

Write-Status "Retrieved $($macDevices.Count) macOS managed device(s)." -Status INFO
#endregion

#region Model-identifier heuristic classification
Write-Status "Classifying devices by model identifier (best-effort heuristic — see script header)..." -Status SECTION

function Get-ChipClassification {
    param([string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) { return "Unknown (no model data)" }

    # Known Intel-era model-identifier prefixes (final Intel generations, roughly 2017-2020)
    $intelPatterns = @(
        '^MacBookPro1[3-6],', '^MacBookAir[6-9],', '^MacBookAir10,1', '^MacBook[89],', '^MacBook10,',
        '^iMac1[4-9],', '^iMac20,', '^iMacPro1,', '^Macmini[68],', '^MacPro[1-6],', '^MacPro7,1'
    )
    # Known Apple Silicon model-identifier prefixes (Mac13/14/15/16.. naming, and MacBookPro17+)
    $appleSiliconPatterns = @(
        '^MacBookPro1[7-9],', '^MacBookPro2[0-9],', '^MacBookAir10,', '^Mac1[3-9],', '^Mac[2-9][0-9],'
    )

    foreach ($p in $intelPatterns) { if ($Model -match $p) { return "Intel (heuristic match)" } }
    foreach ($p in $appleSiliconPatterns) { if ($Model -match $p) { return "Apple Silicon (heuristic match)" } }
    return "Unknown — verify locally via sysctl -n machdep.cpu.brand_string"
}

$classified = $macDevices | ForEach-Object {
    [PSCustomObject]@{
        DeviceName          = $_.deviceName
        Model                = $_.model
        ChipClassification   = Get-ChipClassification -Model $_.model
        OSVersion            = $_.osVersion
        UserPrincipalName    = $_.userPrincipalName
        ManagedDeviceOwnerType = $_.managedDeviceOwnerType
        EnrolledDateTime     = $_.enrolledDateTime
        LastSyncDateTime     = $_.lastSyncDateTime
    }
}

$likelyIntel = $classified | Where-Object { $_.ChipClassification -eq "Intel (heuristic match)" }
$unknownChip = $classified | Where-Object { $_.ChipClassification -like "Unknown*" }

Write-Status "$($likelyIntel.Count) of $($macDevices.Count) device(s) heuristically match known Intel Mac model identifiers." -Status $(if ($likelyIntel.Count -gt 0) { "WARN" } else { "OK" })
if ($unknownChip.Count -gt 0) {
    Write-Status "$($unknownChip.Count) device(s) could not be classified from model identifier alone — verify locally via sysctl on representative devices before excluding them from planning." -Status WARN
}
#endregion

#region macOS 26 Tahoe ceiling check for likely-Intel devices
Write-Status "Checking OS version against the macOS 26 Tahoe ceiling for likely-Intel devices..." -Status SECTION

foreach ($dev in $likelyIntel) {
    try {
        $majorVersion = [version](($dev.OSVersion -split '\.')[0..1] -join '.')
        if ($majorVersion -ge [version]"26.0") {
            $dev | Add-Member -NotePropertyName "TahoeCeilingStatus" -NotePropertyValue "AT CEILING — macOS 26 Tahoe is the last major OS this hardware will ever receive" -Force
        } else {
            $dev | Add-Member -NotePropertyName "TahoeCeilingStatus" -NotePropertyValue "Below ceiling — may still have upgrade headroom, but refresh should be budgeted" -Force
        }
    } catch {
        $dev | Add-Member -NotePropertyName "TahoeCeilingStatus" -NotePropertyValue "Could not parse OS version" -Force
    }
}

$atCeiling = $likelyIntel | Where-Object { $_.TahoeCeilingStatus -like "AT CEILING*" }
if ($atCeiling.Count -gt 0) {
    Write-Status "$($atCeiling.Count) likely-Intel device(s) are already at the macOS 26 Tahoe ceiling — highest priority for hardware-refresh planning." -Status WARN
}
#endregion

#region Export
Write-Status "Exporting report..." -Status SECTION
$classified | Sort-Object ChipClassification, OSVersion -Descending |
    Format-Table DeviceName, Model, ChipClassification, OSVersion, UserPrincipalName -AutoSize
$classified | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to $ExportPath" -Status OK
Write-Status "Cross-reference flagged 'Intel' and 'Unknown' devices against Apple's current macOS 26 Tahoe compatibility page before finalizing a client-facing refresh plan." -Status INFO
Write-Status "This script covers hardware retirement (Track 1) only. For Intel-only application exposure (Track 2 — Rosetta 2 retirement), run a local system_profiler sweep per IntelMacRetirement-B.md Fix 5 — no fleet-wide Graph equivalent exists as of this writing." -Status INFO
#endregion
