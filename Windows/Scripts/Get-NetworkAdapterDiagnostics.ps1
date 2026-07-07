<#
.SYNOPSIS
    Diagnoses Windows network adapter health — link/driver state, IP config, routing, NDIS bindings,
    NLA profile, and power management — for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/NetworkAdapters-B.md and NetworkAdapters-A.md.
    Walks the dependency stack both runbooks describe (physical/vNIC → driver/NDIS filter bindings →
    IP/DHCP → routing → NLA/network profile → firewall reachability) and flags the exact failure
    signatures those docs call out:
    - Adapter status (Up/Disabled/Not Present) and link speed
    - APIPA (169.254.x.x) addressing — DHCP failure signature
    - Orphaned third-party NDIS filter driver bindings (stale VPN/AV client remnants)
    - Competing default routes (VPN split-tunnel misconfiguration eating all traffic)
    - Default gateway reachability
    - DNS resolution (external + optional internal name)
    - NLA / network profile mismatch (Public profile on a domain-joined machine)
    - NIC power management settings (aggressive power-save on servers)
    - Recent NDIS/TCPIP/DHCP-related System event log errors

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into NetworkAdapters-B.md's Escalation Evidence template.

    Does NOT cover:
    - Actual remediation (that's NetworkAdapters-B.md Fix 1-5 / NetworkAdapters-A.md Playbooks 1-5 —
      this script only detects and reports)
    - Switch/VLAN-side configuration — client-side only
    - Wi-Fi RF/channel analysis — adapter and driver state only

.PARAMETER InternalTestName
    An internal hostname to resolve as a second DNS test (in addition to a public name).
    Skipped if left as the placeholder default.

.PARAMETER GatewayTimeoutMs
    Timeout in milliseconds for the gateway reachability test. Default 2000.

.PARAMETER EventLogHours
    How many hours back to scan the System log for NDIS/TCPIP/DHCP errors. Default 24.

.PARAMETER ExportPath
    Path for CSV export. Default: .\NetworkAdapterDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-NetworkAdapterDiagnostics.ps1
    Runs the full triage sweep with default settings.

.EXAMPLE
    .\Get-NetworkAdapterDiagnostics.ps1 -InternalTestName "dc01.contoso.com" -EventLogHours 48
    Runs the sweep, also tests internal DNS resolution, and scans 48h of event log history.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended (NDIS binding and some driver detail needs elevation)
    Safe: Fully read-only. No adapter state changes, no stack resets.
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2019/2022
#>

[CmdletBinding()]
param(
    [string]$InternalTestName = '<internal-name>',

    [int]$GatewayTimeoutMs = 2000,

    [int]$EventLogHours = 24,

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
Write-Status "Get-NetworkAdapterDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\NetworkAdapterDiagnostics-$timestamp.csv"
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

#region ─── 1. Adapter status, link speed, driver ──────────────────────────────
try {
    $adapters = Get-NetAdapter -ErrorAction Stop
    if (-not $adapters) {
        Add-Result "Adapters" "ERROR" "No adapters returned by Get-NetAdapter"
    } else {
        foreach ($a in $adapters) {
            $detail = "Status=$($a.Status), LinkSpeed=$($a.LinkSpeed), Driver=$($a.DriverVersion) ($($a.DriverDate))"
            switch ($a.Status) {
                'Up'          { Add-Result "Adapter-$($a.Name)" "OK" $detail }
                'Disabled'    { Add-Result "Adapter-$($a.Name)" "WARN" "$detail — manually or policy disabled" }
                'Not Present' { Add-Result "Adapter-$($a.Name)" "ERROR" "$detail — driver missing or hardware fault" }
                default       { Add-Result "Adapter-$($a.Name)" "WARN" $detail }
            }
            if ($a.Status -eq 'Up' -and $a.LinkSpeed -match '^0 ') {
                Add-Result "Adapter-$($a.Name)-LinkSpeed" "ERROR" "Status Up but LinkSpeed reports 0 — driver crash or NIC failure signature"
            }
        }
    }
} catch {
    Add-Result "Adapters" "ERROR" "Could not query Get-NetAdapter: $_"
}
#endregion

#region ─── 2. IP configuration — flag APIPA ───────────────────────────────────
try {
    $ipConfigs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" }
    if (-not $ipConfigs) {
        Add-Result "IPConfig" "ERROR" "No IPv4 addresses assigned on any non-loopback interface"
    } else {
        foreach ($ip in $ipConfigs) {
            if ($ip.IPAddress -match '^169\.254\.') {
                Add-Result "IPConfig-$($ip.InterfaceAlias)" "ERROR" "$($ip.IPAddress) — APIPA address, DHCP failure (DORA did not complete)"
            } else {
                Add-Result "IPConfig-$($ip.InterfaceAlias)" "OK" "$($ip.IPAddress)/$($ip.PrefixLength) (Origin: $($ip.PrefixOrigin))"
            }
        }
    }
} catch {
    Add-Result "IPConfig" "ERROR" "Could not query Get-NetIPAddress: $_"
}
#endregion

#region ─── 3. Default gateway + competing routes ──────────────────────────────
try {
    $defaultRoutes = Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
        Sort-Object RouteMetric

    if (-not $defaultRoutes) {
        Add-Result "DefaultRoute" "ERROR" "No default route (0.0.0.0/0) present — no internet/off-subnet connectivity possible"
    } elseif ($defaultRoutes.Count -gt 1) {
        $summary = ($defaultRoutes | ForEach-Object { "$($_.InterfaceAlias)(metric $($_.RouteMetric))" }) -join ', '
        Add-Result "DefaultRoute" "WARN" "Multiple default routes present: $summary — check for VPN split-tunnel route conflict (NetworkAdapters-B.md Fix 4)"
    } else {
        Add-Result "DefaultRoute" "OK" "$($defaultRoutes[0].InterfaceAlias) via $($defaultRoutes[0].NextHop) (metric $($defaultRoutes[0].RouteMetric))"
    }

    $gw = ($defaultRoutes | Select-Object -First 1).NextHop
    if ($gw -and $gw -ne '0.0.0.0') {
        $ping = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($ping) {
            Add-Result "GatewayReachability" "OK" "$gw responds to ICMP"
        } else {
            Add-Result "GatewayReachability" "ERROR" "$gw does NOT respond to ICMP — problem is between NIC and upstream switch/router, not Windows config"
        }
    } else {
        Add-Result "GatewayReachability" "WARN" "No usable gateway to test"
    }
} catch {
    Add-Result "DefaultRoute" "ERROR" "Could not query Get-NetRoute: $_"
}
#endregion

#region ─── 4. NDIS filter bindings — flag orphaned third-party bindings ───────
try {
    $bindings = Get-NetAdapterBinding -ErrorAction Stop | Where-Object { $_.Enabled -eq $true }
    $orphans  = $bindings | Where-Object { $_.ComponentID -notmatch '^ms_' }
    if ($orphans) {
        foreach ($o in $orphans) {
            Add-Result "NDISBinding-$($o.Name)-$($o.ComponentID)" "WARN" "Third-party binding enabled — confirm owning service/app still exists; orphaned bindings from uninstalled VPN/AV clients stall traffic"
        }
    } else {
        Add-Result "NDISBindings" "OK" "Only standard Microsoft bindings enabled — no orphan risk detected"
    }
} catch {
    Add-Result "NDISBindings" "WARN" "Could not query Get-NetAdapterBinding: $_"
}
#endregion

#region ─── 5. NLA / network profile ───────────────────────────────────────────
try {
    $profiles = Get-NetConnectionProfile -ErrorAction Stop
    foreach ($p in $profiles) {
        if ($isDomainJoined -and $p.NetworkCategory -eq 'Public') {
            Add-Result "NetProfile-$($p.InterfaceAlias)" "ERROR" "NetworkCategory=Public on a domain-joined machine — NLA failed to detect domain; SMB/WMI/RPC will be blocked by firewall profile"
        } elseif ($isDomainJoined -and $p.NetworkCategory -ne 'DomainAuthenticated') {
            Add-Result "NetProfile-$($p.InterfaceAlias)" "WARN" "NetworkCategory=$($p.NetworkCategory) on domain-joined machine (expected DomainAuthenticated)"
        } else {
            Add-Result "NetProfile-$($p.InterfaceAlias)" "OK" "NetworkCategory=$($p.NetworkCategory)"
        }
    }
} catch {
    Add-Result "NetProfile" "WARN" "Could not query Get-NetConnectionProfile: $_"
}
#endregion

#region ─── 6. DNS resolution ───────────────────────────────────────────────────
try {
    $r = Resolve-DnsName -Name "google.com" -ErrorAction Stop | Select-Object -First 1
    Add-Result "DNSResolve-External" "OK" "google.com -> $($r.IPAddress)"
} catch {
    Add-Result "DNSResolve-External" "ERROR" "Could not resolve google.com: $($_.Exception.Message)"
}

if ($InternalTestName -notlike '<*>') {
    try {
        $ri = Resolve-DnsName -Name $InternalTestName -ErrorAction Stop | Select-Object -First 1
        Add-Result "DNSResolve-Internal" "OK" "$InternalTestName -> $($ri.IPAddress)"
    } catch {
        Add-Result "DNSResolve-Internal" "ERROR" "Could not resolve $InternalTestName -- split DNS / NRPT rule issue possible: $($_.Exception.Message)"
    }
}
#endregion

#region ─── 7. Power management (Wi-Fi / laptops) ──────────────────────────────
try {
    $pm = Get-NetAdapterPowerManagement -ErrorAction Stop
    foreach ($p in $pm) {
        if ($p.AllowComputerToTurnOffDevice -eq 'Enabled') {
            Add-Result "PowerMgmt-$($p.Name)" "WARN" "AllowComputerToTurnOffDevice=Enabled — can cause adapter drop after idle; disable if intermittent disconnects reported"
        } else {
            Add-Result "PowerMgmt-$($p.Name)" "OK" "AllowComputerToTurnOffDevice=$($p.AllowComputerToTurnOffDevice)"
        }
    }
} catch {
    Add-Result "PowerMgmt" "INFO" "Could not query Get-NetAdapterPowerManagement (not supported on this adapter type): $_"
}
#endregion

#region ─── 8. Recent NDIS/TCPIP/DHCP event log errors ─────────────────────────
try {
    $since  = (Get-Date).AddHours(-$EventLogHours)
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'NDIS|tcpip|Dhcp-Client|NlaSvc|netprofm' -and $_.LevelDisplayName -in @('Error','Warning','Critical') }

    if ($events) {
        $topIds = ($events | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 |
            ForEach-Object { "ID $($_.Name) x$($_.Count)" }) -join ', '
        Add-Result "EventLogScan" "WARN" "$($events.Count) network-related error/warning event(s) in last ${EventLogHours}h — top: $topIds"
    } else {
        Add-Result "EventLogScan" "OK" "No NDIS/TCPIP/DHCP/NLA error or warning events in last ${EventLogHours}h"
    }
} catch {
    Add-Result "EventLogScan" "WARN" "Could not query System event log: $_"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Network Adapter Diagnostics Summary ────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Network adapter configuration looks healthy on this device." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see NetworkAdapters-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
