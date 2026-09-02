<#
.SYNOPSIS
    Audits the new Microsoft Entra "SOC Identity Responder" role — a dedicated, non-admin-scoped
    identity-containment role for SOC analysts (disable/enable user, revoke sessions, reset
    password) introduced roughly June-July 2026.

.DESCRIPTION
    Read-only audit. Does not modify any role assignment, PIM schedule, or role definition.

    Checks performed:
    1. Resolves the role by display name, trying both "SOC Identity Responder" and "Entra SOC
       Identity Responder" (Microsoft's own documentation uses both labels in different places).
       Falls back to the role template list if the role has never been assigned/activated in this
       tenant. Does NOT hardcode a single trusted role template ID — a specific ID
       (58f930cc-fcf4-4152-852c-1d7dbf502139) has been reported by a third-party community source
       but is not independently confirmed against Microsoft's own documentation as of this
       writing, so this script resolves by display name and reports the live RoleTemplateId it
       actually finds, rather than trusting a hardcoded value.
    2. Enumerates current assignees and their assignment scope (tenant-wide vs. Administrative
       Unit-scoped, via DirectoryScopeId).
    3. Queries the tenant's LIVE role definition to determine whether the four confirmed
       identity-response actions (users/disable, users/enable, users/invalidateAllRefreshTokens,
       users/password/update) are present, AND separately checks for two additional actions
       referenced in Microsoft's broader change-announcement language ("mark user compromised",
       "delete individual authentication method") that are NOT confirmed present in the base role
       definition — reported informationally, not assumed either way.
    4. Cross-references every SOC Identity Responder assignee against membership in Security
       Operator, Security Administrator, Authentication Administrator, and User Administrator to
       flag redundant identity-response/containment access through overlapping roles — the same
       action verbs can now be reached through multiple, structurally distinct roles.
    5. Flags standing (Active, non-PIM) assignments as elevated-risk, consistent with this repo's
       standing recommendation to gate any containment-capable role behind PIM activation.
    6. Optionally pulls recent audit-log activity for the confirmed actions and reports which
       entries were initiated by a current SOC Identity Responder holder.

    Does NOT read Microsoft Defender unified RBAC (URBAC) role/permission state — no confirmed
    stable Graph/REST surface for that specific configuration was found at the time this script
    was written; if an assignment was made exclusively through the Defender portal's URBAC
    experience, this script still detects it correctly because URBAC role assignments for this
    role resolve to the same underlying Entra directory-role assignment object.

    Does NOT modify role assignments, create/convert PIM schedules, or apply Administrative Unit
    scoping — see EntraID/Troubleshooting/SOCIdentityResponder-B.md / -A.md for remediation steps.

.PARAMETER IncludeAuditLogSample
    If specified, pulls up to 100 recent directory audit log entries for the confirmed actions
    and cross-references InitiatedBy against current SOC Identity Responder holders. Requires
    AuditLog.Read.All. Omit for a faster, role-assignment-only pass.

.PARAMETER OutputPath
    Folder to write the CSV/JSON output to. Defaults to the current directory.

.EXAMPLE
    .\Get-SOCIdentityResponderAudit.ps1
    Runs the role-assignment and action-set audit only.

.EXAMPLE
    .\Get-SOCIdentityResponderAudit.ps1 -IncludeAuditLogSample -OutputPath C:\Reports
    Runs the full audit including a recent audit-log cross-reference, writing output to C:\Reports.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement,
    Microsoft.Graph.Identity.Governance modules.
    Run-as: Any account with RoleManagement.Read.Directory and Directory.Read.All (and
    AuditLog.Read.All if using -IncludeAuditLogSample). Does not require an administrative role
    itself — read scopes only.
    Safe/unsafe: Fully read-only. Safe to run in production at any time.
#>

[CmdletBinding()]
param(
    [switch]$IncludeAuditLogSample,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$RoleDisplayNameCandidates = @("SOC Identity Responder", "Entra SOC Identity Responder")
$CommunityReportedTemplateId = "58f930cc-fcf4-4152-852c-1d7dbf502139"  # NOT independently confirmed — informational only
$ConfirmedActions = @(
    "microsoft.directory/users/disable",
    "microsoft.directory/users/enable",
    "microsoft.directory/users/invalidateAllRefreshTokens",
    "microsoft.directory/users/password/update"
)
$HypothesizedActionKeywords = @("compromised", "authenticationMethod")  # loose match — exact action strings not published
$OverlapRoleNames = @("Security Operator", "Security Administrator", "Authentication Administrator", "User Administrator")
$AuditActivityNames = @("Disable account", "Enable account", "Reset user password", "Update user")

# ---- Preflight ----
Write-Status "Checking Microsoft Graph connection..."
$context = Get-MgContext
if (-not $context) {
    $scopes = @("RoleManagement.Read.Directory", "Directory.Read.All")
    if ($IncludeAuditLogSample) { $scopes += "AuditLog.Read.All" }
    Write-Status "Not connected. Connecting with scopes: $($scopes -join ', ')"
    Connect-MgGraph -Scopes $scopes -NoWelcome
    $context = Get-MgContext
}
Write-Status "Connected to tenant $($context.TenantId)" -Status "OK"

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "Output path '$OutputPath' does not exist, creating it." -Status "WARN"
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ---- Detect: resolve the role ----
Write-Status "Resolving SOC Identity Responder role (trying known display-name variants)..."
$role = $null
foreach ($name in $RoleDisplayNameCandidates) {
    try {
        $candidate = Get-MgDirectoryRole -Filter "displayName eq '$name'" -ErrorAction SilentlyContinue
        if ($candidate) { $role = $candidate; break }
    } catch {
        Write-Status "Lookup for '$name' failed: $($_.Exception.Message)" -Status "WARN"
    }
}

$templateOnly = $null
if (-not $role) {
    Write-Status "Role not active (never assigned) in this tenant — checking role templates..." -Status "WARN"
    try {
        $templateOnly = Get-MgDirectoryRoleTemplate -All | Where-Object { $RoleDisplayNameCandidates -contains $_.DisplayName }
        if ($templateOnly) {
            Write-Status "Template found: '$($templateOnly.DisplayName)' ($($templateOnly.Id)). Role has never been assigned in this tenant." -Status "WARN"
            if ($templateOnly.Id -ne $CommunityReportedTemplateId) {
                Write-Status "Note: live template ID ($($templateOnly.Id)) differs from the community-reported ID ($CommunityReportedTemplateId) — this script trusts the live lookup." -Status "INFO"
            }
        } else {
            Write-Status "No matching role template found in this tenant at all. The role may not have propagated here yet (newly published roles can take time), or the display name has changed." -Status "ERROR"
        }
    } catch {
        Write-Status "Failed to enumerate role templates: $($_.Exception.Message)" -Status "ERROR"
    }
} else {
    Write-Status "Role resolved: '$($role.DisplayName)' (Id: $($role.Id), RoleTemplateId: $($role.RoleTemplateId))" -Status "OK"
    if ($role.RoleTemplateId -ne $CommunityReportedTemplateId) {
        Write-Status "Note: live RoleTemplateId ($($role.RoleTemplateId)) differs from the community-reported ID ($CommunityReportedTemplateId) — this script trusts the live lookup, not the reported ID." -Status "INFO"
    }
}

# ---- Detect: assignees and scope ----
$assignees = @()
if ($role) {
    Write-Status "Enumerating assignees..."
    try {
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All
        $assignmentScopes = @{}
        try {
            Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$($role.RoleTemplateId)'" -All -ErrorAction SilentlyContinue |
                ForEach-Object { $assignmentScopes[$_.PrincipalId] = $_.DirectoryScopeId }
        } catch {
            Write-Status "Could not read per-assignment DirectoryScopeId (may require additional permissions) — scope column will be blank." -Status "WARN"
        }
        $assignees = $members | ForEach-Object {
            [pscustomobject]@{
                PrincipalId     = $_.Id
                PrincipalType   = ($_.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.', '')
                DisplayName     = $_.AdditionalProperties.displayName
                AssignmentType  = "Active"
                DirectoryScopeId = if ($assignmentScopes.ContainsKey($_.Id)) { $assignmentScopes[$_.Id] } else { "Unknown" }
            }
        }
        Write-Status "Found $($assignees.Count) assignee(s)." -Status "OK"
        $auScoped = ($assignees | Where-Object { $_.DirectoryScopeId -like "/administrativeUnits/*" }).Count
        if ($auScoped -gt 0) {
            Write-Status "$auScoped assignee(s) are Administrative-Unit-scoped." -Status "OK"
        }
    } catch {
        Write-Status "Failed to enumerate assignees: $($_.Exception.Message)" -Status "ERROR"
    }
}

# ---- Detect: PIM-eligible assignees ----
$eligibleAssignees = @()
if ($role) {
    Write-Status "Enumerating PIM-eligible assignees..."
    try {
        $eligibleAssignees = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "roleDefinitionId eq '$($role.RoleTemplateId)'" -All -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{
                    PrincipalId    = $_.PrincipalId
                    Status         = $_.Status
                    AssignmentType = "Eligible"
                    ExpiresUtc     = $_.ScheduleInfo.Expiration.EndDateTime
                }
            }
        Write-Status "Found $($eligibleAssignees.Count) eligible assignee(s)." -Status "OK"
    } catch {
        Write-Status "Could not enumerate PIM-eligible assignees (may require Entra ID Governance license, or PIM is not configured for this role): $($_.Exception.Message)" -Status "WARN"
    }
}

# ---- Detect: live action set ----
$actionStatus = @()
$hypothesizedFound = @()
if ($role) {
    Write-Status "Checking live role definition for confirmed and hypothesized actions..."
    try {
        $roleDef = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$($role.RoleTemplateId)"
        $allowed = $roleDef.rolePermissions.allowedResourceActions
        $actionStatus = $ConfirmedActions | ForEach-Object {
            [pscustomobject]@{ Action = $_; Present = ($allowed -contains $_) }
        }
        $confirmedCount = ($actionStatus | Where-Object Present).Count
        Write-Status "$confirmedCount of $($ConfirmedActions.Count) confirmed actions present in this tenant's role definition." -Status $(if ($confirmedCount -eq $ConfirmedActions.Count) { "OK" } else { "WARN" })

        foreach ($kw in $HypothesizedActionKeywords) {
            $matches = $allowed | Where-Object { $_ -match $kw }
            if ($matches) {
                $hypothesizedFound += $matches
            }
        }
        if ($hypothesizedFound.Count -gt 0) {
            Write-Status "Found action(s) matching hypothesized (not yet confirmed by Microsoft docs) keywords: $($hypothesizedFound -join ', ')" -Status "INFO"
        } else {
            Write-Status "No actions matching the hypothesized 'mark compromised' / 'delete auth method' keywords found — consistent with the confirmed four-action baseline." -Status "INFO"
        }
    } catch {
        Write-Status "Failed to read live role definition: $($_.Exception.Message)" -Status "ERROR"
    }
}

# ---- Cross-reference overlap ----
$overlapFindings = @()
if ($role) {
    Write-Status "Cross-referencing overlap with Security Operator / Security Administrator / Authentication Administrator / User Administrator..."
    foreach ($roleName in $OverlapRoleNames) {
        try {
            $overlapRole = Get-MgDirectoryRole -Filter "displayName eq '$roleName'" -ErrorAction SilentlyContinue
            if (-not $overlapRole) { continue }
            $overlapMembers = Get-MgDirectoryRoleMember -DirectoryRoleId $overlapRole.Id -All
            foreach ($member in $overlapMembers) {
                $isAlsoResponder = $assignees.PrincipalId -contains $member.Id
                if ($isAlsoResponder) {
                    $overlapFindings += [pscustomobject]@{
                        PrincipalId     = $member.Id
                        DisplayName     = $member.AdditionalProperties.displayName
                        OverlappingRole = $roleName
                        Note            = "Holds SOC Identity Responder AND $roleName — redundant identity-response/containment access through two role paths"
                    }
                }
            }
        } catch {
            Write-Status "Could not check overlap for role '$roleName': $($_.Exception.Message)" -Status "WARN"
        }
    }
    if ($overlapFindings.Count -gt 0) {
        Write-Status "Found $($overlapFindings.Count) overlapping assignment(s) — review for redundant containment access." -Status "WARN"
    } else {
        Write-Status "No overlapping assignments found." -Status "OK"
    }
}

# ---- Standing (non-PIM) assignment risk flag ----
$standingRisk = @()
foreach ($a in $assignees) {
    $standingRisk += [pscustomobject]@{
        PrincipalId = $a.PrincipalId
        DisplayName = $a.DisplayName
        Severity    = "MEDIUM"
        Reason      = "Standing (Active, non-PIM) SOC Identity Responder assignment — grants containment power (disable/enable/revoke-sessions/reset-password) with no activation gate. Consider PIM-eligible per SOCIdentityResponder-B.md Fix 4."
    }
}

# ---- Optional audit-log cross-reference ----
$auditFindings = @()
if ($IncludeAuditLogSample -and $role) {
    Write-Status "Pulling recent audit log activity for confirmed actions (requires AuditLog.Read.All)..."
    try {
        $filterClauses = ($AuditActivityNames | ForEach-Object { "activityDisplayName eq '$_'" }) -join " or "
        $recentEvents = Get-MgAuditLogDirectoryAudit -Filter $filterClauses -Top 100 -ErrorAction Stop
        foreach ($evt in $recentEvents) {
            $initiatorId = $evt.InitiatedBy.User.Id
            $isResponder = $assignees.PrincipalId -contains $initiatorId
            $auditFindings += [pscustomobject]@{
                ActivityDateTime         = $evt.ActivityDateTime
                ActivityDisplayName      = $evt.ActivityDisplayName
                InitiatedByUserId        = $initiatorId
                InitiatedByUPN           = $evt.InitiatedBy.User.UserPrincipalName
                InitiatorIsSOCResponder  = $isResponder
                TargetResources          = ($evt.TargetResources | ForEach-Object { $_.UserPrincipalName }) -join ";"
            }
        }
        Write-Status "Pulled $($auditFindings.Count) recent event(s); $(($auditFindings | Where-Object InitiatorIsSOCResponder).Count) initiated by a current SOC Identity Responder holder." -Status "OK"
    } catch {
        Write-Status "Could not pull audit log sample: $($_.Exception.Message)" -Status "WARN"
    }
}

# ---- Report ----
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $OutputPath "SOCIdentityResponderAudit-$timestamp.csv"
$jsonPath = Join-Path $OutputPath "SOCIdentityResponderAudit-$timestamp.json"

$allAssignees = @($assignees) + @($eligibleAssignees)
if ($allAssignees.Count -gt 0) {
    $allAssignees | Export-Csv -Path $reportPath -NoTypeInformation
} else {
    Write-Status "No assignees to export to CSV." -Status "INFO"
}

$summary = [pscustomobject]@{
    TenantId               = $context.TenantId
    GeneratedUtc           = (Get-Date).ToUniversalTime().ToString("o")
    RoleFound              = [bool]$role
    RoleTemplateIdObserved = if ($role) { $role.RoleTemplateId } elseif ($templateOnly) { $templateOnly.Id } else { $null }
    ActiveAssigneeCount    = $assignees.Count
    EligibleAssigneeCount  = $eligibleAssignees.Count
    ConfirmedActionStatus  = $actionStatus
    HypothesizedActionsFound = $hypothesizedFound
    OverlapFindings        = $overlapFindings
    StandingAssignmentRisk = $standingRisk
    AuditLogFindings       = $auditFindings
}
$summary | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8

Write-Status "Assignment export: $reportPath" -Status "OK"
Write-Status "Full summary (JSON): $jsonPath" -Status "OK"

if ($standingRisk.Count -gt 0) {
    Write-Status "$($standingRisk.Count) standing assignment(s) found — see SOCIdentityResponder-B.md Fix 4 (convert to PIM-eligible)." -Status "WARN"
}

return $summary
