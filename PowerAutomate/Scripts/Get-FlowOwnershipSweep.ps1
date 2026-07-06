<#
.SYNOPSIS
    Tenant-wide discovery sweep for Power Automate flows owned by a departing/offboarded user —
    automates Phase 1-3 triage from Flow-Ownership-Transfer-A.md.

.DESCRIPTION
    Enumerates every Power Platform environment (including the commonly-missed "Default"
    environment) and finds every cloud flow created by the specified user, then flags the
    specific risk signals the runbooks call out as most important for triage:

    - NO_CO_OWNER: single point of failure — nobody else can edit/re-authenticate the flow
      once the owner's account is disabled.
    - PREMIUM_CONNECTOR: flow references a connector (HTTP, SQL, Dataverse, on-prem gateway,
      etc.) that requires Power Automate Premium — a successor owner without that license
      will be able to take ownership but fail to save/enable the flow, per the runbook's
      Symptom -> Cause Map.
    - DISABLED: flow is already Enabled=False, most commonly because Power Automate
      auto-suspended it after the owning identity's connections started failing.

    This script does NOT transfer ownership or touch any connection — remediation
    (Set-AdminFlowOwnerRole, manual per-action reconnection) is a deliberate follow-up step,
    per the runbooks' emphasis that ownership and connection identity are separate systems
    and reassigning one does not fix the other.

    Read-only. Makes no changes to any flow, connection, or ownership role.

.PARAMETER DepartingUserUpn
    UPN of the user being offboarded, e.g. jane.doe@contoso.com.

.PARAMETER OutputPath
    Path to export CSV reports. Default: C:\Temp\FlowOwnershipSweep-<timestamp>

.EXAMPLE
    .\Get-FlowOwnershipSweep.ps1 -DepartingUserUpn "jane.doe@contoso.com"

.NOTES
    Requires: Microsoft.PowerApps.Administration.PowerShell, Microsoft.PowerApps.PowerShell modules
    Install:  Install-Module Microsoft.PowerApps.Administration.PowerShell, Microsoft.PowerApps.PowerShell -Scope CurrentUser -AllowClobber
    Auth:     Add-PowerAppsAccount
    Permissions: Power Platform Environment Admin or Tenant Admin
    Safe to run repeatedly — read-only. Best run BEFORE the account is disabled (Phase 1 of
    Flow-Ownership-Transfer-A.md) so connections can still be observed working, not just found broken.
    Companion runbooks: PowerAutomate/Troubleshooting/Flow-Ownership-Transfer-A.md and -B.md
    Companion script:    PowerAutomate/Scripts/Get-FlowRunHistory.ps1 (per-flow run detail)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DepartingUserUpn,

    [Parameter()]
    [string]$OutputPath = "C:\Temp\FlowOwnershipSweep-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $Colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $Colour
}

# Connectors that require a Power Automate Premium license — not exhaustive, covers the
# highest-frequency offenders called out in the runbook's licensing gap symptom.
$PremiumConnectors = @(
    "shared_httpwithazuread", "shared_http", "shared_sql", "shared_azureblob",
    "shared_dataverse", "shared_commondataserviceforapps", "shared_azuretables",
    "shared_ftp", "shared_odataopenapi", "shared_hdinsight", "shared_azurequeues"
)

# ─── Preflight ────────────────────────────────────────────────────────────────

foreach ($Mod in @("Microsoft.PowerApps.Administration.PowerShell", "Microsoft.PowerApps.PowerShell")) {
    if (-not (Get-Module -ListAvailable -Name $Mod)) {
        Write-Status "$Mod not found. Installing..." "WARN"
        Install-Module $Mod -Scope CurrentUser -Force -AllowClobber -AcceptLicense
    }
}
Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop
Import-Module Microsoft.PowerApps.PowerShell -ErrorAction Stop

Write-Status "Authenticating to Power Platform..."
try { Add-PowerAppsAccount | Out-Null } catch { Write-Status "Power Platform auth failed: $_" "ERROR"; exit 1 }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# ─── Discover environments (never assume just one) ────────────────────────────

Write-Status "Enumerating Power Platform environments (including Default)..."
$Environments = @(Get-AdminPowerAppEnvironment)
Write-Status "Found $($Environments.Count) environment(s)." "OK"

# ─── Sweep every environment for flows owned by the departing user ───────────

$Report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Env in $Environments) {

    $EnvName    = $Env.EnvironmentName
    $EnvDisplay = $Env.DisplayName

    Write-Status "Scanning environment: $EnvDisplay"
    $Flows = @(Get-AdminFlow -EnvironmentName $EnvName -ErrorAction SilentlyContinue | Where-Object {
        $_.CreatedBy.userPrincipalName -eq $DepartingUserUpn -or $_.CreatedBy.email -eq $DepartingUserUpn
    })

    if ($Flows.Count -eq 0) { continue }
    Write-Status "  -> $($Flows.Count) flow(s) owned by $DepartingUserUpn" "WARN"

    foreach ($Flow in $Flows) {

        $CoOwners = @()
        try {
            $CoOwners = @(Get-AdminFlowOwnerRole -EnvironmentName $EnvName -FlowName $Flow.FlowName -ErrorAction SilentlyContinue |
                Where-Object { $_.RoleType -eq "CanEdit" })
        } catch {}

        # Best-effort premium connector detection from the flow's connection references
        $PremiumHit = $false
        $ConnectorsUsed = @()
        try {
            $ConnRefs = $Flow.Internal.properties.connectionReferences
            if ($ConnRefs) {
                $ConnectorsUsed = $ConnRefs.PSObject.Properties.Value.apiId |
                    ForEach-Object { ($_ -split "/")[-1] } | Select-Object -Unique
                foreach ($c in $ConnectorsUsed) {
                    if ($PremiumConnectors -contains $c) { $PremiumHit = $true; break }
                }
            }
        } catch {
            # Some flow objects don't expose connectionReferences via this property path
        }

        $Flags = [System.Collections.Generic.List[string]]::new()
        if ($CoOwners.Count -eq 0) { $Flags.Add("NO_CO_OWNER: single point of failure") }
        if (-not $Flow.Enabled) { $Flags.Add("DISABLED: already suspended, check connection health before re-enabling") }
        if ($PremiumHit) { $Flags.Add("PREMIUM_CONNECTOR: successor owner needs Power Automate Premium") }

        $Status = if ($Flags.Count -eq 0) { "OK" } elseif ($CoOwners.Count -eq 0) { "ERROR" } else { "WARN" }

        $Report.Add([PSCustomObject]@{
            Environment      = $EnvDisplay
            EnvironmentId    = $EnvName
            FlowName         = $Flow.DisplayName
            FlowId           = $Flow.FlowName
            Enabled          = $Flow.Enabled
            CoOwnerCount     = $CoOwners.Count
            ConnectorsUsed   = ($ConnectorsUsed -join ", ")
            PremiumConnectorDetected = $PremiumHit
            Flags            = ($Flags -join "; ")
            Status           = $Status
        })
    }
}

# ─── Report ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== FLOW OWNERSHIP SWEEP: $DepartingUserUpn ===" -ForegroundColor Magenta
Write-Status "Total flows found: $($Report.Count)"

if ($Report.Count -eq 0) {
    Write-Status "No flows found for this UPN in any environment. If the user insists they built one, re-check the exact UPN and confirm they didn't build under a different licensed identity (e.g. shared/service account)." "WARN"
} else {
    $NoCoOwner = $Report | Where-Object { $_.CoOwnerCount -eq 0 }
    $Premium   = $Report | Where-Object PremiumConnectorDetected
    $Disabled  = $Report | Where-Object { -not $_.Enabled }

    Write-Status "`nFlows with NO co-owner (single point of failure): $($NoCoOwner.Count)" $(if ($NoCoOwner.Count -gt 0) { "ERROR" } else { "OK" })
    if ($NoCoOwner.Count -gt 0) { $NoCoOwner | Format-Table Environment, FlowName, Enabled -AutoSize }

    Write-Status "`nFlows using a premium connector (licensing coordination needed): $($Premium.Count)" $(if ($Premium.Count -gt 0) { "WARN" } else { "OK" })
    if ($Premium.Count -gt 0) { $Premium | Format-Table Environment, FlowName, ConnectorsUsed -AutoSize -Wrap }

    Write-Status "`nFlows already disabled/suspended: $($Disabled.Count)" $(if ($Disabled.Count -gt 0) { "WARN" } else { "OK" })
    if ($Disabled.Count -gt 0) { $Disabled | Format-Table Environment, FlowName -AutoSize }

    Write-Status "`nNext steps: Set-AdminFlowOwnerRole to add a co-owner for every flow above, then" "INFO"
    Write-Status "manually re-authenticate each connection as the new owner (no supported API for this)." "INFO"
    Write-Status "See Flow-Ownership-Transfer-B.md Fix 1/2 and -A.md Playbook 4 for the service-account pattern." "INFO"
}

# ─── Export ────────────────────────────────────────────────────────────────────

$Report | Export-Csv "$OutputPath\flow-ownership-sweep.csv" -NoTypeInformation -Encoding UTF8

Write-Status "`nReport exported to: $OutputPath" "OK"
Write-Status "Done." "OK"
