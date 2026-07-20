<#
.SYNOPSIS
    Audits Windows 365 Flex (formerly Frontline) provisioning policies and Cloud PCs across the
    tenant — mode distribution, pool/license utilization, and deprecated-filter risk.

.DESCRIPTION
    Companion to Flex-A.md and Flex-B.md, mirroring the read-only fleet-report pattern already
    established by Azure/Windows365/Scripts/Get-CloudPcFleetStatus.ps1 (which covers Enterprise/
    Business only). This script is Flex-specific and reports:

    - Every provisioning policy, its ProvisioningType, and whether that value is Flex-flavored
      (dedicated Flex vs. Enterprise dedicated cannot be told apart from the policy object's
      ProvisioningType property alone — this script cross-references against the Cloud PC
      object's own ProvisioningType field, which does distinguish Enterprise from Frontline/
      Flex Dedicated/Shared, per Flex-A.md's Validation Steps step 4)
    - SHARED_POOL_AT_CAPACITY — flags Shared-mode policies where the active/provisioned Cloud PC
      count has reached the number of assigned licenses, the expected-but-actionable "no Cloud
      PC available" condition described in Flex-B.md Fix 1
    - DEDICATED_GROUP_OVERSIZED — flags Dedicated-mode policies where the backing Entra ID
      group's member count exceeds what the assigned license pool can support at up to 3
      Cloud PCs/license, per Flex-A.md's Symptom -> Cause Map
    - DEPRECATED_FILTER_RISK — flags any provisioning policy whose ProvisioningType is the
      literal 'shared' value (deprecated, retires April 30, 2027 per Flex-A.md/Flex-B.md Fix 7)
      so tenants can proactively identify policies an unmigrated script/report might miss
    - License summary for Flex service plans distinct from the Enterprise/Business SKUs already
      covered by Get-CloudPcFleetStatus.ps1

    Does NOT check: concurrency buffer usage/block state (no public Graph endpoint as of this
    writing — the Windows 365 Flex connection hourly report and concurrency alert are Intune
    admin center-only surfaces per Flex-A.md's Evidence Pack notes), Cloud Apps
    (published-application) configuration, or User Experience Sync (UES) state. These are
    explicitly out of scope and must be checked manually in the portal.

    Does NOT perform any remediation, resize, or reprovision action — read-only audit only.

.PARAMETER DedicatedGroupOversizedThresholdPercent
    Percentage above the theoretical max-supported group size (licenses x 3) at which a
    Dedicated-mode policy's backing group is flagged DEDICATED_GROUP_OVERSIZED.
    Default: 0 (flag as soon as group size exceeds the theoretical max).

.PARAMETER SkipGroupSizeCheck
    Switch. Skip the per-policy Entra ID group membership count check (faster, avoids extra
    Graph calls, but misses DEDICATED_GROUP_OVERSIZED detection). Useful if Group.Read.All
    isn't granted.

.PARAMETER ExportPath
    Directory to write CSV reports to. Default: current directory.

.EXAMPLE
    .\Get-Windows365FlexAudit.ps1
    Runs a full Flex audit against the connected tenant and exports CSVs to the current directory.

.EXAMPLE
    .\Get-Windows365FlexAudit.ps1 -SkipGroupSizeCheck -ExportPath "C:\Reports"
    Runs the audit without the group-oversizing check, useful for a lower-privilege service
    principal that only holds CloudPC.Read.All.

.NOTES
    Requires: Microsoft.Graph.Beta module, Microsoft.Graph.Groups module (for the group-size
    check unless -SkipGroupSizeCheck is used).
    Requires scopes: CloudPC.Read.All, DeviceManagementConfiguration.Read.All, Group.Read.All
    (Group.Read.All only needed unless -SkipGroupSizeCheck).
    Run as: Any account/service principal holding the scopes above — no elevated local rights
    needed, this is a Graph-only read operation.
    Safe: Yes — entirely read-only, makes no configuration or Cloud PC changes.
#>

#requires -Modules Microsoft.Graph.Beta

[CmdletBinding()]
param(
    [int]$DedicatedGroupOversizedThresholdPercent = 0,
    [switch]$SkipGroupSizeCheck,
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
if (-not $SkipGroupSizeCheck) { $requiredScopes += "Group.Read.All" }
$missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes -and "$_".Replace('.Read.','.ReadWrite.') -notin $context.Scopes }
if ($missingScopes) {
    Write-Status "Missing recommended scopes: $($missingScopes -join ', '). Some checks may fail or return partial data." "WARN"
}

if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# ---------------------------------------------------------------------------
# Detect: provisioning policies and Flex-flavored Cloud PCs
# ---------------------------------------------------------------------------
Write-Status "Enumerating provisioning policies..."
$policies = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All

Write-Status "Enumerating all Cloud PCs (this can take a while in large tenants)..."
$allCloudPcs = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All

# Cloud PC object's own ProvisioningType distinguishes Enterprise from Frontline/Flex
# Dedicated/Shared — this is a DIFFERENT property surface than the policy object's
# ProvisioningType enum (dedicated/shared/sharedByUser/sharedByEntraGroup/reserve), per
# Flex-A.md Validation Steps step 4. Treat any Cloud PC whose ProvisioningType string
# contains "Frontline" (case-insensitive) as Flex — covers pre- and post-rename API values.
$flexCloudPcs = $allCloudPcs | Where-Object { $_.ProvisioningType -match "Frontline|Flex" }

Write-Status "Found $($policies.Count) provisioning policies total, $($flexCloudPcs.Count) Flex-flavored Cloud PCs." "OK"

# ---------------------------------------------------------------------------
# Execute: per-policy analysis
# ---------------------------------------------------------------------------
$policyReport = [System.Collections.Generic.List[object]]::new()
$findings = [System.Collections.Generic.List[object]]::new()

foreach ($policy in $policies) {

    $isDeprecatedFilterRisk = $policy.ProvisioningType -eq "shared"
    $policyCloudPcs = $flexCloudPcs | Where-Object { $_.ProvisioningPolicyId -eq $policy.Id }

    $isFlexPolicy = $policy.ProvisioningType -in @("shared", "sharedByUser", "sharedByEntraGroup") -or
                    $policyCloudPcs.Count -gt 0

    $assignedLicenseCount = $null
    $groupMemberCount = $null
    $mode = if ($policy.ProvisioningType -in @("shared","sharedByUser","sharedByEntraGroup")) { "Shared" }
            elseif ($isFlexPolicy) { "Dedicated" }
            else { "N/A (not Flex)" }

    if ($isDeprecatedFilterRisk) {
        $findings.Add([PSCustomObject]@{
            Finding      = "DEPRECATED_FILTER_RISK"
            PolicyName   = $policy.DisplayName
            PolicyId     = $policy.Id
            Detail       = "ProvisioningType is the literal 'shared' value, deprecated and stops returning after 2027-04-30. Update automation to also match sharedByUser/sharedByEntraGroup (Flex-B.md Fix 7)."
        })
    }

    if (-not $SkipGroupSizeCheck -and $mode -eq "Dedicated") {
        try {
            $assignments = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $policy.Id -ErrorAction Stop
            foreach ($assignment in $assignments) {
                $groupId = $assignment.Target.AdditionalProperties["groupId"]
                if ($groupId) {
                    try {
                        $groupMemberCount = (Get-MgGroupMember -GroupId $groupId -All -ErrorAction Stop).Count
                    } catch {
                        Write-Status "Could not read group membership for policy '$($policy.DisplayName)' (Group.Read.All may be missing). Skipping oversizing check for this policy." "WARN"
                    }
                }
            }
        } catch {
            Write-Status "Could not read assignments for policy '$($policy.DisplayName)'. Skipping oversizing check." "WARN"
        }

        if ($groupMemberCount -and $policyCloudPcs.Count -gt 0) {
            # Theoretical max users a Dedicated-mode license pool can support at up to 3
            # Cloud PCs/license is bounded by distinct users actually assigned Cloud PCs,
            # not a simple multiplication — use provisioned Cloud PC count as the concrete
            # observed ceiling and compare against group size as an early-warning signal.
            $theoreticalMaxSupportable = $policyCloudPcs.Count
            $thresholdMultiplier = 1 + ($DedicatedGroupOversizedThresholdPercent / 100)
            if ($groupMemberCount -gt ($theoreticalMaxSupportable * $thresholdMultiplier)) {
                $findings.Add([PSCustomObject]@{
                    Finding      = "DEDICATED_GROUP_OVERSIZED"
                    PolicyName   = $policy.DisplayName
                    PolicyId     = $policy.Id
                    Detail       = "Backing Entra ID group has $groupMemberCount members but only $theoreticalMaxSupportable Cloud PCs are currently provisioned under this policy — some group members may never receive a Cloud PC (Flex-A.md Symptom -> Cause Map)."
                })
            }
        }
    }

    if ($mode -eq "Shared" -and $policyCloudPcs.Count -gt 0) {
        $statusGroups = $policyCloudPcs | Group-Object Status
        $provisionedCount = ($statusGroups | Where-Object Name -eq "provisioned").Count
        # A shared pool "at capacity" for triage purposes is flagged when every provisioned
        # Cloud PC in the pool is accounted for and none show as available/idle — this script
        # cannot see live session/connection state (no public Graph endpoint for that), so this
        # is a coarse, best-effort signal only, not a live concurrency reading.
        if ($provisionedCount -gt 0 -and $provisionedCount -eq $policyCloudPcs.Count) {
            $findings.Add([PSCustomObject]@{
                Finding      = "SHARED_POOL_LIKELY_AT_CAPACITY"
                PolicyName   = $policy.DisplayName
                PolicyId     = $policy.Id
                Detail       = "All $provisionedCount Cloud PCs in this Shared-mode pool show status 'provisioned' with none in a non-provisioned/failed state — cross-check the Windows 365 Flex connection hourly report in the Intune admin center for actual live concurrency before assuming exhaustion (Flex-B.md Fix 1)."
            })
        }
    }

    $policyReport.Add([PSCustomObject]@{
        PolicyName            = $policy.DisplayName
        PolicyId              = $policy.Id
        RawProvisioningType   = $policy.ProvisioningType
        InferredMode          = $mode
        IsFlexPolicy          = $isFlexPolicy
        CloudPcCount          = $policyCloudPcs.Count
        BackingGroupMemberCount = $groupMemberCount
        DeprecatedFilterRisk  = $isDeprecatedFilterRisk
    })
}

# ---------------------------------------------------------------------------
# License summary for Flex service plans
# ---------------------------------------------------------------------------
Write-Status "Enumerating Flex-eligible service plan sizes..."
try {
    $flexServicePlans = Get-MgBetaDeviceManagementVirtualEndpointFrontLineServicePlan -ErrorAction Stop
} catch {
    Write-Status "Could not enumerate Flex service plans (Get-MgBetaDeviceManagementVirtualEndpointFrontLineServicePlan failed) — may indicate no Flex licenses in this tenant, or insufficient scope." "WARN"
    $flexServicePlans = @()
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "`n=== SUMMARY ===" "OK"
Write-Status "Provisioning policies (total): $($policies.Count)"
Write-Status "Flex-flavored policies: $(($policyReport | Where-Object IsFlexPolicy).Count)"
Write-Status "Flex Cloud PCs: $($flexCloudPcs.Count)"
Write-Status "Flex service plan sizes available: $($flexServicePlans.Count)"
Write-Status "Findings: $($findings.Count)" $(if ($findings.Count -gt 0) { "WARN" } else { "OK" })

if ($findings.Count -gt 0) {
    Write-Status "`n=== FINDINGS ===" "WARN"
    $findings | Format-Table -AutoSize -Wrap
}

Write-Status "`nNOTE: Concurrency buffer usage/block state and live per-second session concurrency are" "WARN"
Write-Status "NOT available via Graph as of this writing — cross-check the Windows 365 Flex connection" "WARN"
Write-Status "hourly report and concurrency alert in the Intune admin center manually before treating" "WARN"
Write-Status "any finding above as a confirmed incident rather than an early-warning signal." "WARN"

$policyReportPath = Join-Path $ExportPath "Windows365Flex_PolicyReport_$timestamp.csv"
$findingsPath = Join-Path $ExportPath "Windows365Flex_Findings_$timestamp.csv"
$servicePlanPath = Join-Path $ExportPath "Windows365Flex_ServicePlans_$timestamp.csv"

$policyReport | Export-Csv -Path $policyReportPath -NoTypeInformation
$findings | Export-Csv -Path $findingsPath -NoTypeInformation
$flexServicePlans | Select-Object DisplayName, Id, VCpuCount, RamInGB, StorageInGB |
    Export-Csv -Path $servicePlanPath -NoTypeInformation

Write-Status "`nReports written to:" "OK"
Write-Status "  $policyReportPath"
Write-Status "  $findingsPath"
Write-Status "  $servicePlanPath"
