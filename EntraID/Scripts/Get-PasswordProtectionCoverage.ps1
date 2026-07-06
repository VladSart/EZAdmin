<#
.SYNOPSIS
    Fleet-wide Password Protection DC Agent coverage check across every
    writable domain controller, plus Proxy health and recent sign-in lockout
    volume.

.DESCRIPTION
    Implements the fleet-wide version of PasswordProtection-A.md's Validation
    Step 2 (which shows the per-DC loop inline) as a standalone, exportable
    script, plus additional signal pulled from the same runbook set:
    - Enumerates every writable domain controller via AD and checks whether
      AzureADPasswordProtectionDCAgent is installed and Running on each one —
      per PasswordProtection-A.md's Learning Pointers, a DC agent gap is "a
      silent, permanent gap, not a temporary one," most commonly introduced
      when a DC is promoted, rebuilt, or restored from an older backup
    - Checks AzureADPasswordProtectionProxy service state on any server where
      it's found (best-effort discovery — Proxy servers aren't enumerable
      from AD the way DCs are, so this checks a caller-supplied list)
    - Pulls recent Smart Lockout sign-in failures (error code 50053) tenant-
      wide via Graph to give a fleet-level view of lockout volume, rather than
      the runbook's default one-user-at-a-time triage
    - Flags any DC where the agent is missing entirely as HIGH severity (a
      standing enforcement gap) vs. installed-but-stopped as MEDIUM (likely
      recoverable with a service restart per PasswordProtection-B.md Fix 3)

    Read-only for the DC/Proxy checks (queries services only, no restarts) and
    read-only for the Graph sign-in query. Exports full results to CSV.

    Does NOT cover:
    - Reading current tenant lockout threshold/duration or Audit-vs-Enforced
      mode — no Graph API exposes these settings as of 2026; both remain
      portal-only checks per PasswordProtection-B.md Triage item 3
    - Custom banned password list contents — portal-only, no read API
    - Password writeback failure detail — lives in Entra Connect Health, not
      queryable via this script; see PasswordProtection-A.md Validation Step 4

.PARAMETER ProxyServer
    One or more Password Protection Proxy server hostnames to check via
    PSRemoting. Proxy servers cannot be auto-discovered from AD, so this must
    be supplied explicitly. If omitted, Proxy health is skipped.

.PARAMETER LockoutLookbackHours
    How many hours back to search sign-in logs for Smart Lockout (error
    50053) events. Default: 24.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\PasswordProtectionCoverage-<timestamp>.csv

.EXAMPLE
    .\Get-PasswordProtectionCoverage.ps1

    Checks DC Agent coverage across every writable DC in the current domain
    and pulls the last 24 hours of tenant-wide Smart Lockout events.

.EXAMPLE
    .\Get-PasswordProtectionCoverage.ps1 -ProxyServer "pwdproxy01" -LockoutLookbackHours 72

    Also checks a named Proxy server and widens the lockout lookback to 3 days.

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT) for DC enumeration,
              Microsoft.Graph.Reports or Microsoft.Graph.Identity.SignIns for
              sign-in log query
    Scopes needed: AuditLog.Read.All, Directory.Read.All
    Run As: Domain account with rights to query AD DCs remotely (WinRM) and
            local admin on Proxy server(s) if checking Proxy health; Graph
            portion needs Reports Reader or Global Reader role
    Safe: Read-only — no services restarted, no agents installed/removed
    Cross-references: EntraID/Troubleshooting/PasswordProtection-B.md (Triage,
                       Fix 3) and PasswordProtection-A.md (Validation Steps
                       2-3, Remediation Playbook — Deploy DC Agent)
#>

[CmdletBinding()]
param(
    [string[]]$ProxyServer,

    [int]$LockoutLookbackHours = 24,

    [string]$OutputPath = ".\PasswordProtectionCoverage-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

$dcResults = [System.Collections.Generic.List[object]]::new()
$proxyResults = [System.Collections.Generic.List[object]]::new()

# ---- Detect: DC Agent coverage across every writable DC ----
Write-Status "Checking ActiveDirectory module for DC enumeration..." "INFO"
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found. Cannot enumerate DCs. Install RSAT AD tools to use this check." "ERROR"
}
else {
    try {
        $dcs = Get-ADDomainController -Filter * -ErrorAction Stop | Select-Object -ExpandProperty HostName
        Write-Status "Found $($dcs.Count) domain controller(s). Checking DC Agent on each..." "INFO"

        foreach ($dc in $dcs) {
            try {
                $svc = Invoke-Command -ComputerName $dc -ScriptBlock {
                    Get-Service -Name "AzureADPasswordProtectionDCAgent" -ErrorAction SilentlyContinue |
                        Select-Object Name, Status, StartType
                } -ErrorAction Stop

                if (-not $svc) {
                    $dcResults.Add([PSCustomObject]@{
                        DomainController = $dc
                        AgentInstalled   = $false
                        AgentStatus      = "NOT INSTALLED"
                        Severity         = "HIGH"
                    })
                    Write-Status "$dc — DC Agent NOT INSTALLED (standing enforcement gap)" "ERROR"
                }
                else {
                    $severity = if ($svc.Status -eq "Running") { "NONE" } else { "MEDIUM" }
                    $dcResults.Add([PSCustomObject]@{
                        DomainController = $dc
                        AgentInstalled   = $true
                        AgentStatus      = $svc.Status
                        Severity         = $severity
                    })
                    Write-Status "$dc — DC Agent status: $($svc.Status)" $(if ($svc.Status -eq "Running") { "OK" } else { "WARN" })
                }
            }
            catch {
                $dcResults.Add([PSCustomObject]@{
                    DomainController = $dc
                    AgentInstalled   = "UNKNOWN"
                    AgentStatus      = "UNREACHABLE"
                    Severity         = "UNKNOWN"
                })
                Write-Status "$dc — unreachable via PSRemoting: $($_.Exception.Message)" "WARN"
            }
        }
    }
    catch {
        Write-Status "Failed to enumerate domain controllers: $($_.Exception.Message)" "ERROR"
    }
}

# ---- Detect: Proxy health (caller-supplied server list only) ----
if ($ProxyServer) {
    Write-Status "Checking Password Protection Proxy service on supplied server(s)..." "INFO"
    foreach ($px in $ProxyServer) {
        try {
            $svc = Invoke-Command -ComputerName $px -ScriptBlock {
                Get-Service -Name "AzureADPasswordProtectionProxy" -ErrorAction SilentlyContinue |
                    Select-Object Name, Status, StartType
            } -ErrorAction Stop

            $proxyResults.Add([PSCustomObject]@{
                ProxyServer = $px
                ProxyStatus = if ($svc) { $svc.Status } else { "NOT INSTALLED" }
            })
            Write-Status "$px — Proxy status: $(if ($svc) { $svc.Status } else { 'NOT INSTALLED' })" $(if ($svc -and $svc.Status -eq "Running") { "OK" } else { "ERROR" })
        }
        catch {
            $proxyResults.Add([PSCustomObject]@{ ProxyServer = $px; ProxyStatus = "UNREACHABLE" })
            Write-Status "$px — unreachable via PSRemoting: $($_.Exception.Message)" "WARN"
        }
    }
}
else {
    Write-Status "No -ProxyServer specified; skipping Proxy health check." "INFO"
}

# ---- Detect: tenant-wide Smart Lockout volume via sign-in logs ----
Write-Status "Checking Smart Lockout (error 50053) volume over the last $LockoutLookbackHours hour(s)..." "INFO"
$lockoutEvents = @()
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Reports) -and -not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.SignIns)) {
    Write-Status "No Microsoft.Graph sign-in log module found. Skipping tenant-wide lockout volume check." "WARN"
}
else {
    try {
        $context = Get-MgContext
        if (-not $context) {
            Connect-MgGraph -Scopes "AuditLog.Read.All", "Directory.Read.All" -NoWelcome
        }
        $sinceUtc = (Get-Date).ToUniversalTime().AddHours(-$LockoutLookbackHours).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $filter = "status/errorCode eq 50053 and createdDateTime ge $sinceUtc"
        $lockoutEvents = Get-MgAuditLogSignIn -Filter $filter -All -ErrorAction Stop
        Write-Status "$($lockoutEvents.Count) Smart Lockout event(s) tenant-wide in the last $LockoutLookbackHours hour(s)." $(if ($lockoutEvents.Count -gt 20) { "WARN" } else { "OK" })
    }
    catch {
        Write-Status "Failed to query sign-in logs: $($_.Exception.Message)" "WARN"
    }
}

$lockoutByUser = $lockoutEvents | Group-Object UserPrincipalName | Sort-Object Count -Descending |
    Select-Object @{N = "UserPrincipalName"; E = { $_.Name } }, Count

# ---- Report ----
Write-Host ""
Write-Host "=== Password Protection Coverage Summary ===" -ForegroundColor Cyan
$missingAgents = ($dcResults | Where-Object { $_.Severity -eq "HIGH" }).Count
$stoppedAgents = ($dcResults | Where-Object { $_.Severity -eq "MEDIUM" }).Count
$proxyDown = ($proxyResults | Where-Object { $_.ProxyStatus -ne "Running" }).Count

Write-Status "$($dcResults.Count) domain controller(s) checked." "INFO"
Write-Status "$missingAgents DC(s) missing the Password Protection DC Agent entirely (standing enforcement gap)." $(if ($missingAgents -gt 0) { "ERROR" } else { "OK" })
Write-Status "$stoppedAgents DC(s) have the agent installed but not Running." $(if ($stoppedAgents -gt 0) { "WARN" } else { "OK" })
if ($ProxyServer) {
    Write-Status "$proxyDown of $($proxyResults.Count) checked Proxy server(s) not Running." $(if ($proxyDown -gt 0) { "ERROR" } else { "OK" })
}
if ($lockoutByUser.Count -gt 0) {
    Write-Status "Top locked-out users in the lookback window (check for stale credential retry storms per PasswordProtection-B.md Fix 4):" "INFO"
    $lockoutByUser | Select-Object -First 5 | Format-Table -AutoSize
}
Write-Host ""

$dcResults | Format-Table DomainController, AgentInstalled, AgentStatus, Severity -AutoSize
if ($proxyResults.Count -gt 0) { $proxyResults | Format-Table -AutoSize }

$exportData = [PSCustomObject]@{
    DCAgentResults   = $dcResults
    ProxyResults     = $proxyResults
    LockoutByUser    = $lockoutByUser
}
$dcResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
if ($proxyResults.Count -gt 0) {
    $proxyPath = $OutputPath -replace "\.csv$", "-Proxy.csv"
    $proxyResults | Export-Csv -Path $proxyPath -NoTypeInformation -Encoding UTF8
}
if ($lockoutByUser.Count -gt 0) {
    $lockoutPath = $OutputPath -replace "\.csv$", "-LockoutByUser.csv"
    $lockoutByUser | Export-Csv -Path $lockoutPath -NoTypeInformation -Encoding UTF8
}
Write-Status "Full results exported to $OutputPath (plus companion files for Proxy/lockout data where applicable)" "OK"
