<#
.SYNOPSIS
    Audits Power Automate connection health across an environment — flags broken, orphaned, and at-risk connections.

.DESCRIPTION
    Enumerates flows in a Power Platform environment and cross-references the connections they depend
    on against the connection owner's Entra ID account state. Surfaces the failure modes that cause
    "flow suddenly stopped working with no changes" tickets:

    - Connection owner account disabled or deleted
    - Connection owner's sign-in sessions revoked (password reset, admin action, MFA change) since
      the connection was created — the strongest signal of a soon-to-expire refresh token
    - Connections not used/refreshed in 60+ days (approaching the 90-day refresh token expiry)
    - Flows with zero connections resolvable (already orphaned)
    - Single-owner concentration — one account owning connections for many production flows,
      a business-continuity risk if that person leaves

    Read-only. Makes no changes to any flow or connection.

.PARAMETER EnvironmentName
    The Power Platform environment name (GUID). Retrieve via Get-AdminPowerAppEnvironment.

.PARAMETER StaleThresholdDays
    Days since last connection use before flagging as "at risk of token expiry." Default: 60.

.PARAMETER OutputPath
    Path to export CSV reports. Default: C:\Temp\ConnectorAuthHealth-<timestamp>

.EXAMPLE
    .\Get-ConnectorAuthHealth.ps1 -EnvironmentName "Default-<tenantId>"

.EXAMPLE
    # Tighter staleness window for a high-compliance environment
    .\Get-ConnectorAuthHealth.ps1 -EnvironmentName "Default-<tenantId>" -StaleThresholdDays 30

.NOTES
    Requires: Microsoft.PowerApps.Administration.PowerShell, Microsoft.Graph.Users modules
    Install:  Install-Module Microsoft.PowerApps.Administration.PowerShell, Microsoft.Graph.Users -Scope CurrentUser
    Auth:     Add-PowerAppsAccount + Connect-MgGraph -Scopes "User.Read.All"
    Permissions: Power Platform Environment Admin (flows/connections) + Entra ID reader (user status)
    Safe to run repeatedly — read-only.
    Companion runbooks: PowerAutomate/Troubleshooting/Connector-Auth-A.md and Connector-Auth-B.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter()][int]$StaleThresholdDays = 60,
    [Parameter()][string]$OutputPath = "C:\Temp\ConnectorAuthHealth-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $Colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $Colour
}

# ─── Preflight ────────────────────────────────────────────────────────────────

foreach ($Mod in @("Microsoft.PowerApps.Administration.PowerShell", "Microsoft.Graph.Users")) {
    if (-not (Get-Module -ListAvailable -Name $Mod)) {
        Write-Status "$Mod not found. Installing..." "WARN"
        Install-Module $Mod -Scope CurrentUser -Force -AllowClobber
    }
}
Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop
Import-Module Microsoft.Graph.Users -ErrorAction Stop

Write-Status "Authenticating to Power Platform..."
try { Add-PowerAppsAccount } catch { Write-Status "Power Platform auth failed: $_" "ERROR"; exit 1 }

Write-Status "Authenticating to Microsoft Graph..."
try {
    Connect-MgGraph -Scopes "User.Read.All" -NoWelcome -ErrorAction Stop
} catch {
    Write-Status "Graph auth failed: $_" "ERROR"
    exit 1
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# ─── Collect flows and connections ────────────────────────────────────────────

Write-Status "Retrieving flows in environment: $EnvironmentName"
$Flows = @(Get-AdminFlow -EnvironmentName $EnvironmentName -ErrorAction SilentlyContinue)

if ($Flows.Count -eq 0) {
    Write-Status "No flows found in environment $EnvironmentName." "WARN"
    exit 0
}
Write-Status "Found $($Flows.Count) flow(s)." "OK"

Write-Status "Retrieving connections in environment..."
$Connections = @(Get-AdminPowerAppConnection -EnvironmentName $EnvironmentName -ErrorAction SilentlyContinue)
Write-Status "Found $($Connections.Count) connection(s)." "OK"

# ─── Resolve connection owner account state (cache lookups to avoid throttling) ──

$UserCache = @{}
function Get-CachedUser {
    param([string]$Upn)
    if (-not $Upn) { return $null }
    if ($UserCache.ContainsKey($Upn)) { return $UserCache[$Upn] }
    try {
        $U = Get-MgUser -UserId $Upn -Property "displayName,accountEnabled,signInSessionsValidFromDateTime" -ErrorAction Stop
    } catch {
        $U = $null
    }
    $UserCache[$Upn] = $U
    return $U
}

$ConnectionReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$OwnerFlowCounts   = @{}

foreach ($Conn in $Connections) {

    $OwnerUpn = $Conn.CreatedBy.userPrincipalName
    $LastMod  = if ($Conn.LastModifiedTime) { [datetime]$Conn.LastModifiedTime } else { $null }
    $DaysSinceUse = if ($LastMod) { [int]((Get-Date) - $LastMod).TotalDays } else { $null }

    $OwnerInfo = Get-CachedUser -Upn $OwnerUpn

    $AccountStatus = if (-not $OwnerUpn) { "Unknown owner" }
                     elseif (-not $OwnerInfo) { "ACCOUNT NOT FOUND (deleted?)" }
                     elseif (-not $OwnerInfo.AccountEnabled) { "DISABLED" }
                     else { "Enabled" }

    $RiskFlags = [System.Collections.Generic.List[string]]::new()
    if ($AccountStatus -match "NOT FOUND|DISABLED") { $RiskFlags.Add("Owner account inactive") }
    if ($DaysSinceUse -and $DaysSinceUse -ge $StaleThresholdDays) { $RiskFlags.Add("Stale >$StaleThresholdDays days") }
    if ($OwnerInfo -and $OwnerInfo.SignInSessionsValidFromDateTime -and $LastMod -and
        ([datetime]$OwnerInfo.SignInSessionsValidFromDateTime) -gt $LastMod) {
        $RiskFlags.Add("Sessions revoked after connection created — token likely invalid")
    }

    $Status = if ($RiskFlags.Count -gt 0) { "WARN" } else { "OK" }
    if ($AccountStatus -match "NOT FOUND|DISABLED") { $Status = "ERROR" }

    $ConnectionReport.Add([PSCustomObject]@{
        ConnectionName   = $Conn.DisplayName
        Connector        = $Conn.ConnectorName
        Owner            = $OwnerUpn
        OwnerAccountState = $AccountStatus
        LastModified     = $LastMod
        DaysSinceUse     = $DaysSinceUse
        RiskFlags        = ($RiskFlags -join "; ")
        Status           = $Status
    })

    if ($OwnerUpn) {
        if (-not $OwnerFlowCounts.ContainsKey($OwnerUpn)) { $OwnerFlowCounts[$OwnerUpn] = 0 }
        $OwnerFlowCounts[$OwnerUpn]++
    }
}

# ─── Orphaned flows (flow references a connection that no longer resolves) ────

Write-Status "Checking for flows with unresolvable connection references..."
$OrphanedFlows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Flow in $Flows) {
    try {
        $FlowConnections = (Get-AdminFlow -FlowName $Flow.FlowName -EnvironmentName $EnvironmentName -ErrorAction Stop).Internal.properties.connectionReferences
        if ($FlowConnections) {
            $RefIds = $FlowConnections.PSObject.Properties.Value.connection.id
            foreach ($RefId in $RefIds) {
                $Match = $Connections | Where-Object { $Conn.ConnectionName -eq $RefId }
                if (-not $Match) {
                    $OrphanedFlows.Add([PSCustomObject]@{
                        FlowName        = $Flow.DisplayName
                        FlowId          = $Flow.FlowName
                        MissingConnRefId = $RefId
                    })
                }
            }
        }
    } catch {
        # Some flow objects don't expose connectionReferences via this property path — skip silently
    }
}

# ─── Concentration risk ───────────────────────────────────────────────────────

$ConcentrationRisk = $OwnerFlowCounts.GetEnumerator() |
    Where-Object { $_.Value -ge 5 } |
    Sort-Object Value -Descending |
    ForEach-Object { [PSCustomObject]@{ Owner = $_.Key; ConnectionsOwned = $_.Value } }

# ─── Report ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== CONNECTOR AUTH HEALTH REPORT ===" -ForegroundColor Magenta
Write-Status "Environment:          $EnvironmentName"
Write-Status "Flows:                $($Flows.Count)"
Write-Status "Connections audited:  $($Connections.Count)"

$ErrorConns = $ConnectionReport | Where-Object Status -eq "ERROR"
$WarnConns  = $ConnectionReport | Where-Object Status -eq "WARN"

if ($ErrorConns.Count -gt 0) {
    Write-Status "`nCONNECTIONS WITH INACTIVE OWNER ACCOUNTS: $($ErrorConns.Count)" "ERROR"
    $ErrorConns | Format-Table ConnectionName, Connector, Owner, OwnerAccountState -AutoSize
} else {
    Write-Status "No connections owned by disabled/deleted accounts." "OK"
}

if ($WarnConns.Count -gt 0) {
    Write-Status "`nAt-risk connections (stale or session-revoked): $($WarnConns.Count)" "WARN"
    $WarnConns | Format-Table ConnectionName, Connector, Owner, DaysSinceUse, RiskFlags -AutoSize -Wrap
}

if ($OrphanedFlows.Count -gt 0) {
    Write-Status "`nFlows with unresolvable connection references: $($OrphanedFlows.Count)" "ERROR"
    $OrphanedFlows | Format-Table -AutoSize
} else {
    Write-Status "No orphaned connection references detected." "OK"
}

if ($ConcentrationRisk) {
    Write-Status "`nOwnership concentration risk (5+ connections owned by one account):" "WARN"
    $ConcentrationRisk | Format-Table -AutoSize
    Write-Status "Recommend migrating shared/production flows to a dedicated service account. See Connector-Auth-B.md Fix 4." "WARN"
}

# ─── Export ────────────────────────────────────────────────────────────────────

$ConnectionReport  | Export-Csv "$OutputPath\connection-health.csv"    -NoTypeInformation -Encoding UTF8
$OrphanedFlows     | Export-Csv "$OutputPath\orphaned-flows.csv"       -NoTypeInformation -Encoding UTF8
$ConcentrationRisk | Export-Csv "$OutputPath\ownership-concentration.csv" -NoTypeInformation -Encoding UTF8

Write-Status "`nReports exported to: $OutputPath" "OK"
Write-Status "Done." "OK"
