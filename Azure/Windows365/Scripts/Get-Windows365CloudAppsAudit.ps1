<#
.SYNOPSIS
    Audits Windows 365 Cloud Apps provisioning policies across the tenant — property-pairing
    validity, image discovery source, and concurrency headroom.

.DESCRIPTION
    Companion to CloudApps-A.md and CloudApps-B.md. Cloud Apps has no dedicated Graph resource
    of its own — it is identified entirely by the UserExperienceType property on a standard
    cloudPcProvisioningPolicy object. This script:

    - Enumerates every provisioning policy and flags which ones are Cloud Apps policies
      (UserExperienceType -eq 'cloudApp')
    - INVALID_PROPERTY_PAIRING — flags any policy where UserExperienceType is 'cloudApp' but
      ProvisioningType is NOT 'sharedByEntraGroup', the only validated pairing per
      CloudApps-A.md's How It Works. Since neither property can be changed after creation,
      this finding means the policy must be re-created, not patched.
    - IMAGE_DISCOVERY_RISK — flags Cloud Apps policies on a custom image, since custom-image
      app discovery depends on a PowerShell Start Menu scan that fails silently under
      tenant PowerShell execution-policy restrictions or unsupported images (CloudApps-B.md
      Fix 2) — this is a risk flag, not a confirmed failure, since the script cannot execute
      or observe the discovery scan itself.
    - ZERO_CLOUDPC_PROVISIONED — flags Cloud Apps policies with no Cloud PC yet in
      'provisioned' status, since app discovery cannot begin until at least one exists.
    - CONCURRENCY_AT_CAPACITY — cross-references provisioned Cloud PC count for each policy
      against its assigned license allotment, using the identical Flex Shared-mode math
      already established in Get-Windows365FlexAudit.ps1, since Cloud Apps introduces no
      separate concurrency model of its own (CloudApps-A.md How It Works).

    Does NOT check and cannot check via any public API as of this writing: per-app publish
    state (Ready to publish/Publishing/Published/Failed), APPX/MSIX discovery results,
    Autopilot Device Preparation's "Prevent users from connection... on install failure/
    timeout" checkbox state, live per-second session concurrency, or Application Control for
    Windows (WDAC) policy presence/restriction state. All of these must be checked manually in
    the Intune admin center — this script's own console output states this explicitly rather
    than silently omitting it, consistent with this repo's established pattern for topics
    lacking a full API surface (see Get-DSPMforAIAudit.ps1, Get-SentinelHuntingAudit.ps1).

    Does NOT perform any remediation, publish/unpublish, or reprovision action — read-only
    audit only.

.PARAMETER SkipGroupMembershipCheck
    Switch. Skip the per-policy Entra ID group membership count check (faster, avoids extra
    Graph calls, but the report omits BackingGroupMemberCount). Useful if Group.Read.All isn't
    granted to the running account/service principal.

.PARAMETER ExportPath
    Directory to write CSV reports to. Default: current directory.

.EXAMPLE
    .\Get-Windows365CloudAppsAudit.ps1
    Runs a full Cloud Apps audit against the connected tenant and exports CSVs to the current
    directory.

.EXAMPLE
    .\Get-Windows365CloudAppsAudit.ps1 -SkipGroupMembershipCheck -ExportPath "C:\Reports"
    Runs the audit without the group-membership check, useful for a lower-privilege service
    principal that only holds CloudPC.Read.All.

.NOTES
    Requires: Microsoft.Graph.Beta module, Microsoft.Graph.Groups module (for the group
    membership check unless -SkipGroupMembershipCheck is used).
    Requires scopes: CloudPC.Read.All, DeviceManagementConfiguration.Read.All, Group.Read.All
    (Group.Read.All only needed unless -SkipGroupMembershipCheck).
    Run as: Any account/service principal holding the scopes above — no elevated local rights
    needed, this is a Graph-only read operation.
    Safe: Yes — entirely read-only, makes no configuration, publish, or Cloud PC changes.
#>

#requires -Modules Microsoft.Graph.Beta

[CmdletBinding()]
param(
    [switch]$SkipGroupMembershipCheck,
    [string]$ExportPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Verifying Graph connection and scopes..."
$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph first with scopes: CloudPC.Read.All, DeviceManagementConfiguration.Read.All, Group.Read.All" "ERROR"
    throw "Not connected to Microsoft Graph."
}

$requiredScopes = @("CloudPC.Read.All", "DeviceManagementConfiguration.Read.All")
if (-not $SkipGroupMembershipCheck) { $requiredScopes += "Group.Read.All" }
$missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes -and "$_".Replace('.Read.','.ReadWrite.') -notin $context.Scopes }
if ($missingScopes) {
    Write-Status "Missing recommended scopes: $($missingScopes -join ', '). Some checks may fail or return partial data." "WARN"
}

if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# ---------------------------------------------------------------------------
# Detect: provisioning policies flavored as Cloud Apps
# ---------------------------------------------------------------------------
Write-Status "Enumerating provisioning policies..."
$allPolicies = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All

$cloudAppPolicies = $allPolicies | Where-Object { $_.UserExperienceType -eq "cloudApp" }

Write-Status "Found $($allPolicies.Count) provisioning policies total, $($cloudAppPolicies.Count) flagged as Cloud Apps (UserExperienceType = cloudApp)." "OK"

if ($cloudAppPolicies.Count -eq 0) {
    Write-Status "No Cloud Apps policies found in this tenant. Nothing further to audit." "OK"
    return
}

Write-Status "Enumerating all Cloud PCs (this can take a while in large tenants)..."
$allCloudPcs = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All

# ---------------------------------------------------------------------------
# Execute: per-policy analysis
# ---------------------------------------------------------------------------
$policyReport = [System.Collections.Generic.List[object]]::new()
$findings = [System.Collections.Generic.List[object]]::new()

foreach ($policy in $cloudAppPolicies) {

    $isValidPairing = $policy.ProvisioningType -eq "sharedByEntraGroup"
    if (-not $isValidPairing) {
        $findings.Add([PSCustomObject]@{
            Finding    = "INVALID_PROPERTY_PAIRING"
            PolicyName = $policy.DisplayName
            PolicyId   = $policy.Id
            Detail     = "UserExperienceType is 'cloudApp' but ProvisioningType is '$($policy.ProvisioningType)', not 'sharedByEntraGroup'. This is the only validated pairing (CloudApps-A.md How It Works) and neither property can be changed after creation — the policy must be re-created, not patched (CloudApps-B.md Fix 1)."
        })
    }

    $isCustomImage = $policy.ImageType -eq "custom"
    if ($isCustomImage) {
        $findings.Add([PSCustomObject]@{
            Finding    = "IMAGE_DISCOVERY_RISK"
            PolicyName = $policy.DisplayName
            PolicyId   = $policy.Id
            Detail     = "Policy uses a custom image ('$($policy.ImageDisplayName)'). Custom-image app discovery depends on a PowerShell Start Menu scan that fails silently under tenant PowerShell execution-policy restrictions or unsupported images (CloudApps-B.md Fix 2). This is a risk flag only — this script cannot observe the discovery scan's actual result."
        })
    }

    $policyCloudPcs = $allCloudPcs | Where-Object { $_.ProvisioningPolicyId -eq $policy.Id }
    $provisionedCount = ($policyCloudPcs | Where-Object { $_.Status -eq "provisioned" }).Count

    if ($provisionedCount -eq 0) {
        $findings.Add([PSCustomObject]@{
            Finding    = "ZERO_CLOUDPC_PROVISIONED"
            PolicyName = $policy.DisplayName
            PolicyId   = $policy.Id
            Detail     = "No Cloud PC under this policy has reached 'provisioned' status yet. App discovery cannot begin until at least one Cloud PC provisions successfully (CloudApps-A.md Dependency Stack)."
        })
    }

    $assignedLicenseCount = $null
    $groupMemberCount = $null
    try {
        $assignments = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $policy.Id -ErrorAction Stop
        foreach ($assignment in $assignments) {
            $count = $assignment.Target.AdditionalProperties["allotmentLicensesCount"]
            if ($count) { $assignedLicenseCount = [int]$count }
            $groupId = $assignment.Target.AdditionalProperties["groupId"]
            if ($groupId -and -not $SkipGroupMembershipCheck) {
                try {
                    $groupMemberCount = (Get-MgGroupMember -GroupId $groupId -All -ErrorAction Stop).Count
                } catch {
                    Write-Status "Could not read group membership for policy '$($policy.DisplayName)' (Group.Read.All may be missing)." "WARN"
                }
            }
        }
    } catch {
        Write-Status "Could not read assignment for policy '$($policy.DisplayName)'. Skipping concurrency check for this policy." "WARN"
    }

    if ($assignedLicenseCount -and $provisionedCount -ge $assignedLicenseCount) {
        $findings.Add([PSCustomObject]@{
            Finding    = "CONCURRENCY_AT_CAPACITY"
            PolicyName = $policy.DisplayName
            PolicyId   = $policy.Id
            Detail     = "Provisioned Cloud PC count ($provisionedCount) has reached the assigned license allotment ($assignedLicenseCount). Cloud Apps has no separate concurrency model of its own — this is the same Flex Shared-mode ceiling documented in Flex-A.md and CloudApps-A.md, and is expected exhaustion, not a fault, unless the client needs more headroom (CloudApps-B.md Fix 7)."
        })
    }

    $policyReport.Add([PSCustomObject]@{
        PolicyName            = $policy.DisplayName
        PolicyId              = $policy.Id
        UserExperienceType    = $policy.UserExperienceType
        ProvisioningType      = $policy.ProvisioningType
        ValidPropertyPairing  = $isValidPairing
        ImageType             = $policy.ImageType
        ImageDisplayName      = $policy.ImageDisplayName
        CloudPcCount          = $policyCloudPcs.Count
        ProvisionedCount      = $provisionedCount
        AssignedLicenseCount  = $assignedLicenseCount
        BackingGroupMemberCount = $groupMemberCount
    })
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "`n=== SUMMARY ===" "OK"
Write-Status "Provisioning policies (total): $($allPolicies.Count)"
Write-Status "Cloud Apps policies: $($cloudAppPolicies.Count)"
Write-Status "Findings: $($findings.Count)" $(if ($findings.Count -gt 0) { "WARN" } else { "OK" })

if ($findings.Count -gt 0) {
    Write-Status "`n=== FINDINGS ===" "WARN"
    $findings | Format-Table -AutoSize -Wrap
}

Write-Status "`nNOTE: Per-app publish state (Ready to publish/Publishing/Published/Failed), APPX/MSIX" "WARN"
Write-Status "discovery results, the Autopilot Device Prep 'Prevent users...' checkbox state, live" "WARN"
Write-Status "per-second session concurrency, and Application Control for Windows (WDAC) policy" "WARN"
Write-Status "presence are NOT available via Graph as of this writing. Verify these manually in the" "WARN"
Write-Status "Intune admin center (Devices > Windows 365 > All Cloud Apps and Provisioning policies)" "WARN"
Write-Status "before treating any finding above as fully confirmed." "WARN"

$policyReportPath = Join-Path $ExportPath "Windows365CloudApps_PolicyReport_$timestamp.csv"
$findingsPath = Join-Path $ExportPath "Windows365CloudApps_Findings_$timestamp.csv"

$policyReport | Export-Csv -Path $policyReportPath -NoTypeInformation
$findings | Export-Csv -Path $findingsPath -NoTypeInformation

Write-Status "`nReports written to:" "OK"
Write-Status "  $policyReportPath"
Write-Status "  $findingsPath"
