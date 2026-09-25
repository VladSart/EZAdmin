<#
.SYNOPSIS
    Read-only tenant-wide health audit of Microsoft Tunnel Gateway Sites, Servers and Server configurations.

.DESCRIPTION
    Uses Microsoft Graph (beta) to enumerate every Microsoft Tunnel Site, the servers enrolled into each
    Site, and every Server configuration, then flags common problems:
      - Sites with no enrolled servers
      - Servers whose tunnelServerHealthStatus is not 'healthy'
      - Servers whose last check-in is older than -StaleMinutes (Intune marks > 5 min as unhealthy)
      - Sites with no internal network probe URL (the Internal network accessibility check stays "Unknown")
      - Sites with automatic upgrade disabled, or an upgrade available but not yet applied
      - Server configurations using full tunnel (RoutesInclude = default / empty)
      - Server configurations whose client IP pool overlaps the Docker (172.17.0.0/16) or Podman
        (10.88.0.0/16) default bridge networks

    It does NOT connect to the Linux hosts. Kernel prerequisites (ip_forward / ip_tables / tun), container
    status and TLS certificate details must be checked on each host with mst-cli (see MicrosoftTunnel-B.md).
    The Graph beta property names are read StrictMode-safely: a missing property is reported as empty.

.PARAMETER StaleMinutes
    Check-in age (minutes) above which a server is flagged as stale. Default 15.

.PARAMETER OutputPath
    Folder for the CSV report. Default: current directory.

.EXAMPLE
    .\Get-MicrosoftTunnelHealthAudit.ps1
    Audits all Sites/Servers and writes MicrosoftTunnelAudit_<timestamp>.csv to the current folder.

.EXAMPLE
    .\Get-MicrosoftTunnelHealthAudit.ps1 -StaleMinutes 10 -OutputPath C:\Temp
    Uses a tighter stale-check-in threshold and writes the CSV to C:\Temp.

.NOTES
    Requires : Microsoft.Graph.Authentication module; delegated scope DeviceManagementConfiguration.Read.All
               (account needs Intune "Microsoft Tunnel Gateway - Read" or Intune Administrator).
    Run-as   : Any user; no local admin needed.
    Safety   : Read-only. Makes GET requests only.
    Graph    : beta endpoints /deviceManagement/microsoftTunnelSites, .../microsoftTunnelServers,
               /deviceManagement/microsoftTunnelConfigurations. Beta schemas can change without notice.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 1440)]
    [int]$StaleMinutes = 15,
    [string]$OutputPath = (Get-Location).Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null }
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

function Invoke-GraphPaged {
    param([string]$Uri)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType Hashtable
        $val = Get-Prop $resp 'value'
        if ($val) { foreach ($v in $val) { $items.Add($v) } }
        $next = Get-Prop $resp '@odata.nextLink'
    }
    return ,$items
}

function Test-CidrOverlap {
    param([string]$A, [string]$B)
    try {
        $toRange = {
            param($cidr)
            $parts = $cidr.Split('/')
            $bytes = ([System.Net.IPAddress]::Parse($parts[0])).GetAddressBytes()
            [Array]::Reverse($bytes)
            $ip = [uint64][BitConverter]::ToUInt32($bytes, 0)
            $bits = [int]$parts[1]
            # Block size avoids 0xFFFFFFFF literals (which PowerShell parses as Int32 -1)
            $size = [uint64][math]::Pow(2, 32 - $bits)
            $start = $ip - ($ip % $size)
            $end = $start + $size - 1
            @($start, $end)
        }
        $ra = & $toRange $A; $rb = & $toRange $B
        return ($ra[0] -le $rb[1] -and $rb[0] -le $ra[1])
    } catch { return $false }
}

# ---------- Preflight ----------
Write-Status "Preflight: checking Microsoft.Graph.Authentication"
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "ERROR"
    return
}
Import-Module Microsoft.Graph.Authentication
if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$base = "https://graph.microsoft.com/beta/deviceManagement"
$now = (Get-Date).ToUniversalTime()
$results = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param([string]$Type, [string]$Name, [string]$Site, [string]$Severity, [string]$Finding, [string]$Detail)
    $results.Add([pscustomobject]@{
        ObjectType = $Type; Name = $Name; Site = $Site; Severity = $Severity; Finding = $Finding; Detail = $Detail
    })
}

# ---------- Detect ----------
Write-Status "Detect: reading Microsoft Tunnel Sites"
try {
    $sites = Invoke-GraphPaged "$base/microsoftTunnelSites"
} catch {
    Write-Status "Failed to read microsoftTunnelSites: $($_.Exception.Message)" "ERROR"
    return
}
if ($sites.Count -eq 0) {
    Write-Status "No Microsoft Tunnel Sites exist in this tenant. Nothing to audit." "WARN"
    return
}
Write-Status "Found $($sites.Count) site(s)" "OK"

try {
    $configs = Invoke-GraphPaged "$base/microsoftTunnelConfigurations"
} catch {
    Write-Status "Failed to read microsoftTunnelConfigurations: $($_.Exception.Message)" "WARN"
    $configs = @()
}

# ---------- Execute (evaluate) ----------
foreach ($s in $sites) {
    $sName = [string](Get-Prop $s 'displayName')
    $sId = [string](Get-Prop $s 'id')
    $pub = [string](Get-Prop $s 'publicAddress')
    $probe = [string](Get-Prop $s 'internalNetworkProbeUrl')
    $autoUp = Get-Prop $s 'upgradeAutomatically'
    $upAvail = Get-Prop $s 'upgradeAvailable'

    Add-Finding 'Site' $sName $sName 'INFO' 'Site present' "PublicAddress=$pub"
    if ([string]::IsNullOrWhiteSpace($probe)) {
        Add-Finding 'Site' $sName $sName 'WARN' 'No internal network probe URL' 'Internal network accessibility health check will always show Unknown.'
    }
    if ($autoUp -eq $false) {
        Add-Finding 'Site' $sName $sName 'WARN' 'Automatic upgrade disabled' 'Servers can fall 2+ versions behind (out of support). Upgrade manually or enable an upgrade window.'
    }
    if ($upAvail -eq $true) {
        Add-Finding 'Site' $sName $sName 'WARN' 'Upgrade available' 'A newer Tunnel release is available for this Site.'
    }

    try {
        $servers = Invoke-GraphPaged "$base/microsoftTunnelSites/$sId/microsoftTunnelServers"
    } catch {
        Add-Finding 'Site' $sName $sName 'ERROR' 'Could not read servers' $_.Exception.Message
        continue
    }
    if ($servers.Count -eq 0) {
        Add-Finding 'Site' $sName $sName 'ERROR' 'Site has no enrolled servers' 'No server ever completed mstunnel-setup enrollment into this Site.'
        continue
    }
    foreach ($srv in $servers) {
        $n = [string](Get-Prop $srv 'displayName')
        $health = [string](Get-Prop $srv 'tunnelServerHealthStatus')
        $lastRaw = Get-Prop $srv 'lastCheckinDateTime'
        $ageMin = $null
        if ($lastRaw) {
            try { $ageMin = [math]::Round(($now - ([datetime]$lastRaw).ToUniversalTime()).TotalMinutes, 1) } catch { $ageMin = $null }
        }
        $detail = "Health=$health; LastCheckin=$lastRaw; AgeMin=$ageMin"
        if ($health -and $health -ne 'healthy') {
            Add-Finding 'Server' $n $sName 'ERROR' "Health status: $health" $detail
        } elseif ($null -eq $ageMin -or $ageMin -gt $StaleMinutes) {
            Add-Finding 'Server' $n $sName 'WARN' 'Stale or missing check-in' $detail
        } else {
            Add-Finding 'Server' $n $sName 'OK' 'Healthy and checking in' $detail
        }
    }
}

$bridgeNets = @{ 'Docker default bridge' = '172.17.0.0/16'; 'Podman default bridge' = '10.88.0.0/16' }
foreach ($c in $configs) {
    $cName = [string](Get-Prop $c 'displayName')
    $net = [string](Get-Prop $c 'network')
    $inc = @(Get-Prop $c 'routesInclude')
    $dns = @(Get-Prop $c 'dnsServers')
    $port = Get-Prop $c 'listenPort'
    Add-Finding 'Configuration' $cName '' 'INFO' 'Server configuration present' ("Network=$net; Port=$port; DNS=" + ($dns -join ','))
    $incClean = @($inc | Where-Object { $_ })
    if ($incClean.Count -eq 0 -or ($incClean -contains 'default')) {
        Add-Finding 'Configuration' $cName '' 'INFO' 'Full tunnel (RoutesInclude default/empty)' 'All device traffic routes through the gateway; size servers accordingly.'
    }
    if (@($dns | Where-Object { $_ }).Count -eq 0) {
        Add-Finding 'Configuration' $cName '' 'WARN' 'No DNS servers configured' 'Internal name resolution through the tunnel will fail.'
    }
    if ($net -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
        foreach ($k in $bridgeNets.Keys) {
            if (Test-CidrOverlap $net $bridgeNets[$k]) {
                Add-Finding 'Configuration' $cName '' 'WARN' "Client pool overlaps $k" "$net overlaps $($bridgeNets[$k]); verify the host bridge was re-addressed."
            }
        }
    }
}

# ---------- Validate / Report ----------
$errors = @($results | Where-Object Severity -eq 'ERROR').Count
$warns = @($results | Where-Object Severity -eq 'WARN').Count
$results | Where-Object Severity -in 'ERROR', 'WARN' | ForEach-Object {
    Write-Status ("{0} [{1}] {2}: {3}" -f $_.ObjectType, $_.Site, $_.Name, $_.Finding) $_.Severity
}
$csv = Join-Path $OutputPath ("MicrosoftTunnelAudit_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
if ($errors -eq 0 -and $warns -eq 0) { Write-Status "No issues found." "OK" }
Write-Status "Summary: $errors error(s), $warns warning(s). Report: $csv" $(if ($errors) { "ERROR" } elseif ($warns) { "WARN" } else { "OK" })
Write-Status "Next: on each Linux host run 'mst-cli server status', 'sysctl net.ipv4.ip_forward', 'lsmod | grep -E ip_tables|tun'."
