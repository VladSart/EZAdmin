<#
.SYNOPSIS
    Audits Entra ID Conditional Access Named Locations for staleness, overlaps,
    missing Trusted flags, and orphaned locations not referenced by any CA policy.

.DESCRIPTION
    Connects to Microsoft Graph and pulls all Named Locations (IP range and
    Countries/Regions types) alongside all Conditional Access policies. Cross-
    references the two to build a full picture of Named Location health:
      - Which locations are Trusted vs. non-Trusted
      - Which locations are referenced by zero CA policies (candidates for cleanup)
      - Which IP-range locations have overlapping or duplicate CIDR blocks
      - Which locations are close to the 2,000 CIDR-range-per-location ceiling
      - Country/region locations with "includeUnknownCountriesAndRegions" set,
        flagged for review since this is an easy-to-miss catch-all
      - CA policies referencing a Named Location that no longer exists (broken ref)
    Exports a CSV audit report plus a console summary. Read-only — makes no
    changes to Named Locations or CA policy state.

.PARAMETER IncludeCountryLocations
    Include Countries/Regions-type Named Locations in the audit (default: $true).

.PARAMETER StaleCheckOnly
    Skip CIDR overlap detection and only report unreferenced/orphaned locations.
    Useful for a fast pass on large tenants. Default: $false.

.PARAMETER OutputPath
    Where to save the CSV report. Default: C:\Temp\NamedLocation-Audit-<date>.csv

.EXAMPLE
    .\Get-NamedLocationAudit.ps1

.EXAMPLE
    .\Get-NamedLocationAudit.ps1 -StaleCheckOnly -OutputPath C:\Reports\NL-Audit.csv

.NOTES
    Requires: Microsoft.Graph.Identity.SignIns module
    Scopes:   Policy.Read.All
    Run as:   Any account with Security Reader or Conditional Access Administrator role
    Safe:     Read-only. No Named Location or CA policy is modified.
#>

[CmdletBinding()]
param(
    [bool]$IncludeCountryLocations = $true,
    [bool]$StaleCheckOnly = $false,
    [string]$OutputPath = "C:\Temp\NamedLocation-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# ─────────────────────────────────────────────
# PREFLIGHT
# ─────────────────────────────────────────────
Write-Host "`n=== Conditional Access Named Location Audit ===" -ForegroundColor Cyan
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.SignIns)) {
    Write-Status "Microsoft.Graph.Identity.SignIns module not found. Install with: Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser" "ERROR"
    exit 1
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph (Policy.Read.All)..." "INFO"
        Connect-MgGraph -Scopes "Policy.Read.All" -NoWelcome
    } else {
        Write-Status "Using existing Graph session: $($context.Account)" "OK"
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $_" "ERROR"
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
# 1. PULL NAMED LOCATIONS AND CA POLICIES
# ─────────────────────────────────────────────
Write-Host "--- Fetching Named Locations ---" -ForegroundColor Cyan

try {
    $namedLocations = Get-MgIdentityConditionalAccessNamedLocation -All
} catch {
    Write-Status "Failed to retrieve Named Locations: $_" "ERROR"
    exit 1
}

if (-not $namedLocations -or $namedLocations.Count -eq 0) {
    Write-Status "No Named Locations found in this tenant." "WARN"
    exit 0
}

Write-Status "Retrieved $($namedLocations.Count) Named Location(s)" "OK"

Write-Host "`n--- Fetching Conditional Access Policies ---" -ForegroundColor Cyan
try {
    $caPolicies = Get-MgIdentityConditionalAccessPolicy -All
} catch {
    Write-Status "Failed to retrieve CA policies: $_" "ERROR"
    exit 1
}

Write-Status "Retrieved $($caPolicies.Count) CA polic$(if ($caPolicies.Count -eq 1) {'y'} else {'ies'})" "OK"

# Build a lookup of every Named Location ID referenced by any policy (include/exclude)
$referencedLocationIds = @{}
foreach ($policy in $caPolicies) {
    $locCond = $policy.Conditions.Locations
    if ($null -eq $locCond) { continue }
    foreach ($locId in @($locCond.IncludeLocations) + @($locCond.ExcludeLocations)) {
        if ($locId -and $locId -ne "All" -and $locId -ne "AllTrusted") {
            if (-not $referencedLocationIds.ContainsKey($locId)) {
                $referencedLocationIds[$locId] = [System.Collections.Generic.List[string]]::new()
            }
            $referencedLocationIds[$locId].Add($policy.DisplayName)
        }
    }
}

# ─────────────────────────────────────────────
# 2. PER-LOCATION ANALYSIS
# ─────────────────────────────────────────────
Write-Host "`n--- Per-Location Analysis ---" -ForegroundColor Cyan

$ipLocations = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($loc in $namedLocations) {
    $odataType = $loc.AdditionalProperties["@odata.type"]
    $isCountry = $odataType -match "countryNamedLocation"
    $isIp      = $odataType -match "ipNamedLocation"

    if ($isCountry -and -not $IncludeCountryLocations) { continue }

    $refs = $referencedLocationIds[$loc.Id]
    $refCount = if ($refs) { $refs.Count } else { 0 }
    $refList  = if ($refs) { ($refs | Select-Object -Unique) -join "; " } else { "" }

    if ($isIp) {
        $isTrusted = [bool]$loc.AdditionalProperties["isTrusted"]
        $cidrRanges = @($loc.AdditionalProperties["ipRanges"])
        $cidrCount = $cidrRanges.Count

        $ipLocations.Add([PSCustomObject]@{
            Id         = $loc.Id
            Name       = $loc.DisplayName
            Trusted    = $isTrusted
            CidrCount  = $cidrCount
            CidrRanges = ($cidrRanges | ForEach-Object { $_.cidrAddress }) -join ", "
        })

        if (-not $isTrusted) {
            Add-Result "IP Location" $loc.DisplayName "INFO" "Not marked Trusted — no MFA/Compliant Network exemption benefit from this location"
        }

        if ($cidrCount -ge 1800) {
            Add-Result "IP Location" $loc.DisplayName "WARN" "$cidrCount / 2000 CIDR range ceiling — approaching per-location limit, consider splitting"
        }

        if (-not $StaleCheckOnly -and $cidrCount -eq 0) {
            Add-Result "IP Location" $loc.DisplayName "WARN" "Zero CIDR ranges defined — effectively a no-op location"
        }
    }

    if ($isCountry) {
        $countries = @($loc.AdditionalProperties["countriesAndRegions"])
        $includeUnknown = [bool]$loc.AdditionalProperties["includeUnknownCountriesAndRegions"]

        if ($includeUnknown) {
            Add-Result "Country Location" $loc.DisplayName "WARN" "includeUnknownCountriesAndRegions = true — catches all non-geolocatable IPs (VPNs, some cloud egress). Verify this is intentional."
        }

        Add-Result "Country Location" $loc.DisplayName "INFO" "$($countries.Count) countries/regions defined"
    }

    if ($refCount -eq 0) {
        Add-Result "Reference Check" $loc.DisplayName "WARN" "Not referenced by any CA policy (include or exclude) — orphaned, candidate for cleanup"
    } else {
        Add-Result "Reference Check" $loc.DisplayName "OK" "Referenced by $refCount polic$(if($refCount -eq 1){'y'}else{'ies'}): $refList"
    }
}

# ─────────────────────────────────────────────
# 3. CIDR OVERLAP DETECTION (IP locations only)
# ─────────────────────────────────────────────
if (-not $StaleCheckOnly) {
    Write-Host "`n--- CIDR Overlap Detection ---" -ForegroundColor Cyan

    function ConvertTo-IpRange {
        param([string]$Cidr)
        try {
            $parts = $Cidr -split '/'
            $ip = [System.Net.IPAddress]::Parse($parts[0])
            if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
            $prefix = [int]$parts[1]
            $ipBytes = $ip.GetAddressBytes()
            [Array]::Reverse($ipBytes)
            $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)
            $maskInt = if ($prefix -eq 0) { 0 } else { [uint32]([uint32]::MaxValue -shl (32 - $prefix)) }
            $network = $ipInt -band $maskInt
            $broadcast = $network -bor (-bnot $maskInt -band [uint32]::MaxValue)
            return [PSCustomObject]@{ Start = $network; End = $broadcast; Cidr = $Cidr }
        } catch {
            return $null
        }
    }

    $allRanges = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ipLoc in $ipLocations) {
        foreach ($cidr in ($ipLoc.CidrRanges -split ", " | Where-Object { $_ })) {
            $range = ConvertTo-IpRange -Cidr $cidr
            if ($range) {
                $allRanges.Add([PSCustomObject]@{ Location = $ipLoc.Name; Start = $range.Start; End = $range.End; Cidr = $cidr })
            }
        }
    }

    $overlapCount = 0
    for ($i = 0; $i -lt $allRanges.Count; $i++) {
        for ($j = $i + 1; $j -lt $allRanges.Count; $j++) {
            $a = $allRanges[$i]; $b = $allRanges[$j]
            if ($a.Location -eq $b.Location) { continue }
            if ($a.Start -le $b.End -and $b.Start -le $a.End) {
                $overlapCount++
                Add-Result "CIDR Overlap" "$($a.Location) <-> $($b.Location)" "WARN" "$($a.Cidr) overlaps $($b.Cidr) — sign-ins from this range match both locations, which may produce unexpected CA evaluation"
            }
        }
    }

    if ($overlapCount -eq 0 -and $allRanges.Count -gt 0) {
        Add-Result "CIDR Overlap" "All IP locations" "OK" "No overlapping CIDR ranges detected across $($allRanges.Count) ranges"
    }
} else {
    Write-Status "Skipping CIDR overlap detection (-StaleCheckOnly specified)" "SKIP"
}

# ─────────────────────────────────────────────
# 4. BROKEN CA POLICY REFERENCES
# ─────────────────────────────────────────────
Write-Host "`n--- Broken Policy References ---" -ForegroundColor Cyan

$knownLocationIds = @($namedLocations | ForEach-Object { $_.Id })
$brokenRefFound = $false

foreach ($policy in $caPolicies) {
    $locCond = $policy.Conditions.Locations
    if ($null -eq $locCond) { continue }
    foreach ($locId in @($locCond.IncludeLocations) + @($locCond.ExcludeLocations)) {
        if ($locId -and $locId -ne "All" -and $locId -ne "AllTrusted" -and $locId -notin $knownLocationIds) {
            Add-Result "Broken Reference" $policy.DisplayName "ERROR" "References Named Location ID '$locId' which no longer exists — policy will not evaluate location condition correctly"
            $brokenRefFound = $true
        }
    }
}

if (-not $brokenRefFound) {
    Add-Result "Broken Reference" "All policies" "OK" "No CA policies reference a deleted Named Location"
}

# ─────────────────────────────────────────────
# REPORT
# ─────────────────────────────────────────────
Write-Host "`n--- Generating Report ---" -ForegroundColor Cyan

$okCount    = ($results | Where-Object {$_.Status -eq "OK"}).Count
$warnCount  = ($results | Where-Object {$_.Status -eq "WARN"}).Count
$errorCount = ($results | Where-Object {$_.Status -eq "ERROR"}).Count
$infoCount  = ($results | Where-Object {$_.Status -eq "INFO"}).Count

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Status "Report saved to: $OutputPath" "OK"
Write-Host ""
Write-Host "=== Summary: OK: $okCount  WARN: $warnCount  ERROR: $errorCount  INFO: $infoCount ===" -ForegroundColor Cyan
Write-Host "Total Named Locations audited: $($namedLocations.Count)" -ForegroundColor Cyan
