<#
.SYNOPSIS
    Read-only RDS licensing health check for one or more RD Session Hosts and their license server(s).

.DESCRIPTION
    For each RD Session Host (local or remote via CIM/WinRM):
      - Licensing mode (Win32_TerminalServiceSetting.LicensingType: 2 = Per Device, 4 = Per User)
      - Configured license server list (GetSpecifiedLicenseServerList) and grace days left (GetGracePeriodDays)
      - Group Policy values (LicensingMode / LicenseServers) and whether they conflict with WMI
      - OS caption/build (for CAL version comparison)
      - TCP 135 reachability from the machine running the script to each listed license server
    For each license server (listed on the hosts, plus -LicenseServer):
      - TermServLicensing service state
      - Installed CAL packs (Win32_TSLicenseKeyPack): type, version, total/available/issued
      - Whether a pack matching the host's mode and a version >= host OS year exists

    Makes no changes. Does not check activation state or AD group membership (use licmgr.exe
    Review Configuration / Get-ADGroupMember) and does not evaluate CAL compliance for Per User.

.PARAMETER ComputerName
    RD Session Host(s) to check. Defaults to the local computer.

.PARAMETER LicenseServer
    Additional license server(s) to inventory even if not configured on the hosts.

.PARAMETER OutputPath
    Folder for the CSV report. Defaults to $env:TEMP.

.EXAMPLE
    .\Get-RDSLicensingDiagnostics.ps1

.EXAMPLE
    .\Get-RDSLicensingDiagnostics.ps1 -ComputerName rdsh01,rdsh02 -LicenseServer rdls01.contoso.com

.NOTES
    Run elevated with admin rights on target hosts/license servers. Remote checks use CIM over WinRM
    (Get-CimInstance -ComputerName); the registry policy read uses Invoke-Command.
    Safe: read-only. Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string[]]$LicenseServer = @(),
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Target, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Target=$Target; Check=$Check; Status=$Status; Detail=$Detail })
    Write-Status "$Target | $Check : $Detail" $Status
}

function Get-OsYear {
    param([string]$Caption)
    if ($Caption -match '(20\d\d)') { return [int]$Matches[1] } else { return $null }
}

function Test-IsLocal {
    param([string]$Name)
    return ($Name -eq $env:COMPUTERNAME -or $Name -eq 'localhost' -or $Name -eq '.' -or $Name -like "$env:COMPUTERNAME.*")
}

# ---------------- Preflight ----------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Status "Not elevated - some WMI methods may be denied." "WARN" }

$modeName = @{ 2 = 'PerDevice'; 4 = 'PerUser' }
$hostInfo = @{}
$lsToCheck = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
foreach ($l in $LicenseServer) { [void]$lsToCheck.Add($l) }

# ---------------- Detect: session hosts ----------------
foreach ($cn in $ComputerName) {
    $cimArgs = @{}
    if (-not (Test-IsLocal $cn)) { $cimArgs['ComputerName'] = $cn }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem @cimArgs
        $ts = Get-CimInstance -Namespace root/cimv2/TerminalServices -ClassName Win32_TerminalServiceSetting @cimArgs
    } catch {
        Add-Result $cn "Connect" "ERROR" "CIM query failed: $($_.Exception.Message)"
        continue
    }
    $year = Get-OsYear $os.Caption
    Add-Result $cn "OS" "INFO" "$($os.Caption) build $($os.BuildNumber)"

    $lt = [int]$ts.LicensingType
    $mode = if ($modeName.ContainsKey($lt)) { $modeName[$lt] } else { "NotConfigured($lt)" }
    Add-Result $cn "LicensingMode(WMI)" ($(if ($modeName.ContainsKey($lt)) {"OK"} else {"ERROR"})) $mode

    $lsList = @()
    try {
        $r = Invoke-CimMethod -InputObject $ts -MethodName GetSpecifiedLicenseServerList
        $lsList = @($r.SpecifiedLSList | Where-Object { $_ })
    } catch { Add-Result $cn "LicenseServerList" "WARN" "Query failed: $($_.Exception.Message)" }
    Add-Result $cn "LicenseServerList(WMI)" ($(if ($lsList.Count) {"OK"} else {"ERROR"})) ($(if ($lsList.Count) {$lsList -join ', '} else {'<empty>'}))
    foreach ($l in $lsList) { [void]$lsToCheck.Add($l) }

    try {
        $g = Invoke-CimMethod -InputObject $ts -MethodName GetGracePeriodDays
        $days = [int]$g.DaysLeft
        $st = if ($days -le 0) { "WARN" } elseif ($days -le 14) { "WARN" } else { "INFO" }
        Add-Result $cn "GraceDaysLeft" $st "$days (only matters if licensing is not working)"
    } catch { Add-Result $cn "GraceDaysLeft" "INFO" "Not available: $($_.Exception.Message)" }

    # Policy
    $polBlock = {
        $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        $o = [ordered]@{ LicensingMode = $null; LicenseServers = $null }
        if (Test-Path $k) {
            $p = Get-ItemProperty $k
            foreach ($n in 'LicensingMode','LicenseServers') {
                $prop = $p.PSObject.Properties[$n]
                if ($prop) { $o[$n] = $prop.Value }
            }
        }
        [pscustomobject]$o
    }
    try {
        $pol = if (Test-IsLocal $cn) { & $polBlock } else { Invoke-Command -ComputerName $cn -ScriptBlock $polBlock }
        if ($null -eq $pol.LicensingMode -and $null -eq $pol.LicenseServers) {
            Add-Result $cn "GroupPolicy" "INFO" "No licensing GPO - deployment/WMI settings are authoritative"
        } else {
            $conflict = ($null -ne $pol.LicensingMode -and [int]$pol.LicensingMode -ne $lt)
            Add-Result $cn "GroupPolicy" ($(if ($conflict) {"WARN"} else {"OK"})) "GPO LicensingMode=$($pol.LicensingMode) LicenseServers=$($pol.LicenseServers) (GPO overrides Server Manager)"
        }
    } catch { Add-Result $cn "GroupPolicy" "WARN" "Could not read policy: $($_.Exception.Message)" }

    $hostInfo[$cn] = [pscustomobject]@{ Mode = $lt; Year = $year; LS = $lsList }
}

# ---------------- Detect: license servers ----------------
$lsPacks = @{}
foreach ($ls in $lsToCheck) {
    try {
        $tnc = Test-NetConnection -ComputerName $ls -Port 135 -WarningAction SilentlyContinue
        Add-Result $ls "RPC135(from $env:COMPUTERNAME)" ($(if ($tnc.TcpTestSucceeded) {"OK"} else {"ERROR"})) "TcpTestSucceeded=$($tnc.TcpTestSucceeded)"
    } catch { Add-Result $ls "RPC135" "ERROR" $_.Exception.Message }

    $cimArgs = @{}
    if (-not (Test-IsLocal $ls)) { $cimArgs['ComputerName'] = $ls }
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='TermServLicensing'" @cimArgs
        if ($null -eq $svc) { Add-Result $ls "TermServLicensing" "ERROR" "Service not installed - not a license server"; continue }
        Add-Result $ls "TermServLicensing" ($(if ($svc.State -eq 'Running') {"OK"} else {"ERROR"})) "State=$($svc.State) StartMode=$($svc.StartMode)"
    } catch { Add-Result $ls "TermServLicensing" "ERROR" "Query failed: $($_.Exception.Message)"; continue }

    try {
        $packs = @(Get-CimInstance -ClassName Win32_TSLicenseKeyPack @cimArgs)
        $lsPacks[$ls] = $packs
        if ($packs.Count -eq 0) { Add-Result $ls "KeyPacks" "ERROR" "No CAL packs returned" }
        foreach ($p in $packs) {
            Add-Result $ls "KeyPack" "INFO" ("Id={0} Version='{1}' Type='{2}' Total={3} Available={4} Issued={5}" -f $p.KeyPackId, $p.ProductVersion, $p.TypeAndModel, $p.TotalLicenses, $p.AvailableLicenses, $p.IssuedLicenses)
        }
    } catch { Add-Result $ls "KeyPacks" "WARN" "Win32_TSLicenseKeyPack query failed: $($_.Exception.Message)" }
}

# ---------------- Validate: host vs packs ----------------
foreach ($cn in $hostInfo.Keys) {
    $h = $hostInfo[$cn]
    if (-not $modeName.ContainsKey($h.Mode)) { continue }
    $want = if ($h.Mode -eq 4) { 'User' } else { 'Device' }
    $match = $false; $detail = @()
    foreach ($ls in $h.LS) {
        if (-not $lsPacks.ContainsKey($ls)) { continue }
        foreach ($p in $lsPacks[$ls]) {
            if ("$($p.TypeAndModel)" -notmatch $want) { continue }
            $pYear = Get-OsYear "$($p.ProductVersion)"
            $verOk = ($null -eq $h.Year -or $null -eq $pYear -or $pYear -ge $h.Year)
            $availOk = ($h.Mode -eq 4 -or [int]$p.AvailableLicenses -gt 0)
            $detail += "${ls}:$($p.ProductVersion)/avail=$($p.AvailableLicenses)"
            if ($verOk -and $availOk -and [int]$p.TotalLicenses -gt 0) { $match = $true }
        }
    }
    $msg = "Needs Per $want CALs version >= $($h.Year). Candidates: $(if ($detail.Count) {$detail -join '; '} else {'none'})"
    Add-Result $cn "MatchingCALs" ($(if ($match) {"OK"} else {"ERROR"})) $msg
}

# ---------------- Report ----------------
if (-not (Test-Path $OutputPath)) { New-Item $OutputPath -ItemType Directory -Force | Out-Null }
$csv = Join-Path $OutputPath ("RDSLicensingDiagnostics_{0}.csv" -f (Get-Date -Format yyyyMMdd_HHmmss))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$bad = @($results | Where-Object { $_.Status -in 'WARN','ERROR' }).Count
Write-Status "Done. $($results.Count) checks, $bad warnings/errors. Next: run lsdiag.msc on each host and licmgr.exe Review Configuration on the LS. Report: $csv" ($(if ($bad) {"WARN"} else {"OK"}))
