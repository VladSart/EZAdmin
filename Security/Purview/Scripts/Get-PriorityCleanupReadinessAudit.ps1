<#
.SYNOPSIS
    Audits organizational readiness for Microsoft Purview priority cleanup (hard delete) policies.

.DESCRIPTION
    Companion script to Security/Purview/PriorityCleanupHardDelete-A.md and -B.md.

    Microsoft Purview Data Lifecycle Management's priority cleanup / "Delete data permanently"
    capability (Roadmap 558343, MC1261587) has NO confirmed dedicated PowerShell or Graph cmdlet
    surface as of this writing -- policies are created and managed only in the Purview portal
    (Data Lifecycle Management > Priority cleanup). This script does NOT and cannot create, list, or
    modify priority cleanup policies, and it never issues any delete action itself.

    Instead, it audits the readiness signals this runbook's Validation Steps depend on before an org
    should safely adopt the feature:
      - eDiscovery Manager / eDiscovery Administrator role membership (the required approval gate for
        hard-deleting content under a hold)
      - Existing retention policies/holds scoped to SharePoint/OneDrive, which are the population any
        priority cleanup policy would need to gate against
      - A best-effort unified audit log sweep for delete-related SharePoint file operations, to help
        establish a baseline before the feature is adopted

    Requires: Security & Compliance PowerShell (Connect-IPPSSession) with eDiscovery/Compliance read
    rights, and SharePoint Online audit log read access.

.PARAMETER AdminUPN
    UPN to use for Connect-IPPSSession. If omitted, assumes an existing IPPS session is present.

.PARAMETER AuditDays
    Number of days back to search the unified audit log for delete-related SharePoint operations.
    Defaults to 30.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to the current user's temp folder.

.EXAMPLE
    .\Get-PriorityCleanupReadinessAudit.ps1 -AdminUPN admin@contoso.com -AuditDays 60

    Connects, audits eDiscovery role coverage and SharePoint/OneDrive holds, sweeps 60 days of audit
    log for delete operations, and exports a CSV report.

.NOTES
    Read-only. Makes NO configuration changes and issues NO delete actions of any kind. Cannot create,
    read, or modify priority cleanup policies themselves -- see .DESCRIPTION. Requires the
    ExchangeOnlineManagement module.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AdminUPN,

    [Parameter(Mandatory = $false)]
    [int]$AuditDays = 30,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = (Join-Path $env:TEMP "PriorityCleanupReadinessAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv")
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
Write-Status "Starting Purview priority cleanup readiness audit" "INFO"
Write-Status "This script is READ-ONLY and issues no delete actions. It cannot read priority cleanup" "INFO"
Write-Status "policies themselves -- no confirmed cmdlet surface exists for that as of this writing." "INFO"

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Status "ExchangeOnlineManagement module not found. Install with: Install-Module ExchangeOnlineManagement" "ERROR"
    throw "Required module missing."
}

try {
    $null = Get-RetentionCompliancePolicy -ErrorAction Stop -ResultSize 1
    Write-Status "Existing IPPS session detected." "OK"
}
catch {
    if ([string]::IsNullOrWhiteSpace($AdminUPN)) {
        Write-Status "No active session and -AdminUPN not supplied. Connecting interactively." "WARN"
        Connect-IPPSSession
    }
    else {
        Write-Status "Connecting to Security & Compliance PowerShell as $AdminUPN" "INFO"
        Connect-IPPSSession -UserPrincipalName $AdminUPN
    }
}

# ---------------------------------------------------------------------------
# Detect: eDiscovery approval role coverage
# ---------------------------------------------------------------------------
Write-Status "Checking eDiscovery Manager / Administrator role membership (required approval gate)" "INFO"
$eDiscoveryManagers = Get-RoleGroupMember -Identity "eDiscovery Manager" -ErrorAction SilentlyContinue
$eDiscoveryAdmins = Get-RoleGroupMember -Identity "eDiscovery Administrator" -ErrorAction SilentlyContinue

$totalApprovers = @($eDiscoveryManagers).Count + @($eDiscoveryAdmins).Count
if ($totalApprovers -eq 0) {
    Write-Status "No eDiscovery Manager/Administrator members found. Hold-protected content targeted by a priority cleanup policy would have NO approver path -- this must be resolved before adopting the feature for any held content." "ERROR"
}
else {
    Write-Status "Found $totalApprovers eDiscovery Manager/Administrator member(s) who could approve hold-protected hard deletes." "OK"
}

# ---------------------------------------------------------------------------
# Detect: SharePoint/OneDrive retention policies and holds (the gate population)
# ---------------------------------------------------------------------------
Write-Status "Enumerating retention policies scoped to SharePoint/OneDrive" "INFO"
$spoPolicies = Get-RetentionCompliancePolicy -ErrorAction SilentlyContinue |
    Where-Object { $_.SharePointLocation -or $_.OneDriveLocation }
Write-Status "Found $($spoPolicies.Count) retention polic(ies) covering SharePoint/OneDrive locations -- any of this content is a candidate for the hold-approval gate if targeted by a future priority cleanup policy." "INFO"

# ---------------------------------------------------------------------------
# Detect: recent delete-related SharePoint audit activity (baseline)
# ---------------------------------------------------------------------------
Write-Status "Sweeping unified audit log for delete-related SharePoint file operations (last $AuditDays days, best-effort baseline)" "INFO"
$auditFindings = @()
try {
    $auditFindings = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-$AuditDays) -EndDate (Get-Date) `
        -RecordType SharePointFileOperation -ResultSize 1000 -ErrorAction Stop |
        Where-Object { $_.Operations -match "Delete" }
    Write-Status "Found $($auditFindings.Count) delete-related SharePoint operations in the audit log window (baseline only -- this predates any priority cleanup policy and does not itself indicate hard-delete activity)." "INFO"
}
catch {
    Write-Status "Unable to search unified audit log in this context ($($_.Exception.Message)). Skipping audit baseline -- verify audit log search permissions separately." "WARN"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "=== Summary ===" "INFO"
Write-Host ""
Write-Host "eDiscovery approval role coverage:" -ForegroundColor Cyan
Write-Host "  eDiscovery Manager members       : $(@($eDiscoveryManagers).Count)"
Write-Host "  eDiscovery Administrator members : $(@($eDiscoveryAdmins).Count)"

Write-Host ""
Write-Host "SharePoint/OneDrive retention policies (hold-gate population):" -ForegroundColor Cyan
$spoPolicies | Select-Object Name, Enabled, SharePointLocation, OneDriveLocation | Format-Table -AutoSize

Write-Host ""
Write-Host "Recent delete-related SharePoint audit activity (baseline, last $AuditDays days):" -ForegroundColor Cyan
if ($auditFindings.Count -gt 0) {
    $auditFindings | Select-Object CreationDate, UserIds, Operations | Format-Table -AutoSize
}
else {
    Write-Host "  (none found or not readable in this context)" -ForegroundColor Yellow
}

$exportData = @()
$exportData += [PSCustomObject]@{ Type = "ApproverCount"; Name = "eDiscovery Manager"; Value = @($eDiscoveryManagers).Count }
$exportData += [PSCustomObject]@{ Type = "ApproverCount"; Name = "eDiscovery Administrator"; Value = @($eDiscoveryAdmins).Count }
$exportData += $spoPolicies | Select-Object @{N = "Type"; E = { "SharePointOneDrivePolicy" } }, Name, Enabled
$exportData += $auditFindings | Select-Object @{N = "Type"; E = { "AuditBaseline" } }, CreationDate, UserIds, Operations

$exportData | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to $ExportPath" "OK"

Write-Host ""
Write-Status "REMINDER: This script cannot read, create, or modify priority cleanup policies themselves." "WARN"
Write-Status "Confirm actual policy existence and scope directly in the Purview portal: Data Lifecycle Management > Priority cleanup." "WARN"
Write-Status "This script never issues a delete action of any kind." "WARN"
