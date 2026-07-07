<#
.SYNOPSIS
    Read-only audit of SharePoint Advanced Management (SAM) tenant and per-site configuration —
    Restricted Access Control (RAC), Restricted Content Discovery (RCD), site lock state, and
    optional Data Access Governance (DAG) report / idle session sign-out / restricted-site-creation
    posture checks.

.DESCRIPTION
    Automates the Validation Steps and Symptom -> Cause Map checks from Advanced-Management-A.md
    and the Diagnosis & Validation Flow from Advanced-Management-B.md, instead of walking through
    each `Get-SPOTenant`/`Get-SPOSite` check manually per ticket or governance review.

    Tenant-level checks (always run):
    - Dynamically inspects Get-SPOTenant output for every property matching *RestrictedAccess*,
      *RestrictedContent*, *Restricted* so this script does not silently miss a property Microsoft
      renames or adds later, and flags TENANT_DELEGATION_ENABLED if RAC/RCD management delegation
      to site admins is on (informational — not necessarily wrong, but worth surfacing).
    - Flags TENANT_SHARING_BYPASSES_RAC if AllowSharingOutsideRestrictedAccessControlGroups is
      $true, per Advanced-Management-A.md's Playbook 1 "sharing is the leak vector" note.

    Per-site checks (for each -SiteUrls entry supplied):
    - RAC_ENABLED_NO_GROUPS — RestrictedAccessControl is $true but RestrictedAccessControlGroups
      is empty, per Advanced-Management-B.md Step 3 ("policy enabled but effectively unenforceable").
    - RAC_GROUP_LIMIT_NEAR — group count is at or above -RACGroupLimitWarningThreshold (default 8)
      out of the documented maximum of 10 groups per site.
    - RCD_ON_ONEDRIVE_ATTEMPTED — RestrictContentOrgWideSearch is set on a personal/OneDrive site
      URL, which SharePoint Advanced Management documents as unsupported.
    - SITE_LOCKED — LockState is not "Unlock", which may indicate Site Lifecycle Management
      enforcement (read-only/archive) has already been actioned on this site.

    Optional checks (each degrades gracefully — a missing cmdlet/module/permission produces a
    flagged, non-fatal row rather than a script failure):
    - -CheckDAGReports: lists existing Data Access Governance report status via
      Get-SPODataAccessGovernanceInsight for the supplied -DAGReportEntities (does not create
      new reports — Start-SPODataAccessGovernanceInsight is intentionally NOT called here to
      keep this script strictly non-mutating).
    - -CheckIdleSignOut: reads Get-SPOBrowserIdleSignOut and flags IDLE_SIGNOUT_DISABLED or
      IDLE_SIGNOUT_MISCONFIGURED (SignOutAfter <= WarnAfter).
    - -CheckRestrictedSiteCreationForApps: reads Get-SPORestrictedSiteCreationForApps.

    Does NOT modify any tenant or site setting, does NOT enable/disable RAC or RCD, and does NOT
    trigger new DAG report generation, site access reviews, or audit data collection — this is a
    read-only audit companion to the Common Fix Paths / Remediation Playbooks documented in
    Advanced-Management-B.md and Advanced-Management-A.md.

.PARAMETER TenantAdminUrl
    The SharePoint admin center URL (e.g. https://contoso-admin.sharepoint.com). Required.

.PARAMETER SiteUrls
    One or more SharePoint (or OneDrive) site URLs to audit for RAC/RCD/lock-state posture.
    Optional — if omitted, only tenant-level checks run.

.PARAMETER RACGroupLimitWarningThreshold
    Number of RestrictedAccessControlGroups (out of the documented max of 10) that triggers a
    RAC_GROUP_LIMIT_NEAR flag. Default: 8.

.PARAMETER CheckDAGReports
    Switch. If set, lists existing Data Access Governance report statuses for each entity in
    -DAGReportEntities. Read-only — never starts a new report.

.PARAMETER DAGReportEntities
    Report entities to check when -CheckDAGReports is used.
    Default: PermissionedUsers, SharingLinks_Anyone, EveryoneExceptExternalUsersAtSite.

.PARAMETER CheckIdleSignOut
    Switch. If set, reads and reports the tenant's idle session sign-out configuration.

.PARAMETER CheckRestrictedSiteCreationForApps
    Switch. If set, reads and reports the tenant's restricted-site-creation-by-apps configuration
    (a SharePoint Advanced Management Plan 1 feature — may itself return a licensing flag).

.PARAMETER OutputPath
    Directory to save the CSV report(s). Defaults to the current directory.

.EXAMPLE
    .\Get-SPAdvancedManagementAudit.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com `
        -SiteUrls "https://contoso.sharepoint.com/sites/Finance","https://contoso.sharepoint.com/sites/HR"

.EXAMPLE
    .\Get-SPAdvancedManagementAudit.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com `
        -SiteUrls "https://contoso.sharepoint.com/sites/LegalHold" `
        -CheckDAGReports -CheckIdleSignOut -CheckRestrictedSiteCreationForApps

.NOTES
    Requires:
    - Microsoft.Online.SharePoint.PowerShell module (Connect-SPOService), v16.0.25409+ recommended
      for full Data Access Governance cmdlet coverage
    - SharePoint Administrator or SharePoint Advanced Management Administrator role
    - Connect-SPOService must be used WITHOUT -Credential per Microsoft's documented SAM guidance

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No Set-/New-/Remove-/Start- SPO cmdlets that change tenant or site
    configuration are called anywhere in this script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantAdminUrl,

    [Parameter()]
    [string[]]$SiteUrls = @(),

    [Parameter()]
    [int]$RACGroupLimitWarningThreshold = 8,

    [Parameter()]
    [switch]$CheckDAGReports,

    [Parameter()]
    [string[]]$DAGReportEntities = @("PermissionedUsers", "SharingLinks_Anyone", "EveryoneExceptExternalUsersAtSite"),

    [Parameter()]
    [switch]$CheckIdleSignOut,

    [Parameter()]
    [switch]$CheckRestrictedSiteCreationForApps,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

$maxRACGroups = 10

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting SharePoint Advanced Management (SAM) audit..." "INFO"

if (-not (Get-Module -Name "Microsoft.Online.SharePoint.PowerShell" -ListAvailable)) {
    Write-Status "Microsoft.Online.SharePoint.PowerShell module not found. Install with: Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser -AllowClobber" "ERROR"
    exit 1
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Connecting to SharePoint Admin Center: $TenantAdminUrl (no -Credential, per SAM guidance)" "INFO"
try {
    Connect-SPOService -Url $TenantAdminUrl -ErrorAction Stop
    Write-Status "Connected to SPO Management Shell" "OK"
} catch {
    Write-Status "Failed to connect to SPO Management Shell: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ------------------------------------------
# TENANT-LEVEL CHECKS
# ------------------------------------------

$tenantFlags = [System.Collections.Generic.List[string]]::new()
$tenant = Get-SPOTenant

# Dynamically discover any Restricted*/RAC/RCD-related properties rather than hardcoding an
# unconfirmed property name — Microsoft has renamed/added SAM tenant properties across releases.
$tenantSamProps = $tenant.PSObject.Properties | Where-Object { $_.Name -match "Restricted" }

$tenantSamSummary = [ordered]@{}
foreach ($prop in $tenantSamProps) {
    $tenantSamSummary[$prop.Name] = $prop.Value
}

if ($tenant.PSObject.Properties.Match("DelegateRestrictedAccessControlManagement").Count -gt 0 -and
    $tenant.DelegateRestrictedAccessControlManagement) {
    $tenantFlags.Add("TENANT_RAC_DELEGATION_ENABLED")
}

if ($tenant.PSObject.Properties.Match("DelegateRestrictedContentDiscoverabilityManagement").Count -gt 0 -and
    $tenant.DelegateRestrictedContentDiscoverabilityManagement) {
    $tenantFlags.Add("TENANT_RCD_DELEGATION_ENABLED")
}

if ($tenant.PSObject.Properties.Match("AllowSharingOutsideRestrictedAccessControlGroups").Count -gt 0 -and
    $tenant.AllowSharingOutsideRestrictedAccessControlGroups) {
    $tenantFlags.Add("TENANT_SHARING_BYPASSES_RAC")
}

Write-Status "Tenant-level SAM properties discovered: $($tenantSamProps.Count)" "INFO"
if ($tenantFlags.Count -gt 0) {
    Write-Status "Tenant flags: $($tenantFlags -join '; ')" "WARN"
} else {
    Write-Status "No tenant-level SAM flags raised" "OK"
}

# ------------------------------------------
# SITE-LEVEL CHECKS
# ------------------------------------------

$siteReport = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($siteUrl in $SiteUrls) {
    Write-Status "Auditing site: $siteUrl" "INFO"
    $flags = [System.Collections.Generic.List[string]]::new()

    try {
        $site = Get-SPOSite -Identity $siteUrl -ErrorAction Stop
    } catch {
        Write-Status "  Could not retrieve site $siteUrl : $($_.Exception.Message)" "ERROR"
        $siteReport.Add([PSCustomObject]@{
            SiteUrl = $siteUrl; LockState = "N/A"; SharingCapability = "N/A"
            RestrictedAccessControl = "N/A"; RestrictedAccessControlGroupCount = -1
            RestrictContentOrgWideSearch = "N/A"; Flags = "SITE_LOOKUP_FAILED"; Severity = "HIGH"
        })
        continue
    }

    $isOneDriveSite = $siteUrl -match "-my\.sharepoint\.com/personal/"

    $racEnabled = $false
    if ($site.PSObject.Properties.Match("RestrictedAccessControl").Count -gt 0) {
        $racEnabled = [bool]$site.RestrictedAccessControl
    }

    $racGroups = @()
    if ($site.PSObject.Properties.Match("RestrictedAccessControlGroups").Count -gt 0 -and $site.RestrictedAccessControlGroups) {
        $racGroups = @($site.RestrictedAccessControlGroups)
    }
    $racGroupCount = $racGroups.Count

    if ($racEnabled -and $racGroupCount -eq 0) {
        $flags.Add("RAC_ENABLED_NO_GROUPS")
    }
    if ($racGroupCount -ge $RACGroupLimitWarningThreshold -and $racGroupCount -le $maxRACGroups) {
        $flags.Add("RAC_GROUP_LIMIT_NEAR")
    }

    $rcdEnabled = $false
    if ($site.PSObject.Properties.Match("RestrictContentOrgWideSearch").Count -gt 0) {
        $rcdEnabled = [bool]$site.RestrictContentOrgWideSearch
    }
    if ($rcdEnabled -and $isOneDriveSite) {
        $flags.Add("RCD_ON_ONEDRIVE_ATTEMPTED")
    }

    if ($site.LockState -and $site.LockState -ne "Unlock") {
        $flags.Add("SITE_LOCKED_$($site.LockState.ToUpper())")
    }

    $severity = if ($flags -match "SITE_LOOKUP_FAILED|SITE_LOCKED") { "HIGH" }
                elseif ($flags.Count -gt 0) { "MEDIUM" }
                else { "OK" }

    $siteReport.Add([PSCustomObject]@{
        SiteUrl                           = $siteUrl
        LockState                         = $site.LockState
        SharingCapability                 = $site.SharingCapability
        RestrictedAccessControl           = $racEnabled
        RestrictedAccessControlGroupCount = $racGroupCount
        RestrictContentOrgWideSearch      = $rcdEnabled
        Flags                              = ($flags -join "; ")
        Severity                           = $severity
    })
}

# ------------------------------------------
# OPTIONAL: DAG REPORT STATUS (read-only listing, never starts a report)
# ------------------------------------------

$dagReport = [System.Collections.Generic.List[PSCustomObject]]::new()
if ($CheckDAGReports) {
    Write-Status "Checking Data Access Governance report status for $($DAGReportEntities.Count) entit(y/ies)..." "INFO"
    foreach ($entity in $DAGReportEntities) {
        try {
            $reports = Get-SPODataAccessGovernanceInsight -ReportEntity $entity -ErrorAction Stop
            if (-not $reports) {
                $dagReport.Add([PSCustomObject]@{
                    ReportEntity = $entity; ReportId = "N/A"; Status = "NO_REPORT_FOUND"
                    TriggeredDateTime = "N/A"; Flag = "NO_REPORT_EVER_RUN"
                })
                continue
            }
            foreach ($r in @($reports)) {
                $flag = switch ($r.Status) {
                    "NotStarted" { "REPORT_QUEUED" }
                    "InQueue"    { "REPORT_QUEUED" }
                    "Completed"  { "OK" }
                    default      { "REPORT_STATUS_$($r.Status.ToString().ToUpper())" }
                }
                $dagReport.Add([PSCustomObject]@{
                    ReportEntity      = $entity
                    ReportId          = $r.ReportId
                    Status            = $r.Status
                    TriggeredDateTime = $r.TriggeredDateTime
                    Flag              = $flag
                })
            }
        } catch {
            Write-Status "  Could not retrieve DAG report status for entity '$entity' : $($_.Exception.Message)" "WARN"
            $dagReport.Add([PSCustomObject]@{
                ReportEntity = $entity; ReportId = "N/A"; Status = "LOOKUP_FAILED"
                TriggeredDateTime = "N/A"; Flag = "DAG_LOOKUP_FAILED"
            })
        }
    }
}

# ------------------------------------------
# OPTIONAL: IDLE SESSION SIGN-OUT
# ------------------------------------------

$idleSignOutReport = $null
if ($CheckIdleSignOut) {
    Write-Status "Checking idle session sign-out configuration..." "INFO"
    try {
        $idle = Get-SPOBrowserIdleSignOut -ErrorAction Stop
        $idleFlags = [System.Collections.Generic.List[string]]::new()
        if (-not $idle.Enabled) {
            $idleFlags.Add("IDLE_SIGNOUT_DISABLED")
        }
        if ($idle.Enabled -and $idle.SignOutAfter -le $idle.WarnAfter) {
            $idleFlags.Add("IDLE_SIGNOUT_MISCONFIGURED")
        }
        $idleSignOutReport = [PSCustomObject]@{
            Enabled      = $idle.Enabled
            WarnAfter    = $idle.WarnAfter
            SignOutAfter = $idle.SignOutAfter
            Flags        = ($idleFlags -join "; ")
        }
    } catch {
        Write-Status "  Could not retrieve idle session sign-out settings: $($_.Exception.Message)" "WARN"
        $idleSignOutReport = [PSCustomObject]@{
            Enabled = "N/A"; WarnAfter = "N/A"; SignOutAfter = "N/A"; Flags = "IDLE_SIGNOUT_LOOKUP_FAILED"
        }
    }
}

# ------------------------------------------
# OPTIONAL: RESTRICTED SITE CREATION FOR APPS
# ------------------------------------------

$appCreationReport = $null
if ($CheckRestrictedSiteCreationForApps) {
    Write-Status "Checking restricted site creation for apps configuration..." "INFO"
    try {
        $appCreation = Get-SPORestrictedSiteCreationForApps -ErrorAction Stop
        $appCreationReport = $appCreation
    } catch {
        Write-Status "  Could not retrieve restricted site creation for apps settings (may require SharePoint Advanced Management Plan 1 add-on): $($_.Exception.Message)" "WARN"
        $appCreationReport = [PSCustomObject]@{ Status = "LOOKUP_FAILED_OR_UNLICENSED" }
    }
}

# ------------------------------------------
# SUMMARY
# ------------------------------------------

$separator = "=" * 60
Write-Host ""
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SHAREPOINT ADVANCED MANAGEMENT (SAM) AUDIT SUMMARY" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

Write-Status "Tenant SAM properties discovered: $($tenantSamProps.Count)" "INFO"
if ($tenantFlags.Count -gt 0) {
    Write-Status "Tenant flags: $($tenantFlags -join '; ')" "WARN"
}

if ($siteReport.Count -gt 0) {
    $high = $siteReport | Where-Object Severity -eq "HIGH"
    $med  = $siteReport | Where-Object Severity -eq "MEDIUM"
    Write-Status "Sites audited: $($siteReport.Count)" "INFO"
    Write-Status "HIGH severity: $($high.Count)" $(if ($high.Count -gt 0) { "ERROR" } else { "OK" })
    Write-Status "MEDIUM severity: $($med.Count)" $(if ($med.Count -gt 0) { "WARN" } else { "OK" })
    $siteReport | Select-Object SiteUrl, Severity, Flags | Format-Table -AutoSize -Wrap
}

if ($dagReport.Count -gt 0) {
    Write-Host "[ DATA ACCESS GOVERNANCE REPORT STATUS ]" -ForegroundColor Yellow
    $dagReport | Format-Table -AutoSize -Wrap
}

if ($idleSignOutReport) {
    Write-Host "[ IDLE SESSION SIGN-OUT ]" -ForegroundColor Yellow
    $idleSignOutReport | Format-List
}

if ($appCreationReport) {
    Write-Host "[ RESTRICTED SITE CREATION FOR APPS ]" -ForegroundColor Yellow
    $appCreationReport | Format-List
}

# ------------------------------------------
# EXPORT
# ------------------------------------------

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'

$tenantCsvPath = Join-Path $OutputPath "SAMAudit-Tenant-$stamp.csv"
[PSCustomObject]$tenantSamSummary | Select-Object *, @{N = "Flags"; E = { $tenantFlags -join "; " } } |
    Export-Csv -Path $tenantCsvPath -NoTypeInformation -Encoding UTF8
Write-Status "Tenant report exported to: $tenantCsvPath" "OK"

if ($siteReport.Count -gt 0) {
    $siteCsvPath = Join-Path $OutputPath "SAMAudit-Sites-$stamp.csv"
    $siteReport | Export-Csv -Path $siteCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "Site report exported to: $siteCsvPath" "OK"
}

if ($dagReport.Count -gt 0) {
    $dagCsvPath = Join-Path $OutputPath "SAMAudit-DAGReports-$stamp.csv"
    $dagReport | Export-Csv -Path $dagCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "DAG report status exported to: $dagCsvPath" "OK"
}

Write-Status "SharePoint Advanced Management audit complete." "OK"
