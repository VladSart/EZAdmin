<#
.SYNOPSIS
    Audits Azure Virtual Network Manager (AVNM) instances for the two most common silent
    failure modes: configurations that were defined but never deployed, and goal-state
    "redeploy risk" regions where multiple configurations are deployed together.

.DESCRIPTION
    Produces a read-only report covering four checks across every network manager instance
    in scope:

      1. NETWORK GROUP MEMBERSHIP — for each network group, records membership type
         (static/dynamic) and flags ZERO_STATIC_MEMBERS for static groups with no members
         (a configuration referencing an empty group deploys "successfully" but governs
         nothing — a common source of "I deployed this and nothing happened" confusion).

      2. DEPLOYMENT COVERAGE — cross-references every connectivity (and, unless skipped,
         security admin) configuration object against actual deployment status. Flags
         DEFINED_NOT_DEPLOYED for any configuration that exists but has never been
         committed to a region — per Microsoft's own troubleshooting FAQ, this is the
         single most common real-world root cause of "the config isn't applying."

      3. GOAL-STATE RISK — flags any region+type deployment entry carrying more than one
         configuration ID as MULTI_CONFIG_GOAL_STATE_RISK. This is not a fault by itself —
         it's an informational flag meaning any *future* redeploy to that region must
         explicitly re-include every listed configuration ID, or the omitted ones will be
         silently removed from that region's enforced state (the goal-state model documented
         in AVNM-A.md/AVNM-B.md).

      4. FAILED DEPLOYMENTS — flags any deployment status entry with DeploymentStatus
         "Failed" and surfaces its ErrorMessage directly, since Azure only populates that
         field on genuine failure.

      Optionally, with -VirtualNetworkName/-VirtualNetworkResourceGroupName supplied, also
      pulls the *effective* (authoritative) connectivity configuration and security admin
      rules actually applied to that one VNet, and flags NOT_RECEIVING_CONNECTIVITY_CONFIG
      if nothing is effectively applied despite configurations existing in scope — the
      single-VNet equivalent of the fleet-wide DEFINED_NOT_DEPLOYED check.

    Explicitly does NOT re-implement Security Admin Rule *content* auditing (rule collections,
    action types, IP prefixes) — that's already covered by NSG-A.md's Security Admin Rules
    section and would duplicate Get-NSGRuleAudit.ps1's own admin-rule presence check. This
    script's security-admin coverage is limited to deployment-status-level presence/failure,
    which that script does not check.

.PARAMETER ResourceGroupName
    Resource group containing the network manager instance(s) to audit. If omitted, attempts
    to enumerate every network manager instance in the current subscription context.

.PARAMETER NetworkManagerName
    Optional. Scopes the audit to a single named network manager instance. Requires
    -ResourceGroupName. If omitted, audits every network manager found.

.PARAMETER SubscriptionId
    Optional. Switches subscription context before running (requires prior authentication to
    that subscription). If omitted, uses the current Az context.

.PARAMETER VirtualNetworkName
    Optional. Name of a specific VNet to also check effective (authoritative) connectivity
    configuration and security admin rules against. Must be paired with
    -VirtualNetworkResourceGroupName.

.PARAMETER VirtualNetworkResourceGroupName
    Optional. Resource group of the VNet named in -VirtualNetworkName.

.PARAMETER SkipSecurityAdminDeploymentCheck
    Switch. Skips the security admin configuration deployment-coverage check, useful in
    environments where the caller lacks Network Manager read permission for that
    configuration type and the resulting access-denied noise isn't wanted.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\AVNMConfigAudit_<timestamp>.csv.

.EXAMPLE
    .\Get-AVNMConfigAudit.ps1 -ResourceGroupName 'rg-network-hub'

.EXAMPLE
    .\Get-AVNMConfigAudit.ps1 -ResourceGroupName 'rg-network-hub' -NetworkManagerName 'nm-corp' `
        -VirtualNetworkName 'vnet-spoke-01' -VirtualNetworkResourceGroupName 'rg-spoke-01'
    Audits one named network manager and also checks effective state on a specific spoke VNet.

.NOTES
    Requires: Az.Network, Az.Accounts modules
    Install:  Install-Module Az.Network, Az.Accounts -Scope CurrentUser
    Permissions: Reader on the network manager resource and its child configurations/groups
                 is sufficient for checks 1-4. Reader on the target VNet is required for the
                 optional effective-state check. Individual checks degrade to a CheckFailed
                 status rather than throwing if the caller lacks permission for that specific
                 check, consistent with this repo's established pattern.
    Safe to run: Read-only. No network groups, configurations, or deployments are created,
                 modified, deployed, or removed.
#>
#Requires -Modules Az.Network, Az.Accounts

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$NetworkManagerName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$VirtualNetworkName,

    [Parameter(Mandatory = $false)]
    [string]$VirtualNetworkResourceGroupName,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSecurityAdminDeploymentCheck,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = "C:\Temp\AVNMConfigAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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
Write-Status "Starting Azure Virtual Network Manager configuration audit..." "INFO"

if (-not (Get-AzContext)) {
    Write-Status "No active Az context found. Run Connect-AzAccount first." "ERROR"
    throw "Not authenticated to Azure."
}

if ($SubscriptionId) {
    Write-Status "Switching to subscription $SubscriptionId..." "INFO"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$currentContext = Get-AzContext
Write-Status "Running against subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" "INFO"

if ($VirtualNetworkName -and -not $VirtualNetworkResourceGroupName) {
    Write-Status "-VirtualNetworkName supplied without -VirtualNetworkResourceGroupName — skipping single-VNet effective-state check." "WARN"
    $VirtualNetworkName = $null
}

$results = New-Object System.Collections.Generic.List[Object]

# ---------------------------------------------------------------------------
# Detect — gather network manager instance(s) in scope
# ---------------------------------------------------------------------------
try {
    if ($NetworkManagerName -and $ResourceGroupName) {
        $networkManagers = @(Get-AzNetworkManager -ResourceGroupName $ResourceGroupName -Name $NetworkManagerName)
    }
    elseif ($ResourceGroupName) {
        $networkManagers = @(Get-AzNetworkManager -ResourceGroupName $ResourceGroupName)
    }
    else {
        $networkManagers = @(Get-AzNetworkManager)
    }
}
catch {
    Write-Status "Failed to enumerate network manager instances: $($_.Exception.Message)" "ERROR"
    throw
}

if ($networkManagers.Count -eq 0) {
    Write-Status "No Network Manager instances found in scope." "WARN"
    return
}

Write-Status "Found $($networkManagers.Count) network manager instance(s) to audit." "INFO"

# ---------------------------------------------------------------------------
# Execute — per network manager: groups, configurations, deployment coverage
# ---------------------------------------------------------------------------
foreach ($nm in $networkManagers) {

    Write-Status "Auditing network manager: $($nm.Name) (RG: $($nm.ResourceGroupName))" "INFO"

    # --- Network groups + membership ---
    try {
        $groups = @(Get-AzNetworkManagerGroup -ResourceGroupName $nm.ResourceGroupName -NetworkManagerName $nm.Name -ErrorAction Stop)
    }
    catch {
        Write-Status "Failed to enumerate network groups for $($nm.Name): $($_.Exception.Message)" "WARN"
        $groups = @()
        $results.Add([PSCustomObject]@{
            CheckType         = "NetworkGroup"
            NetworkManagerName = $nm.Name
            ResourceGroupName = $nm.ResourceGroupName
            ItemName          = ""
            Region            = ""
            DeploymentStatus  = ""
            ConfigurationIds  = ""
            Flags             = "CheckFailed: $($_.Exception.Message)"
        })
    }

    foreach ($group in $groups) {
        $memberType = "Unknown"
        try { if ($group.PSObject.Properties['MemberType']) { $memberType = $group.MemberType } } catch { }

        $staticMemberCount = -1
        if ($memberType -eq "Static" -or $memberType -eq "Unknown") {
            try {
                $staticMembers = @(Get-AzNetworkManagerStaticMember -ResourceGroupName $nm.ResourceGroupName -NetworkManagerName $nm.Name -NetworkGroupName $group.Name -ErrorAction Stop)
                $staticMemberCount = $staticMembers.Count
            }
            catch {
                # Static member enumeration can fail for dynamic-only groups or on a permission gap — non-fatal
                $staticMemberCount = -1
            }
        }

        $groupFlags = New-Object System.Collections.Generic.List[string]
        if ($memberType -eq "Static" -and $staticMemberCount -eq 0) {
            $groupFlags.Add("ZERO_STATIC_MEMBERS")
        }

        $results.Add([PSCustomObject]@{
            CheckType         = "NetworkGroup"
            NetworkManagerName = $nm.Name
            ResourceGroupName = $nm.ResourceGroupName
            ItemName          = $group.Name
            Region            = ""
            DeploymentStatus  = "MemberType=$memberType; StaticMemberCount=$staticMemberCount"
            ConfigurationIds  = ""
            Flags             = if ($groupFlags.Count -gt 0) { $groupFlags -join ";" } else { "OK" }
        })
    }

    # --- Connectivity configurations ---
    try {
        $connectivityConfigs = @(Get-AzNetworkManagerConnectivityConfiguration -ResourceGroupName $nm.ResourceGroupName -NetworkManagerName $nm.Name -ErrorAction Stop)
    }
    catch {
        Write-Status "Failed to enumerate connectivity configurations for $($nm.Name): $($_.Exception.Message)" "WARN"
        $connectivityConfigs = @()
    }

    # --- Deployment status, connectivity type, all regions (no -Region filter = every deployed region) ---
    $connectivityDeployments = @()
    try {
        $connectivityDeployments = @(Get-AzNetworkManagerDeploymentStatus -ResourceGroupName $nm.ResourceGroupName -NetworkManagerName $nm.Name -DeploymentType @("Connectivity") -ErrorAction Stop)
    }
    catch {
        Write-Status "Failed to retrieve connectivity deployment status for $($nm.Name): $($_.Exception.Message)" "WARN"
        $results.Add([PSCustomObject]@{
            CheckType         = "ConnectivityDeployment"
            NetworkManagerName = $nm.Name
            ResourceGroupName = $nm.ResourceGroupName
            ItemName          = ""
            Region            = ""
            DeploymentStatus  = ""
            ConfigurationIds  = ""
            Flags             = "CheckFailed: $($_.Exception.Message)"
        })
    }

    # Build the set of configuration IDs that appear in ANY deployment entry
    $deployedConfigIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($deployment in $connectivityDeployments) {
        foreach ($id in @($deployment.ConfigurationIds)) { [void]$deployedConfigIds.Add($id) }

        $deployFlags = New-Object System.Collections.Generic.List[string]
        if ($deployment.DeploymentStatus -eq "Failed") { $deployFlags.Add("DEPLOYMENT_FAILED") }
        if (@($deployment.ConfigurationIds).Count -gt 1) { $deployFlags.Add("MULTI_CONFIG_GOAL_STATE_RISK") }

        $results.Add([PSCustomObject]@{
            CheckType         = "ConnectivityDeployment"
            NetworkManagerName = $nm.Name
            ResourceGroupName = $nm.ResourceGroupName
            ItemName          = "(deployment)"
            Region            = $deployment.Region
            DeploymentStatus  = "$($deployment.DeploymentStatus)$(if ($deployment.ErrorMessage) { ' — ' + $deployment.ErrorMessage })"
            ConfigurationIds  = (@($deployment.ConfigurationIds) -join ";")
            Flags             = if ($deployFlags.Count -gt 0) { $deployFlags -join ";" } else { "OK" }
        })
    }

    # Flag connectivity configurations that exist but never appear in any deployment
    foreach ($cfg in $connectivityConfigs) {
        if (-not $deployedConfigIds.Contains($cfg.Id)) {
            $results.Add([PSCustomObject]@{
                CheckType         = "ConnectivityConfiguration"
                NetworkManagerName = $nm.Name
                ResourceGroupName = $nm.ResourceGroupName
                ItemName          = $cfg.Name
                Region            = ""
                DeploymentStatus  = ""
                ConfigurationIds  = $cfg.Id
                Flags             = "DEFINED_NOT_DEPLOYED"
            })
        }
    }

    # --- Security admin configuration deployment coverage (presence/failure only — content is NSG-A.md's job) ---
    if (-not $SkipSecurityAdminDeploymentCheck) {
        try {
            $securityAdminConfigs = @(Get-AzNetworkManagerSecurityAdminConfiguration -ResourceGroupName $nm.ResourceGroupName -NetworkManagerName $nm.Name -ErrorAction Stop)
            $securityAdminDeployments = @(Get-AzNetworkManagerDeploymentStatus -ResourceGroupName $nm.ResourceGroupName -NetworkManagerName $nm.Name -DeploymentType @("SecurityAdmin") -ErrorAction Stop)

            $deployedAdminIds = New-Object System.Collections.Generic.HashSet[string]
            foreach ($deployment in $securityAdminDeployments) {
                foreach ($id in @($deployment.ConfigurationIds)) { [void]$deployedAdminIds.Add($id) }

                $adminFlags = New-Object System.Collections.Generic.List[string]
                if ($deployment.DeploymentStatus -eq "Failed") { $adminFlags.Add("DEPLOYMENT_FAILED") }

                $results.Add([PSCustomObject]@{
                    CheckType         = "SecurityAdminDeployment"
                    NetworkManagerName = $nm.Name
                    ResourceGroupName = $nm.ResourceGroupName
                    ItemName          = "(deployment)"
                    Region            = $deployment.Region
                    DeploymentStatus  = "$($deployment.DeploymentStatus)$(if ($deployment.ErrorMessage) { ' — ' + $deployment.ErrorMessage })"
                    ConfigurationIds  = (@($deployment.ConfigurationIds) -join ";")
                    Flags             = if ($adminFlags.Count -gt 0) { $adminFlags -join ";" } else { "OK" }
                })
            }

            foreach ($cfg in $securityAdminConfigs) {
                if (-not $deployedAdminIds.Contains($cfg.Id)) {
                    $results.Add([PSCustomObject]@{
                        CheckType         = "SecurityAdminConfiguration"
                        NetworkManagerName = $nm.Name
                        ResourceGroupName = $nm.ResourceGroupName
                        ItemName          = $cfg.Name
                        Region            = ""
                        DeploymentStatus  = ""
                        ConfigurationIds  = $cfg.Id
                        Flags             = "DEFINED_NOT_DEPLOYED"
                    })
                }
            }
        }
        catch {
            Write-Status "Security admin deployment check failed or insufficient permissions for $($nm.Name) — recorded as CheckFailed rather than skipped silently." "WARN"
            $results.Add([PSCustomObject]@{
                CheckType         = "SecurityAdminDeployment"
                NetworkManagerName = $nm.Name
                ResourceGroupName = $nm.ResourceGroupName
                ItemName          = ""
                Region            = ""
                DeploymentStatus  = ""
                ConfigurationIds  = ""
                Flags             = "CheckFailed: $($_.Exception.Message)"
            })
        }
    }
    else {
        Write-Status "Security admin deployment check skipped (-SkipSecurityAdminDeploymentCheck)." "INFO"
    }
}

# ---------------------------------------------------------------------------
# Execute — optional single-VNet effective state check
# ---------------------------------------------------------------------------
if ($VirtualNetworkName -and $VirtualNetworkResourceGroupName) {
    Write-Status "Checking effective (authoritative) state on VNet: $VirtualNetworkName..." "INFO"
    try {
        $effectiveConnectivity = @(Get-AzNetworkManagerEffectiveConnectivityConfiguration -VirtualNetworkName $VirtualNetworkName -VirtualNetworkResourceGroupName $VirtualNetworkResourceGroupName -ErrorAction Stop)

        $results.Add([PSCustomObject]@{
            CheckType         = "EffectiveConnectivity"
            NetworkManagerName = ""
            ResourceGroupName = $VirtualNetworkResourceGroupName
            ItemName          = $VirtualNetworkName
            Region            = ""
            DeploymentStatus  = ""
            ConfigurationIds  = (@($effectiveConnectivity | ForEach-Object { $_.Id }) -join ";")
            Flags             = if ($effectiveConnectivity.Count -eq 0) { "NOT_RECEIVING_CONNECTIVITY_CONFIG" } else { "OK" }
        })
    }
    catch {
        Write-Status "Effective connectivity check failed for $($VirtualNetworkName): $($_.Exception.Message)" "WARN"
        $results.Add([PSCustomObject]@{
            CheckType         = "EffectiveConnectivity"
            NetworkManagerName = ""
            ResourceGroupName = $VirtualNetworkResourceGroupName
            ItemName          = $VirtualNetworkName
            Region            = ""
            DeploymentStatus  = ""
            ConfigurationIds  = ""
            Flags             = "CheckFailed: $($_.Exception.Message)"
        })
    }

    try {
        $effectiveAdmin = @(Get-AzNetworkManagerEffectiveSecurityAdminRule -VirtualNetworkName $VirtualNetworkName -VirtualNetworkResourceGroupName $VirtualNetworkResourceGroupName -ErrorAction Stop)

        $results.Add([PSCustomObject]@{
            CheckType         = "EffectiveSecurityAdmin"
            NetworkManagerName = ""
            ResourceGroupName = $VirtualNetworkResourceGroupName
            ItemName          = $VirtualNetworkName
            Region            = ""
            DeploymentStatus  = ""
            ConfigurationIds  = ""
            Flags             = "RuleCount=$($effectiveAdmin.Count) (see NSG-A.md for rule-content interpretation)"
        })
    }
    catch {
        Write-Status "Effective security admin rule check failed for $($VirtualNetworkName): $($_.Exception.Message)" "WARN"
        $results.Add([PSCustomObject]@{
            CheckType         = "EffectiveSecurityAdmin"
            NetworkManagerName = ""
            ResourceGroupName = $VirtualNetworkResourceGroupName
            ItemName          = $VirtualNetworkName
            Region            = ""
            DeploymentStatus  = ""
            ConfigurationIds  = ""
            Flags             = "CheckFailed: $($_.Exception.Message)"
        })
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$definedNotDeployedCount = ($results | Where-Object { $_.Flags -like "*DEFINED_NOT_DEPLOYED*" }).Count
$goalStateRiskCount = ($results | Where-Object { $_.Flags -like "*MULTI_CONFIG_GOAL_STATE_RISK*" }).Count
$failedDeploymentCount = ($results | Where-Object { $_.Flags -like "*DEPLOYMENT_FAILED*" }).Count
$zeroMemberGroupCount = ($results | Where-Object { $_.Flags -like "*ZERO_STATIC_MEMBERS*" }).Count
$notReceivingCount = ($results | Where-Object { $_.Flags -like "*NOT_RECEIVING_CONNECTIVITY_CONFIG*" }).Count

Write-Status "Audit complete." "OK"
Write-Status "  Configurations defined but never deployed: $definedNotDeployedCount" "INFO"
Write-Status "  Regions with multi-configuration goal-state risk: $goalStateRiskCount" "INFO"
Write-Status "  Failed deployments: $failedDeploymentCount" "INFO"
Write-Status "  Static network groups with zero members: $zeroMemberGroupCount" "INFO"

if ($definedNotDeployedCount -gt 0) {
    Write-Status "  $definedNotDeployedCount configuration(s) exist but were never deployed — they are doing nothing. See AVNM-B.md Fix 1." "WARN"
}
if ($failedDeploymentCount -gt 0) {
    Write-Status "  $failedDeploymentCount deployment(s) show Failed status — review ErrorMessage in the report." "WARN"
}
if ($notReceivingCount -gt 0) {
    Write-Status "  Target VNet is not receiving any effective connectivity configuration — see AVNM-B.md Triage." "WARN"
}

$exportDir = Split-Path $ExportPath -Parent
if ($exportDir -and -not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to: $ExportPath" "OK"

return $results
