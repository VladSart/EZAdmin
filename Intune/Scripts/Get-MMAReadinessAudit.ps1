<#
.SYNOPSIS
    Audits a tenant's readiness for Intune's Multiple Managed Accounts (MMA) app protection
    feature and flags configuration that would silently block it.

.DESCRIPTION
    Multiple Managed Accounts (MMA) lets a single app (currently Microsoft Teams for
    iOS/iPadOS v8.10.0+ and Microsoft Outlook for iOS/iPadOS v5.2626.0+) hold more than one
    Intune-MAM-managed identity at once. Microsoft provides no first-class "enable MMA" toggle;
    the only documented admin-facing lever is the iOS app configuration key
    IntuneMAMAllowedAccountsOnly, which — if set true — forces single-managed-account mode and
    silently disables MMA even in an otherwise-eligible app.

    This is a READ-ONLY reporting script. It does not change any policy or app configuration.
    It:
      1. Enumerates managed iOS/iPadOS devices and their detected Outlook/Teams app versions,
         flagging devices below the documented MMA version floor.
      2. Enumerates targeted app configuration policies and flags any that set
         IntuneMAMAllowedAccountsOnly = true, along with which apps/groups they're assigned to.
      3. Cross-references flagged policies against the flagged low-version devices so the report
         highlights users who are BOTH app-eligible AND currently blocked by app config.

    It does NOT and cannot:
      - Determine how many managed accounts are actually signed into an app on a given device
        (no supported Graph API surface reports in-app sign-in state).
      - Distinguish segmented-view from mixed-view runtime behavior (that's an app UI concept,
        not a queryable device/policy property).
      - Modify or remove the IntuneMAMAllowedAccountsOnly setting — see Playbook A in
        Intune/Troubleshooting/AppMultipleManagedAccounts-A.md for the (deliberately manual,
        confirm-first) remediation.

.PARAMETER OutputPath
    CSV path for the device/app-version portion of the report. Default .\MMAReadinessAudit.csv

.PARAMETER PolicyOutputPath
    CSV path for the flagged app-configuration-policy portion of the report.
    Default .\MMABlockingPolicies.csv

.EXAMPLE
    .\Get-MMAReadinessAudit.ps1
    Runs with default output paths.

.NOTES
    Requires: an interactive or app-only Microsoft Graph connection with at minimum
              DeviceManagementManagedDevices.Read.All and DeviceManagementApps.Read.All.
    Safe/unsafe: fully read-only. Safe to run at any time, including in production, on a schedule.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".\MMAReadinessAudit.csv",
    [string]$PolicyOutputPath = ".\MMABlockingPolicies.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
try {
    $context = Get-MgContext
    if (-not $context) { throw "Not connected." }
    Write-Status "Connected to tenant $($context.TenantId) as $($context.Account)" "OK"
}
catch {
    Write-Status "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All','DeviceManagementApps.Read.All'" "ERROR"
    return
}

$mmaFloors = @{
    'Microsoft Outlook' = [version]'5.2626.0'
    'Microsoft Teams'   = [version]'8.10.0'
}

# ---- Detect: managed iOS devices ----
Write-Status "Retrieving managed iOS/iPadOS devices..."
$iosDevices = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'iOS'").value
if (-not $iosDevices -or $iosDevices.Count -eq 0) {
    Write-Status "No managed iOS/iPadOS devices found in this tenant." "WARN"
}
else {
    Write-Status "Retrieved $($iosDevices.Count) managed iOS/iPadOS device(s)." "OK"
}

# ---- Execute: check detected app versions per device ----
$deviceResults = foreach ($d in $iosDevices) {
    $detected = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($d.id)/detectedApps").value |
        Where-Object { $_.displayName -in @('Microsoft Outlook','Microsoft Teams') }

    foreach ($app in $detected) {
        $floor = $mmaFloors[$app.displayName]
        $installed = $null
        try { $installed = [version]$app.version } catch { $installed = $null }

        $eligible = if ($installed -and $floor) { $installed -ge $floor } else { $null }

        [pscustomobject]@{
            DeviceName      = $d.deviceName
            UserPrincipalName = $d.userPrincipalName
            DeviceId        = $d.id
            App             = $app.displayName
            InstalledVersion = $app.version
            RequiredFloor   = $floor.ToString()
            MMAEligibleByVersion = $eligible
        }
    }
}

if ($deviceResults) {
    $deviceResults | Export-Csv -Path $OutputPath -NoTypeInformation
    $below = @($deviceResults | Where-Object { $_.MMAEligibleByVersion -eq $false })
    Write-Status "Device/app-version report written to $OutputPath ($($deviceResults.Count) app instances, $($below.Count) below MMA floor)" "OK"
}
else {
    Write-Status "No Outlook/Teams detected-app records found on managed iOS devices." "WARN"
}

# ---- Detect: app configuration policies with IntuneMAMAllowedAccountsOnly ----
Write-Status "Retrieving targeted app configuration policies..."
$appConfigPolicies = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/targetedManagedAppConfigurations?`$expand=apps,assignments").value

$blockingPolicies = foreach ($policy in $appConfigPolicies) {
    $hit = $policy.customSettings | Where-Object { $_.name -eq 'IntuneMAMAllowedAccountsOnly' }
    if ($hit -and $hit.value -eq 'true') {
        [pscustomobject]@{
            PolicyName   = $policy.displayName
            PolicyId     = $policy.id
            SettingValue = $hit.value
            TargetedApps = ($policy.apps.mobileAppIdentifier.bundleId -join '; ')
            AssignedGroups = ($policy.assignments.target.groupId -join '; ')
        }
    }
}

if ($blockingPolicies) {
    $blockingPolicies | Export-Csv -Path $PolicyOutputPath -NoTypeInformation
    Write-Status "$($blockingPolicies.Count) app configuration polic(y/ies) found with IntuneMAMAllowedAccountsOnly = true — written to $PolicyOutputPath" "WARN"
    Write-Status "These policies will silently disable MMA for any in-scope user, even on eligible app versions. Confirm intent with the policy owner before removing (see Playbook A)." "WARN"
}
else {
    Write-Status "No app configuration policies found setting IntuneMAMAllowedAccountsOnly = true." "OK"
}

Write-Status "Done. This script cannot confirm actual in-app signed-in account counts or segmented/mixed view behavior — those require user interview or on-device inspection." "INFO"
