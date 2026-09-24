<#
.SYNOPSIS
    Classifies Windows Servers for exposure to the September 2026 CU RDS session-teardown deadlock.

.DESCRIPTION
    Read-only fleet check for the Remote Desktop Services deadlock introduced by the September 8, 2026
    cumulative updates (KB5122871 / KB5122882 / KB5122876 / KB5123099) and fixed by the September 14, 2026
    out-of-band updates (KB5129235 / KB5129237 / KB5129238).

    For each target it collects: OS, build.UBR, relevant KBs, TermService state, Event 20498 and
    Winlogon 6005 counts, RDS roles, KIR policy overrides, the community registry override for feature
    flag 3802373433, and last boot time — then assigns a status bucket:

        Fixed                 OOB installed / OOB build or later
        Deadlocked            Sept CU present, TermService StopPending, or deadlock events present w/o fix
        Mitigated-KIR         KIR policy override values present and host rebooted since (heuristic)
        Mitigated-Registry    Community override key present
        Exposed               Sept CU present, no fix, no mitigation, no events yet
        NotApplicable         No Sept CU detected
        Unreachable           Remoting failed

    It does NOT install updates, apply KIR, edit the registry, or restart services.
    KIR detection is heuristic: KIR ADMX policies write numeric values under
    HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides; the script reports that
    values exist, not which KIR they belong to.

.PARAMETER ComputerName
    One or more servers. Defaults to the local machine.

.PARAMETER DaysBack
    How many days of event log to scan for 20498 / 6005. Default 7.

.PARAMETER OutputPath
    Folder for the CSV report. Default C:\Temp.

.EXAMPLE
    .\Get-RDSDeadlockSept2026Status.ps1
    Checks the local server.

.EXAMPLE
    .\Get-RDSDeadlockSept2026Status.ps1 -ComputerName (Get-Content .\servers.txt) -DaysBack 3
    Checks a list of servers via PowerShell remoting and writes a CSV.

.NOTES
    Requires: PowerShell 5.1+, WinRM to remote targets, local admin on targets (event log + HKLM read).
    Safe: read-only. Run from a non-RDP session if the local host is already deadlocked.
    Build/KB references: Microsoft release health + community reporting (LazyAdmin, BleepingComputer, Citrix CTX697101).
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [ValidateRange(1,90)][int]$DaysBack = 7,
    [string]$OutputPath = 'C:\Temp'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------- Preflight ----------
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$SeptKBs = @('KB5122871','KB5122882','KB5122876','KB5123099')
$OobKBs  = @('KB5129235','KB5129237','KB5129238','KB5129243')
# Minimum fixed UBR per build (from OOB KB articles); 2019/2016 not listed -> KB-based detection only
$FixedUbr = @{ '26100' = 33451; '20348' = 5631 }

Write-Status "Checking $($ComputerName.Count) target(s); event window $DaysBack day(s)."

# ---------- Detect (remote scriptblock) ----------
$probe = {
    param($DaysBack, $SeptKBs, $OobKBs)
    Set-StrictMode -Off
    $ErrorActionPreference = 'SilentlyContinue'
    $cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $hf   = @(Get-HotFix | Select-Object -ExpandProperty HotFixID)
    $svc  = Get-Service TermService
    $start = (Get-Date).AddDays(-$DaysBack)
    $e20498 = @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin'; Id=20498; StartTime=$start}).Count
    $e6005  = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Winlogon'; Id=6005; StartTime=$start}).Count
    $kirKey = 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'
    $kirVals = 0
    if (Test-Path $kirKey) {
        $p = Get-ItemProperty $kirKey
        if ($p) { $kirVals = @($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }).Count }
    }
    $regOverride = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\4\3802373433'
    $roles = ''
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $roles = (@(Get-WindowsFeature RDS-* | Where-Object Installed | Select-Object -ExpandProperty Name) -join ';')
    }
    [pscustomobject]@{
        ProductName   = $cv.ProductName
        Build         = [string]$cv.CurrentBuild
        UBR           = [int]$cv.UBR
        SeptKB        = (@($hf | Where-Object { $SeptKBs -contains $_ }) -join ';')
        OobKB         = (@($hf | Where-Object { $OobKBs  -contains $_ }) -join ';')
        TermService   = if ($svc) { [string]$svc.Status } else { 'Missing' }
        Evt20498      = $e20498
        Evt6005       = $e6005
        KirPolicyVals = $kirVals
        RegOverride   = $regOverride
        RdsRoles      = $roles
        LastBoot      = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    }
}

# ---------- Execute ----------
$results = foreach ($c in $ComputerName) {
    try {
        if ($c -eq $env:COMPUTERNAME -or $c -eq 'localhost' -or $c -eq '.') {
            $r = & $probe $DaysBack $SeptKBs $OobKBs
        } else {
            $r = Invoke-Command -ComputerName $c -ScriptBlock $probe -ArgumentList $DaysBack, $SeptKBs, $OobKBs -ErrorAction Stop
        }

        # ---------- Validate / classify ----------
        $fixedByUbr = $FixedUbr.ContainsKey($r.Build) -and ($r.UBR -ge $FixedUbr[$r.Build])
        $septByUbr  = ($r.Build -eq '26100' -and $r.UBR -ge 33438) -or ($r.Build -eq '20348' -and $r.UBR -ge 5622)
        $status =
            if ($r.OobKB -or $fixedByUbr) { 'Fixed' }
            elseif (-not $r.SeptKB -and -not $septByUbr) { 'NotApplicable' }
            elseif ($r.TermService -eq 'StopPending') { 'Deadlocked' }
            elseif ($r.RegOverride) { 'Mitigated-Registry' }
            elseif ($r.KirPolicyVals -gt 0) { 'Mitigated-KIR' }
            elseif ($r.Evt20498 -gt 0 -or $r.Evt6005 -gt 0) { 'Deadlocked' }
            else { 'Exposed' }

        $action = switch ($status) {
            'Fixed'              { 'None. Remove KIR GPO / registry override if still present.' }
            'Deadlocked'         { 'Recover (kill TermService svchost or hard reset), then install OOB (2016: KIR).' }
            'Mitigated-KIR'      { 'Confirm reboot after KIR; plan OOB (2019/2022/2025).' }
            'Mitigated-Registry' { 'Unofficial mitigation - replace with OOB/KIR, then remove override.' }
            'Exposed'            { 'Install OOB in next window (2016: deploy KIR).' }
            default              { 'Not this issue.' }
        }
        $lvl = switch ($status) { 'Fixed'{'OK'} 'NotApplicable'{'OK'} 'Deadlocked'{'ERROR'} default{'WARN'} }
        Write-Status "$c [$($r.Build).$($r.UBR)] -> $status" $lvl

        [pscustomobject]@{
            ComputerName = $c; Status = $status; Action = $action
            ProductName = $r.ProductName; BuildUBR = "$($r.Build).$($r.UBR)"
            SeptKB = $r.SeptKB; OobKB = $r.OobKB; TermService = $r.TermService
            Evt20498 = $r.Evt20498; Evt6005 = $r.Evt6005
            KirPolicyVals = $r.KirPolicyVals; RegOverride = $r.RegOverride
            RdsRoles = $r.RdsRoles; LastBoot = $r.LastBoot
        }
    }
    catch {
        Write-Status "$c unreachable: $($_.Exception.Message)" 'ERROR'
        [pscustomobject]@{
            ComputerName = $c; Status = 'Unreachable'; Action = 'Check WinRM / use console or RMM shell'
            ProductName = ''; BuildUBR = ''; SeptKB = ''; OobKB = ''; TermService = ''
            Evt20498 = $null; Evt6005 = $null; KirPolicyVals = $null; RegOverride = $null
            RdsRoles = ''; LastBoot = $null
        }
    }
}

# ---------- Report ----------
$csv = Join-Path $OutputPath ("RDSDeadlockSept2026_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Summary:"
$results | Group-Object Status | Sort-Object Name | ForEach-Object { Write-Status ("  {0,-20} {1}" -f $_.Name, $_.Count) }
Write-Status "Report written to $csv" 'OK'
$results
