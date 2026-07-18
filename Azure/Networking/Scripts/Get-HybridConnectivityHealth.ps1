<#
.SYNOPSIS
    Audits Azure hybrid connectivity health across VPN Gateway (site-to-site) and ExpressRoute
    circuits in a resource group or subscription.

.DESCRIPTION
    Produces a read-only report covering:
      - VPN Gateway: type/SKU/BGP capability, connection (IPsec tunnel) status, BGP peer state
        and learned-route counts, with a NEAR_PREFIX_LIMIT flag as the on-prem peer approaches
        the 4,000-prefix session-drop ceiling
      - ExpressRoute: circuit + provider provisioning state, private/Microsoft peering config
        presence, eBGP peering state on the MSEE route table, and traffic byte counters as a
        control-plane-vs-data-plane sanity check (a healthy BGP session with zero bytes flowing
        points at a downstream NSG/UDR block, not a connectivity-path fault)

    Deliberately does NOT attempt to reach into the on-premises VPN device or the ExpressRoute
    provider's network — those are outside Azure's API surface entirely. Flags requiring
    provider- or on-prem-side action (e.g. ServiceProviderProvisioningState stuck, or zero BGP
    routes learned) are surfaced so an engineer knows where to escalate, not fixed automatically.

.PARAMETER ResourceGroupName
    Resource group to scope the sweep to. If omitted, scans every resource group in the current
    subscription context.

.PARAMETER SubscriptionId
    Optional. Switches subscription context before running (requires prior authentication to
    that subscription). If omitted, uses the current Az context.

.PARAMETER VpnPrefixWarningThreshold
    Learned-route count on a VPN BGP peer that triggers a NEAR_PREFIX_LIMIT warning ahead of the
    hard 4,000-prefix session-drop ceiling. Defaults to 3500.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\HybridConnectivityAudit_<timestamp>.csv.

.EXAMPLE
    .\Get-HybridConnectivityHealth.ps1 -ResourceGroupName 'rg-network-prod'

.EXAMPLE
    .\Get-HybridConnectivityHealth.ps1 -VpnPrefixWarningThreshold 3000
    Sweeps the entire current subscription with an earlier prefix-limit warning threshold.

.NOTES
    Requires: Az.Network, Az.Accounts modules
    Install:  Install-Module Az.Network, Az.Accounts -Scope CurrentUser
    Permissions: Reader on the network resources is sufficient for every check in this script.
    Safe to run: Read-only. No gateway resets, connection changes, peering config changes, or
                 shared-key operations are performed.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$SubscriptionId,
    [int]$VpnPrefixWarningThreshold = 3500,
    [string]$ExportPath = "C:\Temp\HybridConnectivityAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
try {
    $null = Get-AzContext -ErrorAction Stop
} catch {
    Write-Status "No active Az context. Run Connect-AzAccount first." "ERROR"
    throw
}

if ($SubscriptionId) {
    Write-Status "Switching to subscription $SubscriptionId"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$results = New-Object System.Collections.Generic.List[Object]

# ---- VPN Gateways ----
Write-Status "Enumerating VPN Gateways..."
$gwFilter = if ($ResourceGroupName) { @{ ResourceGroupName = $ResourceGroupName } } else { @{} }
$vpnGateways = Get-AzVirtualNetworkGateway @gwFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.GatewayType -eq 'Vpn' }

foreach ($gw in $vpnGateways) {
    Write-Status "  VPN Gateway: $($gw.Name)"

    $connections = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $gw.ResourceGroupName -ErrorAction SilentlyContinue |
        Where-Object { $_.VirtualNetworkGateway1.Id -eq $gw.Id -or $_.VirtualNetworkGateway2.Id -eq $gw.Id }

    if (-not $connections) {
        $results.Add([pscustomobject]@{
            ResourceType   = "VpnGateway"
            Name           = $gw.Name
            ResourceGroup  = $gw.ResourceGroupName
            Sku            = $gw.Sku.Name
            VpnType        = $gw.VpnType
            EnableBgp      = $gw.EnableBgp
            Item           = "(no connections found)"
            Status         = "NO_CONNECTION"
            Detail         = "Gateway exists with zero connection resources - likely mid-provisioning or orphaned"
            BytesIn        = $null
            BytesOut       = $null
        })
        continue
    }

    foreach ($conn in $connections) {
        $connStatus = if ($conn.ConnectionStatus -eq 'Connected') { 'OK' } else { 'DOWN' }
        $results.Add([pscustomobject]@{
            ResourceType   = "VpnConnection"
            Name           = $gw.Name
            ResourceGroup  = $gw.ResourceGroupName
            Sku            = $gw.Sku.Name
            VpnType        = $gw.VpnType
            EnableBgp      = $gw.EnableBgp
            Item           = $conn.Name
            Status         = $connStatus
            Detail         = "ConnectionStatus=$($conn.ConnectionStatus)"
            BytesIn        = $conn.IngressBytesTransferred
            BytesOut       = $conn.EgressBytesTransferred
        })

        if ($connStatus -eq 'DOWN') {
            Write-Status "    Connection '$($conn.Name)': NotConnected" "WARN"
        }
    }

    if ($gw.EnableBgp) {
        try {
            $bgpPeers = Get-AzVirtualNetworkGatewayBgpPeerStatus -ResourceGroupName $gw.ResourceGroupName -VirtualNetworkGatewayName $gw.Name -ErrorAction Stop
            foreach ($peer in $bgpPeers.BgpPeerStatus) {
                $peerStatus = if ($peer.Connected) { 'OK' } else { 'BGP_DOWN' }
                if ($peer.Connected -and $peer.RoutesReceived -eq 0) { $peerStatus = 'NO_ROUTES_LEARNED' }
                if ($peer.Connected -and $peer.RoutesReceived -ge $VpnPrefixWarningThreshold) { $peerStatus = 'NEAR_PREFIX_LIMIT' }

                $results.Add([pscustomobject]@{
                    ResourceType   = "VpnBgpPeer"
                    Name           = $gw.Name
                    ResourceGroup  = $gw.ResourceGroupName
                    Sku            = $gw.Sku.Name
                    VpnType        = $gw.VpnType
                    EnableBgp      = $gw.EnableBgp
                    Item           = $peer.Neighbor
                    Status         = $peerStatus
                    Detail         = "Connected=$($peer.Connected); RoutesReceived=$($peer.RoutesReceived); ASN=$($peer.Asn)"
                    BytesIn        = $null
                    BytesOut       = $null
                })

                if ($peerStatus -ne 'OK') {
                    Write-Status "    BGP peer $($peer.Neighbor): $peerStatus" "WARN"
                }
            }
        } catch {
            Write-Status "    Could not retrieve BGP peer status: $($_.Exception.Message)" "WARN"
            $results.Add([pscustomobject]@{
                ResourceType = "VpnBgpPeer"; Name = $gw.Name; ResourceGroup = $gw.ResourceGroupName
                Sku = $gw.Sku.Name; VpnType = $gw.VpnType; EnableBgp = $gw.EnableBgp
                Item = "(query failed)"; Status = "CHECK_FAILED"; Detail = $_.Exception.Message
                BytesIn = $null; BytesOut = $null
            })
        }
    }
}

if (-not $vpnGateways) { Write-Status "No VPN Gateways found in scope." }

# ---- ExpressRoute Circuits ----
Write-Status "Enumerating ExpressRoute circuits..."
$circuits = Get-AzExpressRouteCircuit @gwFilter -ErrorAction SilentlyContinue

foreach ($ckt in $circuits) {
    Write-Status "  ExpressRoute circuit: $($ckt.Name)"

    $circuitOk  = $ckt.CircuitProvisioningState -eq 'Enabled'
    $providerOk = $ckt.ServiceProviderProvisioningState -eq 'Provisioned'
    $circuitStatus = if ($circuitOk -and $providerOk) { 'OK' }
                     elseif (-not $circuitOk) { 'MICROSOFT_SIDE_NOT_ENABLED' }
                     else { 'PROVIDER_SIDE_NOT_PROVISIONED' }

    $results.Add([pscustomobject]@{
        ResourceType   = "ExpressRouteCircuit"
        Name           = $ckt.Name
        ResourceGroup  = $ckt.ResourceGroupName
        Sku            = $ckt.Sku.Name
        VpnType        = "N/A"
        EnableBgp      = "N/A"
        Item           = $ckt.ServiceKey
        Status         = $circuitStatus
        Detail         = "CircuitProvisioningState=$($ckt.CircuitProvisioningState); ServiceProviderProvisioningState=$($ckt.ServiceProviderProvisioningState); Provider=$($ckt.ServiceProviderProperties.ServiceProviderName)"
        BytesIn        = $null
        BytesOut       = $null
    })

    if ($circuitStatus -ne 'OK') {
        Write-Status "    Circuit/provider state: $circuitStatus" "WARN"
        continue  # peering/route checks are meaningless until the circuit itself is healthy
    }

    foreach ($peeringType in @('AzurePrivatePeering', 'MicrosoftPeering')) {
        try {
            $peeringCfg = Get-AzExpressRouteCircuitPeeringConfig -Name $peeringType -ExpressRouteCircuit $ckt -ErrorAction Stop
        } catch {
            # Peering not configured - not a fault, just not in use
            continue
        }

        $peeringResult = [pscustomobject]@{
            ResourceType   = "ExpressRoutePeering"
            Name           = $ckt.Name
            ResourceGroup  = $ckt.ResourceGroupName
            Sku            = $ckt.Sku.Name
            VpnType        = "N/A"
            EnableBgp      = "N/A"
            Item           = $peeringType
            Status         = "CONFIGURED"
            Detail         = "VlanId=$($peeringCfg.VlanId); AzureASN=$($peeringCfg.AzureASN); PeerASN=$($peeringCfg.PeerASN); ProvisioningState=$($peeringCfg.ProvisioningState)"
            BytesIn        = $null
            BytesOut       = $null
        }

        if ($peeringType -eq 'AzurePrivatePeering') {
            try {
                $routeTable = Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName $ckt.Name -PeeringType $peeringType -ResourceGroupName $ckt.ResourceGroupName -ErrorAction Stop
                $peeringResult.Status = if ($routeTable) { "BGP_ROUTES_PRESENT" } else { "BGP_ESTABLISHED_NO_ROUTES" }
            } catch {
                $peeringResult.Status = "BGP_NOT_ESTABLISHED"
                $peeringResult.Detail += "; RouteTableQuery=$($_.Exception.Message)"
            }

            try {
                $stats = Get-AzExpressRouteCircuitStats -ResourceGroupName $ckt.ResourceGroupName -ExpressRouteCircuitName $ckt.Name -PeeringType $peeringType -ErrorAction Stop
                $peeringResult.BytesIn  = $stats.PrimaryBytesIn
                $peeringResult.BytesOut = $stats.PrimaryBytesOut
                if ($peeringResult.Status -eq 'BGP_ROUTES_PRESENT' -and $stats.PrimaryBytesIn -eq 0 -and $stats.PrimaryBytesOut -eq 0) {
                    $peeringResult.Status = "ROUTES_OK_ZERO_TRAFFIC"
                    Write-Status "    $peeringType routes present but zero traffic - check NSG/UDR downstream" "WARN"
                }
            } catch {
                $peeringResult.Detail += "; StatsQuery=$($_.Exception.Message)"
            }
        }

        $results.Add($peeringResult)

        if ($peeringResult.Status -in @('BGP_NOT_ESTABLISHED', 'BGP_ESTABLISHED_NO_ROUTES')) {
            Write-Status "    $peeringType : $($peeringResult.Status)" "WARN"
        }
    }
}

if (-not $circuits) { Write-Status "No ExpressRoute circuits found in scope." }

# ---- Report ----
$results | Export-Csv -Path $ExportPath -NoTypeInformation

$problemCount = ($results | Where-Object { $_.Status -notin @('OK', 'CONFIGURED', 'BGP_ROUTES_PRESENT') }).Count
Write-Status "Audit complete. $($results.Count) items checked, $problemCount flagged for review." $(if ($problemCount -gt 0) { "WARN" } else { "OK" })
Write-Status "Report exported to: $ExportPath" "OK"

$results
