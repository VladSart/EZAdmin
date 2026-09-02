<#
.SYNOPSIS
    Read-only audit of Microsoft Entra Tenant Governance posture: discovery
    enablement, governance relationship health, delegated-access usability,
    the Partner Center GDAP mutual-exclusion conflict, and configuration
    monitoring quota/staleness risk.

.DESCRIPTION
    Tenant Governance has several failure modes that look identical from an
    end user's seat ("I can't manage the customer tenant") but trace to very
    different root causes: discovery was never enabled, a relationship never
    completed its handshake, a relationship is Active but the requesting
    admin was never added to the delegated security group (or is
    PIM-eligible but never activated), or — the highest-value MSP-specific
    check — an existing Partner Center GDAP relationship is silently blocking
    a new Tenant Governance relationship from being created at all, since the
    two are mutually exclusive per tenant pair by platform design.

    This script walks each of those checks and reports exactly where the
    chain breaks, plus a lightweight configuration-monitor quota/staleness
    check for tenants using the drift-detection layer.

    Analysis flags applied:
      DISCOVERY_NOT_ENABLED       - isRelatedTenantsEnabled = false. Related
                                     tenants will never populate until this
                                     one-way setting is turned on.
      RELATIONSHIP_PENDING        - A governance relationship request has
                                     been sitting in Pending state; flagged
                                     with its age for stale-request triage.
      GDAP_CONFLICT               - A relationship exists (or a request is
                                     being attempted) to a tenant that also
                                     has an active Partner Center GDAP
                                     relationship — the platform's own mutual
                                     exclusion rule will block or has already
                                     blocked one of the two.
      DELEGATED_GROUP_EMPTY       - An Active relationship's delegated
                                     administration security group has zero
                                     members — nobody can actually use the
                                     access this relationship grants.
      RELATIONSHIP_TERMINATED     - A relationship shows Terminated or
                                     Termination requested; surfaced so it
                                     isn't mistaken for an still-active,
                                     silently-broken relationship.
      MONITOR_QUOTA_RISK          - Tenant-wide resource-instance count
                                     across all configuration monitors is
                                     approaching the documented 800/day cap.
      MONITOR_OVER_BASELINE_LIMIT - A single monitor's baseline exceeds (or
                                     is close to) the 200-resource-instance
                                     per-baseline limit.

    Read-only. Makes no changes to any relationship, settings, group
    membership, or configuration monitor.

    Does NOT cover:
    - Enabling discovery (irreversible — this script only reports current
      state, never calls the enable endpoint)
    - Full configuration drift detail (queries monitor/baseline counts and
      state only; drift record inspection is a separate, tenant-specific
      deep dive — see TenantGovernance-A.md Validation Step 6)
    - PIM for Groups policy configuration itself (only whether an admin's
      activation state resolves cleanly) — see PIM for Groups troubleshooting
      under Troubleshooting/PIM-A.md for policy-level issues
    - Partner Center GDAP relationship health in its own right — see
      Get-GDAPRelationshipAudit.ps1 for that relationship's own lifecycle

.PARAMETER CheckGdapConflicts
    When set, cross-references every governance relationship's governed
    tenant ID against existing Partner Center GDAP relationships. Requires
    the calling account to also hold GDAP read permissions in a partner
    (CSP) tenant context. Default: $true

.PARAMETER StalePendingDays
    Number of days a relationship request may sit in Pending before being
    flagged for stale-request triage. Default: 14

.PARAMETER OutputPath
    Directory where CSV reports will be written.
    Default: .\TenantGovernance-Audit-<timestamp>\

.EXAMPLE
    .\Get-TenantGovernanceAudit.ps1

    Full tenant-wide Tenant Governance posture audit with default thresholds.

.EXAMPLE
    .\Get-TenantGovernanceAudit.ps1 -CheckGdapConflicts:$false -StalePendingDays 7

    Skip the GDAP cross-check (e.g., not a CSP partner tenant) and flag
    Pending requests older than 7 days instead of the 14-day default.

.NOTES
    Requires: Microsoft.Graph.Beta PowerShell SDK
              (Install-Module Microsoft.Graph.Beta -Scope CurrentUser)
    Scopes needed: TenantGovernance-Relationship.Read.All, Group.Read.All,
                   DelegatedAdminRelationship.Read.All (only if
                   -CheckGdapConflicts is used and this is a CSP partner tenant)
    Run As: Tenant Governance Reader, Global Reader, or Global Administrator
            (read only)
    Safe: Read-only — no settings, relationships, group memberships, or
          configuration monitors are changed
    Cross-references: EntraID/Troubleshooting/TenantGovernance-A.md
                       (Dependency Stack, Symptom -> Cause Map, Validation
                       Steps), TenantGovernance-B.md (Triage, Fix 1-7),
                       Get-GDAPRelationshipAudit.ps1 (run alongside this
                       script for the GDAP side of a mixed-estate MSP)
#>

[CmdletBinding()]
param(
    [bool]$CheckGdapConflicts = $true,

    [int]$StalePendingDays = 14,

    [string]$OutputPath = ".\TenantGovernance-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

function Invoke-GraphGetAll {
    <# Minimal @odata.nextLink-following GET wrapper #>
    param([string]$Uri)
    $results = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        if ($resp.value) { $results.AddRange([object[]]$resp.value) }
        $next = $resp.'@odata.nextLink'
    }
    return $results
}

# --- Connect ---
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph (beta)..." "INFO"
        $scopes = @("TenantGovernance-Relationship.Read.All", "Group.Read.All")
        if ($CheckGdapConflicts) { $scopes += "DelegatedAdminRelationship.Read.All" }
        Connect-MgGraph -Scopes $scopes -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

if (-not (Get-Command Invoke-MgGraphRequest -EA SilentlyContinue)) {
    Write-Status "Microsoft.Graph(.Beta) module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Beta -Scope CurrentUser" "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$findings = New-Object System.Collections.Generic.List[object]

# --- 1. Discovery enablement state ---
Write-Status "Checking related-tenant discovery state..." "INFO"
$discoveryEnabled = $null
try {
    $settings = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/settings" -ErrorAction Stop
    $discoveryEnabled = $settings.isRelatedTenantsEnabled
} catch {
    Write-Status "Failed to retrieve Tenant Governance settings: $($_.Exception.Message)" "ERROR"
}

if ($discoveryEnabled -eq $false) {
    $findings.Add([pscustomobject]@{
        Flag = "DISCOVERY_NOT_ENABLED"; Severity = "INFO"
        Object = "(tenant setting)"
        Detail = "isRelatedTenantsEnabled = false. Related tenants will never populate until this is enabled (POST .../settings/enableRelatedTenants). This is a ONE-WAY, irreversible setting — confirm licensing and intent before enabling."
    })
    Write-Status "Related-tenant discovery is NOT enabled for this tenant." "WARN"
} elseif ($discoveryEnabled -eq $true) {
    Write-Status "Related-tenant discovery is enabled." "OK"
} else {
    Write-Status "Could not determine discovery state (see error above)." "WARN"
}

# --- 2. Governance relationships ---
Write-Status "Retrieving governance relationships..." "INFO"
$relationships = @()
try {
    $relationships = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships"
} catch {
    Write-Status "Failed to retrieve governance relationships: $($_.Exception.Message)" "ERROR"
}
Write-Status "Found $($relationships.Count) governance relationship(s)." "INFO"

# --- 3. Existing Partner Center GDAP relationships (for conflict cross-check) ---
$gdapRelationships = @()
if ($CheckGdapConflicts) {
    Write-Status "Retrieving Partner Center GDAP relationships for conflict cross-check..." "INFO"
    try {
        $gdapRelationships = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminRelationships"
    } catch {
        Write-Status "Could not retrieve GDAP relationships (this may not be a CSP partner tenant, or DelegatedAdminRelationship.Read.All is missing): $($_.Exception.Message)" "WARN"
    }
}

# --- 4. Per-relationship analysis ---
$relationshipResults = foreach ($rel in $relationships) {

    $ageDays = $null
    if ($rel.creationDateTime) {
        $ageDays = [math]::Round(((Get-Date) - [datetime]$rel.creationDateTime).TotalDays, 1)
    }

    switch ($rel.status) {
        "Pending" {
            if ($ageDays -ne $null -and $ageDays -ge $StalePendingDays) {
                $findings.Add([pscustomobject]@{
                    Flag = "RELATIONSHIP_PENDING"; Severity = "WARN"
                    Object = "$($rel.governingTenantName) -> $($rel.governedTenantName)"
                    Detail = "Relationship request has been Pending for $ageDays day(s) (threshold: $StalePendingDays). Confirm the counterparty is checking the correct queue (Requests vs. Invitations) and that the requester holds Tenant Governance Administrator or Global Administrator."
                })
            }
        }
        { $_ -in @("Terminated", "Termination requested") } {
            $findings.Add([pscustomobject]@{
                Flag = "RELATIONSHIP_TERMINATED"; Severity = "INFO"
                Object = "$($rel.governingTenantName) -> $($rel.governedTenantName)"
                Detail = "Relationship status = '$($rel.status)'. If unexpected, remember a governed tenant can unilaterally terminate at any time — this is by design, not a fault. Confirm with the governed-tenant admin if access loss is business-impacting."
            })
        }
        "Active" {
            # Check delegated group membership
            $roleAssignments = $rel.policySnapshot.delegatedAdministrationRoleAssignments
            foreach ($ra in $roleAssignments) {
                if ($ra.group -and $ra.group.id) {
                    try {
                        $members = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/v1.0/groups/$($ra.group.id)/members"
                        if (-not $members -or $members.Count -eq 0) {
                            $findings.Add([pscustomobject]@{
                                Flag = "DELEGATED_GROUP_EMPTY"; Severity = "CRITICAL"
                                Object = "$($rel.governingTenantName) -> $($rel.governedTenantName)"
                                Detail = "Delegated administration security group '$($ra.group.id)' has zero members. Relationship is Active but nobody can use the access it grants. Add the intended admin(s) to this group in the governing tenant."
                            })
                        }
                    } catch {
                        Write-Status "  Could not read membership for group $($ra.group.id): $($_.Exception.Message)" "WARN"
                    }
                }
            }
        }
    }

    # GDAP conflict cross-check
    if ($CheckGdapConflicts -and $gdapRelationships) {
        $conflict = $gdapRelationships | Where-Object {
            $_.customer.tenantId -eq $rel.governedTenantId -or $_.customer.tenantId -eq $rel.governingTenantId
        }
        if ($conflict) {
            $findings.Add([pscustomobject]@{
                Flag = "GDAP_CONFLICT"; Severity = "CRITICAL"
                Object = "$($rel.governingTenantName) <-> $($rel.governedTenantName)"
                Detail = "An active Partner Center GDAP relationship exists for this same tenant pair (GDAP relationship '$($conflict.displayName)', status '$($conflict.status)'). Tenant Governance and Partner Center GDAP cannot coexist between the same two tenants — one must be retired before the other is fully usable."
            })
        }
    }

    [pscustomobject]@{
        GoverningTenant = $rel.governingTenantName
        GovernedTenant  = $rel.governedTenantName
        Status          = $rel.status
        AgeDays         = $ageDays
        RelationshipId  = $rel.id
    }
}

$relationshipResults | Export-Csv "$OutputPath\governance_relationships.csv" -NoTypeInformation

# --- 5. Configuration monitor quota/staleness check ---
Write-Status "Checking configuration monitor quota usage..." "INFO"
$monitors = @()
try {
    $monitors = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/directory/configurationManagement/configurationMonitors"
} catch {
    Write-Status "Could not retrieve configuration monitors (feature may not be in use in this tenant): $($_.Exception.Message)" "INFO"
}

$totalResourceInstances = 0
$monitorResults = foreach ($mon in $monitors) {
    $resourceCount = @($mon.baseline.resources).Count
    $totalResourceInstances += $resourceCount

    if ($resourceCount -ge 180) {
        $findings.Add([pscustomobject]@{
            Flag = "MONITOR_OVER_BASELINE_LIMIT"; Severity = "WARN"
            Object = $mon.displayName
            Detail = "Baseline has $resourceCount resource instances (limit: 200/baseline). Approaching the per-baseline ceiling — plan to split or consolidate before hitting the hard limit."
        })
    }

    [pscustomobject]@{
        MonitorName    = $mon.displayName
        State          = $mon.state
        ResourceCount  = $resourceCount
    }
}

if ($totalResourceInstances -ge 720) {
    $findings.Add([pscustomobject]@{
        Flag = "MONITOR_QUOTA_RISK"; Severity = "WARN"
        Object = "(tenant-wide)"
        Detail = "Total resource instances across all monitors = $totalResourceInstances (tenant daily limit: 800). Approaching the ceiling — new monitor/snapshot job creation will start failing outright once the limit is reached."
    })
}

if ($monitorResults) {
    $monitorResults | Export-Csv "$OutputPath\configuration_monitors.csv" -NoTypeInformation
}

$findings | Export-Csv "$OutputPath\findings.csv" -NoTypeInformation

# --- Summary ---
Write-Host ""
Write-Status "=== Tenant Governance Posture Summary ===" "INFO"
$critical = @($findings | Where-Object Severity -eq "CRITICAL").Count
$warn     = @($findings | Where-Object Severity -eq "WARN").Count
$info     = @($findings | Where-Object Severity -eq "INFO").Count

Write-Status "Governance relationships found: $($relationships.Count)" "INFO"
Write-Status "Critical findings (blocks access or creation outright): $critical" $(if ($critical -gt 0) { "ERROR" } else { "OK" })
Write-Status "Warnings (drift/quota/staleness risk): $warn" $(if ($warn -gt 0) { "WARN" } else { "OK" })
Write-Status "Informational findings: $info" "INFO"
Write-Status "Reports written to: $OutputPath" "INFO"

if ($critical -eq 0 -and $warn -eq 0) {
    Write-Status "Tenant Governance posture looks healthy across all checked dimensions." "OK"
}
