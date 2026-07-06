<#
.SYNOPSIS
    Runs a full client-side DHCP diagnostic pass and produces a triage report.

.DESCRIPTION
    Collects adapter DHCP state, current lease details, recent DHCP-Client and
    duplicate-IP events, and (optionally) times a release/renew cycle to help
    distinguish "no server responded" (APIPA) failures from "wrong scope
    options" or "conflict/decline" failures. Designed as the first thing to
    run on a "no network / bad IP" ticket before escalating to the DHCP
    server or network team.

    Covers:
    - Adapter link state and DHCP-enabled status per interface
    - Current IP, gateway, DNS, lease obtained/expiry
    - APIPA detection (169.254.0.0/16)
    - Recent Dhcp-Client provider events (last 24h)
    - Duplicate IP / conflict events (Event ID 1002, 4199 — last 7 days)
    - Optional timed release/renew test (-TestRenew)
    - Exports a CSV summary plus raw evidence files, suitable for attaching to a ticket

    Does NOT cover:
    - Server-side DHCP scope/option administration (requires DhcpServer module
      on the DHCP server itself — see DHCP-Client-A.md Playbook 2/3)
    - Network-layer relay/IP-helper verification (switch/router config,
      outside Windows client tooling)

.PARAMETER TestRenew
    If specified, performs a timed ipconfig /release + /renew cycle as part
    of the diagnostic. This will briefly interrupt network connectivity.

.PARAMETER OutputPath
    Directory to write the evidence report and CSVs to. Default: .\DHCP-Diagnostics-<timestamp>

.EXAMPLE
    .\Get-DHCPClientDiagnostics.ps1
    Runs a read-only diagnostic pass (no release/renew) and writes a report.

.EXAMPLE
    .\Get-DHCPClientDiagnostics.ps1 -TestRenew
    Runs the full diagnostic including a timed release/renew test.

.NOTES
    Requires: Windows 10/11 or Server 2016+, run as Administrator for full
              event log and service access
    Safe:     Read-only unless -TestRenew is specified. -TestRenew briefly
              drops network connectivity during the release/renew cycle.
#>

[CmdletBinding()]
param(
    [switch]$TestRenew,
    [string]$OutputPath
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
Write-Status "Get-DHCPClientDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $OutputPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $OutputPath = ".\DHCP-Diagnostics-$timestamp"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-Status "Output directory: $OutputPath"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Status "Not running as Administrator — event log and service checks may be incomplete." "WARN"
}
#endregion

#region ─── Adapter & IP config ────────────────────────────────────────────────
Write-Status "Collecting adapter and IP configuration..."

$adapters = Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, InterfaceIndex
$adapters | Export-Csv "$OutputPath\Adapters.csv" -NoTypeInformation

$ipInterfaces = Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias, InterfaceIndex, Dhcp, ConnectionState
$ipInterfaces | Export-Csv "$OutputPath\IPInterfaces.csv" -NoTypeInformation

$ipAddresses = Get-NetIPAddress -AddressFamily IPv4 | Where-Object PrefixOrigin -ne "WellKnown" |
    Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin, SuffixOrigin
$ipAddresses | Export-Csv "$OutputPath\IPAddresses.csv" -NoTypeInformation

ipconfig /all | Out-File "$OutputPath\ipconfig-all.txt"
#endregion

#region ─── APIPA detection ────────────────────────────────────────────────────
$apipaHits = $ipAddresses | Where-Object { $_.IPAddress -like "169.254.*" }
if ($apipaHits) {
    Write-Status "APIPA address detected — no DHCP server responded to discovery:" "ERROR"
    $apipaHits | ForEach-Object { Write-Host "    $($_.InterfaceAlias): $($_.IPAddress)" -ForegroundColor Red }
} else {
    Write-Status "No APIPA addresses found." "OK"
}
#endregion

#region ─── DHCP-enabled check ─────────────────────────────────────────────────
$staticAdapters = $ipInterfaces | Where-Object { $_.Dhcp -eq "Disabled" -and $_.ConnectionState -eq "Connected" }
if ($staticAdapters) {
    Write-Status "Adapter(s) with DHCP disabled (static config):" "WARN"
    $staticAdapters | ForEach-Object { Write-Host "    $($_.InterfaceAlias)" -ForegroundColor Yellow }
} else {
    Write-Status "All connected adapters are DHCP-enabled." "OK"
}
#endregion

#region ─── DHCP-Client events (last 24h) ──────────────────────────────────────
Write-Status "Collecting Dhcp-Client events (last 24h)..."
$dhcpEvents = Get-WinEvent -LogName System -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -eq "Dhcp-Client" -and $_.TimeCreated -gt (Get-Date).AddHours(-24) } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message

if ($dhcpEvents) {
    $dhcpEvents | Export-Csv "$OutputPath\Dhcp-Client-Events.csv" -NoTypeInformation
    $errorEvents = $dhcpEvents | Where-Object LevelDisplayName -in "Error", "Warning"
    if ($errorEvents) {
        Write-Status "Found $($errorEvents.Count) Dhcp-Client warning/error event(s) in last 24h." "WARN"
    } else {
        Write-Status "$($dhcpEvents.Count) Dhcp-Client event(s) found, none error/warning level." "OK"
    }
} else {
    Write-Status "No Dhcp-Client events in the last 24h." "OK"
}
#endregion

#region ─── Conflict / duplicate IP events (last 7 days) ──────────────────────
Write-Status "Checking for duplicate IP / conflict events (last 7 days)..."
$conflictEvents = Get-WinEvent -LogName System -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in 1002, 4199 -and $_.TimeCreated -gt (Get-Date).AddDays(-7) } |
    Select-Object TimeCreated, Id, Message

if ($conflictEvents) {
    $conflictEvents | Export-Csv "$OutputPath\Conflict-Events.csv" -NoTypeInformation
    Write-Status "Found $($conflictEvents.Count) duplicate-IP/conflict event(s) — possible rogue static device or rogue DHCP server." "ERROR"
} else {
    Write-Status "No duplicate IP / conflict events found." "OK"
}
#endregion

#region ─── ARP table (for conflict investigation) ────────────────────────────
arp -a | Out-File "$OutputPath\arp-table.txt"
#endregion

#region ─── Optional timed release/renew ──────────────────────────────────────
if ($TestRenew) {
    Write-Status "Running timed release/renew test (connectivity will briefly drop)..." "WARN"
    $timing = Measure-Command {
        ipconfig /release | Out-Null
        ipconfig /renew   | Out-Null
    }
    $renewReport = "Release/Renew completed in $([math]::Round($timing.TotalSeconds,2)) seconds`r`n`r`n"
    $renewReport += (ipconfig /all | Out-String)
    $renewReport | Out-File "$OutputPath\Release-Renew-Test.txt"

    if ($timing.TotalSeconds -gt 8) {
        Write-Status "Release/renew took $([math]::Round($timing.TotalSeconds,2))s — unusually slow, possible server-side conflict detection or reachability delay." "WARN"
    } else {
        Write-Status "Release/renew completed in $([math]::Round($timing.TotalSeconds,2))s." "OK"
    }

    # Re-check APIPA after renew
    $postRenewIP = Get-NetIPAddress -AddressFamily IPv4 | Where-Object PrefixOrigin -ne "WellKnown"
    if ($postRenewIP.IPAddress -like "169.254.*") {
        Write-Status "Still on APIPA after renew — DHCP server unreachable or not responding." "ERROR"
    }
} else {
    Write-Status "Skipping release/renew test (use -TestRenew to include it)."
}
#endregion

#region ─── Summary ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── DHCP Diagnostic Summary ───────────────────────" -ForegroundColor Cyan
Write-Host "  APIPA detected            : $(if ($apipaHits) {'YES'} else {'No'})" -ForegroundColor $(if ($apipaHits) { "Red" } else { "Green" })
Write-Host "  Static (DHCP-disabled) NICs: $($staticAdapters.Count)" -ForegroundColor $(if ($staticAdapters) { "Yellow" } else { "Green" })
Write-Host "  Dhcp-Client events (24h)  : $($dhcpEvents.Count)"
Write-Host "  Conflict events (7d)      : $($conflictEvents.Count)" -ForegroundColor $(if ($conflictEvents) { "Red" } else { "Green" })
Write-Host ""
Write-Status "Full report written to: $OutputPath" "OK"
#endregion

#region ─── Package for ticket attachment ──────────────────────────────────────
Compress-Archive -Path "$OutputPath\*" -DestinationPath "$OutputPath.zip" -Force
Write-Status "Archive ready for escalation: $OutputPath.zip" "OK"
#endregion
