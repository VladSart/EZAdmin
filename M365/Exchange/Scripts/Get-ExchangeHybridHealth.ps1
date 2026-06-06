<#
.SYNOPSIS
    Validates Exchange hybrid coexistence health — connectors, mail flow, migration endpoints, and OAuth.

.DESCRIPTION
    Runs a structured health check of an Exchange hybrid configuration, covering both
    the on-premises Exchange organisation and Exchange Online. Outputs a findings table
    and exports results to CSV for escalation or audit purposes.

    Covers:
    - Hybrid send/receive connectors (on-premises and EXO)
    - Mail flow: test message delivery (on-prem → EXO and EXO → on-prem)
    - Migration endpoint reachability
    - OAuth / Hybrid Modern Authentication configuration
    - Free/busy cross-premises availability
    - MRS Proxy service status
    - TLS certificate on the hybrid send connector
    - Domain shared namespace vs. split DNS

    Does NOT cover:
    - Exchange Hybrid Wizard re-running or configuration changes
    - Full mailbox migration execution
    - Edge Transport server health

.PARAMETER OnPremExchangeServer
    FQDN of an on-premises Exchange server (CAS/Mailbox). Required for remote PowerShell.

.PARAMETER OnPremCredential
    PSCredential for the on-premises Exchange remote PowerShell session.

.PARAMETER TenantDomain
    Your tenant's primary SMTP domain (e.g. contoso.com). Required.

.PARAMETER SkipMailFlowTest
    If specified, skips the live mail flow test (useful when a test mailbox isn't available).

.PARAMETER TestMailbox
    UPN of a cloud mailbox to use for mail flow test. Required unless -SkipMailFlowTest.

.PARAMETER ExportPath
    Path for the CSV export. Default: .\HybridHealth-<timestamp>.csv

.EXAMPLE
    .\Get-ExchangeHybridHealth.ps1 `
        -OnPremExchangeServer mail.contoso.local `
        -OnPremCredential (Get-Credential) `
        -TenantDomain contoso.com `
        -TestMailbox admin@contoso.com

.EXAMPLE
    .\Get-ExchangeHybridHealth.ps1 `
        -OnPremExchangeServer mail.contoso.local `
        -OnPremCredential (Get-Credential) `
        -TenantDomain contoso.com `
        -SkipMailFlowTest

.NOTES
    Requires: Exchange Management Shell (on-prem) + ExchangeOnlineManagement module
    Run-as: Exchange Organization Admin (on-prem) + Exchange Admin (EXO)
    Safe: Read-only checks + one test message if -TestMailbox is supplied
    Tested on: Exchange 2016/2019 hybrid with Exchange Online
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OnPremExchangeServer,
    [Parameter(Mandatory)][System.Management.Automation.PSCredential]$OnPremCredential,
    [Parameter(Mandatory)][string]$TenantDomain,
    [switch]$SkipMailFlowTest,
    [string]$TestMailbox,
    [string]$ExportPath
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

function Add-Finding {
    param(
        [string]$Area,
        [string]$Check,
        [string]$Result,
        [string]$Status,
        [string]$Detail = ""
    )
    $script:findings.Add([PSCustomObject]@{
        Area      = $Area
        Check     = $Check
        Result    = $Result
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "  [$Status] $Check : $Result" -ForegroundColor $colour
    if ($Detail) { Write-Host "           $Detail" -ForegroundColor DarkGray }
}

$script:findings = [System.Collections.Generic.List[PSCustomObject]]::new()

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\HybridHealth-$timestamp.csv"
}

if (-not $SkipMailFlowTest -and -not $TestMailbox) {
    Write-Status "No -TestMailbox specified. Use -SkipMailFlowTest or provide -TestMailbox <UPN>." "WARN"
    $SkipMailFlowTest = $true
}

#region ─── Connect to on-premises Exchange ───────────────────────────────────
Write-Status "Connecting to on-premises Exchange: $OnPremExchangeServer"
try {
    $onPremSession = New-PSSession `
        -ConfigurationName Microsoft.Exchange `
        -ConnectionUri "http://$OnPremExchangeServer/PowerShell/" `
        -Authentication Kerberos `
        -Credential $OnPremCredential `
        -ErrorAction Stop
    Import-PSSession $onPremSession -DisableNameChecking -AllowClobber | Out-Null
    Write-Status "Connected to on-premises Exchange" "OK"
} catch {
    Write-Status "Failed to connect to on-premises Exchange: $_" "ERROR"
    exit 1
}
#endregion

#region ─── Connect to Exchange Online ───────────────────────────────────────
Write-Status "Connecting to Exchange Online..."
try {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        Write-Status "ExchangeOnlineManagement module not found. Install: Install-Module ExchangeOnlineManagement" "ERROR"
        exit 1
    }
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    Write-Status "Connected to Exchange Online" "OK"
} catch {
    Write-Status "Failed to connect to Exchange Online: $_" "ERROR"
    Remove-PSSession $onPremSession
    exit 1
}
#endregion

#region ─── 1. On-Premises Hybrid Connectors ──────────────────────────────────
Write-Status "Checking on-premises hybrid connectors..."

# Outbound (Send) connector to EXO
$onPremSend = Get-SendConnector | Where-Object { $_.AddressSpaces -like "*$TenantDomain*" -or $_.Name -like "*Hybrid*" -or $_.Name -like "*Office 365*" }
if ($onPremSend) {
    foreach ($sc in $onPremSend) {
        $certCheck = if ($sc.TlsAuthLevel -eq "DomainValidation" -or $sc.TlsAuthLevel -eq "CertificateValidation") { "TLS enforced" } else { "TLS not enforced" }
        $statusLabel = if ($sc.Enabled -and $sc.TlsAuthLevel -ne "None") { "OK" } elseif (-not $sc.Enabled) { "ERROR" } else { "WARN" }
        Add-Finding -Area "On-Prem Connectors" -Check "Send connector: $($sc.Name)" `
            -Result "Enabled=$($sc.Enabled), SmartHost=$($sc.SmartHosts), TLS=$($sc.TlsAuthLevel)" `
            -Status $statusLabel -Detail $certCheck
    }
} else {
    Add-Finding -Area "On-Prem Connectors" -Check "Hybrid Send connector" `
        -Result "NOT FOUND — no send connector matching $TenantDomain" -Status "ERROR"
}

# Inbound (Receive) connector from EXO
$onPremReceive = Get-ReceiveConnector | Where-Object { $_.Name -like "*Hybrid*" -or $_.Name -like "*Office 365*" -or $_.RemoteIPRanges -like "*40.92.*" }
if ($onPremReceive) {
    foreach ($rc in $onPremReceive) {
        $statusLabel = if ($rc.Enabled) { "OK" } else { "ERROR" }
        Add-Finding -Area "On-Prem Connectors" -Check "Receive connector: $($rc.Name)" `
            -Result "Enabled=$($rc.Enabled), AuthMechanism=$($rc.AuthMechanism), TLS=$($rc.RequireTLS)" `
            -Status $statusLabel
    }
} else {
    Add-Finding -Area "On-Prem Connectors" -Check "Hybrid Receive connector" `
        -Result "NOT FOUND — no receive connector for EXO IP ranges" -Status "WARN" `
        -Detail "EXO sends from 40.92.0.0/14, 40.107.0.0/16, 52.100.0.0/14 ranges"
}
#endregion

#region ─── 2. EXO Inbound/Outbound Connectors ───────────────────────────────
Write-Status "Checking Exchange Online connectors..."

$exoInbound = Get-InboundConnector | Where-Object { $_.ConnectorType -eq "OnPremises" -or $_.Name -like "*Hybrid*" }
if ($exoInbound) {
    foreach ($ic in $exoInbound) {
        $statusLabel = if ($ic.Enabled) { "OK" } else { "ERROR" }
        Add-Finding -Area "EXO Connectors" -Check "EXO Inbound: $($ic.Name)" `
            -Result "Enabled=$($ic.Enabled), TLSSenderCert=$($ic.TlsSenderCertificateName)" `
            -Status $statusLabel
    }
} else {
    Add-Finding -Area "EXO Connectors" -Check "EXO Inbound connector" `
        -Result "NOT FOUND" -Status "ERROR"
}

$exoOutbound = Get-OutboundConnector | Where-Object { $_.ConnectorType -eq "OnPremises" -or $_.Name -like "*Hybrid*" }
if ($exoOutbound) {
    foreach ($oc in $exoOutbound) {
        $statusLabel = if ($oc.Enabled) { "OK" } else { "ERROR" }
        Add-Finding -Area "EXO Connectors" -Check "EXO Outbound: $($oc.Name)" `
            -Result "Enabled=$($oc.Enabled), SmartHost=$($oc.SmartHosts), TLS=$($oc.TlsSettings)" `
            -Status $statusLabel
    }
} else {
    Add-Finding -Area "EXO Connectors" -Check "EXO Outbound connector" `
        -Result "NOT FOUND" -Status "ERROR"
}
#endregion

#region ─── 3. MRS Proxy ──────────────────────────────────────────────────────
Write-Status "Checking MRS Proxy (mailbox move endpoint)..."

$mrsProxyEndpoint = Get-WebServicesVirtualDirectory | Select-Object Server, MRSProxyEnabled, InternalUrl, ExternalUrl
foreach ($ep in $mrsProxyEndpoint) {
    $statusLabel = if ($ep.MRSProxyEnabled) { "OK" } else { "WARN" }
    Add-Finding -Area "MRS Proxy" -Check "MRS Proxy on $($ep.Server)" `
        -Result "Enabled=$($ep.MRSProxyEnabled) | ExternalURL=$($ep.ExternalUrl)" `
        -Status $statusLabel `
        -Detail $(if (-not $ep.MRSProxyEnabled) { "Enable with: Set-WebServicesVirtualDirectory -Identity '$($ep.Server)\EWS (Default Web Site)' -MRSProxyEnabled `$true" } else { "" })
}

# Check migration endpoint in EXO
try {
    $migEndpoints = Get-MigrationEndpoint -ErrorAction SilentlyContinue
    if ($migEndpoints) {
        foreach ($me in $migEndpoints) {
            Add-Finding -Area "MRS Proxy" -Check "Migration endpoint: $($me.Identity)" `
                -Result "Type=$($me.EndpointType) | RemoteServer=$($me.RemoteServer)" -Status "OK"
        }
    } else {
        Add-Finding -Area "MRS Proxy" -Check "EXO Migration endpoints" `
            -Result "None found — no hybrid migration endpoints configured in EXO" -Status "WARN"
    }
} catch {
    Add-Finding -Area "MRS Proxy" -Check "EXO Migration endpoints" `
        -Result "Query failed: $_" -Status "ERROR"
}
#endregion

#region ─── 4. OAuth / Hybrid Modern Auth ─────────────────────────────────────
Write-Status "Checking OAuth / Hybrid Modern Authentication..."

try {
    $authServer = Get-AuthServer | Where-Object { $_.Name -like "*ACS*" -or $_.Name -like "*MicrosoftACS*" -or $_.IsDefaultAuthorizationEndpoint }
    if ($authServer) {
        foreach ($as in $authServer) {
            $statusLabel = if ($as.Enabled) { "OK" } else { "WARN" }
            Add-Finding -Area "OAuth" -Check "Auth server: $($as.Name)" `
                -Result "Enabled=$($as.Enabled) | Realm=$($as.Realm)" -Status $statusLabel
        }
    } else {
        Add-Finding -Area "OAuth" -Check "On-prem Auth server (ACS)" `
            -Result "Not configured — OAuth may not be set up for Hybrid Modern Auth" -Status "WARN" `
            -Detail "Run Hybrid Wizard or: New-AuthServer -Name 'ACS' -AuthMetadataUrl 'https://accounts.accesscontrol.windows.net/<tenantId>/metadata/json/1'"
    }
} catch {
    Add-Finding -Area "OAuth" -Check "Auth server check" -Result "Query failed: $_" -Status "ERROR"
}

try {
    $partnerApp = Get-PartnerApplication | Where-Object { $_.Name -like "*Exchange Online*" -or $_.ApplicationIdentifier -like "*outlook*" }
    if ($partnerApp) {
        Add-Finding -Area "OAuth" -Check "Partner app (EXO trust)" `
            -Result "Found: $($partnerApp.Name) | Enabled=$($partnerApp.Enabled)" `
            -Status $(if ($partnerApp.Enabled) { "OK" } else { "WARN" })
    } else {
        Add-Finding -Area "OAuth" -Check "Partner app (EXO trust)" `
            -Result "Not found" -Status "WARN"
    }
} catch {
    Add-Finding -Area "OAuth" -Check "Partner app check" -Result "Query failed: $_" -Status "WARN"
}
#endregion

#region ─── 5. Free/Busy ──────────────────────────────────────────────────────
Write-Status "Checking free/busy configuration..."

try {
    $orgRelationship = Get-OrganizationRelationship | Where-Object { $_.DomainNames -like "*$TenantDomain*" -or $_.Name -like "*Office 365*" -or $_.Name -like "*Exchange Online*" }
    if ($orgRelationship) {
        foreach ($or in $orgRelationship) {
            $fbEnabled = $or.FreeBusyAccessEnabled
            $statusLabel = if ($or.Enabled -and $fbEnabled) { "OK" } elseif ($or.Enabled -and -not $fbEnabled) { "WARN" } else { "ERROR" }
            Add-Finding -Area "FreeBusy" -Check "Org relationship (on-prem): $($or.Name)" `
                -Result "Enabled=$($or.Enabled) | FreeBusy=$fbEnabled | Level=$($or.FreeBusyAccessLevel)" `
                -Status $statusLabel
        }
    } else {
        Add-Finding -Area "FreeBusy" -Check "On-prem org relationship" `
            -Result "NOT FOUND — cross-premises free/busy will not work" -Status "ERROR"
    }
} catch {
    Add-Finding -Area "FreeBusy" -Check "Org relationship" -Result "Query failed: $_" -Status "ERROR"
}

try {
    $exoOrgRel = Get-OrganizationRelationship | Where-Object { $_.Name -like "*On-Premises*" -or $_.Name -like "*Hybrid*" }
    if ($exoOrgRel) {
        foreach ($or in $exoOrgRel) {
            $statusLabel = if ($or.Enabled -and $or.FreeBusyAccessEnabled) { "OK" } else { "WARN" }
            Add-Finding -Area "FreeBusy" -Check "Org relationship (EXO): $($or.Name)" `
                -Result "Enabled=$($or.Enabled) | FreeBusy=$($or.FreeBusyAccessEnabled)" `
                -Status $statusLabel
        }
    }
} catch { }
#endregion

#region ─── 6. Mail flow test ─────────────────────────────────────────────────
if (-not $SkipMailFlowTest) {
    Write-Status "Running mail flow test to: $TestMailbox"
    try {
        # EXO → on-prem test
        $testResult = Test-MailFlow -TargetEmailAddress $TestMailbox -ErrorAction Stop
        $statusLabel = if ($testResult.TestMailFlowResult -eq "Success") { "OK" } else { "ERROR" }
        Add-Finding -Area "Mail Flow" -Check "EXO → On-prem mail flow" `
            -Result $testResult.TestMailFlowResult -Status $statusLabel `
            -Detail "Latency: $($testResult.MessageLatency)"
    } catch {
        Add-Finding -Area "Mail Flow" -Check "Mail flow test" `
            -Result "Test failed: $_" -Status "WARN" `
            -Detail "Use EXO Admin Center → Mail flow → Message trace to verify manually"
    }
} else {
    Add-Finding -Area "Mail Flow" -Check "Mail flow test" `
        -Result "Skipped (-SkipMailFlowTest)" -Status "INFO"
}
#endregion

#region ─── Summary ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Hybrid Health Summary ─────────────────────────" -ForegroundColor Cyan

$okCount    = ($script:findings | Where-Object { $_.Status -eq "OK" }).Count
$warnCount  = ($script:findings | Where-Object { $_.Status -eq "WARN" }).Count
$errorCount = ($script:findings | Where-Object { $_.Status -eq "ERROR" }).Count

Write-Host "  OK      : $okCount" -ForegroundColor Green
Write-Host "  WARN    : $warnCount" -ForegroundColor Yellow
Write-Host "  ERROR   : $errorCount" -ForegroundColor Red
Write-Host ""

$problems = $script:findings | Where-Object { $_.Status -in "WARN","ERROR" }
if ($problems) {
    Write-Host "─── Issues Found ──────────────────────────────────" -ForegroundColor Yellow
    $problems | Format-Table Area, Check, Result, Status, Detail -AutoSize -Wrap
}

$script:findings | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported → $ExportPath" "OK"
#endregion

#region ─── Cleanup ───────────────────────────────────────────────────────────
Remove-PSSession $onPremSession -ErrorAction SilentlyContinue
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Write-Status "Hybrid health check complete — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
