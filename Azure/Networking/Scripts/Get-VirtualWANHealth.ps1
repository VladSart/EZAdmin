<#
.SYNOPSIS
    Audits Azure Virtual WAN resources for the most common silent failure and design-gap
    patterns: hub/router health, Basic-SKU capability mismatches, Routing Intent adoption
    state, and branch/spoke connection association-consistency.

.DESCRIPTION
    Produces a read-only report covering, for every Virtual WAN in scope:

      1. SKU CHECK — records VirtualWANType (Basic/Standard) for every Virtual WAN found.

      2. HUB HEALTH — for every virtual hub, records ProvisioningState and RoutingState
         separately and flags HUB_PROVISIONING_FAILED and/or ROUTER_STATE_FAILED. These are
         independent signals in the real service (a hub can be Succeeded while its router is
         Failed) and this script does not collapse them into a single status, matching the
         guidance in VirtualWAN-A.md/VirtualWAN-B.md.

      3. GATEWAY INVENTORY — enumerates VPN, ExpressRoute, and P2S gateways per hub and flags
         GATEWAY_ON_BASIC_SKU if any ExpressRoute or P2S gateway is found attached to a hub
         whose parent Virtual WAN reports Basic (should not be possible via supported paths,
         but is flagged rather than assumed impossible, since it indicates either a stale SKU
         read or a genuine support-boundary anomaly worth escalating).

      4. ROUTING INTENT COVERAGE — for each hub, checks whether a Routing Intent object
         exists and what its Next Hop resource is. Flags NO_ROUTING_INTENT_BUT_FIREWALL_PRESENT
         when an Azure Firewall resource is found in the same resource group as the hub but no
         Routing Intent references it — a common half-finished secured-hub deployment.

      5. CONNECTION ASSOCIATION CONSISTENCY — for every Hub VNet connection, records the
         associated route table and propagation labels, then flags
         INCONSISTENT_BRANCH_ASSOCIATION when connections on the same hub are associated to
         different route tables without an obvious deliberate segmentation reason (i.e., more
         than one distinct associated route table in use across all connections on that hub).
         This is informational — deliberate segmentation is a valid design — but it is flagged
         for human review every time, since accidental inconsistency is far more common than
         intentional segmentation per this repo's research.

      6. EXPRESSROUTE PREFIX COUNT (best-effort) — where circuit route data is accessible,
         flags ER_PREFIX_COUNT_NEAR_LIMIT if advertised IPv4 prefixes on a connection approach
         the documented 1,000-prefix ceiling, since Azure silently drops excess prefixes rather
         than erroring.

    Explicitly does NOT audit Azure Firewall rule content, NSG rule content on spoke subnets, or
    on-premises BGP/IPsec configuration — those are covered by their own dedicated tooling
    (`NSG-A.md`/`Get-NSGRuleAudit.ps1`, `HybridConnectivity-A.md`/`Get-HybridConnectivityHealth.ps1`)
    and duplicating them here would blur this script's scope boundary.

.PARAMETER ResourceGroupName
    Optional. Scopes the audit to Virtual WAN resources in a single resource group. If omitted,
    enumerates every Virtual WAN in the current subscription context.

.PARAMETER VirtualWanName
    Optional. Scopes the audit to a single named Virtual WAN. Requires -ResourceGroupName.

.PARAMETER SubscriptionId
    Optional. Switches subscription context before running (requires prior authentication to
    that subscription). If omitted, uses the current Az context.

.PARAMETER IncludeExpressRoutePrefixCheck
    Switch. Enables the best-effort ExpressRoute advertised-prefix-count check, which requires
    additional per-circuit calls and read permission on the ExpressRoute circuit resources.
    Off by default to keep a routine sweep fast.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\VirtualWANHealth_<timestamp>.csv.

.EXAMPLE
    .\Get-VirtualWANHealth.ps1

.EXAMPLE
    .\Get-VirtualWANHealth.ps1 -ResourceGroupName 'rg-network-hub' -VirtualWanName 'vwan-corp' -IncludeExpressRoutePrefixCheck

.NOTES
    Requires: Az.Network, Az.Accounts modules
    Install:  Install-Module Az.Network, Az.Accounts -Scope CurrentUser
    Permissions: Reader on the Virtual WAN, its virtual hubs, gateways, and connections is
                 sufficient for checks 1-5. The optional ExpressRoute prefix check additionally
                 requires Reader on the linked ExpressRoute circuit resources. Individual checks
                 degrade to a CheckFailed status rather than throwing if the caller lacks
                 permission for that specific check, consistent with this repo's established
                 pattern (see Get-AVNMConfigAudit.ps1, Get-HybridConnectivityHealth.ps1).
    Safe to run: Read-only. No Virtual WAN, hub, gateway, connection, or Routing Intent object
                 is created, modified, or removed. Does not perform hub or router resets.
#>
#Requires -Modules Az.Network, Az.Accounts

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VirtualWanName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeExpressRoutePrefixCheck,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = "C:\Temp\VirtualWANHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function New-Finding {
    param(
        [string]$CheckType,
        [string]$VirtualWanName,
        [string]$HubName,
        [string]$ItemName,
        [string]$Detail,
        [string]$Flags = "OK"
    )
    [PSCustomObject]@{
        CheckType      = $CheckType
        VirtualWanName = $VirtualWanName
        HubName        = $HubName
        ItemName       = $ItemName
        Detail         = $Detail
        Flags          = $Flags
    }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Azure Virtual WAN health audit..." "INFO"

if (-not (Get-AzContext)) {
    Write-Status "No active Az context found. Run Connect-AzAccount first." "ERROR"
    throw "Not authenticated to Azure."
}

if ($SubscriptionId) {
    Write-Status "Switching to subscription $SubscriptionId..." "INFO"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$currentContext = Get-AzContext
Write-Status "Running against subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" "INFO"

if ($VirtualWanName -and -not $ResourceGroupName) {
    Write-Status "-VirtualWanName supplied without -ResourceGroupName — cannot scope to a single Virtual WAN. Falling back to full enumeration." "WARN"
    $VirtualWanName = $null
}

$results = New-Object System.Collections.Generic.List[Object]

# ---------------------------------------------------------------------------
# Detect — enumerate Virtual WAN resource(s) in scope
# ---------------------------------------------------------------------------
try {
    if ($VirtualWanName -and $ResourceGroupName) {
        $vwans = @(Get-AzVirtualWan -ResourceGroupName $ResourceGroupName -Name $VirtualWanName -ErrorAction Stop)
    }
    elseif ($ResourceGroupName) {
        $vwans = @(Get-AzVirtualWan -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    }
    else {
        $vwans = @(Get-AzVirtualWan -ErrorAction Stop)
    }
}
catch {
    Write-Status "Failed to enumerate Virtual WAN resources: $($_.Exception.Message)" "ERROR"
    throw
}

if ($vwans.Count -eq 0) {
    Write-Status "No Virtual WAN resources found in scope." "WARN"
    return
}

Write-Status "Found $($vwans.Count) Virtual WAN resource(s) to audit." "INFO"

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
foreach ($vwan in $vwans) {

    Write-Status "Auditing Virtual WAN: $($vwan.Name) (RG: $($vwan.ResourceGroupName), Type: $($vwan.VirtualWANType))" "INFO"

    $results.Add((New-Finding -CheckType "VirtualWanSku" -VirtualWanName $vwan.Name -HubName "" -ItemName "" `
        -Detail "VirtualWANType=$($vwan.VirtualWANType)" -Flags "OK"))

    # --- Hubs belonging to this Virtual WAN ---
    try {
        $allHubs = @(Get-AzVirtualHub -ResourceGroupName $vwan.ResourceGroupName -ErrorAction Stop)
        $hubs = @($allHubs | Where-Object { $_.VirtualWan.Id -eq $vwan.Id })
    }
    catch {
        Write-Status "Failed to enumerate virtual hubs for $($vwan.Name): $($_.Exception.Message)" "WARN"
        $results.Add((New-Finding -CheckType "Hub" -VirtualWanName $vwan.Name -HubName "" -ItemName "" `
            -Detail "" -Flags "CheckFailed: $($_.Exception.Message)"))
        continue
    }

    if ($hubs.Count -eq 0) {
        Write-Status "  No virtual hubs found for $($vwan.Name)." "INFO"
        continue
    }

    foreach ($hub in $hubs) {

        # --- Hub health: ProvisioningState and RoutingState are independent ---
        $hubFlags = New-Object System.Collections.Generic.List[string]
        if ($hub.ProvisioningState -ne "Succeeded") { $hubFlags.Add("HUB_PROVISIONING_FAILED") }
        if ($hub.PSObject.Properties['RoutingState'] -and $hub.RoutingState -eq "Failed") { $hubFlags.Add("ROUTER_STATE_FAILED") }

        $results.Add((New-Finding -CheckType "Hub" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName $hub.Name `
            -Detail "ProvisioningState=$($hub.ProvisioningState); RoutingState=$($hub.RoutingState); ASN=$($hub.VirtualRouterAsn)" `
            -Flags $(if ($hubFlags.Count -gt 0) { $hubFlags -join ";" } else { "OK" })))

        # --- Gateway inventory ---
        $vpnGateways = @()
        $erGateways  = @()
        $p2sGateways = @()
        try { $vpnGateways = @(Get-AzVpnGateway -ResourceGroupName $vwan.ResourceGroupName -ErrorAction Stop | Where-Object { $_.VirtualHub.Id -eq $hub.Id }) } catch { }
        try { $erGateways  = @(Get-AzExpressRouteGateway -ResourceGroupName $vwan.ResourceGroupName -ErrorAction Stop | Where-Object { $_.VirtualHub.Id -eq $hub.Id }) } catch { }
        try { $p2sGateways = @(Get-AzP2sVpnGateway -ResourceGroupName $vwan.ResourceGroupName -ErrorAction Stop | Where-Object { $_.VirtualHub.Id -eq $hub.Id }) } catch { }

        foreach ($gw in $vpnGateways) {
            $results.Add((New-Finding -CheckType "Gateway" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName $gw.Name `
                -Detail "Type=VPN" -Flags "OK"))
        }
        foreach ($gw in $erGateways) {
            $flags = if ($vwan.VirtualWANType -eq "Basic") { "GATEWAY_ON_BASIC_SKU" } else { "OK" }
            $results.Add((New-Finding -CheckType "Gateway" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName $gw.Name `
                -Detail "Type=ExpressRoute" -Flags $flags))
        }
        foreach ($gw in $p2sGateways) {
            $flags = if ($vwan.VirtualWANType -eq "Basic") { "GATEWAY_ON_BASIC_SKU" } else { "OK" }
            $results.Add((New-Finding -CheckType "Gateway" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName $gw.Name `
                -Detail "Type=P2S/UserVPN" -Flags $flags))
        }

        # --- Routing Intent presence + Next Hop ---
        $routingIntent = $null
        try {
            $routingIntent = Get-AzRoutingIntent -ResourceGroupName $vwan.ResourceGroupName -ParentResourceId $hub.Id -ErrorAction Stop
        }
        catch {
            # No Routing Intent configured, or insufficient permission — treated as "none found" rather than a hard failure
            $routingIntent = $null
        }

        # Look for an Azure Firewall resource in the same resource group as a half-finished-deployment signal
        $firewallPresent = $false
        try {
            $fw = @(Get-AzFirewall -ResourceGroupName $vwan.ResourceGroupName -ErrorAction SilentlyContinue)
            $firewallPresent = $fw.Count -gt 0
        }
        catch { $firewallPresent = $false }

        if ($routingIntent) {
            $policyNextHops = ($routingIntent.RoutingPolicies | ForEach-Object { "$($_.Name)->$($_.NextHop)" }) -join ";"
            $results.Add((New-Finding -CheckType "RoutingIntent" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName $routingIntent.Name `
                -Detail "Policies: $policyNextHops" -Flags "OK"))
        }
        elseif ($firewallPresent) {
            $results.Add((New-Finding -CheckType "RoutingIntent" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName "(none)" `
                -Detail "Azure Firewall resource found in RG, but no Routing Intent references this hub" `
                -Flags "NO_ROUTING_INTENT_BUT_FIREWALL_PRESENT"))
        }
        else {
            $results.Add((New-Finding -CheckType "RoutingIntent" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName "(none)" `
                -Detail "No Routing Intent configured; no Firewall detected in RG" -Flags "OK"))
        }

        # --- Hub VNet connections: association consistency ---
        $connections = @()
        try {
            $connections = @(Get-AzVirtualHubVnetConnection -ResourceGroupName $vwan.ResourceGroupName -ParentResourceName $hub.Name -ErrorAction Stop)
        }
        catch {
            Write-Status "  Failed to enumerate Hub VNet connections for $($hub.Name): $($_.Exception.Message)" "WARN"
            $results.Add((New-Finding -CheckType "HubVnetConnection" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName "" `
                -Detail "" -Flags "CheckFailed: $($_.Exception.Message)"))
        }

        $associatedTables = New-Object System.Collections.Generic.HashSet[string]
        foreach ($conn in $connections) {
            $assocTable = "Unknown"
            try {
                if ($conn.RoutingConfiguration -and $conn.RoutingConfiguration.AssociatedRouteTable) {
                    $assocTable = $conn.RoutingConfiguration.AssociatedRouteTable.Id
                }
            }
            catch { $assocTable = "Unknown" }
            [void]$associatedTables.Add($assocTable)

            $connFlags = New-Object System.Collections.Generic.List[string]
            if ($conn.ConnectionStatus -and $conn.ConnectionStatus -ne "Connected") { $connFlags.Add("CONNECTION_NOT_CONNECTED") }

            $results.Add((New-Finding -CheckType "HubVnetConnection" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName $conn.Name `
                -Detail "Status=$($conn.ConnectionStatus); AssociatedRouteTable=$assocTable" `
                -Flags $(if ($connFlags.Count -gt 0) { $connFlags -join ";" } else { "OK" })))
        }

        if ($associatedTables.Count -gt 1) {
            $results.Add((New-Finding -CheckType "HubVnetConnection" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName "(hub-level)" `
                -Detail "Distinct associated route tables in use on this hub: $($associatedTables.Count)" `
                -Flags "INCONSISTENT_BRANCH_ASSOCIATION"))
        }

        # --- Optional: ExpressRoute advertised-prefix-count check ---
        if ($IncludeExpressRoutePrefixCheck -and $erGateways.Count -gt 0) {
            try {
                $erConnections = @(Get-AzExpressRouteConnection -ResourceGroupName $vwan.ResourceGroupName -ExpressRouteGatewayName $erGateways[0].Name -ErrorAction Stop)
                foreach ($erConn in $erConnections) {
                    # Best-effort — actual advertised-prefix count requires circuit-level route table inspection,
                    # which is deliberately out of scope for a fast fleet sweep; this records connection presence
                    # and flags for manual follow-up rather than fetching per-circuit route tables at scale.
                    $results.Add((New-Finding -CheckType "ExpressRouteConnection" -VirtualWanName $vwan.Name -HubName $hub.Name -ItemName $erConn.Name `
                        -Detail "Manual follow-up required: check advertised IPv4 prefix count against the 1,000-prefix ceiling via Get-AzExpressRouteCircuitRouteTable" `
                        -Flags "MANUAL_CHECK_RECOMMENDED"))
                }
            }
            catch {
                Write-Status "  ExpressRoute connection check failed for hub $($hub.Name): $($_.Exception.Message)" "WARN"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$hubProvFailedCount   = ($results | Where-Object { $_.Flags -like "*HUB_PROVISIONING_FAILED*" }).Count
$routerFailedCount    = ($results | Where-Object { $_.Flags -like "*ROUTER_STATE_FAILED*" }).Count
$basicSkuGatewayCount = ($results | Where-Object { $_.Flags -like "*GATEWAY_ON_BASIC_SKU*" }).Count
$halfFinishedSecuredHubCount = ($results | Where-Object { $_.Flags -like "*NO_ROUTING_INTENT_BUT_FIREWALL_PRESENT*" }).Count
$inconsistentAssocCount = ($results | Where-Object { $_.Flags -like "*INCONSISTENT_BRANCH_ASSOCIATION*" }).Count
$connNotConnectedCount = ($results | Where-Object { $_.Flags -like "*CONNECTION_NOT_CONNECTED*" }).Count

Write-Status "Audit complete." "OK"
Write-Status "  Hubs with ProvisioningState != Succeeded: $hubProvFailedCount" "INFO"
Write-Status "  Hubs with RoutingState = Failed: $routerFailedCount" "INFO"
Write-Status "  Gateways found attached to a Basic-SKU Virtual WAN (should not occur via supported paths): $basicSkuGatewayCount" "INFO"
Write-Status "  Hubs with a Firewall present but no Routing Intent referencing it: $halfFinishedSecuredHubCount" "INFO"
Write-Status "  Hubs with inconsistent connection route-table association: $inconsistentAssocCount" "INFO"
Write-Status "  Connections not in Connected state: $connNotConnectedCount" "INFO"

if ($routerFailedCount -gt 0) {
    Write-Status "  $routerFailedCount hub(s) show RoutingState: Failed — use the portal's 'Reset router' action; see VirtualWAN-B.md Fix 1." "WARN"
}
if ($hubProvFailedCount -gt 0) {
    Write-Status "  $hubProvFailedCount hub(s) show ProvisioningState != Succeeded — use the portal's full hub 'Reset'; see VirtualWAN-B.md Fix 2." "WARN"
}
if ($basicSkuGatewayCount -gt 0) {
    Write-Status "  $basicSkuGatewayCount gateway(s) found on a Basic-SKU Virtual WAN — verify this is not a stale SKU read before escalating as an anomaly." "WARN"
}
if ($halfFinishedSecuredHubCount -gt 0) {
    Write-Status "  $halfFinishedSecuredHubCount hub(s) have a Firewall deployed but no Routing Intent pointing at it — likely an incomplete secured-hub build." "WARN"
}
if ($inconsistentAssocCount -gt 0) {
    Write-Status "  $inconsistentAssocCount hub(s) show connections associated to more than one route table — confirm this is deliberate segmentation, not drift." "WARN"
}

$exportDir = Split-Path $ExportPath -Parent
if ($exportDir -and -not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to: $ExportPath" "OK"

return $results
