<#
.SYNOPSIS
    Audits macOS Wi-Fi/802.1X-related device configuration profiles (network profile, Trusted root
    certificate profile, SCEP/PKCS certificate profile) and flags assignment-scope mismatches between
    them — the single most common root cause covered in WiFi-8021x-B.md / WiFi-8021x-A.md.

.DESCRIPTION
    Companion script to macOS/Troubleshooting/WiFi-8021x-A.md and WiFi-8021x-B.md.

    Enterprise Wi-Fi and wired 802.1X on macOS depend on THREE independently-assignable profile
    objects resolving to the same device/user group: the network profile itself (macOSWiFiConfiguration
    / macOSEnterpriseWiFiConfiguration, or the equivalent wired-network profile type), a Trusted root
    certificate profile (server trust), and a SCEP or PKCS certificate profile (client identity). Intune
    does not warn you if these drift out of scope with each other — this script exists to surface that
    drift before it becomes a live escalation.

    This script:
      1. Queries all macOS device configuration profiles and buckets them by role (network / trusted
         root / SCEP / PKCS) via @odata.type substring matching, since exact beta type names are not
         treated here as guaranteed-stable across Graph API versions.
      2. Pulls each matched profile's group assignment targets.
      3. Cross-references assignment targets across the three roles and flags any network profile
         whose assignment group set does NOT have at least one Trusted-root profile AND one
         SCEP/PKCS profile sharing the exact same group — this is the "three-legged stool" gap.
      4. Separately reports macOS managed devices with a stale check-in, since certificate delivery
         and any recent profile change are both check-in-gated (same pattern as every other Apple MDM
         feature in this repo).

    Does NOT attempt to read certificate private key material, does NOT inspect deployment channel
    (User/Device) vs. certificate-profile scope match from Graph alone (this requires per-profile
    schema fields not uniformly exposed across profile types at the generic deviceConfiguration level —
    verify deployment channel / certificate scope manually in the portal per WiFi-8021x-B.md Fix 4).
    Does NOT touch NDES/SCEP server health, RADIUS/NPS server configuration, or switch/AP-side 802.1X
    settings — all outside Graph's visibility and this script's scope.

    NOTE: the exact @odata.type string for the macOS WIRED (802.1X) network profile was not confirmed
    against current Graph beta schema at time of writing (only macOSWiFiConfiguration /
    macOSEnterpriseWiFiConfiguration were confirmed) — this script matches on the substring "wired"
    case-insensitively to catch it defensively. If your tenant's wired profiles don't surface, verify
    the live @odata.type in the portal (Configuration profile > export/inspect) and extend the
    $networkTypePatterns array below.

.PARAMETER StaleSyncDays
    Number of days since last successful check-in before a macOS device is flagged SYNC_STALE.
    Default 14.

.PARAMETER OutputPath
    Base path (without extension) to export CSV reports:
    "<OutputPath>-Profiles.csv", "<OutputPath>-ScopeGaps.csv", "<OutputPath>-Devices.csv"
    Default: $env:TEMP\WiFiProfileAudit-<date>

.EXAMPLE
    .\Get-WiFiProfileAudit.ps1

.EXAMPLE
    .\Get-WiFiProfileAudit.ps1 -StaleSyncDays 7

.NOTES
    Requires: Microsoft.Graph.Beta.DeviceManagement module,
              Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All",
              "DeviceManagementManagedDevices.Read.All"
    Run as:   Any account with Intune device configuration + managed device read rights.
    Safe to run repeatedly — read-only, no changes made.
    Companion runbooks: macOS/Troubleshooting/WiFi-8021x-A.md, WiFi-8021x-B.md
    Related but distinct: NDES/SCEP server-side health is not visible via this script — see
    Windows/Troubleshooting/ certificate services content for on-prem PKI diagnosis.
#>

[CmdletBinding()]
param(
    [int]$StaleSyncDays = 14,
    [string]$OutputPath = "$env:TEMP\WiFiProfileAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

Write-Status "macOS Wi-Fi/802.1X profile audit started — $(Get-Date)" "INFO"

# ─── Preflight ──────────────────────────────────────────────────────────────────

try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "No Graph context." }
    $requiredScopes = @("DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All")
    $missing = $requiredScopes | Where-Object { $ctx.Scopes -notcontains $_ }
    if ($missing) {
        Write-Status "Current Graph session is missing scope(s): $($missing -join ', ') — connecting again." "WARN"
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }
} catch {
    Write-Status "Not connected to Microsoft Graph. Connecting now..." "WARN"
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All" -NoWelcome
}

if (-not (Get-Module -ListAvailable -Name "Microsoft.Graph.Beta.DeviceManagement")) {
    Write-Status "Microsoft.Graph.Beta.DeviceManagement module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Beta.DeviceManagement -Scope CurrentUser" "ERROR"
    exit 1
}

# ─── Part 1: Pull and bucket relevant device configuration profiles ────────────

Write-Status "Querying device configuration profiles..." "INFO"

try {
    $allConfigs = Get-MgBetaDeviceManagementDeviceConfiguration -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query device configuration profiles: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Substring patterns matched case-insensitively against @odata.type to bucket by role.
$networkTypePatterns = @("wifi", "wired")
$trustedRootPatterns = @("trustedrootcertificate")
$scepPatterns        = @("scepcertificate")
$pkcsPatterns        = @("pkcscertificate")

function Test-TypeMatch {
    param([string]$TypeString, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ($TypeString -match [regex]::Escape($p)) { return $true }
    }
    return $false
}

function Get-OdataType {
    param($Config)
    $t = $Config.AdditionalProperties['@odata.type']
    if (-not $t) { $t = $Config.GetType().Name }
    return $t.ToString().TrimStart('#').Replace('microsoft.graph.', '')
}

$networkProfiles     = [System.Collections.Generic.List[PSObject]]::new()
$trustedRootProfiles  = [System.Collections.Generic.List[PSObject]]::new()
$scepProfiles         = [System.Collections.Generic.List[PSObject]]::new()
$pkcsProfiles         = [System.Collections.Generic.List[PSObject]]::new()

foreach ($c in $allConfigs) {
    $typeStr = Get-OdataType -Config $c
    $lower = $typeStr.ToLowerInvariant()

    # Only consider Apple/macOS-relevant profiles; skip obviously unrelated types early.
    if (-not (Test-TypeMatch $lower $networkTypePatterns) -and
        -not (Test-TypeMatch $lower $trustedRootPatterns) -and
        -not (Test-TypeMatch $lower $scepPatterns) -and
        -not (Test-TypeMatch $lower $pkcsPatterns)) {
        continue
    }
    if ($lower -notmatch "macos|apple") { continue }

    $assignments = @()
    try {
        $assignments = Get-MgBetaDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId $c.Id -ErrorAction Stop
    } catch {
        Write-Status "  Could not read assignments for '$($c.DisplayName)': $($_.Exception.Message)" "WARN"
    }

    $groupIds = @()
    foreach ($a in $assignments) {
        $gid = $a.Target.AdditionalProperties['groupId']
        if ($gid) { $groupIds += $gid }
    }

    $entry = [PSCustomObject]@{
        Id           = $c.Id
        DisplayName  = $c.DisplayName
        OdataType    = $typeStr
        GroupIds     = $groupIds
        LastModified = $c.LastModifiedDateTime
    }

    if (Test-TypeMatch $lower $networkTypePatterns)    { $networkProfiles.Add($entry) }
    elseif (Test-TypeMatch $lower $trustedRootPatterns) { $trustedRootProfiles.Add($entry) }
    elseif (Test-TypeMatch $lower $scepPatterns)        { $scepProfiles.Add($entry) }
    elseif (Test-TypeMatch $lower $pkcsPatterns)        { $pkcsProfiles.Add($entry) }
}

Write-Status "Found: $($networkProfiles.Count) network (Wi-Fi/Wired), $($trustedRootProfiles.Count) trusted-root, $($scepProfiles.Count) SCEP, $($pkcsProfiles.Count) PKCS profile(s)." "INFO"

$AllProfileResults = [System.Collections.Generic.List[PSObject]]::new()
foreach ($p in @($networkProfiles + $trustedRootProfiles + $scepProfiles + $pkcsProfiles)) {
    $AllProfileResults.Add([PSCustomObject]@{
        Role         = if ($networkProfiles.Contains($p)) { "Network" }
                        elseif ($trustedRootProfiles.Contains($p)) { "TrustedRoot" }
                        elseif ($scepProfiles.Contains($p)) { "SCEP" }
                        else { "PKCS" }
        DisplayName  = $p.DisplayName
        OdataType    = $p.OdataType
        GroupIds     = ($p.GroupIds -join "; ")
        LastModified = $p.LastModified
    })
}

# ─── Part 2: Cross-reference scope gaps — the "three-legged stool" check ───────

Write-Status "`nCross-referencing assignment scope across network / trusted-root / cert profiles..." "INFO"

$allCertGroupIds = @()
$trustedRootProfiles | ForEach-Object { $allCertGroupIds += $_.GroupIds }
$scepProfiles        | ForEach-Object { $allCertGroupIds += $_.GroupIds }
$pkcsProfiles        | ForEach-Object { $allCertGroupIds += $_.GroupIds }
$allCertGroupIds = $allCertGroupIds | Select-Object -Unique

$allTrustedRootGroupIds = ($trustedRootProfiles | ForEach-Object { $_.GroupIds }) | Select-Object -Unique
$allCredGroupIds        = (($scepProfiles + $pkcsProfiles) | ForEach-Object { $_.GroupIds }) | Select-Object -Unique

$ScopeGapResults = [System.Collections.Generic.List[PSObject]]::new()

if ($networkProfiles.Count -eq 0) {
    Write-Status "No macOS Wi-Fi/Wired network profiles found — nothing to cross-reference." "WARN"
} else {
    foreach ($np in $networkProfiles) {
        if ($np.GroupIds.Count -eq 0) {
            Write-Status "[$($np.DisplayName)] UNASSIGNED — profile has no assignment target at all." "WARN"
            $ScopeGapResults.Add([PSCustomObject]@{
                NetworkProfile = $np.DisplayName
                Issue          = "UNASSIGNED"
                Detail         = "Network profile has no group assignment; it will never deliver to any device."
            })
            continue
        }

        foreach ($gid in $np.GroupIds) {
            $hasTrustedRoot = $allTrustedRootGroupIds -contains $gid
            $hasCredential  = $allCredGroupIds -contains $gid

            if (-not $hasTrustedRoot -and -not $hasCredential) {
                Write-Status "[$($np.DisplayName)] group $gid has NO matching Trusted-root AND NO matching SCEP/PKCS profile." "WARN"
                $ScopeGapResults.Add([PSCustomObject]@{
                    NetworkProfile = $np.DisplayName
                    Issue          = "MISSING_BOTH_CERT_PROFILES"
                    Detail         = "Group $gid has no Trusted-root profile and no SCEP/PKCS profile in the same scope."
                })
            } elseif (-not $hasTrustedRoot) {
                Write-Status "[$($np.DisplayName)] group $gid has NO matching Trusted-root profile (server trust gap)." "WARN"
                $ScopeGapResults.Add([PSCustomObject]@{
                    NetworkProfile = $np.DisplayName
                    Issue          = "MISSING_TRUSTED_ROOT"
                    Detail         = "Group $gid has a client-cert profile but no Trusted-root profile in the same scope — server trust evaluation will fail."
                })
            } elseif (-not $hasCredential) {
                Write-Status "[$($np.DisplayName)] group $gid has NO matching SCEP/PKCS profile (client identity gap)." "WARN"
                $ScopeGapResults.Add([PSCustomObject]@{
                    NetworkProfile = $np.DisplayName
                    Issue          = "MISSING_CLIENT_CERT"
                    Detail         = "Group $gid has a Trusted-root profile but no SCEP/PKCS profile in the same scope — device will have no client identity certificate."
                })
            } else {
                Write-Status "[$($np.DisplayName)] group $gid — Trusted-root and SCEP/PKCS coverage both present." "OK"
            }
        }
    }
}

# ─── Part 3: macOS device sync freshness (check-in-gated delivery) ─────────────

Write-Status "`nPulling macOS managed devices for sync-freshness check..." "INFO"

try {
    $macDevices = Get-MgBetaDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query managed devices: $($_.Exception.Message)" "ERROR"
    exit 1
}

$now = Get-Date
$DeviceResults = [System.Collections.Generic.List[PSObject]]::new()

foreach ($d in $macDevices) {
    $lastSync = $d.LastSyncDateTime
    $daysSinceSync = if ($lastSync) { [math]::Round(($now - $lastSync).TotalDays, 1) } else { $null }
    $stale = ($null -eq $lastSync) -or ($daysSinceSync -ge $StaleSyncDays)

    $DeviceResults.Add([PSCustomObject]@{
        DeviceName        = $d.DeviceName
        SerialNumber      = $d.SerialNumber
        OSVersion         = $d.OsVersion
        LastSyncDateTime  = $lastSync
        DaysSinceLastSync = $daysSinceSync
        Stale             = $stale
    })
}

$staleDevices = $DeviceResults | Where-Object { $_.Stale }
Write-Status "macOS devices evaluated: $($DeviceResults.Count) — stale (>=$StaleSyncDays days): $($staleDevices.Count)" $(if ($staleDevices.Count -gt 0) { "WARN" } else { "OK" })

# ─── Summary ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Magenta
Write-Status "Network (Wi-Fi/Wired) profiles:     $($networkProfiles.Count)"
Write-Status "Trusted-root profiles:              $($trustedRootProfiles.Count)"
Write-Status "SCEP/PKCS certificate profiles:     $($scepProfiles.Count + $pkcsProfiles.Count)"
Write-Status "Scope gaps found:                   $($ScopeGapResults.Count)" $(if ($ScopeGapResults.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Stale macOS devices (>=$StaleSyncDays days): $($staleDevices.Count)" $(if ($staleDevices.Count -gt 0) { "WARN" } else { "OK" })

if ($ScopeGapResults.Count -gt 0) {
    Write-Host ""
    Write-Host "Scope gaps mean a network profile's assigned group has no matching Trusted-root and/or" -ForegroundColor Yellow
    Write-Host "SCEP/PKCS profile in the SAME group — authentication will fail for devices in that group" -ForegroundColor Yellow
    Write-Host "even though the network profile itself delivers successfully. See WiFi-8021x-B.md Fix 1/2." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "This script does NOT verify deployment channel (User/Device) vs. certificate-profile scope" -ForegroundColor Yellow
Write-Host "match, and does NOT confirm the wired-network @odata.type pattern against a live tenant —" -ForegroundColor Yellow
Write-Host "verify both manually per WiFi-8021x-A.md if wired profiles don't appear in the Network bucket." -ForegroundColor Yellow

# ─── Export ──────────────────────────────────────────────────────────────────────

$AllProfileResults | Export-Csv -Path "$OutputPath-Profiles.csv" -NoTypeInformation
$ScopeGapResults    | Export-Csv -Path "$OutputPath-ScopeGaps.csv" -NoTypeInformation
$DeviceResults      | Export-Csv -Path "$OutputPath-Devices.csv" -NoTypeInformation
Write-Status "`nProfile report:   $OutputPath-Profiles.csv" "INFO"
Write-Status "Scope gap report: $OutputPath-ScopeGaps.csv" "INFO"
Write-Status "Device report:    $OutputPath-Devices.csv" "INFO"
Write-Status "Done." "OK"
