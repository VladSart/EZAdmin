<#
.SYNOPSIS
    Generates a comprehensive mailbox audit report for one or more mailboxes, including access, send-as, and permissions audit.

.DESCRIPTION
    Collects mailbox audit log entries, current permissions (Full Access, Send As, Send on Behalf),
    forwarding rules, and litigation hold status. Useful for compliance reviews, offboarding audits,
    and security investigations. Outputs to console and CSV.

    Covers:
    - Mailbox audit log entries (last N days)
    - Full Access, Send As, Send on Behalf permissions
    - Inbox forwarding rules
    - Auto-forwarding (SMTP forwarding via mailbox settings)
    - Litigation hold and retention policy status
    - Mailbox login activity summary

    Does NOT cover:
    - SharePoint/OneDrive audit
    - Teams message audit
    - Admin audit log (use Search-UnifiedAuditLog separately for those)

.PARAMETER Mailbox
    One or more mailboxes (UPN, alias, or display name). Accepts pipeline input.
    Defaults to ALL mailboxes if not specified (use with caution in large environments).

.PARAMETER DaysBack
    Number of days of audit log history to retrieve. Default: 30. Max: 90 (Exchange limitation).

.PARAMETER OutputPath
    Path for CSV export. Default: C:\Temp\MailboxAuditReport-<timestamp>.csv

.PARAMETER IncludeAuditLog
    Switch. If specified, fetches mailbox audit log entries (can be slow for many mailboxes).

.EXAMPLE
    .\Get-MailboxAuditReport.ps1 -Mailbox "john.smith@contoso.com" -DaysBack 30 -IncludeAuditLog

.EXAMPLE
    "user1@contoso.com","user2@contoso.com" | .\Get-MailboxAuditReport.ps1 -DaysBack 7

.EXAMPLE
    .\Get-MailboxAuditReport.ps1 -DaysBack 30
    # Reports on ALL mailboxes — use in small tenants only

.NOTES
    Requires: Exchange Online module (ExchangeOnlineManagement) v3.0+
    Permissions: Exchange Administrator or Security Administrator
    Run-as: Connect-ExchangeOnline before running this script
    Safe: Read-only. No changes made to any mailbox.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]]$Mailbox,

    [ValidateRange(1, 90)]
    [int]$DaysBack = 30,

    [string]$OutputPath = "C:\Temp\MailboxAuditReport-$(Get-Date -Format 'yyyyMMdd-HHmm').csv",

    [switch]$IncludeAuditLog
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

# Preflight: verify Exchange Online connection
Write-Status "Checking Exchange Online connection..."
Try {
    $null = Get-OrganizationConfig -ErrorAction Stop
    Write-Status "Exchange Online connected" -Status "OK"
} Catch {
    Write-Status "Not connected to Exchange Online. Run: Connect-ExchangeOnline" -Status "ERROR"
    Exit 1
}

New-Item -Path (Split-Path $OutputPath) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

$startDate = (Get-Date).AddDays(-$DaysBack)
$results   = [System.Collections.Generic.List[PSObject]]::new()

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
    Write-Status "No mailbox specified — retrieving ALL mailboxes (this may take a while)..." -Status "WARN"
    $mailboxObjects = Get-Mailbox -ResultSize Unlimited
}

Write-Status "Processing $($mailboxObjects.Count) mailbox(es)..."

ForEach ($mbx in $mailboxObjects) {
    Write-Status "Processing: $($mbx.UserPrincipalName)"

    $record = [ordered]@{
        UPN                  = $mbx.UserPrincipalName
        DisplayName          = $mbx.DisplayName
        PrimarySmtpAddress   = $mbx.PrimarySmtpAddress
        MailboxType          = $mbx.RecipientTypeDetails
        LitigationHoldEnabled = $mbx.LitigationHoldEnabled
        LitigationHoldDate   = $mbx.LitigationHoldDate
        RetentionPolicy      = $mbx.RetentionPolicy
        ForwardingAddress    = ""
        ForwardingSMTP       = ""
        DeliverToMailbox     = ""
        FullAccessDelegates  = ""
        SendAsDelegates      = ""
        SendOnBehalfDelegates = ""
        InboxForwardingRules = ""
        AuditEnabled         = $mbx.AuditEnabled
        AuditLogAgeLimit     = $mbx.AuditLogAgeLimit
        LastLogonTime        = ""
        RecentAuditEvents    = ""
    }

    # Forwarding settings
    If ($mbx.ForwardingAddress) {
        $record.ForwardingAddress  = $mbx.ForwardingAddress
        $record.DeliverToMailbox   = $mbx.DeliverToMailboxAndForward
    }
    If ($mbx.ForwardingSmtpAddress) {
        $record.ForwardingSMTP     = $mbx.ForwardingSmtpAddress
        $record.DeliverToMailbox   = $mbx.DeliverToMailboxAndForward
    }

    # Full Access permissions
    Try {
        $faPerms = Get-MailboxPermission -Identity $mbx.Identity |
            Where-Object { $_.IsInherited -eq $false -and $_.User -notlike "NT AUTHORITY*" -and $_.User -notlike "S-1-*" }
        $record.FullAccessDelegates = ($faPerms | ForEach-Object { "$($_.User) [$($_.AccessRights -join ',')]" }) -join '; '
    } Catch {
        $record.FullAccessDelegates = "Error: $_"
    }

    # Send As permissions
    Try {
        $saPerms = Get-RecipientPermission -Identity $mbx.Identity |
            Where-Object { $_.IsInherited -eq $false -and $_.Trustee -notlike "NT AUTHORITY*" }
        $record.SendAsDelegates = ($saPerms.Trustee) -join '; '
    } Catch {
        $record.SendAsDelegates = "Error: $_"
    }

    # Send on Behalf
    If ($mbx.GrantSendOnBehalfTo) {
        $record.SendOnBehalfDelegates = $mbx.GrantSendOnBehalfTo -join '; '
    }

    # Inbox forwarding rules
    Try {
        $fwRules = Get-InboxRule -Mailbox $mbx.Identity -ErrorAction Stop |
            Where-Object { $_.ForwardTo -or $_.ForwardAsAttachmentTo -or $_.RedirectTo }
        If ($fwRules) {
            $ruleDetails = $fwRules | ForEach-Object {
                $targets = @($_.ForwardTo, $_.ForwardAsAttachmentTo, $_.RedirectTo) | Where-Object { $_ } | ForEach-Object { $_ -join ',' }
                "Rule:'$($_.Name)' → $($targets -join '; ')"
            }
            $record.InboxForwardingRules = $ruleDetails -join ' | '
        }
    } Catch {
        $record.InboxForwardingRules = "Could not retrieve (access denied or OWA rules)"
    }

    # Last logon (from mailbox statistics)
    Try {
        $stats = Get-MailboxStatistics -Identity $mbx.Identity -ErrorAction SilentlyContinue
        If ($stats) { $record.LastLogonTime = $stats.LastLogonTime }
    } Catch { }

    # Mailbox audit log (optional — slow)
    If ($IncludeAuditLog -and $mbx.AuditEnabled) {
        Try {
            $auditEntries = Search-MailboxAuditLog -Identity $mbx.Identity `
                -StartDate $startDate -EndDate (Get-Date) `
                -ShowDetails -LogonTypes Delegate, Admin `
                -ResultSize 50 -ErrorAction Stop

            If ($auditEntries) {
                $summary = $auditEntries | Group-Object Operation |
                    ForEach-Object { "$($_.Name):$($_.Count)" }
                $record.RecentAuditEvents = $summary -join ', '
            } Else {
                $record.RecentAuditEvents = "No audit events in last $DaysBack days"
            }
        } Catch {
            $record.RecentAuditEvents = "Audit log query failed: $_"
        }
    } ElseIf ($IncludeAuditLog -and !$mbx.AuditEnabled) {
        $record.RecentAuditEvents = "Audit logging DISABLED on this mailbox"
    }

    $results.Add([PSCustomObject]$record)
}

# Output
Write-Host ""
Write-Status "=== SUMMARY ===" -Status "OK"

# Flag high-interest findings
$flagged = @()
ForEach ($r in $results) {
    If ($r.ForwardingAddress -or $r.ForwardingSMTP) {
        $flagged += "  ⚠ FORWARDING: $($r.UPN) → $($r.ForwardingAddress)$($r.ForwardingSMTP)"
    }
    If ($r.InboxForwardingRules -and $r.InboxForwardingRules -ne "") {
        $flagged += "  ⚠ INBOX RULE FORWARDING: $($r.UPN)"
    }
    If (!$r.AuditEnabled) {
        $flagged += "  ⚠ AUDIT DISABLED: $($r.UPN)"
    }
}

If ($flagged) {
    Write-Status "High-interest findings:" -Status "WARN"
    $flagged | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
} Else {
    Write-Status "No high-interest findings (no active forwarding, audit enabled on all)" -Status "OK"
}

Write-Host ""
$results | Format-Table UPN, LitigationHoldEnabled, ForwardingSMTP, FullAccessDelegates -AutoSize

# Export
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report exported to: $OutputPath" -Status "OK"
