<#
.SYNOPSIS
    Reports macOS fleet-wide DDM (Declarative Device Management) eligibility and inventories
    Settings Catalog policies in the "Declarative Device Management" category, to speed up triage
    per DDM-B.md before assuming an individual device's DDM channel itself is broken.

.DESCRIPTION
    Companion script to macOS/Troubleshooting/DDM-A.md and DDM-B.md.

    DDM is a *transport*, not a single feature — Software Updates, Compliance evaluation, and a
    growing share of Settings Catalog macOS settings all ride the same declarative channel, which
    has a hard protocol floor of macOS 13 (Ventura). The single most common "DDM is broken" ticket
    is actually a device that was never DDM-eligible in the first place. This script answers that
    question fleet-wide before anyone spends time on `mdmclient QueryDeclarations` device-by-device.

    Graph does NOT expose a device's live declaration/status-channel state (QueryDeclarations and
    QueryResponses are device-local mdmclient calls only — see DDM-A.md's Command Cheat Sheet for
    the on-device equivalent). This script covers what IS visible fleet-wide from the admin side:

    1. FLEET ELIGIBILITY — every enrolled macOS device's OS version, supervision state, and sync
       freshness. Flags DDM_INELIGIBLE_OS (macOS below 13.0) and NOT_SUPERVISED (many DDM-delivered
       declaration types require supervision independently of the DDM transport itself) and
       SYNC_STALE (device may be holding stale declarations if something changed since last check-in).

    2. DDM POLICY INVENTORY — every macOS Settings Catalog configuration policy, flagged as
       DDM-category or not based on whether its constituent settings reference the
       "declarative" configuration category, along with assignment targets. Because Settings
       Catalog policies can mix DDM-category and non-DDM-category settings in ways not always
       cleanly separable via Graph's policy metadata alone, this script flags candidates by name
       pattern AND by querying each policy's settings for known DDM-category setting definition
       ID prefixes — treat the DDM flag as a strong signal, not an absolute guarantee; confirm
       ambiguous cases in the Intune portal (Devices > Configuration > filter by category).

    3. CROSS-REFERENCE — for each flagged DDM-category policy, reports how many of its assigned
       devices are DDM-ineligible (OS < 13), so an admin can immediately see "this policy will
       silently never reach N of its M assigned devices" before troubleshooting individual tickets.

    Read-only. Does not create, modify, assign, or remove any policy, and does not touch any
    device's declarations, status responses, or MDM enrollment.

.PARAMETER StaleSyncDays
    Number of days since last successful check-in before a macOS device is flagged SYNC_STALE.
    Default 14.

.PARAMETER MinDDMOSVersion
    Minimum macOS version required for DDM eligibility. Default "13.0" (Ventura) per Apple's
    documented protocol floor. Override only if a future Apple/Microsoft change is confirmed.

.PARAMETER OutputPath
    Base path (without extension) to export two CSV reports:
    "<OutputPath>-Devices.csv" and "<OutputPath>-Policies.csv"
    Default: $env:TEMP\DDMStatusAudit-<date>

.EXAMPLE
    .\Get-DDMStatusAudit.ps1

.EXAMPLE
    .\Get-DDMStatusAudit.ps1 -StaleSyncDays 7

.NOTES
    Requires: Microsoft.Graph.Beta.DeviceManagement module,
              Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All",
              "DeviceManagementManagedDevices.Read.All"
    Run as:   Any account with Intune device configuration + managed device read rights.
    Safe to run repeatedly — read-only, no changes made.
    Companion runbooks: macOS/Troubleshooting/DDM-A.md, DDM-B.md
    Related but distinct: for Software-Update-specific status (not general DDM channel health),
    see Scripts/Get-SoftwareUpdateStatus.sh (device-local) — a device can be DDM-healthy and still
    fail an individual Software Update declaration for update-specific reasons.
#>

[CmdletBinding()]
param(
    [int]$StaleSyncDays = 14,
    [string]$MinDDMOSVersion = "13.0",
    [string]$OutputPath = "$env:TEMP\DDMStatusAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

function Test-DDMEligibleVersion {
    param([string]$OsVersion, [string]$MinVersion)
    if ([string]::IsNullOrWhiteSpace($OsVersion)) { return $false }
    try {
        # macOS version strings are typically "13.4.1" — compare major.minor only for robustness
        $osParts  = ($OsVersion -split '\.') | Select-Object -First 2 | ForEach-Object { [int]$_ }
        $minParts = ($MinVersion -split '\.') | Select-Object -First 2 | ForEach-Object { [int]$_ }
        if ($osParts[0] -ne $minParts[0]) { return $osParts[0] -gt $minParts[0] }
        return $osParts[1] -ge $minParts[1]
    } catch {
        return $null  # unparseable version string — flag separately, don't guess
    }
}

Write-Status "macOS DDM (Declarative Device Management) status audit started — $(Get-Date)" "INFO"

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

# ─── Part 1: macOS fleet DDM eligibility ────────────────────────────────────────

Write-Status "Pulling macOS managed devices for DDM eligibility check (min OS $MinDDMOSVersion)..." "INFO"

try {
    $macDevices = Get-MgBetaDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query managed devices: $($_.Exception.Message)" "ERROR"
    exit 1
}

if (-not $macDevices -or $macDevices.Count -eq 0) {
    Write-Status "No macOS managed devices found. Nothing further to report." "WARN"
    exit 0
}

Write-Status "Found $($macDevices.Count) macOS device(s) to evaluate." "INFO"
Write-Host ""

$now = Get-Date
$DeviceResults = [System.Collections.Generic.List[PSObject]]::new()

foreach ($d in $macDevices) {

    $lastSync = $d.LastSyncDateTime
    $daysSinceSync = if ($lastSync) { [math]::Round(($now - $lastSync).TotalDays, 1) } else { $null }
    $ddmEligible = Test-DDMEligibleVersion -OsVersion $d.OsVersion -MinVersion $MinDDMOSVersion

    $flags = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $ddmEligible) {
        $flags.Add("OS_VERSION_UNPARSEABLE")
    } elseif (-not $ddmEligible) {
        $flags.Add("DDM_INELIGIBLE_OS")
    }

    if (-not $d.IsSupervised) {
        $flags.Add("NOT_SUPERVISED")
    }

    if ($null -eq $lastSync) {
        $flags.Add("NEVER_SYNCED")
    } elseif ($daysSinceSync -ge $StaleSyncDays) {
        $flags.Add("SYNC_STALE")
    }

    $status = if ($flags.Count -gt 0) { "WARN" } else { "OK" }

    Write-Status "[$($d.DeviceName)] os=$($d.OsVersion) supervised=$($d.IsSupervised) lastSync=$lastSync ($daysSinceSync days ago)" $status
    if ($flags.Count -gt 0) {
        Write-Status "    Flags: $($flags -join ', ')" $status
    }

    $DeviceResults.Add([PSCustomObject]@{
        DeviceId          = $d.Id
        DeviceName        = $d.DeviceName
        SerialNumber      = $d.SerialNumber
        OSVersion         = $d.OsVersion
        DDMEligible       = $ddmEligible
        IsSupervised      = $d.IsSupervised
        EnrollmentType    = $d.DeviceEnrollmentType
        LastSyncDateTime  = $lastSync
        DaysSinceLastSync = $daysSinceSync
        Flags             = ($flags -join "; ")
        Status            = $status
    })
}

# ─── Part 2: DDM-category Settings Catalog policy inventory ────────────────────

Write-Status "`nSearching macOS Settings Catalog policies for DDM-category settings..." "INFO"

try {
    $allPolicies = Get-MgBetaDeviceManagementConfigurationPolicy -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query configuration policies: $($_.Exception.Message)" "ERROR"
    exit 1
}

$macPolicies = $allPolicies | Where-Object { $_.Platforms -match "macOS" -or $_.Platforms -match "all" }

$PolicyResults = [System.Collections.Generic.List[PSObject]]::new()

if (-not $macPolicies -or $macPolicies.Count -eq 0) {
    Write-Status "No macOS Settings Catalog policies found." "WARN"
} else {
    foreach ($p in $macPolicies) {

        # Heuristic DDM-category detection: name pattern OR setting-definition-id substring match.
        # Graph's policy-level metadata does not expose a single reliable "isDDM" boolean, so this
        # combines both signals rather than trusting either alone — see .DESCRIPTION caveat.
        $nameMatch = $p.Name -match "(?i)software\s*update|declarative|ddm|compliance"

        $settingMatch = $false
        try {
            $settings = Get-MgBetaDeviceManagementConfigurationPolicySetting -DeviceManagementConfigurationPolicyId $p.Id -ErrorAction Stop
            foreach ($s in $settings) {
                $defId = $s.SettingInstance.SettingDefinitionId
                if ($defId -match "(?i)declarative|softwareupdate\.enforcement|com\.apple\.configuration") {
                    $settingMatch = $true
                    break
                }
            }
        } catch {
            Write-Status "  Could not read settings for policy '$($p.Name)': $($_.Exception.Message)" "WARN"
        }

        $isDDMCandidate = $nameMatch -or $settingMatch
        if (-not $isDDMCandidate) { continue }

        $assignments = @()
        try {
            $assignments = Get-MgBetaDeviceManagementConfigurationPolicyAssignment -DeviceManagementConfigurationPolicyId $p.Id -ErrorAction Stop
        } catch {
            Write-Status "  Could not read assignments for policy '$($p.Name)': $($_.Exception.Message)" "WARN"
        }

        $targetGroupIds = @()
        $targets = if ($assignments) {
            ($assignments | ForEach-Object {
                if ($_.Target.AdditionalProperties['groupId']) {
                    $targetGroupIds += $_.Target.AdditionalProperties['groupId']
                    $_.Target.AdditionalProperties['groupId']
                } else { $_.Target.AdditionalProperties['@odata.type'] }
            }) -join "; "
        } else { "UNASSIGNED" }

        # Cross-reference: how many devices targeted by this policy are DDM-ineligible?
        # Best-effort — only meaningful for group-based assignments where we can resolve membership;
        # "All devices" assignments are reported against the full ineligible count computed in Part 1.
        $ineligibleCount = "N/A (see Part 1 fleet totals for 'All devices' assignments)"
        if ($targetGroupIds.Count -gt 0) {
            $memberIneligible = 0
            foreach ($gid in $targetGroupIds) {
                try {
                    $members = Get-MgGroupMember -GroupId $gid -All -ErrorAction Stop
                    foreach ($m in $members) {
                        $match = $DeviceResults | Where-Object { $_.DeviceId -eq $m.Id -and $_.Flags -match "DDM_INELIGIBLE_OS" }
                        if ($match) { $memberIneligible++ }
                    }
                } catch {
                    # Group may be device-targeted rather than user-targeted, or membership unreadable
                    # with current scopes — not fatal, just skip the cross-reference for this group.
                }
            }
            $ineligibleCount = $memberIneligible
        }

        Write-Status "[$($p.Name)] platforms=$($p.Platforms) DDM-nameMatch=$nameMatch DDM-settingMatch=$settingMatch assignments=$targets ineligibleTargets=$ineligibleCount" $(if ($targets -eq "UNASSIGNED") { "WARN" } else { "OK" })

        $PolicyResults.Add([PSCustomObject]@{
            PolicyId              = $p.Id
            PolicyName            = $p.Name
            Platforms             = $p.Platforms
            NameMatchedDDM        = $nameMatch
            SettingMatchedDDM     = $settingMatch
            AssignmentTargets     = $targets
            IneligibleTargetCount = $ineligibleCount
            LastModified          = $p.LastModifiedDateTime
        })
    }
}

# ─── Summary ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Magenta

$ineligibleOS  = $DeviceResults | Where-Object { $_.Flags -match "DDM_INELIGIBLE_OS" }
$notSupervised = $DeviceResults | Where-Object { $_.Flags -match "NOT_SUPERVISED" }
$stale         = $DeviceResults | Where-Object { $_.Flags -match "SYNC_STALE|NEVER_SYNCED" }
$unassignedPol = $PolicyResults | Where-Object { $_.AssignmentTargets -eq "UNASSIGNED" }

Write-Status "macOS devices evaluated:              $($DeviceResults.Count)"
Write-Status "  ...DDM-ineligible (OS < $MinDDMOSVersion):    $($ineligibleOS.Count)" $(if ($ineligibleOS.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "  ...not supervised:                  $($notSupervised.Count)" $(if ($notSupervised.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "  ...stale/never synced (>=$StaleSyncDays days): $($stale.Count)" $(if ($stale.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "DDM-category candidate policies found: $($PolicyResults.Count)"
Write-Status "  ...unassigned:                       $($unassignedPol.Count)" $(if ($unassignedPol.Count -gt 0) { "WARN" } else { "OK" })

if ($ineligibleOS.Count -gt 0) {
    Write-Host ""
    Write-Host "Devices flagged DDM_INELIGIBLE_OS will NEVER receive any DDM-delivered declaration" -ForegroundColor Yellow
    Write-Host "(Software Update via DDM, and an increasing share of Settings Catalog settings) until" -ForegroundColor Yellow
    Write-Host "upgraded to macOS $MinDDMOSVersion or later. This is expected behavior, not a fault — see DDM-B.md Fix 2." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "This script cannot see a device's live declarations or status-channel responses — those" -ForegroundColor Yellow
Write-Host "are device-local only (mdmclient QueryDeclarations / QueryResponses). Use this report to" -ForegroundColor Yellow
Write-Host "rule out fleet-wide eligibility/assignment gaps before troubleshooting an individual device." -ForegroundColor Yellow

# ─── Export ──────────────────────────────────────────────────────────────────────

$DeviceResults | Export-Csv -Path "$OutputPath-Devices.csv" -NoTypeInformation
$PolicyResults | Export-Csv -Path "$OutputPath-Policies.csv" -NoTypeInformation
Write-Status "`nDevice report:  $OutputPath-Devices.csv" "INFO"
Write-Status "Policy report:  $OutputPath-Policies.csv" "INFO"
Write-Status "Done." "OK"
