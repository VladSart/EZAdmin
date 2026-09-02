<#
.SYNOPSIS
    Audits Security Administrator role assignment posture ahead of / following the Microsoft
    September 2026 identity-response permission expansion (disable/enable user, revoke sessions,
    force password reset — now scoped to non-privileged users).

.DESCRIPTION
    Read-only audit. Does not modify any role assignment, PIM schedule, or role definition.

    Checks performed:
    1. Enumerates ACTIVE Security Administrator assignees.
    2. Enumerates PIM-ELIGIBLE Security Administrator assignees and their activation state.
    3. Queries the tenant's LIVE role definition to determine whether the four candidate
       identity-response actions (users/disable, users/enable, users/invalidateAllRefreshTokens,
       users/password/update) have landed in this tenant yet. Microsoft's own announcement does
       not publish the literal appended action-string list for this role specifically — this
       script treats these four as the working hypothesis (based on the identical action names
       already used by Authentication Administrator/User Administrator for the same functional
       capabilities) and reports live tenant state rather than assuming presence.
    4. Cross-references every Security Administrator assignee against membership in
       Authentication Administrator, User Administrator, Helpdesk Administrator, and Password
       Administrator to flag redundant identity-response access through overlapping roles.
    5. Flags standing (Active, non-PIM) assignments as HIGH severity once the rollout is
       confirmed live in this tenant, since those grant the new actions with no activation gate.
    6. Optionally pulls recent audit-log activity for the four candidate actions and reports
       which entries were initiated by a current Security Administrator holder.

    Does NOT modify role assignments, create/convert PIM schedules, or build custom roles —
    see EntraID/Troubleshooting/SecurityAdminRoleExpansion-B.md / -A.md for remediation steps.

.PARAMETER IncludeAuditLogSample
    If specified, pulls up to 100 recent directory audit log entries for the candidate actions
    and cross-references InitiatedBy against current Security Administrator holders. Requires
    AuditLog.Read.All. Omit for a faster, role-assignment-only pass.

.PARAMETER OutputPath
    Folder to write the CSV/JSON output to. Defaults to the current directory.

.EXAMPLE
    .\Get-SecurityAdminRoleAudit.ps1
    Runs the role-assignment and rollout-status audit only.

.EXAMPLE
    .\Get-SecurityAdminRoleAudit.ps1 -IncludeAuditLogSample -OutputPath C:\Reports
    Runs the full audit including a recent audit-log cross-reference, writing output to C:\Reports.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement,
    Microsoft.Graph.Identity.Governance modules.
    Run-as: Any account with RoleManagement.Read.Directory (and AuditLog.Read.All if using
    -IncludeAuditLogSample). Does not require an administrative role itself — read scopes only.
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

$SecurityAdminRoleTemplateId = "194ae4cb-b126-40b2-bd5b-6091b380977d"
$CandidateActions = @(
    "microsoft.directory/users/disable",
    "microsoft.directory/users/enable",
    "microsoft.directory/users/invalidateAllRefreshTokens",
    "microsoft.directory/users/password/update"
)
$OverlapRoleNames = @("Authentication Administrator", "User Administrator", "Helpdesk Administrator", "Password Administrator")
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

# ---- Detect ----
Write-Status "Enumerating active Security Administrator assignees..."
$activeAssignees = @()
try {
    $role = Get-MgDirectoryRole -Filter "displayName eq 'Security Administrator'" -ErrorAction SilentlyContinue
    if ($role) {
        $activeAssignees = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All | ForEach-Object {
            [pscustomobject]@{
                PrincipalId   = $_.Id
                PrincipalType = ($_.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.', '')
                DisplayName   = $_.AdditionalProperties.displayName
                AssignmentType = "Active"
            }
        }
        Write-Status "Found $($activeAssignees.Count) active assignee(s)." -Status "OK"
    } else {
        Write-Status "Security Administrator role has never been activated in this tenant (no active assignments possible)." -Status "WARN"
    }
} catch {
    Write-Status "Failed to enumerate active assignees: $($_.Exception.Message)" -Status "ERROR"
}

Write-Status "Enumerating PIM-eligible Security Administrator assignees..."
$eligibleAssignees = @()
try {
    $eligibleAssignees = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "roleDefinitionId eq '$SecurityAdminRoleTemplateId'" -All -ErrorAction SilentlyContinue |
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

Write-Status "Checking live role definition for candidate identity-response actions..."
$rolloutStatus = @()
try {
    $roleDef = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$SecurityAdminRoleTemplateId"
    $allowed = $roleDef.rolePermissions.allowedResourceActions
    $rolloutStatus = $CandidateActions | ForEach-Object {
        [pscustomobject]@{
            Action              = $_
            PresentInThisTenant = ($allowed -contains $_)
        }
    }
    $landedCount = ($rolloutStatus | Where-Object PresentInThisTenant).Count
    if ($landedCount -eq $CandidateActions.Count) {
        Write-Status "All $($CandidateActions.Count) candidate identity-response actions are present in this tenant's role definition — rollout has landed." -Status "WARN"
    } elseif ($landedCount -gt 0) {
        Write-Status "$landedCount of $($CandidateActions.Count) candidate actions present — rollout may be partially applied or the action set differs from the working hypothesis. Verify manually." -Status "WARN"
    } else {
        Write-Status "None of the candidate actions are present yet — rollout has not reached this tenant as of this check (expected to complete by end of September 2026)." -Status "OK"
    }
} catch {
    Write-Status "Failed to read live role definition: $($_.Exception.Message)" -Status "ERROR"
}

Write-Status "Cross-referencing overlap with Authentication/User/Helpdesk/Password Administrator..."
$overlapFindings = @()
foreach ($roleName in $OverlapRoleNames) {
    try {
        $overlapRole = Get-MgDirectoryRole -Filter "displayName eq '$roleName'" -ErrorAction SilentlyContinue
        if (-not $overlapRole) { continue }
        $overlapMembers = Get-MgDirectoryRoleMember -DirectoryRoleId $overlapRole.Id -All
        foreach ($member in $overlapMembers) {
            $isAlsoSecurityAdmin = $activeAssignees.PrincipalId -contains $member.Id
            if ($isAlsoSecurityAdmin) {
                $overlapFindings += [pscustomobject]@{
                    PrincipalId       = $member.Id
                    DisplayName       = $member.AdditionalProperties.displayName
                    OverlappingRole   = $roleName
                    Note              = "Holds Security Administrator AND $roleName — redundant identity-response access through two role paths"
                }
            }
        }
    } catch {
        Write-Status "Could not check overlap for role '$roleName': $($_.Exception.Message)" -Status "WARN"
    }
}
if ($overlapFindings.Count -gt 0) {
    Write-Status "Found $($overlapFindings.Count) overlapping assignment(s) — review for redundant access." -Status "WARN"
} else {
    Write-Status "No overlapping assignments found." -Status "OK"
}

# ---- Standing (non-PIM) assignment risk flag ----
$standingRisk = @()
if ($rolloutStatus | Where-Object PresentInThisTenant) {
    foreach ($a in $activeAssignees) {
        $standingRisk += [pscustomobject]@{
            PrincipalId = $a.PrincipalId
            DisplayName = $a.DisplayName
            Severity    = "HIGH"
            Reason      = "Standing (Active, non-PIM) Security Administrator assignment with the Sept 2026 identity-response actions confirmed live in this tenant — no activation gate protects this power."
        }
    }
}

# ---- Optional audit-log cross-reference ----
$auditFindings = @()
if ($IncludeAuditLogSample) {
    Write-Status "Pulling recent audit log activity for candidate actions (requires AuditLog.Read.All)..."
    try {
        $filterClauses = ($AuditActivityNames | ForEach-Object { "activityDisplayName eq '$_'" }) -join " or "
        $recentEvents = Get-MgAuditLogDirectoryAudit -Filter $filterClauses -Top 100 -ErrorAction Stop
        foreach ($evt in $recentEvents) {
            $initiatorId = $evt.InitiatedBy.User.Id
            $isSecurityAdmin = $activeAssignees.PrincipalId -contains $initiatorId
            $auditFindings += [pscustomobject]@{
                ActivityDateTime      = $evt.ActivityDateTime
                ActivityDisplayName   = $evt.ActivityDisplayName
                InitiatedByUserId     = $initiatorId
                InitiatedByUPN        = $evt.InitiatedBy.User.UserPrincipalName
                InitiatorIsSecurityAdmin = $isSecurityAdmin
                TargetResources       = ($evt.TargetResources | ForEach-Object { $_.UserPrincipalName }) -join ";"
            }
        }
        Write-Status "Pulled $($auditFindings.Count) recent event(s); $(($auditFindings | Where-Object InitiatorIsSecurityAdmin).Count) initiated by a current Security Administrator holder." -Status "OK"
    } catch {
        Write-Status "Could not pull audit log sample: $($_.Exception.Message)" -Status "WARN"
    }
}

# ---- Report ----
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $OutputPath "SecurityAdminRoleAudit-$timestamp.csv"
$jsonPath = Join-Path $OutputPath "SecurityAdminRoleAudit-$timestamp.json"

$allAssignees = @($activeAssignees) + @($eligibleAssignees)
$allAssignees | Export-Csv -Path $reportPath -NoTypeInformation

$summary = [pscustomobject]@{
    TenantId              = $context.TenantId
    GeneratedUtc          = (Get-Date).ToUniversalTime().ToString("o")
    ActiveAssigneeCount   = $activeAssignees.Count
    EligibleAssigneeCount = $eligibleAssignees.Count
    RolloutStatus         = $rolloutStatus
    OverlapFindings       = $overlapFindings
    StandingAssignmentRisk = $standingRisk
    AuditLogFindings      = $auditFindings
}
$summary | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8

Write-Status "Assignment export: $reportPath" -Status "OK"
Write-Status "Full summary (JSON): $jsonPath" -Status "OK"

if ($standingRisk.Count -gt 0) {
    Write-Status "$($standingRisk.Count) HIGH-severity standing assignment(s) found — see SecurityAdminRoleExpansion-B.md Fix 2 (convert to PIM-eligible)." -Status "WARN"
}

return $summary
