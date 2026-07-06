<#
.SYNOPSIS
    Audits Intune Scope Tags and RBAC role assignments tenant-wide, and optionally
    checks a specific admin's effective visibility against a target object.

.DESCRIPTION
    Companion diagnostic for Intune/Troubleshooting/ScopeTags-B.md and ScopeTags-A.md.

    Both runbooks describe the RBAC visibility rule as a triad that must all align
    (ScopeTags-A.md How It Works): the admin needs (1) a role assignment granting the
    action, (2) group membership in that assignment, and (3) a scope tag on the
    assignment that matches at least one scope tag on the target object. This script
    automates the two checks that are hardest to do by hand — enumerating tag overlap
    and finding objects that only carry the wildcard Default tag (ScopeTags-A.md
    Playbook 4, ScopeTags-B.md Learning Pointers).

    Always produces (tenant-wide, no parameters needed):
      - ScopeTags-All.csv           — every scope tag defined in the tenant
      - RoleAssignments-All.csv     — every role assignment with its scope tag IDs
      - UntaggedObjects.csv         — config profiles + compliance policies carrying
                                      only the Default tag (ID "0") — the "why can't
                                      anyone with a scoped role see this?" gap from
                                      ScopeTags-A.md Playbook 4

    Optional, if -AdminUpn is supplied:
      - Resolves which role assignment(s) the admin belongs to and which scope tags
        those assignments carry (ScopeTags-A.md Validation Step 1)
      - If -TargetObjectName is also supplied, checks whether that object's scope
        tags overlap with the admin's — the exact "at least one matching tag" rule
        from ScopeTags-B.md Learning Pointers

    This script makes no RBAC, scope tag, or policy changes — it is read-only audit
    and diagnostic only. See ScopeTags-A.md Remediation Playbooks 1-3 for the actual
    fixes once a gap is confirmed here.

.PARAMETER AdminUpn
    UPN of an admin to check role assignment membership and scope tag coverage for.
    Optional.

.PARAMETER TargetObjectName
    Display name of a config profile or compliance policy to check scope tag overlap
    against the admin specified in -AdminUpn. Requires -AdminUpn to also be set.

.PARAMETER OutputPath
    Folder to write CSV reports to. Default: current directory.

.EXAMPLE
    .\Get-ScopeTagRBACAudit.ps1
    Runs the tenant-wide scope tag, role assignment, and untagged-object audit.

.EXAMPLE
    .\Get-ScopeTagRBACAudit.ps1 -AdminUpn "helpdesk.emea@contoso.com"
    Also resolves which role assignments/scope tags that admin has.

.EXAMPLE
    .\Get-ScopeTagRBACAudit.ps1 -AdminUpn "helpdesk.emea@contoso.com" -TargetObjectName "Windows-Security-Baseline"
    Checks whether the named admin's scope tags overlap with the named policy's tags —
    answers "why can't this admin see this policy?" in one pass.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Users, Microsoft.Graph.Groups
    Scopes:   DeviceManagementRBAC.Read.All, DeviceManagementConfiguration.Read.All, User.Read.All, GroupMember.Read.All
    Safe/Unsafe: Fully read-only. Makes no changes to roles, assignments, or scope tags.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AdminUpn,

    [Parameter(Mandatory = $false)]
    [string]$TargetObjectName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if ($TargetObjectName -and -not $AdminUpn) {
    Write-Status "-TargetObjectName requires -AdminUpn to also be supplied so overlap can be checked." "ERROR"
    return
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected. Connecting with required scopes..." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementRBAC.Read.All", "DeviceManagementConfiguration.Read.All", "User.Read.All", "GroupMember.Read.All" -NoWelcome
    }
    else {
        Write-Status "Connected as $($context.Account)" "OK"
    }
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    throw
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ---------------------------------------------------------------------------
# 1. All scope tags
# ---------------------------------------------------------------------------
Write-Status "Pulling all scope tags..." "INFO"
$scopeTags = Get-MgDeviceManagementRoleScopeTag -All | Select-Object Id, DisplayName, Description
$scopeTagsFile = Join-Path $OutputPath "ScopeTags-All-$timestamp.csv"
$scopeTags | Export-Csv -Path $scopeTagsFile -NoTypeInformation
Write-Status "Found $($scopeTags.Count) scope tag(s). Exported to $scopeTagsFile" "OK"
$tagNameMap = @{}
$scopeTags | ForEach-Object { $tagNameMap[$_.Id] = $_.DisplayName }

# ---------------------------------------------------------------------------
# 2. All role assignments and their scope tags
# ---------------------------------------------------------------------------
Write-Status "Pulling all role assignments..." "INFO"
$assignments = Get-MgDeviceManagementRoleAssignment -All
$assignmentReport = $assignments | ForEach-Object {
    [PSCustomObject]@{
        AssignmentName = $_.DisplayName
        Id             = $_.Id
        ScopeTagIds    = ($_.RoleScopeTagIds -join ", ")
        ScopeTagNames  = (($_.RoleScopeTagIds | ForEach-Object { $tagNameMap[$_] }) -join ", ")
    }
}
$assignmentFile = Join-Path $OutputPath "RoleAssignments-All-$timestamp.csv"
$assignmentReport | Export-Csv -Path $assignmentFile -NoTypeInformation
Write-Status "Found $($assignments.Count) role assignment(s). Exported to $assignmentFile" "OK"

# ---------------------------------------------------------------------------
# 3. Untagged objects (Default-only) — visibility gap candidates
# ---------------------------------------------------------------------------
Write-Status "Scanning config profiles and compliance policies for Default-only (untagged) objects..." "INFO"
$untagged = @()

Get-MgDeviceManagementDeviceConfiguration -All | Where-Object {
    $_.RoleScopeTagIds.Count -eq 0 -or ($_.RoleScopeTagIds.Count -eq 1 -and $_.RoleScopeTagIds[0] -eq "0")
} | ForEach-Object {
    $untagged += [PSCustomObject]@{ Type = "ConfigProfile"; Name = $_.DisplayName; Id = $_.Id }
}

Get-MgDeviceManagementDeviceCompliancePolicy -All | Where-Object {
    $_.RoleScopeTagIds.Count -eq 0 -or ($_.RoleScopeTagIds.Count -eq 1 -and $_.RoleScopeTagIds[0] -eq "0")
} | ForEach-Object {
    $untagged += [PSCustomObject]@{ Type = "CompliancePolicy"; Name = $_.DisplayName; Id = $_.Id }
}

$untaggedFile = Join-Path $OutputPath "UntaggedObjects-$timestamp.csv"
$untagged | Export-Csv -Path $untaggedFile -NoTypeInformation
Write-Status "$($untagged.Count) object(s) carry only the Default scope tag — visible to ALL admins with any Intune role. Exported to $untaggedFile" $(if ($untagged.Count -gt 0) { "WARN" } else { "OK" })

# ---------------------------------------------------------------------------
# 4. Optional — resolve a specific admin's role assignments
# ---------------------------------------------------------------------------
$adminTagIds = @()
if ($AdminUpn) {
    Write-Status "Resolving role assignments for $AdminUpn..." "INFO"
    $user = Get-MgUser -Filter "userPrincipalName eq '$AdminUpn'" -Property Id -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Status "User '$AdminUpn' not found." "ERROR"
    }
    else {
        $matchedAssignments = @()
        foreach ($a in $assignments) {
            try {
                $members = Get-MgDeviceManagementRoleAssignmentMember -RoleAssignmentId $a.Id -ErrorAction SilentlyContinue
                if ($members -and $members.Id -contains $user.Id) {
                    $matchedAssignments += $a
                }
            }
            catch { }
        }

        if ($matchedAssignments.Count -eq 0) {
            Write-Status "$AdminUpn is not a member of any role assignment — they have NO Intune RBAC role at all." "ERROR"
        }
        else {
            foreach ($ma in $matchedAssignments) {
                $tagNames = ($ma.RoleScopeTagIds | ForEach-Object { $tagNameMap[$_] }) -join ", "
                Write-Status "Role Assignment: $($ma.DisplayName) | Scope Tags: $tagNames" "OK"
                $adminTagIds += $ma.RoleScopeTagIds
            }
            $adminTagIds = $adminTagIds | Select-Object -Unique
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Optional — check overlap against a target object
# ---------------------------------------------------------------------------
if ($TargetObjectName -and $adminTagIds.Count -ge 0) {
    Write-Status "Checking scope tag overlap for object '$TargetObjectName'..." "INFO"
    $target = Get-MgDeviceManagementDeviceConfiguration -Filter "displayName eq '$TargetObjectName'" -ErrorAction SilentlyContinue
    if (-not $target) {
        $target = Get-MgDeviceManagementDeviceCompliancePolicy -Filter "displayName eq '$TargetObjectName'" -ErrorAction SilentlyContinue
    }

    if (-not $target) {
        Write-Status "Object '$TargetObjectName' not found among config profiles or compliance policies." "ERROR"
    }
    else {
        $targetTags = $target.RoleScopeTagIds
        $overlap = $targetTags | Where-Object { $adminTagIds -contains $_ }

        Write-Status "Object scope tags: $($targetTags -join ', ')" "INFO"
        Write-Status "Admin scope tags:  $($adminTagIds -join ', ')" "INFO"

        if ($overlap.Count -gt 0) {
            Write-Status "MATCH — admin's role assignment shares at least one scope tag with this object. If they still can't act on it, the issue is a missing resource-action PERMISSION on the role, not scope (ScopeTags-A.md Phase 2)." "OK"
        }
        else {
            Write-Status "NO MATCH — this object's scope tags do not overlap with the admin's role assignment tags. This is why the admin cannot see it (ScopeTags-B.md Fix 1/Fix 2)." "ERROR"
        }
    }
}

Write-Host ""
Write-Status "Audit complete. Review UntaggedObjects.csv for visibility gaps and RoleAssignments-All.csv for scope tag coverage." "OK"
