<#
.SYNOPSIS
    Tenant-wide health audit for Microsoft Entra Global Secure Access (GSA) —
    Traffic Forwarding Profiles, Private Access connector fleet, and published
    application-to-connector-group mappings.

.DESCRIPTION
    Connects to Microsoft Graph (beta) and:
      1. Enumerates Traffic Forwarding Profiles and flags any that are disabled
         (the single most common "GSA isn't doing anything" root cause, and one
         with no client-side error to surface it)
      2. Enumerates Private Access connectors, groups them by Connector Group,
         and flags stale heartbeats / inactive connectors / groups with zero
         healthy connectors (single points of failure)
      3. Enumerates published Private Access applications and cross-references
         each against its assigned Connector Group's health

    Analysis flags applied:
      PROFILE_DISABLED           - A Traffic Forwarding Profile is disabled. Any
                                    traffic in that category passes through
                                    untunneled, indistinguishable from a healthy-
                                    but-unused client from the endpoint's view.
      CONNECTOR_INACTIVE         - Connector Status != active.
      CONNECTOR_STALE_HEARTBEAT  - Connector is active but LastHeartbeat is older
                                    than StaleHeartbeatMinutes — often means the
                                    service is running locally but an outbound
                                    network path to the Entra Network Access
                                    service broke after deployment.
      GROUP_ZERO_HEALTHY         - A Connector Group has no active connectors at
                                    all — every app assigned to it is unreachable.
      GROUP_SINGLE_CONNECTOR     - A Connector Group has exactly one healthy
                                    connector — no failover if it goes down.
      APP_NO_CONNECTOR_GROUP     - A published application has no ConnectorGroupId
                                    assigned — it can never be reached.
      APP_GROUP_UNHEALTHY        - A published application's assigned Connector
                                    Group has zero healthy connectors.

    Read-only. Makes no changes to any profile, connector, or application.

    Does NOT cover:
    - Per-device client health (service state, PRT, operational event log) — must
      be run ON the affected device, see GlobalSecureAccess-A.md Validation Steps
      1, 5, 6
    - Conditional Access "Compliant Network" policy analysis — see
      Security/ConditionalAccess/ for CA-specific tooling
    - DNS/hostname routing correctness for Private DNS-configured apps

.PARAMETER StaleHeartbeatMinutes
    Minutes since last heartbeat before an "active" connector is additionally
    flagged as having a stale heartbeat worth a second look. Default: 10.

.PARAMETER OutputPath
    Directory where CSV reports will be written.
    Default: .\GSA-Health-<timestamp>\

.EXAMPLE
    .\Get-GlobalSecureAccessHealth.ps1

    Full tenant-wide audit of forwarding profiles, connectors, and published apps.

.EXAMPLE
    .\Get-GlobalSecureAccessHealth.ps1 -StaleHeartbeatMinutes 5

    Same audit with a tighter heartbeat staleness threshold for a fresher signal.

.NOTES
    Requires: Microsoft.Graph.Beta PowerShell SDK
              (Install-Module Microsoft.Graph.Beta -Scope CurrentUser)
    Scopes needed: NetworkAccess.Read.All
    Run As: Global Reader, Security Reader, or Global Administrator (read only)
    Safe: Read-only — no forwarding profiles, connectors, or applications are changed
    Cross-references: EntraID/Troubleshooting/GlobalSecureAccess-A.md (Dependency
                       Stack, Symptom -> Cause Map, Validation Steps 2-4),
                       GlobalSecureAccess-B.md (Triage, Fix 2/Fix 3)
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 1440)]
    [int]$StaleHeartbeatMinutes = 10,

    [string]$OutputPath = ".\GSA-Health-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

# --- Connect ---
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph (beta)..." "INFO"
        Connect-MgGraph -Scopes "NetworkAccess.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

if (-not (Get-Command Get-MgBetaNetworkAccessForwardingProfile -EA SilentlyContinue)) {
    Write-Status "Microsoft.Graph.Beta module (NetworkAccess cmdlets) not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Beta -Scope CurrentUser" "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# --- 1. Traffic Forwarding Profiles ---
Write-Status "Retrieving Traffic Forwarding Profiles..." "INFO"
try {
    $profiles = Get-MgBetaNetworkAccessForwardingProfile -EA Stop |
        Select-Object Id, Name, TrafficForwardingType, State
} catch {
    Write-Status "Failed to retrieve forwarding profiles: $($_.Exception.Message)" "ERROR"
    $profiles = @()
}

$profileResults = foreach ($p in $profiles) {
    $flags = if ($p.State -ne "enabled") { "PROFILE_DISABLED" } else { "" }
    [PSCustomObject]@{
        Name    = $p.Name
        Type    = $p.TrafficForwardingType
        State   = $p.State
        Flags   = $flags
    }
}

$disabledProfiles = $profileResults | Where-Object { $_.Flags -ne "" }
Write-Host "`n=== Traffic Forwarding Profiles ===" -ForegroundColor Cyan
$profileResults | Format-Table -AutoSize
if ($disabledProfiles.Count -gt 0) {
    Write-Status "$($disabledProfiles.Count) profile(s) DISABLED — traffic in this category passes untunneled with no client-side error." "WARN"
}

# --- 2. Connector fleet health ---
Write-Status "`nRetrieving Private Access connectors..." "INFO"
try {
    $connectors = Get-MgBetaNetworkAccessConnector -All -EA Stop |
        Select-Object Id, MachineName, Status, Version, LastHeartbeat, @{N = "ConnectorGroupId"; E = { $_.ConnectorGroupId } }
} catch {
    Write-Status "Failed to retrieve connectors: $($_.Exception.Message)" "WARN"
    $connectors = @()
}

$staleCutoff = (Get-Date).ToUniversalTime().AddMinutes(-$StaleHeartbeatMinutes)

$connectorResults = foreach ($c in $connectors) {
    $flags = [System.Collections.Generic.List[string]]::new()
    $isActive = ($c.Status -eq "active")
    if (-not $isActive) { $flags.Add("CONNECTOR_INACTIVE") }

    $heartbeatAge = $null
    if ($c.LastHeartbeat) {
        $heartbeatAge = [math]::Round(((Get-Date).ToUniversalTime() - $c.LastHeartbeat.ToUniversalTime()).TotalMinutes, 1)
        if ($isActive -and $c.LastHeartbeat.ToUniversalTime() -lt $staleCutoff) {
            $flags.Add("CONNECTOR_STALE_HEARTBEAT")
        }
    }

    [PSCustomObject]@{
        MachineName       = $c.MachineName
        Status            = $c.Status
        Version           = $c.Version
        LastHeartbeat     = if ($c.LastHeartbeat) { $c.LastHeartbeat.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
        HeartbeatAgeMins  = if ($null -ne $heartbeatAge) { $heartbeatAge } else { "N/A" }
        ConnectorGroupId  = $c.ConnectorGroupId
        Flags             = ($flags -join "|")
    }
}

Write-Host "`n=== Private Access Connector Fleet ===" -ForegroundColor Cyan
if ($connectorResults.Count -gt 0) {
    $connectorResults | Sort-Object ConnectorGroupId, MachineName | Format-Table -AutoSize
} else {
    Write-Status "No Private Access connectors found (tenant may only use Internet Access, or Private Access is not configured)." "INFO"
}

# --- Group-level rollup ---
$groupRollup = $connectorResults | Group-Object ConnectorGroupId | ForEach-Object {
    $healthyCount = ($_.Group | Where-Object { $_.Status -eq "active" }).Count
    $flags = [System.Collections.Generic.List[string]]::new()
    if ($healthyCount -eq 0) { $flags.Add("GROUP_ZERO_HEALTHY") }
    elseif ($healthyCount -eq 1) { $flags.Add("GROUP_SINGLE_CONNECTOR") }

    [PSCustomObject]@{
        ConnectorGroupId  = $_.Name
        TotalConnectors   = $_.Count
        HealthyConnectors = $healthyCount
        Flags             = ($flags -join "|")
    }
}

if ($groupRollup.Count -gt 0) {
    Write-Host "`n=== Connector Group Rollup ===" -ForegroundColor Cyan
    $groupRollup | Format-Table -AutoSize
    $unhealthyGroups = $groupRollup | Where-Object { $_.Flags -match "GROUP_ZERO_HEALTHY" }
    if ($unhealthyGroups.Count -gt 0) {
        Write-Status "$($unhealthyGroups.Count) connector group(s) have ZERO healthy connectors — every app assigned to these groups is unreachable." "ERROR"
    }
    $singleConnGroups = $groupRollup | Where-Object { $_.Flags -match "GROUP_SINGLE_CONNECTOR" }
    if ($singleConnGroups.Count -gt 0) {
        Write-Status "$($singleConnGroups.Count) connector group(s) have exactly one healthy connector — no failover." "WARN"
    }
}

# --- 3. Published applications ---
Write-Status "`nRetrieving published Private Access applications..." "INFO"
try {
    $apps = Get-MgBetaNetworkAccessApplication -All -EA Stop |
        Select-Object Id, DisplayName, DestinationHost, DestinationPort, Protocol, ConnectorGroupId
} catch {
    Write-Status "Failed to retrieve published applications: $($_.Exception.Message)" "WARN"
    $apps = @()
}

$appResults = foreach ($a in $apps) {
    $flags = [System.Collections.Generic.List[string]]::new()
    if (-not $a.ConnectorGroupId) {
        $flags.Add("APP_NO_CONNECTOR_GROUP")
    } else {
        $matchedGroup = $groupRollup | Where-Object { $_.ConnectorGroupId -eq $a.ConnectorGroupId }
        if (-not $matchedGroup -or $matchedGroup.HealthyConnectors -eq 0) {
            $flags.Add("APP_GROUP_UNHEALTHY")
        }
    }

    [PSCustomObject]@{
        DisplayName      = $a.DisplayName
        DestinationHost  = $a.DestinationHost
        DestinationPort  = $a.DestinationPort
        Protocol         = $a.Protocol
        ConnectorGroupId = $a.ConnectorGroupId
        Flags            = ($flags -join "|")
    }
}

Write-Host "`n=== Published Applications ===" -ForegroundColor Cyan
if ($appResults.Count -gt 0) {
    $appResults | Format-Table -AutoSize
    $unreachableApps = $appResults | Where-Object { $_.Flags -ne "" }
    if ($unreachableApps.Count -gt 0) {
        Write-Status "$($unreachableApps.Count) published application(s) flagged as unreachable or misconfigured." "ERROR"
    }
} else {
    Write-Status "No published Private Access applications found." "INFO"
}

# --- Export ---
$profileResults   | Export-Csv -Path (Join-Path $OutputPath "ForwardingProfiles.csv")   -NoTypeInformation -Encoding UTF8
$connectorResults | Export-Csv -Path (Join-Path $OutputPath "ConnectorHealth.csv")       -NoTypeInformation -Encoding UTF8
$groupRollup      | Export-Csv -Path (Join-Path $OutputPath "ConnectorGroupRollup.csv")  -NoTypeInformation -Encoding UTF8
$appResults       | Export-Csv -Path (Join-Path $OutputPath "PublishedApplications.csv") -NoTypeInformation -Encoding UTF8

Write-Status "`nAll reports exported to: $OutputPath" "OK"
Write-Status "Reminder: forwarding profiles fail SILENTLY on the client — always check that first on any 'GSA isn't doing anything' ticket before chasing connector or app config." "INFO"
