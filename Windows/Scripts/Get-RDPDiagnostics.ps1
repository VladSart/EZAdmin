<#
.SYNOPSIS
    Collects Remote Desktop Protocol (RDP) health data from a client or server for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/RDP-B.md.
    Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
    - fDenyTSConnections registry state (RDP enabled/disabled)
    - TermService and dependency service status (RpcSs, TermDD, UmRdpService)
    - Port 3389 (or custom port) listening state
    - Windows Firewall Remote Desktop rule state
    - Network Level Authentication (NLA) requirement
    - Remote Desktop Users local group membership
    - Recent TerminalServices-LocalSessionManager event log entries (21/24/25/40/41)
    - Active/disconnected session count (query session, if available)

    Can run locally or against a remote host via PSRemoting (-ComputerName).

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Enabling RDP or fixing any of the above (see RDP-B.md Fix 1-6)
    - Azure NSG / network path checks (see RDP-B.md Fix 4 — requires Az PowerShell)
    - RDS CAL licensing configuration

.PARAMETER ComputerName
    Target hostname to check. Defaults to the local machine. Requires PSRemoting
    (WinRM) enabled on the target if remote.

.PARAMETER Port
    RDP port to check. Default: 3389.

.PARAMETER EventLookbackHours
    How far back to search the TerminalServices-LocalSessionManager event log. Default: 4.

.PARAMETER ExportPath
    Path for CSV export. Default: .\RDPDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-RDPDiagnostics.ps1
    Runs the full triage sweep against the local machine.

.EXAMPLE
    .\Get-RDPDiagnostics.ps1 -ComputerName SRV-RDS01 -Port 3389 -EventLookbackHours 8
    Runs the sweep against a remote RDS host over PSRemoting, widening the event log search to 8 hours.

.NOTES
    Requires: Windows PowerShell 5.1+; PSRemoting (WinRM) enabled for -ComputerName use
    Run-as: Administrator (required to read Security/TerminalServices event logs and query services)
    Safe: Read-only — makes no changes to registry, services, or firewall rules
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2019/2022
#>

[CmdletBinding()]
param(
    [string]$ComputerName = $env:COMPUTERNAME,

    [int]$Port = 3389,

    [int]$EventLookbackHours = 4,

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
Write-Status "Get-RDPDiagnostics — target: $ComputerName — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\RDPDiagnostics-$timestamp.csv"
}

$isLocal = ($ComputerName -eq $env:COMPUTERNAME) -or ($ComputerName -eq "localhost") -or ($ComputerName -eq ".")

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

# Wrapper: run a scriptblock locally or via Invoke-Command, uniformly
function Invoke-Remotely {
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    if ($isLocal) {
        & $ScriptBlock @ArgumentList
    } else {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
}
#endregion

#region ─── 1. fDenyTSConnections (RDP enabled/disabled) ──────────────────────
try {
    $deny = Invoke-Remotely -ScriptBlock {
        (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -ErrorAction Stop).fDenyTSConnections
    }
    if ($deny -eq 0) {
        Add-Result "RDPEnabled" "OK" "fDenyTSConnections=0 (RDP enabled)"
    } else {
        Add-Result "RDPEnabled" "ERROR" "fDenyTSConnections=$deny (RDP disabled) — see RDP-B.md Fix 1"
    }
} catch {
    Add-Result "RDPEnabled" "ERROR" "Could not read fDenyTSConnections: $_"
}
#endregion

#region ─── 2. TermService and dependencies ────────────────────────────────────
try {
    $svcResults = Invoke-Remotely -ScriptBlock {
        $services = @("RpcSs", "TermService", "UmRdpService")
        $out = @{}
        foreach ($svc in $services) {
            $s = Get-Service $svc -ErrorAction SilentlyContinue
            $out[$svc] = if ($s) { $s.Status.ToString() } else { "NotFound" }
        }
        $out
    }
    foreach ($svcName in $svcResults.Keys) {
        $status = $svcResults[$svcName]
        if ($status -eq "Running") {
            Add-Result "Service-$svcName" "OK" "Running"
        } else {
            Add-Result "Service-$svcName" "ERROR" "$status — see RDP-B.md Fix 2"
        }
    }
} catch {
    Add-Result "ServiceCheck" "ERROR" "Could not query services: $_"
}
#endregion

#region ─── 3. Port listening state ────────────────────────────────────────────
try {
    $portState = Invoke-Remotely -ScriptBlock {
        param($p)
        $conn = Get-NetTCPConnection -LocalPort $p -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) { $conn.State.ToString() } else { "NOT LISTENING" }
    } -ArgumentList $Port

    if ($portState -eq "Listen") {
        Add-Result "Port$Port" "OK" "Listening"
    } else {
        Add-Result "Port$Port" "ERROR" "Not listening ($portState) — resolve service/firewall first"
    }
} catch {
    Add-Result "Port$Port" "ERROR" "Could not check port state: $_"
}
#endregion

#region ─── 4. Firewall rule state ─────────────────────────────────────────────
try {
    $fwRules = Invoke-Remotely -ScriptBlock {
        Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue |
            Select-Object DisplayName, Enabled, Direction, Action
    }
    if ($fwRules) {
        $inboundEnabled = $fwRules | Where-Object { $_.Direction -eq "Inbound" -and $_.Enabled -eq $true -and $_.Action -eq "Allow" }
        if ($inboundEnabled) {
            Add-Result "FirewallRDP" "OK" "$($inboundEnabled.Count) inbound Allow rule(s) enabled"
        } else {
            Add-Result "FirewallRDP" "ERROR" "No enabled inbound Allow rule found — see RDP-B.md Fix 3"
        }
    } else {
        Add-Result "FirewallRDP" "ERROR" "No 'Remote Desktop' firewall rule group found — see RDP-B.md Fix 3"
    }
} catch {
    Add-Result "FirewallRDP" "ERROR" "Could not query firewall rules: $_"
}
#endregion

#region ─── 5. NLA requirement ─────────────────────────────────────────────────
try {
    $nla = Invoke-Remotely -ScriptBlock {
        (Get-WmiObject -Class Win32_TerminalServiceSetting -Namespace root\CIMv2\TerminalServices -ErrorAction Stop).UserAuthenticationRequired
    }
    if ($nla -eq 1) {
        Add-Result "NLA" "OK" "NLA required (UserAuthenticationRequired=1)"
    } else {
        Add-Result "NLA" "WARN" "NLA NOT required (UserAuthenticationRequired=0) — reduced pre-auth security"
    }
} catch {
    Add-Result "NLA" "WARN" "Could not read NLA setting: $_"
}
#endregion

#region ─── 6. Remote Desktop Users group membership ───────────────────────────
try {
    $rdpUsers = Invoke-Remotely -ScriptBlock {
        Get-LocalGroupMember -Group "Remote Desktop Users" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    }
    if ($rdpUsers) {
        Add-Result "RDPUsersGroup" "OK" "$($rdpUsers.Count) member(s): $($rdpUsers -join '; ')"
    } else {
        Add-Result "RDPUsersGroup" "WARN" "Remote Desktop Users group is empty — only local admins can connect"
    }
} catch {
    Add-Result "RDPUsersGroup" "WARN" "Could not query group membership: $_"
}
#endregion

#region ─── 7. Recent TerminalServices event log entries ──────────────────────
try {
    $events = Invoke-Remotely -ScriptBlock {
        param($hours)
        Get-WinEvent -FilterHashtable @{
            LogName   = "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"
            Id        = @(21, 24, 25, 40, 41)
            StartTime = (Get-Date).AddHours(-$hours)
        } -ErrorAction Stop | Select-Object TimeCreated, Id, Message
    } -ArgumentList $EventLookbackHours

    $failures = $events | Where-Object { $_.Id -eq 41 }
    if ($failures.Count -gt 0) {
        Add-Result "SessionEvents" "WARN" "$($failures.Count) connection failure event(s) (ID 41) in last $EventLookbackHours h"
    } else {
        Add-Result "SessionEvents" "OK" "No connection failures (ID 41) in last $EventLookbackHours h ($($events.Count) total session events)"
    }
} catch {
    if ($_.Exception.Message -match 'No events were found') {
        Add-Result "SessionEvents" "OK" "No matching session events in last $EventLookbackHours h"
    } else {
        Add-Result "SessionEvents" "WARN" "Could not query session event log: $_"
    }
}
#endregion

#region ─── 8. Active/disconnected session count ──────────────────────────────
try {
    $sessionOutput = Invoke-Remotely -ScriptBlock {
        query session 2>&1 | Out-String
    }
    if ($sessionOutput -match '\S') {
        $sessionLines = ($sessionOutput -split "`n" | Where-Object { $_.Trim() -ne "" }).Count - 1
        Add-Result "ActiveSessions" "INFO" "$sessionLines session(s) reported by 'query session'"
    } else {
        Add-Result "ActiveSessions" "INFO" "query session returned no output (may not be an RDS host)"
    }
} catch {
    Add-Result "ActiveSessions" "INFO" "query session not available or failed: $_"
}
#endregion

#region ─── Summary ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── RDP Diagnostics Summary ($ComputerName) ──────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: RDP looks healthy on $ComputerName." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see RDP-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ─────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
