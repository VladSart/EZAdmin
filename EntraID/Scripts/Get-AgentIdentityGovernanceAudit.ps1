<#
.SYNOPSIS
    Read-only tenant-wide governance audit for Microsoft Entra Agent ID objects — ownership/
    sponsorship hygiene, sponsor group-type validity, privileged role assignment overlap
    (AI Administrator vs. Agent ID Administrator), and access package agent-identity scope gaps.

.DESCRIPTION
    Companion to EntraID/Troubleshooting/AgentID-A.md and AgentID-B.md. Uses Microsoft Graph
    BETA endpoints directly via Invoke-MgGraphRequest, since dedicated stable SDK cmdlets for
    Agent ID objects do not yet exist as of this writing (the feature reached GA in April 2026
    but its Graph surface is still documented under graph-rest-beta). Endpoint shapes may change
    before v1.0 promotion — re-verify against current Microsoft Learn documentation periodically.

    Reports:
    - AGENT_IDENTITY_NO_OWNER — agent identity or blueprint with zero owners (technical
      administration gap; owners are optional but their total absence is a hygiene finding).
    - AGENT_IDENTITY_SINGLE_OWNER — exactly one owner (succession risk: ownership does NOT
      auto-transfer on that owner's departure, unlike sponsorship — see AgentID-B.md Fix 6).
    - AGENT_IDENTITY_NO_SPONSOR — agent identity or blueprint with zero sponsors. Creation-time
      validation is supposed to make this impossible except for blueprint principals (which are
      exempt); a hit here indicates drift (e.g., the sole sponsor was later removed) and should
      be treated as a real finding, not a false positive.
    - SPONSOR_INVALID_GROUP_TYPE — a group assigned as sponsor that is role-assignable or an
      assigned-membership security group — neither is a supported sponsor type per Microsoft's
      documented rules; the assignment may appear to exist in the directory while silently not
      functioning as a sponsor.
    - AGENT_USER_NO_MANAGER — an agent's paired user account with no manager set, informational
      (managers are optional; flagged for completeness in access-request routing scenarios).
    - PRIVILEGED_ROLE_OVERLAP — principals holding BOTH AI Administrator and Agent ID
      Administrator, a redundant privileged-role assignment worth a least-privilege review
      (see AgentID-A.md Playbook 2).
    - AI_ADMINISTRATOR_HOLDER / AGENT_ID_ADMINISTRATOR_HOLDER / AGENT_ID_DEVELOPER_HOLDER /
      AGENT_REGISTRY_ADMINISTRATOR_HOLDER — informational role-membership inventory for
      periodic access review, since all four are either privileged or agent-identity-scoped
      administrative roles.
    - ACCESS_PACKAGE_AGENT_SCOPE_GAP — an access package assignment policy whose requestor
      settings do not include agent identities at all (best-effort based on the properties
      Microsoft Graph beta currently exposes for assignment policies; a policy that scopes
      to specific users/groups by design, rather than "all agents," will also show here and
      should be reviewed rather than treated as automatically wrong).

    Does NOT check: Conditional Access policy assignment/effectiveness for agents (requires a
    separate CA policy read plus simulation, out of scope for an identity-hygiene audit),
    Identity Protection agent risk scores (a distinct, separately-licensed detection surface —
    query Identity Protection's own risk APIs for that), M365 admin center Agent Registry state
    (a different product surface entirely — see AgentID-A.md Playbook 4 for the reconciliation
    process and cross-reference against that system's own export), or whether a third-party
    (non-Microsoft-platform) agent has been integrated via the Auth SDK sidecar or workload
    identity federation (not observable from this tenant's Graph data alone in the general case).
    These gaps are reported explicitly in the summary output rather than silently omitted.

    Performs NO write operations — no create, update, delete, disable, or role-assignment
    changes of any kind. Read-only audit only.

.PARAMETER ExportPath
    Directory to write CSV reports to. Default: current directory.

.PARAMETER IncludeAccessPackageCheck
    Switch. When set, also audits Entitlement Management access package assignment policies
    for agent-identity requestor scope gaps. Off by default because it requires an additional,
    potentially large set of Graph calls (one per access package) on tenants with many packages.

.EXAMPLE
    .\Get-AgentIdentityGovernanceAudit.ps1
    Runs the ownership/sponsorship/role-overlap audit and exports CSVs to the current directory.

.EXAMPLE
    .\Get-AgentIdentityGovernanceAudit.ps1 -IncludeAccessPackageCheck -ExportPath "C:\Reports"
    Runs the full audit including the access package agent-scope check.

.NOTES
    Requires: Microsoft.Graph.Authentication module (Invoke-MgGraphRequest).
    Requires scopes: Directory.Read.All (or AgentIdentity.Read.All if/when generally available
    as a narrower scope), RoleManagement.Read.Directory, EntitlementManagement.Read.All
    (only if -IncludeAccessPackageCheck is used), Group.Read.All (for sponsor group-type checks).
    Run as: Any account/service principal holding the scopes above — no elevated local rights
    needed, this is a Graph-only read operation. Does NOT require Agent ID Administrator or
    AI Administrator — read scopes are sufficient.
    Safe: Yes — entirely read-only, makes no directory, role, or access-package changes.
    Written for Windows PowerShell 5.1 compatibility (no PS7-only syntax used).
    Graph endpoints used are BETA — re-verify against https://learn.microsoft.com/en-us/graph/api/resources/agentidentity
    before relying on this script long-term, as beta surfaces can change without notice.
#>

#requires -Modules Microsoft.Graph.Authentication

[CmdletBinding()]
param(
    [string]$ExportPath = (Get-Location).Path,
    [switch]$IncludeAccessPackageCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Role template IDs — verified directly against the live Microsoft Entra
# built-in roles reference (permissions-reference) rather than recalled.
# ---------------------------------------------------------------------------
$RoleTemplateIds = @{
    "Agent ID Administrator"        = "db506228-d27e-4b7d-95e5-295956d6615f"
    "Agent ID Developer"            = "adb2368d-a9be-41b5-8667-d96778e081b0"
    "Agent Registry Administrator"  = "6b942400-691f-4bf0-9d12-d8a254a2baf5"
}
# AI Administrator's template ID (verified directly against the live Microsoft Entra
# built-in roles reference, same pass as the three roles above): d2562ede-74db-457e-a7b6-544e236ebb61

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
try {
    $context = Get-MgContext
    if (-not $context) {
        throw "No active Microsoft Graph session. Run Connect-MgGraph with Directory.Read.All, RoleManagement.Read.Directory, Group.Read.All (and EntitlementManagement.Read.All if using -IncludeAccessPackageCheck) before running this script."
    }
    Write-Status "Connected to tenant $($context.TenantId) as $($context.Account)" "OK"
}
catch {
    Write-Status "Preflight failed: $_" "ERROR"
    throw
}

if (-not (Test-Path -Path $ExportPath)) {
    Write-Status "Export path '$ExportPath' does not exist — creating it." "WARN"
    New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
}

$findings = New-Object System.Collections.Generic.List[Object]

function Add-Finding {
    param(
        [string]$FindingType,
        [string]$ObjectType,
        [string]$ObjectId,
        [string]$DisplayName,
        [string]$Detail
    )
    $findings.Add([PSCustomObject]@{
        FindingType  = $FindingType
        ObjectType   = $ObjectType
        ObjectId     = $ObjectId
        DisplayName  = $DisplayName
        Detail       = $Detail
        Timestamp    = (Get-Date).ToString("o")
    })
}

# ---------------------------------------------------------------------------
# Helper: page through a Graph beta collection endpoint
# ---------------------------------------------------------------------------
function Get-GraphBetaCollection {
    param([string]$Uri)
    $results = New-Object System.Collections.Generic.List[Object]
    $nextUri = $Uri
    while ($nextUri) {
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri
        }
        catch {
            Write-Status "Graph call failed for '$nextUri': $_" "WARN"
            break
        }
        if ($response.value) { $response.value | ForEach-Object { $results.Add($_) } }
        $nextUri = $response.'@odata.nextLink'
    }
    return $results
}

# ---------------------------------------------------------------------------
# Step 1 — Enumerate agent identities and agent identity blueprints
# ---------------------------------------------------------------------------
Write-Status "Enumerating agent identities..." "INFO"
$agentIdentities = Get-GraphBetaCollection -Uri "https://graph.microsoft.com/beta/directory/agentIdentities"
Write-Status "Found $($agentIdentities.Count) agent identities." "INFO"

Write-Status "Enumerating agent identity blueprints..." "INFO"
$agentBlueprints = Get-GraphBetaCollection -Uri "https://graph.microsoft.com/beta/directory/agentIdentityBlueprints"
Write-Status "Found $($agentBlueprints.Count) agent identity blueprints." "INFO"

Write-Status "Enumerating agent users..." "INFO"
$agentUsers = Get-GraphBetaCollection -Uri "https://graph.microsoft.com/beta/directory/agentUsers"
Write-Status "Found $($agentUsers.Count) agent user accounts." "INFO"

# Note: agent identity blueprint principals are intentionally NOT audited for
# sponsor/owner gaps below — they are documented as exempt from the sponsor-
# required-at-creation rule, so a zero-sponsor blueprint principal is expected
# behavior, not a finding. They are still worth inventorying separately if a
# multitenant-agent census is needed, but that is out of scope for this pass.

# Validate group sponsor type (Dynamic security/M365 or Assigned-M365 only)
function Test-ValidSponsorGroup {
    param($Group)
    if (-not $Group) { return $true }
    $isRoleAssignable = [bool]($Group.isAssignableToRole)
    $isDynamic        = ($Group.groupTypes -contains "DynamicMembership")
    $isM365           = ($Group.groupTypes -contains "Unified")
    if ($isRoleAssignable) { return $false }
    if ($isDynamic) { return $true }               # Dynamic security or M365 — both allowed
    if ($isM365 -and -not $isDynamic) { return $true }   # Assigned M365 — allowed
    # Remaining case: assigned-membership security group — not allowed
    return $false
}

# ---------------------------------------------------------------------------
# Step 2 — Owner/Sponsor hygiene for agent identities + blueprints
# ---------------------------------------------------------------------------
$objectsToAudit = @()
$agentIdentities | ForEach-Object { $objectsToAudit += [PSCustomObject]@{ Type = "AgentIdentity"; Object = $_ } }
$agentBlueprints  | ForEach-Object { $objectsToAudit += [PSCustomObject]@{ Type = "AgentIdentityBlueprint"; Object = $_ } }

Write-Status "Auditing ownership and sponsorship for $($objectsToAudit.Count) objects..." "INFO"
foreach ($entry in $objectsToAudit) {
    $obj = $entry.Object
    $type = $entry.Type
    $basePath = if ($type -eq "AgentIdentity") { "agentIdentities" } else { "agentIdentityBlueprints" }

    $owners = Get-GraphBetaCollection -Uri "https://graph.microsoft.com/beta/directory/$basePath/$($obj.id)/owners"
    $sponsors = Get-GraphBetaCollection -Uri "https://graph.microsoft.com/beta/directory/$basePath/$($obj.id)/sponsors"

    if ($owners.Count -eq 0) {
        Add-Finding -FindingType "AGENT_IDENTITY_NO_OWNER" -ObjectType $type -ObjectId $obj.id `
            -DisplayName $obj.displayName -Detail "Zero owners assigned — no technical administrator can modify credentials/config without Agent ID Administrator escalation."
    }
    elseif ($owners.Count -eq 1) {
        Add-Finding -FindingType "AGENT_IDENTITY_SINGLE_OWNER" -ObjectType $type -ObjectId $obj.id `
            -DisplayName $obj.displayName -Detail "Exactly one owner ('$($owners[0].displayName)') — succession risk, ownership does not auto-transfer on departure."
    }

    if ($sponsors.Count -eq 0) {
        Add-Finding -FindingType "AGENT_IDENTITY_NO_SPONSOR" -ObjectType $type -ObjectId $obj.id `
            -DisplayName $obj.displayName -Detail "Zero sponsors — unexpected drift, since a sponsor is required at creation for this object type."
    }

    foreach ($sponsor in $sponsors) {
        if ($sponsor.'@odata.type' -like '*group*' -or $sponsor.groupTypes) {
            $groupDetail = $null
            try {
                $groupDetail = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$($sponsor.id)?`$select=displayName,groupTypes,isAssignableToRole,securityEnabled,mailEnabled"
            }
            catch {
                Write-Status "Could not resolve group details for sponsor '$($sponsor.id)' on $type '$($obj.displayName)': $_" "WARN"
                continue
            }
            if (-not (Test-ValidSponsorGroup -Group $groupDetail)) {
                Add-Finding -FindingType "SPONSOR_INVALID_GROUP_TYPE" -ObjectType $type -ObjectId $obj.id `
                    -DisplayName $obj.displayName -Detail "Sponsor group '$($groupDetail.displayName)' is role-assignable or an assigned-security group — not a supported sponsor type; may silently fail to function as a sponsor."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Step 3 — Agent user manager check
# ---------------------------------------------------------------------------
Write-Status "Auditing agent user manager assignment..." "INFO"
foreach ($agentUser in $agentUsers) {
    try {
        $manager = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$($agentUser.id)/manager" -ErrorAction Stop
    }
    catch {
        $manager = $null
    }
    if (-not $manager) {
        Add-Finding -FindingType "AGENT_USER_NO_MANAGER" -ObjectType "AgentUser" -ObjectId $agentUser.id `
            -DisplayName $agentUser.displayName -Detail "No manager set on this agent's paired user account — informational, affects manager-initiated access-request routing only."
    }
}

# ---------------------------------------------------------------------------
# Step 4 — Privileged role assignment inventory + overlap check
# ---------------------------------------------------------------------------
Write-Status "Auditing Agent ID role assignments..." "INFO"
$roleHolders = @{}
foreach ($roleName in $RoleTemplateIds.Keys) {
    $templateId = $RoleTemplateIds[$roleName]
    $assignments = Get-GraphBetaCollection -Uri "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '$templateId'&`$expand=principal"
    $roleHolders[$roleName] = $assignments
    foreach ($assignment in $assignments) {
        $principalName = if ($assignment.principal.displayName) { $assignment.principal.displayName } else { $assignment.principalId }
        $findingType = ($roleName.ToUpper() -replace ' ', '_') + "_HOLDER"
        Add-Finding -FindingType $findingType -ObjectType "RoleAssignment" -ObjectId $assignment.principalId `
            -DisplayName $principalName -Detail "Holds '$roleName' — periodic access review candidate."
    }
}

# Overlap check: Agent ID Administrator holders who are also flagged for AI Administrator.
# Both roles are documented to grant full agentIdentities/agentIdentityBlueprints/
# agentIdentityBlueprintPrincipals CRUD, so co-holding both is a redundant privileged
# assignment worth a least-privilege review (see AgentID-A.md Playbook 2).
$aiAdminTemplateId = "d2562ede-74db-457e-a7b6-544e236ebb61"
try {
    $aiAdminHolders = Get-GraphBetaCollection -Uri "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '$aiAdminTemplateId'&`$expand=principal"
    $agentIdAdminIds = $roleHolders["Agent ID Administrator"] | ForEach-Object { $_.principalId }
    foreach ($aiHolder in $aiAdminHolders) {
        if ($agentIdAdminIds -contains $aiHolder.principalId) {
            $principalName = if ($aiHolder.principal.displayName) { $aiHolder.principal.displayName } else { $aiHolder.principalId }
            Add-Finding -FindingType "PRIVILEGED_ROLE_OVERLAP" -ObjectType "RoleAssignment" -ObjectId $aiHolder.principalId `
                -DisplayName $principalName -Detail "Holds BOTH AI Administrator and Agent ID Administrator — redundant for agent-identity CRUD (both roles grant it); review for least-privilege consolidation per AgentID-A.md Playbook 2."
        }
    }
}
catch {
    Write-Status "AI Administrator overlap check skipped (role assignment lookup failed): $_" "WARN"
}

# ---------------------------------------------------------------------------
# Step 5 — Access package agent-identity scope check (optional)
# ---------------------------------------------------------------------------
if ($IncludeAccessPackageCheck) {
    Write-Status "Auditing access package assignment policies for agent-identity scope..." "INFO"
    $accessPackages = Get-GraphBetaCollection -Uri "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages"
    foreach ($package in $accessPackages) {
        $policies = Get-GraphBetaCollection -Uri "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages/$($package.id)/assignmentPolicies"
        foreach ($policy in $policies) {
            $requestorSettingsRaw = $policy.requestorSettings | ConvertTo-Json -Depth 5 -Compress
            $includesAgents = $requestorSettingsRaw -match "(?i)agent"
            if (-not $includesAgents) {
                Add-Finding -FindingType "ACCESS_PACKAGE_AGENT_SCOPE_GAP" -ObjectType "AccessPackagePolicy" -ObjectId $policy.id `
                    -DisplayName "$($package.displayName) / $($policy.displayName)" -Detail "Policy's requestorSettings do not appear to reference agent identities — confirm manually in the portal if this package is expected to serve agents; a policy intentionally scoped to specific named users/groups is not automatically wrong."
            }
        }
    }
}
else {
    Write-Status "Skipping access package scope check (-IncludeAccessPackageCheck not specified)." "INFO"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$exportFile = Join-Path -Path $ExportPath -ChildPath ("AgentIdentityGovernanceAudit_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$findings | Export-Csv -Path $exportFile -NoTypeInformation -Encoding UTF8
Write-Status "Exported $($findings.Count) findings to '$exportFile'." "OK"

$summary = $findings | Group-Object FindingType | Select-Object Name, Count | Sort-Object Count -Descending
Write-Status "=== Summary ===" "INFO"
$summary | ForEach-Object { Write-Status ("{0,-40} {1}" -f $_.Name, $_.Count) "INFO" }

Write-Status "=== Known Gaps (not covered by this script) ===" "WARN"
Write-Status "- Conditional Access policy assignment/effectiveness for agent identities (query CA policies + simulate separately)." "WARN"
Write-Status "- Identity Protection agent risk scores (separate detection surface, own licensing/API)." "WARN"
Write-Status "- M365 admin center Agent Registry state — Shadow agent risk, ownership shown there, publish/audience scope (see AgentID-A.md Playbook 4 for manual reconciliation)." "WARN"
Write-Status "- Third-party (non-Microsoft-platform) agent Auth SDK sidecar / workload identity federation integration status (not observable from this tenant's Agent ID Graph data alone)." "WARN"
