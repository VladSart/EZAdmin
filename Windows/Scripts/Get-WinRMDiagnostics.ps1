<#
.SYNOPSIS
    Collects WinRM/PowerShell Remoting health — service/listener state, firewall, network profile,
    auth path indicators, GPO conflicts, quotas, and CredSSP state — for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/WinRM-B.md and WinRM-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - WinRM service state and configured listeners (HTTP/HTTPS)
    - Firewall rule state per network profile, flagging Public-profile exclusion
    - Current network connection profile
    - Domain-join state (to indicate whether Kerberos or NTLM applies)
    - TrustedHosts contents (client-side NTLM path)
    - GPO-managed WinRM detection (best-effort, via registry policy keys — does not require
      running gpresult, which is slow; flags for manual gpresult review when ambiguous)
    - WSMan quota configuration and current active shell count (orphan/exhaustion detection)
    - CredSSP client/server role state and Encryption Oracle Remediation policy level
    - Optional remote connectivity test against a specified target

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's WinRM-B.md Fix 1-6 / WinRM-A.md Playbooks 1-4 — this
      script only detects)
    - Kerberos delegation configuration (msDS-AllowedToDelegateTo / RBCD) — see
      ActiveDirectory/Scripts/Get-KerberosDelegationAudit.ps1 for that half of the double-hop picture
    - JEA endpoint auditing — out of scope, general Microsoft.PowerShell endpoint only

.PARAMETER TargetComputer
    Optional remote computer name to test connectivity/auth against, in addition to
    auditing the local machine's WinRM configuration. If omitted, only local config is audited.

.PARAMETER Port
    WinRM HTTP port to test reachability on. Default 5985.

.PARAMETER ExportPath
    Path for CSV export. Default: .\WinRMDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-WinRMDiagnostics.ps1
    Audits local WinRM configuration only.

.EXAMPLE
    .\Get-WinRMDiagnostics.ps1 -TargetComputer SERVER01
    Audits local configuration AND tests connectivity/auth against SERVER01.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended (some WSMan config reads and CredSSP registry checks need elevation)
    Safe: Fully read-only. No listener/firewall/quota changes, no CredSSP enable/disable.
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2016+
#>

[CmdletBinding()]
param(
    [string]$TargetComputer,

    [int]$Port = 5985,

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
Write-Status "Get-WinRMDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\WinRMDiagnostics-$timestamp.csv"
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

#region ─── 1. WinRM service state ──────────────────────────────────────────────
try {
    $svc = Get-Service -Name WinRM -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Add-Result "WinRMService" "OK" "Running (StartType: $($svc.StartType))"
    } else {
        Add-Result "WinRMService" "ERROR" "Status: $($svc.Status) — remoting will fail entirely until this is running"
    }
} catch {
    Add-Result "WinRMService" "ERROR" "Could not query WinRM service: $_"
}
#endregion

#region ─── 2. Listeners ────────────────────────────────────────────────────────
try {
    $listenerRaw = winrm enumerate winrm/config/listener 2>&1
    $listenerText = $listenerRaw -join "`n"
    $hasHttp  = $listenerText -match 'Transport\s*=\s*HTTP\b'
    $hasHttps = $listenerText -match 'Transport\s*=\s*HTTPS\b'

    if (-not $hasHttp -and -not $hasHttps) {
        Add-Result "Listeners" "ERROR" "No listeners configured — WinRM service running with nothing to accept connections. Run Enable-PSRemoting (check for GPO conflict first)."
    } else {
        $transports = @()
        if ($hasHttp)  { $transports += "HTTP" }
        if ($hasHttps) { $transports += "HTTPS" }
        Add-Result "Listeners" "OK" "Configured transports: $($transports -join ', ')"
    }
} catch {
    Add-Result "Listeners" "WARN" "Could not enumerate listeners: $_"
}
#endregion

#region ─── 3. Firewall rules vs. active network profile ──────────────────────
try {
    $profile = Get-NetConnectionProfile -ErrorAction Stop | Select-Object -First 1
    $category = if ($profile) { $profile.NetworkCategory } else { "Unknown" }
    Add-Result "NetworkProfile" $(if ($category -eq 'Public') { "WARN" } else { "OK" }) "Active category: $category$(if ($category -eq 'Public') { ' — default WinRM firewall rules do NOT apply on Public profile' })"

    $rules = Get-NetFirewallRule -DisplayName "WinRM*" -ErrorAction Stop
    if ($rules) {
        foreach ($rule in $rules) {
            $appliesToActive = $rule.Profile.ToString() -match $category -or $rule.Profile.ToString() -match 'Any'
            $status = if ($rule.Enabled -eq 'True' -and ($appliesToActive -or $category -eq 'Unknown')) { "OK" }
                      elseif ($rule.Enabled -ne 'True') { "WARN" }
                      else { "WARN" }
            $detail = "Enabled=$($rule.Enabled), Profile=$($rule.Profile)"
            Add-Result "Firewall-$($rule.DisplayName)" $status $detail
        }
    } else {
        Add-Result "Firewall" "ERROR" "No WinRM firewall rules found at all — Enable-PSRemoting likely never run"
    }
} catch {
    Add-Result "Firewall" "WARN" "Could not query firewall/network profile: $_"
}
#endregion

#region ─── 4. Domain join / auth path indicator ───────────────────────────────
if ($isDomainJoined) {
    Add-Result "DomainJoin" "OK" "Domain-joined — Kerberos available for name-based connections to trusted domains"
} else {
    Add-Result "DomainJoin" "INFO" "Not domain-joined (workgroup) — NTLM only; TrustedHosts or HTTPS required for any incoming connection"
}
#endregion

#region ─── 5. TrustedHosts ─────────────────────────────────────────────────────
try {
    $trustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
    if ([string]::IsNullOrWhiteSpace($trustedHosts)) {
        if ($isDomainJoined) {
            Add-Result "TrustedHosts" "INFO" "Empty — fine if all remoting targets are reached via Kerberos (domain-joined, by name). Will block any NTLM-path (by-IP, workgroup, cross-domain) connection."
        } else {
            Add-Result "TrustedHosts" "WARN" "Empty on a non-domain-joined machine — outbound remoting to any target will fail unless HTTPS is used"
        }
    } elseif ($trustedHosts -eq '*') {
        Add-Result "TrustedHosts" "WARN" "Set to wildcard '*' — accepts any host claiming any name over HTTP with no identity verification; scope this down if not intentional (e.g. an isolated lab)"
    } else {
        Add-Result "TrustedHosts" "OK" "Configured: $trustedHosts"
    }
} catch {
    Add-Result "TrustedHosts" "WARN" "Could not read TrustedHosts: $_"
}
#endregion

#region ─── 6. GPO-managed WinRM detection (best-effort, registry-based) ──────
try {
    $gpoPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service"
    if (Test-Path $gpoPolicyPath) {
        $gpoAllowAutoConfig = (Get-ItemProperty -Path $gpoPolicyPath -Name "AllowAutoConfig" -ErrorAction SilentlyContinue).AllowAutoConfig
        if ($null -ne $gpoAllowAutoConfig) {
            Add-Result "GPOManagedWinRM" "WARN" "GPO policy registry key present (AllowAutoConfig=$gpoAllowAutoConfig) — local Enable-PSRemoting/winrm quickconfig changes may be overridden or blocked. Verify with 'gpresult /h report.html' before editing local config."
        } else {
            Add-Result "GPOManagedWinRM" "INFO" "GPO policy key present but AllowAutoConfig not set — partial GPO management possible, review with gpresult"
        }
    } else {
        Add-Result "GPOManagedWinRM" "OK" "No GPO WinRM policy registry key detected — local configuration should be authoritative (not a substitute for gpresult on a machine with unusual OU placement)"
    }
} catch {
    Add-Result "GPOManagedWinRM" "INFO" "Could not check GPO policy registry key: $_"
}
#endregion

#region ─── 7. WSMan quotas and active shell count ─────────────────────────────
try {
    $maxShells = (Get-Item WSMan:\localhost\Shell\MaxShellsPerUser -ErrorAction Stop).Value
    $maxConcurrentOps = (Get-Item WSMan:\localhost\Plugin\Microsoft.PowerShell\Quotas\MaxConcurrentOperationsPerUser -ErrorAction SilentlyContinue).Value
    Add-Result "WSManQuotas" "INFO" "MaxShellsPerUser=$maxShells, MaxConcurrentOperationsPerUser=$maxConcurrentOps"

    try {
        $activeShells = Get-WSManInstance -ResourceURI shell -Enumerate -ErrorAction Stop
        $shellCount = @($activeShells).Count
        if ($maxShells -and $shellCount -ge ([int]$maxShells * 0.8)) {
            Add-Result "ActiveShellCount" "WARN" "$shellCount active shell(s) against a limit of $maxShells — approaching or at quota; check for orphaned sessions from failed automation"
        } else {
            Add-Result "ActiveShellCount" "OK" "$shellCount active shell(s) (limit: $maxShells)"
        }
    } catch {
        Add-Result "ActiveShellCount" "INFO" "No active shells or query failed (expected if nothing is currently connected): $_"
    }
} catch {
    Add-Result "WSManQuotas" "WARN" "Could not read WSMan quota configuration: $_"
}
#endregion

#region ─── 8. CredSSP state ─────────────────────────────────────────────────────
try {
    $credsspClient = Get-Item WSMan:\localhost\Client\Auth\CredSSP -ErrorAction SilentlyContinue
    $credsspServer = Get-Item WSMan:\localhost\Service\Auth\CredSSP -ErrorAction SilentlyContinue
    $clientState = if ($credsspClient) { $credsspClient.Value } else { "Unknown" }
    $serverState = if ($credsspServer) { $credsspServer.Value } else { "Unknown" }

    if ($clientState -eq 'true' -or $serverState -eq 'true') {
        Add-Result "CredSSP" "WARN" "CredSSP enabled — Client=$clientState, Server=$serverState. Confirm this is a documented, time-boxed exception (see WinRM-A.md Playbook 2), not a permanent double-hop workaround."
    } else {
        Add-Result "CredSSP" "OK" "Disabled — Client=$clientState, Server=$serverState"
    }

    $eoRemediation = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters" -Name "AllowEncryptionOracle" -ErrorAction SilentlyContinue
    if ($eoRemediation) {
        $level = switch ($eoRemediation.AllowEncryptionOracle) {
            0 { "Force Updated Clients (secure default)" }
            1 { "Mitigated" }
            2 { "Vulnerable — do not leave set long-term" }
            default { "Unknown value: $($eoRemediation.AllowEncryptionOracle)" }
        }
        $status = if ($eoRemediation.AllowEncryptionOracle -eq 2) { "WARN" } else { "OK" }
        Add-Result "CredSSP-EncryptionOracle" $status $level
    } else {
        Add-Result "CredSSP-EncryptionOracle" "INFO" "Policy not explicitly set — OS default (Force Updated Clients) applies"
    }
} catch {
    Add-Result "CredSSP" "INFO" "Could not fully read CredSSP state: $_"
}
#endregion

#region ─── 9. Optional remote target test ─────────────────────────────────────
if ($TargetComputer) {
    try {
        $portTest = Test-NetConnection -ComputerName $TargetComputer -Port $Port -WarningAction SilentlyContinue -ErrorAction Stop
        if ($portTest.TcpTestSucceeded) {
            Add-Result "TargetPortReachable-$TargetComputer" "OK" "TCP $Port reachable"
        } else {
            Add-Result "TargetPortReachable-$TargetComputer" "ERROR" "TCP $Port NOT reachable — firewall/routing issue, check this before auth troubleshooting"
        }
    } catch {
        Add-Result "TargetPortReachable-$TargetComputer" "ERROR" "Port test failed: $_"
    }

    try {
        $wsmanTest = Test-WSMan -ComputerName $TargetComputer -ErrorAction Stop
        Add-Result "TargetWSManHandshake-$TargetComputer" "OK" "Protocol handshake succeeded ($($wsmanTest.ProductVersion))"
    } catch {
        Add-Result "TargetWSManHandshake-$TargetComputer" "ERROR" "Handshake failed: $($_.Exception.Message) — if the port test above passed, this is an authentication/negotiation problem, not connectivity"
    }
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── WinRM Diagnostics Summary ─────────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: WinRM configuration looks healthy on this device." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see WinRM-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
