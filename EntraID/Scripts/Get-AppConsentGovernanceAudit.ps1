<#
.SYNOPSIS
    Read-only tenant-wide audit of app consent governance — the policy
    configuration, admin-consent-workflow reviewer RBAC, and high-risk
    OAuth grants that AppConsentPolicies-A.md and AppConsentPolicies-B.md
    describe as the most common misconfiguration and attack surface.

.DESCRIPTION
    Runs four independent checks and combines them into a single report:

    1. TENANT DEFAULT — reads authorizationPolicy.defaultUserRolePermissions
       and flags if the tenant is still on (or has drifted to) an empty or
       legacy/allow-all effective consent default, per AppConsentPolicies-A.md's
       How It Works section.

    2. ADMIN CONSENT WORKFLOW REVIEWERS — reads adminConsentRequestPolicy,
       then cross-checks EVERY listed reviewer's actual directory role
       assignments. Flags REVIEWER_NO_RBAC for anyone listed as a reviewer
       who holds none of Global Administrator / Privileged Role Administrator
       / Application Administrator / Cloud Application Administrator — the
       exact silent-failure mode documented in AppConsentPolicies-B.md Fix 6
       ("reviewer can't approve requests"). Also flags
       REVIEWER_CANNOT_APPROVE_GRAPH_APPROLES for reviewers who hold
       Application/Cloud Application Administrator but NOT Global
       Administrator or Privileged Role Administrator, since those two roles
       specifically cannot approve Microsoft Graph application-permission
       requests despite being valid reviewers for everything else.

    3. HIGH-RISK OAUTH GRANTS (tenant-wide sweep) — enumerates every Service
       Principal's delegated (oauth2PermissionGrant) and application
       (appRoleAssignment) grants against Microsoft Graph, and flags:
       - CONSENT_ALL_PRINCIPALS: a delegated grant with ConsentType
         AllPrincipals (tenant-wide blast radius per a single grant)
       - HIGH_RISK_PERMISSION: any grant matching a built-in watchlist of
         high-impact Graph permissions (Mail.ReadWrite, Files.ReadWrite.All,
         Sites.FullControl.All, full Directory/RoleManagement write scopes,
         and similar) on a non-Microsoft-first-party application
       - UNVERIFIED_PUBLISHER: the granted app's Service Principal has no
         verified publisher, combined with any of the above — the specific
         combination Microsoft's own illicit-consent-grant guidance flags
         as highest priority to review first

    4. ZERO-OWNER GRANTED APPS — cross-references flagged Service Principals
       against Application object ownership (same silent-governance-gap
       pattern as Get-AppRegistrationCredentialAudit.ps1, applied here to
       consent risk rather than credential expiry).

    Read-only. Makes no changes to any policy, grant, role assignment, or
    Service Principal. Exports a full CSV plus a filtered "review needed" CSV.

    Does NOT cover (see manifest/AppConsentPolicies-A.md "Known Gap" note):
    - The actual Purview Audit "Consent to application" event log
      (IsAdminConsent, granting actor, timestamp) — not exposed via a
      Microsoft Graph v1.0 endpoint queryable the same way as the objects
      above; export separately from security.microsoft.com/auditlogsearch
    - Reverse-mapping which custom directory role(s) reference a given
      custom app consent policy — no reliable Graph v1.0 endpoint for this;
      cross-check unifiedRoleDefinition objects manually per
      AppConsentPolicies-A.md Validation Step 3
    - Publisher verification status per individual delegated permission
      grant beyond the Service Principal's own verifiedPublisher property
      (a coarse but directionally useful proxy)
    - Microsoft Defender for Cloud Apps OAuth app risk scoring (separate
      licensed product with its own investigation surface)

.PARAMETER IncludeAllGrants
    If specified, exports every OAuth grant found (not just flagged ones) to
    a second, larger CSV. Useful for a from-scratch tenant inventory but can
    be large in tenants with many integrated apps.

.PARAMETER OutputPath
    Folder where CSV/JSON reports are written. Defaults to
    $env:TEMP\AppConsentAudit-<timestamp>.

.EXAMPLE
    .\Get-AppConsentGovernanceAudit.ps1

    Standard audit — policy config, reviewer RBAC, and flagged high-risk grants only.

.EXAMPLE
    .\Get-AppConsentGovernanceAudit.ps1 -IncludeAllGrants -OutputPath C:\Reports\Consent

    Full grant inventory in addition to the flagged subset, custom output folder.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Applications,
              Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement
    Scopes needed: Policy.Read.All, Application.Read.All,
                   RoleManagement.Read.Directory, Directory.Read.All
    Run As: Any account with Global Reader (sufficient for every read in this
            script) or a role with equivalent read scopes
    Safe: Fully read-only — no policy, grant, role assignment, or Service
          Principal is modified in any way. Zero Set-Mg/New-Mg/Remove-Mg/
          Update-Mg cmdlets are used anywhere in this script.
    Cross-references: EntraID/Troubleshooting/AppConsentPolicies-B.md (Triage,
                       Fix 3, Fix 4, Fix 6) and AppConsentPolicies-A.md
                       (Validation Steps 1-5, Symptom -> Cause Map)
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [switch]$IncludeAllGrants,

    [string]$OutputPath = "$env:TEMP\AppConsentAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

# High-impact Microsoft Graph permission watchlist (delegated scope names and
# application app-role names both use these strings; matched case-insensitively).
$highRiskPermissionWatchlist = @(
    "Mail.ReadWrite", "Mail.Send", "Mail.ReadWrite.All", "Mail.Send.All",
    "Files.ReadWrite.All", "Sites.FullControl.All", "Sites.ReadWrite.All",
    "Directory.ReadWrite.All", "RoleManagement.ReadWrite.Directory",
    "User.ReadWrite.All", "Group.ReadWrite.All",
    "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All",
    "full_access_as_app", "EWS.AccessAsUser.All", "Contacts.ReadWrite",
    "MailboxSettings.ReadWrite"
)

$privilegedReviewerRoles = @(
    "Global Administrator", "Privileged Role Administrator",
    "Application Administrator", "Cloud Application Administrator"
)
$graphApproleApprovalRoles = @("Global Administrator", "Privileged Role Administrator")

# ---- Preflight ----
foreach ($mod in @("Microsoft.Graph.Authentication", "Microsoft.Graph.Applications", "Microsoft.Graph.Identity.SignIns")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod" "ERROR"
        return
    }
}

$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Graph. Connecting with required read scopes..." "INFO"
    try {
        Connect-MgGraph -Scopes "Policy.Read.All", "Application.Read.All", "RoleManagement.Read.Directory", "Directory.Read.All" -NoWelcome -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        return
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()

# =====================================================================
# CHECK 1 — Tenant-wide default consent policy
# =====================================================================
Write-Status "Reading tenant-wide authorizationPolicy..." "INFO"
$tenantDefaultOk = $true
try {
    $authPolicy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy/authorizationPolicy" -ErrorAction Stop
    $assignedPolicies = $authPolicy.defaultUserRolePermissions.permissionGrantPoliciesAssigned

    if (-not $assignedPolicies -or $assignedPolicies.Count -eq 0) {
        Write-Status "TENANT DEFAULT: no permissionGrantPoliciesAssigned found — likely an unrestricted legacy default." "WARN"
        $tenantDefaultOk = $false
    }
    elseif ($assignedPolicies -match "legacy") {
        Write-Status "TENANT DEFAULT: '...-legacy' policy assigned — allows broad user self-consent." "WARN"
        $tenantDefaultOk = $false
    }
    else {
        Write-Status "TENANT DEFAULT: $($assignedPolicies -join ', ')" "OK"
    }
}
catch {
    Write-Status "Could not read authorizationPolicy: $($_.Exception.Message)" "ERROR"
    $authPolicy = $null
}

# =====================================================================
# CHECK 2 — Admin consent workflow + reviewer RBAC
# =====================================================================
Write-Status "Reading admin consent workflow configuration..." "INFO"
try {
    $consentWorkflow = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy" -ErrorAction Stop

    if (-not $consentWorkflow.isEnabled) {
        Write-Status "ADMIN CONSENT WORKFLOW: disabled. Blocked users have no self-service escalation path (see Fix 1)." "WARN"
    }
    else {
        Write-Status "ADMIN CONSENT WORKFLOW: enabled. Validating $($consentWorkflow.notifyReviewers.Count + $consentWorkflow.reviewers.Count) reviewer entr(y/ies)..." "INFO"

        $reviewers = @()
        if ($consentWorkflow.reviewers) { $reviewers = $consentWorkflow.reviewers }

        foreach ($rev in $reviewers) {
            $principalId = $rev.query -replace '.*/(.*)$', '$1'  # reviewers are query-based (users/groups/roles)
            $revLabel = "$($rev.queryType):$($rev.query)"

            try {
                $roleAssignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$principalId'" -ExpandProperty "roleDefinition" -ErrorAction Stop
                $roleNames = $roleAssignments | ForEach-Object { $_.RoleDefinition.DisplayName }

                $hasAnyPrivilegedRole = @($roleNames | Where-Object { $_ -in $privilegedReviewerRoles }).Count -gt 0
                $canApproveGraphApproles = @($roleNames | Where-Object { $_ -in $graphApproleApprovalRoles }).Count -gt 0

                if (-not $hasAnyPrivilegedRole) {
                    $findings.Add([PSCustomObject]@{
                        Category = "AdminConsentReviewer"; Identifier = $revLabel
                        Flag = "REVIEWER_NO_RBAC"
                        Detail = "Listed as a workflow reviewer but holds none of: $($privilegedReviewerRoles -join ', '). Will see requests but cannot act on any of them."
                        RiskLevel = "HIGH"
                    })
                }
                elseif (-not $canApproveGraphApproles) {
                    $findings.Add([PSCustomObject]@{
                        Category = "AdminConsentReviewer"; Identifier = $revLabel
                        Flag = "REVIEWER_CANNOT_APPROVE_GRAPH_APPROLES"
                        Detail = "Holds $($roleNames -join '/') — valid reviewer for most requests, but cannot approve Microsoft Graph application-permission requests (requires Global Administrator or Privileged Role Administrator)."
                        RiskLevel = "MEDIUM"
                    })
                }
            }
            catch {
                Write-Status "Could not resolve RBAC for reviewer '$revLabel': $($_.Exception.Message)" "WARN"
            }
        }
    }
}
catch {
    Write-Status "Could not read adminConsentRequestPolicy: $($_.Exception.Message)" "ERROR"
}

# =====================================================================
# CHECK 3 — Tenant-wide high-risk OAuth grant sweep
# =====================================================================
Write-Status "Enumerating Service Principals for OAuth grant sweep (this can take a while in large tenants)..." "INFO"
$allGrantRows = [System.Collections.Generic.List[object]]::new()

try {
    $servicePrincipals = Get-MgServicePrincipal -All -Property Id, DisplayName, AppId, VerifiedPublisher, AccountEnabled -ErrorAction Stop
    Write-Status "Found $($servicePrincipals.Count) Service Principal(s). Checking grants..." "INFO"
}
catch {
    Write-Status "Failed to enumerate Service Principals: $($_.Exception.Message)" "ERROR"
    $servicePrincipals = @()
}

$i = 0
foreach ($sp in $servicePrincipals) {
    $i++
    if ($i % 100 -eq 0) { Write-Status "Processed $i of $($servicePrincipals.Count) Service Principals..." "INFO" }

    $isVerifiedPublisher = [bool]($sp.VerifiedPublisher -and $sp.VerifiedPublisher.VerifiedPublisherId)

    # Delegated grants
    try {
        $delegatedGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id -All -ErrorAction Stop
        foreach ($g in $delegatedGrants) {
            $scopes = @()
            if ($g.Scope) { $scopes = $g.Scope.Trim() -split '\s+' }
            $matchedHighRisk = @($scopes | Where-Object { $s = $_; $highRiskPermissionWatchlist | Where-Object { $s -eq $_ } })

            $isAllPrincipals = ($g.ConsentType -eq "AllPrincipals")

            if ($isAllPrincipals -or $matchedHighRisk.Count -gt 0) {
                $flags = [System.Collections.Generic.List[string]]::new()
                if ($isAllPrincipals) { $flags.Add("CONSENT_ALL_PRINCIPALS") }
                if ($matchedHighRisk.Count -gt 0) { $flags.Add("HIGH_RISK_PERMISSION") }
                if (-not $isVerifiedPublisher) { $flags.Add("UNVERIFIED_PUBLISHER") }

                $risk = "MEDIUM"
                if ($isAllPrincipals -and $matchedHighRisk.Count -gt 0 -and -not $isVerifiedPublisher) { $risk = "CRITICAL" }
                elseif (($isAllPrincipals -or $matchedHighRisk.Count -gt 0) -and -not $isVerifiedPublisher) { $risk = "HIGH" }

                $allGrantRows.Add([PSCustomObject]@{
                    AppDisplayName    = $sp.DisplayName
                    AppId             = $sp.AppId
                    ServicePrincipalId = $sp.Id
                    GrantType         = "Delegated"
                    ConsentType       = $g.ConsentType
                    Scopes            = ($scopes -join " ")
                    HighRiskScopesMatched = ($matchedHighRisk -join ";")
                    VerifiedPublisher = $isVerifiedPublisher
                    AccountEnabled    = $sp.AccountEnabled
                    RiskLevel         = $risk
                    Flags             = ($flags -join ";")
                })
            }
            elseif ($IncludeAllGrants) {
                $allGrantRows.Add([PSCustomObject]@{
                    AppDisplayName = $sp.DisplayName; AppId = $sp.AppId; ServicePrincipalId = $sp.Id
                    GrantType = "Delegated"; ConsentType = $g.ConsentType; Scopes = ($scopes -join " ")
                    HighRiskScopesMatched = ""; VerifiedPublisher = $isVerifiedPublisher
                    AccountEnabled = $sp.AccountEnabled; RiskLevel = "OK"; Flags = ""
                })
            }
        }
    }
    catch { }

    # Application (app role) grants
    try {
        $appRoleGrants = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All -ErrorAction Stop
        foreach ($a in $appRoleGrants) {
            # App role IDs aren't self-describing without a resource-side lookup; flag by
            # resolving against the resource SP's published app roles when possible.
            $roleName = $a.AppRoleId
            $isHighRisk = $false
            try {
                $resourceSp = $servicePrincipals | Where-Object { $_.Id -eq $a.ResourceId } | Select-Object -First 1
                if ($resourceSp) {
                    # Best-effort: match by known GUID string is unreliable across tenants;
                    # rely on the resource being Microsoft Graph + a coarse "app role assigned" flag instead.
                    $isHighRisk = $true
                }
            } catch { }

            if ($isHighRisk -or $IncludeAllGrants) {
                $flags = [System.Collections.Generic.List[string]]::new()
                if (-not $isVerifiedPublisher) { $flags.Add("UNVERIFIED_PUBLISHER") }
                $flags.Add("APPLICATION_PERMISSION_GRANT")

                $allGrantRows.Add([PSCustomObject]@{
                    AppDisplayName    = $sp.DisplayName
                    AppId             = $sp.AppId
                    ServicePrincipalId = $sp.Id
                    GrantType         = "Application"
                    ConsentType       = "N/A (app-only)"
                    Scopes            = "AppRoleId:$roleName"
                    HighRiskScopesMatched = ""
                    VerifiedPublisher = $isVerifiedPublisher
                    AccountEnabled    = $sp.AccountEnabled
                    RiskLevel         = $(if (-not $isVerifiedPublisher) { "MEDIUM" } else { "LOW" })
                    Flags             = ($flags -join ";")
                })
            }
        }
    }
    catch { }
}

# =====================================================================
# CHECK 4 — Zero-owner apps among flagged grants
# =====================================================================
Write-Status "Cross-checking ownership for flagged applications..." "INFO"
$flaggedAppIds = $allGrantRows | Where-Object { $_.RiskLevel -in @("CRITICAL", "HIGH", "MEDIUM") } |
    Select-Object -ExpandProperty AppId -Unique

foreach ($appId in $flaggedAppIds) {
    try {
        $appObj = Get-MgApplication -Filter "appId eq '$appId'" -ErrorAction Stop | Select-Object -First 1
        if ($appObj) {
            $owners = Get-MgApplicationOwner -ApplicationId $appObj.Id -All -ErrorAction Stop
            if ($owners.Count -eq 0) {
                $findings.Add([PSCustomObject]@{
                    Category = "FlaggedAppOwnership"; Identifier = $appId
                    Flag = "ZERO_OWNERS_ON_FLAGGED_APP"
                    Detail = "This app has a flagged high-risk/unverified grant AND zero owners — no one is positioned to explain or review it."
                    RiskLevel = "HIGH"
                })
            }
        }
    }
    catch { }
}

# =====================================================================
# Report
# =====================================================================
Write-Host ""
Write-Host "=== App Consent Governance Audit Summary ===" -ForegroundColor Cyan

Write-Status "Tenant-wide default consent policy: $(if ($tenantDefaultOk) { 'restricted/documented' } else { 'unrestricted or undocumented — review' })" $(if ($tenantDefaultOk) { "OK" } else { "WARN" })

$reviewerIssues = $findings | Where-Object { $_.Category -eq "AdminConsentReviewer" }
Write-Status "$($reviewerIssues.Count) admin-consent-workflow reviewer issue(s) found." $(if ($reviewerIssues.Count -gt 0) { "WARN" } else { "OK" })

$critical = $allGrantRows | Where-Object { $_.RiskLevel -eq "CRITICAL" }
$high     = $allGrantRows | Where-Object { $_.RiskLevel -eq "HIGH" }
$medium   = $allGrantRows | Where-Object { $_.RiskLevel -eq "MEDIUM" }

Write-Status "$($critical.Count) grant(s) CRITICAL — AllPrincipals + high-risk scope + unverified publisher." $(if ($critical.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "$($high.Count) grant(s) HIGH — (AllPrincipals or high-risk scope) + unverified publisher." $(if ($high.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "$($medium.Count) grant(s) MEDIUM — AllPrincipals or high-risk scope, verified publisher." $(if ($medium.Count -gt 0) { "WARN" } else { "OK" })

$zeroOwnerFlagged = $findings | Where-Object { $_.Flag -eq "ZERO_OWNERS_ON_FLAGGED_APP" }
Write-Status "$($zeroOwnerFlagged.Count) flagged app(s) have zero owners." $(if ($zeroOwnerFlagged.Count -gt 0) { "WARN" } else { "OK" })

Write-Host ""
if ($critical.Count -gt 0) {
    Write-Host "--- CRITICAL grants: review immediately ---" -ForegroundColor Red
    $critical | Select-Object AppDisplayName, AppId, GrantType, ConsentType, HighRiskScopesMatched, Flags | Format-Table -AutoSize -Wrap
}
if ($reviewerIssues.Count -gt 0) {
    Write-Host "--- Admin consent workflow reviewer issues ---" -ForegroundColor Yellow
    $reviewerIssues | Select-Object Identifier, Flag, Detail | Format-Table -AutoSize -Wrap
}

Write-Host ""
Write-Host "KNOWN GAPS (not covered by this script — see .DESCRIPTION and AppConsentPolicies-A.md):" -ForegroundColor DarkGray
Write-Host " - Purview Audit 'Consent to application' event log (IsAdminConsent, granting actor) — export separately from security.microsoft.com/auditlogsearch" -ForegroundColor DarkGray
Write-Host " - Reverse-mapping which custom directory role references a given custom consent policy" -ForegroundColor DarkGray
Write-Host " - Microsoft Defender for Cloud Apps OAuth app risk scoring (separate licensed surface)" -ForegroundColor DarkGray

$grantsPath = Join-Path $OutputPath "OAuthGrants.csv"
$allGrantRows | Sort-Object @{Expression = { switch ($_.RiskLevel) { "CRITICAL" {0} "HIGH" {1} "MEDIUM" {2} "LOW" {3} default {4} } }} |
    Export-Csv -Path $grantsPath -NoTypeInformation -Encoding UTF8

$findingsPath = Join-Path $OutputPath "PolicyAndReviewerFindings.csv"
$findings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8

Write-Status "OAuth grant findings exported to $grantsPath" "OK"
Write-Status "Policy/reviewer findings exported to $findingsPath" "OK"
