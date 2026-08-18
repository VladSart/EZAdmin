<#
.SYNOPSIS
    Audits a Microsoft 365 tenant's governance posture around the Microsoft 365 Admin agent:
    who holds the two roles that actually govern it (Global Administrator, AI Administrator),
    who holds the broader set of roles the agent commonly reflects on behalf of admins, whether
    Copilot/Agent 365 licensing is present, and an explicit list of what this script cannot read.

.DESCRIPTION
    The Microsoft 365 Admin agent has no standing privilege of its own — every action it can
    take is a mirror of the signed-in admin's existing Microsoft Entra role-based access control
    (RBAC) assignments, and Registry governance actions (block/scope/approve/assign owner) for
    this agent (and every other agent in the tenant) are restricted to Global Administrator and
    AI Administrator specifically. This means the single most useful thing a PowerShell audit
    CAN do here is inventory who holds the roles that matter, since there is no dedicated
    Graph/PowerShell API to read the agent's own Registry block/scope state, its usage
    analytics, or the SMB Teams-surface rollout eligibility for this tenant.

    This script covers:
      - Global Administrator and AI Administrator role holders (Registry governance authority
        for this and every other agent), flagging both an EXCESSIVE Global Administrator count
        (standard least-privilege concern, independent of this agent) and a ZERO AI Administrator
        count (a concentration risk specific to agent governance — if nobody holds AI
        Administrator, only Global Administrators can govern any agent in the tenant, forcing
        every Registry action through the highest-privilege role available)
      - Role holder counts for the other roles most commonly reflected by Admin-Agent task
        categories (User Administrator, Teams Administrator, SharePoint Administrator,
        Exchange Administrator, License Administrator, Groups Administrator) purely as
        informational context — this script draws no conclusion about whether these counts are
        appropriate, since that depends entirely on org size and structure
      - Whether Copilot/Agent 365 licensing SKUs are present in the tenant (informational only —
        the Admin agent itself requires no such license; this context is provided because a
        tenant with NO Copilot licensing at all will have no other agents governed by the same
        Registry the Admin agent uses)
      - An explicit "Known Gap" phase enumerating every governance/rollout signal this script
        cannot read via PowerShell or Graph, so a reviewer knows to check these manually rather
        than assuming a clean report means full coverage

    This script does NOT cover:
      - Agent Registry block/scope state for the Microsoft 365 Admin agent specifically — no
        Graph/PowerShell read API exists for this as of this script's writing; must be checked
        manually in the Microsoft 365 admin center (Agents > Registry)
      - Microsoft 365 Admin agent usage analytics, active-user counts, or per-admin interaction
        history — no read API exists for this either
      - SMB Teams-surface rollout eligibility (tenant qualifies for the ~300-user-ceiling
        Teams-embedded experience) — this is a Microsoft-side rollout-ring determination with no
        tenant-readable flag
      - General agent lifecycle governance for OTHER agents in the tenant (Copilot Studio, Agent
        Builder, SharePoint, Foundry) — see M365/Copilot/AgentGovernance's scripts for that
        broader Registry-wide audit surface, if one exists; this script is scoped to the roles
        that gate the Admin agent specifically

.PARAMETER TenantName
    Friendly label for the tenant being audited, used only in console output and the exported
    report filename. Does not affect connection targeting.

.PARAMETER GlobalAdminWarningThreshold
    Flag a WARN finding if the number of active Global Administrator holders exceeds this value.
    Defaults to 5, consistent with common least-privilege guidance for this role.

.PARAMETER OutputPath
    Directory to write the CSV report to. Defaults to the current directory.

.EXAMPLE
    .\Get-AdminAgentGovernanceAudit.ps1 -TenantName "Contoso"

    Runs a full audit against the currently connected Graph session and writes a timestamped
    CSV report to the current directory.

.EXAMPLE
    .\Get-AdminAgentGovernanceAudit.ps1 -TenantName "Contoso" -GlobalAdminWarningThreshold 3

    Runs the audit with a stricter Global Administrator count threshold for a smaller tenant.

.NOTES
    Requires: Microsoft Graph PowerShell SDK (Microsoft.Graph.Authentication,
    Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users modules) connected via
    Connect-MgGraph with at minimum RoleManagement.Read.Directory, Directory.Read.All, and
    Organization.Read.All scopes. This script does not establish that connection itself, since
    credential/MFA handling should remain under the operator's control.

    Written for Windows PowerShell 5.1 compatibility (no ??/?. operators) per this repo's usual
    scripting convention.

    Read-only. No role assignments, licenses, or tenant settings are created, modified, or
    deleted by this script.

    Role template IDs used below are Microsoft's documented, stable built-in role template IDs
    (Microsoft Entra built-in roles reference) — Global Administrator:
    62e90394-69f5-4237-9190-012177145e10, AI Administrator: d2562ede-74db-457e-a7b6-544e236ebb61.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantName,

    [int]$GlobalAdminWarningThreshold = 5,

    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[pscustomobject]

function Add-Finding {
    param(
        [string]$Category,
        [string]$Object,
        [string]$Status,
        [string]$Detail
    )
    $findings.Add([pscustomobject]@{
        Category = $Category
        Object   = $Object
        Status   = $Status
        Detail   = $Detail
    })
}

# Documented, stable Microsoft Entra built-in role template IDs.
$RoleTemplateIds = @{
    "Global Administrator"       = "62e90394-69f5-4237-9190-012177145e10"
    "AI Administrator"           = "d2562ede-74db-457e-a7b6-544e236ebb61"
    "User Administrator"         = "fe930be7-5e62-47db-91af-98c3a49a38b1"
    "Teams Administrator"        = "69091246-20e8-4a56-aa4d-066075b2a7a8"
    "SharePoint Administrator"   = "f28a1f50-f6e7-4571-818b-6a12f2af6b6c"
    "Exchange Administrator"     = "29232cdf-9323-42fd-ade2-1d097af3e4de"
    "License Administrator"      = "4d6ac14f-3453-41d0-bef9-a3e0c569773a"
    "Groups Administrator"       = "fdd7a751-b60b-444a-984c-02652fe8fa1c"
}

Write-Status "=== Microsoft 365 Admin Agent Governance Audit: $TenantName ===" "INFO"

# ---------------------------------------------------------------------------
# Phase 1: Preflight — Graph session check
# ---------------------------------------------------------------------------
Write-Status "Phase 1: Preflight checks" "INFO"

$graphConnected = $false
try {
    $context = Get-MgContext -ErrorAction Stop
    if ($null -eq $context) {
        throw "No context returned."
    }
    $graphConnected = $true
    Write-Status "Microsoft Graph session active as $($context.Account) — OK" "OK"
    Add-Finding -Category "Preflight" -Object "Graph session" -Status "OK" -Detail "Connected as $($context.Account)."

    $requiredScopes = @("RoleManagement.Read.Directory", "Directory.Read.All")
    $missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes }
    if ($missingScopes.Count -gt 0) {
        Write-Status "Missing recommended scope(s): $($missingScopes -join ', '). Some checks below may fail or return partial data." "WARN"
        Add-Finding -Category "Preflight" -Object "Graph scopes" -Status "WARN" -Detail "Missing: $($missingScopes -join ', ')"
    }
}
catch {
    Write-Status "No active Microsoft Graph session. Run Connect-MgGraph -Scopes 'RoleManagement.Read.Directory','Directory.Read.All','Organization.Read.All' first. Aborting." "ERROR"
    Add-Finding -Category "Preflight" -Object "Graph session" -Status "FAIL" -Detail "Not connected — Connect-MgGraph required."
}

Write-Status "REMINDER: Agent Registry block/scope state for the Microsoft 365 Admin agent has NO Graph/PowerShell read API. This script cannot verify it — check manually in the M365 admin center." "WARN"
Add-Finding -Category "Preflight" -Object "Agent Registry state" -Status "LIMITED" `
    -Detail "No Graph/PowerShell API exists to read whether the Microsoft 365 Admin agent is Blocked, Scoped, or Unrestricted. Verify manually: admin.cloud.microsoft > Agents > Registry > Microsoft 365 Admin."

# ---------------------------------------------------------------------------
# Phase 2: Registry-governance role holders (Global Administrator, AI Administrator)
# ---------------------------------------------------------------------------
if ($graphConnected) {
    Write-Status "Phase 2: Registry-governance role holders" "INFO"

    foreach ($roleName in @("Global Administrator", "AI Administrator")) {
        try {
            $templateId = $RoleTemplateIds[$roleName]
            $assignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$templateId'" -ExpandProperty principal -ErrorAction Stop
            $count = $assignments.Count

            if ($roleName -eq "Global Administrator") {
                if ($count -gt $GlobalAdminWarningThreshold) {
                    Write-Status "$roleName holders: $count (exceeds warning threshold of $GlobalAdminWarningThreshold)." "WARN"
                    Add-Finding -Category "RegistryGovernanceRole" -Object $roleName -Status "WARN" `
                        -Detail "$count active holders, exceeds threshold of $GlobalAdminWarningThreshold. Standard least-privilege concern independent of the Admin agent — every holder also has unrestricted Agent Registry governance authority for every agent in the tenant."
                }
                elseif ($count -eq 0) {
                    Write-Status "$roleName holders: 0 — this should not be possible in a functioning tenant; investigate immediately." "ERROR"
                    Add-Finding -Category "RegistryGovernanceRole" -Object $roleName -Status "ERROR" -Detail "0 active holders found — verify this reflects reality, not a query/permission issue."
                }
                else {
                    Write-Status "$roleName holders: $count — within threshold — OK" "OK"
                    Add-Finding -Category "RegistryGovernanceRole" -Object $roleName -Status "OK" -Detail "$count active holders, within threshold of $GlobalAdminWarningThreshold."
                }
            }
            else {
                # AI Administrator
                if ($count -eq 0) {
                    Write-Status "$roleName holders: 0 — nobody outside Global Administrator can govern ANY agent (block/scope/approve/assign owner) in this tenant, including the Admin agent itself." "WARN"
                    Add-Finding -Category "RegistryGovernanceRole" -Object $roleName -Status "WARN" `
                        -Detail "0 active holders. Every Registry governance action for every agent in the tenant is forced through Global Administrator, the highest-privilege role available — consider delegating this narrower role instead."
                }
                else {
                    Write-Status "$roleName holders: $count — OK" "OK"
                    Add-Finding -Category "RegistryGovernanceRole" -Object $roleName -Status "OK" -Detail "$count active holders."
                }
            }

            foreach ($a in $assignments) {
                $principalName = "Unknown"
                if ($a.Principal -and $a.Principal.AdditionalProperties -and $a.Principal.AdditionalProperties.ContainsKey('displayName')) {
                    $principalName = $a.Principal.AdditionalProperties['displayName']
                }
                Add-Finding -Category "RoleHolderDetail" -Object "$roleName : $principalName" -Status "INFO" -Detail "Active assignment (not PIM-eligible-only; run a separate PIM eligibility check if PIM is in use)."
            }
        }
        catch {
            Write-Status "Unable to query role '$roleName': $($_.Exception.Message)" "ERROR"
            Add-Finding -Category "RegistryGovernanceRole" -Object $roleName -Status "ERROR" -Detail $_.Exception.Message
        }
    }
}
else {
    Write-Status "Phase 2 skipped — no Graph session." "WARN"
    Add-Finding -Category "RegistryGovernanceRole" -Object "N/A" -Status "SKIPPED" -Detail "No active Graph session."
}

# ---------------------------------------------------------------------------
# Phase 3: Task-category role holders (informational context only)
# ---------------------------------------------------------------------------
if ($graphConnected) {
    Write-Status "Phase 3: Task-category role holder counts (informational — no pass/fail judgment)" "INFO"

    foreach ($roleName in @("User Administrator", "Teams Administrator", "SharePoint Administrator", "Exchange Administrator", "License Administrator", "Groups Administrator")) {
        try {
            $templateId = $RoleTemplateIds[$roleName]
            $assignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$templateId'" -ErrorAction Stop
            $count = $assignments.Count
            Write-Status "  $roleName holders: $count" "INFO"
            Add-Finding -Category "TaskCategoryRole" -Object $roleName -Status "INFO" `
                -Detail "$count active holders. This role gates the corresponding Admin-Agent task category for anyone who holds it; count provided as context, not a pass/fail judgment — appropriate staffing varies by org size."
        }
        catch {
            Write-Status "Unable to query role '$roleName': $($_.Exception.Message)" "ERROR"
            Add-Finding -Category "TaskCategoryRole" -Object $roleName -Status "ERROR" -Detail $_.Exception.Message
        }
    }
}
else {
    Write-Status "Phase 3 skipped — no Graph session." "WARN"
    Add-Finding -Category "TaskCategoryRole" -Object "N/A" -Status "SKIPPED" -Detail "No active Graph session."
}

# ---------------------------------------------------------------------------
# Phase 4: Copilot / Agent 365 licensing presence (informational)
# ---------------------------------------------------------------------------
if ($graphConnected) {
    Write-Status "Phase 4: Copilot / Agent 365 licensing presence (informational — Admin agent itself needs none)" "INFO"

    try {
        $skus = Get-MgSubscribedSku -ErrorAction Stop | Where-Object { $_.SkuPartNumber -match "COPILOT|AGENT365|SPE_E7" }
        if ($skus.Count -eq 0) {
            Write-Status "No Copilot/Agent 365/E7 SKUs found in tenant. The Admin agent itself still works normally — this only means no OTHER Copilot-dependent agents/features are licensed." "INFO"
            Add-Finding -Category "Licensing" -Object "Copilot/Agent365 SKUs" -Status "INFO" -Detail "None found. Does not affect Admin agent availability — it requires no additional license."
        }
        else {
            foreach ($sku in $skus) {
                Write-Status "  SKU: $($sku.SkuPartNumber) — Consumed: $($sku.ConsumedUnits) / Prepaid: $($sku.PrepaidUnits.Enabled)" "INFO"
                Add-Finding -Category "Licensing" -Object $sku.SkuPartNumber -Status "INFO" `
                    -Detail "Consumed=$($sku.ConsumedUnits), PrepaidEnabled=$($sku.PrepaidUnits.Enabled). Informational context only."
            }
        }
    }
    catch {
        Write-Status "Unable to query subscribed SKUs: $($_.Exception.Message)" "ERROR"
        Add-Finding -Category "Licensing" -Object "Get-MgSubscribedSku" -Status "ERROR" -Detail $_.Exception.Message
    }
}
else {
    Write-Status "Phase 4 skipped — no Graph session." "WARN"
    Add-Finding -Category "Licensing" -Object "N/A" -Status "SKIPPED" -Detail "No active Graph session."
}

# ---------------------------------------------------------------------------
# Phase 5: Explicit governance/coverage gaps this script cannot audit
# ---------------------------------------------------------------------------
Write-Status "Phase 5: Known governance gaps not covered by this script (reported explicitly, not silently omitted)" "INFO"

Add-Finding -Category "KnownGap" -Object "Agent Registry block/scope state (this agent)" -Status "LIMITED" `
    -Detail "No Graph/PowerShell read API. Verify manually: admin.cloud.microsoft > Agents > Registry > Microsoft 365 Admin > confirm Blocked/Scoped/Unrestricted state and, if scoped, the exact user/group scope."
Add-Finding -Category "KnownGap" -Object "Microsoft 365 Admin agent usage analytics" -Status "LIMITED" `
    -Detail "No read API for active-user counts, run-time hours, or per-admin interaction history specific to this agent. Use the Agent overview dashboard in the M365 admin center manually."
Add-Finding -Category "KnownGap" -Object "SMB Teams-surface rollout eligibility" -Status "LIMITED" `
    -Detail "Whether this specific tenant currently qualifies for the ~300-user-ceiling, Teams-embedded surface is a Microsoft-side rollout-ring/eligibility determination with no tenant-readable flag. Confirm via direct observation in the Teams desktop client and current Message Center posts, not this script."
Add-Finding -Category "KnownGap" -Object "PIM-eligible (vs. active) role assignments" -Status "LIMITED" `
    -Detail "This script queries ACTIVE role assignments only via Get-MgRoleManagementDirectoryRoleAssignment. If Privileged Identity Management (PIM) is in use, eligible-but-not-activated assignments for Global Administrator/AI Administrator are not reflected here and require a separate PIM-specific query (Get-MgRoleManagementDirectoryRoleEligibilitySchedule)."
Add-Finding -Category "KnownGap" -Object "Write-action confirmation/audit correlation" -Status "INFO" `
    -Detail "By design, not a script limitation: actions taken through the Admin agent are logged in the underlying workload's own audit trail (M365 admin center, Entra, or Teams admin audit log) with no separate agent-specific log to query — search the relevant workload log directly for a specific action."

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "=== Audit Summary ===" "INFO"
$findings | Format-Table -AutoSize

$reportFile = Join-Path -Path $OutputPath -ChildPath "AdminAgentGovernanceAudit-$TenantName-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$findings | Export-Csv -Path $reportFile -NoTypeInformation
Write-Status "Report exported to: $reportFile" "OK"

$warnCount = ($findings | Where-Object { $_.Status -in @("WARN", "ERROR") }).Count
if ($warnCount -gt 0) {
    Write-Status "$warnCount finding(s) need attention — review the report, and remember to separately verify Agent Registry state and Teams-surface eligibility manually, since this script cannot read either." "WARN"
}
else {
    Write-Status "No blocking findings detected in the Graph-readable role data — still verify Agent Registry state, usage analytics, and Teams-surface eligibility manually, since this script cannot read any of them." "OK"
}
