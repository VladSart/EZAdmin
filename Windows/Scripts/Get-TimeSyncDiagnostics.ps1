<#
.SYNOPSIS
    Diagnoses Windows Time (W32Time) sync health — service/trigger state, effective config, policy
    overrides, NTP reachability, and scheduled task health — for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/Time/TimeSync A.md, TimeSync B.md, and
    "Can't sync time.windows.com.md". Walks the dependency stack those runbooks describe
    (hardware RTC -> W32Time service/provider -> MDM/GPO policy -> network/DNS/firewall ->
    external NTP source) and flags the exact failure signatures they call out:
    - Current time source (flags "Local CMOS Clock" — the headline symptom of all three docs)
    - W32Time service state and trigger-start configuration
    - Effective NTP peer configuration and last successful sync time
    - Policy keys under HKLM\SOFTWARE\Policies\Microsoft\W32Time (Intune/GPO override detection)
    - NTP reachability via w32tm stripchart against multiple public NTP hosts (the "ping works,
      NTP doesn't" gotcha — ICMP success proves nothing about UDP/123)
    - DNS resolution of NTP hostnames (isolates network path vs. name resolution failures)
    - Windows Time Synchronization scheduled task health and last-run result
    - Time zone sanity check (rules out "wrong TZ looks like wrong time")
    - AADJ / hybrid join state via dsregcmd (context for which time model applies)

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into TimeSync B.md's Evidence Pack / Escalation section.

    Does NOT cover:
    - Actual remediation (that's TimeSync-B.md Playbooks A-E / TimeSync-A.md Remediation — this
      script only detects and reports)
    - AD DS domain time hierarchy (PDC emulator, NT5DS) — this covers the AADJ/workgroup-style
      model both source runbooks scope to
    - Changing NTP peers or policy — read-only throughout

.PARAMETER NtpTestServers
    List of NTP servers to test reachability against via w32tm stripchart.
    Default: time.windows.com, time.cloudflare.com, time.google.com

.PARAMETER StripchartSamples
    Number of samples per stripchart test. Default 3 (kept low to keep runtime short).

.PARAMETER ExportPath
    Path for CSV export. Default: .\TimeSyncDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-TimeSyncDiagnostics.ps1
    Runs the full triage sweep against the default public NTP servers.

.EXAMPLE
    .\Get-TimeSyncDiagnostics.ps1 -NtpTestServers "ntp.corp.local","time.windows.com" -StripchartSamples 5
    Tests reachability against an internal corporate NTP server as well as the public default.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended (policy registry reads and scheduled task detail need elevation
    on hardened systems)
    Safe: Fully read-only. Does NOT run w32tm /resync, does NOT change peer config, does NOT
    restart the W32Time service.
    Tested on: Windows 10 21H2+, Windows 11 (incl. 25H2), Windows Server 2016+
#>

[CmdletBinding()]
param(
    [string[]]$NtpTestServers = @('time.windows.com', 'time.cloudflare.com', 'time.google.com'),

    [int]$StripchartSamples = 3,

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
Write-Status "Get-TimeSyncDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\TimeSyncDiagnostics-$timestamp.csv"
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
#endregion

#region ─── 1. Join type / management state (context) ─────────────────────────
try {
    $dsreg = dsregcmd /status 2>$null
    $aadJoined = ($dsreg | Select-String 'AzureAdJoined\s*:\s*YES')
    $domainJoined = ($dsreg | Select-String 'DomainJoined\s*:\s*YES')
    if ($aadJoined -and -not $domainJoined) {
        Add-Result "JoinType" "INFO" "Azure AD (Entra) joined, workgroup-style time model applies — no AD DS time hierarchy"
    } elseif ($domainJoined) {
        Add-Result "JoinType" "INFO" "Domain-joined — AD DS time hierarchy (PDC emulator) may apply; this script's scope is the AADJ/workgroup model"
    } else {
        Add-Result "JoinType" "WARN" "Could not determine AADJ/domain state from dsregcmd output"
    }
} catch {
    Add-Result "JoinType" "WARN" "Could not run dsregcmd /status: $_"
}
#endregion

#region ─── 2. Time zone sanity ─────────────────────────────────────────────────
try {
    $tz  = tzutil /g
    $now = Get-Date
    Add-Result "TimeZone" "INFO" "TZ=$tz, local time=$now — confirm this matches the site's expected zone before chasing a sync issue"
} catch {
    Add-Result "TimeZone" "WARN" "Could not query tzutil: $_"
}
#endregion

#region ─── 3. W32Time service + trigger state ──────────────────────────────────
try {
    $svc = Get-Service -Name W32Time -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Add-Result "W32TimeService" "OK" "Running (StartType: $($svc.StartType))"
    } else {
        Add-Result "W32TimeService" "ERROR" "Status: $($svc.Status) — service must be running for sync to occur"
    }
} catch {
    Add-Result "W32TimeService" "ERROR" "Could not query W32Time service: $_"
}
#endregion

#region ─── 4. Current source, status, peers ────────────────────────────────────
try {
    $source = (w32tm /query /source 2>$null) -join ' '
    if ($source -match 'Local CMOS Clock') {
        Add-Result "TimeSource" "ERROR" "Source = Local CMOS Clock — device is free-running, not synced to any NTP source (headline symptom)"
    } elseif ($source) {
        Add-Result "TimeSource" "OK" "Source = $source"
    } else {
        Add-Result "TimeSource" "WARN" "w32tm /query /source returned no output"
    }
} catch {
    Add-Result "TimeSource" "ERROR" "Could not run w32tm /query /source: $_"
}

try {
    $statusRaw = w32tm /query /status 2>$null
    $lastSync  = ($statusRaw | Select-String 'Last Successful Sync Time') -replace 'Last Successful Sync Time:\s*', ''
    if ($lastSync -and $lastSync -notmatch 'unspecified|none') {
        Add-Result "LastSuccessfulSync" "OK" "$lastSync"
    } else {
        Add-Result "LastSuccessfulSync" "WARN" "No recorded last successful sync time — device has never synced or record was reset"
    }
} catch {
    Add-Result "LastSuccessfulSync" "WARN" "Could not run w32tm /query /status: $_"
}

try {
    $peers = (w32tm /query /peers 2>$null) -join ' | '
    if ($peers -and $peers.Trim() -ne '') {
        Add-Result "ConfiguredPeers" "OK" "$peers"
    } else {
        Add-Result "ConfiguredPeers" "WARN" "No peers returned — empty peer list will keep source at Local CMOS Clock"
    }
} catch {
    Add-Result "ConfiguredPeers" "WARN" "Could not run w32tm /query /peers: $_"
}
#endregion

#region ─── 5. Policy overrides (Intune/GPO) ────────────────────────────────────
try {
    $ntpClientPolicy = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\W32Time\TimeProviders\NtpClient" -Name Enabled -ErrorAction Stop
    if ($ntpClientPolicy.Enabled -eq 0) {
        Add-Result "PolicyNtpClientEnabled" "ERROR" "Policy sets NtpClient Enabled=0 — NTP client disabled by MDM/GPO; local fixes will not stick, remediate in Intune"
    } else {
        Add-Result "PolicyNtpClientEnabled" "OK" "Policy NtpClient Enabled=$($ntpClientPolicy.Enabled)"
    }
} catch {
    Add-Result "PolicyNtpClientEnabled" "INFO" "No NtpClient policy key present — not managed by GPO/Intune for this setting (local/default config governs)"
}

try {
    $ntpServerPolicy = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters" -Name NtpServer -ErrorAction Stop
    Add-Result "PolicyNtpServer" "INFO" "Policy enforces NtpServer=$($ntpServerPolicy.NtpServer) — manual peer changes will be overwritten"
} catch {
    Add-Result "PolicyNtpServer" "INFO" "No NtpServer policy key present — peers are not centrally enforced"
}
#endregion

#region ─── 6. DNS resolution of NTP hostnames ──────────────────────────────────
foreach ($srv in $NtpTestServers) {
    try {
        $r = Resolve-DnsName -Name $srv -ErrorAction Stop | Select-Object -First 1
        Add-Result "DNSResolve-$srv" "OK" "Resolved to $($r.IPAddress)"
    } catch {
        Add-Result "DNSResolve-$srv" "ERROR" "Failed to resolve $srv — NTP cannot work without name resolution unless IPs are used: $($_.Exception.Message)"
    }
}
#endregion

#region ─── 7. NTP reachability (stripchart — the money test) ──────────────────
$anyStripchartOk = $false
foreach ($srv in $NtpTestServers) {
    try {
        $out = w32tm /stripchart /computer:$srv /dataonly /samples:$StripchartSamples /packetinfo 2>$null
        $joined = ($out -join ' ')
        if ($joined -match 'error|timed out|could not' -or -not $out) {
            Add-Result "NTPReachability-$srv" "ERROR" "Stripchart failed/timed out against $srv — UDP/123 likely blocked (ICMP working proves nothing here)"
        } else {
            Add-Result "NTPReachability-$srv" "OK" "Stripchart returned offset/delay samples against $srv"
            $anyStripchartOk = $true
        }
    } catch {
        Add-Result "NTPReachability-$srv" "ERROR" "Could not run w32tm stripchart against $srv -- $_"
    }
}

if ($anyStripchartOk -and $lastSync -match 'unspecified|none') {
    Add-Result "StripchartVsResyncMismatch" "WARN" "Stripchart succeeds but no recorded successful resync — classic source-port-123 blocking or policy restriction signature (TimeSync-A.md Playbook B)"
}
#endregion

#region ─── 8. Scheduled task health ────────────────────────────────────────────
$taskNames = @(
    '\Microsoft\Windows\Time Synchronization\SynchronizeTime',
    '\Microsoft\Windows\Time Synchronization\ForceSynchronizeTime'
)
foreach ($t in $taskNames) {
    try {
        $info = schtasks /Query /TN $t /V /FO LIST 2>$null
        if (-not $info) {
            Add-Result "ScheduledTask-$t" "WARN" "Task not found or query failed"
            continue
        }
        $lastResult = ($info | Select-String 'Last Result') -replace '.*:\s*', ''
        $enabled    = ($info | Select-String 'Scheduled Task State') -replace '.*:\s*', ''
        if ($lastResult -and $lastResult.Trim() -ne '0') {
            Add-Result "ScheduledTask-$t" "WARN" "Last Result=$($lastResult.Trim()), State=$($enabled.Trim()) — non-zero result indicates last run failed"
        } else {
            Add-Result "ScheduledTask-$t" "OK" "Last Result=0 (success), State=$($enabled.Trim())"
        }
    } catch {
        Add-Result "ScheduledTask-$t" "WARN" "Could not query task $t -- $_"
    }
}
#endregion

#region ─── 9. UDP 123 local binding check ──────────────────────────────────────
try {
    $portCheck = netstat -ano | Select-String ':123'
    if ($portCheck) {
        Add-Result "UDP123LocalBinding" "INFO" "$($portCheck.Count) local socket entr(ies) referencing port 123 — review for unexpected owning process"
    } else {
        Add-Result "UDP123LocalBinding" "INFO" "No local port 123 entries found in netstat snapshot (normal if W32Time is idle between polls)"
    }
} catch {
    Add-Result "UDP123LocalBinding" "WARN" "Could not run netstat: $_"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Time Sync Diagnostics Summary ──────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Time sync configuration looks healthy on this device." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see TimeSync B.md Playbooks A-E matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
