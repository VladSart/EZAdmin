<#
.SYNOPSIS
    Read-only audit of Azure Lighthouse delegations visible from the currently authenticated
    managing-tenant context: registration assignment/definition state, authorization content,
    and flags for unsupported-role and eligible-without-permanent-role misconfigurations.

.DESCRIPTION
    Matches the dependency stack documented in Azure/Lighthouse/Lighthouse-A.md and
    Lighthouse-B.md. For every Lighthouse delegation visible to the current session, checks:
      1. Registration assignment/definition provisioning state (definition without a
         succeeded assignment = onboarding never actually completed).
      2. Every authorization entry's principalId/roleDefinitionId, flagging any known
         unsupported role pattern (Owner, User Access Administrator used WITHOUT the
         required delegatedRoleDefinitionIds constraint) that should never have been
         accepted by ARM in the first place but is worth confirming isn't present due to
         a since-changed template or a role definition ID typo resolving to something
         unexpected.
      3. Whether any eligible-type authorization exists without at least one permanent
         (non-eligible) authorization present in the same offer.
      4. Whether individual users (not groups) are used as principalId — a design smell,
         not a hard error, flagged as a maintainability finding.

    This script does NOT create, modify, or remove any registration definition, assignment,
    or authorization. It only reads what Get-AzManagedServicesAssignment/-Definition expose
    for the currently authenticated context — it cannot enumerate delegations the current
    session isn't a principal in / doesn't have visibility into.

.PARAMETER SubscriptionId
    Optional. Scope the audit to Lighthouse delegations on a specific customer subscription
    ID. If omitted, audits every delegation visible in the current session across all
    subscriptions the managing tenant has access to enumerate.

.PARAMETER OutputPath
    Folder to write the CSV summary to. Default: current directory.

.EXAMPLE
    .\Get-LighthouseDelegationAudit.ps1
    Audits every Lighthouse delegation visible to the current authenticated session.

.EXAMPLE
    .\Get-LighthouseDelegationAudit.ps1 -SubscriptionId "11111111-1111-1111-1111-111111111111"
    Audits only the delegation(s) covering a specific customer subscription.

.NOTES
    Requires: Az.ManagedServices and Az.Resources PowerShell modules, authenticated
              (Connect-AzAccount) as a principal in the MANAGING tenant with visibility
              into the delegations being audited.
    Run-as: Any managing-tenant principal with read access to the relevant registration
            definitions/assignments — no elevated rights required for this read-only audit.
    Safe/Unsafe: 100% read-only. No delegation, authorization, or role assignment is
                 created, modified, or removed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
try {
    Import-Module Az.ManagedServices -ErrorAction Stop
    Import-Module Az.Resources -ErrorAction Stop
} catch {
    Write-Status "Az.ManagedServices / Az.Resources modules not available. Install-Module Az.ManagedServices, Az.Resources." "ERROR"
    throw
}

try {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw "No active Azure context." }
} catch {
    Write-Status "Not authenticated. Run Connect-AzAccount against the MANAGING tenant first." "ERROR"
    throw
}

Write-Status "Auditing Lighthouse delegations as seen from tenant: $($ctx.Tenant.Id)"

# Known unsupported / restricted role definition GUIDs (built-in Azure roles)
$ownerRoleId = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
$uaaRoleId   = "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"

$results = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Enumerate assignments (optionally scoped to a specific subscription)
# ---------------------------------------------------------------------------
Write-Status "Enumerating registration assignments..."

try {
    if ($SubscriptionId) {
        $assignments = @(Get-AzManagedServicesAssignment -Scope "/subscriptions/$SubscriptionId" -ErrorAction Stop)
    } else {
        $assignments = @(Get-AzManagedServicesAssignment -ErrorAction Stop)
    }
} catch {
    Write-Status "Could not enumerate registration assignments: $($_.Exception.Message)" "ERROR"
    $assignments = @()
}

if ($assignments.Count -eq 0) {
    Write-Status "No Lighthouse delegations visible to this session (or none in the specified scope)." "WARN"
}

foreach ($assignment in $assignments) {

    $scope = $assignment.Scope
    Write-Status "Auditing delegation at scope: $scope" "INFO"

    $findings = [System.Collections.Generic.List[string]]::new()

    if ($assignment.ProvisioningState -ne "Succeeded") {
        $findings.Add("ASSIGNMENT_NOT_SUCCEEDED:$($assignment.ProvisioningState)")
    }

    # Resolve the paired registration definition for authorization detail
    $definition = $null
    try {
        $definition = Get-AzManagedServicesDefinition -Scope $scope -ErrorAction Stop |
            Where-Object { $_.Id -eq $assignment.RegistrationDefinitionId } | Select-Object -First 1
        if (-not $definition) {
            # Fallback: some module versions require enumerating without the assignment filter
            $definition = (Get-AzManagedServicesDefinition -Scope $scope -ErrorAction Stop) | Select-Object -First 1
        }
    } catch {
        $findings.Add("DEFINITION_LOOKUP_FAILED")
    }

    $authSummary = "NONE_FOUND"
    $eligibleCount = 0
    $permanentCount = 0
    $individualPrincipalCount = 0

    if ($definition -and $definition.Authorization) {
        $authEntries = @($definition.Authorization)
        $authDetail = [System.Collections.Generic.List[string]]::new()

        foreach ($auth in $authEntries) {
            $roleId = $auth.RoleDefinitionId
            $isEligible = $false
            try { if ($auth.PSObject.Properties.Match('Type').Count -gt 0 -and $auth.Type -eq 'Eligible') { $isEligible = $true } } catch {}

            if ($isEligible) { $eligibleCount++ } else { $permanentCount++ }

            if ($roleId -eq $ownerRoleId) {
                $findings.Add("UNSUPPORTED_ROLE_OWNER_PRESENT")
            }
            if ($roleId -eq $uaaRoleId) {
                $hasDelegated = $false
                try { if ($auth.PSObject.Properties.Match('DelegatedRoleDefinitionIds').Count -gt 0 -and $auth.DelegatedRoleDefinitionIds) { $hasDelegated = $true } } catch {}
                if (-not $hasDelegated) {
                    $findings.Add("UAA_WITHOUT_DELEGATED_ROLE_CONSTRAINT")
                }
            }

            # Heuristic: a principalIdDisplayName that looks like an individual person
            # (contains an @ or looks like "First Last") rather than a group naming pattern
            # is flagged as a maintainability smell, not an error
            $displayName = $auth.PrincipalIdDisplayName
            if ($displayName -and ($displayName -match '@' -or $displayName -notmatch '(?i)group|team|admins|contributors|lighthouse')) {
                $individualPrincipalCount++
            }

            $authDetail.Add("$displayName [$roleId]$(if($isEligible){' (Eligible)'})")
        }

        $authSummary = ($authDetail -join "; ")

        if ($eligibleCount -gt 0 -and $permanentCount -eq 0) {
            $findings.Add("ELIGIBLE_WITHOUT_PERMANENT_AUTHORIZATION")
        }
        if ($individualPrincipalCount -gt 0) {
            $findings.Add("POSSIBLE_INDIVIDUAL_PRINCIPAL_USED:$individualPrincipalCount")
        }
    } else {
        $findings.Add("NO_AUTHORIZATIONS_FOUND_OR_DEFINITION_UNRESOLVED")
    }

    if ($findings.Count -eq 0) { $findings.Add("OK") }

    $results.Add([PSCustomObject]@{
        Scope                = $scope
        OfferName            = if ($definition) { $definition.RegistrationDefinitionName } else { "UNKNOWN" }
        ManagedByTenantId    = if ($definition) { $definition.ManagedByTenantId } else { "UNKNOWN" }
        AssignmentState      = $assignment.ProvisioningState
        PermanentAuthCount   = $permanentCount
        EligibleAuthCount    = $eligibleCount
        AuthorizationDetail  = $authSummary
        Findings             = ($findings -join ", ")
    })
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----- Summary -----" "INFO"
$results | Format-Table Scope, OfferName, AssignmentState, PermanentAuthCount, EligibleAuthCount, Findings -AutoSize

$flaggedCount = @($results | Where-Object { $_.Findings -ne "OK" }).Count
if ($flaggedCount -gt 0) {
    Write-Status "$flaggedCount of $($results.Count) delegation(s) have one or more findings. Review the Findings column." "WARN"
} else {
    Write-Status "All $($results.Count) delegation(s) audited cleanly." "OK"
}

$csvPath = Join-Path -Path $OutputPath -ChildPath "LighthouseDelegationAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"
