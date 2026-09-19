<#
.SYNOPSIS
    Audits Intune-managed Linux Antivirus (Microsoft Defender Antivirus) endpoint
    security policies for offline security intelligence update readiness — flags
    policies with offline updates enabled but a missing/malformed mirror URL, and
    reports policy assignment scope for review.

.DESCRIPTION
    Defender for Endpoint on Linux devices in isolated/restricted-network
    environments rely on a locally-hosted mirror server plus an Intune (or
    Defender portal) endpoint security Antivirus policy to configure offline
    security intelligence updates. Misconfiguration most commonly takes the
    form of an offlineDefinitionUpdateUrl that incorrectly includes the
    arch_* subfolder, or offline updates left disabled despite an
    organization's intent to run air-gapped Linux endpoints.

    This script queries Microsoft Graph (beta endpoint security policy
    templates) for Linux-platform Microsoft Defender Antivirus policies,
    inspects the offline-update-related settings each policy configures, and
    flags likely misconfigurations for manual review. It does NOT and CANNOT:
      - Read a live device's actual mdatp_managed.json or mdatp health output
        (no Graph surface exists for this — use the Evidence Pack script in
        MDELinuxOfflineUpdates-A.md directly on a device for that)
      - Confirm the mirror server itself is reachable, current, or correctly
        populated (this is a policy-configuration audit only)
      - Validate engine signature verification state (device-local only)

    Treat flagged policies as manual-review candidates, not confirmed breakage.

.PARAMETER OutputPath
    Folder to write the CSV report output to. Defaults to
    C:\Temp\MDELinuxOfflineUpdate-Audit.

.PARAMETER IncludeUnassignedPolicies
    Switch. By default, only policies with at least one assignment are
    included in the report. Pass this switch to also include unassigned
    (draft/orphaned) policies.

.EXAMPLE
    .\Get-MDELinuxOfflineUpdateReadiness.ps1

.EXAMPLE
    .\Get-MDELinuxOfflineUpdateReadiness.ps1 -OutputPath 'D:\Reports\MDELinux' -IncludeUnassignedPolicies

.NOTES
    Run from a PowerShell session with the Microsoft.Graph.Authentication and
    Microsoft.Graph.DeviceManagement modules available.
    Requires: Microsoft Graph delegated or app permissions —
    DeviceManagementConfiguration.Read.All at minimum.
    Safe/Read-only: makes no policy or configuration changes.
    This script audits Intune policy CONFIGURATION only — it cannot confirm
    live device-side update success. Pair with the Evidence Pack script in
    MDELinuxOfflineUpdates-A.md for per-device validation.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\Temp\MDELinuxOfflineUpdate-Audit',
    [switch]$IncludeUnassignedPolicies
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    Write-Status "Created output directory: $OutputPath"
}

if (-not (Get-MgContext)) {
    Write-Status 'No active Microsoft Graph session — connecting with required scope.' -Status WARN
    Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All' | Out-Null
}

Write-Status 'Querying Intune Settings Catalog policies for Linux Microsoft Defender Antivirus configuration...'

# Settings Catalog policies are platform-agnostic at the API level; filter client-side
# on the settings actually present rather than relying on a single platform field, since
# Linux Antivirus profiles are delivered as Settings Catalog policies under the hood.
$policies = @()
try {
    $uri = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$expand=settings'
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        $policies += $resp.value
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
    Write-Status "Retrieved $($policies.Count) configuration policies for inspection."
} catch {
    Write-Status "Failed to query configuration policies: $($_.Exception.Message)" -Status ERROR
    throw
}

# Narrow to policies whose settings reference the Linux MDAV offline-update setting IDs.
# Setting definition IDs follow Microsoft's linux_mdatp_* naming convention in the
# Settings Catalog; matched by substring since exact GUIDs/IDs are not stable across
# tenants/API versions and Microsoft does not publish a fixed lookup table.
$linuxAvKeywords = @('linux_mdatp', 'offlinedefinitionupdate', 'offline_definition_update')

$candidatePolicies = $policies | Where-Object {
    $settingsJson = ($_.settings | ConvertTo-Json -Depth 10 -Compress) -as [string]
    if (-not $settingsJson) { return $false }
    $lower = $settingsJson.ToLowerInvariant()
    $linuxAvKeywords | Where-Object { $lower -like "*$_*" } | Select-Object -First 1
}

Write-Status "Identified $($candidatePolicies.Count) candidate Linux offline-update-related policies."

$report = foreach ($policy in $candidatePolicies) {
    $policyId = $policy.id
    $policyName = $policy.name

    # Assignment check
    $assignments = @()
    try {
        $assignUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId/assignments"
        $assignResp = Invoke-MgGraphRequest -Method GET -Uri $assignUri
        $assignments = $assignResp.value
    } catch {
        Write-Status "Could not retrieve assignments for policy '$policyName': $($_.Exception.Message)" -Status WARN
    }

    if (-not $IncludeUnassignedPolicies -and $assignments.Count -eq 0) {
        continue
    }

    $settingsJson = $policy.settings | ConvertTo-Json -Depth 10 -Compress
    $lower = $settingsJson.ToLowerInvariant()

    $offlineEnabled = $lower -match '"offlinedefinitionupdate"[^,}]*"?enabled'
    $hasUrl = $lower -match 'offlinedefinitionupdateurl'
    $urlLooksMalformed = $hasUrl -and ($lower -match 'arch_(x86_64|arm64)')

    $flag = if ($offlineEnabled -and -not $hasUrl) {
        'OfflineUpdateEnabled_NoUrlConfigured'
    } elseif ($urlLooksMalformed) {
        'UrlIncludesArchSubfolder_LikelyMisconfigured'
    } elseif ($offlineEnabled -and $hasUrl) {
        'AppearsConfigured_ManualSpotCheckRecommended'
    } else {
        'OfflineUpdateNotEnabled'
    }

    [pscustomobject]@{
        PolicyId              = $policyId
        PolicyName            = $policyName
        AssignmentCount       = $assignments.Count
        OfflineUpdateEnabled  = $offlineEnabled
        UrlConfigured         = $hasUrl
        Flag                  = $flag
        LastModifiedDateTime  = $policy.lastModifiedDateTime
    }
}

if (-not $report) {
    Write-Status 'No candidate Linux offline-update policies found matching the expected settings keywords. This may mean no such policies exist yet, or Microsoft has changed the Settings Catalog setting IDs since this script was written — spot-check manually in the Intune or Defender portal before concluding there is no coverage.' -Status WARN
}

$csvPath = Join-Path $OutputPath "MDELinuxOfflineUpdate-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Force

Write-Status "Report written to: $csvPath" -Status OK
$flaggedCount = ($report | Where-Object { $_.Flag -ne 'AppearsConfigured_ManualSpotCheckRecommended' -and $_.Flag -ne 'OfflineUpdateNotEnabled' }).Count
if ($flaggedCount -gt 0) {
    Write-Status "$flaggedCount polic(y/ies) flagged for likely misconfiguration — review the CSV." -Status WARN
} else {
    Write-Status 'No policies flagged as likely misconfigured. Remember: this audits policy CONFIGURATION only, not live device update success.' -Status OK
}
