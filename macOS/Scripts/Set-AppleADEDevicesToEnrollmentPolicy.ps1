<#
.SYNOPSIS
    Bulk-reassigns already-imported Apple ADE devices to a target enrollment
    policy/profile — works around the Intune portal's lack of a select-all
    option on the enrollment-token device list.

.DESCRIPTION
    Setting a new-style Apple ADE enrollment policy as a token's default only
    affects devices that sync in from ABM/ASM afterward. Every device already
    imported keeps its previously assigned classic profile or new-style policy
    until explicitly reassigned, and the Intune portal offers no bulk-select
    control for this — only page-by-page single selection.

    This script reassigns already-imported devices for a given Apple
    enrollment program token (or all tokens) to a target policy/profile in
    batches via the Microsoft Graph beta `updateDeviceProfileAssignment`
    action, which accepts serial numbers rather than object IDs.

    Because new-style (Settings-Catalog-backed) enrollment policies never
    populate the classic `isDefault` property on their mirrored
    `enrollmentProfiles` entry, this script falls back to a heuristic when no
    -PolicyName is given: it looks for a classic profile with `isDefault`
    true first, and if none exists, queries `configurationPolicies` for the
    token's ADE template with `isAssigned eq false` and treats that as the
    current default. This heuristic can be wrong if a tenant has multiple
    unassigned ADE policies of the same platform on one token (the script
    warns and picks the first) — pass -PolicyName explicitly whenever more
    than one candidate policy could exist.

    Reassignment takes effect only at a device's NEXT enrollment (wipe or
    hardware replacement) — it does not retroactively reconfigure a device
    already in daily use, and this script does not attempt to trigger
    re-enrollment.

.PARAMETER PolicyName
    Optional. Display name of the target enrollment policy or classic
    profile. If omitted, the token's current default for -Platform is used
    (see heuristic above).

.PARAMETER TokenName
    Optional. Limit the run to a single enrollment program token. If
    omitted, every token is processed.

.PARAMETER SerialNumber
    Optional. One or more device serial numbers. If provided, only these
    devices are considered instead of every imported device of -Platform
    that isn't already on the target policy.

.PARAMETER Platform
    Platform of the devices to reassign. One of: ios, macOS. Defaults to ios.

.PARAMETER BatchSize
    Number of serial numbers sent per updateDeviceProfileAssignment call.
    Defaults to 100.

.EXAMPLE
    .\Set-AppleADEDevicesToEnrollmentPolicy.ps1 -Platform ios -WhatIf

.EXAMPLE
    .\Set-AppleADEDevicesToEnrollmentPolicy.ps1 -Platform macOS

.EXAMPLE
    .\Set-AppleADEDevicesToEnrollmentPolicy.ps1 -PolicyName 'ABM-EnrollmentPolicy-iOS-WithUser-ModernAuth'

.EXAMPLE
    .\Set-AppleADEDevicesToEnrollmentPolicy.ps1 -SerialNumber 'C7XXXXXXXXXX','F9XXXXXXXXXX' -Platform ios

.NOTES
    Requires: Microsoft.Graph.Authentication module, delegated or app-only
    Graph permission DeviceManagementServiceConfig.ReadWrite.All.
    Uses beta Graph endpoints (depOnboardingSettings) — no v1.0 equivalent
    exists for these ADE-specific resources as of this writing.
    Read-only unless -WhatIf is omitted and confirmation is given (supports
    -WhatIf/-Confirm via SupportsShouldProcess). Performs zero device wipes,
    profile deletions, or Entra group changes — reassignment only.
#>
#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PolicyName,

    [string]$TokenName,

    [string[]]$SerialNumber,

    [ValidateSet('ios', 'macOS')]
    [string]$Platform = 'ios',

    [ValidateRange(1, 1000)]
    [int]$BatchSize = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-GraphAllPages {
    param([string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    do {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        foreach ($item in $page.value) { $results.Add($item) }
        $next = $page.PSObject.Properties['@odata.nextLink'] | ForEach-Object { $_.Value }
    } while ($next)
    return $results
}

function Get-DefaultAdeProfile {
    # Classic profiles track isDefault directly and are authoritative when set.
    # New-style (Settings Catalog) policies never populate isDefault on their
    # mirrored enrollmentProfiles entry, so when no classic default exists we
    # fall back to querying configurationPolicies directly for the token's ADE
    # template and treat an unassigned match as "the" default. This is a
    # heuristic, not an authoritative flag — it can misfire if a tenant has
    # more than one unassigned ADE policy of the same platform on one token.
    param(
        [object[]]$Profiles,
        [string]$TokenId,
        [string]$Platform
    )

    $profileType = if ($Platform -eq 'ios') { '#microsoft.graph.depIOSEnrollmentProfile' } else { '#microsoft.graph.depMacOSEnrollmentProfile' }
    $classicDefault = $Profiles | Where-Object { $_.'@odata.type' -eq $profileType -and $_.isDefault }
    if ($classicDefault) { return $classicDefault }

    $odataPlatform = if ($Platform -eq 'ios') { 'ios' } else { 'macOS' }
    $filter = "(technologies has 'enrollment') and (platforms eq '$odataPlatform') and (creationSource eq 'DepTokenId_$TokenId') and (isAssigned eq false)"
    $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=$([System.Uri]::EscapeDataString($filter))&`$select=id,name"
    $unassigned = @(Get-GraphAllPages -Uri $uri)

    if ($unassigned.Count -gt 1) {
        Write-Status "Multiple unassigned $Platform ADE policies found on this token — using '$($unassigned[0].name)' as the default. Pass -PolicyName to disambiguate." 'WARN'
    }
    if ($unassigned.Count -eq 0) { return $null }

    $match = $Profiles | Where-Object { $_.id -like "*$($unassigned[0].id)*" }
    return $match
}

$requiredScope = 'DeviceManagementServiceConfig.ReadWrite.All'
$context = Get-MgContext
if (-not $context -or $context.Scopes -notcontains $requiredScope) {
    Connect-MgGraph -Scopes $requiredScope -NoWelcome
}

Write-Status "Enumerating enrollment program tokens..."
$tokens = Get-GraphAllPages -Uri 'https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings'
if ($TokenName) {
    $tokens = @($tokens | Where-Object { $_.tokenName -eq $TokenName })
    if ($tokens.Count -eq 0) { throw "Enrollment program token '$TokenName' not found." }
}

$summary = [System.Collections.Generic.List[object]]::new()

foreach ($token in $tokens) {
    Write-Status "--- Token: $($token.tokenName) ---"

    $profiles = Get-GraphAllPages -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$($token.id)/enrollmentProfiles"

    $target = if ($PolicyName) {
        $profiles | Where-Object { $_.displayName -eq $PolicyName }
    } else {
        Get-DefaultAdeProfile -Profiles $profiles -TokenId $token.id -Platform $Platform
    }

    if (-not $target) {
        $wanted = if ($PolicyName) { "Policy '$PolicyName'" } else { "A default $Platform policy" }
        Write-Status "$wanted not found on this token — skipping." 'WARN'
        continue
    }

    Write-Status "Target policy/profile: $($target.displayName)"

    $devices = Get-GraphAllPages -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$($token.id)/importedAppleDeviceIdentities"

    $toAssign = @($devices | Where-Object {
        $_.platform -eq $Platform -and
        -not $_.isDeleted -and
        -not [string]::IsNullOrWhiteSpace($_.serialNumber) -and
        $_.requestedEnrollmentProfileId -ne $target.id
    })

    if ($SerialNumber) {
        $toAssign = @($toAssign | Where-Object { $_.serialNumber -in $SerialNumber })
        $missing = @($SerialNumber | Where-Object { $_ -notin $devices.serialNumber })
        foreach ($s in $missing) { Write-Status "Serial number '$s' not found on this token." 'WARN' }
    }

    Write-Status "Devices ($Platform): $($devices.Count) imported, $($toAssign.Count) to reassign"

    $reassignedCount = 0
    for ($i = 0; $i -lt $toAssign.Count; $i += $BatchSize) {
        $end = [Math]::Min($i + $BatchSize, $toAssign.Count) - 1
        $chunk = @($toAssign[$i..$end])
        $serials = @($chunk | Select-Object -ExpandProperty serialNumber)

        if ($PSCmdlet.ShouldProcess("$($serials.Count) device(s) starting with $($serials[0])", "Assign to '$($target.displayName)'")) {
            $body = @{ deviceIds = $serials } | ConvertTo-Json
            Invoke-MgGraphRequest -Method POST `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$($token.id)/enrollmentProfiles/$($target.id)/updateDeviceProfileAssignment" `
                -Body $body | Out-Null
            Write-Status "Assigned batch of $($serials.Count) device(s)" 'OK'
            $reassignedCount += $serials.Count
        }
    }

    $summary.Add([PSCustomObject]@{
        TokenName       = $token.tokenName
        TargetPolicy    = $target.displayName
        Platform        = $Platform
        DevicesImported = $devices.Count
        DevicesQueued   = $toAssign.Count
        DevicesReassigned = $reassignedCount
    })
}

Write-Status "Run complete."
$summary | Format-Table -AutoSize
$csvPath = Join-Path -Path (Get-Location) -ChildPath "AppleADEReassignment-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$summary | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Summary exported to $csvPath" 'OK'
