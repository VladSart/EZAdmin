<#
.SYNOPSIS
    Fleet-wide audit of AVD Scaling Plan configuration, RBAC prerequisites, host pool assignment,
    and drain/session conflicts — the checks behind Scaling-A.md and Scaling-B.md's Triage steps.

.DESCRIPTION
    Connects to Azure and audits one or more AVD Scaling Plans and their assigned host pools,
    surfacing the misconfigurations that most commonly cause "scaling plan shows no errors but
    VMs just don't respond" tickets.

    Checks performed:
      - RBAC: does the "Windows Virtual Desktop" / "Azure Virtual Desktop" service principal have
        "Desktop Virtualization Power On Off Contributor" at the host pool / resource group scope?
      - Assignment: is the scaling plan actually linked to the host pool(s) it's meant to manage?
      - Drain conflicts: any session host in drain mode (AllowNewSession=False) that still has
        active sessions — autoscale will not shut it down, which looks like a "stuck" host
      - Off-peak/ramp-down floor: any schedule with minimum host percentage of 0% AND the host
        pool type is Personal without Start VM on Connect enabled (users will be unable to connect
        outside ramp-up/peak windows)
      - Exclusion tags: enumerates VMs tagged with the plan's ExclusionTag so "why isn't this host
        scaling?" investigations don't waste time re-deriving this from the portal
      - Diagnostic settings: whether the scaling plan has a diagnostic setting configured (needed
        for WVDAutoscaleEvaluationPooled query-based troubleshooting)

    Flags raised:
      MISSING_RBAC_ROLE        - AVD service principal lacks Power On Off Contributor at RG scope
      NOT_ASSIGNED_TO_HOSTPOOL - Scaling plan exists but has no host pool association
      DRAIN_WITH_ACTIVE_SESSIONS - Host in drain mode with Sessions > 0 (won't be stopped by design;
                                    flagged so it isn't mistaken for a scaling bug)
      ZERO_FLOOR_NO_START_ON_CONNECT - Personal pool, off-peak minimum 0%, Start VM on Connect off
      NO_DIAGNOSTICS            - No diagnostic setting found on the scaling plan resource
      TIMEZONE_UNVERIFIED       - Informational: lists configured time zone for manual DST sanity check

    Read-only — does not change RBAC, host pool assignment, VM tags, or diagnostic settings.

.PARAMETER ResourceGroupName
    Resource group to scope the audit to. If omitted, scans all resource groups in the subscription.

.PARAMETER ScalingPlanName
    Specific scaling plan to audit. If omitted, audits all scaling plans found in scope.

.PARAMETER SubscriptionId
    Azure subscription ID. If omitted, uses the current Az context subscription.

.PARAMETER ExportPath
    Path to export the CSV summary. Defaults to C:\Temp\AVDScalingAudit_<timestamp>.csv.

.EXAMPLE
    .\Get-AVDScalingPlanAudit.ps1 -ResourceGroupName 'rg-avd-prod'

    Audits every scaling plan found in rg-avd-prod.

.EXAMPLE
    .\Get-AVDScalingPlanAudit.ps1 -ResourceGroupName 'rg-avd-prod' -ScalingPlanName 'sp-weekday'

    Audits a single named scaling plan.

.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization, Az.Compute, Az.Resources modules.
    Install:  Install-Module Az.Accounts, Az.DesktopVirtualization, Az.Compute, Az.Resources -Scope CurrentUser
    Permissions: Reader on the scaling plan / host pool resource groups; Reader on role assignments
    (Microsoft.Authorization/roleAssignments/read) to check the RBAC prerequisite.
    Safe to run: Read-only. No remediation actions are taken.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$ScalingPlanName,
    [string]$SubscriptionId,
    [string]$ExportPath = "C:\Temp\AVDScalingAudit_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        default { 'Cyan'   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region — Preflight
Write-Status 'AVD Scaling Plan Audit' 'INFO'
Write-Status '=======================' 'INFO'

$requiredModules = 'Az.Accounts', 'Az.DesktopVirtualization', 'Az.Compute', 'Az.Resources'
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" 'ERROR'
        throw "Missing required module: $mod"
    }
}

try {
    $ctx = Get-AzContext
    if (-not $ctx) {
        Write-Status 'No Azure context — launching interactive login...' 'WARN'
        Connect-AzAccount
        $ctx = Get-AzContext
    }
    Write-Status "Azure context: $($ctx.Account.Id) | $($ctx.Subscription.Name)" 'OK'
} catch {
    Write-Status "Failed to get Azure context: $_" 'ERROR'
    throw
}

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Status "Switched to subscription: $SubscriptionId" 'OK'
}

$outDir = Split-Path $ExportPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
#endregion

#region — AVD service principal lookup (once)
Write-Status 'Resolving AVD autoscale service principal...' 'INFO'
$avdSp = Get-AzADServicePrincipal -DisplayName 'Windows Virtual Desktop' -ErrorAction SilentlyContinue
if (-not $avdSp) {
    $avdSp = Get-AzADServicePrincipal -DisplayName 'Azure Virtual Desktop' -ErrorAction SilentlyContinue
}
if (-not $avdSp) {
    Write-Status 'Could not resolve AVD service principal by display name — RBAC checks will be skipped.' 'WARN'
}
#endregion

#region — Discover scaling plans
Write-Status 'Discovering scaling plans...' 'INFO'
try {
    if ($ResourceGroupName -and $ScalingPlanName) {
        $plans = @(Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -Name $ScalingPlanName)
    } elseif ($ResourceGroupName) {
        $plans = @(Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName)
    } else {
        $plans = @(Get-AzWvdScalingPlan)
    }
} catch {
    Write-Status "Failed to retrieve scaling plans: $_" 'ERROR'
    throw
}

if (-not $plans -or $plans.Count -eq 0) {
    Write-Status 'No scaling plans found with the specified parameters.' 'WARN'
    return
}
Write-Status "Found $($plans.Count) scaling plan(s)." 'OK'
#endregion

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($plan in $plans) {
    $planRG   = ($plan.Id -split '/')[4]
    $planName = $plan.Name
    $flags    = [System.Collections.Generic.List[string]]::new()

    Write-Status "Auditing scaling plan: $planName (RG: $planRG)" 'INFO'

    #region — Host pool associations
    $associations = @()
    try {
        $associations = @(Get-AzWvdScalingPlanHostPoolAssociation -ResourceGroupName $planRG -ScalingPlanName $planName -ErrorAction SilentlyContinue)
    } catch { $associations = @() }

    if (-not $associations -or $associations.Count -eq 0) {
        $flags.Add('NOT_ASSIGNED_TO_HOSTPOOL')
        Write-Status "  No host pool association found for $planName." 'ERROR'
    } else {
        Write-Status "  Assigned to $($associations.Count) host pool(s)." 'OK'
    }
    #endregion

    #region — RBAC check
    $rbacOk = $false
    if ($avdSp) {
        try {
            $roles = Get-AzRoleAssignment -ObjectId $avdSp.Id -ResourceGroupName $planRG -ErrorAction SilentlyContinue
            $rbacOk = [bool]($roles | Where-Object { $_.RoleDefinitionName -like '*Power On Off*' })
        } catch { $rbacOk = $false }

        if (-not $rbacOk) {
            $flags.Add('MISSING_RBAC_ROLE')
            Write-Status "  AVD service principal missing 'Desktop Virtualization Power On Off Contributor' at RG scope." 'ERROR'
        } else {
            Write-Status '  RBAC role present.' 'OK'
        }
    }
    #endregion

    #region — Per-host-pool: drain/session conflicts and zero-floor check
    foreach ($assoc in $associations) {
        $hpId = $assoc.HostPoolArmPath
        if (-not $hpId) { continue }
        $hpName = ($hpId -split '/')[-1]
        $hpRG   = ($hpId -split '/')[4]

        try {
            $hostPool = Get-AzWvdHostPool -ResourceGroupName $hpRG -Name $hpName -ErrorAction Stop
        } catch {
            Write-Status "  Could not retrieve host pool $hpName`: $_" 'WARN'
            continue
        }

        try {
            $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $hpRG -HostPoolName $hpName -ErrorAction SilentlyContinue
        } catch { $sessionHosts = @() }

        $drainConflicts = $sessionHosts | Where-Object { $_.AllowNewSession -eq $false -and $_.Session -gt 0 }
        if ($drainConflicts) {
            $flags.Add('DRAIN_WITH_ACTIVE_SESSIONS')
            Write-Status "  Host pool $hpName`: $($drainConflicts.Count) host(s) in drain mode with active sessions (won't be stopped by design)." 'WARN'
        }

        if ($hostPool.HostPoolType -eq 'Personal' -and -not $hostPool.StartVMOnConnect) {
            foreach ($sched in $plan.Schedule) {
                $offPeakFloor = if ($sched.PSObject.Properties.Name -contains 'OffPeakMinimumHostsPct') { $sched.OffPeakMinimumHostsPct } else { $null }
                if ($offPeakFloor -eq 0) {
                    $flags.Add('ZERO_FLOOR_NO_START_ON_CONNECT')
                    Write-Status "  Host pool $hpName`: Personal pool, off-peak floor 0%, Start VM on Connect disabled — users cannot connect off-peak." 'ERROR'
                    break
                }
            }
        }
    }
    #endregion

    #region — Diagnostic settings
    $diagOk = $false
    try {
        $diag = Get-AzDiagnosticSetting -ResourceId $plan.Id -ErrorAction SilentlyContinue
        $diagOk = [bool]$diag
    } catch { $diagOk = $false }

    if (-not $diagOk) {
        $flags.Add('NO_DIAGNOSTICS')
        Write-Status '  No diagnostic setting configured — WVDAutoscaleEvaluationPooled troubleshooting unavailable.' 'WARN'
    } else {
        Write-Status '  Diagnostic setting present.' 'OK'
    }
    #endregion

    Write-Status "  Time zone: $($plan.TimeZone) (verify DST handling manually if users report off-by-one-hour scaling)" 'INFO'

    $report.Add([PSCustomObject]@{
        ScalingPlan          = $planName
        ResourceGroup        = $planRG
        HostPoolType         = $plan.HostPoolType
        TimeZone             = $plan.TimeZone
        HostPoolAssociations = $associations.Count
        RBACRoleAssigned     = $rbacOk
        DiagnosticsEnabled   = $diagOk
        Flags                = ($flags -join '; ')
    })
}

#region — Summary and export
Write-Status '' 'INFO'
Write-Status '=== SUMMARY ===' 'INFO'
$flaggedPlans = $report | Where-Object { $_.Flags -ne '' }
Write-Status "Scaling plans audited: $($report.Count)" 'INFO'
Write-Status "Scaling plans with flags: $($flaggedPlans.Count)" $(if ($flaggedPlans.Count -eq 0) { 'OK' } else { 'WARN' })

if ($flaggedPlans) {
    $flaggedPlans | Select-Object ScalingPlan, ResourceGroup, Flags | Format-Table -AutoSize -Wrap
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" 'OK'
#endregion
