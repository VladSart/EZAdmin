<#
.SYNOPSIS
    Audits all Restricted Management Administrative Units (RMAUs) in a tenant — member
    inventory, scoped role assignments, and cross-checks against Entra ID Governance
    features that are documented as incompatible with RMAU membership.

.DESCRIPTION
    Connects to Microsoft Graph and reports, read-only:
    - Every administrative unit in the tenant, flagging which are restricted-management
      (isMemberManagementRestricted = true) vs. regular
    - For each RMAU: its direct member inventory broken down by object type (User,
      Device, Group), flagging any unexpected member type
    - For each RMAU: every role assignment scoped specifically to that RMAU
      (DirectoryScopeId = /administrativeUnits/<id>), flagging assignments whose
      principal no longer resolves (removed/disabled user or deleted service principal)
      as orphaned — these represent access nobody can actually use, and a potential
      "nobody can manage this RMAU" dead end if a Global Administrator hasn't also
      retained a path back in
    - A best-effort cross-check flagging RMAU member users/groups that also appear in
      PIM eligible role assignments, since PIM is documented as incompatible with RMAU
      membership and a PIM assignment against such an object will not function as expected

    This answers the two questions an RMAU health check or escalation always needs
    first: "does every RMAU actually have a working path for someone to manage its
    members" and "are any RMAU-protected objects also configured with a Governance
    feature that silently won't work against them."

    Exports results to CSV and prints a colour-coded console summary. Read-only — makes
    no changes to any AU, role assignment, or membership.

    Does NOT cover:
    - Entitlement Management, Lifecycle Workflows, or Access Reviews cross-checks
      (PIM eligible assignments only, in this pass) — see RestrictedManagementAU-A.md
      Playbook 4 note for extending this audit
    - BitLocker recovery key delegation specifics
    - Creating, deleting, or modifying any RMAU or role assignment

.PARAMETER OutputPath
    Path for the CSV export. Default: .\RMAU-Audit-<timestamp>.csv

.EXAMPLE
    .\Get-RestrictedManagementAUAudit.ps1

.EXAMPLE
    .\Get-RestrictedManagementAUAudit.ps1 -OutputPath C:\Reports\rmau-audit.csv

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Scopes needed: AdministrativeUnit.Read.All, RoleManagement.Read.Directory,
                   Directory.Read.All, RoleEligibilitySchedule.Read.Directory (for the
                   optional PIM cross-check; script degrades gracefully without it)
    Run As: Global Reader, Security Reader, or Privileged Role Administrator (read) —
            does not require write permissions
    Safe: Read-only — no AU, role assignment, or membership changes are made
    Cross-references: EntraID/Troubleshooting/RestrictedManagementAU-B.md (Fix 1-6),
                       EntraID/Troubleshooting/RestrictedManagementAU-A.md (Validation
                       Steps, Playbook 4)
#>

[CmdletBinding()]
param(
    [string]$OutputPath = ".\RMAU-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# ─── Connect ───
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        Connect-MgGraph -Scopes "AdministrativeUnit.Read.All","RoleManagement.Read.Directory","Directory.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ─── Enumerate all AUs, identify RMAUs ───
Write-Status "Enumerating administrative units..." "INFO"
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$rmauList   = [System.Collections.Generic.List[object]]::new()

try {
    $allAUs = Get-MgDirectoryAdministrativeUnit -All -EA Stop
    foreach ($au in $allAUs) {
        $isRestricted = [bool]$au.AdditionalProperties.isMemberManagementRestricted
        if ($isRestricted) { $rmauList.Add($au) }
    }
    Write-Status "Found $($allAUs.Count) administrative unit(s), $($rmauList.Count) restricted-management." "OK"
} catch {
    Write-Status "Could not enumerate administrative units: $($_.Exception.Message)" "ERROR"
    return
}

if ($rmauList.Count -eq 0) {
    Write-Status "No restricted management administrative units found in this tenant." "OK"
    return
}

# ─── Per-RMAU: members + scoped roles ───
foreach ($rmau in $rmauList) {
    Write-Host "`n=== RMAU: $($rmau.DisplayName) ($($rmau.Id)) ===" -ForegroundColor Cyan

    # Members
    $memberTypeCounts = @{ User = 0; Device = 0; Group = 0; Other = 0 }
    try {
        $members = Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $rmau.Id -All -EA Stop
        foreach ($m in $members) {
            $type = $m.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', ''
            switch ($type) {
                "user"   { $memberTypeCounts.User++ }
                "device" { $memberTypeCounts.Device++ }
                "group"  { $memberTypeCounts.Group++ }
                default  { $memberTypeCounts.Other++ }
            }
        }
        Write-Status "Members — Users: $($memberTypeCounts.User), Devices: $($memberTypeCounts.Device), Groups: $($memberTypeCounts.Group), Other/Unexpected: $($memberTypeCounts.Other)" $(if ($memberTypeCounts.Other -gt 0) { "WARN" } else { "OK" })
        if ($memberTypeCounts.Other -gt 0) {
            Write-Status "Unexpected member type found — only Users, Devices, and Security Groups are documented as valid RMAU members." "WARN"
        }
    } catch {
        Write-Status "Could not enumerate members: $($_.Exception.Message)" "ERROR"
    }

    # Scoped role assignments
    $scopedRoleCount = 0
    $orphanedCount   = 0
    try {
        $scopedRoles = Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $rmau.Id -All -EA Stop
        $scopedRoleCount = ($scopedRoles | Measure-Object).Count

        foreach ($sr in $scopedRoles) {
            $principalId = $sr.RoleMemberInfo.Id
            $resolved = $true
            try {
                $null = Get-MgDirectoryObject -DirectoryObjectId $principalId -EA Stop
            } catch {
                $resolved = $false
                $orphanedCount++
            }
            $flag = if ($resolved) { "OK" } else { "WARN" }
            Write-Status "  Scoped role member: $($sr.RoleMemberInfo.DisplayName) [$principalId] — resolves: $resolved" $flag
        }

        if ($scopedRoleCount -eq 0) {
            Write-Status "No roles scoped to this RMAU at all — only Global Administrator/Privileged Role Administrator can currently manage its members (via container-level access), and neither can modify member objects directly. Confirm this is intentional." "WARN"
        }
        if ($orphanedCount -gt 0) {
            Write-Status "$orphanedCount scoped role assignment(s) reference a principal that no longer resolves — orphaned access, worth cleaning up." "WARN"
        }
    } catch {
        Write-Status "Could not enumerate scoped role members: $($_.Exception.Message)" "ERROR"
    }

    $allResults.Add([PSCustomObject]@{
        RMAUDisplayName       = $rmau.DisplayName
        RMAUObjectId          = $rmau.Id
        MemberUsers           = $memberTypeCounts.User
        MemberDevices         = $memberTypeCounts.Device
        MemberGroups          = $memberTypeCounts.Group
        MemberUnexpectedType  = $memberTypeCounts.Other
        ScopedRoleAssignments = $scopedRoleCount
        OrphanedScopedRoles   = $orphanedCount
        NoScopedRoleAtAll     = ($scopedRoleCount -eq 0)
    })
}

# ─── Optional PIM eligible-assignment cross-check ───
Write-Host "`n=== Governance-Feature Conflict Cross-Check (PIM eligible assignments) ===" -ForegroundColor Cyan
try {
    $rmauMemberIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($rmau in $rmauList) {
        $members = Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $rmau.Id -All -EA SilentlyContinue
        foreach ($m in $members) { [void]$rmauMemberIds.Add($m.Id) }
    }

    $eligible = Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -All -EA Stop
    $conflicts = $eligible | Where-Object { $rmauMemberIds.Contains($_.PrincipalId) }

    if ($conflicts.Count -gt 0) {
        Write-Status "$($conflicts.Count) PIM eligible role assignment(s) found targeting a principal that is also an RMAU member — these will NOT function as expected per documented RMAU/Governance incompatibility." "ERROR"
        foreach ($c in $conflicts) {
            Write-Status "  PrincipalId $($c.PrincipalId) — RoleDefinitionId $($c.RoleDefinitionId)" "ERROR"
        }
    } else {
        Write-Status "No PIM eligible assignments found targeting RMAU members." "OK"
    }
} catch {
    Write-Status "PIM cross-check skipped (requires RoleEligibilitySchedule.Read.Directory and PIM for Directory Roles licensing): $($_.Exception.Message)" "WARN"
}

# ─── Export ───
if ($allResults.Count -gt 0) {
    $outputDir = Split-Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "`nResults exported to: $OutputPath" "OK"
}

# ─── Summary ───
Write-Host "`n=== RMAU Audit Summary ===" -ForegroundColor Cyan
Write-Host "Total RMAUs                        : $($rmauList.Count)"
Write-Host "RMAUs with no scoped role at all    : $(($allResults | Where-Object { $_.NoScopedRoleAtAll }).Count)"
Write-Host "RMAUs with orphaned scoped roles    : $(($allResults | Where-Object { $_.OrphanedScopedRoles -gt 0 }).Count)"
Write-Host "RMAUs with unexpected member type   : $(($allResults | Where-Object { $_.MemberUnexpectedType -gt 0 }).Count)"
