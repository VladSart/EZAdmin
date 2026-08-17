<#
.SYNOPSIS
    Tenant-wide read-only audit of Viva Insights admin roles, Viva Feature Access
    Management (VFAM) policy state, and license posture.

.DESCRIPTION
    Produces a governance/health snapshot of Viva Insights covering:
    - Entra-native admin role membership for the three real directory roles:
      Insights Administrator, Insights Analyst, and AI Administrator (via
      Microsoft Graph Get-MgDirectoryRole / Get-MgDirectoryRoleMember)
    - Current Viva Feature Access Management (VFAM) policy state for the
      "Viva Insights web app" and "AgentDashboard" features (via Exchange
      Online's Get-VivaModuleFeaturePolicy) — this is the current, supported
      control surface for Copilot Dashboard / Agent Dashboard access as of
      2026; the older Microsoft 365 admin center "Copilot Dashboard" toggle
      and any pre-VFAM PowerShell method are retired and NOT checked here
    - Tenant-wide license posture: counts of users holding a Viva Insights
      service plan versus a Microsoft 365 Copilot license, since minimum
      group size and several other settings are configured on DIFFERENT
      surfaces depending on which of these the tenant holds

    This script explicitly REPORTS gaps rather than silently skipping them —
    for example, if a role hasn't been activated yet in the tenant, or a VFAM
    feature ID returns no policy, that's reported as a finding, not omitted.

    Deliberately NOT collected, because no Graph/PowerShell read exists for
    either as of this writing (both are Viva Insights web app UI-only):
    - Manager / Group Manager enablement lists (CSV or Entra group reference
      configured inside the Viva Insights web app's own Manager settings page)
    - Minimum team size and Minimum group size current values (two separate
      settings depending on license state — see VivaInsights-A.md)
    These gaps are explicitly reported in the script's output rather than
    silently omitted, consistent with this repository's audit-script
    convention.

    Read-only. Makes no changes.

.PARAMETER OutputPath
    Folder where CSV reports are written. Defaults to $env:TEMP\VivaInsightsAudit-<timestamp>.

.PARAMETER SkipLicenseScan
    If specified, skips the tenant-wide license posture scan. Use this on very
    large tenants where enumerating all users' license details would take a
    long time and a quick role/VFAM snapshot is all that's needed.

.PARAMETER MaxUsersForLicenseScan
    Caps how many users are scanned in the license posture pass (default 500),
    to keep a single run within a predictable runtime. Increase deliberately
    for a full tenant census, understanding the run will take proportionally
    longer.

.EXAMPLE
    .\Get-VivaInsightsAdminAudit.ps1

.EXAMPLE
    .\Get-VivaInsightsAdminAudit.ps1 -OutputPath "C:\Reports\VivaInsights" -SkipLicenseScan

.EXAMPLE
    .\Get-VivaInsightsAdminAudit.ps1 -MaxUsersForLicenseScan 2000

.NOTES
    Requires: Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users
              modules, and the ExchangeOnlineManagement module (for VFAM cmdlets).
    Permissions (delegated or app): RoleManagement.Read.Directory, User.Read.All
              for Graph; Exchange Online admin role (e.g., Global Reader is NOT
              sufficient for Get-VivaModuleFeaturePolicy — requires at minimum
              View-Only Organization Management or a role with Exchange Online
              PowerShell read access) for the VFAM checks.
    Run as: Global Reader is sufficient for the Graph-based role checks;
              an Exchange Online admin role is required for the VFAM checks.
    Safe: read-only, no changes made anywhere.
    No pwsh available in this authoring environment to execute-test directly —
    reviewed manually for cmdlet/parameter correctness and brace/paren balance
    against current Microsoft Graph PowerShell SDK and Exchange Online
    PowerShell documentation. Windows PowerShell 5.1-compatible (no ??/?.
    operators used).
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "",
    [switch]$SkipLicenseScan,
    [int]$MaxUsersForLicenseScan = 500
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
$requiredModules = @("Microsoft.Graph.Identity.DirectoryManagement","Microsoft.Graph.Users","ExchangeOnlineManagement")
$missing = @()
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) { $missing += $m }
}
if ($missing.Count -gt 0) {
    Write-Status "Missing module(s): $($missing -join ', '). Run: Install-Module Microsoft.Graph, Install-Module ExchangeOnlineManagement" "ERROR"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $env:TEMP "VivaInsightsAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-Status "Output folder: $OutputPath"

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All" -NoWelcome

Write-Status "Connecting to Exchange Online (required for VFAM checks)..."
try {
    Connect-ExchangeOnline -ShowBanner:$false
    $exoConnected = $true
} catch {
    Write-Status "Could not connect to Exchange Online: $($_.Exception.Message). VFAM checks will be marked NOT COLLECTED." "WARN"
    $exoConnected = $false
}

#endregion

#region ─── 1. Entra-native admin role membership ────────────────────────────

Write-Status "Collecting Entra-native Viva Insights admin role membership..."
$entraRoleNames = @("Insights Administrator","Insights Analyst","AI Administrator")
$roleResults = @()
foreach ($roleName in $entraRoleNames) {
    try {
        $roleDef = Get-MgDirectoryRole -Filter "DisplayName eq '$roleName'" -ErrorAction SilentlyContinue
        if (-not $roleDef) {
            # Entra roles activate on first use in a tenant — not activated yet is a valid state, not an error
            $roleResults += [PSCustomObject]@{ Role = $roleName; Member = "(role not activated in this tenant)"; UPN = "" }
            continue
        }
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $roleDef.Id
        if ($members.Count -eq 0) {
            $roleResults += [PSCustomObject]@{ Role = $roleName; Member = "(no direct members)"; UPN = "" }
        }
        foreach ($m in $members) {
            $upn = ""
            if ($m.AdditionalProperties.ContainsKey("userPrincipalName")) { $upn = $m.AdditionalProperties["userPrincipalName"] }
            $displayName = ""
            if ($m.AdditionalProperties.ContainsKey("displayName")) { $displayName = $m.AdditionalProperties["displayName"] }
            $roleResults += [PSCustomObject]@{ Role = $roleName; Member = $displayName; UPN = $upn }
        }
    } catch {
        Write-Status "Could not read role '$roleName': $($_.Exception.Message)" "WARN"
        $roleResults += [PSCustomObject]@{ Role = $roleName; Member = "NOT COLLECTED (error)"; UPN = "" }
    }
}
$roleResults | Export-Csv -Path (Join-Path $OutputPath "01-EntraAdminRoles.csv") -NoTypeInformation
Write-Status "Entra-native role membership written (Insights Administrator / Insights Analyst / AI Administrator)."
Write-Status "Reminder: Global Administrator inherits Insights Administrator automatically and will NOT appear as a direct member above." "WARN"
Write-Status "Reminder: Manager and Group Manager are NOT Entra roles — never enumerated here. Confirm those in the Viva Insights web app's own Manager settings page." "WARN"

#endregion

#region ─── 2. VFAM policy state (Viva Insights web app + Agent Dashboard) ───

Write-Status "Checking Viva Feature Access Management (VFAM) policy state..."
$vfamResults = @()
if ($exoConnected) {
    foreach ($featureId in @("Viva Insights web app","AgentDashboard")) {
        try {
            $policies = Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId $featureId -ErrorAction Stop
            if ($policies) {
                foreach ($p in $policies) {
                    $vfamResults += [PSCustomObject]@{
                        FeatureId       = $featureId
                        PolicyName      = $p.Name
                        IsFeatureEnabled = $p.IsFeatureEnabled
                        Scope           = if ($p.Everyone) { "Everyone (tenant-wide)" } else { "Scoped (user/group)" }
                    }
                }
            } else {
                $vfamResults += [PSCustomObject]@{ FeatureId = $featureId; PolicyName = "(no explicit policy — platform default applies)"; IsFeatureEnabled = ""; Scope = "" }
            }
        } catch {
            Write-Status "Could not read VFAM policy for '$featureId': $($_.Exception.Message)" "WARN"
            $vfamResults += [PSCustomObject]@{ FeatureId = $featureId; PolicyName = "NOT COLLECTED (error)"; IsFeatureEnabled = ""; Scope = "" }
        }
    }
} else {
    $vfamResults += [PSCustomObject]@{ FeatureId = "ALL"; PolicyName = "NOT COLLECTED (Exchange Online connection unavailable)"; IsFeatureEnabled = ""; Scope = "" }
}
$vfamResults | Export-Csv -Path (Join-Path $OutputPath "02-VFAMPolicies.csv") -NoTypeInformation
Write-Status "VFAM policy state written for 'Viva Insights web app' and 'AgentDashboard'."
Write-Status "Reminder: the old M365 admin center Copilot Dashboard toggle and pre-VFAM PowerShell methods are retired and intentionally not checked by this script." "WARN"

#endregion

#region ─── 3. License posture (Viva Insights vs. Copilot) ──────────────────

if ($SkipLicenseScan) {
    Write-Status "Skipping license posture scan (-SkipLicenseScan specified)."
} else {
    Write-Status "Collecting tenant license posture (max $MaxUsersForLicenseScan users)..."
    $licenseResults = @()
    $vivaInsightsCount = 0
    $copilotCount = 0
    $checkedCount = 0
    try {
        $users = Get-MgUser -All -Property Id,UserPrincipalName -ErrorAction Stop | Select-Object -First $MaxUsersForLicenseScan
        foreach ($u in $users) {
            $checkedCount++
            try {
                $licDetails = Get-MgUserLicenseDetail -UserId $u.Id -ErrorAction SilentlyContinue
                $hasVivaInsights = $false
                $hasCopilot = $false
                foreach ($lic in $licDetails) {
                    if ($lic.SkuPartNumber -match "VIVA|INSIGHTS") { $hasVivaInsights = $true }
                    if ($lic.SkuPartNumber -match "COPILOT") { $hasCopilot = $true }
                }
                if ($hasVivaInsights) { $vivaInsightsCount++ }
                if ($hasCopilot) { $copilotCount++ }
            } catch {
                # Skip individual user errors silently in the loop; overall counts are best-effort
                continue
            }
        }
        $licenseResults += [PSCustomObject]@{
            UsersChecked            = $checkedCount
            UsersWithVivaInsightsSku = $vivaInsightsCount
            UsersWithCopilotSku     = $copilotCount
            Finding                 = "Best-effort SKU-name match (SkuPartNumber -match 'VIVA|INSIGHTS' or 'COPILOT'). Confirm exact SKU names against your tenant's current licensing agreement before treating counts as authoritative."
        }
        if ($vivaInsightsCount -gt 0 -and $copilotCount -gt 0) {
            Write-Status "Tenant has users on BOTH Viva Insights and Copilot SKUs — confirm which Minimum group size surface (M365 admin center vs. Viva Insights web app Privacy settings) is currently authoritative; both may have been configured independently." "WARN"
        } elseif ($vivaInsightsCount -gt 0) {
            Write-Status "Tenant has Viva Insights-licensed users — Minimum group size should be checked/configured in the Viva Insights web app's own Privacy settings page." "OK"
        } elseif ($copilotCount -gt 0) {
            Write-Status "Tenant has Copilot-licensed users only (no distinct Viva Insights SKU detected) — Minimum group size should be checked/configured via the M365 admin center's Copilot Dashboard settings." "OK"
        } else {
            Write-Status "No Viva Insights or Copilot SKU detected in the sampled users — confirm licensing state manually before assuming Organizational insights is unlicensed tenant-wide." "WARN"
        }
    } catch {
        Write-Status "License posture scan stopped early: $($_.Exception.Message)" "WARN"
        $licenseResults += [PSCustomObject]@{ UsersChecked = $checkedCount; UsersWithVivaInsightsSku = "NOT COLLECTED"; UsersWithCopilotSku = "NOT COLLECTED"; Finding = "Error: $($_.Exception.Message)" }
    }
    $licenseResults | Export-Csv -Path (Join-Path $OutputPath "03-LicensePosture.csv") -NoTypeInformation
}

#endregion

#region ─── Report ────────────────────────────────────────────────────────────

Write-Status "=== SUMMARY ===" "OK"
Write-Status "Entra-native role membership: see 01-EntraAdminRoles.csv"
Write-Status "VFAM policy state: see 02-VFAMPolicies.csv"
if (-not $SkipLicenseScan) { Write-Status "License posture: see 03-LicensePosture.csv" }
Write-Status "CSV reports written to: $OutputPath" "OK"
Write-Status "NOT COLLECTED by design (no Graph/PowerShell read exists): Manager/Group Manager enablement lists, Minimum team size, Minimum group size current value. Confirm these directly in the Viva Insights web app's Manager settings and Privacy settings pages." "WARN"

#endregion
