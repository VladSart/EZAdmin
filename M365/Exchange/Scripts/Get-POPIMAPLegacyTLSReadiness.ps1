<#
.SYNOPSIS
    Read-only readiness check for the Exchange Online POP3/IMAP4 legacy TLS retirement (MC1293480).

.DESCRIPTION
    Two independent halves; run either or both:

    TENANT (requires a connected Exchange Online session; skip with -SkipTenant):
      - AllowLegacyTLSClients (org-wide opt-in to pop-legacy / imap-legacy / smtp-legacy endpoints).
      - Mailboxes with PopEnabled or ImapEnabled = True, and the CAS mailbox plan defaults.
      - Optional -IncludeUsageReport: Graph Email apps usage (D180) rows where POP3/IMAP4 was used
        (requires Connect-MgGraph -Scopes Reports.Read.All).
      - Optional -IncludeSignIns: recent Entra sign-ins with clientAppUsed IMAP4 / POP3
        (requires Connect-MgGraph -Scopes AuditLog.Read.All).

    HOST (runs locally on the machine you execute it on; skip with -SkipHost):
      - TLS 1.0 / 1.1 / 1.2 handshake probe against -ProbeHost on ports 993 (IMAPS) and 995 (POP3S).
        Run it ON the polling server/app host — results from an admin PC prove nothing about the app host.
      - .NET Framework SchUseStrongCrypto / SystemDefaultTlsVersions (64- and 32-bit hives).
      - Schannel TLS 1.2 client registry state and OS version.

    Does NOT change any setting. Does NOT test OAuth/XOAUTH2 authentication (TLS layer only).
    A handshake failure for Tls/Tls11 AFTER your tenant is in the rollout is expected and correct.
    A local failure can also mean the client OS has that protocol disabled — the Detail column
    carries the raw exception text to tell the two apart.

.PARAMETER ProbeHost
    Host to probe. Default outlook.office365.com. Use imap-legacy.office365.com to test the legacy endpoint.

.PARAMETER SkipTenant
    Do not query Exchange Online / Graph (host checks only — useful on app servers without admin modules).

.PARAMETER SkipHost
    Do not run local handshake/registry checks.

.PARAMETER IncludeUsageReport
    Pull the 180-day Email apps usage report via Graph and list POP3/IMAP4 users.

.PARAMETER IncludeSignIns
    Pull up to -SignInTop recent sign-ins with clientAppUsed IMAP4 or POP3.

.PARAMETER SignInTop
    Maximum sign-in records to retrieve. Default 200.

.PARAMETER OutputPath
    CSV path. Default .\POPIMAP-LegacyTLS-Readiness-<timestamp>.csv

.EXAMPLE
    # On the failing app server (no admin modules needed)
    .\Get-POPIMAPLegacyTLSReadiness.ps1 -SkipTenant

.EXAMPLE
    Connect-ExchangeOnline
    Connect-MgGraph -Scopes Reports.Read.All,AuditLog.Read.All
    .\Get-POPIMAPLegacyTLSReadiness.ps1 -SkipHost -IncludeUsageReport -IncludeSignIns

.NOTES
    Requires : Windows PowerShell 5.1 or PowerShell 7 on Windows for host checks (registry).
               ExchangeOnlineManagement v3 for tenant checks; Microsoft.Graph.Reports /
               Microsoft.Graph.Authentication and Microsoft.Graph.Identity.SignIns for the Graph options.
    Roles    : Global Reader / View-Only Organization Management; Reports Reader; Reports/Security Reader for sign-ins.
    Safety   : Read-only. Safe in production. Does not need to run as administrator.
    Related  : M365/Exchange/POPIMAPLegacyTLS-B.md, M365/Exchange/POPIMAPLegacyTLS-A.md
#>
[CmdletBinding()]
param(
    [string]$ProbeHost = 'outlook.office365.com',
    [switch]$SkipTenant,
    [switch]$SkipHost,
    [switch]$IncludeUsageReport,
    [switch]$IncludeSignIns,
    [int]$SignInTop = 200,
    [string]$OutputPath = (Join-Path $PWD ("POPIMAP-LegacyTLS-Readiness-{0}.csv" -f (Get-Date -Format yyyyMMdd-HHmm)))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Area, [string]$Check, [string]$Value, [string]$Status, [string]$Detail = '')
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Value = $Value; Status = $Status; Detail = $Detail })
    Write-Status -Message ("{0} | {1} = {2} {3}" -f $Area, $Check, $Value, $(if ($Detail) { "($Detail)" } else { '' })) -Status $Status
}

function Test-TlsHandshake {
    param([string]$HostName, [int]$Port, [string]$Protocol)
    $tcp = $null; $ssl = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(5000)) { throw "TCP connect timeout (5s)" }
        $tcp.EndConnect($iar)
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false)
        $proto = [System.Security.Authentication.SslProtocols]::$Protocol
        $ssl.AuthenticateAsClient($HostName, $null, $proto, $false)
        return [pscustomobject]@{ Success = $true; Negotiated = [string]$ssl.SslProtocol; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Negotiated = ''; Error = $_.Exception.GetBaseException().Message }
    }
    finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Dispose() }
    }
}

# ---------------- Preflight ----------------
Write-Status "POP3/IMAP4 legacy TLS readiness (MC1293480: rollout 1 Aug - 31 Dec 2026)"
if ($SkipTenant -and $SkipHost) { throw "Both -SkipTenant and -SkipHost specified — nothing to do." }

# ---------------- Tenant ----------------
if (-not $SkipTenant) {
    if (-not (Get-Command Get-TransportConfig -ErrorAction SilentlyContinue)) {
        Write-Status "Get-TransportConfig not available — run Connect-ExchangeOnline first, or use -SkipTenant." "ERROR"
    }
    else {
        $tc = Get-TransportConfig
        if ($tc.AllowLegacyTLSClients) {
            Add-Result 'Tenant' 'AllowLegacyTLSClients' 'True' 'WARN' 'Opted in to *-legacy endpoints; also gates smtp-legacy.office365.com - inventory before disabling'
        } else {
            Add-Result 'Tenant' 'AllowLegacyTLSClients' 'False' 'OK' 'No legacy-endpoint opt-in'
        }

        try {
            $plans = Get-CASMailboxPlan
            foreach ($p in $plans) {
                $st = if ($p.PopEnabled -or $p.ImapEnabled) { 'WARN' } else { 'OK' }
                Add-Result 'Tenant' ("CASMailboxPlan: {0}" -f $p.Name) ("Pop={0};Imap={1}" -f $p.PopEnabled, $p.ImapEnabled) $st 'Default for new mailboxes'
            }
        } catch { Add-Result 'Tenant' 'CASMailboxPlan' 'n/a' 'WARN' $_.Exception.Message }

        Write-Status "Enumerating CAS mailboxes (may take time in large tenants)..."
        $cas = @(Get-EXOCASMailbox -ResultSize Unlimited -PropertySets Minimum,Pop,Imap |
                 Where-Object { $_.PopEnabled -or $_.ImapEnabled })
        $st = if ($cas.Count -gt 0) { 'WARN' } else { 'OK' }
        Add-Result 'Tenant' 'Mailboxes with POP or IMAP enabled' $cas.Count $st 'Enabled != used; see usage report'
        foreach ($m in $cas) {
            $results.Add([pscustomobject]@{ Area = 'Mailbox'; Check = [string]$m.PrimarySmtpAddress
                Value = ("Pop={0};Imap={1}" -f $m.PopEnabled, $m.ImapEnabled); Status = 'INFO'; Detail = '' })
        }

        if ($IncludeUsageReport) {
            if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
                Add-Result 'Usage' 'Email apps usage (D180)' 'n/a' 'ERROR' 'Microsoft.Graph.Authentication not loaded / Connect-MgGraph not run'
            } else {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) ("EmailAppUsage-{0}.csv" -f [guid]::NewGuid())
                try {
                    Invoke-MgGraphRequest -Method GET -OutputFilePath $tmp `
                        -Uri "https://graph.microsoft.com/v1.0/reports/getEmailAppUsageUserDetail(period='D180')"
                    $rows = @(Import-Csv $tmp | Where-Object { $_.'POP3 App' -or $_.'IMAP4 App' })
                    $st = if ($rows.Count -gt 0) { 'WARN' } else { 'OK' }
                    Add-Result 'Usage' 'Users with POP3/IMAP4 activity (180d)' $rows.Count $st 'Report lags ~2 days; UPNs may be concealed'
                    foreach ($r in $rows) {
                        $results.Add([pscustomobject]@{ Area = 'UsageUser'; Check = $r.'User Principal Name'
                            Value = ("POP3={0};IMAP4={1}" -f $r.'POP3 App', $r.'IMAP4 App'); Status = 'INFO'; Detail = ("LastActivity={0}" -f $r.'Last Activity Date') })
                    }
                } catch { Add-Result 'Usage' 'Email apps usage (D180)' 'n/a' 'ERROR' $_.Exception.Message }
                finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
            }
        }

        if ($IncludeSignIns) {
            if (-not (Get-Command Get-MgAuditLogSignIn -ErrorAction SilentlyContinue)) {
                Add-Result 'SignIns' 'IMAP4/POP3 sign-ins' 'n/a' 'ERROR' 'Microsoft.Graph.Reports module not loaded / not connected'
            } else {
                try {
                    $si = @(Get-MgAuditLogSignIn -Filter "clientAppUsed eq 'IMAP4' or clientAppUsed eq 'POP3'" -Top $SignInTop)
                    Add-Result 'SignIns' 'IMAP4/POP3 sign-ins retrieved' $si.Count 'INFO' 'Token requests only - TLS version is NOT logged here'
                    foreach ($s in $si) {
                        $results.Add([pscustomobject]@{ Area = 'SignIn'; Check = [string]$s.UserPrincipalName
                            Value = ("{0};{1};{2}" -f $s.ClientAppUsed, $s.AppDisplayName, $s.IPAddress); Status = 'INFO'
                            Detail = ("{0};Error={1}" -f $s.CreatedDateTime, $s.Status.ErrorCode) })
                    }
                } catch { Add-Result 'SignIns' 'IMAP4/POP3 sign-ins' 'n/a' 'ERROR' $_.Exception.Message }
            }
        }
    }
}

# ---------------- Host ----------------
if (-not $SkipHost) {
    Add-Result 'Host' 'ComputerName' $env:COMPUTERNAME 'INFO'
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Add-Result 'Host' 'OS' ("{0} {1}" -f $os.Caption, $os.BuildNumber) 'INFO'
    } catch { Add-Result 'Host' 'OS' 'n/a' 'WARN' $_.Exception.Message }

    foreach ($port in 993, 995) {
        $tls12Ok = $false
        foreach ($proto in 'Tls', 'Tls11', 'Tls12') {
            $r = Test-TlsHandshake -HostName $ProbeHost -Port $port -Protocol $proto
            if ($proto -eq 'Tls12') {
                $tls12Ok = $r.Success
                $st = if ($r.Success) { 'OK' } else { 'ERROR' }
            } else {
                # Legacy success = still accepted today (tenant not yet reached, or legacy endpoint); failure = expected post-rollout
                $st = if ($r.Success) { 'WARN' } else { 'INFO' }
            }
            $val = if ($r.Success) { "OK ($($r.Negotiated))" } else { 'FAIL' }
            Add-Result 'Handshake' ("{0}:{1} {2}" -f $ProbeHost, $port, $proto) $val $st $r.Error
        }
        if (-not $tls12Ok) { Write-Status "TLS 1.2 failed from this host on port $port - OS/stack problem (see B runbook Fix 4)." "ERROR" }
    }

    $netKeys = @{ '64-bit' = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'
                  '32-bit' = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' }
    foreach ($k in $netKeys.GetEnumerator()) {
        $p = Get-ItemProperty -Path $k.Value -ErrorAction SilentlyContinue
        foreach ($name in 'SchUseStrongCrypto', 'SystemDefaultTlsVersions') {
            $v = $null
            if ($p -and ($p.PSObject.Properties.Name -contains $name)) { $v = $p.$name }
            $st = if ($v -eq 1) { 'OK' } else { 'WARN' }
            $shown = if ($null -eq $v) { '(not set)' } else { [string]$v }
            Add-Result 'DotNet' ("{0} {1}" -f $k.Key, $name) $shown $st 'Should be 1 for .NET 4.x apps to use OS TLS defaults'
        }
    }

    $sch = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -ErrorAction SilentlyContinue
    if (-not $sch) {
        Add-Result 'Schannel' 'TLS 1.2 Client key' '(not present)' 'OK' 'OS default applies (enabled on supported Windows)'
    } else {
        $en  = if ($sch.PSObject.Properties.Name -contains 'Enabled') { $sch.Enabled } else { '(n/a)' }
        $dbd = if ($sch.PSObject.Properties.Name -contains 'DisabledByDefault') { $sch.DisabledByDefault } else { '(n/a)' }
        $st  = if (($en -eq 0) -or ($dbd -eq 1)) { 'ERROR' } else { 'OK' }
        Add-Result 'Schannel' 'TLS 1.2 Client' ("Enabled={0};DisabledByDefault={1}" -f $en, $dbd) $st
    }
}

# ---------------- Report ----------------
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
$warn = @($results | Where-Object { $_.Status -in 'WARN', 'ERROR' }).Count
Write-Status ("Done. {0} rows, {1} WARN/ERROR. CSV: {2}" -f $results.Count, $warn, $OutputPath) $(if ($warn) { 'WARN' } else { 'OK' })
