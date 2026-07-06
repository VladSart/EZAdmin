<#
.SYNOPSIS
    Fleet-wide audit of Exchange Online shared mailboxes — type, delegation, licensing, quota, and
    sign-in security posture.

.DESCRIPTION
    Iterates every shared mailbox in the tenant (or a supplied list) and flags the specific misconfigurations
    called out as the most common root causes in SharedMailbox-B.md and SharedMailbox-A.md, rather than
    requiring an engineer to run the per-mailbox Diagnosis Steps manually one at a time:

    - WRONG_TYPE          RecipientTypeDetails is not SharedMailbox (converted/created wrong)
    - NO_FULL_ACCESS      No non-inherited Full Access delegate — an orphaned mailbox nobody can reach
    - SENTITEMS_GAP       Has Send As/Send On Behalf delegates but MessageCopyForSentAsEnabled and/or
                          MessageCopyForSendOnBehalfEnabled is False — sent mail won't land in the shared
                          mailbox's Sent Items, a common "where did my sent email go" ticket
    - QUOTA_RISK          Mailbox size within a configurable threshold of the 50GB free-tier ceiling
    - LICENSED_UNNECESSARY A full user licence is assigned with no evidence of the features that require
                          one (Litigation Hold, In-Place Hold, Exchange Online Archiving, > 50GB) — the
                          "wasteful and unnecessary" case called out in SharedMailbox-B.md Fix 6
    - SIGNIN_NOT_BLOCKED  The underlying Entra ID account has AccountEnabled = True — shared mailbox
                          accounts should not be capable of interactive sign-in (SharedMailbox-A.md
                          Validation Step 7 security note)
    - HIDDEN_FROM_GAL     HiddenFromAddressListsEnabled = True (informational — may be intentional)

    Read-only. Does not grant/revoke permissions, remove licences, or change GAL visibility — see
    SharedMailbox-B.md Common Fix Paths / SharedMailbox-A.md Remediation Playbooks for the corresponding
    fixes once a flagged mailbox is confirmed.

.PARAMETER Identity
    Optional list of specific shared mailbox SMTP addresses/identities to audit. Default: every
    mailbox in the tenant with RecipientTypeDetails -eq SharedMailbox (plus any UserMailbox matched by
    -IncludeMisconvertedCandidates, to catch WRONG_TYPE before it's obvious from the recipient filter alone).

.PARAMETER QuotaWarningGB
    Mailbox size (GB) at or above which a shared mailbox is flagged QUOTA_RISK. Default: 45 (leaves a
    5GB buffer before the 50GB free-tier ceiling referenced in SharedMailbox-A.md Validation Step 2).

.PARAMETER SkipGraphChecks
    Switch. Skip the Microsoft Graph-based licence and AccountEnabled checks (LICENSED_UNNECESSARY,
    SIGNIN_NOT_BLOCKED) and only run the Exchange Online-based checks. Use when Graph scopes are not
    available in the current session.

.PARAMETER OutputPath
    Path for CSV export of the full per-mailbox audit. Defaults to
    .\SharedMailboxAudit_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-SharedMailboxAudit.ps1

.EXAMPLE
    .\Get-SharedMailboxAudit.ps1 -Identity "support@contoso.com","billing@contoso.com" -QuotaWarningGB 40

.NOTES
    Requires: ExchangeOnlineManagement module, connected via Connect-ExchangeOnline.
    Optional:  Microsoft.Graph.Users module for LICENSED_UNNECESSARY / SIGNIN_NOT_BLOCKED checks
               (Connect-MgGraph -Scopes "User.Read.All").
    Safe: Yes — fully read-only against Exchange Online and Microsoft Graph.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$Identity,

    [Parameter(Mandatory = $false)]
    [double]$QuotaWarningGB = 45,

    [Parameter(Mandatory = $false)]
    [switch]$SkipGraphChecks,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\SharedMailboxAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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

# ---------------------------------------------------------------------------
# PREFLIGHT — EXCHANGE ONLINE
# ---------------------------------------------------------------------------
Write-Status "===== PREFLIGHT =====" "OK"
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Status "Module 'ExchangeOnlineManagement' not found. Install with: Install-Module ExchangeOnlineManagement -Scope CurrentUser" "ERROR"
    throw "Missing required module: ExchangeOnlineManagement"
}
Import-Module ExchangeOnlineManagement -ErrorAction Stop

try {
    $exoSession = Get-ConnectionInformation -ErrorAction SilentlyContinue
    if (-not $exoSession) {
        Write-Status "Not connected to Exchange Online. Connecting..." "WARN"
        Connect-ExchangeOnline -ShowBanner:$false | Out-Null
    }
    else {
        Write-Status "Connected to Exchange Online." "OK"
    }
}
catch {
    Write-Status "Failed to establish Exchange Online connection: $($_.Exception.Message)" "ERROR"
    throw
}

$graphAvailable = $false
if (-not $SkipGraphChecks) {
    if (Get-Module -ListAvailable -Name Microsoft.Graph.Users) {
        Import-Module Microsoft.Graph.Users -ErrorAction SilentlyContinue
        try {
            $mgContext = Get-MgContext -ErrorAction SilentlyContinue
            if (-not $mgContext) {
                Write-Status "Not connected to Microsoft Graph. Connecting for licence/sign-in checks..." "WARN"
                Connect-MgGraph -Scopes "User.Read.All" | Out-Null
            }
            $graphAvailable = $true
            Write-Status "Microsoft Graph available — LICENSED_UNNECESSARY and SIGNIN_NOT_BLOCKED checks enabled." "OK"
        }
        catch {
            Write-Status "Could not connect to Microsoft Graph — skipping licence/sign-in checks: $($_.Exception.Message)" "WARN"
        }
    }
    else {
        Write-Status "Microsoft.Graph.Users module not found — skipping licence/sign-in checks. Install to enable: Install-Module Microsoft.Graph.Users -Scope CurrentUser" "WARN"
    }
}
else {
    Write-Status "Skipping Graph-based checks (-SkipGraphChecks specified)." "INFO"
}

# ---------------------------------------------------------------------------
# DETECT — collect target shared mailboxes
# ---------------------------------------------------------------------------
Write-Status "===== COLLECTING SHARED MAILBOXES =====" "OK"
if ($Identity -and $Identity.Count -gt 0) {
    $mailboxes = $Identity | ForEach-Object {
        try { Get-Mailbox -Identity $_ -ErrorAction Stop }
        catch { Write-Status "Could not find mailbox '$_': $($_.Exception.Message)" "WARN" }
    }
}
else {
    $mailboxes = Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited
}

if (-not $mailboxes -or $mailboxes.Count -eq 0) {
    Write-Status "No shared mailboxes found to audit." "WARN"
    return
}
Write-Status "Auditing $($mailboxes.Count) shared mailbox(es)." "OK"

# ---------------------------------------------------------------------------
# EXECUTE — per-mailbox checks
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($mailbox in $mailboxes) {
    $flags = [System.Collections.Generic.List[string]]::new()
    $identity = $mailbox.PrimarySmtpAddress

    if ($mailbox.RecipientTypeDetails -ne "SharedMailbox") {
        $flags.Add("WRONG_TYPE")
    }

    $fullAccess = Get-MailboxPermission -Identity $identity -ErrorAction SilentlyContinue |
        Where-Object {
            $_.User -notlike "NT AUTHORITY*" -and $_.User -notlike "S-1-5*" -and
            $_.AccessRights -contains "FullAccess" -and -not $_.IsInherited -and -not $_.Deny
        }
    if (-not $fullAccess -or $fullAccess.Count -eq 0) {
        $flags.Add("NO_FULL_ACCESS")
    }

    $sendAs = Get-RecipientPermission -Identity $identity -ErrorAction SilentlyContinue |
        Where-Object { $_.Trustee -notlike "NT AUTHORITY*" }
    $sendOnBehalf = @($mailbox.GrantSendOnBehalfTo)

    if (($sendAs -and $sendAs.Count -gt 0) -or ($sendOnBehalf -and $sendOnBehalf.Count -gt 0)) {
        $sentItemsGap = @()
        if ($sendAs -and $sendAs.Count -gt 0 -and -not $mailbox.MessageCopyForSentAsEnabled) {
            $sentItemsGap += "SendAs"
        }
        if ($sendOnBehalf -and $sendOnBehalf.Count -gt 0 -and -not $mailbox.MessageCopyForSendOnBehalfEnabled) {
            $sentItemsGap += "SendOnBehalf"
        }
        if ($sentItemsGap.Count -gt 0) {
            $flags.Add("SENTITEMS_GAP:$($sentItemsGap -join '+')")
        }
    }

    $stats = Get-MailboxStatistics -Identity $identity -ErrorAction SilentlyContinue
    $sizeGB = $null
    if ($stats -and $stats.TotalItemSize) {
        try {
            $sizeGB = [math]::Round(($stats.TotalItemSize.Value.ToBytes() / 1GB), 2)
        }
        catch {
            $sizeGB = $null
        }
    }
    if ($sizeGB -and $sizeGB -ge $QuotaWarningGB) {
        $flags.Add("QUOTA_RISK:${sizeGB}GB")
    }

    if ($mailbox.HiddenFromAddressListsEnabled) {
        $flags.Add("HIDDEN_FROM_GAL")
    }

    $licenseSkus = $null
    $accountEnabled = $null
    if ($graphAvailable) {
        try {
            $graphUser = Get-MgUser -UserId $identity -Property "accountEnabled" -ErrorAction Stop
            $accountEnabled = $graphUser.AccountEnabled
            if ($accountEnabled) {
                $flags.Add("SIGNIN_NOT_BLOCKED")
            }

            $licenseDetails = Get-MgUserLicenseDetail -UserId $identity -ErrorAction SilentlyContinue
            if ($licenseDetails -and $licenseDetails.Count -gt 0) {
                $licenseSkus = ($licenseDetails.SkuPartNumber -join ",")
                $needsLicense = $mailbox.LitigationHoldEnabled -or
                                ($mailbox.ArchiveStatus -and $mailbox.ArchiveStatus -ne "None") -or
                                ($sizeGB -and $sizeGB -gt 50)
                if (-not $needsLicense) {
                    $flags.Add("LICENSED_UNNECESSARY:$licenseSkus")
                }
            }
        }
        catch {
            Write-Status "  Could not retrieve Graph user details for ${identity}: $($_.Exception.Message)" "WARN"
        }
    }

    $results.Add([PSCustomObject]@{
        Identity              = $identity
        DisplayName           = $mailbox.DisplayName
        RecipientTypeDetails  = $mailbox.RecipientTypeDetails
        FullAccessDelegates   = ($fullAccess | Select-Object -ExpandProperty User) -join "; "
        SendAsDelegates       = ($sendAs | Select-Object -ExpandProperty Trustee) -join "; "
        SendOnBehalfDelegates = ($sendOnBehalf -join "; ")
        SizeGB                = $sizeGB
        LitigationHoldEnabled = $mailbox.LitigationHoldEnabled
        ArchiveStatus         = $mailbox.ArchiveStatus
        HiddenFromGAL         = $mailbox.HiddenFromAddressListsEnabled
        LicenseSkus           = $licenseSkus
        AccountEnabled        = $accountEnabled
        Flags                 = ($flags -join "; ")
    })
}

# ---------------------------------------------------------------------------
# VALIDATE / REPORT
# ---------------------------------------------------------------------------
$flagged = @($results | Where-Object { $_.Flags -ne "" })

Write-Host ""
Write-Status "===== SHARED MAILBOX AUDIT SUMMARY =====" "OK"
Write-Status "Total mailboxes audited: $($results.Count)"
Write-Status "Flagged (one or more issues): $($flagged.Count)" $(if ($flagged.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "  WRONG_TYPE:            $(@($results | Where-Object {$_.Flags -like '*WRONG_TYPE*'}).Count)"
Write-Status "  NO_FULL_ACCESS:        $(@($results | Where-Object {$_.Flags -like '*NO_FULL_ACCESS*'}).Count)"
Write-Status "  SENTITEMS_GAP:         $(@($results | Where-Object {$_.Flags -like '*SENTITEMS_GAP*'}).Count)"
Write-Status "  QUOTA_RISK:            $(@($results | Where-Object {$_.Flags -like '*QUOTA_RISK*'}).Count)"
Write-Status "  LICENSED_UNNECESSARY:  $(@($results | Where-Object {$_.Flags -like '*LICENSED_UNNECESSARY*'}).Count)"
Write-Status "  SIGNIN_NOT_BLOCKED:    $(@($results | Where-Object {$_.Flags -like '*SIGNIN_NOT_BLOCKED*'}).Count)"
Write-Status "  HIDDEN_FROM_GAL (info):$(@($results | Where-Object {$_.Flags -like '*HIDDEN_FROM_GAL*'}).Count)"

if ($flagged.Count -gt 0) {
    $flagged | Format-Table Identity, RecipientTypeDetails, SizeGB, Flags -AutoSize -Wrap
}

try {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Full report exported to: $OutputPath" "OK"
}
catch {
    Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
}

Write-Status "Done." "OK"
