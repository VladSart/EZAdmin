<#
.SYNOPSIS
    Audits organizational readiness for Microsoft Purview priority cleanup policies scoped to
    Exchange mailboxes.

.DESCRIPTION
    Companion script to Security/Purview/PriorityCleanupExchange-A.md and -B.md.

    Priority cleanup for Exchange (Roadmap 473493) has no confirmed dedicated PowerShell or Graph
    cmdlet surface for creating, listing, or reading policy configuration -- that remains portal-only
    (Purview portal > Data Lifecycle Management > Priority cleanup) as of this writing. This script
    does NOT and cannot create, list, or modify priority cleanup policies, and it never issues any
    delete action itself.

    Instead, it audits the specific readiness signals this feature's approval model depends on --
    signals that are meaningfully different from the SharePoint/OneDrive variant's own readiness
    script (Get-PriorityCleanupReadinessAudit.ps1), because Exchange priority cleanup requires THREE
    mandatory, individually role-staffed approver types rather than one:

      - Priority Cleanup Admin role coverage (first-stage approver, always required)
      - Retention Management role coverage (required whenever matched content has a retention
        policy/label or Litigation Hold)
      - eDiscovery admin role coverage, specifically Search And Purge + Hold (required whenever
        matched content has an eDiscovery hold)
      - Whether unified audit log ingestion has been enabled, and for how long -- a hard prerequisite
        for simulation-mode results and for auditability generally
      - A best-effort mailbox-size sweep against the documented 10-MB minimum eligibility floor for a
        supplied list of mailboxes
      - A best-effort audit-log sweep for the two dedicated priority-cleanup operation names, to
        establish whether the feature has already been used in this tenant

    This script explicitly CANNOT read: the tenant-wide priority cleanup enable/disable toggle
    (shared between Exchange and SharePoint/OneDrive), any existing policy's KeyQL query or scope
    configuration, or Pending cleanups approval-queue state -- none of these have a confirmed
    read-only cmdlet surface as of this writing. Capture those directly from the Purview portal.

    Requires: Security & Compliance PowerShell (Connect-IPPSSession) with role/audit read rights.
    Exchange Online PowerShell access is also needed if -MailboxList is supplied.

.PARAMETER AdminUPN
    UPN to use for Connect-IPPSSession. If omitted, assumes an existing IPPS session is present.

.PARAMETER AuditDays
    Number of days back to search the unified audit log for PriorityCleanupTagApplied and
    PriorityCleanupDelete operations. Defaults to 90 (Exchange priority cleanup's stated rarer,
    incident-driven cadence versus SharePoint/OneDrive's more continual use warrants a longer default
    look-back).

.PARAMETER MailboxList
    Optional array of mailbox identities (UPN or alias) to check against the 10-MB minimum eligibility
    floor. If omitted, the mailbox-size section is skipped entirely.

.PARAMETER ExportPath
    Path to export the CSV/JSON reports. Defaults to the current user's temp folder.

.EXAMPLE
    .\Get-PriorityCleanupExchangeReadiness.ps1 -AdminUPN admin@contoso.com -MailboxList user1@contoso.com,user2@contoso.com

    Connects, audits all three approver-role pools, checks audit log ingestion state, sweeps 90 days
    of audit log for priority cleanup activity, checks the two named mailboxes against the 10-MB
    floor, and exports CSV/JSON reports.

.NOTES
    Read-only. Makes NO configuration changes and issues NO delete actions of any kind. Cannot read
    the tenant-wide priority cleanup toggle or any existing policy's own configuration -- see
    .DESCRIPTION. Requires the ExchangeOnlineManagement module.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AdminUPN,

    [Parameter(Mandatory = $false)]
    [int]$AuditDays = 90,

    [Parameter(Mandatory = $false)]
    [string[]]$MailboxList,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = (Join-Path $env:TEMP "PriorityCleanupExchangeReadiness-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
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
Write-Status "Starting Purview priority cleanup (Exchange) readiness audit" "INFO"
Write-Status "READ-ONLY. Cannot read the tenant-wide toggle or existing policy configuration --" "INFO"
Write-Status "those remain portal-only as of this writing. No delete actions are issued." "INFO"

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Status "ExchangeOnlineManagement module not found. Install with: Install-Module ExchangeOnlineManagement" "ERROR"
    throw "Required module missing."
}

try {
    if ($AdminUPN) {
        Connect-IPPSSession -UserPrincipalName $AdminUPN -ErrorAction Stop
    }
    else {
        Write-Status "No -AdminUPN supplied; assuming an existing IPPS session is already connected." "WARN"
    }
}
catch {
    Write-Status "Failed to connect to Security & Compliance PowerShell: $($_.Exception.Message)" "ERROR"
    throw
}

$report = [ordered]@{
    GeneratedAt              = (Get-Date).ToString("o")
    AuditingEnabled          = $null
    PriorityCleanupAdmins    = @()
    RetentionManagers        = @()
    EDiscoveryAdmins         = @()
    MissingApproverTypes     = @()
    MailboxEligibility       = @()
    RecentPriorityCleanupOps = @()
}

# ---------------------------------------------------------------------------
# 1. Audit log ingestion state -- hard prerequisite for simulation mode
# ---------------------------------------------------------------------------
Write-Status "Checking unified audit log ingestion state..." "INFO"
try {
    $auditConfig = Get-AdminAuditLogConfig
    $report.AuditingEnabled = [bool]$auditConfig.UnifiedAuditLogIngestionEnabled
    if ($report.AuditingEnabled) {
        Write-Status "Unified audit log ingestion is ENABLED." "OK"
        Write-Status "Cannot confirm exactly how long it has been enabled via this cmdlet -- if it was" "WARN"
        Write-Status "enabled recently, wait >= 24 hours before relying on simulation-mode results." "WARN"
    }
    else {
        Write-Status "Unified audit log ingestion is DISABLED. Enable it and wait >= 24 hours before" "WARN"
        Write-Status "creating any priority cleanup policy -- simulation results depend on this." "WARN"
    }
}
catch {
    Write-Status "Could not read audit log configuration: $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# 2. Three mandatory approver-role pools
# ---------------------------------------------------------------------------
Write-Status "Auditing Priority Cleanup admin role coverage..." "INFO"
try {
    $pcAdminGroups = Get-RoleGroup | Where-Object { $_.Roles -contains "Priority Cleanup Admin" }
    $report.PriorityCleanupAdmins = $pcAdminGroups | ForEach-Object { Get-RoleGroupMember -Identity $_.Name } |
        Select-Object -ExpandProperty Name -Unique
    if ($report.PriorityCleanupAdmins.Count -eq 0) {
        Write-Status "No users found with the Priority Cleanup Admin role. This role must be assigned" "WARN"
        Write-Status "before ANY priority cleanup policy (Exchange or SharePoint/OneDrive) can be created." "WARN"
        $report.MissingApproverTypes += "Priority Cleanup Admin"
    }
    else {
        Write-Status "Found $($report.PriorityCleanupAdmins.Count) Priority Cleanup Admin(s)." "OK"
    }
}
catch {
    Write-Status "Could not enumerate Priority Cleanup Admin role membership: $($_.Exception.Message)" "ERROR"
}

Write-Status "Auditing Retention Management role coverage..." "INFO"
try {
    $retentionGroups = Get-RoleGroup | Where-Object { $_.Roles -contains "Retention Management" }
    $report.RetentionManagers = $retentionGroups | ForEach-Object { Get-RoleGroupMember -Identity $_.Name } |
        Select-Object -ExpandProperty Name -Unique
    if ($report.RetentionManagers.Count -eq 0) {
        Write-Status "No users found with the Retention Management role. Any content under a retention" "WARN"
        Write-Status "policy/label or Litigation Hold cannot be approved for priority cleanup without one." "WARN"
        $report.MissingApproverTypes += "Retention Management"
    }
    else {
        Write-Status "Found $($report.RetentionManagers.Count) Retention Manager(s)." "OK"
    }
}
catch {
    Write-Status "Could not enumerate Retention Management role membership: $($_.Exception.Message)" "ERROR"
}

Write-Status "Auditing eDiscovery admin role coverage (Search And Purge + Hold)..." "INFO"
try {
    $eDiscoveryGroups = Get-RoleGroup | Where-Object { $_.Roles -contains "Search And Purge" -and $_.Roles -contains "Hold" }
    $report.EDiscoveryAdmins = $eDiscoveryGroups | ForEach-Object { Get-RoleGroupMember -Identity $_.Name } |
        Select-Object -ExpandProperty Name -Unique
    if ($report.EDiscoveryAdmins.Count -eq 0) {
        Write-Status "No users found holding BOTH Search And Purge and Hold roles together. Any content" "WARN"
        Write-Status "under an eDiscovery hold cannot be approved for priority cleanup without this pairing." "WARN"
        $report.MissingApproverTypes += "eDiscovery Admin (Search And Purge + Hold)"
    }
    else {
        Write-Status "Found $($report.EDiscoveryAdmins.Count) eDiscovery admin(s) with the required pairing." "OK"
    }
}
catch {
    Write-Status "Could not enumerate eDiscovery admin role membership: $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# 3. Mailbox 10-MB eligibility floor (optional)
# ---------------------------------------------------------------------------
if ($MailboxList -and $MailboxList.Count -gt 0) {
    Write-Status "Checking $($MailboxList.Count) mailbox(es) against the 10-MB priority cleanup eligibility floor..." "INFO"
    foreach ($mbx in $MailboxList) {
        try {
            $stats = Get-MailboxStatistics -Identity $mbx -ErrorAction Stop
            $sizeBytes = $stats.TotalItemSize.Value.ToBytes()
            $eligible = $sizeBytes -ge 10MB
            $report.MailboxEligibility += [pscustomobject]@{
                Mailbox      = $mbx
                TotalItemSize = $stats.TotalItemSize.ToString()
                EligibleFor10MBFloor = $eligible
            }
            if (-not $eligible) {
                Write-Status "  $mbx is BELOW the 10-MB floor -- silently ineligible for priority cleanup." "WARN"
            }
        }
        catch {
            Write-Status "  Could not retrieve mailbox statistics for $mbx : $($_.Exception.Message)" "ERROR"
            $report.MailboxEligibility += [pscustomobject]@{
                Mailbox = $mbx; TotalItemSize = "ERROR"; EligibleFor10MBFloor = $null
            }
        }
    }
}
else {
    Write-Status "No -MailboxList supplied; skipping the 10-MB eligibility floor check." "INFO"
}

# ---------------------------------------------------------------------------
# 4. Best-effort audit log sweep for prior priority cleanup activity
# ---------------------------------------------------------------------------
Write-Status "Sweeping $AuditDays day(s) of unified audit log for priority cleanup activity..." "INFO"
try {
    $ops = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1 * $AuditDays) -EndDate (Get-Date) `
        -Operations "PriorityCleanupTagApplied", "PriorityCleanupDelete" -ResultSize 5000 -ErrorAction Stop
    $report.RecentPriorityCleanupOps = $ops | Select-Object CreationDate, Operations, UserIds, Workload
    if ($ops.Count -eq 0) {
        Write-Status "No PriorityCleanupTagApplied / PriorityCleanupDelete events found in the last $AuditDays day(s)." "INFO"
        Write-Status "This does not confirm the feature is unconfigured -- only that no matching audit" "INFO"
        Write-Status "events were logged in this window, or that auditing wasn't enabled throughout it." "INFO"
    }
    else {
        Write-Status "Found $($ops.Count) priority cleanup audit event(s) in the last $AuditDays day(s)." "OK"
    }
}
catch {
    Write-Status "Audit log search failed: $($_.Exception.Message)" "ERROR"
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$jsonPath = "$ExportPath.json"
$report | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding utf8
Write-Status "Full report exported to $jsonPath" "OK"

if ($report.MailboxEligibility.Count -gt 0) {
    $csvPath = "$ExportPath-MailboxEligibility.csv"
    $report.MailboxEligibility | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Status "Mailbox eligibility CSV exported to $csvPath" "OK"
}

if ($report.RecentPriorityCleanupOps.Count -gt 0) {
    $csvPath = "$ExportPath-AuditEvents.csv"
    $report.RecentPriorityCleanupOps | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Status "Audit events CSV exported to $csvPath" "OK"
}

Write-Status "Done. REMINDER: the tenant-wide priority cleanup toggle and any existing policy's own" "WARN"
Write-Status "configuration (scope, KeyQL query, assigned approvers) must still be confirmed directly" "WARN"
Write-Status "in the Purview portal -- no read-only cmdlet surface is confirmed for either as of this writing." "WARN"
