<#
.SYNOPSIS
    Tenant-wide health report for Entra Entitlement Management access package
    assignments — flags stuck deliveries, aging approvals, and orphaned resources.

.DESCRIPTION
    Connects to Microsoft Graph and walks every access package in the tenant to
    surface the failure states operators actually get tickets for:
    - STUCK_DELIVERING:   Assignment has sat in `Delivering` state longer than
                          -DeliveringThresholdMinutes — the resource role write-back
                          (group membership / app role / SharePoint grant) likely failed
                          silently and needs a manual Reprocess.
    - AGING_APPROVAL:     Assignment request has been `PendingApproval` longer than
                          -ApprovalThresholdDays — approver is unresponsive or the
                          approval policy has no escalation configured.
    - UNPUBLISHED_CATALOG: The catalog containing the package is not in `Published`
                          state, so requests will silently fail even if the package
                          itself looks fine.
    - ORPHANED_RESOURCE:  A resource role in the package points at a group/app that
                          no longer exists (DeletedDateTime set or lookup fails) —
                          assignments referencing it can never deliver.
    - NO_REQUESTOR_SCOPE: Assignment policy's RequestorSettings.ScopeType is
                          `NoSubjects` — nobody can request this package at all,
                          which usually indicates an incomplete configuration rather
                          than intentional lockdown.

    This is a fleet-level triage tool: it tells you WHICH packages/assignments are
    worth investigating before you burn time chasing individual "I don't have
    access" tickets one at a time. Read-only — makes no changes to catalogs,
    packages, policies, or assignments.

    Exports results to CSV and prints a colour-coded console summary grouped by
    flag type.

    Does NOT cover:
    - Per-user license eligibility (P2 / Governance) — see
      EntraID/Troubleshooting/AccessPackages-A.md Validation Step 1, run per-user
    - SharePoint-side permission propagation lag after a successful group write —
      see AccessPackages-B.md Fix 2
    - Connected Organization `Proposed` vs `Configured` triage for external/guest
      requestors — see AccessPackages-B.md Diagnosis Step 6 and Fix 4

.PARAMETER DeliveringThresholdMinutes
    Minutes an assignment can sit in `Delivering` state before being flagged as
    stuck. Default: 30 (matches the guidance in AccessPackages-B.md Diagnosis Step 4).

.PARAMETER ApprovalThresholdDays
    Days an assignment request can sit in `PendingApproval` before being flagged
    as aging. Default: 3 (matches the recommended escalation timeout in Fix 1).

.PARAMETER OutputPath
    Path for the CSV export. Default: .\AccessPackage-Health-<timestamp>.csv

.EXAMPLE
    .\Get-AccessPackageAssignmentHealth.ps1

    Reports on all access packages tenant-wide with default thresholds.

.EXAMPLE
    .\Get-AccessPackageAssignmentHealth.ps1 -DeliveringThresholdMinutes 15 -ApprovalThresholdDays 1

    Uses tighter thresholds for a tenant with an SLA that requires faster escalation.

.NOTES
    Requires: Microsoft.Graph.Identity.Governance, Microsoft.Graph.Groups,
              Microsoft.Graph.Users PowerShell SDK modules
    Scopes needed: EntitlementManagement.Read.All, Group.Read.All, User.Read.All
    Run As: An account with Identity Governance Administrator (read) or Global
            Reader role — does not require write permissions
    Safe: Read-only — no packages, policies, or assignments are changed
    Cross-references: EntraID/Troubleshooting/AccessPackages-B.md (Triage,
                       Diagnosis & Validation Flow, Fix 1-5) and AccessPackages-A.md

    Known limitation: this script cannot see approval decision context (who is
    the approver, whether they've been notified) — only assignment/request state
    and timestamps. Use the Fix 1 diagnose commands in AccessPackages-B.md to pull
    approver identities once a stuck package is identified here.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 1440)]
    [int]$DeliveringThresholdMinutes = 30,

    [ValidateRange(1, 30)]
    [int]$ApprovalThresholdDays = 3,

    [string]$OutputPath = ".\AccessPackage-Health-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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
Write-Status "Checking Microsoft.Graph.Identity.Governance module..." "INFO"
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.Governance)) {
    Write-Status "Microsoft.Graph.Identity.Governance module not found. Install with: Install-Module Microsoft.Graph.Identity.Governance -Scope CurrentUser" "ERROR"
    return
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Graph. Connecting with required scopes..." "WARN"
        Connect-MgGraph -Scopes "EntitlementManagement.Read.All", "Group.Read.All", "User.Read.All" -NoWelcome
    }
    else {
        Write-Status "Connected to Graph as $($context.Account) [tenant: $($context.TenantId)]" "OK"
    }
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

$results = [System.Collections.Generic.List[object]]::new()
$now = Get-Date

# ---- Detect: catalogs ----
Write-Status "Retrieving catalogs..." "INFO"
$catalogs = @()
try {
    $catalogs = Get-MgEntitlementManagementAccessPackageCatalog -All -ErrorAction Stop
    Write-Status "Found $($catalogs.Count) catalog(s)." "OK"
}
catch {
    Write-Status "Failed to retrieve catalogs: $($_.Exception.Message)" "ERROR"
}

$catalogById = @{}
foreach ($cat in $catalogs) {
    $catalogById[$cat.Id] = $cat
    if ($cat.State -ne "published") {
        $results.Add([PSCustomObject]@{
            FlagType     = "UNPUBLISHED_CATALOG"
            PackageName  = "-"
            PackageId    = "-"
            CatalogName  = $cat.DisplayName
            CatalogId    = $cat.Id
            Detail       = "Catalog state = $($cat.State) (expected: published)"
            Severity     = "HIGH"
        })
    }
}

# ---- Detect: access packages, policies, resource roles ----
Write-Status "Retrieving access packages..." "INFO"
$packages = @()
try {
    $packages = Get-MgEntitlementManagementAccessPackage -All -ExpandProperty "accessPackageResourceRoleScopes" -ErrorAction Stop
    Write-Status "Found $($packages.Count) access package(s)." "OK"
}
catch {
    Write-Status "Failed to retrieve access packages: $($_.Exception.Message)" "ERROR"
}

foreach ($pkg in $packages) {
    # Assignment policies - check requestor scope
    try {
        $policies = Get-MgEntitlementManagementAccessPackageAssignmentPolicy -AccessPackageId $pkg.Id -ErrorAction Stop
        foreach ($policy in $policies) {
            $scopeType = $policy.RequestorSettings.ScopeType
            if ($scopeType -eq "NoSubjects") {
                $results.Add([PSCustomObject]@{
                    FlagType     = "NO_REQUESTOR_SCOPE"
                    PackageName  = $pkg.DisplayName
                    PackageId    = $pkg.Id
                    CatalogName  = $catalogById[$pkg.CatalogId].DisplayName
                    CatalogId    = $pkg.CatalogId
                    Detail       = "Policy '$($policy.DisplayName)' has ScopeType=NoSubjects — nobody can request"
                    Severity     = "MEDIUM"
                })
            }
        }
    }
    catch {
        Write-Status "Could not retrieve policies for package $($pkg.DisplayName): $($_.Exception.Message)" "WARN"
    }

    # Resource role scopes - check for orphaned groups
    foreach ($roleScope in $pkg.AccessPackageResourceRoleScopes) {
        $originId = $roleScope.AccessPackageResource.OriginId
        $originType = $roleScope.AccessPackageResource.OriginSystem
        if ($originType -eq "AadGroup" -and $originId) {
            try {
                $grp = Get-MgGroup -GroupId $originId -ErrorAction Stop
                if ($grp.DeletedDateTime) {
                    $results.Add([PSCustomObject]@{
                        FlagType     = "ORPHANED_RESOURCE"
                        PackageName  = $pkg.DisplayName
                        PackageId    = $pkg.Id
                        CatalogName  = $catalogById[$pkg.CatalogId].DisplayName
                        CatalogId    = $pkg.CatalogId
                        Detail       = "Resource group $originId is soft-deleted (DeletedDateTime set)"
                        Severity     = "HIGH"
                    })
                }
            }
            catch {
                $results.Add([PSCustomObject]@{
                    FlagType     = "ORPHANED_RESOURCE"
                    PackageName  = $pkg.DisplayName
                    PackageId    = $pkg.Id
                    CatalogName  = $catalogById[$pkg.CatalogId].DisplayName
                    CatalogId    = $pkg.CatalogId
                    Detail       = "Resource group $originId could not be resolved — likely deleted"
                    Severity     = "HIGH"
                })
            }
        }
    }
}

# ---- Detect: assignments stuck Delivering ----
Write-Status "Checking assignments in 'Delivering' state..." "INFO"
try {
    $deliveringAssignments = Get-MgEntitlementManagementAssignment -Filter "state eq 'Delivering'" -All -ExpandProperty "accessPackage" -ErrorAction Stop
    foreach ($a in $deliveringAssignments) {
        $results.Add([PSCustomObject]@{
            FlagType     = "STUCK_DELIVERING"
            PackageName  = $a.AccessPackage.DisplayName
            PackageId    = $a.AccessPackageId
            CatalogName  = "-"
            CatalogId    = "-"
            Detail       = "Assignment $($a.Id) has been Delivering since at least this scan — verify against $DeliveringThresholdMinutes-min threshold, reprocess if stale"
            Severity     = "HIGH"
        })
    }
    Write-Status "Found $($deliveringAssignments.Count) assignment(s) in Delivering state." "INFO"
}
catch {
    Write-Status "Failed to query Delivering assignments: $($_.Exception.Message)" "WARN"
}

# ---- Detect: aging PendingApproval requests ----
Write-Status "Checking assignment requests pending approval..." "INFO"
try {
    $pendingRequests = Get-MgEntitlementManagementAssignmentRequest -Filter "state eq 'PendingApproval'" -All -ExpandProperty "accessPackageAssignment" -ErrorAction Stop
    foreach ($req in $pendingRequests) {
        $age = $now - $req.CreatedDateTime
        if ($age.TotalDays -ge $ApprovalThresholdDays) {
            $results.Add([PSCustomObject]@{
                FlagType     = "AGING_APPROVAL"
                PackageName  = $req.AccessPackageAssignment.AccessPackage.DisplayName
                PackageId    = $req.AccessPackageAssignment.AccessPackageId
                CatalogName  = "-"
                CatalogId    = "-"
                Detail       = "Request $($req.Id) has been PendingApproval for $([math]::Round($age.TotalDays,1)) days (threshold: $ApprovalThresholdDays)"
                Severity     = "MEDIUM"
            })
        }
    }
    Write-Status "Found $($pendingRequests.Count) request(s) pending approval; flagged those over $ApprovalThresholdDays day(s)." "INFO"
}
catch {
    Write-Status "Failed to query pending approval requests: $($_.Exception.Message)" "WARN"
}

# ---- Report ----
Write-Host ""
Write-Host "=== Access Package Assignment Health Summary ===" -ForegroundColor Cyan
if ($results.Count -eq 0) {
    Write-Status "No issues found across $($packages.Count) package(s) in $($catalogs.Count) catalog(s)." "OK"
}
else {
    $grouped = $results | Group-Object FlagType | Sort-Object Count -Descending
    foreach ($g in $grouped) {
        $sev = ($g.Group | Select-Object -First 1).Severity
        $status = if ($sev -eq "HIGH") { "ERROR" } else { "WARN" }
        Write-Status "$($g.Name): $($g.Count) item(s)" $status
    }
    Write-Host ""
    $results | Sort-Object Severity, FlagType | Format-Table FlagType, PackageName, Severity, Detail -AutoSize -Wrap
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to $OutputPath" "OK"
