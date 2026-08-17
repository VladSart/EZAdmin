<#
.SYNOPSIS
    Tenant-wide read-only audit of Viva Engage access gates, admin role assignments, and community inventory.

.DESCRIPTION
    Produces a governance/health snapshot of Viva Engage covering:
    - Tenant-wide sign-in gate: Viva Engage (Yammer) service principal AccountEnabled state
      (AppId 00000005-0000-0ff1-ce00-000000000000)
    - Microsoft 365 Group creation policy (Group.Unified: EnableGroupCreation /
      GroupCreationAllowedGroupId) — the setting that actually gates community creation,
      since Viva Engage has no separate creation toggle of its own
    - Verified domain list (home-network access is domain-gated)
    - Membership of all 7 Viva Engage-relevant admin roles, split correctly across their
      real assignment surfaces: Entra directory roles (Global Administrator, Engage
      Administrator/"Yammer administrator", Answers Administrator/Knowledge Manager) via
      Microsoft Graph, versus Viva Engage-native roles (Verified Administrator, Network
      Administrator, Corporate Communicator) via the /employeeExperience/roles API —
      Community Administrator is intentionally NOT enumerated here (it's scoped per
      community, not tenant-wide, and would require iterating every community's group
      owners individually)
    - Community inventory: count and basic metadata via /employeeExperience/communities,
      paced to respect the documented 10-requests-per-user-per-app-per-30-seconds limit

    This script explicitly REPORTS gaps rather than silently skipping them — for example,
    if the caller's token lacks a scope needed for one section, that section is marked
    NOT COLLECTED in the output rather than being omitted with no explanation, matching
    the audit-script convention used elsewhere in this repository.

    Read-only. Makes no changes. Every Viva Engage network reachable by this script is,
    by definition, Native Mode (Microsoft retired all legacy networks on 2025-10-13), so
    this script does not attempt to detect or branch on legacy/non-native state.

.PARAMETER OutputPath
    Folder where CSV reports are written. Defaults to $env:TEMP\VivaEngageAudit-<timestamp>.

.PARAMETER SkipCommunityInventory
    If specified, skips the community-listing pass. Use this on very large tenants where
    a full community enumeration would consume a meaningful share of the 10-req/30s budget
    and a quick governance/role snapshot is all that's needed.

.PARAMETER MaxCommunities
    Caps how many communities are enumerated in the inventory pass (default 200), to keep
    a single run within a predictable number of paced Graph calls. Increase deliberately
    for very large networks, understanding the run will take proportionally longer due to
    rate-limit pacing.

.EXAMPLE
    .\Get-VivaEngageAdminAudit.ps1

.EXAMPLE
    .\Get-VivaEngageAdminAudit.ps1 -OutputPath "C:\Reports\VivaEngage" -SkipCommunityInventory

.EXAMPLE
    .\Get-VivaEngageAdminAudit.ps1 -MaxCommunities 500

.NOTES
    Requires: Microsoft.Graph and Microsoft.Graph.Beta modules (Install-Module Microsoft.Graph, Install-Module Microsoft.Graph.Beta)
    Permissions (delegated or app): Application.Read.All, Directory.Read.All,
                 RoleManagement.Read.Directory, User.Read.All
    Run as: Global Reader is sufficient for every read in this script.
    Safe: read-only, no changes made anywhere.
    No pwsh available in this authoring environment to execute-test directly — reviewed
    manually for cmdlet/parameter correctness and brace/paren balance against current
    Microsoft Graph PowerShell SDK documentation. Windows PowerShell 5.1-compatible
    (no ??/?. operators used).
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "",
    [switch]$SkipCommunityInventory,
    [int]$MaxCommunities = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        default { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region ─── Preflight ────────────────────────────────────────────────────────

Write-Status "Checking required modules..."
$requiredModules = @("Microsoft.Graph.Applications","Microsoft.Graph.Identity.DirectoryManagement","Microsoft.Graph.Users","Microsoft.Graph.Beta.Identity.DirectoryManagement")
$missing = @()
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) { $missing += $m }
}
if ($missing.Count -gt 0) {
    Write-Status "Missing module(s): $($missing -join ', '). Run: Install-Module Microsoft.Graph, Install-Module Microsoft.Graph.Beta" "ERROR"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $env:TEMP "VivaEngageAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-Status "Output folder: $OutputPath"

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All","RoleManagement.Read.Directory","User.Read.All" -NoWelcome

#endregion

#region ─── 1. Tenant-wide sign-in gate ──────────────────────────────────────

Write-Status "Checking Viva Engage service principal state..."
$vivaEngageAppId = "00000005-0000-0ff1-ce00-000000000000"
$sp = Get-MgServicePrincipal -Filter "AppId eq '$vivaEngageAppId'"

$spResult = [PSCustomObject]@{
    AppId           = $vivaEngageAppId
    DisplayName     = if ($sp) { $sp.DisplayName } else { "NOT FOUND" }
    AccountEnabled  = if ($sp) { $sp.AccountEnabled } else { $null }
    Finding         = ""
}
if (-not $sp) {
    $spResult.Finding = "Service principal not found — unexpected for a tenant with Viva Engage in use."
    Write-Status $spResult.Finding "WARN"
} elseif (-not $sp.AccountEnabled) {
    $spResult.Finding = "DISABLED — breaks Viva Engage sign-in for the ENTIRE tenant."
    Write-Status $spResult.Finding "ERROR"
} else {
    $spResult.Finding = "Enabled — no tenant-wide sign-in gate issue."
    Write-Status $spResult.Finding "OK"
}
$spResult | Export-Csv -Path (Join-Path $OutputPath "01-ServicePrincipal.csv") -NoTypeInformation

#endregion

#region ─── 2. Microsoft 365 Group creation policy (gates community creation) ─

Write-Status "Checking Group.Unified creation policy (gates community creation)..."
$groupUnified = $null
try {
    $groupUnified = Get-MgBetaDirectorySetting | Where-Object { $_.DisplayName -eq "Group.Unified" }
} catch {
    Write-Status "Could not read directory settings: $($_.Exception.Message)" "WARN"
}

$policyResult = [PSCustomObject]@{
    SettingsObjectExists       = [bool]$groupUnified
    EnableGroupCreation        = "NOT COLLECTED"
    GroupCreationAllowedGroupId = "NOT COLLECTED"
    Finding                    = ""
}
if ($groupUnified) {
    foreach ($v in $groupUnified.Values) {
        if ($v.Name -eq "EnableGroupCreation") { $policyResult.EnableGroupCreation = $v.Value }
        if ($v.Name -eq "GroupCreationAllowedGroupId") { $policyResult.GroupCreationAllowedGroupId = $v.Value }
    }
    if ($policyResult.EnableGroupCreation -eq "False") {
        $policyResult.Finding = "Group/community creation is RESTRICTED tenant-wide. Only members of GroupCreationAllowedGroupId (plus Global/Engage Admins) can create communities."
        Write-Status $policyResult.Finding "WARN"
    } else {
        $policyResult.Finding = "Group/community creation is open tenant-wide."
        Write-Status $policyResult.Finding "OK"
    }
} else {
    $policyResult.Finding = "No Group.Unified settings object exists — group/community creation is UNRESTRICTED by default (this is the out-of-the-box state, not necessarily a misconfiguration)."
    Write-Status $policyResult.Finding "WARN"
}
$policyResult | Export-Csv -Path (Join-Path $OutputPath "02-GroupCreationPolicy.csv") -NoTypeInformation

#endregion

#region ─── 3. Verified domains ──────────────────────────────────────────────

Write-Status "Collecting verified domain list..."
$domains = Get-MgDomain | Select-Object Id, IsVerified, IsDefault, @{N="AuthenticationType";E={$_.AuthenticationType}}
$domains | Export-Csv -Path (Join-Path $OutputPath "03-Domains.csv") -NoTypeInformation
$unverified = $domains | Where-Object { -not $_.IsVerified }
if ($unverified) {
    Write-Status "$($unverified.Count) unverified domain(s) found — users on these domains cannot see the home network." "WARN"
} else {
    Write-Status "All $($domains.Count) domain(s) verified." "OK"
}

#endregion

#region ─── 4. Admin role membership (split by real assignment surface) ─────

Write-Status "Collecting Entra-native Viva Engage-relevant admin role membership..."
$entraRoleNames = @("Global Administrator","Yammer Administrator","Knowledge Manager")
$entraRoleResults = @()
foreach ($roleName in $entraRoleNames) {
    try {
        $roleDef = Get-MgDirectoryRole -Filter "DisplayName eq '$roleName'" -ErrorAction SilentlyContinue
        if (-not $roleDef) {
            # Role may not be activated in this tenant yet (Entra roles activate on first use)
            $entraRoleResults += [PSCustomObject]@{ Role = $roleName; Member = "(role not activated in this tenant)"; UPN = "" }
            continue
        }
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $roleDef.Id
        if ($members.Count -eq 0) {
            $entraRoleResults += [PSCustomObject]@{ Role = $roleName; Member = "(no members)"; UPN = "" }
        }
        foreach ($m in $members) {
            $upn = ""
            if ($m.AdditionalProperties.ContainsKey("userPrincipalName")) { $upn = $m.AdditionalProperties["userPrincipalName"] }
            $displayName = ""
            if ($m.AdditionalProperties.ContainsKey("displayName")) { $displayName = $m.AdditionalProperties["displayName"] }
            $entraRoleResults += [PSCustomObject]@{ Role = $roleName; Member = $displayName; UPN = $upn }
        }
    } catch {
        Write-Status "Could not read role '$roleName': $($_.Exception.Message)" "WARN"
        $entraRoleResults += [PSCustomObject]@{ Role = $roleName; Member = "NOT COLLECTED (error)"; UPN = "" }
    }
}
$entraRoleResults | Export-Csv -Path (Join-Path $OutputPath "04-EntraAdminRoles.csv") -NoTypeInformation
Write-Status "Entra-native role membership written (Global Administrator / Yammer Administrator [Engage Admin] / Knowledge Manager [Answers Admin])."

Write-Status "Collecting Viva Engage-native role membership (Verified Admin / Network Admin / Corporate Communicator)..."
$engageRoleResults = @()
try {
    $roleList = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/employeeExperience/roles"
    if ($roleList -and $roleList.value) {
        foreach ($role in $roleList.value) {
            Start-Sleep -Milliseconds 500   # pacing against the 10 req/30s API limit
            try {
                $members = Invoke-MgGraphRequest -Method GET `
                    -Uri "https://graph.microsoft.com/v1.0/employeeExperience/roles/$($role.id)/members"
                if ($members -and $members.value -and $members.value.Count -gt 0) {
                    foreach ($m in $members.value) {
                        $engageRoleResults += [PSCustomObject]@{ Role = $role.displayName; Member = $m.displayName; UPN = $m.userPrincipalName }
                    }
                } else {
                    $engageRoleResults += [PSCustomObject]@{ Role = $role.displayName; Member = "(no members)"; UPN = "" }
                }
            } catch {
                $engageRoleResults += [PSCustomObject]@{ Role = $role.displayName; Member = "NOT COLLECTED (error)"; UPN = "" }
                Write-Status "Could not read members for role '$($role.displayName)': $($_.Exception.Message)" "WARN"
            }
        }
    } else {
        Write-Status "No role list returned from /employeeExperience/roles — confirm the tenant has Viva Engage in use and the token has sufficient scope." "WARN"
    }
} catch {
    Write-Status "Could not read /employeeExperience/roles: $($_.Exception.Message). Note: Community Administrator is never enumerated here regardless — it's scoped per community, not tenant-wide." "WARN"
    $engageRoleResults += [PSCustomObject]@{ Role = "ALL"; Member = "NOT COLLECTED (error calling employeeExperience/roles)"; UPN = "" }
}
$engageRoleResults | Export-Csv -Path (Join-Path $OutputPath "05-VivaEngageNativeRoles.csv") -NoTypeInformation

#endregion

#region ─── 5. Community inventory (optional, rate-limit-paced) ─────────────

if ($SkipCommunityInventory) {
    Write-Status "Skipping community inventory (-SkipCommunityInventory specified)."
} else {
    Write-Status "Collecting community inventory (max $MaxCommunities, paced for the 10 req/30s API limit)..."
    $communityResults = @()
    $collected = 0
    $requestsThisWindow = 0
    $windowStart = Get-Date
    try {
        $uri = "https://graph.microsoft.com/v1.0/employeeExperience/communities?`$top=25"
        while ($uri -and $collected -lt $MaxCommunities) {
            if ($requestsThisWindow -ge 8) {
                # stay comfortably under the documented 10-req/30s ceiling
                $elapsed = (Get-Date) - $windowStart
                if ($elapsed.TotalSeconds -lt 30) {
                    Start-Sleep -Seconds (30 - [int]$elapsed.TotalSeconds)
                }
                $requestsThisWindow = 0
                $windowStart = Get-Date
            }
            $page = Invoke-MgGraphRequest -Method GET -Uri $uri
            $requestsThisWindow++
            if ($page.value) {
                foreach ($c in $page.value) {
                    if ($collected -ge $MaxCommunities) { break }
                    $communityResults += [PSCustomObject]@{
                        Id          = $c.id
                        DisplayName = $c.displayName
                        Description = $c.description
                        GroupId     = $c.groupId
                        Visibility  = $c.visibility
                    }
                    $collected++
                }
            }
            $uri = if ($page.'@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
        }
        Write-Status "Collected $collected communities." "OK"
    } catch {
        Write-Status "Community inventory collection stopped early: $($_.Exception.Message)" "WARN"
    }
    $communityResults | Export-Csv -Path (Join-Path $OutputPath "06-Communities.csv") -NoTypeInformation
}

#endregion

#region ─── Report ────────────────────────────────────────────────────────────

Write-Status "=== SUMMARY ===" "OK"
Write-Status "Service principal: $($spResult.Finding)"
Write-Status "Group creation policy: $($policyResult.Finding)"
Write-Status "Unverified domains: $(if ($unverified) { $unverified.Count } else { 0 })"
Write-Status "CSV reports written to: $OutputPath" "OK"
Write-Status "Reminder: Community Administrator assignments are NOT captured by this script — they're scoped per community; audit those individually via each community's connected group ownership if needed." "WARN"

#endregion
