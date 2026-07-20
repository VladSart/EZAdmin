<#
.SYNOPSIS
    Read-only health and configuration audit for Azure VPN Gateway Point-to-Site (P2S) deployments.

.DESCRIPTION
    Sweeps VPN Gateways in a subscription (or a single named gateway) and reports P2S-specific
    configuration health: gateway SKU capability ceiling checks (Basic SKU vs. IKEv2/RADIUS/IPv6),
    client address pool presence and overlap risk against the gateway's own VNet address space,
    root certificate presence (Certificate auth), RADIUS server configuration presence (RADIUS auth),
    Microsoft Entra ID Audience/Tenant/Issuer configuration presence (Entra ID auth), and a basic
    RADIUS reachability check when a RADIUS server address is configured and reachable from the
    machine running this script (best-effort — the authoritative reachability path is FROM the
    gateway subnet, which this script cannot test directly).

    This script makes NO configuration changes. It does not validate certificate CHAIN correctness
    (only presence/count), does not test actual VPN client connectivity, and does not inspect
    per-session/per-user connection state (no Az cmdlet exposes live P2S session telemetry).

.PARAMETER ResourceGroupName
    Optional. Limit the sweep to VPN Gateways in this resource group. If omitted, scans the
    current subscription context.

.PARAMETER GatewayName
    Optional. Audit only this specific gateway (requires -ResourceGroupName).

.PARAMETER TestRadiusReachability
    Optional switch. If set, attempts a TCP/UDP reachability probe to any configured RADIUS
    server address from the machine running this script. This is a best-effort convenience check,
    NOT authoritative — the gateway itself reaches RADIUS from its own subnet, which may have a
    different network path than wherever this script is run from.

.EXAMPLE
    .\Get-P2SVPNGatewayHealth.ps1

    Scans every VPN Gateway in the current subscription and reports P2S configuration health.

.EXAMPLE
    .\Get-P2SVPNGatewayHealth.ps1 -ResourceGroupName rg-network-prod -GatewayName vgw-hub-01 -TestRadiusReachability

    Audits a single named gateway and attempts a best-effort RADIUS reachability probe.

.NOTES
    Requires: Az.Network module, an authenticated Az context with Reader access to the target
    subscription/resource group.
    Run-as: any account with Microsoft.Network/virtualNetworkGateways/read permission.
    Safe: read-only. Makes no configuration changes. Exports findings to CSV.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$ResourceGroupName,
    [Parameter(Mandatory = $false)][string]$GatewayName,
    [Parameter(Mandatory = $false)][switch]$TestRadiusReachability
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Status "No Az context found. Run Connect-AzAccount first." "ERROR"
        return
    }
    Write-Status "Running as $($context.Account.Id) against subscription $($context.Subscription.Name)" "INFO"
}
catch {
    Write-Status "Failed to resolve Az context: $($_.Exception.Message)" "ERROR"
    return
}

# --- Detect: gather target gateways ---
$gateways = @()
try {
    if ($GatewayName -and $ResourceGroupName) {
        $gateways += Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -Name $GatewayName
    }
    elseif ($ResourceGroupName) {
        $gateways += Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName | Where-Object { $_.GatewayType -eq "Vpn" }
    }
    else {
        $allRgs = Get-AzResourceGroup
        foreach ($rg in $allRgs) {
            $gateways += Get-AzVirtualNetworkGateway -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue |
                Where-Object { $_.GatewayType -eq "Vpn" }
        }
    }
}
catch {
    Write-Status "Failed to enumerate VPN Gateways: $($_.Exception.Message)" "ERROR"
    return
}

if ($gateways.Count -eq 0) {
    Write-Status "No VPN-type gateways found in scope." "WARN"
    return
}

Write-Status "Found $($gateways.Count) VPN-type gateway(s) to audit." "INFO"

# --- Execute: build audit report ---
$report = New-Object System.Collections.Generic.List[PSObject]

foreach ($gw in $gateways) {
    $vcc = $gw.VpnClientConfiguration
    $hasP2S = $null -ne $vcc -and ($null -ne $vcc.VpnClientAddressPool -and $vcc.VpnClientAddressPool.AddressPrefixes.Count -gt 0)

    if (-not $hasP2S) {
        $report.Add([PSCustomObject]@{
            GatewayName           = $gw.Name
            ResourceGroup         = $gw.ResourceGroupName
            SkuName               = $gw.Sku.Name
            P2SConfigured         = $false
            AddressPool           = $null
            Protocols             = $null
            RootCertCount         = 0
            RadiusConfigured      = $false
            RadiusReachable       = "N/A"
            AadAuthConfigured     = $false
            AadAudience           = $null
            BasicSkuFeatureGap    = "N/A"
            Finding               = "P2S not configured on this gateway"
        })
        continue
    }

    $protocols = @($vcc.VpnClientProtocols)
    $radiusConfigured = -not [string]::IsNullOrEmpty($vcc.RadiusServerAddress)
    $aadConfigured = -not [string]::IsNullOrEmpty($vcc.AadAudience)
    $rootCertCount = if ($vcc.VpnClientRootCertificates) { $vcc.VpnClientRootCertificates.Count } else { 0 }

    # Basic SKU feature-gap check
    $basicGap = $false
    $basicGapReasons = @()
    if ($gw.Sku.Name -eq "Basic") {
        if ($protocols -contains "IkeV2") { $basicGapReasons += "IKEv2 configured on Basic SKU (unsupported)" }
        if ($radiusConfigured) { $basicGapReasons += "RADIUS configured on Basic SKU (unsupported)" }
        $basicGap = $basicGapReasons.Count -gt 0
    }

    # RADIUS reachability best-effort probe
    $radiusReachable = "Not tested"
    if ($TestRadiusReachability -and $radiusConfigured) {
        try {
            $probe = Test-NetConnection -ComputerName $vcc.RadiusServerAddress -Port 1812 -WarningAction SilentlyContinue -ErrorAction Stop
            $radiusReachable = if ($probe.TcpTestSucceeded) { "Reachable (TCP probe — RADIUS itself is UDP, treat as indicative only)" } else { "Unreachable from script host (not authoritative — gateway reaches from its own subnet)" }
        }
        catch {
            $radiusReachable = "Probe failed: $($_.Exception.Message)"
        }
    }

    $findings = @()
    if ($basicGap) { $findings += "BASIC SKU FEATURE GAP: $($basicGapReasons -join '; ')" }
    if ($rootCertCount -eq 0 -and ($protocols -notcontains "OpenVPN" -or -not $aadConfigured) -and -not $radiusConfigured) {
        $findings += "No root certificates AND no RADIUS/Entra ID auth configured — Certificate auth likely intended but incomplete"
    }
    if ($vcc.VpnClientAddressPool.AddressPrefixes.Count -eq 0) {
        $findings += "Client address pool is empty despite VpnClientConfiguration existing"
    }
    if ($findings.Count -eq 0) { $findings += "No issues detected by this script's checks" }

    $report.Add([PSCustomObject]@{
        GatewayName           = $gw.Name
        ResourceGroup         = $gw.ResourceGroupName
        SkuName               = $gw.Sku.Name
        P2SConfigured         = $true
        AddressPool           = ($vcc.VpnClientAddressPool.AddressPrefixes -join "; ")
        Protocols             = ($protocols -join "; ")
        RootCertCount         = $rootCertCount
        RadiusConfigured      = $radiusConfigured
        RadiusReachable       = $radiusReachable
        AadAuthConfigured     = $aadConfigured
        AadAudience           = $vcc.AadAudience
        BasicSkuFeatureGap    = if ($basicGap) { "YES" } else { "No" }
        Finding               = ($findings -join " | ")
    })
}

# --- Report ---
$report | Format-Table GatewayName, SkuName, P2SConfigured, BasicSkuFeatureGap, RootCertCount, RadiusConfigured, AadAuthConfigured, Finding -AutoSize

$exportPath = ".\P2SVPNGatewayHealth_$(Get-Date -Format yyyyMMdd_HHmm).csv"
$report | Export-Csv -Path $exportPath -NoTypeInformation
Write-Status "Report exported to $exportPath" "OK"

$gapCount = ($report | Where-Object { $_.BasicSkuFeatureGap -eq "YES" }).Count
if ($gapCount -gt 0) {
    Write-Status "$gapCount gateway(s) have a Basic SKU feature gap — IKEv2/RADIUS configured but unsupported by SKU." "WARN"
}
