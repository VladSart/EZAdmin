<#
.SYNOPSIS
    Audits an Exchange Online tenant's exposure to Direct Send abuse and reports the
    current mitigation posture (RejectDirectSend, SPF enforcement, anti-phishing spoof
    intelligence).

.DESCRIPTION
    Connects to Exchange Online and reports, read-only:
    - Current RejectDirectSend organization-config state (the primary control — default
      is False/off, meaning unauthenticated Direct Send is exposed unless explicitly
      rejected)
    - The tenant's accepted domains and each domain's SPF TXT record enforcement
      qualifier (-all hard fail / ~all soft fail / ?all neutral / missing), since
      Direct Send-delivered mail IS subject to SPF evaluation (unlike genuine intra-org
      mail) and a weak SPF record is the single biggest factor in whether an abuse
      attempt actually reaches an inbox
    - Anti-phishing policy spoof intelligence enablement and authentication-fail action
    - A message-trace sweep over a configurable lookback window flagging messages sent
      to an accepted domain with an empty Connectors field (a strong Direct-Send
      indicator), grouped by sender address, to surface both potential abuse and
      undocumented legitimate dependents that would need migrating before enabling
      RejectDirectSend

    This does NOT inspect individual message headers for MessageDirectionality/AuthAs
    (that requires Defender for Office 365 Advanced Hunting or a per-message header
    pull — see DirectSendAbuse-A.md's KQL query and Validation Step 5) and does NOT
    modify RejectDirectSend, SPF records, or any policy. Read-only audit only.

.PARAMETER LookbackDays
    Number of days of message trace history to sweep for Direct Send indicators.
    Default: 7. Exchange Online message trace supports up to 90 days via the newer
    reporting APIs, but this script uses Get-MessageTrace, which is capped at 10 days
    per call — values above 10 are automatically chunked into multiple calls.

.PARAMETER OutputPath
    Path for the CSV export of flagged sender addresses. Default:
    .\DirectSend-Exposure-Audit-<timestamp>.csv

.EXAMPLE
    .\Get-DirectSendExposureAudit.ps1

.EXAMPLE
    .\Get-DirectSendExposureAudit.ps1 -LookbackDays 30 -OutputPath C:\Reports\directsend.csv

.NOTES
    Requires: ExchangeOnlineManagement PowerShell module, connected session
              (Connect-ExchangeOnline)
    Scopes/Role needed: Global Reader or View-Only Organization Management is sufficient
              for all read operations in this script. RejectDirectSend itself can only
              be SET by an account holding the Organization Configuration role — this
              script does not set it.
    Safe: Read-only — makes no configuration changes (RejectDirectSend, SPF, or
          anti-phishing policy are only reported, never modified)
    Cross-references: M365/Exchange/DirectSendAbuse-B.md (Triage, Fix 1-5),
                       M365/Exchange/DirectSendAbuse-A.md (How It Works, Validation Steps,
                       Playbooks 1-3)
#>

[CmdletBinding()]
param(
    [int]$LookbackDays = 7,

    [string]$OutputPath = ".\DirectSend-Exposure-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# ─── Connect ───
try {
    $null = Get-ConnectionInformation -EA Stop
} catch {
    Write-Status "Connecting to Exchange Online..." "INFO"
    try {
        Connect-ExchangeOnline -ShowBanner:$false
    } catch {
        Write-Status "Failed to connect to Exchange Online: $($_.Exception.Message)" "ERROR"
        return
    }
}

# ─── RejectDirectSend state ───
Write-Status "Checking RejectDirectSend organization-config state..." "INFO"
$rejectState = $null
try {
    $orgConfig  = Get-OrganizationConfig -EA Stop
    $rejectState = $orgConfig.RejectDirectSend
    Write-Status "RejectDirectSend: $rejectState" $(if ($rejectState) { "OK" } else { "WARN" })
    if (-not $rejectState) {
        Write-Status "Tenant is exposed to unauthenticated Direct Send delivery — see DirectSendAbuse-B.md Fix 1." "WARN"
    }
} catch {
    Write-Status "Could not read RejectDirectSend (module may be outdated — Update-Module ExchangeOnlineManagement): $($_.Exception.Message)" "ERROR"
}

# ─── Anti-phishing spoof intelligence ───
Write-Status "`nChecking anti-phishing spoof intelligence policies..." "INFO"
$phishResults = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $policies = Get-AntiPhishPolicy -EA Stop
    foreach ($p in $policies) {
        $flag = if ($p.EnableSpoofIntelligence) { "OK" } else { "WARN" }
        Write-Status "Policy '$($p.Name)': SpoofIntelligence=$($p.EnableSpoofIntelligence), AuthFailAction=$($p.AuthenticationFailAction)" $flag
        $phishResults.Add([PSCustomObject]@{
            PolicyName             = $p.Name
            EnableSpoofIntelligence = $p.EnableSpoofIntelligence
            AuthenticationFailAction = $p.AuthenticationFailAction
        })
    }
} catch {
    Write-Status "Could not enumerate anti-phishing policies: $($_.Exception.Message)" "ERROR"
}

# ─── Accepted domains + SPF enforcement ───
Write-Status "`nChecking accepted domains and SPF enforcement..." "INFO"
$domainResults = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $domains = Get-AcceptedDomain -EA Stop
    foreach ($d in $domains) {
        $spfQualifier = "NOT FOUND"
        $spfFlag = "ERROR"
        try {
            $txt = Resolve-DnsName -Name $d.DomainName -Type TXT -EA Stop |
                Where-Object { $_.Strings -like "*v=spf1*" } | Select-Object -First 1
            if ($txt) {
                $spfString = ($txt.Strings -join " ")
                if ($spfString -match "-all")      { $spfQualifier = "HARD FAIL (-all)";  $spfFlag = "OK" }
                elseif ($spfString -match "~all")   { $spfQualifier = "SOFT FAIL (~all)";  $spfFlag = "WARN" }
                elseif ($spfString -match "\?all")  { $spfQualifier = "NEUTRAL (?all)";    $spfFlag = "WARN" }
                else                                 { $spfQualifier = "NO ALL QUALIFIER"; $spfFlag = "WARN" }
            }
        } catch {
            $spfQualifier = "DNS LOOKUP FAILED"
        }
        Write-Status "Domain '$($d.DomainName)': SPF = $spfQualifier" $spfFlag
        $domainResults.Add([PSCustomObject]@{
            Domain       = $d.DomainName
            IsDefault    = $d.Default
            SPFQualifier = $spfQualifier
        })
    }
} catch {
    Write-Status "Could not enumerate accepted domains: $($_.Exception.Message)" "ERROR"
}

# ─── Message trace sweep for Direct Send indicators ───
Write-Status "`nSweeping message trace for possible Direct Send traffic (last $LookbackDays day(s))..." "INFO"
$senderResults = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $acceptedDomainNames = $domainResults.Domain
    $endDate   = Get-Date
    $chunkDays = 10
    $remaining = $LookbackDays
    $traceHits = [System.Collections.Generic.List[object]]::new()

    while ($remaining -gt 0) {
        $span      = [Math]::Min($chunkDays, $remaining)
        $startDate = $endDate.AddDays(-$span)
        try {
            $chunk = Get-MessageTrace -StartDate $startDate -EndDate $endDate -PageSize 1000 -EA Stop
            foreach ($m in $chunk) { $traceHits.Add($m) }
        } catch {
            Write-Status "Message trace chunk failed ($startDate to $endDate): $($_.Exception.Message)" "WARN"
        }
        $endDate   = $startDate
        $remaining -= $span
    }

    # Flag messages to an accepted domain with no populated connector — a Direct Send indicator.
    # NOTE: Get-MessageTrace does not expose the ConnectorName field directly in all tenant
    # configurations; this heuristic uses FromIP/Organization emptiness as a proxy and should
    # be treated as a candidate list requiring header-level confirmation (see DirectSendAbuse-A.md
    # Validation Step 2/5), not a definitive verdict.
    $flagged = $traceHits | Where-Object {
        $recipientDomain = ($_.RecipientAddress -split "@")[-1]
        $recipientDomain -in $acceptedDomainNames -and [string]::IsNullOrWhiteSpace($_.Organization)
    }

    $bySender = $flagged | Group-Object SenderAddress | Sort-Object Count -Descending

    foreach ($grp in $bySender) {
        $senderResults.Add([PSCustomObject]@{
            SenderAddress = $grp.Name
            MessageCount  = $grp.Count
            SampleSubject = ($grp.Group | Select-Object -First 1).Subject
            SampleReceived = ($grp.Group | Select-Object -First 1).Received
        })
    }

    if ($senderResults.Count -eq 0) {
        Write-Status "No candidate Direct Send traffic found in the lookback window (or Organization field wasn't a reliable indicator for this tenant's connector config — confirm with header-level checks)." "OK"
    } else {
        Write-Status "$($senderResults.Count) candidate sender address(es) found — review each: legitimate device/app to migrate (DirectSendAbuse-A.md Playbook 1), or confirmed abuse." "WARN"
        foreach ($r in $senderResults) {
            Write-Status "  $($r.SenderAddress) — $($r.MessageCount) message(s), e.g. '$($r.SampleSubject)'" "WARN"
        }
    }
} catch {
    Write-Status "Message trace sweep failed: $($_.Exception.Message)" "ERROR"
}

# ─── Export ───
if ($senderResults.Count -gt 0) {
    $outputDir = Split-Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $senderResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "`nCandidate sender results exported to: $OutputPath" "OK"
}

# ─── Summary ───
Write-Host "`n=== Direct Send Exposure Summary ===" -ForegroundColor Cyan
Write-Host "RejectDirectSend enabled       : $rejectState"
Write-Host "Domains with hard-fail SPF     : $(($domainResults | Where-Object { $_.SPFQualifier -like 'HARD FAIL*' }).Count) / $($domainResults.Count)"
Write-Host "Domains with weak/missing SPF  : $(($domainResults | Where-Object { $_.SPFQualifier -notlike 'HARD FAIL*' }).Count) / $($domainResults.Count)"
Write-Host "Anti-phish spoof intel policies: $(($phishResults | Where-Object { $_.EnableSpoofIntelligence }).Count) / $($phishResults.Count) enabled"
Write-Host "Candidate Direct Send senders  : $($senderResults.Count)"

if (-not $rejectState -and $senderResults.Count -eq 0) {
    Write-Status "RejectDirectSend is off and no candidate senders were found in this window — safe to consider enabling RejectDirectSend after a longer lookback confirms no infrequent legitimate dependents exist." "WARN"
} elseif (-not $rejectState -and $senderResults.Count -gt 0) {
    Write-Status "RejectDirectSend is off AND candidate sender traffic exists — review the exported list before enabling; each entry needs to be classified as legitimate (migrate per Playbook 1) or abuse." "ERROR"
} elseif ($rejectState) {
    Write-Status "RejectDirectSend is already enabled — tenant is protected against the primary vector; SPF/anti-phish findings above remain relevant as defense-in-depth." "OK"
}
