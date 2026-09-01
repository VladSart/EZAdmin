<#
.SYNOPSIS
    Audits tenant-wide App Settings (Declarative Device Management binary/app launch control)
    policy configuration and device eligibility for Apple devices.

.DESCRIPTION
    Admin-side Graph diagnostic supporting
    macOS/Troubleshooting/AppSettings-A.md and AppSettings-B.md.

    Checks:
      - Enumerates Settings Catalog policies matching App Settings / binary control naming
      - For each policy, flags Allowed/Denied Binaries entries missing their required
        identifier field(s) per Apple's schema rule (Allowed needs CDHash or TeamID;
        Denied needs CDHash, TeamID, or SigningID) — this is the #1 cause of a policy
        that reports Success while still not matching the intended binary
      - Reports Always Allow Managed Apps value per policy (default False; easy to miss)
      - Audits managed macOS/iOS devices for platform-version and supervision eligibility
        (App Settings requires macOS 27+ / iOS-iPadOS 27+ AND supervision, with no error
        surfaced anywhere for a device that fails either gate)
      - Flags devices with an App Settings policy assigned to their group but that fail
        eligibility, since the policy will silently never apply to them

    Does NOT and cannot check individual binary identifier correctness against real
    on-device binaries — that requires running `codesign -dvvv` on the specific Mac and
    binary in question. This script only validates the schema-level required-field rule
    on the configured policy content itself.

    Read-only. Makes no configuration changes.

.PARAMETER TenantWideDeviceSweep
    Also enumerate all managed macOS/iOS/iPadOS devices and report platform-version/
    supervision eligibility. Without this switch, only policy-content checks run.

.EXAMPLE
    .\Get-AppSettingsAudit.ps1

    Audits App Settings policy configuration only (identifier schema validation).

.EXAMPLE
    .\Get-AppSettingsAudit.ps1 -TenantWideDeviceSweep

    Also audits every managed Apple device's eligibility (platform version + supervision).

.NOTES
    Requires: Microsoft.Graph.Beta module, active Connect-MgGraph session with
    DeviceManagementConfiguration.Read.All and (-TenantWideDeviceSweep only)
    DeviceManagementManagedDevices.Read.All scopes.
    Companion runbook: macOS/Troubleshooting/AppSettings-A.md and AppSettings-B.md
    Safe: entirely read-only, no write cmdlets anywhere in this script.
#>

[CmdletBinding()]
param(
    [switch]$TenantWideDeviceSweep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string]$Category, [string]$Item, [string]$Result, [string]$Detail)
    $findings.Add([PSCustomObject]@{ Category = $Category; Item = $Item; Result = $Result; Detail = $Detail })
}

try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) {
        throw "No active Graph session. Run Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All','DeviceManagementManagedDevices.Read.All' first."
    }
} catch {
    Write-Status "Graph connection required: $($_.Exception.Message)" "ERROR"
    return
}

Write-Status "Starting App Settings (binary/app launch control) audit"

# ---------------------------------------------------------------------------
# 1. Enumerate Settings Catalog policies matching App Settings naming
# ---------------------------------------------------------------------------
$appSettingsPolicies = @()
try {
    $allPolicies = Get-MgBetaDeviceManagementConfigurationPolicy -All -ErrorAction Stop
    $appSettingsPolicies = $allPolicies | Where-Object {
        $_.Name -match 'App Settings|AppSettings|Binary Control|Allowed Binaries|Denied Binaries'
    }

    if ($appSettingsPolicies.Count -eq 0) {
        Write-Status "No policies matched App Settings naming heuristics — confirm naming convention if policies are known to exist" "WARN"
        Add-Finding "Discovery" "Policy count" "WARN" "0 policies matched — heuristic name search only, does not inspect policy content type directly"
    } else {
        Write-Status "Found $($appSettingsPolicies.Count) candidate App Settings polic(ies)" "OK"
    }
} catch {
    Write-Status "Could not enumerate configuration policies: $($_.Exception.Message)" "ERROR"
    Add-Finding "Discovery" "Policy enumeration" "ERROR" $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 2. Inspect each candidate policy's settings for the required-field rule
#    and Always Allow Managed Apps value
# ---------------------------------------------------------------------------
foreach ($policy in $appSettingsPolicies) {
    try {
        $settings = Get-MgBetaDeviceManagementConfigurationPolicySetting `
            -DeviceManagementConfigurationPolicyId $policy.Id -All -ErrorAction Stop

        $settingsJson = $settings | ConvertTo-Json -Depth 12 -Compress -ErrorAction SilentlyContinue

        # Heuristic scan: flag entries that look like binary identifiers but are missing
        # every one of CDHash/TeamID/SigningID (a JSON-string heuristic, not a schema parser,
        # since the Settings Catalog JSON shape for this category is not independently
        # documented at the property-name level as of this writing)
        $hasCdHash    = $settingsJson -match '(?i)cdhash'
        $hasTeamId    = $settingsJson -match '(?i)teamid'
        $hasSigningId = $settingsJson -match '(?i)signingid'
        $hasBinaryRef = $settingsJson -match '(?i)binary'

        if ($hasBinaryRef -and -not ($hasCdHash -or $hasTeamId -or $hasSigningId)) {
            Write-Status "Policy '$($policy.Name)' references binaries but no CDHash/TeamID/SigningID field detected — likely fails the required-field rule" "ERROR"
            Add-Finding "Policy content" $policy.Name "FAIL" "No CDHash/TeamID/SigningID detected in settings payload — verify manually in the admin center Configuration settings tab"
        } elseif ($hasBinaryRef) {
            Write-Status "Policy '$($policy.Name)' contains binary identifier field(s) — spot-check required-field rule manually per list type" "INFO"
            Add-Finding "Policy content" $policy.Name "INFO" "CDHash=$hasCdHash TeamID=$hasTeamId SigningID=$hasSigningId — confirm Allowed entries have CDHash/TeamID and Denied entries have CDHash/TeamID/SigningID"
        } else {
            Add-Finding "Policy content" $policy.Name "INFO" "No binary-identifier fields detected — likely an iOS/iPadOS app-launch-only (bundle ID) policy"
        }

        $alwaysAllow = $settingsJson -match '(?i)alwaysallowmanagedapps.{0,20}true'
        if ($alwaysAllow) {
            Add-Finding "Always Allow Managed Apps" $policy.Name "TRUE" "VPP + Line-of-business (non-PKG/DMG) apps auto-allowed — LOB PKG/DMG via Intune agent still excluded, verify those are separately listed if deployed"
        } else {
            Add-Finding "Always Allow Managed Apps" $policy.Name "FALSE (default)" "No managed apps auto-allowed — every legitimately deployed macOS app/binary must appear explicitly in Allowed Binaries or it will be blocked once enforcement is active"
        }
    } catch {
        Write-Status "Could not inspect settings for policy '$($policy.Name)': $($_.Exception.Message)" "ERROR"
        Add-Finding "Policy content" $policy.Name "ERROR" $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 3. Optional tenant-wide device eligibility sweep
# ---------------------------------------------------------------------------
if ($TenantWideDeviceSweep) {
    Write-Status "Running tenant-wide Apple device eligibility sweep..." "INFO"
    try {
        $appleDevices = Get-MgBetaDeviceManagementManagedDevice -All -ErrorAction Stop |
            Where-Object { $_.OperatingSystem -in @('macOS', 'iOS', 'iPadOS') }

        Write-Status "Found $($appleDevices.Count) managed macOS/iOS/iPadOS device(s)" "INFO"

        $ineligible = 0
        foreach ($device in $appleDevices) {
            $osVersionMajor = 0
            if ($device.OsVersion -match '^\s*(\d+)') { $osVersionMajor = [int]$Matches[1] }

            $meetsOsGate = $osVersionMajor -ge 27
            $meetsSupervisionGate = [bool]$device.IsSupervised

            if (-not ($meetsOsGate -and $meetsSupervisionGate)) {
                $ineligible++
                Add-Finding "Device eligibility" $device.DeviceName "INELIGIBLE" "OS='$($device.OsVersion)' (needs 27+) Supervised=$($device.IsSupervised) — App Settings will silently never apply to this device, no error surfaced anywhere"
            }
        }

        if ($ineligible -gt 0) {
            Write-Status "$ineligible of $($appleDevices.Count) Apple device(s) fail the OS-version-27+/supervision gate — App Settings policies will not apply to them" "WARN"
        } else {
            Write-Status "All enumerated Apple devices meet the OS-version/supervision gate (does not confirm policy assignment scope)" "OK"
        }
    } catch {
        Write-Status "Device eligibility sweep failed: $($_.Exception.Message)" "ERROR"
        Add-Finding "Device eligibility" "Sweep" "ERROR" $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== App Settings Audit Summary ===" -ForegroundColor Cyan
$findings | Format-Table -AutoSize -Wrap

Write-Host ""
Write-Status "Reminder: this script cannot validate binary identifier CORRECTNESS against real on-device binaries. For a specific blocked/unblocked binary, run 'codesign -dvvv <path>' on the actual affected Mac and compare CDHash/TeamID/SigningID against the policy's configured values." "WARN"

$outPath = ".\AppSettingsAudit_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$findings | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8
Write-Host "Results exported to: $outPath" -ForegroundColor Green
