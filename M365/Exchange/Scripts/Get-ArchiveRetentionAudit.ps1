<#
.SYNOPSIS
    Fleet-wide audit of mailbox archive and retention configuration — flags stuck archives, stale retention holds, and quota risk.

.DESCRIPTION
    Companion script for ArchiveRetention-B.md / ArchiveRetention-A.md. Automates the Symptom → Cause
    Map and Validation Steps from both runbooks across every mailbox (or a target set) instead of the
    runbooks' one-user-at-a-time walkthrough.

    Flags, per mailbox:
    - NO_ARCHIVE: ArchiveStatus is None (archive never enabled)
    - RETENTION_HOLD_STUCK: RetentionHoldEnabled=$true — the single most commonly missed check per
      both runbooks' Learning Pointers, frequently left on after a migration
    - NO_MOVE_TO_ARCHIVE_TAG: mailbox has a RetentionPolicy assigned but it contains no tag with
      RetentionAction=MoveToArchive, so items will never leave the primary mailbox
    - ARCHIVE_QUOTA_RISK: archive TotalItemSize within a configurable percentage of ArchiveQuota
    - LIT_HOLD_NO_ARCHIVE: LitigationHoldEnabled=$true but ArchiveStatus=None — a common driver of
      the "mailbox always full" complaint, since held items have nowhere to move

    Does NOT cover:
    - MRM 2.0 / Compliance Center retention label policy status (separate service, no per-mailbox
      Exchange cmdlet equivalent — check via Purview compliance portal)
    - Forcing Managed Folder Assistant runs (this script is read-only; use
      Start-ManagedFolderAssistant manually per the runbook's Fix 2 / Playbook 3 after reviewing output)

.PARAMETER Mailbox
    One or more mailboxes (UPN, alias, or display name) to audit. Accepts pipeline input.
    Defaults to ALL user mailboxes if not specified (use with caution in large environments).

.PARAMETER QuotaWarningPercent
    Percentage of ArchiveQuota at which a mailbox is flagged ARCHIVE_QUOTA_RISK. Default: 85.

.PARAMETER OutputPath
    Path for CSV export. Default: C:\Temp\ArchiveRetentionAudit-<timestamp>.csv

.EXAMPLE
    .\Get-ArchiveRetentionAudit.ps1 -Mailbox "john.smith@contoso.com"

.EXAMPLE
    .\Get-ArchiveRetentionAudit.ps1 -QuotaWarningPercent 90
    # Tenant-wide audit, flags archives at 90%+ of quota

.NOTES
    Requires: Exchange Online module (ExchangeOnlineManagement) v3.0+
    Permissions: Exchange Administrator or View-Only Recipients (read-only cmdlets used)
    Run-as: Connect-ExchangeOnline before running this script
    Safe: Read-only. Makes no changes to any mailbox, archive, or retention policy.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]]$Mailbox,

    [ValidateRange(50, 99)]
    [int]$QuotaWarningPercent = 85,

    [string]$OutputPath = "C:\Temp\ArchiveRetentionAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# Preflight
Write-Status "Checking Exchange Online connection..."
Try {
    $null = Get-OrganizationConfig -ErrorAction Stop
    Write-Status "Exchange Online connected" -Status "OK"
} Catch {
    Write-Status "Not connected to Exchange Online. Run: Connect-ExchangeOnline" -Status "ERROR"
    Exit 1
}

New-Item -Path (Split-Path $OutputPath) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

# Resolve mailboxes
Write-Status "Resolving mailboxes..."
$mailboxObjects = @()
If ($Mailbox) {
    ForEach ($m in $Mailbox) {
        Try {
            $mailboxObjects += Get-Mailbox -Identity $m -ErrorAction Stop
        } Catch {
            Write-Status "Could not find mailbox: $m — skipping" -Status "WARN"
        }
    }
} Else {
    Write-Status "No mailbox specified — retrieving ALL user mailboxes (this may take a while)..." -Status "WARN"
    $mailboxObjects = Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox
}

Write-Status "Auditing $($mailboxObjects.Count) mailbox(es)..."

# Cache retention policy tag lookups to avoid re-querying the same policy repeatedly
$policyTagCache = @{}

$results = [System.Collections.Generic.List[PSObject]]::new()

ForEach ($mbx in $mailboxObjects) {

    $record = [ordered]@{
        UPN                     = $mbx.UserPrincipalName
        DisplayName             = $mbx.DisplayName
        ArchiveStatus           = $mbx.ArchiveStatus
        AutoExpandingArchive    = $mbx.AutoExpandingArchiveEnabled
        RetentionPolicy         = $mbx.RetentionPolicy
        RetentionHoldEnabled    = $mbx.RetentionHoldEnabled
        LitigationHoldEnabled   = $mbx.LitigationHoldEnabled
        HasMoveToArchiveTag     = $null
        ArchiveTotalSizeMB      = $null
        ArchiveQuotaMB          = $null
        ArchivePercentUsed      = $null
        Flags                   = ""
    }

    $flags = @()

    If ($mbx.ArchiveStatus -eq "None") {
        $flags += "NO_ARCHIVE"
        If ($mbx.LitigationHoldEnabled) { $flags += "LIT_HOLD_NO_ARCHIVE" }
    }

    If ($mbx.RetentionHoldEnabled) {
        $flags += "RETENTION_HOLD_STUCK"
    }

    # Check for MoveToArchive tag in assigned policy (cached per-policy)
    If ($mbx.RetentionPolicy) {
        If (-not $policyTagCache.ContainsKey($mbx.RetentionPolicy)) {
            Try {
                $tagLinks = (Get-RetentionPolicy -Identity $mbx.RetentionPolicy -ErrorAction Stop).RetentionPolicyTagLinks
                $hasMoveTag = $false
                ForEach ($link in $tagLinks) {
                    $tag = Get-RetentionPolicyTag -Identity $link -ErrorAction SilentlyContinue
                    If ($tag -and $tag.RetentionAction -eq "MoveToArchive") { $hasMoveTag = $true; break }
                }
                $policyTagCache[$mbx.RetentionPolicy] = $hasMoveTag
            } Catch {
                $policyTagCache[$mbx.RetentionPolicy] = $null
            }
        }
        $record.HasMoveToArchiveTag = $policyTagCache[$mbx.RetentionPolicy]
        If ($mbx.ArchiveStatus -eq "Active" -and $policyTagCache[$mbx.RetentionPolicy] -eq $false) {
            $flags += "NO_MOVE_TO_ARCHIVE_TAG"
        }
    }

    # Archive size vs quota (only if archive is active)
    If ($mbx.ArchiveStatus -eq "Active") {
        Try {
            $stats = Get-MailboxStatistics -Identity $mbx.Identity -Archive -ErrorAction Stop
            If ($stats -and $stats.TotalItemSize) {
                $sizeMB  = [math]::Round(($stats.TotalItemSize.ToString() -replace '.*\(([0-9,]+) bytes\).*', '$1' -replace ',', '') / 1MB, 1)
                $record.ArchiveTotalSizeMB = $sizeMB

                If (-not $mbx.AutoExpandingArchiveEnabled -and $mbx.ArchiveQuota) {
                    $quotaMB = [math]::Round(($mbx.ArchiveQuota.ToString() -replace '.*\(([0-9,]+) bytes\).*', '$1' -replace ',', '') / 1MB, 1)
                    $record.ArchiveQuotaMB = $quotaMB
                    If ($quotaMB -gt 0) {
                        $pctUsed = [math]::Round(($sizeMB / $quotaMB) * 100, 1)
                        $record.ArchivePercentUsed = $pctUsed
                        If ($pctUsed -ge $QuotaWarningPercent) { $flags += "ARCHIVE_QUOTA_RISK" }
                    }
                }
            }
        } Catch {
            # Archive stats can fail transiently for freshly-provisioned archives — not fatal
        }
    }

    $record.Flags = ($flags -join ', ')
    $results.Add([PSCustomObject]$record)
}

# Summary
Write-Host ""
Write-Status "=== SUMMARY ===" -Status "OK"

$summary = @{
    NoArchive           = ($results | Where-Object { $_.Flags -match "NO_ARCHIVE" }).Count
    RetentionHoldStuck  = ($results | Where-Object { $_.Flags -match "RETENTION_HOLD_STUCK" }).Count
    NoMoveToArchiveTag  = ($results | Where-Object { $_.Flags -match "NO_MOVE_TO_ARCHIVE_TAG" }).Count
    QuotaRisk           = ($results | Where-Object { $_.Flags -match "ARCHIVE_QUOTA_RISK" }).Count
    LitHoldNoArchive    = ($results | Where-Object { $_.Flags -match "LIT_HOLD_NO_ARCHIVE" }).Count
}

Write-Host "  Mailboxes with no archive enabled:      $($summary.NoArchive)"
Write-Host "  Mailboxes with retention hold stuck ON: $($summary.RetentionHoldStuck)"
Write-Host "  Mailboxes missing a MoveToArchive tag:  $($summary.NoMoveToArchiveTag)"
Write-Host "  Archives at/near quota:                 $($summary.QuotaRisk)"
Write-Host "  Litigation hold + no archive (highest-priority combo): $($summary.LitHoldNoArchive)"

If ($summary.LitHoldNoArchive -gt 0) {
    Write-Status "$($summary.LitHoldNoArchive) mailbox(es) on litigation hold with no archive — these are the most likely source of 'mailbox always full' tickets" -Status "WARN"
}
If ($summary.RetentionHoldStuck -gt 0) {
    Write-Status "$($summary.RetentionHoldStuck) mailbox(es) have RetentionHoldEnabled=`$true — verify these are intentional (migration in progress) before clearing" -Status "WARN"
}

$results | Where-Object { $_.Flags -ne "" } | Format-Table UPN, ArchiveStatus, RetentionHoldEnabled, Flags -AutoSize

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report exported to: $OutputPath" -Status "OK"
