<#
.SYNOPSIS
    Collects Kerberos authentication health data from a client for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/Kerberos-B.md and Kerberos-A.md.
    Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
    - Current Kerberos ticket cache (klist)
    - Time sync status and skew vs. domain
    - DNS resolution of the domain and _kerberos._tcp SRV records
    - Secure channel health (nltest /sc_verify)
    - Recent Kerberos/NTLM related Security event log entries (4768/4769/4771/4776/4625)
    - SPN lookups for a supplied service name (optional)

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Repairing secure channel or purging tickets (that's Kerberos-B.md Fix 1 / Fix 4)
    - Server-side DC health (run on a DC separately if the issue is DC-wide)
    - Cross-forest/cross-realm trust validation

.PARAMETER DomainName
    FQDN of the domain to check (e.g. contoso.com). Required.

.PARAMETER ServiceName
    Optional service class/hostname to check SPN registration for (e.g. HTTP/app01).
    If omitted, SPN checks are skipped.

.PARAMETER EventLookbackMinutes
    How far back to search the Security event log for auth-related events. Default: 60.

.PARAMETER ExportPath
    Path for CSV export. Default: .\KerberosDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-KerberosDiagnostics.ps1 -DomainName contoso.com
    Runs the full triage sweep against contoso.com from the local machine.

.EXAMPLE
    .\Get-KerberosDiagnostics.ps1 -DomainName contoso.com -ServiceName "HTTP/app01" -EventLookbackMinutes 240
    Also checks SPN registration for HTTP/app01 and widens the event log search to 4 hours.

.NOTES
    Requires: Windows PowerShell 5.1+; RSAT (setspn) only needed if -ServiceName is used
    Run-as: Administrator (required to read the Security event log)
    Safe: Read-only — makes no changes to tickets, secure channel, or SPNs
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2019/2022
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [string]$ServiceName,

    [int]$EventLookbackMinutes = 60,

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

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Get-KerberosDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\KerberosDiagnostics-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "$Check — $Detail" $Status
}
#endregion

#region ─── 1. Ticket cache ────────────────────────────────────────────────────
try {
    $klistOutput = klist 2>&1 | Out-String
    if ($klistOutput -match 'krbtgt') {
        Add-Result "TicketCache" "OK" "TGT present in cache"
    } elseif ($klistOutput -match 'Cached Tickets: \(0\)' -or $klistOutput -match 'No tickets') {
        Add-Result "TicketCache" "ERROR" "No tickets cached — user has no TGT"
    } else {
        Add-Result "TicketCache" "WARN" "Tickets present but no krbtgt entry found — review manually"
    }
} catch {
    Add-Result "TicketCache" "ERROR" "klist failed: $_"
}
#endregion

#region ─── 2. Time sync ───────────────────────────────────────────────────────
try {
    $w32tm = w32tm /query /status 2>&1 | Out-String
    if ($w32tm -match 'Source:\s*(.+)') {
        $source = $Matches[1].Trim()
        Add-Result "TimeSource" "OK" "Syncing from: $source"
    } else {
        Add-Result "TimeSource" "WARN" "Could not determine time source"
    }

    # Compare local time to domain time via net time (best-effort; requires domain reachability)
    $netTime = net time "\\$DomainName" 2>&1 | Out-String
    if ($netTime -match 'Current time at') {
        Add-Result "DomainTimeQuery" "OK" ($netTime.Trim() -replace '\r?\n', ' | ')
    } else {
        Add-Result "DomainTimeQuery" "WARN" "Could not query domain time directly — check via w32tm skew instead"
    }
} catch {
    Add-Result "TimeSync" "ERROR" "Time sync check failed: $_"
}
#endregion

#region ─── 3. DNS resolution ──────────────────────────────────────────────────
try {
    $domainA = Resolve-DnsName -Name $DomainName -Type A -ErrorAction Stop
    Add-Result "DNS-DomainA" "OK" "Resolved $($domainA.Count) A record(s) for $DomainName"
} catch {
    Add-Result "DNS-DomainA" "ERROR" "Failed to resolve $DomainName : $_"
}

try {
    $srv = Resolve-DnsName -Name "_kerberos._tcp.$DomainName" -Type SRV -ErrorAction Stop
    Add-Result "DNS-KerberosSRV" "OK" "Found $($srv.Count) KDC SRV record(s)"
} catch {
    Add-Result "DNS-KerberosSRV" "ERROR" "No _kerberos._tcp SRV records found — clients cannot locate a KDC: $_"
}
#endregion

#region ─── 4. Secure channel ──────────────────────────────────────────────────
try {
    $scVerify = nltest /sc_verify:$DomainName 2>&1 | Out-String
    if ($scVerify -match 'NERR_Success' -or $scVerify -match 'ERROR_SUCCESS') {
        Add-Result "SecureChannel" "OK" "Secure channel verified successfully"
    } else {
        $firstLine = ($scVerify -split '\r?\n' | Select-Object -First 3) -join ' | '
        Add-Result "SecureChannel" "ERROR" "Secure channel verify failed: $firstLine"
    }
} catch {
    Add-Result "SecureChannel" "ERROR" "nltest failed: $_"
}
#endregion

#region ─── 5. SPN check (optional) ────────────────────────────────────────────
if ($ServiceName) {
    try {
        $spnOutput = setspn -Q $ServiceName 2>&1 | Out-String
        if ($spnOutput -match 'No such SPN found') {
            Add-Result "SPN-$ServiceName" "ERROR" "SPN not registered to any account"
        } elseif ($spnOutput -match 'Existing SPN found' -or $spnOutput -match 'CN=') {
            $lines = ($spnOutput -split '\r?\n' | Where-Object { $_ -match 'CN=' }).Count
            if ($lines -gt 1) {
                Add-Result "SPN-$ServiceName" "ERROR" "Duplicate SPN — registered to $lines accounts"
            } else {
                Add-Result "SPN-$ServiceName" "OK" "SPN registered to a single account"
            }
        } else {
            Add-Result "SPN-$ServiceName" "WARN" "Unexpected setspn output — review manually"
        }
    } catch {
        Add-Result "SPN-$ServiceName" "WARN" "setspn not available (RSAT not installed?): $_"
    }
} else {
    Add-Result "SPN-Check" "INFO" "Skipped — no -ServiceName supplied"
}
#endregion

#region ─── 6. Security event log ──────────────────────────────────────────────
try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = "Security"
        Id        = @(4768, 4769, 4771, 4776, 4625)
        StartTime = (Get-Date).AddMinutes(-$EventLookbackMinutes)
    } -ErrorAction Stop

    $failures = $events | Where-Object { $_.Id -in @(4771, 4776, 4625) }
    if ($failures.Count -gt 0) {
        Add-Result "SecurityEvents" "WARN" "$($failures.Count) failure event(s) in last $EventLookbackMinutes min (IDs 4771/4776/4625)"
    } else {
        Add-Result "SecurityEvents" "OK" "No Kerberos/NTLM failure events in last $EventLookbackMinutes min ($($events.Count) total auth events)"
    }
} catch [System.Exception] {
    if ($_.Exception.Message -match 'No events were found') {
        Add-Result "SecurityEvents" "OK" "No matching events in last $EventLookbackMinutes min"
    } else {
        Add-Result "SecurityEvents" "WARN" "Could not query Security log (run as Administrator?): $_"
    }
}
#endregion

#region ─── Summary ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Kerberos Diagnostics Summary ──────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Kerberos looks healthy on this client." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see Kerberos-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
