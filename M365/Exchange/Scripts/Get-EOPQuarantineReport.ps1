<#
.SYNOPSIS
    Reports quarantined messages, tenant allow/block list state, and spam filter policy config for triage or audit.

.DESCRIPTION
    Companion script for EOP-AntiSpam-B.md / EOP-AntiSpam-A.md. Automates the Triage and Diagnosis &
    Validation Flow steps from both runbooks in one pass: pulls quarantine messages for a user or
    tenant-wide, summarizes by QuarantineTypes (Spam/Phish/HighConfidencePhish/Bulk/Malware), lists
    active Tenant Allow/Block List entries with expiration dates, and reports the effective spam
    filter policy (BulkThreshold, SpamAction, HighConfidenceSpamAction) per recipient scope.

    Covers:
    - Quarantine message summary (counts by type, released vs. unreleased)
    - Tenant Allow/Block List — Sender allow/block entries and expiration audit (flags entries with
      no expiration date, per Fix 2's "never allow indefinitely" guidance)
    - Hosted Content Filter Policy inventory (Default + custom policies, BulkThreshold, actions)
    - Hosted Content Filter Rule inventory (which policy applies to which group/recipient)

    Does NOT cover:
    - Message trace (use Get-MessageTrace.ps1 in this same folder for delivery-path tracing)
    - DMARC/DKIM/SPF authentication checks (use Get-DKIMDMARCReport.ps1)
    - Releasing quarantined messages (this script is read-only reporting; use Release-QuarantineMessage
      manually per EOP-AntiSpam-B.md Fix 1 after review)

.PARAMETER RecipientAddress
    One or more recipient UPNs to scope the quarantine report to. Defaults to tenant-wide if omitted.

.PARAMETER DaysBack
    Number of days of quarantine history to retrieve. Default: 7. Max: 30 (practical UI/API limit).

.PARAMETER OutputPath
    Path for CSV export. Default: C:\Temp\EOPQuarantineReport-<timestamp>.csv

.EXAMPLE
    .\Get-EOPQuarantineReport.ps1 -RecipientAddress "user@contoso.com" -DaysBack 14

.EXAMPLE
    .\Get-EOPQuarantineReport.ps1
    # Tenant-wide quarantine + policy report, last 7 days

.NOTES
    Requires: Exchange Online module (ExchangeOnlineManagement) v3.0+
    Permissions: Security Reader (for read) / Security Administrator (recommended)
    Run-as: Connect-ExchangeOnline before running this script
    Safe: Read-only. Does not release, delete, or modify any quarantined message or policy.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]]$RecipientAddress,

    [ValidateRange(1, 30)]
    [int]$DaysBack = 7,

    [string]$OutputPath = "C:\Temp\EOPQuarantineReport-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

$startDate = (Get-Date).AddDays(-$DaysBack)

# --- 1. Quarantine messages ---
Write-Status "Retrieving quarantine messages (last $DaysBack days)..."
$quarantineResults = [System.Collections.Generic.List[PSObject]]::new()

Try {
    If ($RecipientAddress) {
        ForEach ($r in $RecipientAddress) {
            $msgs = Get-QuarantineMessage -RecipientAddress $r -StartExpiresDate $startDate -ErrorAction Stop
            $quarantineResults.AddRange([PSObject[]]$msgs)
        }
    } Else {
        $quarantineResults.AddRange([PSObject[]](Get-QuarantineMessage -StartExpiresDate $startDate -ErrorAction Stop))
    }
} Catch {
    Write-Status "Quarantine query failed: $_" -Status "ERROR"
}

Write-Status "Found $($quarantineResults.Count) quarantined message(s)"

$quarantineSummary = $quarantineResults | Group-Object QuarantineTypes | ForEach-Object {
    [PSCustomObject]@{
        QuarantineType = $_.Name
        Count          = $_.Count
        Released       = ($_.Group | Where-Object { $_.Released }).Count
        Unreleased     = ($_.Group | Where-Object { -not $_.Released }).Count
    }
}

If ($quarantineSummary) {
    Write-Host ""
    Write-Status "=== QUARANTINE SUMMARY (by type) ===" -Status "OK"
    $quarantineSummary | Format-Table -AutoSize

    $hcPhish = $quarantineResults | Where-Object { $_.QuarantineTypes -eq "HighConfidencePhish" -and -not $_.Released }
    If ($hcPhish) {
        Write-Status "$($hcPhish.Count) unreleased HighConfidencePhish message(s) — these require Global/Security Admin to release, review carefully" -Status "WARN"
    }
} Else {
    Write-Status "No quarantined messages in the lookback window" -Status "OK"
}

# --- 2. Tenant Allow/Block List audit ---
Write-Status "Auditing Tenant Allow/Block List..."
$tablResults = [System.Collections.Generic.List[PSObject]]::new()
Try {
    $tabl = Get-TenantAllowBlockListItems -ListType Sender -ErrorAction Stop
    ForEach ($item in $tabl) {
        $noExpiry = -not $item.ExpirationDate
        $tablResults.Add([PSCustomObject]@{
            Value          = $item.Value
            Action         = $item.Action
            ExpirationDate = $item.ExpirationDate
            NoExpirySet    = $noExpiry
            Notes          = $item.Notes
        })
        If ($noExpiry -and $item.Action -eq "Allow") {
            Write-Status "Allow entry '$($item.Value)' has NO expiration date — indefinite allow, review per Fix 2 guidance" -Status "WARN"
        }
    }
} Catch {
    Write-Status "Tenant Allow/Block List query failed: $_" -Status "WARN"
}

# --- 3. Hosted Content Filter Policies ---
Write-Status "Retrieving anti-spam policy configuration..."
$policyResults = [System.Collections.Generic.List[PSObject]]::new()
Try {
    $policies = Get-HostedContentFilterPolicy -ErrorAction Stop
    ForEach ($p in $policies) {
        $policyResults.Add([PSCustomObject]@{
            Name                     = $p.Name
            IsDefault                = $p.IsDefault
            SpamAction               = $p.SpamAction
            HighConfidenceSpamAction = $p.HighConfidenceSpamAction
            PhishSpamAction          = $p.PhishSpamAction
            HighConfidencePhishAction= $p.HighConfidencePhishAction
            BulkThreshold            = $p.BulkThreshold
            BulkSpamAction           = $p.BulkSpamAction
        })
    }
    Write-Host ""
    Write-Status "=== ANTI-SPAM POLICIES ===" -Status "OK"
    $policyResults | Format-Table -AutoSize
} Catch {
    Write-Status "Hosted Content Filter Policy query failed: $_" -Status "WARN"
}

# --- 4. Policy-to-recipient rule mapping ---
Write-Status "Retrieving policy assignment rules..."
$ruleResults = [System.Collections.Generic.List[PSObject]]::new()
Try {
    $rules = Get-HostedContentFilterRule -ErrorAction Stop
    ForEach ($r in $rules) {
        $ruleResults.Add([PSCustomObject]@{
            RuleName    = $r.Name
            Policy      = $r.HostedContentFilterPolicy
            Priority    = $r.Priority
            Enabled     = $r.Enabled
            Recipients  = ($r.SentTo -join ',')
            Groups      = ($r.SentToMemberOf -join ',')
        })
    }
    Write-Host ""
    Write-Status "=== POLICY ASSIGNMENT RULES ===" -Status "OK"
    $ruleResults | Format-Table -AutoSize
} Catch {
    Write-Status "Hosted Content Filter Rule query failed: $_" -Status "WARN"
}

# Export combined CSV (quarantine detail as primary rows; policy/TABL as separate sections in console only)
$quarantineResults |
    Select-Object ReceivedTime, SenderAddress, RecipientAddress, Subject, QuarantineTypes, Released, PolicyName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Status "Quarantine detail exported to: $OutputPath" -Status "OK"

$tablPath = $OutputPath -replace '\.csv$', '-AllowBlockList.csv'
$tablResults | Export-Csv -Path $tablPath -NoTypeInformation -Encoding UTF8
Write-Status "Allow/Block list exported to: $tablPath" -Status "OK"
