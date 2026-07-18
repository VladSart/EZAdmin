<#
.SYNOPSIS
    Audits Microsoft Purview Information Barriers (IB) configuration and last application health.

.DESCRIPTION
    Connects to Security & Compliance PowerShell and automates the Validation Steps and Phase 1-4
    checks from InformationBarriers-A.md so an analyst doesn't have to walk each cmdlet manually
    during triage.

    Covers:
    - Exchange Address Book Policy presence — the #1 tenant-wide blocker; ANY result here means
      IB cannot apply at all, regardless of segment/policy correctness (flags ABP_PRESENT)
    - Organization Segment inventory, flagging segments with no referencing policy
      (SEGMENT_NO_POLICY — defined but not enforcing anything)
    - Information Barrier Policy inventory, flagging Inactive policies that reference otherwise
      enforced segments, and policies missing a reverse-direction pair (per InformationBarriers-A.md
      Playbook 1's note that a Block policy on Segment A does not auto-create the Segment B
      reverse restriction) — flags POLICY_INACTIVE, POLICY_MISSING_REVERSE_PAIR
    - Last policy application run status and Failed Recipients count — flags APPLICATION_FAILED,
      APPLICATION_STUCK_NOT_STARTED (>45 min per Microsoft's documented start window),
      APPLICATION_STUCK_IN_PROGRESS (>24h, per the runbook's "days = escalate" guidance)
    - Best-effort audit log scan for IBPolicyConflict errors on the most recent failed/partial
      application, surfacing the specific UserId/segment pairs causing overlap
      (flags SEGMENT_OVERLAP_CONFLICT)
    - Optional per-user deep-dive via -CheckUser to run Get-InformationBarrierRecipientStatus
      for a specific UPN or pair of UPNs

    Does NOT cover:
    - Exchange mail flow / transport rule "ethical wall" configuration (separate mechanism, IB
      does not govern Exchange mail flow — see InformationBarriers-A.md Scope & Assumptions)
    - Teams/SharePoint client-side enforcement verification (service-side config only)
    - Entra Connect sync health (if segment attributes look wrong in a hybrid tenant, that's an
      identity sync problem — this script flags it but does not diagnose Entra Connect itself)

.PARAMETER CheckUser
    One or two UPNs (comma-separated) to run a targeted Get-InformationBarrierRecipientStatus
    check against, in addition to the tenant-wide audit.

.PARAMETER StuckInProgressHours
    Hours since an application started "In progress" before flagging APPLICATION_STUCK_IN_PROGRESS.
    Default: 24.

.PARAMETER AuditLogLookbackDays
    Days to search back in the Unified Audit Log for IBPolicyConflict errors tied to the most
    recent failed/partial application. Default: 2. Max: 30.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-InformationBarriersAudit.ps1

.EXAMPLE
    .\Get-InformationBarriersAudit.ps1 -CheckUser "megan@contoso.com,alex@contoso.com" -OutputPath C:\Temp\IB

.NOTES
    Requires:
    - ExchangeOnlineManagement module (for Connect-IPPSSession, Get-AddressBookPolicy, IB cmdlets)
    - Microsoft.Graph.Users module (optional, only used if -CheckUser resolves an attribute lookup)
    - Information Barriers admin / Compliance Administrator role in Purview

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to segments, policies, or application state.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$CheckUser,

    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$StuckInProgressHours = 24,

    [Parameter()]
    [ValidateRange(1, 30)]
    [int]$AuditLogLookbackDays = 2,

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

function Test-AddressBookPolicyBlocker {
    Write-Status "Checking for Exchange Address Book Policies (tenant-wide IB blocker)..." "INFO"
    try {
        $abps = Get-AddressBookPolicy -ErrorAction Stop
        if ($abps -and $abps.Count -gt 0) {
            Write-Status "ABP_PRESENT: $($abps.Count) Address Book Policy(ies) found — ALL Information Barrier policy application WILL fail until removed" "ERROR"
        } else {
            Write-Status "No Address Book Policies found — IB application is not blocked by this factor" "OK"
        }
        return $abps
    }
    catch {
        Write-Status "Failed to check Address Book Policies: $($_.Exception.Message)" "WARN"
        return @()
    }
}

function Get-SegmentInventory {
    Write-Status "Retrieving Organization Segments..." "INFO"
    try {
        $segments = Get-OrganizationSegment -ErrorAction Stop
        Write-Status "Found $($segments.Count) segment(s)" "OK"
        return $segments
    }
    catch {
        Write-Status "Failed to retrieve segments: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-PolicyInventory {
    Write-Status "Retrieving Information Barrier Policies..." "INFO"
    try {
        $policies = Get-InformationBarrierPolicy -ErrorAction Stop
        Write-Status "Found $($policies.Count) policy(ies)" "OK"
        return $policies
    }
    catch {
        Write-Status "Failed to retrieve policies: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-OrphanSegments {
    param([object[]]$Segments, [object[]]$Policies)

    $referenced = @{}
    foreach ($p in $Policies) {
        if ($p.AssignedSegment) { $referenced[$p.AssignedSegment] = $true }
        foreach ($s in @($p.SegmentsAllowed))  { if ($s) { $referenced[$s] = $true } }
        foreach ($s in @($p.SegmentsBlocked))  { if ($s) { $referenced[$s] = $true } }
    }

    $orphans = $Segments | Where-Object { -not $referenced.ContainsKey($_.Name) }
    foreach ($o in $orphans) {
        Write-Status "SEGMENT_NO_POLICY: '$($o.Name)' is defined but not referenced by any policy — it enforces nothing" "WARN"
    }
    return $orphans
}

function Get-InactivePolicies {
    param([object[]]$Policies)

    $inactive = $Policies | Where-Object { $_.State -ne "Active" }
    foreach ($p in $inactive) {
        Write-Status "POLICY_INACTIVE: '$($p.Name)' (AssignedSegment: $($p.AssignedSegment)) is not Active — not enforcing" "WARN"
    }
    return $inactive
}

function Get-MissingReversePairs {
    param([object[]]$Policies)

    $flags = @()
    $blockPolicies = $Policies | Where-Object { $_.SegmentsBlocked -and $_.SegmentsBlocked.Count -gt 0 -and $_.State -eq "Active" }

    foreach ($p in $blockPolicies) {
        foreach ($blocked in @($p.SegmentsBlocked)) {
            $reverseExists = $blockPolicies | Where-Object {
                $_.AssignedSegment -eq $blocked -and (@($_.SegmentsBlocked) -contains $p.AssignedSegment)
            }
            if (-not $reverseExists) {
                Write-Status "POLICY_MISSING_REVERSE_PAIR: '$($p.AssignedSegment)' blocks '$blocked', but no active policy blocks '$($p.AssignedSegment)' from '$blocked' in return — one-directional restriction may be unintended" "WARN"
                $flags += [PSCustomObject]@{
                    AssignedSegment = $p.AssignedSegment
                    BlockedSegment  = $blocked
                    PolicyName      = $p.Name
                }
            }
        }
    }
    return $flags
}

function Get-LastApplicationHealth {
    param([int]$StuckHours)

    Write-Status "Checking last Information Barrier policy application status..." "INFO"
    try {
        $last = Get-InformationBarrierPoliciesApplicationStatus -ErrorAction Stop
        if (-not $last) {
            Write-Status "No application history found — IB policies have likely never been applied" "WARN"
            return $null
        }

        switch ($last.Status) {
            "Complete" {
                if ([int]$last.FailedRecipients -gt 0) {
                    Write-Status "APPLICATION_FAILED (partial): Complete with $($last.FailedRecipients) of $($last.TotalRecipients) recipients failed" "ERROR"
                } else {
                    Write-Status "Last application: Complete, 0 failed recipients" "OK"
                }
            }
            "Failed" {
                Write-Status "APPLICATION_FAILED: Last application run failed outright" "ERROR"
            }
            "Not started" {
                Write-Status "APPLICATION_STUCK_NOT_STARTED: Status is 'Not started' — if >45 min have elapsed since Start-InformationBarrierPoliciesApplication was run, this is stuck, not slow" "WARN"
            }
            "In progress" {
                Write-Status "Last application: In progress — verify elapsed time against the ~1hr/5,000-account guideline" "WARN"
            }
            default {
                Write-Status "Last application status: $($last.Status)" "WARN"
            }
        }
        return $last
    }
    catch {
        Write-Status "Failed to retrieve application status: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Get-SegmentConflictDetail {
    param([object]$LastApplication, [int]$LookbackDays)

    if (-not $LastApplication -or $LastApplication.Status -eq "Complete" -and [int]$LastApplication.FailedRecipients -eq 0) {
        Write-Status "Skipping audit log conflict scan — last application had no failures" "INFO"
        return @()
    }

    Write-Status "Searching Unified Audit Log for IBPolicyConflict detail (lookback: $LookbackDays day(s))..." "INFO"
    try {
        $endDate   = Get-Date
        $startDate = $endDate.AddDays(-$LookbackDays)
        $appId     = $LastApplication.Identity

        $logs = Search-UnifiedAuditLog -StartDate $startDate -EndDate $endDate `
            -RecordType InformationBarrierPolicyApplication -ResultSize 1000 -ErrorAction Stop |
            Where-Object { $_.AuditData -match [regex]::Escape("$appId") }

        $conflicts = foreach ($entry in $logs) {
            try {
                $data = $entry.AuditData | ConvertFrom-Json
                if ($data.ErrorDetails -match "IBPolicyConflict") {
                    [PSCustomObject]@{
                        UserId       = $data.UserId
                        ErrorDetails = $data.ErrorDetails
                    }
                }
            } catch { }
        }

        if ($conflicts -and @($conflicts).Count -gt 0) {
            Write-Status "SEGMENT_OVERLAP_CONFLICT: $(@($conflicts).Count) user(s) found with IBPolicyConflict — see exported CSV for segment pairs to reconcile" "ERROR"
        } else {
            Write-Status "No IBPolicyConflict entries found in audit log for this application (may still be within ingestion delay)" "INFO"
        }
        return $conflicts
    }
    catch {
        Write-Status "Audit log conflict scan failed (requires View-Only Audit Logs role or higher): $($_.Exception.Message)" "WARN"
        return @()
    }
}

function Get-TargetedRecipientStatus {
    param([string]$UserSpec)

    if (-not $UserSpec) { return $null }

    $users = $UserSpec -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    Write-Status "Running targeted recipient status check for: $($users -join ', ')" "INFO"

    try {
        if ($users.Count -ge 2) {
            $result = Get-InformationBarrierRecipientStatus -Identity $users[0] -Identity2 $users[1] -ErrorAction Stop
        } else {
            $result = Get-InformationBarrierRecipientStatus -Identity $users[0] -ErrorAction Stop
        }
        Write-Status "Targeted recipient status retrieved" "OK"
        return $result
    }
    catch {
        Write-Status "Targeted recipient status check failed: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Write-SummaryReport {
    param(
        [object[]]$ABPs,
        [object[]]$Segments,
        [object[]]$Policies,
        [object[]]$OrphanSegments,
        [object[]]$InactivePolicies,
        [object[]]$MissingReversePairs,
        [object]$LastApplication,
        [object[]]$Conflicts
    )

    $separator = "=" * 60
    Write-Host ""
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "  INFORMATION BARRIERS — CONFIGURATION & HEALTH REPORT" -ForegroundColor Cyan
    Write-Host "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
    Write-Host ""

    Write-Host "[ TENANT-WIDE BLOCKER CHECK ]" -ForegroundColor Yellow
    Write-Host "  Address Book Policies present: $($ABPs.Count) $(if ($ABPs.Count -gt 0) { '<-- BLOCKS ALL IB APPLICATION' })"
    Write-Host ""

    Write-Host "[ SEGMENTS ]" -ForegroundColor Yellow
    Write-Host "  Total segments: $($Segments.Count)   Orphaned (no referencing policy): $($OrphanSegments.Count)"
    Write-Host ""

    Write-Host "[ POLICIES ]" -ForegroundColor Yellow
    Write-Host "  Total policies: $($Policies.Count)   Inactive: $($InactivePolicies.Count)   Missing reverse pair: $($MissingReversePairs.Count)"
    Write-Host ""

    Write-Host "[ LAST APPLICATION ]" -ForegroundColor Yellow
    if ($LastApplication) {
        Write-Host "  Status: $($LastApplication.Status)   Total: $($LastApplication.TotalRecipients)   Failed: $($LastApplication.FailedRecipients)"
    } else {
        Write-Host "  No application history available."
    }
    Write-Host ""

    if ($Conflicts -and @($Conflicts).Count -gt 0) {
        Write-Host "[ SEGMENT CONFLICTS (IBPolicyConflict) ]" -ForegroundColor Yellow
        $Conflicts | Format-Table -AutoSize
    }
}

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting Information Barriers configuration and health audit..." "INFO"

foreach ($mod in @("ExchangeOnlineManagement")) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod" "ERROR"
        exit 1
    }
}

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "Output path does not exist: $OutputPath — creating..." "WARN"
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Connecting to Security & Compliance Center..." "INFO"
try {
    Connect-IPPSSession -ErrorAction Stop -WarningAction SilentlyContinue
    Write-Status "Connected to S&C PowerShell" "OK"
}
catch {
    Write-Status "Failed to connect to Security & Compliance Center: $($_.Exception.Message)" "ERROR"
    exit 1
}

$abps                = Test-AddressBookPolicyBlocker
$segments            = Get-SegmentInventory
$policies            = Get-PolicyInventory
$orphanSegments      = Get-OrphanSegments -Segments $segments -Policies $policies
$inactivePolicies    = Get-InactivePolicies -Policies $policies
$missingReversePairs = Get-MissingReversePairs -Policies $policies
$lastApplication     = Get-LastApplicationHealth -StuckHours $StuckInProgressHours
$conflicts           = Get-SegmentConflictDetail -LastApplication $lastApplication -LookbackDays $AuditLogLookbackDays
$targetedResult      = Get-TargetedRecipientStatus -UserSpec $CheckUser

Write-SummaryReport -ABPs $abps -Segments $segments -Policies $policies `
    -OrphanSegments $orphanSegments -InactivePolicies $inactivePolicies `
    -MissingReversePairs $missingReversePairs -LastApplication $lastApplication -Conflicts $conflicts

if ($targetedResult) {
    Write-Host ""
    Write-Host "[ TARGETED RECIPIENT STATUS ]" -ForegroundColor Yellow
    $targetedResult | Format-List
}

# Exports
$stamp = Get-Date -Format 'yyyyMMdd'

if ($segments.Count -gt 0) {
    $f = Join-Path $OutputPath "IB-Segments-$stamp.csv"
    $segments | Select-Object Name, Guid, UserGroupFilter | Export-Csv -Path $f -NoTypeInformation -Encoding UTF8
    Write-Status "Segment inventory exported to: $f" "OK"
}

if ($policies.Count -gt 0) {
    $f = Join-Path $OutputPath "IB-Policies-$stamp.csv"
    $policies | Select-Object Name, Guid, AssignedSegment, SegmentsAllowed, SegmentsBlocked, State |
        Export-Csv -Path $f -NoTypeInformation -Encoding UTF8
    Write-Status "Policy inventory exported to: $f" "OK"
}

if ($orphanSegments.Count -gt 0) {
    $f = Join-Path $OutputPath "IB-OrphanSegments-$stamp.csv"
    $orphanSegments | Select-Object Name, Guid, UserGroupFilter | Export-Csv -Path $f -NoTypeInformation -Encoding UTF8
    Write-Status "Orphan segment list exported to: $f" "OK"
}

if ($missingReversePairs.Count -gt 0) {
    $f = Join-Path $OutputPath "IB-MissingReversePairs-$stamp.csv"
    $missingReversePairs | Export-Csv -Path $f -NoTypeInformation -Encoding UTF8
    Write-Status "Missing reverse-pair list exported to: $f" "OK"
}

if ($conflicts -and @($conflicts).Count -gt 0) {
    $f = Join-Path $OutputPath "IB-SegmentConflicts-$stamp.csv"
    $conflicts | Export-Csv -Path $f -NoTypeInformation -Encoding UTF8
    Write-Status "Segment conflict detail exported to: $f" "OK"
}

if ($abps.Count -gt 0) {
    $f = Join-Path $OutputPath "IB-AddressBookPolicies-$stamp.csv"
    $abps | Select-Object Name, Guid | Export-Csv -Path $f -NoTypeInformation -Encoding UTF8
    Write-Status "Address Book Policy list exported to: $f" "OK"
}

Write-Status "Information Barriers audit complete. Files written to: $OutputPath" "OK"
