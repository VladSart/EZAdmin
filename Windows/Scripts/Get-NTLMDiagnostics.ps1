<#
.SYNOPSIS
    Collects NTLM authentication configuration, secure channel status, and recent NTLM events for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/NTLM-B.md and NTLM-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - LAN Manager authentication level (LmCompatibilityLevel) and NTLM min security settings
    - NTLM restriction policy (RestrictSendingNTLMTraffic / RestrictReceivingNTLMTraffic / RestrictNTLMInDomain)
    - NetLogon service state
    - Secure channel health via Test-ComputerSecureChannel and nltest /sc_query
    - DC discovery and reachability on TCP 445/135
    - Recent NTLM operational log entries (client-side, if the log/channel is enabled)
    - Recent Event ID 4776 (credential validation) if run on a DC or with remote log access

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Repairing the secure channel or resetting NTLM policy (that's NTLM-B.md Fix 1-5 / NTLM-A.md Playbooks 1-4 — this script only detects)
    - IIS-side authentication provider order or Extended Protection settings (checked informationally only if run on an IIS box with the WebAdministration module)
    - SPN registration audit (see setspn -L manually; out of scope for this evidence collector)

.PARAMETER DomainController
    Specific DC to test connectivity against. If omitted, discovers the nearest DC automatically.

.PARAMETER IncludeNtlmOperationalLog
    Also queries the Microsoft-Windows-NTLM/Operational log (must be enabled via GPO/auditpol first — often empty by default).

.PARAMETER Event4776LookbackMinutes
    How far back to search for Event ID 4776 (Security log). Only useful when run on/against a DC. Default: 30.

.PARAMETER ExportPath
    Path for CSV export. Default: .\NTLMDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-NTLMDiagnostics.ps1
    Runs the full triage sweep against the auto-discovered nearest DC.

.EXAMPLE
    .\Get-NTLMDiagnostics.ps1 -DomainController dc01.corp.local -IncludeNtlmOperationalLog
    Targets a specific DC and also pulls the NTLM operational log if present.

.NOTES
    Requires: Windows PowerShell 5.1+, machine must be domain-joined
    Run-as: Administrator (required to read Security event log and some Lsa registry keys reliably)
    Safe: Fully read-only. nltest /sc_query is non-destructive (does not reset the channel).
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2016+
#>

[CmdletBinding()]
param(
    [string]$DomainController,

    [switch]$IncludeNtlmOperationalLog,

    [int]$Event4776LookbackMinutes = 30,

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
Write-Status "Get-NTLMDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\NTLMDiagnostics-$timestamp.csv"
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
$domainName     = (Get-CimInstance Win32_ComputerSystem).Domain

if (-not $isDomainJoined) {
    Add-Result "DomainJoinStatus" "ERROR" "This device is not domain-joined — NTLM domain authentication diagnostics do not apply"
}
#endregion

#region ─── 1. LAN Manager auth level ───────────────────────────────────────────
try {
    $lsa = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -ErrorAction Stop
    $lmLevel = $lsa.LmCompatibilityLevel
    if ($null -eq $lmLevel) {
        Add-Result "LmCompatibilityLevel" "WARN" "Not explicitly set — OS default in effect (verify against org baseline)"
    } elseif ($lmLevel -ge 3) {
        Add-Result "LmCompatibilityLevel" "OK" "Level $lmLevel (NTLMv2 enforced)"
    } else {
        Add-Result "LmCompatibilityLevel" "WARN" "Level $lmLevel (legacy — NTLMv1/LM may be sent; consider raising to 3+)"
    }
} catch {
    Add-Result "LmCompatibilityLevel" "WARN" "Could not read LmCompatibilityLevel: $_"
}
#endregion

#region ─── 2. NTLM restriction policy ──────────────────────────────────────────
try {
    $msv1 = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0" -ErrorAction SilentlyContinue
    $netlogonParams = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" -ErrorAction SilentlyContinue

    $restrictSend = $msv1.RestrictSendingNTLMTraffic
    if ($null -eq $restrictSend -or $restrictSend -eq 0) {
        Add-Result "RestrictSendingNTLMTraffic" "OK" "$($restrictSend) — NTLM sending not restricted (0/unset)"
    } elseif ($restrictSend -eq 1) {
        Add-Result "RestrictSendingNTLMTraffic" "WARN" "1 — Audit mode; outgoing NTLM allowed but check exceptions list before assuming full access"
    } else {
        Add-Result "RestrictSendingNTLMTraffic" "WARN" "2 — Outgoing NTLM DENIED to non-exempted servers; likely cause of NTLM auth failures"
    }

    $restrictReceive = $msv1.RestrictReceivingNTLMTraffic
    if ($restrictReceive) {
        Add-Result "RestrictReceivingNTLMTraffic" "WARN" "$restrictReceive — this machine restricts incoming NTLM; check exceptions if it hosts services"
    } else {
        Add-Result "RestrictReceivingNTLMTraffic" "OK" "Not restricted (0/unset)"
    }

    $restrictDomain = $netlogonParams.RestrictNTLMInDomain
    if ($restrictDomain) {
        Add-Result "RestrictNTLMInDomain" "WARN" "$restrictDomain — domain-level NTLM restriction policy active (DC-enforced)"
    } else {
        Add-Result "RestrictNTLMInDomain" "OK" "Not restricted (0/unset)"
    }
} catch {
    Add-Result "NTLMRestrictionPolicy" "WARN" "Could not read NTLM restriction registry values: $_"
}
#endregion

#region ─── 3. NetLogon service ─────────────────────────────────────────────────
try {
    $netlogon = Get-Service -Name Netlogon -ErrorAction Stop
    if ($netlogon.Status -eq 'Running') {
        Add-Result "NetLogonService" "OK" "Running (StartType: $($netlogon.StartType))"
    } else {
        Add-Result "NetLogonService" "ERROR" "Status: $($netlogon.Status) — Kerberos AND NTLM both fail without this"
    }
} catch {
    Add-Result "NetLogonService" "ERROR" "Could not query NetLogon service: $_"
}
#endregion

#region ─── 4. Secure channel health ────────────────────────────────────────────
if ($isDomainJoined) {
    try {
        $scResult = Test-ComputerSecureChannel -ErrorAction Stop
        if ($scResult) {
            Add-Result "SecureChannel" "OK" "Test-ComputerSecureChannel = True"
        } else {
            Add-Result "SecureChannel" "ERROR" "Test-ComputerSecureChannel = False — trust relationship broken; NTLM and Kerberos pass-through will fail"
        }
    } catch {
        Add-Result "SecureChannel" "WARN" "Could not run Test-ComputerSecureChannel: $_"
    }

    try {
        $nltestOutput = & nltest /sc_query:$domainName 2>&1
        $nltestJoined = $nltestOutput -join ' '
        if ($nltestJoined -match 'NERR_Success') {
            Add-Result "NltestSecureChannel" "OK" "nltest /sc_query reports NERR_Success"
        } else {
            Add-Result "NltestSecureChannel" "WARN" "nltest /sc_query did not report success: $nltestJoined"
        }
    } catch {
        Add-Result "NltestSecureChannel" "WARN" "Could not run nltest: $_"
    }
}
#endregion

#region ─── 5. DC discovery and reachability ────────────────────────────────────
if ($isDomainJoined) {
    try {
        if ($DomainController) {
            $dc = $DomainController
        } else {
            $dcQuery = & nltest /dsgetdc:$domainName 2>&1
            $dcLine = $dcQuery | Where-Object { $_ -match '\\\\' } | Select-Object -First 1
            $dc = if ($dcLine) { ($dcLine -replace '.*\\\\', '' -replace '\s.*', '').Trim() } else { $null }
        }

        if ($dc) {
            Add-Result "DCDiscovery" "OK" "Using DC: $dc"
            foreach ($port in @(445, 135)) {
                try {
                    $test = Test-NetConnection -ComputerName $dc -Port $port -WarningAction SilentlyContinue -ErrorAction Stop
                    if ($test.TcpTestSucceeded) {
                        Add-Result "DCPort-$port" "OK" "$dc reachable on TCP $port"
                    } else {
                        Add-Result "DCPort-$port" "ERROR" "$dc NOT reachable on TCP $port — NetLogon pass-through auth will fail"
                    }
                } catch {
                    Add-Result "DCPort-$port" "WARN" "Could not test port $port : $_"
                }
            }
        } else {
            Add-Result "DCDiscovery" "ERROR" "Could not discover a domain controller for $domainName"
        }
    } catch {
        Add-Result "DCDiscovery" "WARN" "Could not run DC discovery: $_"
    }
}
#endregion

#region ─── 6. NTLM operational log (optional) ──────────────────────────────────
if ($IncludeNtlmOperationalLog) {
    try {
        $ntlmEvents = Get-WinEvent -LogName "Microsoft-Windows-NTLM/Operational" -MaxEvents 50 -ErrorAction Stop
        if ($ntlmEvents) {
            $v1Count = ($ntlmEvents | Where-Object { $_.Id -eq 4001 }).Count
            if ($v1Count -gt 0) {
                Add-Result "NTLMOperationalLog" "WARN" "$($ntlmEvents.Count) recent events; $v1Count are Event 4001 (NTLMv1 attempts) — candidates for LM level hardening review"
            } else {
                Add-Result "NTLMOperationalLog" "OK" "$($ntlmEvents.Count) recent events, no NTLMv1 (4001) attempts"
            }
        } else {
            Add-Result "NTLMOperationalLog" "INFO" "Log present but empty"
        }
    } catch {
        Add-Result "NTLMOperationalLog" "INFO" "Log not available or not enabled (enable via 'Network security: Restrict NTLM: Audit NTLM authentication in this domain' GPO): $_"
    }
} else {
    Add-Result "NTLMOperationalLog" "INFO" "Skipped (-IncludeNtlmOperationalLog not specified)"
}
#endregion

#region ─── 7. Event 4776 — credential validation (DC-side) ────────────────────
try {
    $filterParams = @{
        LogName   = 'Security'
        Id        = 4776
        StartTime = (Get-Date).AddMinutes(-$Event4776LookbackMinutes)
    }
    $eventArgs = @{ FilterHashtable = $filterParams; ErrorAction = 'Stop' }
    if ($DomainController) { $eventArgs['ComputerName'] = $DomainController }

    $events4776 = Get-WinEvent @eventArgs
    if ($events4776) {
        $failures = $events4776 | Where-Object { $_.Message -notmatch '0x0\b' }
        if ($failures) {
            Add-Result "Event4776" "WARN" "$($events4776.Count) event(s) in last $Event4776LookbackMinutes min; $($failures.Count) non-success — review SubStatus codes"
        } else {
            Add-Result "Event4776" "OK" "$($events4776.Count) event(s) in last $Event4776LookbackMinutes min, all success"
        }
    } else {
        Add-Result "Event4776" "INFO" "No Event 4776 in last $Event4776LookbackMinutes min (or not run against a DC)"
    }
} catch {
    Add-Result "Event4776" "INFO" "Could not query Event 4776 — normal if not run on/against a DC, or Credential Validation auditing is disabled: $_"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── NTLM Diagnostics Summary ─────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: NTLM configuration and secure channel look healthy on this device." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see NTLM-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
