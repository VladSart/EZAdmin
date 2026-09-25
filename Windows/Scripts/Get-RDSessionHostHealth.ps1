<#
.SYNOPSIS
    Read-only health check of RDS session collections and their session hosts.

.DESCRIPTION
    Companion to Windows/Troubleshooting/RDSessionHost-A.md / -B.md.
    Collects, without changing anything:
      - Collections in the deployment (or one named collection)
      - Per host: broker drain flag (NewConnectionAllowed), local drain state (change logon /query),
        and flags a mismatch between the two (the classic "healthy host that gets no users")
      - Per host: TermService / SessionEnv / UmRdpService state, TCP 3389 reachability, last boot,
        active vs disconnected session counts
      - Load-balancing RelativeWeight / SessionLimit per host, flags weight 0 and hosts at the limit
      - Collection connection limits (disconnected/idle/active minutes, broken-connection action)
      - User Profile Disk configuration: path reachable, template present, VHDX count
      - LocalSessionManager error/warning count per host over the last N hours
    Does NOT: change drain state, log users off, check GPO precedence (use gpresult),
    validate broker HA/database (Get-RDConnectionBrokerDiagnostics.ps1) or licensing
    (Get-RDSLicensingDiagnostics.ps1).

.PARAMETER ConnectionBroker
    FQDN of a Connection Broker (the active management server in HA). Default: local FQDN.

.PARAMETER CollectionName
    Limit to one session collection. Default: all session collections.

.PARAMETER HoursBack
    Window for event log counts. Default 24.

.PARAMETER OutputPath
    Folder for the CSV report. Default: C:\Temp.

.EXAMPLE
    .\Get-RDSessionHostHealth.ps1 -ConnectionBroker rdcb01.contoso.com -CollectionName 'Desktops'

.EXAMPLE
    .\Get-RDSessionHostHealth.ps1 -HoursBack 72 -OutputPath D:\Reports

.NOTES
    Requires: Windows PowerShell 5.1, RemoteDesktop module, admin rights on the deployment,
    WinRM to each session host. Safe: read-only.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConnectionBroker = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName),
    [string]$CollectionName,
    [ValidateRange(1, 720)][int]$HoursBack = 24,
    [string]$OutputPath = 'C:\Temp'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Collection, [string]$Target, [string]$Check, [string]$Value, [string]$Status = 'INFO')
    $results.Add([pscustomobject]@{
        Timestamp  = (Get-Date).ToString('s')
        Collection = $Collection
        Target     = $Target
        Check      = $Check
        Value      = $Value
        Status     = $Status
    })
    Write-Status "$Collection | $Target | $Check : $Value" $Status
}

# ---------------- Preflight ----------------
Write-Status "Preflight: RemoteDesktop module and broker $ConnectionBroker"
try { Import-Module RemoteDesktop -ErrorAction Stop }
catch { Write-Status 'RemoteDesktop module not available. Run on a broker or install RSAT-RDS-Tools.' 'ERROR'; return }
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

# ---------------- Detect collections ----------------
try {
    $collections = @(Get-RDSessionCollection -ConnectionBroker $ConnectionBroker)
} catch {
    Write-Status "Cannot enumerate collections on $ConnectionBroker : $($_.Exception.Message)" 'ERROR'
    Write-Status 'If this is a non-active broker in HA, re-run against the active management server.' 'WARN'
    return
}
if ($CollectionName) { $collections = @($collections | Where-Object { $_.CollectionName -eq $CollectionName }) }
if ($collections.Count -eq 0) { Write-Status 'No matching session collections found.' 'WARN'; return }

$since = (Get-Date).AddHours(-$HoursBack)

foreach ($c in $collections) {
    $coll = $c.CollectionName
    Write-Status "=== Collection: $coll ==="

    # Sessions
    $sessions = @()
    try { $sessions = @(Get-RDUserSession -ConnectionBroker $ConnectionBroker -CollectionName $coll) }
    catch { Add-Result $coll $ConnectionBroker 'Get-RDUserSession' $_.Exception.Message 'WARN' }

    # Load balancing
    $lb = @()
    try { $lb = @(Get-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $ConnectionBroker -LoadBalancing) }
    catch { Add-Result $coll $ConnectionBroker 'LoadBalancing config' $_.Exception.Message 'WARN' }

    # Connection limits
    try {
        $conn = Get-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $ConnectionBroker -Connection
        $val = "Disconnected=$($conn.DisconnectedSessionLimitMin)m Idle=$($conn.IdleSessionLimitMin)m Active=$($conn.ActiveSessionLimitMin)m Broken=$($conn.BrokenConnectionAction)"
        $st = 'OK'; if ($conn.DisconnectedSessionLimitMin -eq 0) { $st = 'WARN'; $val += ' (disconnected sessions never end unless a GPO sets a limit)' }
        Add-Result $coll $ConnectionBroker 'Connection limits (collection; GPO may override)' $val $st
    } catch { Add-Result $coll $ConnectionBroker 'Connection limits' $_.Exception.Message 'WARN' }

    # UPD
    try {
        $upd = Get-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $ConnectionBroker -UserProfileDisk
        if ($upd.EnableUserProfileDisk) {
            $path = [string]$upd.DiskPath
            if (Test-Path -LiteralPath $path) {
                $tmpl = Test-Path -LiteralPath (Join-Path $path 'UVHD-template.vhdx')
                $count = @(Get-ChildItem -LiteralPath $path -Filter 'UVHD-S-*.vhdx' -ErrorAction SilentlyContinue).Count
                $st = 'OK'; if (-not $tmpl) { $st = 'WARN' }
                Add-Result $coll $path 'UPD share' "Reachable; template=$tmpl; disks=$count; max=$($upd.MaxUserProfileDiskSizeGB)GB" $st
            } else {
                Add-Result $coll $path 'UPD share' 'NOT reachable from this machine' 'ERROR'
            }
        } else {
            Add-Result $coll $ConnectionBroker 'UPD' 'Disabled (FSLogix/local/roaming profiles)' 'INFO'
        }
    } catch { Add-Result $coll $ConnectionBroker 'UPD config' $_.Exception.Message 'WARN' }

    # Hosts
    $hosts = @()
    try { $hosts = @(Get-RDSessionHost -CollectionName $coll -ConnectionBroker $ConnectionBroker) }
    catch { Add-Result $coll $ConnectionBroker 'Get-RDSessionHost' $_.Exception.Message 'ERROR'; continue }
    if ($hosts.Count -eq 0) { Add-Result $coll $ConnectionBroker 'Hosts' 'Collection has no session hosts' 'ERROR'; continue }

    foreach ($h in $hosts) {
        $hn = [string]$h.SessionHost
        $broker = [string]$h.NewConnectionAllowed
        $bst = 'OK'; if ($broker -ne 'Yes') { $bst = 'WARN' }
        Add-Result $coll $hn 'Broker NewConnectionAllowed' $broker $bst

        # Reachability
        $rdp = $false
        try { $rdp = (Test-NetConnection -ComputerName $hn -Port 3389 -WarningAction SilentlyContinue).TcpTestSucceeded } catch {}
        $rst = 'OK'; if (-not $rdp) { $rst = 'ERROR' }
        Add-Result $coll $hn 'TCP 3389' ([string]$rdp) $rst

        # Remote host state
        $local = $null
        try {
            $local = Invoke-Command -ComputerName $hn -ErrorAction Stop -ScriptBlock {
                $q = ((& change.exe logon /query 2>&1) | Out-String).Trim()
                $svc = Get-Service TermService, SessionEnv, UmRdpService -ErrorAction SilentlyContinue |
                    ForEach-Object { '{0}={1}' -f $_.Name, $_.Status }
                [pscustomobject]@{
                    Logon    = $q
                    Services = ($svc -join ';')
                    LastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                }
            }
        } catch { Add-Result $coll $hn 'WinRM' $_.Exception.Message 'ERROR' }

        if ($local) {
            $logonUpper = $local.Logon.ToUpperInvariant()
            $lst = 'OK'; $lval = 'ENABLED'
            if ($logonUpper -match 'DRAIN') { $lst = 'WARN'; $lval = 'DRAIN' }
            elseif ($logonUpper -match 'DISABLED') { $lst = 'ERROR'; $lval = 'DISABLED' }
            elseif ($logonUpper -notmatch 'ENABLED') { $lst = 'WARN'; $lval = "Unrecognised: $($local.Logon)" }
            Add-Result $coll $hn 'Local logon state (change logon)' $lval $lst

            if ($broker -eq 'Yes' -and $lval -ne 'ENABLED') {
                Add-Result $coll $hn 'Drain mismatch' 'Broker routes users here but host refuses new logons (run: change logon /enable)' 'ERROR'
            }
            $sst = 'OK'; if ($local.Services -match '=(Stopped|StopPending|StartPending)') { $sst = 'ERROR' }
            Add-Result $coll $hn 'RDS services' $local.Services $sst
            Add-Result $coll $hn 'Last boot' ([string]$local.LastBoot) 'INFO'
            if ($broker -eq 'NotUntilReboot') {
                Add-Result $coll $hn 'Drain note' 'NotUntilReboot: host returns to Yes after next restart' 'INFO'
            }
        }

        # Sessions per host
        $mine = @($sessions | Where-Object { [string]$_.HostServer -eq $hn })
        $active = @($mine | Where-Object { [string]$_.SessionState -match 'Active' }).Count
        $disc = @($mine | Where-Object { [string]$_.SessionState -match 'Disconnected' }).Count
        Add-Result $coll $hn 'Sessions' "Total=$($mine.Count) Active=$active Disconnected=$disc" 'INFO'

        # LB
        $lbh = @($lb | Where-Object { [string]$_.SessionHost -eq $hn }) | Select-Object -First 1
        if ($lbh) {
            $lst2 = 'OK'; $note = ''
            if ([int]$lbh.RelativeWeight -le 0) { $lst2 = 'ERROR'; $note = ' (weight 0: never selected)' }
            elseif ([int]$lbh.SessionLimit -gt 0 -and $mine.Count -ge [int]$lbh.SessionLimit) { $lst2 = 'WARN'; $note = ' (at SessionLimit: skipped for new users)' }
            Add-Result $coll $hn 'Load balancing' "Weight=$($lbh.RelativeWeight) Limit=$($lbh.SessionLimit)$note" $lst2
        }

        # Events
        try {
            $ev = @(Get-WinEvent -ComputerName $hn -FilterHashtable @{
                LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Level = 2, 3; StartTime = $since } -ErrorAction Stop)
            $est = 'OK'; if ($ev.Count -gt 0) { $est = 'WARN' }
            Add-Result $coll $hn "LSM errors/warnings ($HoursBack h)" ([string]$ev.Count) $est
        } catch {
            if ($_.Exception.Message -match 'No events were found') { Add-Result $coll $hn "LSM errors/warnings ($HoursBack h)" '0' 'OK' }
            else { Add-Result $coll $hn 'LSM event log' $_.Exception.Message 'WARN' }
        }
    }

    # Distribution skew (simple): any accepting host with 0 sessions while another has >= 5
    $perHost = foreach ($h in $hosts) { @($sessions | Where-Object { [string]$_.HostServer -eq [string]$h.SessionHost }).Count }
    $max = ($perHost | Measure-Object -Maximum).Maximum
    foreach ($h in $hosts) {
        $n = @($sessions | Where-Object { [string]$_.HostServer -eq [string]$h.SessionHost }).Count
        if ([string]$h.NewConnectionAllowed -eq 'Yes' -and $n -eq 0 -and $max -ge 5) {
            Add-Result $coll ([string]$h.SessionHost) 'Distribution' "0 sessions while peer has $max - check local drain, weight, or stale broker record" 'WARN'
        }
    }
}

# ---------------- Report ----------------
$file = Join-Path $OutputPath ("RDSessionHostHealth-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$results | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
$err = @($results | Where-Object Status -eq 'ERROR').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
$sum = 'OK'; if ($err) { $sum = 'ERROR' } elseif ($warn) { $sum = 'WARN' }
Write-Status "Done. Errors=$err Warnings=$warn. Report: $file" $sum
