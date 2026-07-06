<#
.SYNOPSIS
    Collects Windows DNS client resolution health — server config, cache state, NRPT, DoH, and HOSTS file — for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/DNS-Client-B.md and DNS-Client-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - DNS Client (Dnscache) service state
    - Configured DNS servers per active interface (flags public resolvers on domain-joined machines)
    - DNS server reachability on TCP 53
    - DNS suffix search list / connection-specific suffix
    - NRPT rules (VPN/DirectAccess split-DNS routing)
    - DoH server list (flags internal-looking IPs configured for DoH)
    - HOSTS file contents (flags non-loopback entries)
    - DNS cache snapshot, with NXDOMAIN entries called out
    - Optional resolution test against a list of names (public + internal)

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - DNS server-side administration (zones, replication) — client-side only
    - Fixing NRPT/suffix issues (that's DNS-Client-B.md Fix 1-5 / DNS-Client-A.md Playbooks 1-4 — this script only detects)
    - Third-party VPN client DNS push configuration — informational only

.PARAMETER TestNames
    Array of names to test resolution against. Default includes a public name and placeholders for internal names.

.PARAMETER DnsServerPort
    Port to test DNS server reachability on. Default 53.

.PARAMETER ExportPath
    Path for CSV export. Default: .\DNSClientDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-DNSClientDiagnostics.ps1
    Runs the full triage sweep with default test names.

.EXAMPLE
    .\Get-DNSClientDiagnostics.ps1 -TestNames "google.com","intranet.corp.local","server01"
    Runs the sweep and tests resolution against a specific set of internal/external names.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended (HOSTS file and some registry reads need elevation on hardened systems)
    Safe: Fully read-only. No cache flush, no config changes.
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2016+
#>

[CmdletBinding()]
param(
    [string[]]$TestNames = @('google.com', '<internal-name-1>', '<internal-name-2>'),

    [int]$DnsServerPort = 53,

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
Write-Status "Get-DNSClientDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\DNSClientDiagnostics-$timestamp.csv"
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

$isDomainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
#endregion

#region ─── 1. Dnscache service ─────────────────────────────────────────────────
try {
    $svc = Get-Service -Name Dnscache -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Add-Result "DnscacheService" "OK" "Running (StartType: $($svc.StartType))"
    } else {
        Add-Result "DnscacheService" "ERROR" "Status: $($svc.Status) — no DNS caching; resolution may still work but slower/uncached"
    }
} catch {
    Add-Result "DnscacheService" "ERROR" "Could not query Dnscache service: $_"
}
#endregion

#region ─── 2. DNS server assignment per active interface ─────────────────────
$publicResolvers = @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '208.67.222.222', '208.67.220.220')

try {
    $dnsConfigs = Get-DnsClientServerAddress -ErrorAction Stop | Where-Object { $_.AddressFamily -eq 2 -and $_.ServerAddresses.Count -gt 0 }
    if ($dnsConfigs) {
        foreach ($cfg in $dnsConfigs) {
            $servers = $cfg.ServerAddresses -join ', '
            $usesPublic = $cfg.ServerAddresses | Where-Object { $_ -in $publicResolvers }
            if ($isDomainJoined -and $usesPublic) {
                Add-Result "DNSServers-$($cfg.InterfaceAlias)" "WARN" "Servers: $servers — public resolver in use on domain-joined machine; internal names will likely fail"
            } else {
                Add-Result "DNSServers-$($cfg.InterfaceAlias)" "OK" "Servers: $servers"
            }
        }
    } else {
        Add-Result "DNSServers" "ERROR" "No IPv4 DNS servers configured on any interface"
    }
} catch {
    Add-Result "DNSServers" "ERROR" "Could not query DNS server addresses: $_"
}
#endregion

#region ─── 3. DNS server reachability (TCP 53) ────────────────────────────────
try {
    $primaryServer = ($dnsConfigs | Select-Object -First 1).ServerAddresses | Select-Object -First 1
    if ($primaryServer) {
        $test = Test-NetConnection -ComputerName $primaryServer -Port $DnsServerPort -WarningAction SilentlyContinue -ErrorAction Stop
        if ($test.TcpTestSucceeded) {
            Add-Result "DNSServerReachability" "OK" "$primaryServer reachable on TCP $DnsServerPort"
        } else {
            Add-Result "DNSServerReachability" "ERROR" "$primaryServer NOT reachable on TCP $DnsServerPort — firewall/routing issue, not a client config issue"
        }
    } else {
        Add-Result "DNSServerReachability" "WARN" "No primary DNS server to test"
    }
} catch {
    Add-Result "DNSServerReachability" "WARN" "Could not test DNS server reachability: $_"
}
#endregion

#region ─── 4. DNS suffix search list ───────────────────────────────────────────
try {
    $suffixInfo = Get-DnsClient -ErrorAction Stop | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" }
    $globalSuffix = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -ErrorAction SilentlyContinue).SearchList

    if ($globalSuffix) {
        Add-Result "DNSSuffixSearchList" "OK" "Global search list: $globalSuffix"
    } elseif ($isDomainJoined) {
        Add-Result "DNSSuffixSearchList" "WARN" "No global suffix search list configured on a domain-joined machine — short internal names may fail to resolve"
    } else {
        Add-Result "DNSSuffixSearchList" "INFO" "No global suffix search list (expected on non-domain-joined device)"
    }

    foreach ($iface in $suffixInfo) {
        if ($iface.ConnectionSpecificSuffix) {
            Add-Result "ConnSpecificSuffix-$($iface.InterfaceAlias)" "OK" "$($iface.ConnectionSpecificSuffix)"
        }
    }
} catch {
    Add-Result "DNSSuffixSearchList" "WARN" "Could not query DNS suffix info: $_"
}
#endregion

#region ─── 5. NRPT rules (VPN / DirectAccess / split-DNS) ─────────────────────
try {
    $nrpt = Get-DnsClientNrptRule -ErrorAction Stop
    if ($nrpt -and $nrpt.Count -gt 0) {
        foreach ($rule in $nrpt) {
            Add-Result "NRPT-$($rule.Namespace)" "OK" "Routes to: $($rule.NameServers -join ', ')"
        }
    } else {
        Add-Result "NRPT" "INFO" "No NRPT rules configured — expected unless using VPN/DirectAccess split-DNS"
    }
} catch {
    Add-Result "NRPT" "WARN" "Could not query NRPT rules: $_"
}
#endregion

#region ─── 6. DoH server list — flag internal-looking IPs ─────────────────────
try {
    $doh = Get-DnsClientDohServerAddress -ErrorAction Stop
    if ($doh -and $doh.Count -gt 0) {
        foreach ($entry in $doh) {
            $isPrivateRange = $entry.ServerAddress -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'
            if ($isPrivateRange) {
                Add-Result "DoH-$($entry.ServerAddress)" "WARN" "Private/internal-range IP configured for DoH — internal DCs rarely support DoH; this can break internal resolution"
            } else {
                Add-Result "DoH-$($entry.ServerAddress)" "INFO" "DoH configured (public resolver — normal)"
            }
        }
    } else {
        Add-Result "DoH" "INFO" "No DoH servers configured"
    }
} catch {
    Add-Result "DoH" "INFO" "DoH cmdlet not available on this OS build (requires Windows 11 / Server 2022+)"
}
#endregion

#region ─── 7. HOSTS file — flag non-loopback entries ──────────────────────────
try {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsLines = Get-Content $hostsPath -ErrorAction Stop | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\s*#' }
    $suspicious = $hostsLines | Where-Object { $_ -notmatch '127\.0\.0\.1|::1' }

    if ($suspicious) {
        Add-Result "HostsFile" "WARN" "$($suspicious.Count) non-loopback entr(ies) found — HOSTS overrides DNS; review for stale/incorrect entries: $($suspicious -join ' | ')"
    } else {
        Add-Result "HostsFile" "OK" "Only standard loopback entries present"
    }
} catch {
    Add-Result "HostsFile" "WARN" "Could not read HOSTS file: $_"
}
#endregion

#region ─── 8. DNS cache snapshot — flag NXDOMAIN entries ──────────────────────
try {
    $cache = Get-DnsClientCache -ErrorAction Stop
    $nxCount = ($cache | Where-Object { $_.Status -ne 0 -and $_.Status -ne 'Success' }).Count
    if ($nxCount -gt 0) {
        Add-Result "DNSCache" "WARN" "$nxCount cached entr(ies) with non-Success status (possible stale NXDOMAIN) out of $($cache.Count) total"
    } else {
        Add-Result "DNSCache" "OK" "$($cache.Count) cache entries, none with error status"
    }
} catch {
    Add-Result "DNSCache" "INFO" "Could not read DNS cache (may be empty): $_"
}
#endregion

#region ─── 9. Resolution tests ─────────────────────────────────────────────────
$resolutionResults = foreach ($name in $TestNames) {
    if ($name -like '<*>') { continue }
    try {
        $r = Resolve-DnsName $name -ErrorAction Stop | Select-Object -First 1
        Add-Result "Resolve-$name" "OK" "Resolved to $($r.IPAddress)"
        [PSCustomObject]@{ Name = $name; Status = 'Resolved'; IP = $r.IPAddress }
    } catch {
        Add-Result "Resolve-$name" "ERROR" "Failed: $($_.Exception.Message)"
        [PSCustomObject]@{ Name = $name; Status = 'Failed'; IP = $_.Exception.Message }
    }
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── DNS Client Diagnostics Summary ─────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: DNS client configuration looks healthy on this device." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see DNS-Client-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
