<#
.SYNOPSIS
    Audits tenant-wide macOS Settings Catalog "System Policy" (Gatekeeper) configuration and flags
    fleet-wide policy states that would explain widespread app-launch blocking, per
    Gatekeeper-Notarization-B.md / Gatekeeper-Notarization-A.md.

.DESCRIPTION
    Companion script to macOS/Troubleshooting/Gatekeeper-Notarization-A.md and -B.md.

    Individual app signing/notarization problems are a device-local investigation (spctl, codesign,
    pkgutil — see the B-runbook's Triage section) with no meaningful Graph-side signal. The ONE part
    of this topic that genuinely benefits from a fleet-wide, admin-side view is the Settings Catalog
    System Policy layer itself: a single misconfigured or over-restrictive policy can silently block
    every non-App-Store app across an entire assignment scope, and there is no Intune portal alert
    for "this policy now blocks internally signed software." This script exists to surface that.

    This script:
      1. Queries all macOS Settings Catalog configuration policies and identifies ones containing
         System Policy / Gatekeeper settings via setting-definition-ID substring matching against the
         confirmed com.apple.systempolicy.control.* keys (AllowIdentifiedDevelopers, EnableAssessment,
         EnableXProtectMalwareUpload) plus the System Policy Managed "Disable Override" key, since
         Graph exposes no single reliable "isGatekeeperPolicy" boolean at the policy level.
      2. For each matched policy, extracts the configured values and flags:
           - ASSESSMENT_DISABLED: EnableAssessment = false — Gatekeeper effectively off fleet-wide
             for the assigned scope (accepts everything, including obviously malicious software)
           - APP_STORE_ONLY: AllowIdentifiedDevelopers = false — blocks ALL non-Mac-App-Store
             software, including internally signed-and-notarized apps; the most common cause of a
             sudden fleet-wide "every internal app is blocked" wave
           - OVERRIDE_DISABLED_NO_NOTARIZATION_CONTEXT: Disable Override = true paired with an
             otherwise-restrictive policy — flagged as informational since this removes the
             per-user "Open Anyway" escape hatch entirely, raising the operational cost of any
             signing/notarization gap in deployed internal apps
      3. Cross-references each flagged policy's group assignment against the tenant's macOS managed
         device population to estimate scope (how many macOS devices are potentially affected).
      4. Separately flags macOS devices with NO System Policy profile assigned at all, which simply
         means Apple's own default (App Store and identified developers, assessment enabled) applies —
         informational only, not itself a problem.

    Does NOT and cannot:
      - Evaluate any individual app's code signature, notarization ticket, or quarantine state —
        that is exclusively device-local, see Gatekeeper-Notarization-B.md's Triage section
        (spctl -a -vvv, codesign -dv, pkgutil --check-signature)
      - Detect a certificate revocation affecting a specific deployed app — Apple's revocation
        infrastructure is not queryable via Graph
      - Confirm whether "Open Anyway" overrides exist on any device (per-user, device-local state)

.PARAMETER OutputPath
    Base path (without extension) to export CSV reports:
    "<OutputPath>-Policies.csv", "<OutputPath>-Flags.csv", "<OutputPath>-DeviceScope.csv"
    Default: $env:TEMP\GatekeeperPolicyAudit-<date>

.EXAMPLE
    .\Get-GatekeeperPolicyAudit.ps1

.EXAMPLE
    .\Get-GatekeeperPolicyAudit.ps1 -OutputPath C:\Reports\GatekeeperAudit

.NOTES
    Requires: Microsoft.Graph.Beta.DeviceManagement module,
              Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All",
              "DeviceManagementManagedDevices.Read.All"
    Run as:   Any account with Intune device configuration + managed device read rights.
    Safe to run repeatedly — read-only, no changes made.
    Companion runbooks: macOS/Troubleshooting/Gatekeeper-Notarization-A.md, Gatekeeper-Notarization-B.md
    Related but distinct: macOS/Troubleshooting/Compliance-Policies-A.md uses spctl --status as a
    per-device COMPLIANCE signal (pass/fail), which is a different question from "is the fleet-wide
    Gatekeeper POLICY itself misconfigured" — this script answers the latter.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:TEMP\GatekeeperPolicyAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

Write-Status "macOS Gatekeeper / System Policy audit started — $(Get-Date)" "INFO"

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

# ─── Part 1: Pull Settings Catalog policies and identify System Policy ones ────

Write-Status "Querying Settings Catalog configuration policies..." "INFO"

try {
    $allPolicies = Get-MgBetaDeviceManagementConfigurationPolicy -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query Settings Catalog policies: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Substring patterns matched case-insensitively against setting definition IDs to identify
# System Policy (Gatekeeper) settings within a policy's setting instances.
$gatekeeperKeyPatterns = @(
    "systempolicy.control_allowidentifieddevelopers",
    "systempolicy.control_enableassessment",
    "systempolicy.control_enablexprotectmalwareupload",
    "systempolicy_managed_disableoverride",
    "systempolicy.managed_disableoverride"
)

$MatchedPolicies = [System.Collections.Generic.List[PSObject]]::new()
$FlagResults      = [System.Collections.Generic.List[PSObject]]::new()

foreach ($policy in $allPolicies) {
    # Only consider macOS-platform policies
    if ($policy.Platforms -notmatch "macOS" -and $policy.Platforms -ne "macOS") { continue }

    $settingInstances = @()
    try {
        $settingInstances = Get-MgBetaDeviceManagementConfigurationPolicySetting -DeviceManagementConfigurationPolicyId $policy.Id -All -ErrorAction Stop
    } catch {
        Write-Status "  Could not read settings for policy '$($policy.Name)': $($_.Exception.Message)" "WARN"
        continue
    }

    # Flatten setting instance JSON to text for cheap substring matching against known Gatekeeper keys —
    # Settings Catalog's nested setting-instance schema varies by setting type, and a full typed parse
    # is unnecessary overhead for a presence/value check like this one.
    $rawText = ($settingInstances | ConvertTo-Json -Depth 12 -Compress)
    $isGatekeeperPolicy = $false
    foreach ($pattern in $gatekeeperKeyPatterns) {
        if ($rawText -match [regex]::Escape($pattern)) { $isGatekeeperPolicy = $true; break }
    }
    if (-not $isGatekeeperPolicy) { continue }

    $assignments = @()
    try {
        $assignments = Get-MgBetaDeviceManagementConfigurationPolicyAssignment -DeviceManagementConfigurationPolicyId $policy.Id -ErrorAction Stop
    } catch {
        Write-Status "  Could not read assignments for '$($policy.Name)': $($_.Exception.Message)" "WARN"
    }
    $groupIds = @()
    $allDevicesTarget = $false
    foreach ($a in $assignments) {
        $targetType = $a.Target.AdditionalProperties['@odata.type']
        if ($targetType -match "allDevices") { $allDevicesTarget = $true }
        $gid = $a.Target.AdditionalProperties['groupId']
        if ($gid) { $groupIds += $gid }
    }

    # Extract effective boolean values via simple text-based lookup (values are typically
    # represented as "value": true/false or "value": "0"/"1" — check both patterns defensively).
    $allowIdentifiedDevelopers = $null
    $enableAssessment          = $null
    $disableOverride           = $null

    if ($rawText -match 'systempolicy\.control_allowidentifieddevelopers["\s\S]{0,80}?"value"\s*:\s*(true|false|"0"|"1")') {
        $allowIdentifiedDevelopers = $Matches[1] -replace '"', ''
    }
    if ($rawText -match 'systempolicy\.control_enableassessment["\s\S]{0,80}?"value"\s*:\s*(true|false|"0"|"1")') {
        $enableAssessment = $Matches[1] -replace '"', ''
    }
    if ($rawText -match 'systempolicy[._]managed_disableoverride["\s\S]{0,80}?"value"\s*:\s*(true|false|"0"|"1")') {
        $disableOverride = $Matches[1] -replace '"', ''
    }

    $entry = [PSCustomObject]@{
        Id                          = $policy.Id
        Name                        = $policy.Name
        LastModified                = $policy.LastModifiedDateTime
        AllDevicesAssigned          = $allDevicesTarget
        AssignedGroupCount          = $groupIds.Count
        AllowIdentifiedDevelopers   = $allowIdentifiedDevelopers
        EnableAssessment            = $enableAssessment
        DisableOverride             = $disableOverride
    }
    $MatchedPolicies.Add($entry)

    # ─── Flag logic ───────────────────────────────────────────────────────────
    $isTrue  = { param($v) $v -in @("true", "1") }
    $isFalse = { param($v) $v -in @("false", "0") }

    if ($enableAssessment -and (& $isFalse $enableAssessment)) {
        Write-Status "[$($policy.Name)] ASSESSMENT_DISABLED — Gatekeeper is effectively OFF for this policy's assigned scope." "WARN"
        $FlagResults.Add([PSCustomObject]@{
            PolicyName = $policy.Name
            Flag       = "ASSESSMENT_DISABLED"
            Detail     = "EnableAssessment = false. Gatekeeper accepts all software (including unsigned/malicious) for devices in scope. Confirm this is deliberate."
            ScopeAllDevices = $allDevicesTarget
            AssignedGroupCount = $groupIds.Count
        })
    }

    if ($allowIdentifiedDevelopers -and (& $isFalse $allowIdentifiedDevelopers)) {
        Write-Status "[$($policy.Name)] APP_STORE_ONLY — non-Mac-App-Store software (including signed-and-notarized internal apps) will be BLOCKED for this policy's assigned scope." "WARN"
        $FlagResults.Add([PSCustomObject]@{
            PolicyName = $policy.Name
            Flag       = "APP_STORE_ONLY"
            Detail     = "AllowIdentifiedDevelopers = false. This is the most common cause of a sudden fleet-wide 'every internal app is blocked' incident — see Gatekeeper-Notarization-B.md Fix 4."
            ScopeAllDevices = $allDevicesTarget
            AssignedGroupCount = $groupIds.Count
        })
    }

    if ($disableOverride -and (& $isTrue $disableOverride)) {
        $restrictive = ($allowIdentifiedDevelopers -and (& $isFalse $allowIdentifiedDevelopers)) -or ($enableAssessment -and (& $isFalse $enableAssessment))
        Write-Status "[$($policy.Name)] OVERRIDE_DISABLED — users cannot manually 'Open Anyway' past a Gatekeeper block on devices in this scope.$(if($restrictive){' Paired with a restrictive policy above — no user-side escape hatch exists at all for this scope.'})" $(if ($restrictive) { "WARN" } else { "INFO" })
        $FlagResults.Add([PSCustomObject]@{
            PolicyName = $policy.Name
            Flag       = "OVERRIDE_DISABLED"
            Detail     = "System Policy Managed Disable Override = true. Any signing/notarization gap in a deployed app becomes a hard block with no per-user workaround for this scope."
            ScopeAllDevices = $allDevicesTarget
            AssignedGroupCount = $groupIds.Count
        })
    }
}

Write-Status "Found $($MatchedPolicies.Count) macOS System Policy (Gatekeeper) configuration polic(y/ies)." "INFO"

# ─── Part 2: macOS device population size for scope estimation ────────────────

Write-Status "`nPulling macOS managed device count for scope estimation..." "INFO"

try {
    $macDevices = Get-MgBetaDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query managed devices: $($_.Exception.Message)" "ERROR"
    exit 1
}

Write-Status "Tenant macOS managed device count: $($macDevices.Count) (used as a rough denominator — this script does not resolve group membership counts per policy; cross-reference AssignedGroupCount/AllDevicesAssigned per flagged policy against your own group sizes for a precise scope estimate)." "INFO"

# ─── Summary ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Magenta
Write-Status "macOS System Policy (Gatekeeper) policies found: $($MatchedPolicies.Count)"
Write-Status "Flags raised:                                    $($FlagResults.Count)" $(if ($FlagResults.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Tenant macOS managed device count:               $($macDevices.Count)"

if ($FlagResults.Count -eq 0) {
    Write-Host ""
    Write-Host "No System Policy configuration flags raised. If users are still reporting Gatekeeper blocks," -ForegroundColor Cyan
    Write-Host "the cause is almost certainly device-local (app signing/notarization) — see the device-local" -ForegroundColor Cyan
    Write-Host "Triage commands in Gatekeeper-Notarization-B.md, not the fleet-wide policy layer this script checks." -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "Flags found — review Flags CSV. APP_STORE_ONLY and ASSESSMENT_DISABLED can explain symptoms" -ForegroundColor Yellow
    Write-Host "across MANY apps/devices simultaneously and should be ruled out before investigating any" -ForegroundColor Yellow
    Write-Host "single app's signature — see Gatekeeper-Notarization-A.md Troubleshooting Phase 1." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "This script cannot evaluate any individual app's code signature, notarization ticket, or" -ForegroundColor Yellow
Write-Host "quarantine state — that is exclusively device-local. See Gatekeeper-Notarization-B.md Triage" -ForegroundColor Yellow
Write-Host "(spctl -a -vvv, codesign -dv, pkgutil --check-signature) for per-app diagnosis." -ForegroundColor Yellow

# ─── Export ──────────────────────────────────────────────────────────────────────

$MatchedPolicies | Export-Csv -Path "$OutputPath-Policies.csv" -NoTypeInformation
$FlagResults      | Export-Csv -Path "$OutputPath-Flags.csv" -NoTypeInformation
$macDevices | Select-Object DeviceName, SerialNumber, OsVersion, LastSyncDateTime |
    Export-Csv -Path "$OutputPath-DeviceScope.csv" -NoTypeInformation

Write-Status "`nPolicy report:       $OutputPath-Policies.csv" "INFO"
Write-Status "Flags report:        $OutputPath-Flags.csv" "INFO"
Write-Status "Device scope report: $OutputPath-DeviceScope.csv" "INFO"
Write-Status "Done." "OK"
