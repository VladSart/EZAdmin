<#
.SYNOPSIS
    Audits Microsoft Sentinel Logic Apps playbook health: Sentinel's permission on each
    playbook, API connection status for connectors in use, and (optionally) recent
    automation-rule/playbook-trigger outcomes pulled from the SentinelHealth table.

.DESCRIPTION
    Read-only diagnostic script. Does not modify role assignments, connections, or workflows.
    Covers three checks:
      1. Enumerates Logic App ("Microsoft.Logic/workflows") resources in a resource group and
         reports whether the supplied Sentinel service principal object ID has a role
         assignment scoped to each one (a missing assignment is the #1 cause of "playbook
         could not be triggered" errors).
      2. Enumerates API Connection ("Microsoft.Web/connections") resources in the same
         resource group and reports their overall connection status (Connected/Error/etc.) —
         a broken connector auth is invisible from the Sentinel portal.
      3. Optionally queries SentinelHealth (if -WorkspaceId is supplied and the Az.OperationalInsights
         module / Log Analytics query access is available) for recent automation rule run and
         playbook trigger outcomes, to correlate against the above.

    Does NOT and CANNOT check: whether a workflow's internal actions succeeded (that requires
    Logic Apps diagnostics routed to the workspace — see AzureDiagnostics table, documented in
    LogicAppsPlaybooks-A.md), or third-party destination-system health (Teams, ServiceNow, etc.).
    Both are explicitly out of scope and flagged here rather than silently omitted.

.PARAMETER ResourceGroupName
    Resource group containing the Logic App playbooks and their API connections.

.PARAMETER SentinelServicePrincipalObjectId
    Object ID of Microsoft Sentinel's first-party service principal in this tenant. Used to
    check role assignments on each playbook. If omitted, the role-assignment check is skipped
    and only inventory + connection status are reported.

.PARAMETER WorkspaceId
    Log Analytics workspace ID (GUID) backing Microsoft Sentinel. If supplied, queries
    SentinelHealth for automation rule / playbook trigger events in the last 24 hours.

.PARAMETER LookbackHours
    Hours of SentinelHealth history to query. Default 24.

.PARAMETER OutputPath
    CSV export path for the combined playbook inventory + connection status report.
    Default: .\SentinelPlaybookHealth-<timestamp>.csv

.EXAMPLE
    .\Get-SentinelPlaybookHealth.ps1 -ResourceGroupName "rg-soc-automation" `
        -SentinelServicePrincipalObjectId "00000000-0000-0000-0000-000000000000" `
        -WorkspaceId "11111111-1111-1111-1111-111111111111"

.NOTES
    Requires: Az.Accounts, Az.Resources modules (Connect-AzAccount first).
    Optional: Az.OperationalInsights module if -WorkspaceId is supplied.
    Run-as: any account with Reader access to the target resource group is sufficient for
    inventory/connection checks; role-assignment checks require Microsoft.Authorization/
    roleAssignments/read at the scope of each playbook.
    Safe: fully read-only. No New-/Set-/Remove- cmdlets against Logic Apps, connections, or
    role assignments appear anywhere in this script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$SentinelServicePrincipalObjectId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [int]$LookbackHours = 24,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\SentinelPlaybookHealth-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Sentinel playbook health audit for resource group '$ResourceGroupName'"

try {
    $context = Get-AzContext
    if (-not $context) { throw "No active Az context." }
    Write-Status "Connected as $($context.Account.Id) (subscription: $($context.Subscription.Name))" "OK"
}
catch {
    Write-Status "Not connected to Azure. Run Connect-AzAccount first." "ERROR"
    throw
}

if (-not $SentinelServicePrincipalObjectId) {
    Write-Status "No -SentinelServicePrincipalObjectId supplied — role-assignment checks will be skipped." "WARN"
}
if (-not $WorkspaceId) {
    Write-Status "No -WorkspaceId supplied — SentinelHealth correlation will be skipped." "WARN"
}

# ---------------------------------------------------------------------------
# Detect: enumerate Logic Apps (playbooks) and API connections
# ---------------------------------------------------------------------------
Write-Status "Enumerating Logic App resources..."
$logicApps = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Logic/workflows" -ErrorAction SilentlyContinue

if (-not $logicApps -or $logicApps.Count -eq 0) {
    Write-Status "No Logic App resources found in '$ResourceGroupName'. Nothing to audit." "WARN"
    return
}
Write-Status "Found $($logicApps.Count) Logic App resource(s)." "OK"

Write-Status "Enumerating API Connection resources..."
$connections = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Web/connections" -ErrorAction SilentlyContinue
Write-Status "Found $(@($connections).Count) API Connection resource(s)." "OK"

# ---------------------------------------------------------------------------
# Execute: build per-playbook evidence rows
# ---------------------------------------------------------------------------
$results = foreach ($app in $logicApps) {

    $roleGranted = $null
    if ($SentinelServicePrincipalObjectId) {
        try {
            $assignment = Get-AzRoleAssignment -ObjectId $SentinelServicePrincipalObjectId -Scope $app.ResourceId -ErrorAction SilentlyContinue |
                Where-Object { $_.RoleDefinitionName -match "Sentinel|Logic App Contributor" }
            $roleGranted = [bool]$assignment
            if (-not $roleGranted) {
                Write-Status "Playbook '$($app.Name)': no Sentinel role assignment found." "WARN"
            }
        }
        catch {
            Write-Status "Could not check role assignment for '$($app.Name)': $($_.Exception.Message)" "WARN"
        }
    }

    # Logic App enabled/disabled state
    $stateProp = $null
    try {
        $detail = Get-AzResource -ResourceId $app.ResourceId -ExpandProperties -ErrorAction SilentlyContinue
        $stateProp = $detail.Properties.state
        if ($stateProp -and $stateProp -ne "Enabled") {
            Write-Status "Playbook '$($app.Name)' state = $stateProp (not Enabled)." "WARN"
        }
    }
    catch {
        Write-Status "Could not read state for '$($app.Name)': $($_.Exception.Message)" "WARN"
    }

    [PSCustomObject]@{
        CheckType           = "Playbook"
        Name                = $app.Name
        ResourceGroup       = $app.ResourceGroupName
        State               = $stateProp
        SentinelRoleGranted = $roleGranted
        ResourceId          = $app.ResourceId
    }
}

foreach ($conn in @($connections)) {
    $status = $null
    try {
        $detail = Get-AzResource -ResourceId $conn.ResourceId -ExpandProperties -ErrorAction SilentlyContinue
        $status = $detail.Properties.overallStatus
        if ($status -and $status -ne "Connected") {
            Write-Status "API Connection '$($conn.Name)' status = $status." "WARN"
        }
    }
    catch {
        Write-Status "Could not read status for connection '$($conn.Name)': $($_.Exception.Message)" "WARN"
    }

    $results += [PSCustomObject]@{
        CheckType           = "APIConnection"
        Name                = $conn.Name
        ResourceGroup       = $conn.ResourceGroupName
        State               = $status
        SentinelRoleGranted = $null
        ResourceId          = $conn.ResourceId
    }
}

# ---------------------------------------------------------------------------
# Optional: SentinelHealth correlation (requires Log Analytics query access)
# ---------------------------------------------------------------------------
if ($WorkspaceId) {
    Write-Status "Querying SentinelHealth for automation rule / playbook trigger events (last $LookbackHours h)..."
    try {
        $query = @"
SentinelHealth
| where TimeGenerated > ago(${LookbackHours}h)
| where OperationName in ("Automation rule run", "Playbook was triggered")
| project TimeGenerated, OperationName, SentinelResourceName, Status, Description
| order by TimeGenerated desc
"@
        $healthResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
        $healthRows = $healthResults.Results
        Write-Status "Retrieved $($healthRows.Count) SentinelHealth automation event(s)." "OK"

        $failures = $healthRows | Where-Object { $_.Status -eq "Failure" }
        if ($failures.Count -gt 0) {
            Write-Status "$($failures.Count) failure event(s) found — see exported CSV for detail." "WARN"
        }

        $healthRows | Export-Csv -Path ($OutputPath -replace '\.csv$', '-SentinelHealth.csv') -NoTypeInformation
        Write-Status "SentinelHealth events exported to $($OutputPath -replace '\.csv$', '-SentinelHealth.csv')" "OK"
    }
    catch {
        Write-Status "SentinelHealth query failed (feature may not be enabled, or Az.OperationalInsights missing): $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$results | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Status "Playbook/connection inventory exported to $OutputPath" "OK"

$warnCount = @($results | Where-Object { $_.SentinelRoleGranted -eq $false -or ($_.State -and $_.State -notin @("Enabled", "Connected")) }).Count
if ($warnCount -gt 0) {
    Write-Status "$warnCount item(s) flagged for review — see CSV." "WARN"
}
else {
    Write-Status "No inventory-level issues detected. Remember: this script cannot see inside workflow runs — check AzureDiagnostics for that (see LogicAppsPlaybooks-A.md)." "OK"
}

Write-Status "Audit complete." "OK"
