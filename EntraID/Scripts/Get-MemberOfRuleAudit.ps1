<#
.SYNOPSIS
    Read-only, tenant-wide audit for the retiring Microsoft Entra `memberOf`
    dynamic membership rule operator (MC1448379, retiring November 3, 2026).

.DESCRIPTION
    The public preview of the `memberOf` rule operator ends November 3, 2026.
    After that date:
      - Dynamic membership GROUPS whose rule uses memberOf stop evaluating
        and freeze at their last-known membership (MembershipRuleProcessing
        State keeps reporting "On" -- this property does NOT reflect the
        freeze).
      - Dynamic ADMINISTRATIVE UNITS whose rule uses memberOf freeze the
        same way, silently stranding AU-scoped role assignments against a
        stale population.
      - Entitlement management AUTOMATIC ASSIGNMENT POLICIES whose rule
        uses memberOf are QUARANTINED -- assignment processing halts
        entirely (no additions, no removals) until memberOf is removed
        from the rule.

    None of the three failure modes produce a visible error or portal
    warning. This script sweeps all three object surfaces, flags every
    memberOf-dependent object, and computes urgency based on today's date
    relative to the deadline.

    Analysis flags applied:
      MEMBEROF_GROUP_FOUND         - A dynamic group's membershipRule
                                      references memberOf.
      MEMBEROF_GROUP_ALREADY_FROZEN- Same, and today's date is on/after
                                      Nov 3, 2026 -- this group's membership
                                      is very likely already stale.
      MEMBEROF_AU_FOUND            - A dynamic administrative unit's
                                      membershipRule references memberOf.
      MEMBEROF_AU_ALREADY_FROZEN   - Same, past the deadline.
      MEMBEROF_POLICY_FOUND        - An entitlement management automatic
                                      assignment policy's membershipRule
                                      references memberOf.
      MEMBEROF_POLICY_QUARANTINED  - Same, past the deadline -- assignment
                                      processing for this policy has halted.
      SOLE_ASSIGNMENT_POLICY       - A flagged auto-assignment policy is the
                                      ONLY assignment policy on its access
                                      package -- rewriting or removing it
                                      without a replacement will silently
                                      stop all future assignments to that
                                      package.

    Read-only. Makes no changes to any group, administrative unit, or
    assignment policy.

    Does NOT cover:
    - Rewriting or migrating any flagged rule (see MemberOfRetirement-B.md
      Fix 1-3 and MemberOfRetirement-A.md Playbook 1-3 for remediation)
    - Nested/transitive membership analysis of the source groups a
      memberOf rule references (memberOf itself only evaluates direct
      membership -- this script reports rule TEXT, not resolved membership)
    - Historical drift analysis (how long a frozen group has actually been
      stale) -- Entra does not expose a "last rule evaluation" timestamp
      for this purpose; use audit log sign-in/group-membership-change
      history for that investigation if needed

.PARAMETER DeadlineDate
    The retirement cutover date used to classify findings as "at risk"
    (pre-deadline) vs. "already frozen/quarantined" (post-deadline).
    Default: 2026-11-03 (per MC1448379).

.PARAMETER SkipEntitlementManagement
    When set, skips the entitlement management auto-assignment policy
    sweep (e.g., tenant has no Entra ID Governance/Entra Suite license
    and the Graph calls would only return permission errors).
    Default: $false

.PARAMETER OutputPath
    Directory where CSV reports will be written.
    Default: .\MemberOfRuleAudit-<timestamp>\

.EXAMPLE
    .\Get-MemberOfRuleAudit.ps1

    Full tenant-wide sweep of dynamic groups, dynamic administrative units,
    and entitlement management auto-assignment policies for memberOf usage.

.EXAMPLE
    .\Get-MemberOfRuleAudit.ps1 -SkipEntitlementManagement -DeadlineDate "2026-11-03"

    Groups/AUs only, explicit deadline date (useful if this script is kept
    in use past the original deadline for historical reference).

.NOTES
    Requires: Microsoft.Graph PowerShell SDK (v1.0/GA cmdlets only --
              no .Beta module required for this specific audit)
              Install-Module Microsoft.Graph -Scope CurrentUser
    Scopes needed: Group.Read.All, AdministrativeUnit.Read.All,
                   EntitlementManagement.Read.All (unless
                   -SkipEntitlementManagement is used)
    Run As: Global Reader (read only) is sufficient for every check here
    Safe: Read-only -- no group, administrative unit, or assignment policy
          is modified
    Cross-references: EntraID/Troubleshooting/MemberOfRetirement-A.md
                       (Dependency Stack, Symptom -> Cause Map, Validation
                       Steps), MemberOfRetirement-B.md (Triage, Fix 1-5)
#>

[CmdletBinding()]
param(
    [datetime]$DeadlineDate = [datetime]"2026-11-03",

    [switch]$SkipEntitlementManagement,

    [string]$OutputPath = ".\MemberOfRuleAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        $scopes = @("Group.Read.All", "AdministrativeUnit.Read.All")
        if (-not $SkipEntitlementManagement) { $scopes += "EntitlementManagement.Read.All" }
        Connect-MgGraph -Scopes $scopes -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

if (-not (Get-Command Get-MgGroup -EA SilentlyContinue)) {
    Write-Status "Microsoft.Graph module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph -Scope CurrentUser" "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$findings = New-Object System.Collections.Generic.List[object]
$daysLeft = [math]::Round(($DeadlineDate - (Get-Date)).TotalDays, 1)
$pastDeadline = $daysLeft -le 0

Write-Status "Deadline: $($DeadlineDate.ToString('yyyy-MM-dd')) | Days remaining: $daysLeft | Past deadline: $pastDeadline" "INFO"

# --- 1. Dynamic groups using memberOf ---
Write-Status "Sweeping dynamic membership groups for memberOf usage..." "INFO"
$memberOfGroups = @()
try {
    $allDynamicGroups = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=groupTypes/any(c:c eq 'DynamicMembership')&`$select=id,displayName,membershipRule,membershipRuleProcessingState&`$top=999"
    $memberOfGroups = $allDynamicGroups | Where-Object { $_.membershipRule -and $_.membershipRule -match '(?i)memberof' }
} catch {
    Write-Status "Failed to retrieve dynamic groups: $($_.Exception.Message)" "ERROR"
}

foreach ($g in $memberOfGroups) {
    $flag = if ($pastDeadline) { "MEMBEROF_GROUP_ALREADY_FROZEN" } else { "MEMBEROF_GROUP_FOUND" }
    $severity = if ($pastDeadline) { "CRITICAL" } else { "WARN" }
    $findings.Add([pscustomobject]@{
        Flag = $flag; Severity = $severity
        ObjectType = "Dynamic Group"
        Object = "$($g.displayName) ($($g.id))"
        Detail = "MembershipRuleProcessingState='$($g.membershipRuleProcessingState)' (NOTE: this property does not reflect memberOf retirement status). Rule: $($g.membershipRule)"
    })
}
Write-Status "Found $($memberOfGroups.Count) dynamic group(s) using memberOf." $(if ($memberOfGroups.Count -gt 0) { "WARN" } else { "OK" })
$memberOfGroups | Select-Object displayName, id, membershipRuleProcessingState, membershipRule |
    Export-Csv "$OutputPath\memberof_groups.csv" -NoTypeInformation

# --- 2. Dynamic administrative units using memberOf ---
Write-Status "Sweeping dynamic administrative units for memberOf usage..." "INFO"
$memberOfAUs = @()
try {
    $allAUs = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits?`$select=id,displayName,membershipType,membershipRule&`$top=999"
    $memberOfAUs = $allAUs | Where-Object { $_.membershipType -eq 'Dynamic' -and $_.membershipRule -and $_.membershipRule -match '(?i)memberof' }
} catch {
    Write-Status "Failed to retrieve administrative units: $($_.Exception.Message)" "ERROR"
}

foreach ($au in $memberOfAUs) {
    $flag = if ($pastDeadline) { "MEMBEROF_AU_ALREADY_FROZEN" } else { "MEMBEROF_AU_FOUND" }
    $severity = if ($pastDeadline) { "CRITICAL" } else { "WARN" }
    $findings.Add([pscustomobject]@{
        Flag = $flag; Severity = $severity
        ObjectType = "Dynamic Administrative Unit"
        Object = "$($au.displayName) ($($au.id))"
        Detail = "AU-scoped role assignments now apply to a $(if ($pastDeadline) {'FROZEN'} else {'soon-to-freeze'}) population. Rule: $($au.membershipRule)"
    })
}
Write-Status "Found $($memberOfAUs.Count) dynamic administrative unit(s) using memberOf." $(if ($memberOfAUs.Count -gt 0) { "WARN" } else { "OK" })
$memberOfAUs | Select-Object displayName, id, membershipRule |
    Export-Csv "$OutputPath\memberof_administrative_units.csv" -NoTypeInformation

# --- 3. Entitlement management automatic assignment policies using memberOf ---
$memberOfPolicies = @()
if (-not $SkipEntitlementManagement) {
    Write-Status "Sweeping entitlement management automatic assignment policies for memberOf usage..." "INFO"
    try {
        $allPolicies = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies?`$expand=accessPackage&`$top=50"

        foreach ($p in $allPolicies) {
            if (-not $p.automaticRequestSettings) { continue }
            foreach ($t in @($p.specificAllowedTargets)) {
                if ([string]$t.'@odata.type' -like '*attributeRuleMembers*' -and [string]$t.membershipRule -match '(?i)memberof') {
                    $memberOfPolicies += [pscustomobject]@{
                        AccessPackageName = $p.accessPackage.displayName
                        AccessPackageId   = $p.accessPackage.id
                        PolicyName        = $p.displayName
                        PolicyId          = $p.id
                        MembershipRule    = [string]$t.membershipRule
                    }
                }
            }
        }
    } catch {
        Write-Status "Failed to retrieve entitlement management assignment policies (may lack Entra ID Governance/Entra Suite license, or EntitlementManagement.Read.All scope): $($_.Exception.Message)" "WARN"
    }

    foreach ($pol in $memberOfPolicies) {
        $flag = if ($pastDeadline) { "MEMBEROF_POLICY_QUARANTINED" } else { "MEMBEROF_POLICY_FOUND" }
        $severity = if ($pastDeadline) { "CRITICAL" } else { "WARN" }
        $findings.Add([pscustomobject]@{
            Flag = $flag; Severity = $severity
            ObjectType = "Entitlement Management Auto-Assignment Policy"
            Object = "$($pol.AccessPackageName) / $($pol.PolicyName)"
            Detail = "$(if ($pastDeadline) {'Assignment processing HALTED (quarantined) -- no additions or removals occurring.'} else {'Will be quarantined at the deadline.'}) Rule: $($pol.MembershipRule)"
        })

        # Blast-radius check: is this the only assignment policy on the access package?
        try {
            $siblingPolicies = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/$($pol.AccessPackageId)/assignmentPolicies").value
            if (@($siblingPolicies).Count -le 1) {
                $findings.Add([pscustomobject]@{
                    Flag = "SOLE_ASSIGNMENT_POLICY"; Severity = "WARN"
                    ObjectType = "Entitlement Management Access Package"
                    Object = $pol.AccessPackageName
                    Detail = "The flagged policy '$($pol.PolicyName)' is the ONLY assignment policy on this access package. Rewriting or removing it without a replacement assignment method in place will silently stop all future assignments to this package."
                })
            }
        } catch {
            Write-Status "  Could not check sibling policies for access package $($pol.AccessPackageId): $($_.Exception.Message)" "WARN"
        }
    }
    Write-Status "Found $($memberOfPolicies.Count) automatic assignment policy(ies) using memberOf." $(if ($memberOfPolicies.Count -gt 0) { "WARN" } else { "OK" })
    $memberOfPolicies | Export-Csv "$OutputPath\memberof_assignment_policies.csv" -NoTypeInformation
} else {
    Write-Status "Skipping entitlement management sweep (-SkipEntitlementManagement)." "INFO"
}

$findings | Export-Csv "$OutputPath\findings.csv" -NoTypeInformation

# --- Summary ---
Write-Host ""
Write-Status "=== memberOf Retirement Exposure Summary ===" "INFO"
$critical = @($findings | Where-Object Severity -eq "CRITICAL").Count
$warn     = @($findings | Where-Object Severity -eq "WARN").Count

Write-Status "Deadline: $($DeadlineDate.ToString('yyyy-MM-dd')) ($daysLeft day(s) remaining, past deadline: $pastDeadline)" "INFO"
Write-Status "Dynamic groups using memberOf: $($memberOfGroups.Count)" "INFO"
Write-Status "Dynamic administrative units using memberOf: $($memberOfAUs.Count)" "INFO"
Write-Status "Entitlement management auto-assignment policies using memberOf: $($memberOfPolicies.Count)" "INFO"
Write-Status "Critical findings (already frozen/quarantined): $critical" $(if ($critical -gt 0) { "ERROR" } else { "OK" })
Write-Status "Warnings (at-risk before deadline, or sole-policy blast-radius): $warn" $(if ($warn -gt 0) { "WARN" } else { "OK" })
Write-Status "Reports written to: $OutputPath" "INFO"

if ($critical -eq 0 -and $warn -eq 0) {
    Write-Status "No memberOf usage found across groups, administrative units, or entitlement management policies." "OK"
} else {
    Write-Status "Remediate every finding per MemberOfRetirement-B.md (Fix 1-5) before the deadline. See MemberOfRetirement-A.md Playbook 1-3 for migration depth." "WARN"
}
