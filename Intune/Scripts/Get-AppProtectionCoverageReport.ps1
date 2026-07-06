<#
.SYNOPSIS
    Fleet-wide Intune App Protection Policy (MAM) coverage and health report.

.DESCRIPTION
    Read-only diagnostic script for App Protection Policies (APP/MAM) as covered in
    Intune/Troubleshooting/AppProtection-B.md and AppProtection-A.md.

    For every user in a target group (or every user with a managed app registration,
    if no group is supplied) this script reports:
      - Managed app registrations (platform, app identifier, SDK version, last sync)
      - STALE_CHECKIN: registration exists but LastSyncDateTime is older than -StaleHours
        (default 48h) — per AppProtection-B.md Fix 1/Validation Step 3, this is the
        single most common "policy not applying" symptom
      - NO_POLICY_APPLIED: registration exists but zero policies came back applied —
        per AppProtection-B.md Fix 2 (registration present, no policy applied)
      - NO_INTUNE_LICENSE: user has an app registration but no detectable Intune/EMS/
        SPE license SKU — per AppProtection-A.md Validation Step 2
      - SDK_VERSION_MISSING: ManagementSdkVersion is null/empty, which AppProtection-B.md
        Fix 3 flags as a common cause of "policy applied but restrictions not enforced"

    This does not call any write/PATCH/wipe operations. It is a reporting tool only —
    use the Fix playbooks in AppProtection-B.md/A.md to remediate what it finds.

.PARAMETER GroupId
    Optional Entra ID group Object ID to scope the report to a specific population
    (e.g., the group targeted by an APP policy). If omitted, the script reports on
    every user who currently has at least one managed app registration.

.PARAMETER StaleHours
    Hours since LastSyncDateTime before a registration is flagged STALE_CHECKIN.
    Default: 48.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: current directory.

.EXAMPLE
    .\Get-AppProtectionCoverageReport.ps1
    Reports on all users with existing managed app registrations, using default thresholds.

.EXAMPLE
    .\Get-AppProtectionCoverageReport.ps1 -GroupId "11111111-2222-3333-4444-555555555555" -StaleHours 24
    Scopes the report to a specific policy-assignment group with a tighter staleness window.

.NOTES
    Requires:      Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups
    Scopes:        DeviceManagementApps.Read.All, User.Read.All, Group.Read.All
    Run as:        Any account with the above Graph scopes (no local admin required —
                   this is a Graph-only script, no on-device execution)
    Safe/Unsafe:   Fully read-only. No policy, wipe, or configuration changes are made.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$GroupId,

    [Parameter(Mandatory = $false)]
    [int]$StaleHours = 48,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Checking Microsoft Graph connection..."
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected. Connecting with required scopes..." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementApps.Read.All", "User.Read.All", "Group.Read.All" -NoWelcome
    }
    else {
        Write-Status "Connected as $($context.Account)" "OK"
    }
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    throw
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportFile = Join-Path $OutputPath "AppProtectionCoverage-$timestamp.csv"

# ---------------------------------------------------------------------------
# Detect population: group members, or all users with an app registration
# ---------------------------------------------------------------------------
$targetUserIds = @{}

if ($GroupId) {
    Write-Status "Resolving members of group $GroupId..."
    try {
        $members = Get-MgGroupMember -GroupId $GroupId -All
        foreach ($m in $members) { $targetUserIds[$m.Id] = $true }
        Write-Status "Group has $($targetUserIds.Count) direct member(s)." "OK"
    }
    catch {
        Write-Status "Failed to resolve group membership: $($_.Exception.Message)" "ERROR"
        throw
    }
}

Write-Status "Retrieving managed app registrations (this covers all platforms: iOS, Android, Windows MAM)..."
try {
    $allRegs = Get-MgDeviceAppManagementManagedAppRegistration -All
}
catch {
    Write-Status "Failed to retrieve managed app registrations: $($_.Exception.Message)" "ERROR"
    throw
}
Write-Status "Retrieved $($allRegs.Count) total registration(s) across the tenant." "OK"

# If a group was supplied, filter registrations to that population.
# ManagedAppRegistration objects expose UserId via AdditionalProperties in most SDK versions.
if ($GroupId) {
    $allRegs = $allRegs | Where-Object {
        $uid = $_.AdditionalProperties['userId']
        $uid -and $targetUserIds.ContainsKey($uid)
    }
    Write-Status "Filtered to $($allRegs.Count) registration(s) belonging to group members." "OK"
}

$staleThreshold = (Get-Date).AddHours(-$StaleHours)
$results = New-Object System.Collections.Generic.List[object]
$licenseCache = @{}

$i = 0
foreach ($reg in $allRegs) {
    $i++
    if ($i % 25 -eq 0) { Write-Status "Processed $i / $($allRegs.Count) registrations..." }

    $userId = $reg.AdditionalProperties['userId']
    $upn = $reg.AdditionalProperties['userEmail']
    $lastSync = $null
    if ($reg.AdditionalProperties.ContainsKey('lastSyncDateTime')) {
        [void][DateTime]::TryParse($reg.AdditionalProperties['lastSyncDateTime'], [ref]$lastSync)
    }
    $appliedPolicyCount = 0
    if ($reg.AdditionalProperties.ContainsKey('appliedPolicies')) {
        $appliedPolicyCount = @($reg.AdditionalProperties['appliedPolicies']).Count
    }
    $sdkVersion = $reg.AdditionalProperties['managementSdkVersion']
    $platform = $reg.AdditionalProperties['platformType']
    $appId = $reg.AdditionalProperties['appIdentifier']

    $flags = New-Object System.Collections.Generic.List[string]

    if ($lastSync -and $lastSync -lt $staleThreshold) { $flags.Add("STALE_CHECKIN") }
    elseif (-not $lastSync) { $flags.Add("NO_CHECKIN_TIMESTAMP") }

    if ($appliedPolicyCount -eq 0) { $flags.Add("NO_POLICY_APPLIED") }

    if ([string]::IsNullOrWhiteSpace($sdkVersion)) { $flags.Add("SDK_VERSION_MISSING") }

    # License check (cached per user to avoid redundant calls)
    $licenseOk = $null
    if ($userId) {
        if (-not $licenseCache.ContainsKey($userId)) {
            try {
                $skus = (Get-MgUserLicenseDetail -UserId $userId -ErrorAction Stop).SkuPartNumber
                $licenseCache[$userId] = ($skus -match "INTUNE|EMS|EMS_EDU|SPE_|ENTERPRISEPACK") -contains $true
            }
            catch {
                $licenseCache[$userId] = $null
            }
        }
        $licenseOk = $licenseCache[$userId]
        if ($licenseOk -eq $false) { $flags.Add("NO_INTUNE_LICENSE") }
    }

    $results.Add([PSCustomObject]@{
        UserId              = $userId
        UserPrincipalName   = $upn
        Platform            = $platform
        AppIdentifier       = $appId
        ManagementSdkVersion = $sdkVersion
        LastSyncDateTime    = $lastSync
        AppliedPolicyCount  = $appliedPolicyCount
        IntuneLicenseFound  = $licenseOk
        Flags               = ($flags -join "; ")
    })
}

$results | Sort-Object Flags -Descending | Export-Csv -Path $reportFile -NoTypeInformation

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "=== App Protection Coverage Summary ===" "INFO"
Write-Status "Total registrations analysed: $($results.Count)" "INFO"
Write-Status "STALE_CHECKIN (>${StaleHours}h since last sync): $(@($results | Where-Object { $_.Flags -match 'STALE_CHECKIN' }).Count)" "WARN"
Write-Status "NO_POLICY_APPLIED: $(@($results | Where-Object { $_.Flags -match 'NO_POLICY_APPLIED' }).Count)" "WARN"
Write-Status "SDK_VERSION_MISSING: $(@($results | Where-Object { $_.Flags -match 'SDK_VERSION_MISSING' }).Count)" "WARN"
Write-Status "NO_INTUNE_LICENSE: $(@($results | Where-Object { $_.Flags -match 'NO_INTUNE_LICENSE' }).Count)" "WARN"
Write-Status "Clean (no flags): $(@($results | Where-Object { [string]::IsNullOrEmpty($_.Flags) }).Count)" "OK"
Write-Host ""
Write-Status "Full report exported to: $reportFile" "OK"
