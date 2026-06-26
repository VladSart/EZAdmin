<#
.SYNOPSIS
    Audits Privileged Identity Management (PIM) role assignments and activation history.

.DESCRIPTION
    Connects to Microsoft Graph and retrieves:
    - All PIM-eligible and active role assignments (Entra ID directory roles)
    - Permanent active role assignments (assignments that bypass PIM activation)
    - Recent PIM activation history (default: past 7 days)
    - Roles with no expiry set (potential over-privileged accounts)
    - Summary statistics per role

    Output is exported to a CSV file for compliance review and sign-off.
    Requires Microsoft.Graph PowerShell module (Graph API, not legacy AzureAD).

    Safe to run in any tenant — read-only Graph API calls only.

.PARAMETER Days
    Number of days of activation history to retrieve. Default: 7.

.PARAMETER OutputPath
    Path for the CSV report. Default: current directory with timestamp.

.PARAMETER TenantId
    Optional. Target tenant ID. If omitted, uses the authenticated tenant.

.EXAMPLE
    .\Get-PIMReport.ps1
    # Runs with defaults: 7 days of history, output to current directory

.EXAMPLE
    .\Get-PIMReport.ps1 -Days 30 -OutputPath "C:\Reports\PIM"
    # 30-day history, saves to C:\Reports\PIM\

.NOTES
    Requires: Microsoft.Graph module (Install-Module Microsoft.Graph -Scope CurrentUser)
    Permissions needed (delegated): RoleManagement.Read.Directory, AuditLog.Read.All, Directory.Read.All
    Safe: Read-only. No changes made to the tenant.
    Run as: Any user with at least Security Reader role in Entra ID.
#>
[CmdletBinding()]
param(
    [int]$Days       = 7,
    [string]$OutputPath = ".",
    [string]$TenantId   = ""
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

# ─── Preflight: module check ─────────────────────────────────────────────────

Write-Status "Checking for Microsoft.Graph module..."
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.Governance)) {
    Write-Status "Microsoft.Graph not found. Installing..." "WARN"
    Install-Module Microsoft.Graph -Scope CurrentUser -Force -Repository PSGallery
}
Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.Governance,
               Microsoft.Graph.DirectoryObjects, Microsoft.Graph.Users -ErrorAction SilentlyContinue

# ─── Connect ─────────────────────────────────────────────────────────────────

Write-Status "Connecting to Microsoft Graph..."
$ConnectParams = @{
    Scopes = @(
        "RoleManagement.Read.Directory",
        "AuditLog.Read.All",
        "Directory.Read.All"
    )
}
if ($TenantId) { $ConnectParams.TenantId = $TenantId }
Connect-MgGraph @ConnectParams -NoWelcome
Write-Status "Connected to Graph." "OK"

# ─── Collect directory roles (role definitions) ───────────────────────────────

Write-Status "Retrieving Entra ID role definitions..."
$RoleDefs = Get-MgRoleManagementDirectoryRoleDefinition -All
$RoleMap   = @{}
foreach ($r in $RoleDefs) { $RoleMap[$r.Id] = $r.DisplayName }
Write-Status "Found $($RoleDefs.Count) role definitions." "OK"

# ─── Eligible assignments (PIM-managed) ───────────────────────────────────────

Write-Status "Retrieving PIM eligible role assignments..."
try {
    $EligibleAssignments = Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -All
    Write-Status "Found $($EligibleAssignments.Count) eligible assignments." "OK"
} catch {
    Write-Status "Could not retrieve eligible assignments (PIM may not be licensed): $_" "WARN"
    $EligibleAssignments = @()
}

# ─── Active assignments (currently activated or permanent) ───────────────────

Write-Status "Retrieving active role assignments..."
try {
    $ActiveAssignments = Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance -All
    Write-Status "Found $($ActiveAssignments.Count) active assignments." "OK"
} catch {
    Write-Status "Could not retrieve active schedule instances: $_" "WARN"
    $ActiveAssignments = @()
}

# Also get permanent (non-PIM) assignments via the classic role assignment API
Write-Status "Retrieving permanent (non-PIM) direct role assignments..."
$PermanentAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All
Write-Status "Found $($PermanentAssignments.Count) permanent role assignments." "OK"

# ─── Activation history ───────────────────────────────────────────────────────

Write-Status "Retrieving PIM activation history for past $Days days..."
$StartDate  = (Get-Date).AddDays(-$Days).ToString("o")
$AuditFilter = "activityDateTime ge $StartDate and (activityDisplayName eq 'Add member to role in PIM completed (permanent)' or activityDisplayName eq 'Add member to role in PIM requested')"

try {
    $ActivationEvents = Get-MgAuditLogDirectoryAudit -Filter $AuditFilter -All
    Write-Status "Found $($ActivationEvents.Count) activation events in the past $Days days." "OK"
} catch {
    Write-Status "Could not retrieve audit log events: $_" "WARN"
    $ActivationEvents = @()
}

# ─── Build eligible assignment report ─────────────────────────────────────────

Write-Status "Building eligible assignments report..."
$EligibleReport = foreach ($a in $EligibleAssignments) {
    $RoleName = $RoleMap[$a.RoleDefinitionId] ?? $a.RoleDefinitionId

    # Resolve principal display name
    try {
        $Principal = Get-MgUser -UserId $a.PrincipalId -ErrorAction SilentlyContinue
        $DisplayName = $Principal.DisplayName
        $UPN         = $Principal.UserPrincipalName
        $PrincipalType = "User"
    } catch {
        try {
            $Group = Get-MgGroup -GroupId $a.PrincipalId -ErrorAction SilentlyContinue
            $DisplayName   = $Group.DisplayName
            $UPN           = "N/A (Group)"
            $PrincipalType = "Group"
        } catch {
            $DisplayName   = $a.PrincipalId
            $UPN           = "Unknown"
            $PrincipalType = "Unknown"
        }
    }

    $HasExpiry    = -not [string]::IsNullOrEmpty($a.EndDateTime)
    $DaysToExpiry = if ($HasExpiry) {
        [math]::Round(($a.EndDateTime - (Get-Date)).TotalDays, 1)
    } else { "NoExpiry" }

    [PSCustomObject]@{
        ReportType      = "Eligible"
        DisplayName     = $DisplayName
        UPN             = $UPN
        PrincipalType   = $PrincipalType
        RoleName        = $RoleName
        AssignmentType  = $a.AssignmentType   # "Assigned" or "Activated"
        StartDateTime   = $a.StartDateTime
        EndDateTime     = $a.EndDateTime
        HasExpiry       = $HasExpiry
        DaysToExpiry    = $DaysToExpiry
        MemberType      = $a.MemberType       # "Direct" or "Group"
        Scope           = $a.DirectoryScopeId
        PrincipalId     = $a.PrincipalId
        RoleDefinitionId = $a.RoleDefinitionId
    }
}

# ─── Build active assignment report ──────────────────────────────────────────

Write-Status "Building active assignments report..."
$ActiveReport = foreach ($a in $ActiveAssignments) {
    $RoleName = $RoleMap[$a.RoleDefinitionId] ?? $a.RoleDefinitionId

    try {
        $Principal     = Get-MgUser -UserId $a.PrincipalId -ErrorAction SilentlyContinue
        $DisplayName   = $Principal.DisplayName
        $UPN           = $Principal.UserPrincipalName
        $PrincipalType = "User"
    } catch {
        try {
            $Group         = Get-MgGroup -GroupId $a.PrincipalId -ErrorAction SilentlyContinue
            $DisplayName   = $Group.DisplayName
            $UPN           = "N/A (Group)"
            $PrincipalType = "Group"
        } catch {
            $DisplayName   = $a.PrincipalId
            $UPN           = "Unknown"
            $PrincipalType = "Unknown"
        }
    }

    $HasExpiry    = -not [string]::IsNullOrEmpty($a.EndDateTime)
    $DaysToExpiry = if ($HasExpiry) {
        [math]::Round(($a.EndDateTime - (Get-Date)).TotalDays, 1)
    } else { "NoExpiry" }

    [PSCustomObject]@{
        ReportType       = "Active"
        DisplayName      = $DisplayName
        UPN              = $UPN
        PrincipalType    = $PrincipalType
        RoleName         = $RoleName
        AssignmentType   = $a.AssignmentType
        StartDateTime    = $a.StartDateTime
        EndDateTime      = $a.EndDateTime
        HasExpiry        = $HasExpiry
        DaysToExpiry     = $DaysToExpiry
        MemberType       = $a.MemberType
        Scope            = $a.DirectoryScopeId
        PrincipalId      = $a.PrincipalId
        RoleDefinitionId = $a.RoleDefinitionId
    }
}

# ─── Build activation history report ─────────────────────────────────────────

Write-Status "Building activation history report..."
$HistoryReport = foreach ($e in $ActivationEvents) {
    $Initiator   = $e.InitiatedBy.User.DisplayName ?? $e.InitiatedBy.User.Id ?? "Unknown"
    $InitiatorUPN = $e.InitiatedBy.User.UserPrincipalName ?? "N/A"
    $TargetUser  = ($e.TargetResources | Where-Object Type -eq "User" | Select-Object -First 1).DisplayName ?? "N/A"
    $RoleName    = ($e.TargetResources | Where-Object Type -eq "Role" | Select-Object -First 1).DisplayName ?? "N/A"
    $Result      = $e.Result
    $Justification = ($e.AdditionalDetails | Where-Object Key -eq "justification").Value ?? ""

    [PSCustomObject]@{
        EventTime      = $e.ActivityDateTime
        ActivityName   = $e.ActivityDisplayName
        Result         = $Result
        InitiatedBy    = $Initiator
        InitiatorUPN   = $InitiatorUPN
        TargetUser     = $TargetUser
        RoleName       = $RoleName
        Justification  = $Justification
        CorrelationId  = $e.CorrelationId
    }
}

# ─── Identify risk flags ──────────────────────────────────────────────────────

Write-Status "Identifying risk flags..."

# Permanent (non-PIM) high-privilege assignments
$HighPrivRoles = @(
    "Global Administrator",
    "Privileged Role Administrator",
    "Security Administrator",
    "Exchange Administrator",
    "SharePoint Administrator",
    "User Administrator",
    "Intune Administrator",
    "Hybrid Identity Administrator",
    "Application Administrator",
    "Cloud Application Administrator"
)

$PermanentReport = foreach ($a in $PermanentAssignments) {
    $RoleName = $RoleMap[$a.RoleDefinitionId] ?? $a.RoleDefinitionId
    $IsHighPriv = $HighPrivRoles -contains $RoleName

    try {
        $Principal     = Get-MgUser -UserId $a.PrincipalId -ErrorAction SilentlyContinue
        $DisplayName   = $Principal.DisplayName
        $UPN           = $Principal.UserPrincipalName
        $PrincipalType = "User"
    } catch {
        try {
            $Group         = Get-MgGroup -GroupId $a.PrincipalId -ErrorAction SilentlyContinue
            $DisplayName   = $Group.DisplayName
            $UPN           = "N/A (Group)"
            $PrincipalType = "Group"
        } catch {
            $DisplayName   = $a.PrincipalId
            $UPN           = "Unknown"
            $PrincipalType = "Unknown"
        }
    }

    [PSCustomObject]@{
        ReportType       = "Permanent (No PIM)"
        DisplayName      = $DisplayName
        UPN              = $UPN
        PrincipalType    = $PrincipalType
        RoleName         = $RoleName
        IsHighPrivilege  = $IsHighPriv
        Scope            = $a.DirectoryScopeId
        PrincipalId      = $a.PrincipalId
        RoleDefinitionId = $a.RoleDefinitionId
    }
}

# ─── Export reports ───────────────────────────────────────────────────────────

$Date = Get-Date -Format "yyyyMMdd-HHmm"
$OutDir = Resolve-Path $OutputPath

$EligibleCsv   = Join-Path $OutDir "PIM-Eligible-$Date.csv"
$ActiveCsv     = Join-Path $OutDir "PIM-Active-$Date.csv"
$HistoryCsv    = Join-Path $OutDir "PIM-ActivationHistory-${Days}days-$Date.csv"
$PermanentCsv  = Join-Path $OutDir "PIM-PermanentAssignments-$Date.csv"

if ($EligibleReport)   { $EligibleReport   | Export-Csv -Path $EligibleCsv  -NoTypeInformation -Encoding UTF8 }
if ($ActiveReport)     { $ActiveReport     | Export-Csv -Path $ActiveCsv    -NoTypeInformation -Encoding UTF8 }
if ($HistoryReport)    { $HistoryReport    | Export-Csv -Path $HistoryCsv   -NoTypeInformation -Encoding UTF8 }
if ($PermanentReport)  { $PermanentReport  | Export-Csv -Path $PermanentCsv -NoTypeInformation -Encoding UTF8 }

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " PIM Audit Report — Summary" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Eligible assignments:  $($EligibleReport.Count)"
Write-Host "  Active assignments:    $($ActiveReport.Count)"
Write-Host "  Activation events:     $($HistoryReport.Count) (past $Days days)"
Write-Host "  Permanent assignments: $($PermanentReport.Count)"

$HighPrivPermanent = $PermanentReport | Where-Object IsHighPrivilege -eq $true
if ($HighPrivPermanent.Count -gt 0) {
    Write-Status "⚠  $($HighPrivPermanent.Count) permanent high-privilege assignments found (not managed by PIM):" "WARN"
    $HighPrivPermanent | Select DisplayName, UPN, RoleName | Format-Table -AutoSize
}

$NoExpiry = ($EligibleReport + $ActiveReport) | Where-Object HasExpiry -eq $false
if ($NoExpiry.Count -gt 0) {
    Write-Status "⚠  $($NoExpiry.Count) assignments with no expiry date set." "WARN"
}

Write-Host ""
Write-Status "Reports saved to: $OutDir" "OK"
Write-Host "  $EligibleCsv"
Write-Host "  $ActiveCsv"
Write-Host "  $HistoryCsv"
Write-Host "  $PermanentCsv"

# Disconnect
Disconnect-MgGraph | Out-Null
Write-Status "Disconnected from Graph." "OK"
