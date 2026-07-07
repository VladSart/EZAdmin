<#
.SYNOPSIS
    Audits all Granular Delegated Admin Privileges (GDAP) relationships from the
    PARTNER tenant's perspective — lifecycle state, Auto Extend coverage, Access
    Assignment health, and (optionally) guest-account contamination in the
    security groups that back each access assignment.

.DESCRIPTION
    Connects to Microsoft Graph as a partner Admin Agent and:
      1. Enumerates every GDAP relationship and its lifecycle state
      2. Flags relationships approaching expiry with no Auto Extend configured
      3. Flags approval-pending requests aging toward the 90-day hard expiry
      4. Flags relationships that include the Global Administrator role, since
         those can never be Auto Extended and require manual renewal tracking
      5. Enumerates Access Assignments per relationship and flags any not in
         an "active" provisioning state
      6. (Unless -SkipGroupMembershipCheck) enumerates the members of every
         security group used in an Access Assignment and flags guest accounts,
         which silently break GDAP access with no error message anywhere

    Analysis flags applied:
      EXPIRING_SOON              - Active relationship's EndDateTime is within
                                    -ExpiringWithinDays and AutoExtendDuration is
                                    not set — this relationship will go dark with
                                    no further warning beyond Partner Center's own
                                    notifications
      GLOBAL_ADMIN_NO_AUTOEXTEND - Relationship includes the Global Administrator
                                    role. These can never Auto Extend by design —
                                    always surfaced regardless of expiry proximity
                                    so it can be tracked for manual renewal
      APPROVAL_PENDING_STALE     - Status is approvalPending and has been for
                                    longer than -ApprovalPendingStaleDays (default
                                    60) — heading toward the 90-day hard expiry
                                    with no customer action taken yet
      TERMINATED_OR_EXPIRED      - Relationship is no longer active. Informational
                                    — confirms current state for relationships that
                                    may still be referenced in tickets/runbooks
      ACCESS_ASSIGNMENT_NOT_ACTIVE - An access assignment under an active
                                    relationship is not in "active" status (still
                                    provisioning, or failed) — the mapped group's
                                    members will not actually have effective access
                                    until this clears
      GUEST_MEMBER_IN_GROUP      - A user with UserType = Guest was found as a
                                    member of a security group used in an Access
                                    Assignment. GDAP does not honor guest members
                                    for this purpose; access silently fails for them
      GROUP_COUNT_NEAR_LIMIT     - A customer has 90+ distinct security groups
                                    mapped across their Access Assignments,
                                    approaching the documented 100-group-per-customer
                                    ceiling

    Read-only. Makes no changes to any relationship, access assignment, or group.

    Does NOT cover:
    - Anything enforced inside the CUSTOMER tenant (Conditional Access, sign-in
      risk policies, license/service-plan gaps) — this script only has visibility
      into partner-tenant GDAP objects, consistent with where these objects live.
      See GDAP-A.md Phase 4 for customer-tenant-side checks.
    - Azure RBAC role assignments layered on top of a GDAP-derived Entra role
      (e.g. the "Azure Managers" group pattern) — that's an Azure subscription-level
      construct outside the Microsoft Graph partner/delegatedAdminRelationships
      surface this script queries.
    - Recreating, approving, or terminating relationships — audit only. See
      GDAP-A.md Remediation Playbooks for the write-side commands.

.PARAMETER CustomerFilter
    Optional. Only include relationships whose customer display name contains
    this substring (case-insensitive). Default: all customers.

.PARAMETER ExpiringWithinDays
    Number of days out to flag an active relationship as EXPIRING_SOON if it has
    no Auto Extend configured. Default: 30.

.PARAMETER ApprovalPendingStaleDays
    Number of days after creation to flag an approvalPending relationship as
    APPROVAL_PENDING_STALE (a warning ahead of the hard 90-day expiry).
    Default: 60.

.PARAMETER SkipGroupMembershipCheck
    Switch. If set, skips the per-security-group membership/guest-account check
    (faster, but misses the single most common silent-failure cause covered in
    GDAP-B.md Fix 3 / GDAP-A.md Playbook 3).

.PARAMETER OutputPath
    Folder to write the CSV reports to. Default: current directory.

.EXAMPLE
    .\Get-GDAPRelationshipAudit.ps1
    Full audit of every GDAP relationship, including group membership checks.

.EXAMPLE
    .\Get-GDAPRelationshipAudit.ps1 -CustomerFilter "Contoso" -ExpiringWithinDays 45 -OutputPath "C:\Temp"
    Audit only relationships for customers matching "Contoso", using a 45-day
    expiry-warning window, writing reports to C:\Temp.

.NOTES
    Requires: Microsoft.Graph.Identity.Partner (and Microsoft.Graph.Users /
    Microsoft.Graph.Groups for the membership check) PowerShell modules.
    Run as: a user with the Admin Agent role in the PARTNER (CSP) tenant.
    Required Graph scopes: DelegatedAdminRelationship.Read.All, GroupMember.Read.All,
    User.Read.All (the last two only needed unless -SkipGroupMembershipCheck).
    Safe/unsafe: fully read-only — no New-/Update-/Remove- calls anywhere in this
    script.
#>

[CmdletBinding()]
param(
    [string]$CustomerFilter = "",
    [int]$ExpiringWithinDays = 30,
    [int]$ApprovalPendingStaleDays = 60,
    [switch]$SkipGroupMembershipCheck,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Global Administrator built-in role template ID (constant across all Entra tenants)
$script:GlobalAdminRoleId = "62e90394-69f5-4237-9190-012177145e10"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ── Preflight ────────────────────────────────────────────────────────────────

Write-Status "Checking for required Microsoft Graph modules..."
$requiredModules = @("Microsoft.Graph.Identity.Partner")
if (-not $SkipGroupMembershipCheck) {
    $requiredModules += @("Microsoft.Graph.Groups", "Microsoft.Graph.Users")
}

foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Required module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
        throw "Missing required module: $mod"
    }
}

if (-not (Get-MgContext)) {
    Write-Status "Not connected to Microsoft Graph. Connecting now..." "WARN"
    $scopes = @("DelegatedAdminRelationship.Read.All")
    if (-not $SkipGroupMembershipCheck) { $scopes += @("GroupMember.Read.All", "User.Read.All") }
    Connect-MgGraph -Scopes $scopes -NoWelcome
}

$context = Get-MgContext
Write-Status "Connected to tenant: $($context.TenantId)" "OK"

if (-not (Test-Path $OutputPath)) {
    Write-Status "Output path '$OutputPath' does not exist — creating it." "WARN"
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ── Detect ───────────────────────────────────────────────────────────────────

Write-Status "Retrieving all GDAP relationships..."
$allRelationships = @(Get-MgTenantRelationshipDelegatedAdminRelationship -All -ErrorAction Stop)

if ($CustomerFilter) {
    $allRelationships = @($allRelationships | Where-Object {
        $_.Customer -and $_.Customer.DisplayName -like "*$CustomerFilter*"
    })
    Write-Status "Filtered to $($allRelationships.Count) relationship(s) matching customer filter '$CustomerFilter'."
} else {
    Write-Status "Found $($allRelationships.Count) total relationship(s)."
}

if ($allRelationships.Count -eq 0) {
    Write-Status "No relationships found to audit. Exiting." "WARN"
    return
}

# ── Execute — relationship-level analysis ─────────────────────────────────────

$relationshipReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$groupsToCheck      = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()  # groupId -> list of customer names using it

foreach ($rel in $allRelationships) {

    $flags = [System.Collections.Generic.List[string]]::new()

    $customerName = if ($rel.Customer) { $rel.Customer.DisplayName } else { "<unknown>" }
    $customerId   = if ($rel.Customer) { $rel.Customer.TenantId } else { "<unknown>" }

    $roleIds = @()
    if ($rel.AccessDetails -and $rel.AccessDetails.UnifiedRoles) {
        $roleIds = @($rel.AccessDetails.UnifiedRoles | ForEach-Object { $_.RoleDefinitionId })
    }
    $hasGlobalAdmin = $roleIds -contains $script:GlobalAdminRoleId

    $endDate    = $rel.EndDateTime
    $autoExtend = $rel.AutoExtendDuration
    $status     = $rel.Status
    $created    = $rel.CreatedDateTime

    switch -Regex ($status) {
        "^(terminated|expired)$" {
            $flags.Add("TERMINATED_OR_EXPIRED")
        }
        "^approvalPending$" {
            if ($created -and ((Get-Date) - $created).TotalDays -ge $ApprovalPendingStaleDays) {
                $ageDays = [math]::Round(((Get-Date) - $created).TotalDays, 0)
                $flags.Add("APPROVAL_PENDING_STALE (age: $ageDays days)")
            }
        }
        "^active$" {
            if ($endDate -and ($endDate - (Get-Date)).TotalDays -le $ExpiringWithinDays -and (-not $autoExtend -or $autoExtend -eq "PT0S" -or $autoExtend -eq "P0D")) {
                $daysLeft = [math]::Round(($endDate - (Get-Date)).TotalDays, 0)
                $flags.Add("EXPIRING_SOON (days left: $daysLeft, no Auto Extend)")
            }
            if ($hasGlobalAdmin) {
                $flags.Add("GLOBAL_ADMIN_NO_AUTOEXTEND")
            }
        }
    }

    # Access assignments for this relationship
    $assignmentSummaries = @()
    try {
        $assignments = @(Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId $rel.Id -ErrorAction Stop)
        foreach ($a in $assignments) {
            $assignmentSummaries += "$($a.AccessContainer.AccessContainerId):$($a.Status)"
            if ($a.Status -ne "active" -and $status -eq "active") {
                $flags.Add("ACCESS_ASSIGNMENT_NOT_ACTIVE ($($a.AccessContainer.AccessContainerId) = $($a.Status))")
            }
            if ($a.AccessContainer -and $a.AccessContainer.AccessContainerType -eq "securityGroup") {
                $gid = $a.AccessContainer.AccessContainerId
                if (-not $groupsToCheck.ContainsKey($gid)) {
                    $groupsToCheck[$gid] = [System.Collections.Generic.List[string]]::new()
                }
                $groupsToCheck[$gid].Add($customerName)
            }
        }
    } catch {
        $assignmentSummaries = @("ERROR: $($_.Exception.Message)")
        Write-Status "Could not retrieve access assignments for relationship '$($rel.DisplayName)': $($_.Exception.Message)" "WARN"
    }

    $relationshipReport.Add([PSCustomObject]@{
        RelationshipId   = $rel.Id
        DisplayName      = $rel.DisplayName
        CustomerName     = $customerName
        CustomerTenantId = $customerId
        Status           = $status
        CreatedDateTime  = $created
        EndDateTime      = $endDate
        AutoExtendDuration = $autoExtend
        RoleCount        = $roleIds.Count
        HasGlobalAdmin   = $hasGlobalAdmin
        AccessAssignments = ($assignmentSummaries -join "; ")
        Flags            = ($flags -join "; ")
    })
}

# Flag customers approaching the 100-security-group ceiling
$groupCountByCustomer = @{}
foreach ($kvp in $groupsToCheck.GetEnumerator()) {
    foreach ($cust in ($kvp.Value | Select-Object -Unique)) {
        if (-not $groupCountByCustomer.ContainsKey($cust)) { $groupCountByCustomer[$cust] = 0 }
        $groupCountByCustomer[$cust]++
    }
}
$nearLimitCustomers = $groupCountByCustomer.GetEnumerator() | Where-Object { $_.Value -ge 90 }
foreach ($nc in $nearLimitCustomers) {
    Write-Status "Customer '$($nc.Key)' has $($nc.Value) distinct GDAP security groups — approaching the 100-group ceiling (GROUP_COUNT_NEAR_LIMIT)." "WARN"
}

# ── Execute — group membership / guest-account analysis ──────────────────────

$groupMembershipReport = [System.Collections.Generic.List[PSCustomObject]]::new()

if (-not $SkipGroupMembershipCheck) {
    Write-Status "Checking membership of $($groupsToCheck.Count) unique security group(s) used in Access Assignments..."

    foreach ($gid in $groupsToCheck.Keys) {
        try {
            $members = @(Get-MgGroupMember -GroupId $gid -All -ErrorAction Stop)
            foreach ($m in $members) {
                $userType = "unknown"
                try {
                    $u = Get-MgUser -UserId $m.Id -Property "UserPrincipalName,UserType" -ErrorAction Stop
                    $userType = $u.UserType
                    $upn = $u.UserPrincipalName
                } catch {
                    $upn = "<could not resolve — may not be a user object>"
                }

                $flag = if ($userType -eq "Guest") { "GUEST_MEMBER_IN_GROUP" } else { "" }
                if ($flag) {
                    Write-Status "Guest account '$upn' found in GDAP-mapped group $gid (customers: $($groupsToCheck[$gid] -join ', '))" "WARN"
                }

                $groupMembershipReport.Add([PSCustomObject]@{
                    SecurityGroupId = $gid
                    CustomersUsingGroup = ($groupsToCheck[$gid] -join "; ")
                    MemberUPN       = $upn
                    UserType        = $userType
                    Flag            = $flag
                })
            }
        } catch {
            Write-Status "Could not enumerate members of group $gid : $($_.Exception.Message)" "WARN"
            $groupMembershipReport.Add([PSCustomObject]@{
                SecurityGroupId = $gid
                CustomersUsingGroup = ($groupsToCheck[$gid] -join "; ")
                MemberUPN       = "<error>"
                UserType        = "<error>"
                Flag            = "GROUP_ENUMERATION_ERROR: $($_.Exception.Message)"
            })
        }
    }
} else {
    Write-Status "Skipping group membership check (-SkipGroupMembershipCheck set)." "WARN"
}

# ── Validate & Report ──────────────────────────────────────────────────────────

$relPath = Join-Path $OutputPath "GDAP-Relationship-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
$relationshipReport | Export-Csv -Path $relPath -NoTypeInformation
Write-Status "Relationship report written to: $relPath" "OK"

if (-not $SkipGroupMembershipCheck) {
    $memberPath = Join-Path $OutputPath "GDAP-GroupMembership-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
    $groupMembershipReport | Export-Csv -Path $memberPath -NoTypeInformation
    Write-Status "Group membership report written to: $memberPath" "OK"
}

$flaggedCount = ($relationshipReport | Where-Object { $_.Flags -ne "" }).Count
$guestCount   = ($groupMembershipReport | Where-Object { $_.Flag -eq "GUEST_MEMBER_IN_GROUP" }).Count

Write-Status "Audit complete. $flaggedCount of $($relationshipReport.Count) relationship(s) flagged." "OK"
if ($guestCount -gt 0) {
    Write-Status "$guestCount guest account(s) found in GDAP-mapped security groups — these members have broken (silently failing) access. See GDAP-B.md Fix 3." "WARN"
}
if ($nearLimitCustomers) {
    Write-Status "$(@($nearLimitCustomers).Count) customer(s) approaching the 100-security-group ceiling." "WARN"
}

$relationshipReport | Format-Table -Property DisplayName, CustomerName, Status, EndDateTime, Flags -AutoSize
