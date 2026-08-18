<#
.SYNOPSIS
    Read-only readiness/ongoing-health audit for Microsoft Defender for Cloud
    Apps App Governance — the RBAC capability gap, the first-party-app
    exclusion boundary, and currently-disabled non-Microsoft Service
    Principals that AppGovernance-A.md and AppGovernance-B.md describe as the
    most common misconfiguration and triage surface.

.DESCRIPTION
    App governance itself (policies, alerts, the Governance log, dashboard
    statistics) has no Microsoft Graph read surface at the time of writing —
    it is a Defender XDR portal-only feature. This script does NOT attempt to
    read app governance configuration directly. Instead it audits the
    Graph-readable Entra ID objects app governance depends on and acts upon,
    to answer the questions that most commonly generate tickets BEFORE anyone
    opens the portal:

    1. RBAC READINESS — enumerates every principal holding one of the seven
       roles capable of turning app governance on or viewing/managing it, and
       explicitly flags any principal whose ONLY relevant role is Cloud App
       Security Administrator: a TURN_ON_ONLY_NO_VIEW finding, since that role
       grants the enablement toggle but not the ability to see or manage
       anything afterward (AppGovernance-B.md Fix 1) — the single most common
       "I turned it on and it's broken" ticket for this feature.

    2. OAUTH APP INVENTORY SCOPE ESTIMATE — enumerates Service Principals
       that WOULD be in app governance's tracked universe (non-Microsoft
       first-party, i.e. AppOwnerOrganizationId does not equal Microsoft's
       own tenant f8cdef31-a31e-4b4a-93e4-5f571e91255a, AND holding at least
       one delegated or application OAuth grant). Useful both as a
       pre-enablement scoping estimate ("how many apps will app governance
       actually surface") and as a manual first-party-exclusion sanity check
       when a specific app is reported as "missing" from app governance.

    3. DISABLED NON-MICROSOFT APPS — flags every in-scope Service Principal
       currently sitting at AccountEnabled = $false. App governance's primary
       enforcement action (the predefined-policy "Disable app" action, or a
       manual Ban/Disable) sets exactly this flag, and there is no other
       Graph-visible signal for "an app is currently governance-disabled."
       This list is a starting point for the Governance log cross-check
       described in AppGovernance-B.md Fix 4/Fix 5 — this script cannot tell
       you WHY an app is disabled (app governance, a manual admin action, or
       an Entra ID Protection risk action can all produce the same flag), only
       THAT it is, which is the fact most likely to be missing when a ticket
       is first opened.

    4. ZERO-OWNER HIGH-GRANT APPS — cross-references in-scope apps holding a
       high-risk permission (reusing the same watchlist concept as
       Get-AppConsentGovernanceAudit.ps1, but scoped here to apps that would
       also be app-governance-trackable) against Application object
       ownership, flagging apps with no owner as a governance-blind-spot
       indicator: nobody is positioned to explain a governance alert on this
       app before you have to.

    Read-only. Makes no changes to any Service Principal, grant, role
    assignment, or Application object. Exports two CSVs.

    Does NOT cover (portal-only, no Graph v1.0 endpoint exists for these —
    see AppGovernance-A.md "How It Works" and Command Cheat Sheet):
    - App governance enablement toggle state / enablement timestamp
    - Billing-region eligibility for app governance (Singapore, Poland,
      Italy, Qatar, Israel, Spain, Mexico, Taiwan are currently excluded)
    - The 10-hour post-enablement data-population window
    - The both-portals-visited alert-provisioning gate
    - Predefined/user-defined policy configuration, status, or actions
    - The Governance log itself (action history, retry/revert)
    - Threat detection / policy alert content
    - Microsoft 365 connector connection status (Settings > Cloud Apps >
      Connected apps > Office 365) — affects advanced-hunting depth, not
      covered by any Graph endpoint this script uses
    - Full tenant-wide high-risk OAuth grant sweep — that is already owned
      by EntraID/Scripts/Get-AppConsentGovernanceAudit.ps1; this script
      intentionally does not duplicate it and instead narrows to the
      subset relevant to app-governance scope/ownership specifically

.PARAMETER OutputPath
    Folder where CSV reports are written. Defaults to
    $env:TEMP\AppGovernanceAudit-<timestamp>.

.PARAMETER IncludeAllInScopeApps
    If specified, exports every in-scope (non-first-party, has a grant)
    Service Principal to a full inventory CSV, not just flagged ones.

.EXAMPLE
    .\Get-AppGovernanceReadinessAudit.ps1

    Standard audit — RBAC readiness, disabled-app flags, zero-owner
    high-grant apps only.

.EXAMPLE
    .\Get-AppGovernanceReadinessAudit.ps1 -IncludeAllInScopeApps -OutputPath C:\Reports\AppGov

    Adds a full in-scope app inventory export, custom output folder.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Applications,
              Microsoft.Graph.Identity.DirectoryManagement
    Scopes needed: Directory.Read.All, Application.Read.All,
                   RoleManagement.Read.Directory
    Run As: Any account with Global Reader (sufficient for every read in this
            script) or a role with equivalent read scopes
    Safe: Fully read-only — no Set-Mg/New-Mg/Remove-Mg/Update-Mg cmdlets are
          used anywhere in this script.
    Cross-references: Security/Defender/AppGovernance-B.md (Triage, Fix 1,
                       Fix 4, Fix 5) and AppGovernance-A.md (Validation Steps
                       2 and 4, Symptom -> Cause Map)
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:TEMP\AppGovernanceAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')",

    [switch]$IncludeAllInScopeApps
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

# Microsoft's own first-party app home tenant — app governance always excludes
# apps whose AppOwnerOrganizationId matches this, regardless of display name.
$microsoftFirstPartyTenantId = "f8cdef31-a31e-4b4a-93e4-5f571e91255a"

# The two RBAC role lists app governance actually gates on (AppGovernance-B.md
# Dependency Cascade / AppGovernance-A.md Dependency Stack).
$turnOnRoles  = @("Global Administrator", "Company Administrator", "Security Administrator",
                  "Compliance Administrator", "Compliance Data Administrator",
                  "Cloud App Security Administrator")
$viewManageRoles = @("Global Administrator", "Company Administrator", "Compliance Administrator",
                     "Compliance Data Administrator", "Global Reader",
                     "Security Administrator", "Security Operator", "Security Reader")

# Reused high-risk Graph permission watchlist (same concept as
# Get-AppConsentGovernanceAudit.ps1, intentionally not re-deriving it differently).
$highRiskPermissionWatchlist = @(
    "Mail.ReadWrite", "Mail.Send", "Mail.ReadWrite.All", "Mail.Send.All",
    "Files.ReadWrite.All", "Sites.FullControl.All", "Sites.ReadWrite.All",
    "Directory.ReadWrite.All", "RoleManagement.ReadWrite.Directory",
    "User.ReadWrite.All", "Group.ReadWrite.All",
    "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All",
    "full_access_as_app", "EWS.AccessAsUser.All", "Contacts.ReadWrite",
    "MailboxSettings.ReadWrite"
)

# ---- Preflight ----
foreach ($mod in @("Microsoft.Graph.Authentication", "Microsoft.Graph.Applications", "Microsoft.Graph.Identity.DirectoryManagement")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod" "ERROR"
        return
    }
}

$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Graph. Connecting with required read scopes..." "INFO"
    try {
        Connect-MgGraph -Scopes "Directory.Read.All", "Application.Read.All", "RoleManagement.Read.Directory" -NoWelcome -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        return
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$rbacFindings = [System.Collections.Generic.List[object]]::new()

# =====================================================================
# CHECK 1 — RBAC readiness: turn-on-only-no-view gap
# =====================================================================
Write-Status "Enumerating directory role assignments for app-governance-relevant roles..." "INFO"
try {
    $allRoleAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All -ExpandProperty roleDefinition -ErrorAction Stop
}
catch {
    Write-Status "Failed to read directory role assignments: $($_.Exception.Message)" "ERROR"
    $allRoleAssignments = @()
}

$relevantRoleNames = ($turnOnRoles + $viewManageRoles) | Select-Object -Unique
$relevantAssignments = $allRoleAssignments | Where-Object { $_.RoleDefinition.DisplayName -in $relevantRoleNames }

$byPrincipal = $relevantAssignments | Group-Object PrincipalId

foreach ($grp in $byPrincipal) {
    $roleNames = $grp.Group.RoleDefinition.DisplayName | Select-Object -Unique
    $hasTurnOn = @($roleNames | Where-Object { $_ -in $turnOnRoles }).Count -gt 0
    $hasViewManage = @($roleNames | Where-Object { $_ -in $viewManageRoles }).Count -gt 0

    if ($hasTurnOn -and -not $hasViewManage) {
        # Resolve a display name/UPN for readability where possible
        $principalLabel = $grp.Name
        try {
            $u = Get-MgUser -UserId $grp.Name -ErrorAction Stop -Property DisplayName, UserPrincipalName
            if ($u) { $principalLabel = "$($u.DisplayName) ($($u.UserPrincipalName))" }
        } catch { }

        $rbacFindings.Add([PSCustomObject]@{
            Category  = "RBAC"
            Principal = $principalLabel
            Roles     = ($roleNames -join "; ")
            Flag      = "TURN_ON_ONLY_NO_VIEW"
            Detail    = "Can turn app governance on (via $($roleNames -join '/')) but holds none of the view/manage-capable roles — will see nothing in the portal after enabling. Add Security Reader/Security Operator/Global Reader or another view/manage role."
            RiskLevel = "MEDIUM"
        })
    }
}

Write-Status "$(($rbacFindings | Where-Object {$_.Flag -eq 'TURN_ON_ONLY_NO_VIEW'}).Count) principal(s) with a turn-on-only RBAC gap." $(if ($rbacFindings.Count -gt 0) { "WARN" } else { "OK" })

# =====================================================================
# CHECK 2 & 3 — In-scope OAuth app inventory + disabled-app flagging
# =====================================================================
Write-Status "Enumerating Service Principals to build the app-governance-scope estimate (can take a while in large tenants)..." "INFO"

$inScopeRows = [System.Collections.Generic.List[object]]::new()

try {
    $servicePrincipals = Get-MgServicePrincipal -All -Property Id, DisplayName, AppId, AppOwnerOrganizationId, VerifiedPublisher, AccountEnabled -ErrorAction Stop
    Write-Status "Found $($servicePrincipals.Count) Service Principal(s) tenant-wide." "INFO"
}
catch {
    Write-Status "Failed to enumerate Service Principals: $($_.Exception.Message)" "ERROR"
    $servicePrincipals = @()
}

$i = 0
foreach ($sp in $servicePrincipals) {
    $i++
    if ($i % 100 -eq 0) { Write-Status "Processed $i of $($servicePrincipals.Count) Service Principals..." "INFO" }

    # First-party exclusion — app governance never tracks these regardless of grants
    if ($sp.AppOwnerOrganizationId -and ($sp.AppOwnerOrganizationId -eq $microsoftFirstPartyTenantId)) {
        continue
    }

    $hasDelegatedGrant = $false
    $hasAppRoleGrant = $false
    $matchedHighRisk = @()

    try {
        $delegatedGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id -All -ErrorAction Stop
        if ($delegatedGrants.Count -gt 0) {
            $hasDelegatedGrant = $true
            foreach ($g in $delegatedGrants) {
                $scopes = @()
                if ($g.Scope) { $scopes = $g.Scope.Trim() -split '\s+' }
                $matchedHighRisk += @($scopes | Where-Object { $s = $_; $highRiskPermissionWatchlist | Where-Object { $s -eq $_ } })
            }
        }
    } catch { }

    try {
        $appRoleGrants = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All -ErrorAction Stop
        if ($appRoleGrants.Count -gt 0) { $hasAppRoleGrant = $true }
    } catch { }

    # Not in app governance's trackable universe unless it has at least one grant
    if (-not $hasDelegatedGrant -and -not $hasAppRoleGrant) {
        continue
    }

    $isVerifiedPublisher = [bool]($sp.VerifiedPublisher -and $sp.VerifiedPublisher.VerifiedPublisherId)

    $row = [PSCustomObject]@{
        DisplayName          = $sp.DisplayName
        AppId                = $sp.AppId
        ServicePrincipalId   = $sp.Id
        AccountEnabled       = $sp.AccountEnabled
        VerifiedPublisher    = $isVerifiedPublisher
        HasDelegatedGrant    = $hasDelegatedGrant
        HasAppRoleGrant      = $hasAppRoleGrant
        HighRiskScopesMatched = ($matchedHighRisk -join ";")
    }

    if ($IncludeAllInScopeApps) { $inScopeRows.Add($row) }

    if (-not $sp.AccountEnabled) {
        $rbacFindings.Add([PSCustomObject]@{
            Category  = "DisabledApp"
            Principal = "$($sp.DisplayName) ($($sp.AppId))"
            Roles     = ""
            Flag      = "APP_DISABLED_CAUSE_UNKNOWN"
            Detail    = "In-scope non-Microsoft app currently has AccountEnabled=False. Could be an app governance predefined-policy action, a manual Ban/Disable, or an Entra ID Protection risk action — check the Governance log (portal-only) before reactivating. See AppGovernance-B.md Fix 5."
            RiskLevel = "INFO"
        })
    }

    if ($matchedHighRisk.Count -gt 0) {
        # Ownership cross-check only for flagged high-risk apps, to keep this bounded
        try {
            $appObj = Get-MgApplication -Filter "appId eq '$($sp.AppId)'" -ErrorAction Stop | Select-Object -First 1
            if ($appObj) {
                $owners = Get-MgApplicationOwner -ApplicationId $appObj.Id -All -ErrorAction Stop
                if ($owners.Count -eq 0) {
                    $rbacFindings.Add([PSCustomObject]@{
                        Category  = "ZeroOwnerHighRisk"
                        Principal = "$($sp.DisplayName) ($($sp.AppId))"
                        Roles     = ""
                        Flag      = "ZERO_OWNER_HIGH_RISK_INSCOPE_APP"
                        Detail    = "In-scope app holds high-risk permission(s) [$($matchedHighRisk -join ', ')] and has zero owners — no one is positioned to explain an app governance alert on this app before escalation."
                        RiskLevel = "HIGH"
                    })
                }
            }
        } catch { }
    }
}

# =====================================================================
# Report
# =====================================================================
Write-Host ""
Write-Host "=== App Governance Readiness Audit Summary ===" -ForegroundColor Cyan

$turnOnOnlyCount = ($rbacFindings | Where-Object { $_.Flag -eq "TURN_ON_ONLY_NO_VIEW" }).Count
Write-Status "$turnOnOnlyCount principal(s) can turn app governance on but cannot view/manage it (Fix 1 gap)." $(if ($turnOnOnlyCount -gt 0) { "WARN" } else { "OK" })

$disabledCount = ($rbacFindings | Where-Object { $_.Flag -eq "APP_DISABLED_CAUSE_UNKNOWN" }).Count
Write-Status "$disabledCount in-scope non-Microsoft app(s) currently disabled (cause not determinable via Graph)." $(if ($disabledCount -gt 0) { "WARN" } else { "OK" })

$zeroOwnerCount = ($rbacFindings | Where-Object { $_.Flag -eq "ZERO_OWNER_HIGH_RISK_INSCOPE_APP" }).Count
Write-Status "$zeroOwnerCount in-scope app(s) with a high-risk permission and zero owners." $(if ($zeroOwnerCount -gt 0) { "ERROR" } else { "OK" })

Write-Host ""
if ($turnOnOnlyCount -gt 0) {
    Write-Host "--- RBAC turn-on-only gap ---" -ForegroundColor Yellow
    $rbacFindings | Where-Object { $_.Flag -eq "TURN_ON_ONLY_NO_VIEW" } | Select-Object Principal, Roles, Detail | Format-Table -AutoSize -Wrap
}
if ($zeroOwnerCount -gt 0) {
    Write-Host "--- Zero-owner high-risk in-scope apps: review immediately ---" -ForegroundColor Red
    $rbacFindings | Where-Object { $_.Flag -eq "ZERO_OWNER_HIGH_RISK_INSCOPE_APP" } | Select-Object Principal, Detail | Format-Table -AutoSize -Wrap
}

Write-Host ""
Write-Host "KNOWN GAPS (portal-only, not covered by this script — see .DESCRIPTION and AppGovernance-A.md):" -ForegroundColor DarkGray
Write-Host " - App governance enablement state, timestamp, and billing-region eligibility" -ForegroundColor DarkGray
Write-Host " - The 10-hour post-enablement data window and both-portals alert-provisioning gate" -ForegroundColor DarkGray
Write-Host " - Predefined/user-defined policy configuration and the Governance log itself" -ForegroundColor DarkGray
Write-Host " - Full tenant-wide OAuth grant risk sweep — see EntraID/Scripts/Get-AppConsentGovernanceAudit.ps1" -ForegroundColor DarkGray

$findingsPath = Join-Path $OutputPath "AppGovernanceFindings.csv"
$rbacFindings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8
Write-Status "Findings exported to $findingsPath" "OK"

if ($IncludeAllInScopeApps) {
    $inventoryPath = Join-Path $OutputPath "InScopeAppInventory.csv"
    $inScopeRows | Export-Csv -Path $inventoryPath -NoTypeInformation -Encoding UTF8
    Write-Status "Full in-scope app inventory ($($inScopeRows.Count) apps) exported to $inventoryPath" "OK"
}
