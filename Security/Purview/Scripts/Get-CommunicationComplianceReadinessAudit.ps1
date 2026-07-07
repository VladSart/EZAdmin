<#
.SYNOPSIS
    Audits the environment prerequisites for Microsoft Purview Communication Compliance.

.DESCRIPTION
    Communication Compliance has NO PowerShell support for creating, editing, or querying policies —
    Microsoft's own documentation states this explicitly (see CommunicationCompliance-A.md). This script
    therefore does not (and cannot) report on policy configuration, matches, or alerts. Instead it audits
    every adjacent prerequisite that IS scriptable and that, per the companion runbooks, accounts for the
    large majority of real-world "Communication Compliance isn't working" tickets:

    1. Unified Audit Log ingestion state (Layer 1 — single data pipe; nothing works if this is off)
    2. Communication Compliance role group membership, flagging a zero-admin lockout risk
       (CC Admins / Communication Compliance both empty = nobody, including Global Admin, can configure policy)
    3. Reviewer/analyst/investigator prerequisite check for a supplied list of UPNs — Exchange Online
       mailbox hosting + correct role group membership
    4. Communication Compliance-qualifying licence/service-plan presence for a supplied list of users
    5. Teams "Report inappropriate content" end-user reporting state (AllowSecurityEndUserReporting) across
       all Teams messaging policies — this feeds the CC "User-reported messages" system policy
    6. Optional: compliance-boundary security filter check for the legacy SupervisoryReview{*} mailbox
       naming pattern, since eDiscovery compliance boundaries can silently block CC admins/reviewers

    Read-only. Makes no policy, role group, licence, or filter changes.

.PARAMETER UsersToCheck
    One or more UPNs to check for Communication Compliance-qualifying licences (e.g. scoped users).

.PARAMETER ReviewersToCheck
    One or more UPNs to check against the reviewer prerequisites: Exchange Online mailbox +
    membership in Communication Compliance Analysts or Communication Compliance Investigators.

.PARAMETER CheckComplianceBoundaryFilter
    If specified, also checks for an existing compliance security filter covering the legacy
    SupervisoryReview{*} mailbox pattern (relevant only if the tenant has eDiscovery compliance
    boundaries configured — degrades gracefully with a warning if the cmdlet/module isn't available).

.PARAMETER OutputPath
    Folder where CSV reports are written. Default: $env:TEMP\CommunicationComplianceReadiness-<date>

.EXAMPLE
    .\Get-CommunicationComplianceReadinessAudit.ps1

.EXAMPLE
    .\Get-CommunicationComplianceReadinessAudit.ps1 -UsersToCheck alice@contoso.com,bob@contoso.com -ReviewersToCheck reviewer1@contoso.com -CheckComplianceBoundaryFilter

.NOTES
    Requires: ExchangeOnlineManagement module + Connect-IPPSSession (role groups, EXO mailbox checks,
              compliance boundary filter), Microsoft.Graph.Users / Microsoft.Graph.Identity.DirectoryManagement
              (licence checks), MicrosoftTeams module (Teams reporting policy check).
    Run as:   A user with Communication Compliance Admins-equivalent access (Global Admin, Compliance
              Admin, or the Communication Compliance / Communication Compliance Admins role group).
    Safe to run repeatedly — entirely read-only.
    Companion runbooks: Security/Purview/CommunicationCompliance-A.md, CommunicationCompliance-B.md
#>

[CmdletBinding()]
param(
    [string[]]$UsersToCheck = @(),
    [string[]]$ReviewersToCheck = @(),
    [switch]$CheckComplianceBoundaryFilter,
    [string]$OutputPath = "$env:TEMP\CommunicationComplianceReadiness-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-Status "Communication Compliance Readiness Audit started — $(Get-Date)" "INFO"
Write-Status "NOTE: no PowerShell/Graph surface exists for CC policy CRUD — this audits adjacent prerequisites only." "WARN"
Write-Status "Export path: $OutputPath" "INFO"
Write-Host ""

# ─── 1. Unified Audit Log ingestion ────────────────────────────────────────────

Write-Host "=== Unified Audit Log ===" -ForegroundColor Magenta
$AuditResult = [PSCustomObject]@{ Check = "UnifiedAuditLogIngestionEnabled"; Value = $null; Status = "ERROR" }
try {
    $auditConfig = Get-AdminAuditLogConfig -ErrorAction Stop
    $AuditResult.Value  = $auditConfig.UnifiedAuditLogIngestionEnabled
    $AuditResult.Status = if ($auditConfig.UnifiedAuditLogIngestionEnabled) { "OK" } else { "ERROR" }
    Write-Status "UnifiedAuditLogIngestionEnabled: $($auditConfig.UnifiedAuditLogIngestionEnabled)" $AuditResult.Status
} catch {
    Write-Status "Could not read audit log config — is ExchangeOnlineManagement connected? $($_.Exception.Message)" "WARN"
    $AuditResult.Status = "WARN"
}
$AuditResult | Export-Csv "$OutputPath\audit-log-state.csv" -NoTypeInformation
Write-Host ""

# ─── 2. Role group membership + zero-admin lockout risk ────────────────────────

Write-Host "=== Communication Compliance Role Groups ===" -ForegroundColor Magenta
$RoleGroups = "Communication Compliance","Communication Compliance Admins","Communication Compliance Analysts","Communication Compliance Investigators","Communication Compliance Viewers"
$RoleGroupResults = [System.Collections.Generic.List[PSObject]]::new()

foreach ($rg in $RoleGroups) {
    try {
        $members = Get-RoleGroupMember -Identity $rg -ErrorAction Stop
        $memberNames = ($members | Select-Object -ExpandProperty Name) -join "; "
        $status = if ($members.Count -eq 0) { "WARN" } else { "OK" }
        Write-Status "$rg — $($members.Count) member(s)" $status
    } catch {
        $memberNames = ""
        $status = "WARN"
        Write-Status "$rg — could not enumerate ($($_.Exception.Message))" "WARN"
    }
    $RoleGroupResults.Add([PSCustomObject]@{
        RoleGroup   = $rg
        MemberCount = if ($members) { $members.Count } else { 0 }
        Members     = $memberNames
        Status      = $status
    })
}

$adminEquivalents = $RoleGroupResults | Where-Object { $_.RoleGroup -in @("Communication Compliance","Communication Compliance Admins") }
$zeroAdminLockout = ($adminEquivalents | Measure-Object -Property MemberCount -Sum).Sum -eq 0
if ($zeroAdminLockout) {
    Write-Status "ZERO-ADMIN LOCKOUT RISK: both 'Communication Compliance' and 'Communication Compliance Admins' are empty." "ERROR"
    Write-Status "Nobody — not even Global Admin by default — can configure policy until this is fixed. See CommunicationCompliance-B.md Fix 2." "ERROR"
}
$RoleGroupResults | Export-Csv "$OutputPath\role-group-membership.csv" -NoTypeInformation
Write-Host ""

# ─── 3. Reviewer/Analyst/Investigator prerequisite check ───────────────────────

$ReviewerResults = [System.Collections.Generic.List[PSObject]]::new()
if ($ReviewersToCheck.Count -gt 0) {
    Write-Host "=== Reviewer Prerequisite Check ===" -ForegroundColor Magenta

    $analysts     = Get-RoleGroupMember -Identity "Communication Compliance Analysts"     -ErrorAction SilentlyContinue
    $investigators = Get-RoleGroupMember -Identity "Communication Compliance Investigators" -ErrorAction SilentlyContinue

    foreach ($rev in $ReviewersToCheck) {
        $hasExoMailbox = $false
        $recipientType = "NOT_FOUND"
        try {
            $mbx = Get-EXOMailbox -Identity $rev -ErrorAction Stop
            $hasExoMailbox = $true
            $recipientType = $mbx.RecipientTypeDetails
        } catch {
            $hasExoMailbox = $false
        }

        $inAnalysts      = [bool]($analysts      | Where-Object { $_.Name -eq $rev -or $_.PrimarySmtpAddress -eq $rev })
        $inInvestigators = [bool]($investigators | Where-Object { $_.Name -eq $rev -or $_.PrimarySmtpAddress -eq $rev })
        $eligible = $hasExoMailbox -and ($inAnalysts -or $inInvestigators)
        $status = if ($eligible) { "OK" } else { "WARN" }

        Write-Status "$rev — EXO mailbox: $hasExoMailbox ($recipientType) | Analysts: $inAnalysts | Investigators: $inInvestigators" $status

        $ReviewerResults.Add([PSCustomObject]@{
            Reviewer            = $rev
            HasExoMailbox        = $hasExoMailbox
            RecipientTypeDetails = $recipientType
            InAnalystsGroup      = $inAnalysts
            InInvestigatorsGroup = $inInvestigators
            Eligible             = $eligible
            Status               = $status
        })
    }
    $ReviewerResults | Export-Csv "$OutputPath\reviewer-prerequisite-check.csv" -NoTypeInformation
    Write-Host ""
}

# ─── 4. Licence / service plan check ────────────────────────────────────────────

$LicenceResults = [System.Collections.Generic.List[PSObject]]::new()
if ($UsersToCheck.Count -gt 0) {
    Write-Host "=== User Licence Check ===" -ForegroundColor Magenta

    foreach ($u in $UsersToCheck) {
        $hasQualifyingPlan = $false
        $planNames = ""
        try {
            $plans = (Get-MgUserLicenseDetail -UserId $u -ErrorAction Stop).ServicePlans |
                Where-Object { $_.ServicePlanName -match "COMMUNICATION_COMPLIANCE|INFORMATION_PROTECTION_COMPLIANCE" -and $_.ProvisioningStatus -eq "Success" }
            $hasQualifyingPlan = [bool]$plans
            $planNames = ($plans.ServicePlanName -join "; ")
        } catch {
            Write-Status "Could not check licence for $u — $($_.Exception.Message)" "WARN"
        }
        $status = if ($hasQualifyingPlan) { "OK" } else { "WARN" }
        Write-Status "$u — qualifying CC service plan: $hasQualifyingPlan" $status

        $LicenceResults.Add([PSCustomObject]@{
            User              = $u
            HasQualifyingPlan = $hasQualifyingPlan
            ServicePlanNames  = $planNames
            Status            = $status
        })
    }
    $LicenceResults | Export-Csv "$OutputPath\user-licence-check.csv" -NoTypeInformation
    Write-Host ""
}

# ─── 5. Teams end-user reporting policy state ──────────────────────────────────

Write-Host "=== Teams End-User Reporting (feeds CC User-reported messages policy) ===" -ForegroundColor Magenta
$TeamsResults = [System.Collections.Generic.List[PSObject]]::new()
try {
    $teamsPolicies = Get-CsTeamsMessagingPolicy -ErrorAction Stop
    foreach ($p in $teamsPolicies) {
        $status = if ($p.AllowSecurityEndUserReporting) { "OK" } else { "WARN" }
        Write-Status "$($p.Identity) — AllowSecurityEndUserReporting: $($p.AllowSecurityEndUserReporting)" $status
        $TeamsResults.Add([PSCustomObject]@{
            PolicyIdentity              = $p.Identity
            AllowSecurityEndUserReporting = $p.AllowSecurityEndUserReporting
            Status                      = $status
        })
    }
} catch {
    Write-Status "Could not read Teams messaging policies — is the MicrosoftTeams module connected? $($_.Exception.Message)" "WARN"
}
$TeamsResults | Export-Csv "$OutputPath\teams-end-user-reporting.csv" -NoTypeInformation
Write-Host ""

# ─── 6. Optional: compliance boundary filter check ─────────────────────────────

if ($CheckComplianceBoundaryFilter) {
    Write-Host "=== Compliance Boundary Filter (legacy SupervisoryReview mailbox pattern) ===" -ForegroundColor Magenta
    try {
        $filters = Get-ComplianceSecurityFilter -ErrorAction Stop |
            Where-Object { $_.Filters -like "*SupervisoryReview*" }
        if ($filters) {
            Write-Status "Found $($filters.Count) compliance security filter(s) covering SupervisoryReview mailboxes." "OK"
            $filters | Select-Object FilterName, Users, Filters, Action | Export-Csv "$OutputPath\compliance-boundary-filters.csv" -NoTypeInformation
        } else {
            Write-Status "No compliance security filter found covering SupervisoryReview{*} mailboxes." "WARN"
            Write-Status "If eDiscovery compliance boundaries are configured, CC admins/reviewers may be silently blocked. See CommunicationCompliance-A.md Playbook 3." "WARN"
        }
    } catch {
        Write-Status "Could not check compliance security filters — $($_.Exception.Message)" "WARN"
    }
    Write-Host ""
}

# ─── Summary ────────────────────────────────────────────────────────────────────

Write-Host "=== SUMMARY ===" -ForegroundColor Magenta
Write-Status "Audit log ingestion:         $($AuditResult.Status)" $AuditResult.Status
Write-Status "Zero-admin lockout risk:     $(if ($zeroAdminLockout) { 'YES — see CommunicationCompliance-B.md Fix 2' } else { 'No' })" $(if ($zeroAdminLockout) { "ERROR" } else { "OK" })
if ($ReviewerResults.Count -gt 0) {
    $ineligible = $ReviewerResults | Where-Object { -not $_.Eligible }
    Write-Status "Reviewers checked:           $($ReviewerResults.Count) ($($ineligible.Count) not eligible)" $(if ($ineligible.Count -gt 0) { "WARN" } else { "OK" })
}
if ($LicenceResults.Count -gt 0) {
    $unlicensed = $LicenceResults | Where-Object { -not $_.HasQualifyingPlan }
    Write-Status "Users checked for licence:   $($LicenceResults.Count) ($($unlicensed.Count) missing qualifying plan)" $(if ($unlicensed.Count -gt 0) { "WARN" } else { "OK" })
}

Write-Status "`nFull reports: $OutputPath" "INFO"
Write-Status "Done." "OK"
