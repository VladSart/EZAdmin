<#
.SYNOPSIS
    Tenant-wide, read-only health audit of Exchange Online mailbox migration batches
    (Cutover, Staged, IMAP, Remote Move, and Cross-tenant).

.DESCRIPTION
    Connects to Exchange Online and walks every migration batch and migration user,
    flagging real failures versus expected throttling, unapproved skipped-item data
    loss, cutover single-batch-limit risk, cross-tenant organization-relationship
    misconfiguration, and — optionally — completed-but-unlicensed target mailboxes
    that are exposed to the 30-day auto-disable grace period.

    Does NOT modify any migration batch, user, or organization relationship — this
    is a diagnostic/evidence-collection script only. See MigrationBatches-A.md /
    MigrationBatches-B.md for the corresponding remediation playbooks and fix paths.

    Flags raised:
    - BATCH_FAILED               : batch itself reports Failed or CompletedWithErrors
    - BATCH_STOPPED               : batch is in a Stopped state (manual or error-triggered)
    - USER_FAILED                 : individual migration user is in Failed status
    - USER_STALLED                : individual migration user is in Stalled status
                                     (informational — usually WLM/MRS throttling, not a fault)
    - AUTOSUSPENDED_PENDING       : user(s) parked at AutoSuspended/Synced awaiting a
                                     manual Complete-MigrationBatch / Resume-MigrationUser
    - SKIPPED_ITEMS_PENDING       : migration report shows skipped items not yet approved
                                     via -SkippedItemApprovalTime
    - CUTOVER_LIMIT_RISK          : an active cutover batch has TotalCount above the
                                     Microsoft-recommended practical ceiling (150)
    - MULTIPLE_CUTOVER_BATCHES    : more than one cutover batch exists (should be impossible,
                                     surfaced as a sanity-check flag in case of a stale/orphaned batch)
    - ORG_REL_MOVE_DISABLED       : an organization relationship exists but MailboxMoveEnabled is $false
    - ORG_REL_NO_SCOPE            : MailboxMoveEnabled is $true but MailboxMovePublishedScopes is empty
    - UNLICENSED_COMPLETED_USER   : (only with -CheckLicensing) migration user Completed but the
                                     target mailbox has no assigned license

.PARAMETER BatchId
    Optional. Limit the audit to one specific migration batch. Default: all batches.

.PARAMETER CheckOrgRelationships
    If specified, also audits Get-OrganizationRelationship for cross-tenant migration
    readiness (MailboxMoveEnabled / MailboxMoveCapability / MailboxMovePublishedScopes).

.PARAMETER CheckLicensing
    If specified, cross-checks Completed migration users against Microsoft Graph license
    data (requires the Microsoft.Graph.Users module and an active Graph connection with
    User.Read.All). Skipped gracefully with a warning if the module/connection isn't available.

.PARAMETER IncludeCompletedUsers
    If specified, includes fully Completed migration users in the per-user CSV export
    (default export only includes non-Completed / flagged users, to keep output focused).

.PARAMETER ExportPath
    Folder for CSV export. Default: current directory.

.EXAMPLE
    .\Get-MigrationBatchHealth.ps1

    Quick tenant-wide pass — batch and user status audit only.

.EXAMPLE
    .\Get-MigrationBatchHealth.ps1 -CheckOrgRelationships -CheckLicensing -IncludeCompletedUsers

    Full audit including cross-tenant readiness and post-migration licensing exposure.

.EXAMPLE
    .\Get-MigrationBatchHealth.ps1 -BatchId "CutoverBatch01"

    Audit a single batch by name.

.NOTES
    Requires:  ExchangeOnlineManagement module, connected via Connect-ExchangeOnline
               Microsoft.Graph.Users module ONLY if -CheckLicensing is used
    Run-as:    Exchange Recipient Administrator or higher; Global Reader is sufficient
               for the read-only Exchange calls, but Global Reader is documented to be
               unable to read some provisioning/migration configuration in certain tenants —
               use a role with explicit Exchange migration permissions if results look incomplete.
    Safe:      Fully read-only. No batches, users, or relationships are modified.
    Does not cover: on-premises MRSProxy connection counts or WLM setting overrides —
               those live on the on-premises Exchange server and are outside EXO PowerShell's
               reach; see MigrationBatches-B.md Fix 1/Fix 3 for those checks.
#>

[CmdletBinding()]
param(
    [string]$BatchId,
    [switch]$CheckOrgRelationships,
    [switch]$CheckLicensing,
    [switch]$IncludeCompletedUsers,
    [string]$ExportPath = (Get-Location).Path
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

$CutoverPracticalLimit = 150

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Preflight: checking Exchange Online connection..." "INFO"

if (-not (Get-Module -Name ExchangeOnlineManagement)) {
    Write-Status "ExchangeOnlineManagement module not loaded. Run Connect-ExchangeOnline first." "ERROR"
    return
}

try {
    $null = Get-ConnectionInformation -ErrorAction Stop
    Write-Status "Exchange Online session confirmed." "OK"
}
catch {
    Write-Status "No active Exchange Online session. Run Connect-ExchangeOnline first." "ERROR"
    return
}

$graphAvailable = $false
if ($CheckLicensing) {
    if (Get-Module -ListAvailable -Name Microsoft.Graph.Users) {
        try {
            Import-Module Microsoft.Graph.Users -ErrorAction Stop
            $null = Get-MgContext -ErrorAction Stop
            if ($null -ne (Get-MgContext)) {
                $graphAvailable = $true
                Write-Status "Microsoft Graph session confirmed for licensing checks." "OK"
            }
            else {
                Write-Status "Microsoft.Graph.Users loaded but no active connection (Connect-MgGraph). Skipping -CheckLicensing." "WARN"
            }
        }
        catch {
            Write-Status "Could not confirm a Microsoft Graph connection. Skipping -CheckLicensing." "WARN"
        }
    }
    else {
        Write-Status "Microsoft.Graph.Users module not installed. Skipping -CheckLicensing." "WARN"
    }
}

# ---------------------------------------------------------------------------
# Batch collection
# ---------------------------------------------------------------------------
Write-Status "Collecting migration batches..." "INFO"

try {
    if ($BatchId) {
        $batches = @(Get-MigrationBatch -Identity $BatchId -ErrorAction Stop)
    }
    else {
        $batches = @(Get-MigrationBatch -ErrorAction Stop)
    }
}
catch {
    Write-Status "Failed to retrieve migration batches: $($_.Exception.Message)" "ERROR"
    return
}

if ($batches.Count -eq 0) {
    Write-Status "No migration batches found in this tenant." "OK"
}

$batchFindings = New-Object System.Collections.Generic.List[Object]
$userFindings  = New-Object System.Collections.Generic.List[Object]

$cutoverBatches = @($batches | Where-Object { $_.MigrationType -like "*Cutover*" })
if ($cutoverBatches.Count -gt 1) {
    Write-Status "MULTIPLE_CUTOVER_BATCHES: $($cutoverBatches.Count) cutover batches found (platform normally allows only one)." "WARN"
}

foreach ($batch in $batches) {

    $flags = New-Object System.Collections.Generic.List[string]

    if ($batch.Status -in @('Failed', 'CompletedWithErrors')) {
        $flags.Add("BATCH_FAILED")
    }
    if ($batch.Status -eq 'Stopped') {
        $flags.Add("BATCH_STOPPED")
    }
    if ($batch.MigrationType -like "*Cutover*" -and [int]$batch.TotalCount -gt $CutoverPracticalLimit) {
        $flags.Add("CUTOVER_LIMIT_RISK")
    }

    $status = if ($flags.Count -gt 0) { "WARN" } else { "OK" }
    Write-Status "Batch '$($batch.Identity)' [$($batch.MigrationType)] Status=$($batch.Status) Total=$($batch.TotalCount) Failed=$($batch.FailedCount) $(if ($flags.Count -gt 0) { '-- FLAGS: ' + ($flags -join ',') })" $status

    $batchFindings.Add([PSCustomObject]@{
        BatchIdentity   = $batch.Identity
        MigrationType   = $batch.MigrationType
        Status          = $batch.Status
        TotalCount      = $batch.TotalCount
        SuccessfulCount = $batch.SuccessfulCount
        FailedCount     = $batch.FailedCount
        Flags           = ($flags -join ';')
    })

    # -----------------------------------------------------------------
    # Per-user detail for this batch
    # -----------------------------------------------------------------
    try {
        $users = @(Get-MigrationUser -BatchId $batch.Identity -ErrorAction Stop)
    }
    catch {
        Write-Status "  Could not retrieve migration users for batch '$($batch.Identity)': $($_.Exception.Message)" "WARN"
        continue
    }

    foreach ($mu in $users) {

        $userFlags = New-Object System.Collections.Generic.List[string]
        $errorText = ""

        switch ($mu.Status) {
            'Failed'        { $userFlags.Add("USER_FAILED") }
            'Stalled'       { $userFlags.Add("USER_STALLED") }
            'AutoSuspended' { $userFlags.Add("AUTOSUSPENDED_PENDING") }
            'Synced'        { $userFlags.Add("AUTOSUSPENDED_PENDING") }
            default         { }
        }

        if ($mu.Status -in @('Failed', 'Stalled')) {
            try {
                $stats = Get-MigrationUserStatistics -Identity $mu.Identity -IncludeReport -ErrorAction Stop
                $errors = $stats.Report.Errors
                if ($errors -and $errors.Count -gt 0) {
                    $errorText = ($errors | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join ' | '
                }
                if ($stats.Report | Get-Member -Name "SkippedItemCount" -ErrorAction SilentlyContinue) {
                    if ([int]$stats.Report.SkippedItemCount -gt 0) {
                        $userFlags.Add("SKIPPED_ITEMS_PENDING")
                    }
                }
            }
            catch {
                $errorText = "Could not retrieve detailed report: $($_.Exception.Message)"
            }
        }

        if ($userFlags.Count -gt 0 -or $IncludeCompletedUsers) {
            $userFindings.Add([PSCustomObject]@{
                BatchIdentity = $batch.Identity
                Identity      = $mu.Identity
                Status        = $mu.Status
                Flags         = ($userFlags -join ';')
                ErrorSummary  = $errorText
            })
        }

        if ($userFlags.Count -gt 0) {
            Write-Status "  User '$($mu.Identity)' Status=$($mu.Status) -- FLAGS: $($userFlags -join ',')" "WARN"
        }

        # -----------------------------------------------------------------
        # Optional licensing check for Completed users
        # -----------------------------------------------------------------
        if ($graphAvailable -and $mu.Status -eq 'Completed') {
            try {
                $upn = $mu.Identity
                $licenses = Get-MgUserLicenseDetail -UserId $upn -ErrorAction Stop
                if (-not $licenses -or $licenses.Count -eq 0) {
                    Write-Status "  UNLICENSED_COMPLETED_USER: '$upn' migrated but has no assigned license (30-day grace period exposure)." "WARN"
                    $userFindings.Add([PSCustomObject]@{
                        BatchIdentity = $batch.Identity
                        Identity      = $upn
                        Status        = "Completed"
                        Flags         = "UNLICENSED_COMPLETED_USER"
                        ErrorSummary  = "No Microsoft 365 license assigned post-migration."
                    })
                }
            }
            catch {
                # Non-fatal — user may not resolve directly via UPN in Graph (e.g. mismatched routing address)
                Write-Status "  Could not check license for '$($mu.Identity)': $($_.Exception.Message)" "WARN"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Optional: organization relationship audit (cross-tenant readiness)
# ---------------------------------------------------------------------------
$orgRelFindings = New-Object System.Collections.Generic.List[Object]

if ($CheckOrgRelationships) {
    Write-Status "Auditing organization relationships for cross-tenant migration readiness..." "INFO"

    try {
        $orgRels = @(Get-OrganizationRelationship -ErrorAction Stop)
    }
    catch {
        Write-Status "Failed to retrieve organization relationships: $($_.Exception.Message)" "ERROR"
        $orgRels = @()
    }

    foreach ($rel in $orgRels) {

        $relFlags = New-Object System.Collections.Generic.List[string]

        if ($rel.MailboxMoveEnabled -eq $false -and $rel.MailboxMoveCapability) {
            $relFlags.Add("ORG_REL_MOVE_DISABLED")
        }
        if ($rel.MailboxMoveEnabled -eq $true) {
            $scopeEmpty = (-not $rel.MailboxMovePublishedScopes) -or ($rel.MailboxMovePublishedScopes.Count -eq 0)
            if ($scopeEmpty) {
                $relFlags.Add("ORG_REL_NO_SCOPE")
            }
        }

        $status = if ($relFlags.Count -gt 0) { "WARN" } else { "OK" }
        Write-Status "OrgRelationship '$($rel.Identity)' MailboxMoveEnabled=$($rel.MailboxMoveEnabled) $(if ($relFlags.Count -gt 0) { '-- FLAGS: ' + ($relFlags -join ',') })" $status

        $orgRelFindings.Add([PSCustomObject]@{
            Identity                  = $rel.Identity
            DomainNames                = ($rel.DomainNames -join ';')
            MailboxMoveEnabled          = $rel.MailboxMoveEnabled
            MailboxMoveCapability       = $rel.MailboxMoveCapability
            MailboxMovePublishedScopes = ($rel.MailboxMovePublishedScopes -join ';')
            Flags                      = ($relFlags -join ';')
        })
    }
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$batchCsv = Join-Path $ExportPath "MigrationBatchHealth_Batches_$timestamp.csv"
$batchFindings | Export-Csv -Path $batchCsv -NoTypeInformation
Write-Status "Batch summary exported: $batchCsv" "OK"

$userCsv = Join-Path $ExportPath "MigrationBatchHealth_Users_$timestamp.csv"
$userFindings | Export-Csv -Path $userCsv -NoTypeInformation
Write-Status "User detail exported: $userCsv" "OK"

if ($CheckOrgRelationships) {
    $orgRelCsv = Join-Path $ExportPath "MigrationBatchHealth_OrgRelationships_$timestamp.csv"
    $orgRelFindings | Export-Csv -Path $orgRelCsv -NoTypeInformation
    Write-Status "Organization relationship audit exported: $orgRelCsv" "OK"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$totalFlaggedUsers = ($userFindings | Where-Object { $_.Flags -and $_.Flags -ne '' }).Count
$totalFlaggedBatches = ($batchFindings | Where-Object { $_.Flags -and $_.Flags -ne '' }).Count

Write-Status "Audit complete. Batches flagged: $totalFlaggedBatches / $($batches.Count). Users flagged: $totalFlaggedUsers." $(if ($totalFlaggedBatches -gt 0 -or $totalFlaggedUsers -gt 0) { "WARN" } else { "OK" })
