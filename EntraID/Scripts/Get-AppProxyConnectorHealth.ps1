<#
.SYNOPSIS
    Fleet-wide Entra Application Proxy connector health check — service state,
    version drift, connectivity, and portal registration status in one pass.

.DESCRIPTION
    Runs against one or more Application Proxy connector servers (locally or via
    PSRemoting) and cross-references each connector's local state against its
    registration status in Entra ID, per AppProxy-B.md's Triage table and
    AppProxy-A.md's Validation Steps 1-5:
    - Connector service + updater service state (Stopped = offline, per Fix 1)
    - Installed connector version, flagged if more than ~90 days old (version
      drift — AppProxy-A.md Validation Step 2 / Remediation Playbook 4)
    - Outbound connectivity to the required Microsoft endpoints on :443
      (login.microsoftonline.com, proxy.cloudwebappproxy.net,
      servicebus.windows.net, graph.microsoft.com) — a single failed endpoint
      here explains most "connector shows Inactive" tickets per Fix 3
    - System clock drift vs. w32tm, since >300s skew silently breaks
      Kerberos/token validation per AppProxy-B.md Fix 4
    - Cross-checks each server's registration status via Graph
      (onPremisesPublishingProfiles/applicationProxy/connectors) so an operator
      can immediately see "service is Running locally but portal shows
      Inactive" as a network/registration problem rather than a service problem

    This is a read-only diagnostic tool — it makes no changes to any service,
    registration, or configuration. Exports full results to CSV.

    Does NOT cover:
    - KCD/SPN delegation validation — see AppProxy-B.md Fix 5 / AppProxy-A.md
      Playbook 2 (requires AD tools and a specific backend app context this
      script has no way to infer automatically)
    - Per-app pre-authentication or SSO configuration — see AppProxy-A.md
      Symptom → Cause Map for app-level (not connector-level) issues
    - Remote connector servers that are unreachable via WinRM — for those,
      run this script locally on the connector instead

.PARAMETER ConnectorServer
    One or more connector server hostnames to check remotely via PSRemoting.
    If omitted, checks the local machine only (assumes it IS a connector server).

.PARAMETER VersionDriftDays
    Number of days since connector version install date before flagging as
    stale/drifted. Default: 90.

.PARAMETER SkipGraphCheck
    Skip the Graph API cross-reference of portal registration status — use
    this if Microsoft.Graph modules or Application.Read.All consent are not
    available in this context, to still get local service/connectivity data.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\AppProxyConnectorHealth-<timestamp>.csv

.EXAMPLE
    .\Get-AppProxyConnectorHealth.ps1

    Checks the local machine as a connector server, including Graph
    cross-reference of portal registration status.

.EXAMPLE
    .\Get-AppProxyConnectorHealth.ps1 -ConnectorServer "proxy01","proxy02" -VersionDriftDays 60

    Checks two remote connector servers via PSRemoting, flags any connector
    version older than 60 days.

.NOTES
    Requires (local checks): none beyond built-in Windows cmdlets
    Requires (remote checks): PSRemoting enabled on target connector servers
    Requires (Graph check): Microsoft.Graph.Applications PowerShell SDK module
    Scopes needed: Application.Read.All (or OnPremisesPublishingProfiles.Read.All)
    Run As: Local admin on connector server(s) for service/event log queries
    Safe: Read-only — no services restarted, no registrations changed
    Cross-references: EntraID/Troubleshooting/AppProxy-B.md (Triage, Fix 1-5)
                       and AppProxy-A.md (Validation Steps 1-5)
#>

[CmdletBinding()]
param(
    [string[]]$ConnectorServer,

    [int]$VersionDriftDays = 90,

    [switch]$SkipGraphCheck,

    [string]$OutputPath = ".\AppProxyConnectorHealth-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

$requiredEndpoints = @(
    "login.microsoftonline.com",
    "proxy.cloudwebappproxy.net",
    "servicebus.windows.net",
    "graph.microsoft.com"
)

# ---- The block that runs on each connector server (local or remote) ----
$localCheckBlock = {
    param($Endpoints, $DriftDays)

    $svc = Get-Service -Name "WAPCSvc","ApplicationProxyConnectorService" -ErrorAction SilentlyContinue
    $updaterSvc = Get-Service -Name "WAPCUpdaterSvc","ApplicationProxyConnectorUpdaterService" -ErrorAction SilentlyContinue

    $versionInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft AAD App Proxy Connector" -ErrorAction SilentlyContinue

    $versionAgeDays = $null
    $versionDrifted = $false
    if ($versionInfo -and $versionInfo.InstallDate) {
        try {
            $installDate = [datetime]::ParseExact($versionInfo.InstallDate, "yyyyMMdd", $null)
            $versionAgeDays = (New-TimeSpan -Start $installDate -End (Get-Date)).Days
            $versionDrifted = $versionAgeDays -gt $DriftDays
        }
        catch {
            # InstallDate format varies by OS/installer version; leave age unknown rather than fail the run
        }
    }

    $connectivity = foreach ($ep in $Endpoints) {
        $r = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
        [PSCustomObject]@{ Endpoint = $ep; TcpSuccess = $r.TcpTestSucceeded }
    }
    $connectivityFailures = ($connectivity | Where-Object { -not $_.TcpSuccess }).Endpoint -join ";"

    $clockDriftSeconds = $null
    try {
        $timeStatus = w32tm /query /status 2>$null
        $lastSync = ($timeStatus | Select-String "Last Successful Sync Time" | ForEach-Object { $_.ToString().Split(":", 2)[1].Trim() })
        if ($lastSync) {
            $clockDriftSeconds = [Math]::Abs(([datetime]::UtcNow - [datetime]$lastSync).TotalSeconds)
        }
    }
    catch {
        # w32tm parsing is best-effort; leave null if unavailable
    }

    [PSCustomObject]@{
        ComputerName          = $env:COMPUTERNAME
        ConnectorServiceState = if ($svc) { $svc[0].Status } else { "NOT FOUND" }
        UpdaterServiceState   = if ($updaterSvc) { $updaterSvc[0].Status } else { "NOT FOUND" }
        ConnectorVersion      = if ($versionInfo) { $versionInfo.Version } else { "UNKNOWN" }
        VersionAgeDays        = $versionAgeDays
        VersionDrifted        = $versionDrifted
        ConnectivityFailures  = $connectivityFailures
        ClockDriftSeconds     = $clockDriftSeconds
        ClockDriftFlag        = if ($clockDriftSeconds -ne $null -and $clockDriftSeconds -gt 300) { $true } else { $false }
    }
}

$localResults = [System.Collections.Generic.List[object]]::new()

if ($ConnectorServer) {
    foreach ($server in $ConnectorServer) {
        Write-Status "Checking connector server '$server' via PSRemoting..." "INFO"
        try {
            $r = Invoke-Command -ComputerName $server -ScriptBlock $localCheckBlock -ArgumentList $requiredEndpoints, $VersionDriftDays -ErrorAction Stop
            $localResults.Add($r)
            Write-Status "$server — connector service: $($r.ConnectorServiceState)" $(if ($r.ConnectorServiceState -eq "Running") { "OK" } else { "ERROR" })
        }
        catch {
            Write-Status "Failed to reach '$server' via PSRemoting: $($_.Exception.Message)" "ERROR"
            $localResults.Add([PSCustomObject]@{
                ComputerName          = $server
                ConnectorServiceState = "UNREACHABLE"
                UpdaterServiceState   = "UNREACHABLE"
                ConnectorVersion      = "UNKNOWN"
                VersionAgeDays        = $null
                VersionDrifted        = $false
                ConnectivityFailures  = "N/A - unreachable"
                ClockDriftSeconds     = $null
                ClockDriftFlag        = $false
            })
        }
    }
}
else {
    Write-Status "No -ConnectorServer specified; checking local machine as connector server..." "INFO"
    $r = & $localCheckBlock -Endpoints $requiredEndpoints -DriftDays $VersionDriftDays
    $localResults.Add($r)
    Write-Status "Local — connector service: $($r.ConnectorServiceState)" $(if ($r.ConnectorServiceState -eq "Running") { "OK" } else { "ERROR" })
}

# ---- Cross-reference against Graph portal registration status ----
$portalConnectors = @()
if (-not $SkipGraphCheck) {
    Write-Status "Checking portal registration status via Microsoft Graph..." "INFO"
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
        Write-Status "Microsoft.Graph.Applications module not found. Skipping portal cross-reference. Install with: Install-Module Microsoft.Graph.Applications -Scope CurrentUser" "WARN"
    }
    else {
        try {
            $context = Get-MgContext
            if (-not $context) {
                Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome
            }
            $uri = "https://graph.microsoft.com/beta/onPremisesPublishingProfiles/applicationProxy/connectors"
            $portalConnectors = (Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop).value
            Write-Status "Retrieved $($portalConnectors.Count) connector registration(s) from Entra ID." "OK"
        }
        catch {
            Write-Status "Failed to query Graph for connector registrations: $($_.Exception.Message)" "WARN"
        }
    }
}
else {
    Write-Status "Skipping Graph cross-reference (-SkipGraphCheck specified)." "INFO"
}

# ---- Merge local + portal view ----
$finalResults = foreach ($local in $localResults) {
    $portalMatch = $portalConnectors | Where-Object { $_.machineName -match $local.ComputerName }
    $portalStatus = if ($portalMatch) { $portalMatch.status } elseif ($portalConnectors.Count -gt 0) { "NOT FOUND IN PORTAL" } else { "NOT CHECKED" }

    $mismatch = ($local.ConnectorServiceState -eq "Running") -and ($portalStatus -eq "inactive")

    [PSCustomObject]@{
        ComputerName          = $local.ComputerName
        ConnectorServiceState = $local.ConnectorServiceState
        UpdaterServiceState   = $local.UpdaterServiceState
        PortalStatus          = $portalStatus
        LocalVsPortalMismatch = $mismatch
        ConnectorVersion      = $local.ConnectorVersion
        VersionAgeDays        = $local.VersionAgeDays
        VersionDrifted        = $local.VersionDrifted
        ConnectivityFailures  = $local.ConnectivityFailures
        ClockDriftSeconds     = $local.ClockDriftSeconds
        ClockDriftFlag        = $local.ClockDriftFlag
    }
}

# ---- Report ----
Write-Host ""
Write-Host "=== Application Proxy Connector Health Summary ===" -ForegroundColor Cyan
$down = ($finalResults | Where-Object { $_.ConnectorServiceState -ne "Running" }).Count
$drifted = ($finalResults | Where-Object { $_.VersionDrifted }).Count
$connFail = ($finalResults | Where-Object { $_.ConnectivityFailures -and $_.ConnectivityFailures -ne "" -and $_.ConnectivityFailures -ne "N/A - unreachable" }).Count
$clockIssues = ($finalResults | Where-Object { $_.ClockDriftFlag }).Count
$mismatches = ($finalResults | Where-Object { $_.LocalVsPortalMismatch }).Count

Write-Status "$($finalResults.Count) connector server(s) checked." "INFO"
Write-Status "$down connector(s) not in Running state." $(if ($down -gt 0) { "ERROR" } else { "OK" })
Write-Status "$drifted connector(s) with version older than $VersionDriftDays days." $(if ($drifted -gt 0) { "WARN" } else { "OK" })
Write-Status "$connFail connector(s) with at least one failed required endpoint." $(if ($connFail -gt 0) { "ERROR" } else { "OK" })
Write-Status "$clockIssues connector(s) with clock drift exceeding 300 seconds." $(if ($clockIssues -gt 0) { "ERROR" } else { "OK" })
Write-Status "$mismatches connector(s) where local service is Running but portal shows Inactive (likely network/registration issue, not a service issue)." $(if ($mismatches -gt 0) { "WARN" } else { "OK" })
Write-Host ""

$finalResults | Format-Table ComputerName, ConnectorServiceState, PortalStatus, LocalVsPortalMismatch, VersionDrifted, ConnectivityFailures, ClockDriftFlag -AutoSize

$finalResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to $OutputPath" "OK"
