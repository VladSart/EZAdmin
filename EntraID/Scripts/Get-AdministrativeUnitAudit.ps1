<#
.SYNOPSIS
    Read-only tenant-wide audit of Microsoft Entra administrative units (AUs)
    — the delegation-governance gaps AdministrativeUnits-A.md and
    AdministrativeUnits-B.md describe as the most common misconfiguration and
    silent-failure patterns.

.DESCRIPTION
    Runs five independent checks and combines them into a single report:

    1. AU INVENTORY — enumerates every administrative unit in the tenant:
       restricted-management flag, membership type (Assigned/Dynamic), and
       (for dynamic AUs) the rule itself and its processing state.

    2. SCOPED ROLE ASSIGNMENT COVERAGE — for each AU, lists every role
       assignment whose directoryScopeId targets that specific AU, and flags
       NO_SCOPED_ROLE_ASSIGNMENTS for any AU with zero — a delegation
       container nobody can currently use, which for a Restricted Management
       AU specifically means NO ONE, including Global Administrator, can
       modify its members' Entra properties until someone self-assigns in.

    3. SERVICE PRINCIPAL / GUEST READ-PERMISSION GAP — for every AU-scoped
       role assignment whose principal is a service principal or a guest
       user, cross-checks for a supplementary TENANT-WIDE (directoryScopeId
       "/") Directory Readers (or broader) assignment. Flags
       MISSING_SUPPLEMENTARY_READ_ROLE per AdministrativeUnits-B.md Fix 7 —
       the exact "assigned in the portal, every Graph call still 403s"
       pattern, since service principals and guest users get no default
       directory-read permission the way member users do.

    4. DYNAMIC AU HEALTH — flags ZERO_MEMBER_DYNAMIC_AU (rule matches
       nobody, either correct or a silent rule-logic error worth confirming)
       and PROCESSING_PAUSED (membership frozen, a common "why hasn't this
       updated in weeks" root cause per AdministrativeUnits-A.md Validation
       Step 6).

    5. RESTRICTED MANAGEMENT AU SUMMARY — reports member-type breakdown for
       every RMAU found, purely as a rollup of Check 1's own inventory data
       (informational; RMAUs are meant to be small and sensitive, so an
       unexpectedly large one is worth a second look), and elevates Check 2's
       NO_SCOPED_ROLE_ASSIGNMENTS finding to HIGH severity specifically for
       RMAUs, since that gap means literally no one — including Global
       Administrator — can currently manage that RMAU's members.

    This script covers ALL administrative units tenant-wide (regular and
    restricted) as a single governance inventory. For RMAU-specific deep
    checks — orphaned scoped-role principals (removed/disabled accounts
    still holding a live assignment) and a PIM-eligible-assignment conflict
    cross-check — see the dedicated `Get-RestrictedManagementAUAudit.ps1`
    instead; this script does not duplicate that analysis.

    Read-only. Makes no changes to any AU, membership, or role assignment.
    Exports a full CSV plus a filtered "review needed" CSV.

    Does NOT cover (see AdministrativeUnits-A.md "Not in scope" note):
    - Orphaned RMAU-scoped-role principals and the PIM-eligible-assignment
      conflict cross-check — see `Get-RestrictedManagementAUAudit.ps1`
    - The Entra audit log entries for RMAU self-assignment events (an
      auditable action, not a Graph-queryable directory-state object the
      same way role assignments are) — export separately from the Entra
      admin center Audit logs blade, Activity = "Add member to role scoped
      over Restricted Management Administrative Unit"
    - PIM eligible (vs. active) AU-scoped assignments — requires a
      Microsoft Entra ID P2 license and separate PIM-specific Graph
      endpoints (privilegedAccess/roleEligibilityScheduleInstances) not
      queried by this script
    - Intune-side device delegation/scope tags — a wholly separate RBAC
      system that AU scope does not influence in either direction
    - Whether any given AU-scoped admin has actually exercised their access
      recently (a sign-in/activity question, not a configuration one)

.PARAMETER IncludeAllMembers
    If specified, also exports a full per-AU membership list (object Id and
    type) to a separate CSV. Useful for a from-scratch inventory but can be
    large in tenants with many/large AUs.

.PARAMETER OutputPath
    Folder where CSV/JSON reports are written. Defaults to
    $env:TEMP\AUAudit-<timestamp>.

.EXAMPLE
    .\Get-AdministrativeUnitAudit.ps1

    Standard audit — AU inventory, scoped-role coverage, and flagged gaps only.

.EXAMPLE
    .\Get-AdministrativeUnitAudit.ps1 -IncludeAllMembers -OutputPath C:\Reports\AU

    Full per-AU membership export in addition to the flagged findings, custom output folder.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement,
              Microsoft.Graph.Identity.Governance
    Scopes needed: AdministrativeUnit.Read.All, RoleManagement.Read.Directory,
                   Directory.Read.All, User.Read.All
    Run As: Any account with Global Reader (sufficient for every read in this
            script) or a role with equivalent read scopes
    Safe: Fully read-only — no AU, membership, or role assignment is created,
          modified, or removed anywhere in this script. Zero Set-Mg/New-Mg/
          Remove-Mg/Update-Mg cmdlets are used anywhere in this script.
    Cross-references: EntraID/Troubleshooting/AdministrativeUnits-B.md (Triage,
                       Fix 6, Fix 7) and AdministrativeUnits-A.md (Validation
                       Steps 3, 6, 7, Symptom -> Cause Map, Playbook 4). For
                       RMAU-specific orphaned-principal/PIM-conflict checks,
                       see the separate Get-RestrictedManagementAUAudit.ps1.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [switch]$IncludeAllMembers,

    [string]$OutputPath = "$env:TEMP\AUAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

# ---- Preflight ----
foreach ($mod in @("Microsoft.Graph.Authentication", "Microsoft.Graph.Identity.DirectoryManagement", "Microsoft.Graph.Identity.Governance")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod" "ERROR"
        return
    }
}

$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Graph. Connecting with required read scopes..." "INFO"
    try {
        Connect-MgGraph -Scopes "AdministrativeUnit.Read.All", "RoleManagement.Read.Directory", "Directory.Read.All", "User.Read.All" -NoWelcome -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        return
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()
$auRows = [System.Collections.Generic.List[object]]::new()
$scopedAssignmentRows = [System.Collections.Generic.List[object]]::new()
$memberRows = [System.Collections.Generic.List[object]]::new()

# Cache tenant-wide (directoryScopeId "/") role assignments once — avoids a
# per-principal Graph round trip for the SP/guest read-permission check.
Write-Status "Caching tenant-wide role assignments for the read-permission cross-check..." "INFO"
try {
    $tenantWideAssignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter "directoryScopeId eq '/'" -ExpandProperty RoleDefinition -All -ErrorAction Stop
}
catch {
    Write-Status "Could not cache tenant-wide role assignments: $($_.Exception.Message)" "ERROR"
    $tenantWideAssignments = @()
}
$readCapableRoleNames = @("Directory Readers", "Global Reader", "Global Administrator", "Privileged Role Administrator")
$principalsWithReadAccess = @($tenantWideAssignments | Where-Object { $_.RoleDefinition.DisplayName -in $readCapableRoleNames } | Select-Object -ExpandProperty PrincipalId -Unique)

# =====================================================================
# CHECK 1 — AU inventory
# =====================================================================
Write-Status "Enumerating administrative units..." "INFO"
try {
    $allAUs = Get-MgDirectoryAdministrativeUnit -All -ErrorAction Stop
    Write-Status "Found $($allAUs.Count) administrative unit(s)." "INFO"
}
catch {
    Write-Status "Failed to enumerate administrative units: $($_.Exception.Message)" "ERROR"
    $allAUs = @()
}

$i = 0
foreach ($au in $allAUs) {
    $i++
    if ($i % 25 -eq 0) { Write-Status "Processed $i of $($allAUs.Count) administrative units..." "INFO" }

    $isRMAU = [bool]$au.AdditionalProperties['isMemberManagementRestricted']
    $membershipType = $au.AdditionalProperties['membershipType']
    if (-not $membershipType) { $membershipType = "Assigned" }
    $membershipRule = $au.AdditionalProperties['membershipRule']
    $ruleProcessingState = $au.AdditionalProperties['membershipRuleProcessingState']

    # ---- Membership ----
    $members = @()
    try {
        $members = Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -All -ErrorAction Stop
    }
    catch {
        Write-Status "Could not read members for AU '$($au.DisplayName)': $($_.Exception.Message)" "WARN"
    }
    $memberTypeCounts = $members | Group-Object { $_.AdditionalProperties['@odata.type'] } | ForEach-Object { "$($_.Name -replace '#microsoft.graph.',''):$($_.Count)" }

    $auRows.Add([PSCustomObject]@{
        AUId                 = $au.Id
        DisplayName          = $au.DisplayName
        IsRestrictedMgmt     = $isRMAU
        MembershipType       = $membershipType
        MembershipRule       = $membershipRule
        RuleProcessingState  = $ruleProcessingState
        MemberCount          = $members.Count
        MemberTypeBreakdown  = ($memberTypeCounts -join "; ")
    })

    if ($IncludeAllMembers) {
        foreach ($m in $members) {
            $memberRows.Add([PSCustomObject]@{
                AUId       = $au.Id
                AUName     = $au.DisplayName
                MemberId   = $m.Id
                MemberType = ($m.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', '')
            })
        }
    }

    # ---- Dynamic AU health (Check 4) ----
    if ($membershipType -eq "Dynamic") {
        if ($ruleProcessingState -eq "Paused") {
            $findings.Add([PSCustomObject]@{
                Category = "DynamicAU"; AUId = $au.Id; AUName = $au.DisplayName
                Flag = "PROCESSING_PAUSED"
                Detail = "Dynamic membership rule processing is paused — membership is frozen at whatever it was when paused, not reflecting current attribute values."
                RiskLevel = "MEDIUM"
            })
        }
        if ($members.Count -eq 0) {
            $findings.Add([PSCustomObject]@{
                Category = "DynamicAU"; AUId = $au.Id; AUName = $au.DisplayName
                Flag = "ZERO_MEMBER_DYNAMIC_AU"
                Detail = "Dynamic rule currently matches zero objects. May be correct (genuinely empty population) or a rule-logic error — confirm against a known-should-match test object."
                RiskLevel = "LOW"
            })
        }
    }

    # =====================================================================
    # CHECK 2 — Scoped role assignment coverage
    # =====================================================================
    $scopeFilter = "/administrativeUnits/$($au.Id)"
    try {
        $scopedAssignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter "directoryScopeId eq '$scopeFilter'" -ExpandProperty RoleDefinition -All -ErrorAction Stop
    }
    catch {
        Write-Status "Could not read scoped role assignments for AU '$($au.DisplayName)': $($_.Exception.Message)" "WARN"
        $scopedAssignments = @()
    }

    if ($scopedAssignments.Count -eq 0) {
        $findings.Add([PSCustomObject]@{
            Category = "AUGovernance"; AUId = $au.Id; AUName = $au.DisplayName
            Flag = "NO_SCOPED_ROLE_ASSIGNMENTS"
            Detail = $(if ($isRMAU) {
                "RESTRICTED MANAGEMENT AU with zero scoped role assignments — NO ONE, including Global Administrator, can currently modify this AU's members' Entra properties."
            } else {
                "Regular AU with zero scoped role assignments — this delegation container currently grants no one any AU-limited access; only tenant-wide roles can manage its members."
            })
            RiskLevel = $(if ($isRMAU) { "HIGH" } else { "LOW" })
        })
    }

    foreach ($sa in $scopedAssignments) {
        $principalType = "Unknown"
        $principalName = $sa.PrincipalId
        try {
            $dirObj = Get-MgDirectoryObject -DirectoryObjectId $sa.PrincipalId -ErrorAction Stop
            $odataType = $dirObj.AdditionalProperties['@odata.type']
            $principalType = ($odataType -replace '#microsoft.graph.', '')
            if ($dirObj.AdditionalProperties['displayName']) { $principalName = $dirObj.AdditionalProperties['displayName'] }
            if ($odataType -eq '#microsoft.graph.user' -and $dirObj.AdditionalProperties['userType'] -eq 'Guest') { $principalType = 'guestUser' }
        }
        catch { }

        $scopedAssignmentRows.Add([PSCustomObject]@{
            AUId          = $au.Id
            AUName        = $au.DisplayName
            IsRestrictedMgmt = $isRMAU
            RoleName      = $sa.RoleDefinition.DisplayName
            PrincipalId   = $sa.PrincipalId
            PrincipalName = $principalName
            PrincipalType = $principalType
        })

        # =====================================================================
        # CHECK 3 — Service principal / guest supplementary read-permission gap
        # =====================================================================
        if ($principalType -in @("servicePrincipal", "guestUser")) {
            $hasReadAccess = $sa.PrincipalId -in $principalsWithReadAccess
            if (-not $hasReadAccess) {
                $findings.Add([PSCustomObject]@{
                    Category = "ReadPermissionGap"; AUId = $au.Id; AUName = $au.DisplayName
                    Flag = "MISSING_SUPPLEMENTARY_READ_ROLE"
                    Detail = "Principal '$principalName' ($principalType) holds '$($sa.RoleDefinition.DisplayName)' scoped to this AU but has NO tenant-wide Directory Readers/Global Reader/Global Administrator/Privileged Role Administrator assignment — the AU-scoped role is likely functionally inert for this principal (see AdministrativeUnits-B.md Fix 7)."
                    RiskLevel = "MEDIUM"
                })
            }
        }
    }
}

# =====================================================================
# CHECK 5 — Restricted Management AU summary
# =====================================================================
$rmauRows = $auRows | Where-Object { $_.IsRestrictedMgmt }
Write-Status "Found $($rmauRows.Count) restricted management administrative unit(s)." "INFO"

# =====================================================================
# Report
# =====================================================================
Write-Host ""
Write-Host "=== Administrative Unit Audit Summary ===" -ForegroundColor Cyan
Write-Status "$($auRows.Count) administrative unit(s) total ($($rmauRows.Count) restricted management)." "INFO"

$noScopedRole = $findings | Where-Object { $_.Flag -eq "NO_SCOPED_ROLE_ASSIGNMENTS" }
$noScopedRoleRMAU = $noScopedRole | Where-Object { $_.RiskLevel -eq "HIGH" }
Write-Status "$($noScopedRole.Count) AU(s) with zero scoped role assignments ($($noScopedRoleRMAU.Count) of those are Restricted Management AUs — HIGH priority)." $(if ($noScopedRoleRMAU.Count -gt 0) { "ERROR" } elseif ($noScopedRole.Count -gt 0) { "WARN" } else { "OK" })

$readGaps = $findings | Where-Object { $_.Flag -eq "MISSING_SUPPLEMENTARY_READ_ROLE" }
Write-Status "$($readGaps.Count) service principal/guest AU-scoped assignment(s) missing the supplementary tenant-wide read role." $(if ($readGaps.Count -gt 0) { "WARN" } else { "OK" })

$dynamicIssues = $findings | Where-Object { $_.Category -eq "DynamicAU" }
Write-Status "$($dynamicIssues.Count) dynamic-AU health finding(s) (paused processing or zero-member rule)." $(if ($dynamicIssues.Count -gt 0) { "WARN" } else { "OK" })

Write-Host ""
if ($noScopedRoleRMAU.Count -gt 0) {
    Write-Host "--- HIGH: Restricted Management AUs with zero scoped role assignments ---" -ForegroundColor Red
    $noScopedRoleRMAU | Select-Object AUName, Detail | Format-Table -AutoSize -Wrap
}
if ($readGaps.Count -gt 0) {
    Write-Host "--- Service principal/guest read-permission gaps ---" -ForegroundColor Yellow
    $readGaps | Select-Object AUName, Detail | Format-Table -AutoSize -Wrap
}

Write-Host ""
Write-Host "KNOWN GAPS (not covered by this script — see .DESCRIPTION and AdministrativeUnits-A.md):" -ForegroundColor DarkGray
Write-Host " - Orphaned RMAU-scoped-role principals and PIM-conflict cross-check — see Get-RestrictedManagementAUAudit.ps1" -ForegroundColor DarkGray
Write-Host " - RMAU self-assignment audit-log events — export separately from the Entra admin center Audit logs blade" -ForegroundColor DarkGray
Write-Host " - PIM eligible (vs. active) AU-scoped assignments — requires P2 license and separate PIM Graph endpoints" -ForegroundColor DarkGray
Write-Host " - Intune-side device delegation/scope tags — a wholly separate RBAC system" -ForegroundColor DarkGray
Write-Host " - Recent activity/usage of any AU-scoped admin role (a sign-in question, not a configuration one)" -ForegroundColor DarkGray

$auPath = Join-Path $OutputPath "AdministrativeUnits.csv"
$auRows | Export-Csv -Path $auPath -NoTypeInformation -Encoding UTF8

$assignmentsPath = Join-Path $OutputPath "ScopedRoleAssignments.csv"
$scopedAssignmentRows | Export-Csv -Path $assignmentsPath -NoTypeInformation -Encoding UTF8

$findingsPath = Join-Path $OutputPath "Findings.csv"
$findings | Sort-Object @{Expression = { switch ($_.RiskLevel) { "HIGH" {0} "MEDIUM" {1} "LOW" {2} default {3} } }} |
    Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8

Write-Status "AU inventory exported to $auPath" "OK"
Write-Status "Scoped role assignments exported to $assignmentsPath" "OK"
Write-Status "Findings exported to $findingsPath" "OK"

if ($IncludeAllMembers) {
    $membersPath = Join-Path $OutputPath "AllMembers.csv"
    $memberRows | Export-Csv -Path $membersPath -NoTypeInformation -Encoding UTF8
    Write-Status "Full membership list exported to $membersPath" "OK"
}
