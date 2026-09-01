<#
.SYNOPSIS
    Audits Microsoft Purview Compliance Manager prerequisites — licensing tier, Compliance
    Manager role-group membership, and the Unified Audit Log ingestion state that automated
    improvement-action detection depends on.

.DESCRIPTION
    Automates the licensing, access, and audit-log Validation Steps from
    ComplianceManager-A.md so an analyst can rule out (or confirm) the most common
    "Compliance Manager isn't working" root causes before spending time inside a specific
    assessment or improvement action. Compliance Manager is architecturally a read/scoring
    layer over other Purview and Entra features — it never configures anything itself — so
    this script deliberately stays scoped to Compliance Manager's own prerequisites and does
    NOT attempt to validate the dozens of underlying features (DLP, Retention, Sensitivity
    Labels, Insider Risk, Priva, CA, MFA, etc.) any given improvement action might point to;
    each of those has its own dedicated script/runbook in this repo.

    Covers:
    - Compliance-tier licensing presence via Get-MgSubscribedSku, matched against a
      configurable SKU-name pattern (E5/Compliance/EMS Premium by default) — flags
      NO_COMPLIANCE_LICENSE if nothing matches, since template/action availability is
      licensing-gated
    - Compliance Manager's own role-group membership (Reader, Contributor, Assessor,
      Administrator) — deliberately checked independently of any Entra directory role or
      broader Purview compliance portal role group the caller may hold, since Compliance
      Manager's role model does NOT inherit from either; flags EMPTY_ROLE_GROUPS if every
      role group is empty, meaning only an emergency Global Admin path exists into the tool
    - Unified Audit Log ingestion state — a hard prerequisite for automated improvement-action
      detection and for the audit-log-based root-cause investigation Playbook 2 in
      ComplianceManager-A.md depends on; flags NO_AUDIT_LOG if disabled
    - Cross-reference count of Compliance Manager role group membership vs. broader Purview
      "Compliance Administrator"/"Compliance Data Administrator" role group membership,
      surfaced as informational context (CM_ROLE_ENTRA_ROLE_MISMATCH) for the very common
      "I'm a Global Admin, why can't I update this action" ticket pattern

    Does NOT cover:
    - Assessment/control/improvement-action inventory, Compliance Score calculation, or
      "Managed by"/detection-method attributes — these are exposed through the Purview portal
      UI only as of this writing; verify current Graph API coverage before assuming parity
    - Any underlying feature's actual configuration state (DLP, Retention, CA, etc.) — use
      that feature's own script in this repo (e.g. Get-PurviewDLPReport.ps1)
    - Custom assessment staleness-vs-source-template comparison — portal-only, no cmdlet
      equivalent as of this writing

.PARAMETER LicenseSkuPattern
    Regex pattern used to match compliance-tier SKUs against Get-MgSubscribedSku output.
    Default: "E5|COMPLIANCE|EMSPREMIUM".

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-ComplianceManagerReadinessAudit.ps1

.EXAMPLE
    .\Get-ComplianceManagerReadinessAudit.ps1 -LicenseSkuPattern "E5|COMPLIANCE" -OutputPath C:\Temp\CM

.NOTES
    Requires:
    - Microsoft.Graph.Identity.DirectoryManagement module (Get-MgSubscribedSku,
      Get-MgDirectoryRole, Get-MgDirectoryRoleMember) — connect via Connect-MgGraph with at
      least Directory.Read.All and Organization.Read.All before running
    - ExchangeOnlineManagement module (Connect-IPPSSession) for the Unified Audit Log check

    Run-as: Does NOT require local admin. Requires M365 cloud read permissions as above.
    Safe/Unsafe: Read-only. No changes made to licensing, RBAC, or audit log configuration.
#>

[CmdletBinding()]
param(
    [string]$LicenseSkuPattern = "E5|COMPLIANCE|EMSPREMIUM",
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path -Path $OutputPath -ChildPath "ComplianceManager-Readiness-$timestamp"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
Write-Status "Report folder: $reportDir"

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string]$Check, [string]$Flag, [string]$Detail, [string]$Severity = "Info")
    $findings.Add([PSCustomObject]@{
        Check    = $Check
        Flag     = $Flag
        Severity = $Severity
        Detail   = $Detail
    })
}

# ---------------------------------------------------------------------------
# 1. Compliance-tier licensing
# ---------------------------------------------------------------------------
Write-Status "Checking compliance-tier licensing..."
try {
    $skus = Get-MgSubscribedSku -ErrorAction Stop |
        Where-Object { $_.SkuPartNumber -match $LicenseSkuPattern } |
        Select-Object SkuPartNumber, @{N='ConsumedUnits';E={$_.ConsumedUnits}}, @{N='PrepaidUnits';E={$_.PrepaidUnits.Enabled}}
    if ($skus) {
        $skus | Export-Csv (Join-Path $reportDir "ComplianceLicensing.csv") -NoTypeInformation
        Write-Status "Compliance-tier SKU(s) found: $(($skus.SkuPartNumber) -join ', ')" "OK"
    } else {
        Add-Finding -Check "Licensing" -Flag "NO_COMPLIANCE_LICENSE" -Severity "Error" `
            -Detail "No SKU matched pattern '$LicenseSkuPattern' via Get-MgSubscribedSku. Premium assessment templates and detailed improvement-action data will be unavailable or reduced — confirm expected licensing tier with the client before troubleshooting further."
    }
} catch {
    Add-Finding -Check "Licensing" -Flag "SKU_QUERY_FAILED" -Severity "Error" -Detail $_.Exception.Message
    Write-Status "Get-MgSubscribedSku failed — is Connect-MgGraph established with Organization.Read.All? $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# 2. Compliance Manager role-group membership
#    (Reader / Contributor / Assessor / Administrator — separate from Entra directory
#    roles and broader Purview compliance portal role groups, per ComplianceManager-A.md)
# ---------------------------------------------------------------------------
Write-Status "Checking Compliance Manager role-group membership..."
$cmRoleGroups = @(
    "Compliance Manager Readers",
    "Compliance Manager Contributors",
    "Compliance Manager Assessors",
    "Compliance Manager Administrators"
)
$cmMembershipRows = [System.Collections.Generic.List[object]]::new()
$anyCmGroupPopulated = $false
foreach ($groupName in $cmRoleGroups) {
    try {
        $role = Get-MgDirectoryRole -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue
        if (-not $role) {
            $cmMembershipRows.Add([PSCustomObject]@{ RoleGroup = $groupName; MemberCount = $null; Note = "Role group not found/activated in this tenant" })
            continue
        }
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -ErrorAction SilentlyContinue
        $count = if ($members) { $members.Count } else { 0 }
        $cmMembershipRows.Add([PSCustomObject]@{ RoleGroup = $groupName; MemberCount = $count; Note = "" })
        if ($count -gt 0) { $anyCmGroupPopulated = $true }
    } catch {
        $cmMembershipRows.Add([PSCustomObject]@{ RoleGroup = $groupName; MemberCount = $null; Note = $_.Exception.Message })
    }
}
$cmMembershipRows | Export-Csv (Join-Path $reportDir "ComplianceManagerRoleGroups.csv") -NoTypeInformation

if (-not $anyCmGroupPopulated) {
    Add-Finding -Check "RBAC" -Flag "EMPTY_ROLE_GROUPS" -Severity "Warn" `
        -Detail "All four Compliance Manager role groups (Reader/Contributor/Assessor/Administrator) appear empty or unresolvable. Only an emergency Global Admin path exists into the tool — this is the single most common 'why can't I update this action' ticket root cause per ComplianceManager-A.md, since Compliance Manager's role model does NOT inherit from Entra directory roles."
} else {
    Write-Status "At least one Compliance Manager role group is populated." "OK"
}

# Informational: broad Purview compliance-portal role groups, so a Global Admin / Compliance
# Administrator holder can see at a glance that their existing access does not carry over.
try {
    $broadGroups = @("Compliance Administrator", "Compliance Data Administrator")
    $broadCounts = foreach ($g in $broadGroups) {
        $r = Get-MgDirectoryRole -Filter "displayName eq '$g'" -ErrorAction SilentlyContinue
        if ($r) {
            $m = Get-MgDirectoryRoleMember -DirectoryRoleId $r.Id -ErrorAction SilentlyContinue
            [PSCustomObject]@{ RoleGroup = $g; MemberCount = if ($m) { $m.Count } else { 0 } }
        }
    }
    if ($broadCounts -and ($broadCounts | Where-Object { $_.MemberCount -gt 0 }) -and -not $anyCmGroupPopulated) {
        Add-Finding -Check "RBAC" -Flag "CM_ROLE_ENTRA_ROLE_MISMATCH" -Severity "Info" `
            -Detail "Broader Purview compliance role groups (Compliance Administrator / Compliance Data Administrator) have members, but no dedicated Compliance Manager role group does. These are separate role models — broad Purview/Entra admin access does not grant Compliance Manager Contributor/Assessor/Administrator access."
    }
} catch {
    # Non-fatal — this is informational context only.
}

# ---------------------------------------------------------------------------
# 3. Unified Audit Log ingestion state
#    (hard prerequisite for automated improvement-action detection refresh and for
#    audit-log-based score-drop investigation per ComplianceManager-A.md Playbook 2)
# ---------------------------------------------------------------------------
Write-Status "Checking Unified Audit Log ingestion state..."
try {
    $auditConfig = Get-AdminAuditLogConfig -ErrorAction Stop
    if ($auditConfig.UnifiedAuditLogIngestionEnabled -eq $false) {
        Add-Finding -Check "Audit Log" -Flag "NO_AUDIT_LOG" -Severity "Error" `
            -Detail "UnifiedAuditLogIngestionEnabled is False. Automated improvement-action detection and audit-log-based score-drop investigation both depend on this — enable via Enable-OrganizationCustomization / Set-AdminAuditLogConfig before troubleshooting detection-timing complaints further."
    } else {
        Write-Status "Unified Audit Log ingestion is enabled." "OK"
    }
} catch {
    Add-Finding -Check "Audit Log" -Flag "AUDIT_CONFIG_QUERY_FAILED" -Severity "Info" `
        -Detail "Get-AdminAuditLogConfig failed — is Connect-IPPSSession established? $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$findings | Export-Csv (Join-Path $reportDir "Findings.csv") -NoTypeInformation

Write-Host ""
Write-Host "=== Compliance Manager Readiness Summary ===" -ForegroundColor Cyan
if ($findings.Count -eq 0) {
    Write-Status "No issues flagged." "OK"
} else {
    foreach ($f in ($findings | Sort-Object @{Expression = { switch ($_.Severity) { "Error" {0} "Warn" {1} default {2} } }})) {
        Write-Status "[$($f.Check)] $($f.Flag): $($f.Detail)" $(switch ($f.Severity) { "Error" {"ERROR"} "Warn" {"WARN"} default {"INFO"} })
    }
}

Write-Host ""
Write-Status "Full report exported to: $reportDir" "OK"
Compress-Archive -Path "$reportDir\*" -DestinationPath "$reportDir.zip" -Force
Write-Status "Archive: $reportDir.zip" "OK"
