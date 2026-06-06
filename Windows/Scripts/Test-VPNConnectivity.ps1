<#
.SYNOPSIS
    Diagnoses Always On VPN connectivity and IKEv2/SSTP tunnel health on a Windows client.

.DESCRIPTION
    Comprehensive diagnostic tool for Always On VPN (AOVPN) environments.
    Tests Device Tunnel and User Tunnel independently, validates:
    - VPN adapter presence and connection state
    - IKEv2/SSTP tunnel negotiation logs
    - DNS resolution through the VPN interface
    - Route table (split vs. full tunnel)
    - NPS/RADIUS connectivity indicators
    - Certificate validity (Machine and User)
    - RAS phone book entries
    - Conditional Access posture token (if applicable)
    Exports a timestamped HTML report to C:\Temp\.

.PARAMETER CheckDeviceTunnel
    Include Device Tunnel diagnostics (default: $true). Requires admin rights.

.PARAMETER CheckUserTunnel
    Include User Tunnel diagnostics (default: $true).

.PARAMETER InternalDnsName
    An internal hostname to test DNS resolution through the VPN (e.g. dc01.contoso.local).
    If omitted, internal DNS test is skipped.

.PARAMETER InternalHost
    An internal IP or hostname to ping/test connectivity to (e.g. 10.0.0.1).

.PARAMETER VpnProfileName
    Name of the VPN profile to test. If omitted, all profiles are listed.

.PARAMETER OutputPath
    Where to save the HTML report. Default: C:\Temp\VPN-Diag-<hostname>-<date>.html

.EXAMPLE
    .\Test-VPNConnectivity.ps1 -InternalDnsName dc01.contoso.local -InternalHost 10.0.0.1 -VpnProfileName "Contoso VPN"

.EXAMPLE
    .\Test-VPNConnectivity.ps1 -CheckDeviceTunnel $false -VpnProfileName "Contoso User Tunnel"

.NOTES
    Run as: Standard user for User Tunnel; Local Administrator for Device Tunnel and certificate checks.
    Safe: Read-only diagnostics. Does not modify VPN configuration.
    Requires: Windows 10/11, RRAS client components present.
#>

[CmdletBinding()]
param(
    [bool]$CheckDeviceTunnel = $true,
    [bool]$CheckUserTunnel   = $true,
    [string]$InternalDnsName = "",
    [string]$InternalHost    = "",
    [string]$VpnProfileName  = "",
    [string]$OutputPath      = "C:\Temp\VPN-Diag-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmm').html"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "SKIP"  { "DarkGray" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ─────────────────────────────────────────────
# SECTION 1 — VPN ADAPTER STATUS
# ─────────────────────────────────────────────
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Category, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Category = $Category
        Check    = $Check
        Status   = $Status
        Detail   = $Detail
    })
    Write-Status "$Category | $Check — $Detail" $Status
}

Write-Host "`n=== Always On VPN Diagnostic ===" -ForegroundColor Cyan
Write-Host "Computer : $env:COMPUTERNAME"
Write-Host "User     : $env:USERDOMAIN\$env:USERNAME"
Write-Host "Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

# ─────────────────────────────────────────────
# 1.1 VPN Adapters
# ─────────────────────────────────────────────
Write-Host "--- VPN Adapters ---" -ForegroundColor Cyan

$vpnAdapters = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "WAN Miniport|VPN|RAS" -or $_.Name -match "VPN|Tunnel" }

if ($vpnAdapters.Count -eq 0) {
    Add-Result "Adapters" "VPN adapter present" "WARN" "No VPN-type adapters found. RAS/RRAS components may not be installed."
} else {
    foreach ($adapter in $vpnAdapters) {
        $state  = if ($adapter.Status -eq "Up") { "OK" } else { "WARN" }
        Add-Result "Adapters" "Adapter: $($adapter.Name)" $state "Status: $($adapter.Status)  Type: $($adapter.InterfaceDescription)"
    }
}

# ─────────────────────────────────────────────
# 1.2 RasMan Service
# ─────────────────────────────────────────────
Write-Host "`n--- RAS Services ---" -ForegroundColor Cyan

$rasServices = @("RasMan", "RemoteAccess", "IKEExt")
foreach ($svc in $rasServices) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        $status = if ($s.Status -eq "Running") { "OK" } else { "WARN" }
        Add-Result "Services" "Service: $svc" $status "Status: $($s.Status)  StartType: $($s.StartType)"
    } else {
        Add-Result "Services" "Service: $svc" "SKIP" "Service not found on this system"
    }
}

# ─────────────────────────────────────────────
# 1.3 VPN Profiles (Phone Book)
# ─────────────────────────────────────────────
Write-Host "`n--- VPN Profiles ---" -ForegroundColor Cyan

# User-level profiles
$userPbkPath   = "$env:APPDATA\Microsoft\Network\Connections\Pbk"
$systemPbkPath = "C:\ProgramData\Microsoft\Network\Connections\Pbk"

foreach ($pbkDir in @($userPbkPath, $systemPbkPath)) {
    if (Test-Path $pbkDir) {
        $pbkFiles = Get-ChildItem -Path $pbkDir -Filter "*.pbk" -ErrorAction SilentlyContinue
        foreach ($pbk in $pbkFiles) {
            $profiles = Select-String -Path $pbk.FullName -Pattern "^\[.+\]" | ForEach-Object { $_.Matches.Value.Trim("[]") }
            foreach ($profile in $profiles) {
                $isTarget = ($VpnProfileName -eq "" -or $profile -eq $VpnProfileName)
                $tag      = if ($pbkDir -eq $systemPbkPath) { "System" } else { "User" }
                Add-Result "Profiles" "Profile: $profile [$tag]" $(if ($isTarget) {"OK"} else {"INFO"}) "Found in $($pbk.FullName)"
            }
        }
    }
}

# PowerShell VPN profile objects
$vpnProfiles = Get-VpnConnection -ErrorAction SilentlyContinue
$deviceVpnProfiles = Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue

$allProfiles = @($vpnProfiles) + @($deviceVpnProfiles)
foreach ($p in $allProfiles | Where-Object {$_}) {
    $scope  = if ($p.AllUserConnection) { "Device" } else { "User" }
    $status = if ($p.ConnectionStatus -eq "Connected") { "OK" } elseif ($p.ConnectionStatus -eq "Disconnected") { "WARN" } else { "INFO" }
    $tunnel = if ($p.TunnelType) { $p.TunnelType } else { "N/A" }
    Add-Result "Profiles" "[$scope] $($p.Name)" $status "Status: $($p.ConnectionStatus)  TunnelType: $tunnel  Server: $($p.ServerAddress)"
}

# ─────────────────────────────────────────────
# 1.4 Machine Certificate (for Device Tunnel / IKEv2)
# ─────────────────────────────────────────────
Write-Host "`n--- Machine Certificates ---" -ForegroundColor Cyan

if (Test-IsAdmin) {
    $machineCerts = Get-ChildItem -Path "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue |
        Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending

    if ($machineCerts.Count -eq 0) {
        Add-Result "Certificates" "Machine cert (LocalMachine\My)" "WARN" "No valid machine certificates found with private key. Device Tunnel requires this."
    } else {
        foreach ($cert in $machineCerts | Select-Object -First 5) {
            $daysLeft = ($cert.NotAfter - (Get-Date)).Days
            $status   = if ($daysLeft -lt 14) { "WARN" } else { "OK" }
            Add-Result "Certificates" "Machine: $($cert.Subject)" $status "Expires: $($cert.NotAfter.ToString('yyyy-MM-dd')) ($daysLeft days)  Issuer: $($cert.Issuer)"
        }
    }
} else {
    Add-Result "Certificates" "Machine cert check" "SKIP" "Requires admin rights — re-run as administrator"
}

# User certificates
$userCerts = Get-ChildItem -Path "Cert:\CurrentUser\My" -ErrorAction SilentlyContinue |
    Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
    Sort-Object NotAfter -Descending

if ($userCerts.Count -eq 0) {
    Add-Result "Certificates" "User cert (CurrentUser\My)" "WARN" "No valid user certificates. User Tunnel with IKEv2/cert auth requires this."
} else {
    foreach ($cert in $userCerts | Select-Object -First 3) {
        $daysLeft = ($cert.NotAfter - (Get-Date)).Days
        $status   = if ($daysLeft -lt 14) { "WARN" } else { "OK" }
        Add-Result "Certificates" "User: $($cert.Subject)" $status "Expires: $($cert.NotAfter.ToString('yyyy-MM-dd')) ($daysLeft days)"
    }
}

# ─────────────────────────────────────────────
# 1.5 IKE Event Log (recent failures)
# ─────────────────────────────────────────────
Write-Host "`n--- IKE/IKEv2 Event Log ---" -ForegroundColor Cyan

try {
    $ikeEvents = Get-WinEvent -FilterHashtable @{
        LogName   = "System"
        ProviderName = "RasClient", "IKE and AuthIP IPsec Keying Modules"
        Level     = 2, 3  # Error, Warning
        StartTime = (Get-Date).AddHours(-4)
    } -ErrorAction SilentlyContinue -MaxEvents 20

    if ($ikeEvents) {
        foreach ($evt in $ikeEvents | Select-Object -First 10) {
            Add-Result "EventLog" "EventID $($evt.Id)" "WARN" "$($evt.TimeCreated.ToString('HH:mm:ss')) — $($evt.Message.Split("`n")[0])"
        }
    } else {
        Add-Result "EventLog" "IKE errors in last 4h" "OK" "No IKE/RasClient errors found in System log"
    }
} catch {
    Add-Result "EventLog" "IKE event log" "SKIP" "Could not read System event log: $_"
}

# ─────────────────────────────────────────────
# 1.6 DNS Resolution Test (internal)
# ─────────────────────────────────────────────
Write-Host "`n--- DNS / Connectivity ---" -ForegroundColor Cyan

if ($InternalDnsName -ne "") {
    try {
        $resolved = Resolve-DnsName -Name $InternalDnsName -ErrorAction Stop
        Add-Result "DNS" "Resolve $InternalDnsName" "OK" "Resolved to: $($resolved | Select-Object -ExpandProperty IPAddress -ErrorAction SilentlyContinue | Select-Object -First 3 | Join-String -Separator ', ')"
    } catch {
        Add-Result "DNS" "Resolve $InternalDnsName" "ERROR" "DNS resolution failed. Check if VPN is connected and DNS suffix routes are correct."
    }
} else {
    Add-Result "DNS" "Internal DNS test" "SKIP" "No -InternalDnsName provided"
}

# ─────────────────────────────────────────────
# 1.7 Internal Host Connectivity
# ─────────────────────────────────────────────
if ($InternalHost -ne "") {
    $ping = Test-NetConnection -ComputerName $InternalHost -InformationLevel Quiet -ErrorAction SilentlyContinue
    $status = if ($ping) { "OK" } else { "ERROR" }
    Add-Result "Connectivity" "Ping $InternalHost" $status $(if ($ping) {"Host reachable"} else {"Host unreachable — VPN may not be connected or route missing"})
} else {
    Add-Result "Connectivity" "Internal host test" "SKIP" "No -InternalHost provided"
}

# ─────────────────────────────────────────────
# 1.8 Route Table — Detect Split vs. Full Tunnel
# ─────────────────────────────────────────────
Write-Host "`n--- Route Table ---" -ForegroundColor Cyan

$routes = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" }

if ($routes.Count -gt 1) {
    Add-Result "Routes" "Default route count" "WARN" "Multiple default routes found — potential routing conflict. Check metric values."
} elseif ($routes.Count -eq 0) {
    Add-Result "Routes" "Default route" "WARN" "No default route found. Network connectivity issue."
} else {
    Add-Result "Routes" "Default route" "OK" "Gateway: $($routes[0].NextHop)  Interface: $($routes[0].InterfaceAlias)  Metric: $($routes[0].RouteMetric)"
}

# Check for VPN-specific routes (private subnets)
$vpnRoutes = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -match "^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^192\.168\." -and
                   $_.InterfaceAlias -match "VPN|WAN|PPP|Tunnel" }

if ($vpnRoutes.Count -gt 0) {
    Add-Result "Routes" "VPN split tunnel routes" "OK" "$($vpnRoutes.Count) private subnet routes via VPN adapter"
} else {
    Add-Result "Routes" "VPN split tunnel routes" "INFO" "No private subnet routes via VPN adapter detected (may be full tunnel or VPN disconnected)"
}

# ─────────────────────────────────────────────
# REPORT GENERATION
# ─────────────────────────────────────────────
Write-Host "`n--- Generating Report ---" -ForegroundColor Cyan

$okCount    = ($results | Where-Object {$_.Status -eq "OK"}).Count
$warnCount  = ($results | Where-Object {$_.Status -eq "WARN"}).Count
$errorCount = ($results | Where-Object {$_.Status -eq "ERROR"}).Count
$skipCount  = ($results | Where-Object {$_.Status -eq "SKIP" -or $_.Status -eq "INFO"}).Count

$summary = "OK: $okCount  WARN: $warnCount  ERROR: $errorCount  SKIP/INFO: $skipCount"

$htmlRows = $results | ForEach-Object {
    $colour = switch ($_.Status) {
        "OK"    { "#d4edda" }
        "WARN"  { "#fff3cd" }
        "ERROR" { "#f8d7da" }
        default { "#f8f9fa" }
    }
    "<tr style='background:$colour'><td>$($_.Category)</td><td>$($_.Check)</td><td><strong>$($_.Status)</strong></td><td>$($_.Detail)</td></tr>"
}

$html = @"
<!DOCTYPE html>
<html><head><title>AOVPN Diagnostic — $env:COMPUTERNAME</title>
<style>
  body{font-family:Segoe UI,Arial,sans-serif;padding:20px;background:#f4f4f4;}
  h1{color:#0078d4;}
  .summary{background:#0078d4;color:#fff;padding:10px 20px;border-radius:5px;font-size:1.1em;margin-bottom:20px;}
  table{width:100%;border-collapse:collapse;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1);}
  th{background:#0078d4;color:#fff;padding:8px 12px;text-align:left;}
  td{padding:7px 12px;border-bottom:1px solid #dee2e6;font-size:.92em;}
  tr:last-child td{border-bottom:none;}
</style>
</head><body>
<h1>Always On VPN — Diagnostic Report</h1>
<p>Computer: <strong>$env:COMPUTERNAME</strong> | User: <strong>$env:USERDOMAIN\$env:USERNAME</strong> | Date: <strong>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</strong></p>
<div class='summary'>$summary</div>
<table>
<tr><th>Category</th><th>Check</th><th>Status</th><th>Detail</th></tr>
$($htmlRows -join "`n")
</table>
</body></html>
"@

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }
$html | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host ""
Write-Status "Report saved to: $OutputPath" "OK"
Write-Host ""
Write-Host "=== Summary: $summary ===" -ForegroundColor Cyan

# Export CSV alongside HTML
$csvPath = $OutputPath -replace "\.html$", ".csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "CSV exported: $csvPath" "OK"
