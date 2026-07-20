<#
.SYNOPSIS
    Audits a Windows Server DHCP Server role installation for common
    server-side failure conditions.

.DESCRIPTION
    Read-only diagnostic script for the DHCP-Server-A.md and DHCP-Server-B.md
    runbooks. Run directly on the DHCP server (or against it remotely with
    -ComputerName, where the underlying cmdlet supports it) since several
    checks depend on the local DhcpServer PowerShell module and local
    filesystem access to audit logs.

    Covers:
      1. Role/service state and AD authorization
      2. Scope inventory, state, and utilization (flags near-exhaustion)
      3. Superscope inventory
      4. DHCP Failover relationship health (state, MCLT, mode)
      5. DHCP Policy inventory (conditional option assignment)
      6. Secure dynamic DNS update credential validity (password expiry/lockout)
      7. Database/service event log scan for JET/corruption indicators
      8. Audit log configuration and freshness check

    Does NOT modify any DHCP configuration, does NOT test actual client-side
    leasing end-to-end (that requires a real client on the target subnet),
    and does NOT evaluate DHCP Policy condition syntax against live traffic
    (only reports configured conditions — matching behavior requires a
    packet capture or live test).

.PARAMETER ComputerName
    DHCP server to audit. Default: localhost (most checks require running
    directly on the server; remote support varies by cmdlet).

.PARAMETER ExhaustionThresholdPercent
    Scope utilization percentage at or above which a WARN finding is raised.
    Default: 85.

.PARAMETER OutputPath
    Folder to write CSV output to. Default: current directory.

.EXAMPLE
    .\Get-DHCPServerHealth.ps1
    Runs a standard local audit with default 85% exhaustion threshold.

.EXAMPLE
    .\Get-DHCPServerHealth.ps1 -ExhaustionThresholdPercent 90 -OutputPath C:\DHCP-Audit
    Runs an audit flagging scopes at 90%+ utilization, output to C:\DHCP-Audit.

.NOTES
    Requires: DhcpServer PowerShell module (installed automatically with the
    DHCP Server role, or via RSAT-DHCP for remote management). Active
    Directory module recommended (optional) for the DNS credential
    password-expiry check. Run-as: local Administrator on the DHCP server.
    Safe: read-only, no configuration changes are made.
#>

[CmdletBinding()]
param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [int]$ExhaustionThresholdPercent = 85,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$findings = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param([string]$Category, [string]$Flag, [string]$Detail, [string]$Severity = "INFO")
    $findings.Add([PSCustomObject]@{
        Category = $Category
        Flag     = $Flag
        Severity = $Severity
        Detail   = $Detail
    })
}

# ─── Preflight ────────────────────────────────────────────────────────────
Write-Status "Starting DHCP Server health audit against '$ComputerName'..." "INFO"

$dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
if ($ComputerName -eq $env:COMPUTERNAME -and (-not $dhcpFeature -or $dhcpFeature.InstallState -ne "Installed")) {
    Add-Finding "Preflight" "DHCP_ROLE_NOT_INSTALLED" "DHCP Server role is not installed on this local machine. Re-run with -ComputerName pointed at the actual DHCP server, or run this script directly on it." "ERROR"
    Write-Status "DHCP role not installed locally — aborting further local-only checks." "ERROR"
    $findings | Export-Csv -Path (Join-Path $OutputPath "DHCPServerHealth-$stamp.csv") -NoTypeInformation
    return
}
Write-Status "DHCP Server role presence confirmed." "OK"

# ─── 1. Service state and AD authorization ─────────────────────────────────
Write-Status "Checking DHCPServer service state..." "INFO"
try {
    $svc = Get-Service -Name DHCPServer -ErrorAction Stop
    if ($svc.Status -ne "Running") {
        Add-Finding "Service" "DHCP_SERVICE_NOT_RUNNING" "DHCP Server service is in state '$($svc.Status)'. No leasing can occur while stopped." "ERROR"
    } else {
        Add-Finding "Service" "DHCP_SERVICE_RUNNING" "DHCP Server service is running." "OK"
    }
    if ($svc.StartType -ne "Automatic") {
        Add-Finding "Service" "DHCP_STARTUP_NOT_AUTOMATIC" "DHCPServer StartType is '$($svc.StartType)' rather than Automatic — a reboot may not bring DHCP back online." "WARN"
    }
} catch {
    Add-Finding "Service" "DHCP_SERVICE_CHECK_FAILED" "Could not query DHCPServer service: $($_.Exception.Message)" "WARN"
}

Write-Status "Checking AD authorization..." "INFO"
try {
    $authorized = Get-DhcpServerInDC -ErrorAction Stop
    $thisServerAuthorized = $authorized | Where-Object { $_.DnsName -match [regex]::Escape($ComputerName) }
    if (-not $thisServerAuthorized) {
        Add-Finding "Authorization" "SERVER_NOT_AUTHORIZED" "This server does not appear in Get-DhcpServerInDC output. An unauthorized Windows DHCP server silently ignores every DHCPDISCOVER it receives — no error, no event." "ERROR"
    } else {
        Add-Finding "Authorization" "SERVER_AUTHORIZED" "Server is authorized in Active Directory." "OK"
    }
} catch {
    Add-Finding "Authorization" "AUTHORIZATION_CHECK_FAILED" "Could not query Get-DhcpServerInDC: $($_.Exception.Message)" "WARN"
}

# ─── 2. Scope inventory, state, and utilization ────────────────────────────
Write-Status "Inventorying scopes and checking utilization..." "INFO"
try {
    $scopes = Get-DhcpServerv4Scope -ComputerName $ComputerName -ErrorAction Stop
    if (-not $scopes -or $scopes.Count -eq 0) {
        Add-Finding "Scopes" "NO_SCOPES_CONFIGURED" "No IPv4 scopes are configured on this server." "WARN"
    } else {
        $scopes | Select-Object ScopeId, Name, State, StartRange, EndRange, LeaseDuration |
            Export-Csv -Path (Join-Path $OutputPath "Scopes-$stamp.csv") -NoTypeInformation

        $inactive = $scopes | Where-Object { $_.State -ne "Active" }
        foreach ($i in $inactive) {
            Add-Finding "Scopes" "SCOPE_INACTIVE" "Scope '$($i.Name)' ($($i.ScopeId)) is in state '$($i.State)' — it will not lease any addresses while inactive." "WARN"
        }

        $scopeStats = @()
        foreach ($s in $scopes) {
            try {
                $stat = Get-DhcpServerv4ScopeStatistics -ComputerName $ComputerName -ScopeId $s.ScopeId -ErrorAction Stop
                $scopeStats += $stat
                if ($stat.PercentageInUse -ge $ExhaustionThresholdPercent) {
                    Add-Finding "Scopes" "SCOPE_NEAR_EXHAUSTION" "Scope '$($s.Name)' ($($s.ScopeId)) is at $([math]::Round($stat.PercentageInUse,1))% utilization (threshold: $ExhaustionThresholdPercent%). Free: $($stat.Free), InUse: $($stat.InUse)." "WARN"
                }
            } catch {
                Add-Finding "Scopes" "SCOPE_STATS_QUERY_FAILED" "Could not get statistics for scope $($s.ScopeId): $($_.Exception.Message)" "WARN"
            }
        }
        $scopeStats | Select-Object ScopeId, Free, InUse, Reserved, PercentageInUse |
            Export-Csv -Path (Join-Path $OutputPath "ScopeStatistics-$stamp.csv") -NoTypeInformation

        Add-Finding "Scopes" "SCOPE_COUNT" "$($scopes.Count) scope(s) found, $($inactive.Count) inactive." "OK"
    }
} catch {
    Add-Finding "Scopes" "SCOPE_QUERY_FAILED" "Could not query scopes: $($_.Exception.Message)" "WARN"
}

# ─── 3. Superscope inventory ────────────────────────────────────────────────
Write-Status "Checking for superscopes..." "INFO"
try {
    $superscopes = Get-DhcpServerv4Superscope -ComputerName $ComputerName -ErrorAction SilentlyContinue
    if ($superscopes -and $superscopes.Count -gt 0) {
        $superscopes | Export-Csv -Path (Join-Path $OutputPath "Superscopes-$stamp.csv") -NoTypeInformation
        Add-Finding "Superscopes" "SUPERSCOPES_FOUND" "$($superscopes.Count) superscope(s) configured. Remember: superscopes do not auto-balance exhaustion between member scopes without matching relay/router config." "INFO"
    } else {
        Add-Finding "Superscopes" "NO_SUPERSCOPES" "No superscopes configured." "INFO"
    }
} catch {
    Add-Finding "Superscopes" "SUPERSCOPE_CHECK_FAILED" "Could not query superscopes: $($_.Exception.Message)" "WARN"
}

# ─── 4. DHCP Failover relationship health ───────────────────────────────────
Write-Status "Checking DHCP Failover relationships..." "INFO"
try {
    $failovers = Get-DhcpServerv4Failover -ComputerName $ComputerName -ErrorAction SilentlyContinue
    if ($failovers -and $failovers.Count -gt 0) {
        $failovers | Select-Object Name, ScopeId, PartnerServer, Mode, State, LoadBalancePercent, MaxClientLeadTime |
            Export-Csv -Path (Join-Path $OutputPath "Failover-$stamp.csv") -NoTypeInformation

        foreach ($f in $failovers) {
            if ($f.State -eq "PartnerDown") {
                Add-Finding "Failover" "FAILOVER_PARTNER_DOWN" "Relationship '$($f.Name)' with partner '$($f.PartnerServer)' is in state PartnerDown — this server is serving the scope alone, bounded by MaxClientLeadTime ($($f.MaxClientLeadTime)). Verify whether the partner outage is expected/known." "WARN"
            } elseif ($f.State -eq "CommunicationInterrupted") {
                Add-Finding "Failover" "FAILOVER_COMM_INTERRUPTED" "Relationship '$($f.Name)' with partner '$($f.PartnerServer)' shows CommunicationInterrupted — sync channel (default TCP 647) may be blocked. Neither side has declared failure yet, but this needs investigation." "WARN"
            } elseif ($f.State -ne "Normal") {
                Add-Finding "Failover" "FAILOVER_NON_NORMAL_STATE" "Relationship '$($f.Name)' is in state '$($f.State)' (not Normal)." "INFO"
            }
        }
        Add-Finding "Failover" "FAILOVER_RELATIONSHIP_COUNT" "$($failovers.Count) failover relationship(s) found." "OK"
    } else {
        Add-Finding "Failover" "NO_FAILOVER_CONFIGURED" "No DHCP Failover relationships configured. Scopes on this server have no automatic high-availability partner — confirm this is intentional (e.g., branch office standalone) rather than an oversight." "INFO"
    }
} catch {
    Add-Finding "Failover" "FAILOVER_CHECK_FAILED" "Could not query DHCP Failover: $($_.Exception.Message)" "WARN"
}

# ─── 5. DHCP Policies ────────────────────────────────────────────────────────
Write-Status "Checking DHCP Policies..." "INFO"
try {
    $policies = Get-DhcpServerv4Policy -ComputerName $ComputerName -ErrorAction SilentlyContinue
    if ($policies -and $policies.Count -gt 0) {
        $policies | Select-Object Name, Enabled, ProcessingOrder, Condition |
            Export-Csv -Path (Join-Path $OutputPath "Policies-$stamp.csv") -NoTypeInformation
        $disabledPolicies = $policies | Where-Object { -not $_.Enabled }
        Add-Finding "Policies" "POLICY_COUNT" "$($policies.Count) DHCP Policy(ies) found, $($disabledPolicies.Count) disabled." "OK"
    } else {
        Add-Finding "Policies" "NO_POLICIES" "No DHCP Policies configured (conditional option assignment by vendor class/MAC/user class not in use on this server)." "INFO"
    }
} catch {
    Add-Finding "Policies" "POLICY_CHECK_FAILED" "Could not query DHCP Policies: $($_.Exception.Message)" "WARN"
}

# ─── 6. Secure dynamic DNS update credential ────────────────────────────────
Write-Status "Checking DNS dynamic update credential..." "INFO"
try {
    $dnsCred = Get-DhcpServerDnsCredential -ComputerName $ComputerName -ErrorAction Stop
    if ($dnsCred -and $dnsCred.UserName) {
        Add-Finding "DnsCredential" "DNS_CREDENTIAL_CONFIGURED" "Dynamic DNS update credential configured: $($dnsCred.DomainName)\$($dnsCred.UserName)." "INFO"
        if (Get-Command Get-ADUser -ErrorAction SilentlyContinue) {
            try {
                $adAccount = Get-ADUser -Identity $dnsCred.UserName -Properties PasswordExpired, Enabled, LockedOut -ErrorAction Stop
                if ($adAccount.PasswordExpired) {
                    Add-Finding "DnsCredential" "DNS_CREDENTIAL_PASSWORD_EXPIRED" "The DNS update account '$($dnsCred.UserName)' has an EXPIRED password. DHCP leasing continues normally, but dynamic DNS registration for new/renewed leases is silently failing." "ERROR"
                }
                if (-not $adAccount.Enabled) {
                    Add-Finding "DnsCredential" "DNS_CREDENTIAL_DISABLED" "The DNS update account '$($dnsCred.UserName)' is DISABLED in AD." "ERROR"
                }
                if ($adAccount.LockedOut) {
                    Add-Finding "DnsCredential" "DNS_CREDENTIAL_LOCKED" "The DNS update account '$($dnsCred.UserName)' is LOCKED OUT." "ERROR"
                }
                if (-not $adAccount.PasswordExpired -and $adAccount.Enabled -and -not $adAccount.LockedOut) {
                    Add-Finding "DnsCredential" "DNS_CREDENTIAL_HEALTHY" "DNS update account password not expired, enabled, not locked out." "OK"
                }
            } catch {
                Add-Finding "DnsCredential" "DNS_CREDENTIAL_AD_LOOKUP_FAILED" "Could not look up AD account '$($dnsCred.UserName)' for expiry/lockout state: $($_.Exception.Message)" "WARN"
            }
        } else {
            Add-Finding "DnsCredential" "AD_MODULE_UNAVAILABLE" "ActiveDirectory PowerShell module not available — could not verify DNS credential account password expiry/lockout state directly. Verify manually." "WARN"
        }
    } else {
        Add-Finding "DnsCredential" "NO_DNS_CREDENTIAL_SET" "No explicit dynamic DNS update credential configured — server is using its own computer account for secure updates. In a Failover pair, confirm the partner uses the same identity or records may become cross-server unmodifiable." "INFO"
    }
} catch {
    Add-Finding "DnsCredential" "DNS_CREDENTIAL_CHECK_FAILED" "Could not query Get-DhcpServerDnsCredential: $($_.Exception.Message)" "WARN"
}

# ─── 7. Database/service event log scan ─────────────────────────────────────
Write-Status "Scanning event log for DHCP Server errors (last 7 days)..." "INFO"
try {
    $since = (Get-Date).AddDays(-7)
    $events = Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "Microsoft-Windows-DHCP-Server"; Level = 1,2,3; StartTime = $since } -ErrorAction SilentlyContinue
    if ($events) {
        $events | Select-Object TimeCreated, Id, LevelDisplayName, Message |
            Export-Csv -Path (Join-Path $OutputPath "DhcpServerEvents-$stamp.csv") -NoTypeInformation
        $jetErrors = $events | Where-Object { $_.Message -match "jet|database|corrupt" }
        if ($jetErrors) {
            Add-Finding "Database" "POSSIBLE_DATABASE_CORRUPTION" "$($jetErrors.Count) event(s) in the last 7 days reference JET/database/corruption terms. Review DhcpServerEvents-$stamp.csv before assuming a config-only fault." "ERROR"
        }
        Add-Finding "Database" "EVENT_LOG_ERRORS_FOUND" "$($events.Count) Error/Warning/Critical DHCP-Server event(s) in the last 7 days." "WARN"
    } else {
        Add-Finding "Database" "NO_RECENT_EVENT_ERRORS" "No Error/Warning/Critical DHCP-Server events in the last 7 days." "OK"
    }
} catch {
    Add-Finding "Database" "EVENT_LOG_QUERY_FAILED" "Could not query System event log for DHCP-Server events: $($_.Exception.Message)" "WARN"
}

# ─── 8. Audit log configuration and freshness ───────────────────────────────
Write-Status "Checking DHCP audit log configuration..." "INFO"
try {
    $auditCfg = Get-DhcpServerAuditLog -ComputerName $ComputerName -ErrorAction Stop
    if (-not $auditCfg.Enable) {
        Add-Finding "AuditLog" "AUDIT_LOGGING_DISABLED" "DHCP Server audit logging is disabled — per-lease transaction history (DISCOVER/OFFER/REQUEST/ACK/NAK) will not be available for future troubleshooting." "WARN"
    } else {
        Add-Finding "AuditLog" "AUDIT_LOGGING_ENABLED" "DHCP Server audit logging is enabled. Log path: $($auditCfg.Path)." "OK"
        if ($ComputerName -eq $env:COMPUTERNAME) {
            $todayLog = Join-Path $auditCfg.Path "DhcpSrvLog-$(Get-Date -Format ddd).log"
            if (Test-Path $todayLog) {
                $logInfo = Get-Item $todayLog
                Add-Finding "AuditLog" "AUDIT_LOG_FRESHNESS" "Today's audit log ($todayLog) last written $($logInfo.LastWriteTime), size $([math]::Round($logInfo.Length/1KB,1)) KB." "INFO"
            } else {
                Add-Finding "AuditLog" "AUDIT_LOG_FILE_NOT_FOUND" "Expected today's audit log file not found at $todayLog despite audit logging being enabled." "WARN"
            }
        }
    }
} catch {
    Add-Finding "AuditLog" "AUDIT_LOG_CHECK_FAILED" "Could not query Get-DhcpServerAuditLog: $($_.Exception.Message)" "WARN"
}

# ─── Report ─────────────────────────────────────────────────────────────
$reportPath = Join-Path $OutputPath "DHCPServerHealth-$stamp.csv"
$findings | Export-Csv -Path $reportPath -NoTypeInformation

Write-Status "Audit complete. $($findings.Count) finding(s) recorded." "INFO"
$errorCount = ($findings | Where-Object { $_.Severity -eq "ERROR" }).Count
$warnCount  = ($findings | Where-Object { $_.Severity -eq "WARN" }).Count
Write-Status "$errorCount error-level, $warnCount warning-level finding(s)." $(if ($errorCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })
Write-Status "Full report: $reportPath" "INFO"

$findings | Format-Table -AutoSize
