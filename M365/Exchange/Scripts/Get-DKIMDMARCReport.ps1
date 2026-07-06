<#
.SYNOPSIS
    Audits SPF, DKIM, and DMARC configuration for one or more accepted domains — DNS state vs. Exchange Online expectation.

.DESCRIPTION
    Companion script for DMARC-DKIM-B.md / DMARC-DKIM-A.md. Cross-references what Exchange Online
    expects for DKIM signing (Get-DkimSigningConfig) against what is actually published in DNS
    (selector1/selector2 CNAMEs, SPF TXT, DMARC TXT), and flags the specific misconfiguration
    classes both runbooks describe: missing SPF, SPF lookup-count risk (>10), unpublished/mismatched
    DKIM CNAMEs, DKIM enabled-but-not-Valid status, and missing/weak DMARC policy.

    Covers:
    - SPF presence + Exchange Online include: check + DNS lookup count (PermError risk per Fix 2)
    - DKIM signing config (Enabled/Status) vs. actual published CNAME values (mismatch = DNS not updated)
    - DMARC record presence, policy strength (none/quarantine/reject), and rua/ruf reporting addresses
    - MX record sanity check (does it point at Exchange Online)

    Does NOT cover:
    - DMARC aggregate (rua) report parsing — those are separate XML reports emailed to the rua address
    - Third-party sender alignment (Mailchimp/Salesforce custom DKIM) — flagged as a manual follow-up only

.PARAMETER Domain
    One or more accepted domains to audit (e.g. "contoso.com"). Accepts pipeline input.
    Defaults to all accepted domains in the tenant if not specified.

.PARAMETER OutputPath
    Path for CSV export. Default: C:\Temp\DKIMDMARCReport-<timestamp>.csv

.EXAMPLE
    .\Get-DKIMDMARCReport.ps1 -Domain "contoso.com"

.EXAMPLE
    .\Get-DKIMDMARCReport.ps1
    # Audits every accepted domain in the tenant

.NOTES
    Requires: Exchange Online module (ExchangeOnlineManagement) v3.0+, DnsClient (built-in on Windows)
    Permissions: Exchange Administrator or Security Administrator (read-only cmdlets used)
    Run-as: Connect-ExchangeOnline before running this script
    Safe: Read-only. Makes no DNS or Exchange configuration changes.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]]$Domain,

    [string]$OutputPath = "C:\Temp\DKIMDMARCReport-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# Resolve target domains
Write-Status "Resolving target domains..."
$targetDomains = @()
If ($Domain) {
    $targetDomains = $Domain
} Else {
    Write-Status "No domain specified — auditing ALL accepted domains in tenant" -Status "WARN"
    $targetDomains = (Get-AcceptedDomain).DomainName
}

Write-Status "Auditing $($targetDomains.Count) domain(s)..."

$results = [System.Collections.Generic.List[PSObject]]::new()

ForEach ($d in $targetDomains) {
    Write-Status "Processing: $d"

    $record = [ordered]@{
        Domain                = $d
        SPF_Present           = $false
        SPF_Record            = ""
        SPF_IncludesEXO       = $false
        SPF_LookupCount       = 0
        SPF_PermErrorRisk     = $false
        DKIM_Enabled          = $false
        DKIM_Status           = ""
        DKIM_Selector1_DNS_OK = $false
        DKIM_Selector2_DNS_OK = $false
        DMARC_Present         = $false
        DMARC_Policy          = ""
        DMARC_RUA             = ""
        MX_PointsToEXO        = $false
        Verdict               = ""
        Findings              = ""
    }

    $findings = @()

    # --- SPF ---
    Try {
        $spfTxt = (Resolve-DnsName -Name $d -Type TXT -ErrorAction Stop |
            Where-Object { $_.Strings -like '*v=spf1*' }).Strings
        If ($spfTxt) {
            $record.SPF_Present     = $true
            $record.SPF_Record      = ($spfTxt -join ' ')
            $record.SPF_IncludesEXO = $record.SPF_Record -match 'include:spf\.protection\.outlook\.com'
            $lookupCount = ([regex]::Matches($record.SPF_Record, '(?:^|\s)(include:|a:|a\s|mx:|mx(?:\s|$)|ptr:|exists:)')).Count
            $record.SPF_LookupCount   = $lookupCount
            $record.SPF_PermErrorRisk = $lookupCount -gt 10
            If (-not $record.SPF_IncludesEXO) { $findings += "SPF present but missing include:spf.protection.outlook.com" }
            If ($record.SPF_PermErrorRisk)     { $findings += "SPF lookup count ($lookupCount) exceeds 10 — PermError risk" }
        } Else {
            $findings += "SPF record missing entirely"
        }
    } Catch {
        $findings += "SPF DNS query failed: $_"
    }

    # --- DKIM (Exchange Online config vs DNS) ---
    Try {
        $dkim = Get-DkimSigningConfig -Identity $d -ErrorAction Stop
        $record.DKIM_Enabled = $dkim.Enabled
        $record.DKIM_Status  = $dkim.Status
        If (-not $dkim.Enabled) { $findings += "DKIM signing not enabled in Exchange Online" }
        ElseIf ($dkim.Status -ne "Valid") { $findings += "DKIM enabled but Status='$($dkim.Status)' (expected Valid)" }

        Try {
            $sel1 = Resolve-DnsName -Name "selector1._domainkey.$d" -Type CNAME -ErrorAction Stop
            $record.DKIM_Selector1_DNS_OK = ($sel1.NameHost -eq $dkim.Selector1CNAME)
            If (-not $record.DKIM_Selector1_DNS_OK) { $findings += "selector1 CNAME published but does not match expected target" }
        } Catch {
            $findings += "selector1._domainkey CNAME not published (NXDOMAIN)"
        }
        Try {
            $sel2 = Resolve-DnsName -Name "selector2._domainkey.$d" -Type CNAME -ErrorAction Stop
            $record.DKIM_Selector2_DNS_OK = ($sel2.NameHost -eq $dkim.Selector2CNAME)
            If (-not $record.DKIM_Selector2_DNS_OK) { $findings += "selector2 CNAME published but does not match expected target" }
        } Catch {
            $findings += "selector2._domainkey CNAME not published (NXDOMAIN)"
        }
    } Catch {
        $findings += "No DKIM signing config exists for this domain (New-DkimSigningConfig never run)"
    }

    # --- DMARC ---
    Try {
        $dmarcTxt = (Resolve-DnsName -Name "_dmarc.$d" -Type TXT -ErrorAction Stop).Strings
        If ($dmarcTxt) {
            $record.DMARC_Present = $true
            $dmarcJoined = ($dmarcTxt -join ' ')
            If ($dmarcJoined -match 'p=(\w+)') { $record.DMARC_Policy = $Matches[1] }
            If ($dmarcJoined -match 'rua=([^;]+)') { $record.DMARC_RUA = $Matches[1] }
            If ($record.DMARC_Policy -eq "none")   { $findings += "DMARC policy is p=none (monitor-only, no enforcement)" }
            If (-not $record.DMARC_RUA)            { $findings += "DMARC record has no rua= aggregate reporting address" }
        } Else {
            $findings += "DMARC record missing entirely (_dmarc TXT not found)"
        }
    } Catch {
        $findings += "DMARC record missing entirely (_dmarc TXT not found)"
    }

    # --- MX ---
    Try {
        $mx = Resolve-DnsName -Name $d -Type MX -ErrorAction Stop
        $record.MX_PointsToEXO = ($mx.NameExchange -match '\.mail\.protection\.outlook\.com$') -contains $true
        If (-not $record.MX_PointsToEXO) { $findings += "MX does not point to *.mail.protection.outlook.com (hybrid or misconfigured — verify intentional)" }
    } Catch {
        $findings += "MX record query failed: $_"
    }

    # Verdict
    If ($findings.Count -eq 0) {
        $record.Verdict = "HEALTHY"
    } ElseIf ($findings.Count -le 2) {
        $record.Verdict = "MINOR_GAPS"
    } Else {
        $record.Verdict = "AT_RISK"
    }
    $record.Findings = $findings -join ' | '

    $results.Add([PSCustomObject]$record)
}

# Output
Write-Host ""
Write-Status "=== SUMMARY ===" -Status "OK"
$results | Format-Table Domain, Verdict, SPF_Present, DKIM_Status, DMARC_Policy, MX_PointsToEXO -AutoSize

$atRisk = $results | Where-Object { $_.Verdict -eq "AT_RISK" }
If ($atRisk) {
    Write-Status "$($atRisk.Count) domain(s) flagged AT_RISK — review Findings column" -Status "WARN"
} Else {
    Write-Status "No domains flagged AT_RISK" -Status "OK"
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report exported to: $OutputPath" -Status "OK"
